//! Fast transfers in the Rust helper (ADR 0018, PROTOCOL.md § Fast transfers), on one session per friend for now
//! (lanes are WP3's): on a session that negotiated them, our OFFER announces the tree, the friend's helper takes the
//! file by blocks (OFFER_REPLY with Blocks), we send the leaves (HASHES) and then the blocks it wants as PARTs, and it
//! answers with HAVE as blocks check and become durable, and with ACK once the whole file checked and was saved. On
//! every new session it asks for exactly what is still missing (WANT). With anyone else, nothing here runs and the
//! CHUNK flow of `transfers.rs` moves the file as before.

use szfriends_core::session::chunk_bytes_for_route;
use szfriends_core::store::{BlockPart, StoreError, TransferRecord};
use szfriends_core::transfer::{frames, BlockServe, ServeError};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType};

use super::{hex, unhex, State};

/// Parts queued in the channel ahead of the link, as for CHUNKs: a message still overtakes them.
const BULK_DEPTH: usize = 4;
/// What one session keeps sent and not yet in a HAVE (one lane; the scheduler of WP2 sizes this per lane later).
const WINDOW_BYTES: u64 = 16 << 20;
const WINDOW_BYTES_BLUETOOTH: u64 = 2 << 20;

/// One of our files going by blocks on one session.
#[derive(Debug)]
pub struct BlockSend {
    pub serve: BlockServe,
    pub record: TransferRecord,
}

impl State {
    /// Whether this session runs fast transfers (ADR 0018 § 1).
    pub(crate) fn fast_session(&self, id: u64) -> bool {
        self.sessions.map.get(&id).is_some_and(|s| s.channel.fast_transfers())
    }

    /// Our OFFER on a fast session announces the tree (computed once and kept beside the snapshot).
    pub(crate) fn with_tree(&mut self, id: u64, record: &TransferRecord, offer: Frame) -> Frame {
        if !self.fast_session(id) {
            return offer;
        }
        match self.store.sender_tree(record) {
            Ok(tree) => frames::offer_with_tree(offer, &tree.header.geometry, &tree.header.root),
            Err(_) => offer,
        }
    }

    /// Their OFFER announced a tree: kept for when the person accepts.
    pub(crate) fn offered_tree(&mut self, id: u64, frame: &Frame, conversation: &str, transfer: &str) {
        if !self.fast_session(id) {
            return;
        }
        if let Some((geometry, root)) = frames::offered_tree(frame) {
            let _ = self.store.record_offered_tree(transfer, conversation, geometry, root);
        }
    }

    /// Accepting on a fast session, for a file whose tree we have: the reply that takes it by blocks.
    pub(crate) fn blocks_reply(&mut self, id: u64, transfer: &str, conversation: &str) -> Option<Frame> {
        if !self.fast_session(id) {
            if self.store.offered_tree(transfer).is_some() {
                // Taken by CHUNK after all: the CHUNK flow resumes from the prefix, and the map would lie.
                self.store.drop_blocks(transfer);
            }
            return None;
        }
        if !self.store.begin_blocks(transfer, conversation).ok()? {
            return None;
        }
        self.sessions.map.get_mut(&id)?.block_receivers.insert(transfer.to_owned());
        let wire = unhex(transfer)?;
        Some(Frame::new(FrameType::OfferReply).with(tag::ID, wire).with(tag::ACCEPT, [1]).with(tag::BLOCKS, [1]))
    }

    /// A new fast session: an unfinished download by blocks asks for what is missing. `false` when it goes by CHUNK.
    pub(crate) fn resume_blocks(&mut self, id: u64, record: &TransferRecord) -> bool {
        if !self.fast_session(id) {
            if self.store.offered_tree(&record.transfer_id).is_some() {
                self.store.drop_blocks(&record.transfer_id);
            }
            return false;
        }
        if !self.store.begin_blocks(&record.transfer_id, &record.conversation_id).unwrap_or(false) {
            return false;
        }
        let Some(wire) = unhex(&record.transfer_id) else { return false };
        let missing = self.store.block_missing(&record.transfer_id);
        if let Some(session) = self.sessions.map.get_mut(&id) {
            session.block_receivers.insert(record.transfer_id.clone());
        }
        for frame in frames::want(&wire, &missing) {
            self.send_on(id, &frame);
        }
        if missing.is_empty() {
            // Every block arrived before the last session ended: the check and the ACK are all that is left.
            self.blocks_progressed(id, &record.transfer_id, &record.conversation_id);
        }
        true
    }

