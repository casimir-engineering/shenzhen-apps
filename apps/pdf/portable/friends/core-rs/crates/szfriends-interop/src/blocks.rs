//! Fast transfers in the Rust peer, as the Rust helper runs them (`szfriends-helper/src/service/blocks.rs`, ADR 0018):
//! on a session that negotiated them, an OFFER announces the tree, the receiver takes the file by blocks, the sender
//! sends the leaves and then the wanted blocks as PARTs, the receiver answers with HAVE and, once the whole file checked
//! and was saved, ACK; on every new session it asks for exactly what is missing (WANT). With a peer that did not
//! negotiate them, the CHUNK flow of `flows.rs` runs as before. The store does the work; this is the helper's wiring,
//! kept in step with it so the transfer bench and the interop matrix measure what the helper does.

use std::collections::{HashMap, VecDeque};

use serde_json::json;
use szfriends_core::session::lanes::LaneRequest;
use szfriends_core::session::{chunk_bytes_for_route, monotonic_now};
use szfriends_core::store::{BlockPart, StoreError, TransferRecord, TransferState};
use szfriends_core::transfer::scheduler::Action;
use szfriends_core::transfer::slices::SliceSend;
use szfriends_core::transfer::{compress, frames, BlockServe};
use szfriends_core::wire::{tag, Frame, FrameType, RouteMethod};

use crate::hex_bytes;
use crate::peer::State;

/// As the helper: parts queued in the channel ahead of the link; the serve's own window (the scheduler sizes each
/// lane's share within § 3's limits).
const BULK_DEPTH: usize = 4;
/// Many small parts (small files) queue by bytes, up to this many frames: a burst fills the other side's reads.
const BULK_SMALL_FRAMES: usize = 64;

/// Room for another part: fewer than four frames queued, or more but all of them small.
fn bulk_has_room(channel: &szfriends_core::session::SecureChannel) -> bool {
    let frames = channel.queued_frames().1;
    frames < BULK_DEPTH
        || (frames < BULK_SMALL_FRAMES
            && channel.queued_bulk_bytes() < BULK_DEPTH * szfriends_core::wire::consts::PART_BYTES_MAX)
}
const WINDOW_BYTES: u64 = 64 << 20;

/// One of our files going by blocks on one session's group.
pub(crate) struct BlockSend {
    serve: BlockServe,
    record: TransferRecord,
    /// Each lane's parts not yet handed to its channel: (block, part, the block's last part).
    pub(crate) lanes: HashMap<u64, VecDeque<(u32, Frame, bool)>>,
    /// The receiver has the leaves (a HAVE came back; a WANT comes before them): parts may go on lanes.
    lanes_ok: bool,
    /// Pieces acknowledged and checked blocks, for slices (ADR 0018 § 3).
    slices: SliceSend,
}

/// As the helper: pieces reported at least every 256 KiB of parts, after every part on Bluetooth.
const PIECE_HAVE_BYTES: usize = 256 << 10;

/// Parts of a block cut for a lane on this route (16 KiB on Bluetooth, ADR 0018 § 9.8), as the helper does.
fn part_bytes(route: RouteMethod) -> usize {
    if route == RouteMethod::Bluetooth {
        16 * 1024
    } else {
        chunk_bytes_for_route(route)
    }
}

/// What a session does by blocks: files it sends, and files it receives.
#[derive(Default)]
pub(crate) struct Blocks {
    pub(crate) senders: HashMap<String, BlockSend>,
    pub(crate) receivers: std::collections::HashSet<String>,
}

