//! Fast transfers in the Rust peer, as the Rust helper runs them (`szfriends-helper/src/service/blocks.rs`, ADR 0018):
//! on a session that negotiated them, an OFFER announces the tree, the receiver takes the file by blocks, the sender
//! sends the leaves and then the wanted blocks as PARTs, the receiver answers with HAVE and, once the whole file checked
//! and was saved, ACK; on every new session it asks for exactly what is missing (WANT). With a peer that did not
//! negotiate them, the CHUNK flow of `flows.rs` runs as before. The store does the work; this is the helper's wiring,
//! kept in step with it so the transfer bench and the interop matrix measure what the helper does.

use std::collections::HashMap;

use serde_json::json;
use szfriends_core::session::{chunk_bytes_for_route, monotonic_now};
use szfriends_core::store::{BlockPart, StoreError, TransferRecord, TransferState};
use szfriends_core::transfer::{frames, BlockServe};
use szfriends_core::wire::{tag, Frame, FrameType, RouteMethod};

use crate::hex_bytes;
use crate::peer::State;

/// As the helper: parts queued in the channel ahead of the link, and what one session keeps sent and not in a HAVE.
const BULK_DEPTH: usize = 4;
const WINDOW_BYTES: u64 = 16 << 20;
const WINDOW_BYTES_BLUETOOTH: u64 = 2 << 20;

/// One of our files going by blocks on one session.
pub(crate) struct BlockSend {
    serve: BlockServe,
    record: TransferRecord,
}

/// What a session does by blocks: files it sends, and files it receives.
#[derive(Default)]
pub(crate) struct Blocks {
    pub(crate) senders: HashMap<String, BlockSend>,
    pub(crate) receivers: std::collections::HashSet<String>,
}

impl State {
    pub(crate) fn fast_session(&self, id: u64) -> bool {
        self.sessions.get(&id).is_some_and(|s| s.channel.fast_transfers())
    }

    fn send_frame(&mut self, id: u64, frame: &Frame) {
        if let Some(session) = self.sessions.get_mut(&id) {
            session.channel.send_frame(frame, monotonic_now());
        }
    }

    /// Our OFFER on a fast session announces the tree.
    pub(crate) fn with_tree(&mut self, id: u64, record: &TransferRecord, offer: Frame) -> Frame {
        if !self.fast_session(id) {
            return offer;
        }
        match self.store.sender_tree(record) {
            Ok(tree) => frames::offer_with_tree(offer, &tree.header.geometry, &tree.header.root),
            Err(_) => offer,
        }
    }

    /// Their OFFER announced a tree: kept for the acceptance.
    pub(crate) fn offered_tree(&mut self, id: u64, frame: &Frame, conversation: &str, transfer: &str) {
        if !self.fast_session(id) {
            return;
        }
        if let Some((geometry, root)) = frames::offered_tree(frame) {
            let _ = self.store.record_offered_tree(transfer, conversation, geometry, root);
        }
    }

    /// Accepting on a fast session a file whose tree we have: the reply that takes it by blocks.
    pub(crate) fn blocks_reply(&mut self, id: u64, transfer: &str, conversation: &str) -> Option<Frame> {
        if !self.fast_session(id) {
            if self.store.offered_tree(transfer).is_some() {
                self.store.drop_blocks(transfer);
            }
            return None;
        }
        if !self.store.begin_blocks(transfer, conversation).ok()? {
            return None;
        }
        self.sessions.get_mut(&id)?.blocks.receivers.insert(transfer.to_owned());
        let wire = hex_bytes(transfer)?;
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
        let Some(wire) = hex_bytes(&record.transfer_id) else { return false };
        let missing = self.store.block_missing(&record.transfer_id);
        if let Some(session) = self.sessions.get_mut(&id) {
            session.blocks.receivers.insert(record.transfer_id.clone());
        }
        for frame in frames::want(&wire, &missing) {
            self.send_frame(id, &frame);
        }
        if missing.is_empty() {
            self.blocks_progressed(id, &record.transfer_id, &record.conversation_id);
        }
        true
    }