    /// Starts serving one of our files by blocks on this session, sending its leaves first.
    fn start_block_send(&mut self, id: u64, offer: &str, conversation: &str) -> Option<bool> {
        if self.sessions.map.get(&id)?.block_senders.contains_key(offer) {
            return Some(false);
        }
        let (record, first) = match self.store.peer_took_blocks(offer, conversation) {
            Ok(taken) => taken,
            Err(StoreError::FileMissing) => {
                self.changed();
                return None;
            }
            Err(_) => return None,
        };
        let tree = self.store.sender_tree(&record).ok()?;
        let route = self.sessions.map.get(&id).map(|s| s.meta.race_route(&s.channel))?;
        let bluetooth = route == szfriends_core::wire::RouteMethod::Bluetooth;
        let window = if bluetooth { WINDOW_BYTES_BLUETOOTH } else { WINDOW_BYTES };
        let wire = unhex(offer)?;
        let mut serve = BlockServe::new(&wire, tree.header.geometry, tree.leaves, chunk_bytes_for_route(route), window);
        if first {
            serve.want_all();
        }
        for frame in serve.hashes_frames() {
            self.send_on(id, &frame);
        }
        let session = self.sessions.map.get_mut(&id)?;
        session.expecting.insert(hex(&wire), format!("done:{offer}"));
        session.block_senders.insert(offer.to_owned(), BlockSend { serve, record });
        Some(true)
    }

    /// OFFER_REPLY accepting with Blocks: the friend's helper takes our file by blocks.
    pub(crate) fn offer_taken_by_blocks(&mut self, id: u64, offer: &str) -> bool {
        let Some(conversation) = self.conversation_of(id) else { return false };
        if !self.fast_session(id) {
            return false;
        }
        self.start_block_send(id, offer, &conversation).is_some()
    }

    fn block_wire(frame: &Frame) -> Option<String> {
        frame.get(tag::ID).map(hex)
    }

    /// HASHES, WANT, PART and HAVE (minor 4; the channel lets them in only on a fast session).
    pub(crate) fn block_frame(&mut self, id: u64, frame: &Frame, conversation: &str) {
        let Some(transfer) = Self::block_wire(frame) else { return };
        match frame.frame_type {
            FrameType::Hashes => self.hashes(id, frame, conversation, &transfer),
            FrameType::Want => self.want(id, frame, conversation, &transfer),
            FrameType::Part => self.part(id, frame, conversation, &transfer),
            FrameType::Have => self.have(id, frame, &transfer),
            _ => {}
        }
    }

    /// A WANT, HAVE or PART that names something we are not doing with them: unsolicited, as ADR 0001 has it.
    fn unsolicited(&mut self, id: u64) {
        self.close(id, CloseReason::ProtocolError);
    }

    fn hashes(&mut self, id: u64, frame: &Frame, conversation: &str, transfer: &str) {
        let (Some(index), Some(hashes)) = (frame.integer(tag::INDEX), frame.get(tag::HASHES)) else { return };
        match self.store.block_hashes(transfer, conversation, index as u32, hashes) {
            Ok(_) => {
                if let Some(session) = self.sessions.map.get_mut(&id) {
                    session.block_receivers.insert(transfer.to_owned());
                }
                self.blocks_progressed(id, transfer, conversation);
            }
            Err(StoreError::Stale) => {} // cancelled or finished meanwhile
            Err(_) => self.unsolicited(id),
        }
    }

    fn want(&mut self, id: u64, frame: &Frame, conversation: &str, transfer: &str) {
        let Some(ranges) = frames::ranges_of(frame, tag::RANGES).filter(|r| !r.is_empty()) else {
            return self.unsolicited(id);
        };
        // A WANT only for an offer this side made to that person, accepted (§ 8).
        let ours = self.store.transfer(transfer).ok().flatten().is_some_and(|r| {
            r.outgoing && r.conversation_id == conversation && r.state == szfriends_core::store::TransferState::Sending
        });
        if !ours || self.start_block_send(id, transfer, conversation).is_none() {
            return self.unsolicited(id);
        }
        let Some(send) = self.sessions.map.get_mut(&id).and_then(|s| s.block_senders.get_mut(transfer)) else {
            return;
        };
        if send.serve.want(&ranges).is_err() {
            self.unsolicited(id);
        }
    }

    fn have(&mut self, id: u64, frame: &Frame, transfer: &str) {
        let Some(complete) = frames::ranges_of(frame, tag::RANGES) else { return self.unsolicited(id) };
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        let Some(send) = session.block_senders.get_mut(transfer) else {
            // A HAVE for a transfer that ended here meanwhile is late; for anything else, unsolicited.
            let ours = self.store.transfer(transfer).ok().flatten().is_some_and(|r| r.outgoing);
            if !ours {
                self.unsolicited(id);
            }
            return;
        };
        if send.serve.have(&complete).is_err() {
            self.unsolicited(id);
        }
        self.changed();
    }

