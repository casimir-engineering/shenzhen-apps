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
use szfriends_core::transfer::{frames, BlockServe};
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
        || (frames < BULK_SMALL_FRAMES && channel.queued_bulk_bytes() < BULK_DEPTH * szfriends_core::wire::consts::PART_BYTES_MAX)
}
const WINDOW_BYTES: u64 = 64 << 20;

/// One of our files going by blocks on one session's group.
pub(crate) struct BlockSend {
    serve: BlockServe,
    record: TransferRecord,
    /// Each lane's parts not yet handed to its channel: (block, part, the block's last part).
    pub(crate) lanes: HashMap<u64, VecDeque<(u32, Frame, bool)>>,
    /// The receiver has the leaves (a HAVE or WANT came back): parts may go on lanes.
    lanes_ok: bool,
}

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
        group.scheduler.add_transfer(key, geometry);
        if first {
            let _ = group.scheduler.want(key, &[(0, geometry.blocks)], monotonic_now());
        }
        for frame in serve.hashes_frames() {
            self.send_frame(id, &frame);
        }
        let send = BlockSend { serve, record, lanes: HashMap::new(), lanes_ok: false };
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
        send.lanes_ok = true;
        let block_bytes = send.serve.geometry().block_bytes();
        if let Some(group) = self.lanes.groups.get_mut(&id) {
            let key = group.key(transfer);
            let _ = group.scheduler.want(key, &ranges, monotonic_now());
        }
        // The bench reads the resume point here, as it reads a CHUNK resume's offset.
        let offset = u64::from(ranges[0].0) * block_bytes;
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
            return self.unsolicited(id);
        }
        send.lanes_ok = true;
        if let Some(group) = self.lanes.groups.get_mut(&id) {
            let key = group.key(transfer);
            let _ = group.scheduler.have(key, &complete, monotonic_now());
        }
    }

    /// A PART that came on `lane` of `id`'s group: its HAVE goes back on that lane (ADR 0018 § 3, § 7).
    pub(crate) fn part_on(&mut self, id: u64, lane: u64, frame: &Frame) {
        let conversation = self.sessions.get(&id).and_then(|s| s.conversation.clone());
        let (Some(transfer), Some(conversation)) = (frame.get(tag::ID).map(hex::encode), conversation) else {
            return self.close_for_protocol(lane);
        };
        self.part(id, lane, frame, &conversation, &transfer);
    }

    /// Where a HAVE for `lane`'s parts goes: that lane while it is live, else the first session.
    fn reply_lane(&self, id: u64, lane: u64) -> u64 {
        if self.sessions.get(&lane).is_some_and(|s| s.channel.is_established()) {
            lane
        } else {
            id
        }
    }

    fn part(&mut self, id: u64, lane: u64, frame: &Frame, conversation: &str, transfer: &str) {
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
            Ok(BlockPart::Pending) => {}
            Ok(BlockPart::Late) => {
                // The first late part of a block on each lane gets a HAVE for that block (§ 3), so a block whose HAVE
                // went with a silent lane is still acknowledged.
                let Some(header) = self.store.offered_tree(transfer) else { return };
                let block = header.geometry.block_of(offset);
                if self.lanes.late_answered.insert((lane, transfer.to_owned(), block)) {
                    let to = self.reply_lane(id, lane);
                    if let Some(wire) = hex_bytes(transfer) {
                        for frame in frames::have(&wire, &[(block, 1)], &[]) {
                            self.send_frame(to, &frame);
                        }
                    }
                }
            }
            Ok(BlockPart::Written(_)) => self.blocks_progressed_on(id, lane, transfer, conversation),
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
        self.blocks_progressed_on(id, id, transfer, conversation);
    }

    fn blocks_progressed_on(&mut self, id: u64, lane: u64, transfer: &str, conversation: &str) {
        let (complete, durable) = self.store.take_block_have(transfer);
        let Some(wire) = hex_bytes(transfer) else { return };
        let to = self.reply_lane(id, lane);
        for frame in frames::have(&wire, &complete, &durable) {
            self.send_frame(to, &frame);
        }
        if !self.store.blocks_all_durable(transfer) {
            return;
        }
        if let Some(session) = self.sessions.get_mut(&id) {
            session.blocks.receivers.remove(transfer);
        }
        match self.store.finish_block_transfer(transfer, conversation) {
            Ok(path) if path.as_os_str().is_empty() => {}
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

    /// The scheduler gave `block` of `transfer` to `lane`: read, checked against its leaf, cut into the lane's parts.
    fn assign_block(&mut self, head: u64, lane: u64, transfer: u64, block: u32) {
        let Some(offer) = self.lanes.groups.get(&head).and_then(|g| g.name(transfer)) else { return };
        let route = self.lane_route(head, lane);
        let Some(send) = self.sessions.get_mut(&head).and_then(|s| s.blocks.senders.get_mut(&offer)) else { return };
        let geometry = *send.serve.geometry();
        let read = self.store.read_outgoing_block(&send.record, &geometry, block);
        let loaded = read.ok().map(|data| send.serve.load_block(block, data));
        if !matches!(loaded, Some(Ok(()))) {
            self.sessions.get_mut(&head).expect("live").blocks.senders.remove(&offer);
            let _ = self.store.snapshot_changed(&offer);
            self.emit(json!({ "event": "transfer_failed", "transfer": offer, "why": "the snapshot changed" }));
            return;
        }
        send.serve.set_part_bytes(part_bytes(route));
        let queue = send.lanes.entry(lane).or_default();
        while let Some(part) = send.serve.next_part() {
            queue.push_back((block, part, false));
        }
        if let Some(last) = queue.back_mut() {
            last.2 = true;
        }
    }
}