impl Blocks {
    /// Whether a file moves by blocks on this session, and whether the peer owes us something (a HAVE for blocks
    /// sent, or the rest of a file being received): the liveness the channel keeps (ADR 0018 § 7).
    pub(crate) fn liveness(&self, store: &szfriends_core::store::Store) -> (bool, bool) {
        let active = !self.senders.is_empty() || !self.receivers.is_empty();
        let owed = self.senders.values().any(|s| !s.serve.all_acknowledged())
            || self.receivers.iter().any(|t| !store.blocks_all_durable(t));
        (active, owed)
    }
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
        // Filled locally from the same file held here (§ 9.5): the CHUNK reply at its full size, and only DONE follows.
        if self.store.whole_file_held(transfer) {
            self.store.drop_blocks(transfer);
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
        if record.verified_bytes == record.size && !self.store.has_block_map(&record.transfer_id) {
            self.store.drop_blocks(&record.transfer_id);
            return false; // every byte is here already: PROGRESS at the full size, and DONE follows
        }
        if !self.store.begin_blocks(&record.transfer_id, &record.conversation_id).unwrap_or(false) {
            return false;
        }
        let Some(wire) = hex_bytes(&record.transfer_id) else { return false };
        let with_pieces = self.sessions.get(&id).is_some_and(|s| s.channel.pieces());
        let (missing, pieces) = if with_pieces {
            (self.store.block_missing(&record.transfer_id), self.store.block_missing_pieces(&record.transfer_id))
        } else {
            (self.store.block_missing_whole(&record.transfer_id), Vec::new())
        };
        if let Some(session) = self.sessions.get_mut(&id) {
            session.blocks.receivers.insert(record.transfer_id.clone());
        }
        for frame in frames::want_with_pieces(&wire, &missing, &pieces) {
            self.send_frame(id, &frame);
        }
        if missing.is_empty() && pieces.is_empty() {
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
        let wire = hex_bytes(offer)?;
        let geometry = tree.header.geometry;
        let mut serve = BlockServe::new(&wire, geometry, tree.leaves, chunk_bytes_for_route(route), WINDOW_BYTES);
        if first {
            serve.want_all();
            self.emit(json!({ "event": "sending", "session": id, "transfer": offer, "offset": 0, "blocks": true }));
        }
        let group = self.lanes.groups.get_mut(&id)?;
        group.sync();
        let key = group.key(offer);
        let pieces = self.sessions.get(&id).is_some_and(|s| s.channel.pieces());
        let slice_send = SliceSend::new(&geometry, pieces);
        let slices = slice_send.units(&geometry);
        group.scheduler.add_transfer(key, slices);
        if first {
            let _ = group.scheduler.want(key, &[(0, slices.blocks)], monotonic_now());
        }
        for frame in serve.hashes_frames() {
            self.send_frame(id, &frame);
        }
        let send = BlockSend { serve, record, lanes: HashMap::new(), lanes_ok: false, slices: slice_send };
        self.sessions.get_mut(&id)?.blocks.senders.insert(offer.to_owned(), send);
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
            FrameType::Part => self.part(id, id, frame, &conversation, &transfer),
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
        let (Some(ranges), Some(pieces)) =
            (frames::ranges_of(frame, tag::RANGES), frames::ranges_of(frame, tag::PIECES))
        else {
            return self.unsolicited(id);
        };
        if ranges.is_empty() && pieces.is_empty() {
            return self.unsolicited(id);
        }
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
        // A WANT proves nothing about the leaves: the receiver sends one as it accepts, before HASHES arrive, so
        // lanes wait for a HAVE (a PART on a lane would otherwise overtake HASHES and end the session).
        let geometry = *send.serve.geometry();
        send.slices.want(&geometry, &ranges, &pieces);
        let mut slices = send.slices.units_of_blocks(&geometry, &ranges);
        slices.extend(send.slices.units_of_pieces(&geometry, &pieces));
        slices.sort_unstable();
        if let Some(group) = self.lanes.groups.get_mut(&id) {
            let key = group.key(transfer);
            let _ = group.scheduler.want(key, &slices, monotonic_now());
        }
        // The bench reads the resume point here, as it reads a CHUNK resume's offset: the first byte wanted.
        let first_block = ranges.first().map(|r| u64::from(r.0) * geometry.block_bytes());
        let first_piece = pieces.first().map(|p| u64::from(p.0) << szfriends_core::wire::consts::PIECE_SHIFT);
        let offset = first_block.into_iter().chain(first_piece).min().unwrap_or(0);
        self.emit(json!({ "event": "sending", "session": id, "transfer": transfer, "offset": offset, "blocks": true }));
    }

    fn have(&mut self, id: u64, frame: &Frame, transfer: &str) {
        let (Some(complete), Some(pieces)) =
            (frames::ranges_of(frame, tag::RANGES), frames::ranges_of(frame, tag::PIECES))
        else {
            return self.unsolicited(id);
        };
        let Some(send) = self.sessions.get_mut(&id).and_then(|s| s.blocks.senders.get_mut(transfer)) else {
            let ours = self.store.transfer(transfer).ok().flatten().is_some_and(|r| r.outgoing);
            if !ours {
                self.unsolicited(id);
            }
            return;
        };
        if send.serve.have(&complete).is_err() {
            return self.unsolicited(id);
        }
        send.lanes_ok = true;
        let geometry = *send.serve.geometry();
        send.slices.have_blocks(&geometry, &complete);
        let mut done = send.slices.units_of_blocks(&geometry, &complete);
        done.extend(send.slices.have_pieces(&geometry, &pieces));
        done.sort_unstable();
        if let Some(group) = self.lanes.groups.get_mut(&id) {
            let key = group.key(transfer);
            let _ = group.scheduler.have(key, &done, monotonic_now());
        }
    }

    /// Every file this session's group sends by blocks, as the helper does: the scheduler (WP2) gives each block to a
    /// lane; the block is read through its leaf check and cut into the lane's parts, which go out while the lane's
    /// queue is shallow, and a block's last part tells the scheduler it was sent.
    pub(crate) fn pump_blocks(&mut self, head: u64) {
        let offers: Vec<String> = match self.sessions.get(&head) {
            Some(s) if s.channel.is_established() && !s.blocks.senders.is_empty() => {
                s.blocks.senders.keys().cloned().collect()
            }
            _ => return,
        };
        let now = monotonic_now();
        let Some(group) = self.lanes.groups.get_mut(&head) else { return };
        group.sync();
        group.retain(&offers);
        group.scheduler.tick(now);
        let actions = group.scheduler.take_actions();
        let lanes: Vec<u64> = group.lanes.live().map(|(id, _, _)| id).collect();
        for action in actions {
            match action {
                Action::Send { lane, transfer, block } => self.assign_block(head, lane, transfer, block),
                Action::Cancel { lane, transfer, block } => {
                    let name = self.lanes.groups.get(&head).and_then(|g| g.name(transfer));
                    let send = name.and_then(|n| self.sessions.get_mut(&head)?.blocks.senders.get_mut(&n));
                    if let Some(queue) = send.and_then(|s| s.lanes.get_mut(&lane)) {
                        queue.retain(|(b, _, _)| *b != block);
                    }
                }
                // The bench dials every lane itself; one it no longer wants closes.
                Action::Lane(LaneRequest::Open { .. }) => {}
                Action::Lane(LaneRequest::Close { lane }) => {
                    if lane != head {
                        if let Some(s) = self.sessions.get_mut(&lane) {
                            s.channel.close_with_reason(szfriends_core::wire::CloseReason::Normal, now);
                        }
                    }
                }
            }
        }
        for offer in &offers {
            let key = self.lanes.groups.get_mut(&head).map(|g| g.key(offer));
            for &lane in &lanes {
                loop {
                    let room = self
                        .sessions
                        .get(&lane)
                        .is_some_and(|s| s.channel.is_established() && bulk_has_room(&s.channel));
                    if !room {
                        break;
                    }
                    let Some(send) = self.sessions.get_mut(&head).and_then(|s| s.blocks.senders.get_mut(offer)) else {
                        break;
                    };
                    if lane != head && !send.lanes_ok {
                        break;
                    }
                    let Some((block, part, last)) = send.lanes.get_mut(&lane).and_then(VecDeque::pop_front) else {
                        break;
                    };
                    if let Some(s) = self.sessions.get_mut(&lane) {
                        s.channel.send_frame(&part, now);
                    }
                    if let (true, Some(key), Some(group)) = (last, key, self.lanes.groups.get_mut(&head)) {
                        group.scheduler.sent(lane, key, block, now);
                    }
                }
            }
        }
    }

    /// The scheduler gave `slice` of `transfer` to `lane`: its block read and checked against its leaf once, its pieces
    /// not yet acknowledged cut into the lane's parts.
    fn assign_block(&mut self, head: u64, lane: u64, transfer: u64, slice: u32) {
        let Some(offer) = self.lanes.groups.get(&head).and_then(|g| g.name(transfer)) else { return };
        let route = self.lane_route(head, lane);
        // Compressed on Bluetooth (and relay, zstd only) lanes in the codec both read, when the block's sample says
        // it pays (§ 9.4).
        let codec = self
            .sessions
            .get(&lane)
            .and_then(|s| s.channel.part_codec())
            .filter(|&c| compress::route_compresses(route, c));
        let Some(send) = self.sessions.get_mut(&head).and_then(|s| s.blocks.senders.get_mut(&offer)) else { return };
        let geometry = *send.serve.geometry();
        let block = send.slices.block_of_unit(&geometry, slice);
        if send.slices.cached(block).is_none() {
            let read = self.store.read_outgoing_block(&send.record, &geometry, block).ok();
            let Some(data) = read.filter(|data| send.serve.check_block(block, data).is_ok()) else {
                self.sessions.get_mut(&head).expect("live").blocks.senders.remove(&offer);
                let _ = self.store.snapshot_changed(&offer);
                self.emit(json!({ "event": "transfer_failed", "transfer": offer, "why": "the snapshot changed" }));
                return;
            };
            send.slices.keep(block, data);
        }
        let wire = hex_bytes(&offer).unwrap_or_default();
        let parts = send.slices.parts(&wire, &geometry, slice, part_bytes(route));
        let codec = codec.filter(|&c| send.slices.cached(block).is_some_and(|data| compress::worth(data, c)));
        let queue = send.lanes.entry(lane).or_default();
        let parts = parts.into_iter().map(|part| match codec {
            Some(c) => compress::compress_part(part, route, c),
            None => part,
        });
        queue.extend(parts.map(|part| (slice, part, false)));
        if let Some(last) = queue.back_mut() {
            last.2 = true;
        }
    }
}

#[path = "blocks_parts.rs"]
mod parts;