    fn part(&mut self, id: u64, frame: &Frame, conversation: &str, transfer: &str) {
        if frame.get(tag::CODEC).is_some() {
            // Compressed parts are capability bit 2, which this build does not set.
            return self.unsolicited(id);
        }
        let receiving = self.sessions.map.get(&id).is_some_and(|s| s.block_receivers.contains(transfer));
        let (Some(offset), Some(data)) = (frame.integer(tag::OFFSET), frame.get(tag::DATA)) else { return };
        if !receiving {
            // Late for a transfer that just ended here (§ 3); unsolicited otherwise.
            let ended = self
                .store
                .transfer(transfer)
                .ok()
                .flatten()
                .is_some_and(|r| !r.outgoing && r.conversation_id == conversation);
            if !ended {
                self.unsolicited(id);
            }
            return;
        }
        match self.store.block_part(transfer, conversation, offset, data) {
            Ok(BlockPart::Pending | BlockPart::Late) => {}
            Ok(BlockPart::Written(_)) => self.blocks_progressed(id, transfer, conversation),
            Ok(BlockPart::Corrupt(block)) => {
                // Fetched again alone; the file does not restart.
                if let Some(wire) = unhex(transfer) {
                    for frame in frames::want(&wire, &[(block, 1)]) {
                        self.send_on(id, &frame);
                    }
                }
            }
            Err(StoreError::Stale) => {
                if let Some(session) = self.sessions.map.get_mut(&id) {
                    session.block_receivers.remove(transfer);
                }
            }
            Err(_) => self.unsolicited(id),
        }
    }

    /// After blocks were written or made durable: HAVE for what changed, and once every block is durable, the check
    /// before saving and the ACK.
    pub(crate) fn blocks_progressed(&mut self, id: u64, transfer: &str, conversation: &str) {
        let (complete, durable) = self.store.take_block_have(transfer);
        let Some(wire) = unhex(transfer) else { return };
        for frame in frames::have(&wire, &complete, &durable) {
            self.send_on(id, &frame);
        }
        if !complete.is_empty() || !durable.is_empty() {
            self.changed();
        }
        if !self.store.blocks_all_durable(transfer) {
            return;
        }
        if let Some(session) = self.sessions.map.get_mut(&id) {
            session.block_receivers.remove(transfer);
        }
        match self.store.finish_block_transfer(transfer, conversation) {
            Ok(_) => self.send_ack(id, &wire),
            Err(error) => crate::log!("a file received by blocks did not check: {error}"),
        }
        self.changed();
    }

    /// Durability batches that came due while parts paused; their HAVEs go on the session receiving them.
    pub(crate) fn flush_blocks_if_due(&mut self) {
        let Ok(flushed) = self.store.flush_due_blocks(false) else { return };
        for transfer in flushed {
            let found = self
                .sessions
                .map
                .iter()
                .find(|(_, s)| s.block_receivers.contains(&transfer))
                .map(|(id, s)| (*id, s.conversation.clone()));
            if let Some((id, Some(conversation))) = found {
                self.blocks_progressed(id, &transfer, &conversation);
            }
        }
    }

    /// The next parts of every file this session sends by blocks, while the channel's bulk queue is shallow.
    pub(crate) fn pump_blocks(&mut self, id: u64) {
        let offers: Vec<String> = match self.sessions.map.get(&id) {
            Some(s) if s.channel.is_established() => s.block_senders.keys().cloned().collect(),
            _ => return,
        };
        for offer in offers {
            loop {
                let Some(session) = self.sessions.map.get_mut(&id) else { return };
                if session.channel.queued_frames().1 >= BULK_DEPTH {
                    return;
                }
                let Some(send) = session.block_senders.get_mut(&offer) else { break };
                if let Some(part) = send.serve.next_part() {
                    session.channel.send_frame(&part, szfriends_core::session::monotonic_now());
                    continue;
                }
                let Some(block) = send.serve.next_block() else { break };
                let geometry = *send.serve.geometry();
                let read = self.store.read_outgoing_block(&send.record, &geometry, block);
                let session = self.sessions.map.get_mut(&id).expect("live");
                let send = session.block_senders.get_mut(&offer).expect("listed");
                let loaded = match read {
                    Ok(data) => send.serve.load_block(block, data),
                    Err(_) => Err(ServeError::Changed),
                };
                if loaded.is_err() {
                    // The snapshot changed or went: the transfer fails, as a missing source does.
                    session.block_senders.remove(&offer);
                    let _ = self.store.snapshot_changed(&offer);
                    self.changed();
                    break;
                }
            }
        }
    }
}