    /// Starts serving one of our files by blocks on this session, leaves first. `Some(false)` when it already is.
    fn start_block_send(&mut self, id: u64, offer: &str, conversation: &str) -> Option<bool> {
        if self.sessions.get(&id)?.blocks.senders.contains_key(offer) {
            return Some(false);
        }
        let (record, first) = self.store.peer_took_blocks(offer, conversation).ok()?;
        let tree = self.store.sender_tree(&record).ok()?;
        let route = self.sessions.get(&id)?.channel.initiator_route();
        let window = if route == RouteMethod::Bluetooth { WINDOW_BYTES_BLUETOOTH } else { WINDOW_BYTES };
        let wire = hex_bytes(offer)?;
        let mut serve = BlockServe::new(&wire, tree.header.geometry, tree.leaves, chunk_bytes_for_route(route), window);
        if first {
            serve.want_all();
            self.emit(json!({ "event": "sending", "session": id, "transfer": offer, "offset": 0, "blocks": true }));
        }
        for frame in serve.hashes_frames() {
            self.send_frame(id, &frame);
        }
        self.sessions.get_mut(&id)?.blocks.senders.insert(offer.to_owned(), BlockSend { serve, record });
        Some(true)
    }

    /// OFFER_REPLY accepting with Blocks.
    pub(crate) fn offer_taken_by_blocks(&mut self, id: u64, offer: &str) -> bool {
        let Some(conversation) = self.sessions.get(&id).and_then(|s| s.conversation.clone()) else { return false };
        self.fast_session(id) && self.start_block_send(id, offer, &conversation).is_some()
    }

    /// HASHES, WANT, PART and HAVE; `false` for any other frame.
    pub(crate) fn block_frame(&mut self, id: u64, frame: &Frame) -> bool {
        if !matches!(frame.frame_type, FrameType::Hashes | FrameType::Want | FrameType::Part | FrameType::Have) {
            return false;
        }
        let Some(conversation) = self.sessions.get(&id).and_then(|s| s.conversation.clone()) else {
            self.close_for_protocol(id);
            return true;
        };
        let Some(transfer) = frame.get(tag::ID).map(hex::encode) else { return true };
        match frame.frame_type {
            FrameType::Hashes => self.hashes(id, frame, &conversation, &transfer),
            FrameType::Want => self.want(id, frame, &conversation, &transfer),
            FrameType::Part => self.part(id, frame, &conversation, &transfer),
            _ => self.have(id, frame, &transfer),
        }
        true
    }

    /// A WANT, HAVE or PART for nothing this side does with them: unsolicited, as ADR 0001 has it.
    fn unsolicited(&mut self, id: u64) {
        self.close_for_protocol(id);
    }

    fn hashes(&mut self, id: u64, frame: &Frame, conversation: &str, transfer: &str) {
        let (Some(index), Some(hashes)) = (frame.integer(tag::INDEX), frame.get(tag::HASHES)) else { return };
        match self.store.block_hashes(transfer, conversation, index as u32, hashes) {
            Ok(_) => {
                if let Some(session) = self.sessions.get_mut(&id) {
                    session.blocks.receivers.insert(transfer.to_owned());
                }
                self.blocks_progressed(id, transfer, conversation);
            }
            Err(StoreError::Stale) => {}
            Err(_) => self.unsolicited(id),
        }
    }

    fn want(&mut self, id: u64, frame: &Frame, conversation: &str, transfer: &str) {
        let Some(ranges) = frames::ranges_of(frame, tag::RANGES).filter(|r| !r.is_empty()) else {
            return self.unsolicited(id);
        };
        let ours = self
            .store
            .transfer(transfer)
            .ok()
            .flatten()
            .is_some_and(|r| r.outgoing && r.conversation_id == conversation && r.state == TransferState::Sending);
        if !ours || self.start_block_send(id, transfer, conversation).is_none() {
            return self.unsolicited(id);
        }
        let Some(send) = self.sessions.get_mut(&id).and_then(|s| s.blocks.senders.get_mut(transfer)) else { return };
        if send.serve.want(&ranges).is_err() {
            return self.unsolicited(id);
        }
        // The bench reads the resume point here, as it reads a CHUNK resume's offset.
        let offset = u64::from(ranges[0].0) * send.serve.geometry().block_bytes();
        self.emit(json!({ "event": "sending", "session": id, "transfer": transfer, "offset": offset, "blocks": true }));
    }

    fn have(&mut self, id: u64, frame: &Frame, transfer: &str) {
        let Some(complete) = frames::ranges_of(frame, tag::RANGES) else { return self.unsolicited(id) };
        let Some(send) = self.sessions.get_mut(&id).and_then(|s| s.blocks.senders.get_mut(transfer)) else {
            let ours = self.store.transfer(transfer).ok().flatten().is_some_and(|r| r.outgoing);
            if !ours {
                self.unsolicited(id);
            }
            return;
        };
        if send.serve.have(&complete).is_err() {
            self.unsolicited(id);
        }
    }

    fn part(&mut self, id: u64, frame: &Frame, conversation: &str, transfer: &str) {
        if frame.get(tag::CODEC).is_some() {
            return self.unsolicited(id);
        }
        let receiving = self.sessions.get(&id).is_some_and(|s| s.blocks.receivers.contains(transfer));
        let (Some(offset), Some(data)) = (frame.integer(tag::OFFSET), frame.get(tag::DATA)) else { return };
        if !receiving {
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
                if let Some(wire) = hex_bytes(transfer) {
                    for frame in frames::want(&wire, &[(block, 1)]) {
                        self.send_frame(id, &frame);
                    }
                }
            }
            Err(StoreError::Stale) => {
                if let Some(session) = self.sessions.get_mut(&id) {
                    session.blocks.receivers.remove(transfer);
                }
            }
            Err(_) => self.unsolicited(id),
        }
    }

    /// HAVE for what changed; once every block is durable, the check before saving, the ACK and `received_file`.
    fn blocks_progressed(&mut self, id: u64, transfer: &str, conversation: &str) {
        let (complete, durable) = self.store.take_block_have(transfer);
        let Some(wire) = hex_bytes(transfer) else { return };
        for frame in frames::have(&wire, &complete, &durable) {
            self.send_frame(id, &frame);
        }
        if !self.store.blocks_all_durable(transfer) {
            return;
        }
        if let Some(session) = self.sessions.get_mut(&id) {
            session.blocks.receivers.remove(transfer);
        }
        match self.store.finish_block_transfer(transfer, conversation) {
            Ok(path) => {
                self.send_frame(id, &Frame::new(FrameType::Ack).with(tag::ID, wire));
                let path = path.to_string_lossy().into_owned();
                self.emit(json!({ "event": "received_file", "transfer": transfer, "path": path }));
            }
            Err(error) => {
                self.emit(json!({ "event": "transfer_failed", "transfer": transfer, "why": error.to_string() }));
            }
        }
    }

    /// Durability batches that came due while parts paused; their HAVEs go on the session receiving them.
    pub(crate) fn flush_blocks_if_due(&mut self) {
        let Ok(flushed) = self.store.flush_due_blocks(false) else { return };
        for transfer in flushed {
            let found = self
                .sessions
                .iter()
                .find(|(_, s)| s.blocks.receivers.contains(&transfer))
                .map(|(id, s)| (*id, s.conversation.clone()));
            if let Some((id, Some(conversation))) = found {
                self.blocks_progressed(id, &transfer, &conversation);
            }
        }
    }

    /// The next parts of every file this session sends by blocks, while the channel's bulk queue is shallow.
    pub(crate) fn pump_blocks(&mut self, id: u64) {
        let offers: Vec<String> = match self.sessions.get(&id) {
            Some(s) if s.channel.is_established() => s.blocks.senders.keys().cloned().collect(),
            _ => return,
        };
        for offer in offers {
            loop {
                let Some(session) = self.sessions.get_mut(&id) else { return };
                if session.channel.queued_frames().1 >= BULK_DEPTH {
                    return;
                }
                let Some(send) = session.blocks.senders.get_mut(&offer) else { break };
                if let Some(part) = send.serve.next_part() {
                    session.channel.send_frame(&part, monotonic_now());
                    continue;
                }
                let Some(block) = send.serve.next_block() else { break };
                let geometry = *send.serve.geometry();
                let read = self.store.read_outgoing_block(&send.record, &geometry, block);
                let send = self.sessions.get_mut(&id).and_then(|s| s.blocks.senders.get_mut(&offer)).expect("listed");
                let loaded = read.ok().map(|data| send.serve.load_block(block, data));
                if !matches!(loaded, Some(Ok(()))) {
                    self.sessions.get_mut(&id).expect("live").blocks.senders.remove(&offer);
                    let _ = self.store.snapshot_changed(&offer);
                    self.emit(json!({ "event": "transfer_failed", "transfer": offer, "why": "the snapshot changed" }));
                    break;
                }
            }
        }
    }
}
