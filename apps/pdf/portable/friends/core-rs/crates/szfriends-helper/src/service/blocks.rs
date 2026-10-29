//! Fast transfers in the Rust helper (ADR 0018, PROTOCOL.md § Fast transfers), on a session's group of lanes
//! (`lanes.rs`; the first session alone when there are none), blocks given to lanes by WP2's scheduler: on a session
//! that negotiated them, our OFFER announces the tree, the friend's helper takes the file by blocks (OFFER_REPLY with Blocks), we send the leaves (HASHES) and then the blocks it wants as PARTs, and it
//! answers with HAVE as blocks check and become durable, and with ACK once the whole file checked and was saved. On
//! every new session it asks for exactly what is still missing (WANT). With anyone else, nothing here runs and the
//! CHUNK flow of `transfers.rs` moves the file as before.

use std::collections::{HashMap, VecDeque};

use szfriends_core::session::chunk_bytes_for_route;
use szfriends_core::session::lanes::LaneRequest;
use szfriends_core::store::{BlockPart, StoreError, TransferRecord};
use szfriends_core::transfer::scheduler::Action;
use szfriends_core::transfer::{frames, BlockServe, ServeError};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType, RouteMethod};

use super::{hex, unhex, State};

/// A check shorter than this shows nothing: the row goes from the last block straight to saved.
const FINISHING_AFTER: std::time::Duration = std::time::Duration::from_secs(1);
/// Parts queued in the channel ahead of the link, as for CHUNKs: a message still overtakes them.
const BULK_DEPTH: usize = 4;
/// The serve's own window; the scheduler sizes what each lane holds (2 × rate × round trip), within § 3's limits.
const WINDOW_BYTES: u64 = 64 << 20;

/// One of our files going by blocks on one session's group.
#[derive(Debug)]
pub struct BlockSend {
    pub serve: BlockServe,
    pub record: TransferRecord,
    /// Each lane's parts not yet handed to its channel: (block, part, the block's last part).
    pub lanes: HashMap<u64, VecDeque<(u32, Frame, bool)>>,
    /// The friend's helper has the leaves (a HAVE or WANT came back): parts may go on lanes, which could overtake
    /// HASHES on the first session.
    pub lanes_ok: bool,
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
        let wire = unhex(offer)?;
        let geometry = tree.header.geometry;
        let mut serve = BlockServe::new(&wire, geometry, tree.leaves, chunk_bytes_for_route(route), WINDOW_BYTES);
        if first {
            serve.want_all();
        }
        let now = szfriends_core::session::monotonic_now();
        let schedule = self.schedule(id, route);
        let key = schedule.key(offer);
        schedule.scheduler.add_transfer(key, geometry);
        if first {
            let _ = schedule.scheduler.want(key, &[(0, geometry.blocks)], now);
        }
        for frame in serve.hashes_frames() {
            self.send_on(id, &frame);
        }
        let session = self.sessions.map.get_mut(&id)?;
        session.expecting.insert(hex(&wire), format!("done:{offer}"));
        let send = BlockSend { serve, record, lanes: HashMap::new(), lanes_ok: false };
        session.block_senders.insert(offer.to_owned(), send);
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
            FrameType::Part => self.part(id, id, frame, conversation, &transfer),
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
            return self.unsolicited(id);
        }
        send.lanes_ok = true;
        // Copies of a block wanted again are cancelled by the scheduler (it failed its check, or a restart lost it).
        let now = szfriends_core::session::monotonic_now();
        if let Some(schedule) = self.sessions.groups.schedules.get_mut(&id) {
            let key = schedule.key(transfer);
            if schedule.scheduler.want(key, &ranges, now).is_err() {
                self.unsolicited(id);
            }
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
            return self.unsolicited(id);
        }
        send.lanes_ok = true;
        let now = szfriends_core::session::monotonic_now();
        if let Some(schedule) = self.sessions.groups.schedules.get_mut(&id) {
            let key = schedule.key(transfer);
            let _ = schedule.scheduler.have(key, &complete, now);
        }
        self.changed();
    }

    /// A PART that came on `lane` of `id`'s group (`id` itself without lanes): its HAVE goes back on that lane, so it
    /// follows the parts and the sender measures that lane's round trip (§ 3, § 7).
    pub(crate) fn part_on(&mut self, id: u64, lane: u64, frame: &Frame) {
        let (Some(transfer), Some(conversation)) = (Self::block_wire(frame), self.conversation_of(id)) else { return };
        self.part(id, lane, frame, &conversation, &transfer);
    }

    fn part(&mut self, id: u64, lane: u64, frame: &Frame, conversation: &str, transfer: &str) {
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
            Ok(BlockPart::Pending) => {}
            Ok(BlockPart::Late) => self.late_part(id, lane, transfer, offset),
            Ok(BlockPart::Written(_)) => self.blocks_progressed_on(id, lane, transfer, conversation),
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
        self.blocks_progressed_on(id, id, transfer, conversation);
    }

    /// The same, with the HAVE on `lane` of `id`'s group.
    fn blocks_progressed_on(&mut self, id: u64, lane: u64, transfer: &str, conversation: &str) {
        let (complete, durable) = self.store.take_block_have(transfer);
        let Some(wire) = unhex(transfer) else { return };
        let to = if self.sessions.map.get(&lane).is_some_and(|s| s.channel.is_established()) { lane } else { id };
        for frame in frames::have(&wire, &complete, &durable) {
            self.send_on(to, &frame);
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
        if self.finishing.contains_key(transfer) {
            return;
        }
        // The check before saving runs on a thread of its own; past a second the row says "Finishing…".
        let check = match self.store.begin_block_check(transfer, conversation) {
            Ok(check) => check,
            Err(error) => return crate::log!("a file received by blocks could not be checked: {error}"),
        };
        self.finishing.insert(transfer.to_owned(), std::time::Instant::now());
        let input = self.input.clone();
        let spawned = std::thread::Builder::new().name("szfriends-check".into()).spawn(move || {
            let checked = check.run();
            let _ =
                input.send(super::Input::Deferred(Box::new(move |state: &mut State| state.block_check_done(checked))));
        });
        if spawned.is_err() {
            self.finishing.remove(transfer);
        }
        self.changed();
    }

    /// The check before saving finished: saved and acknowledged, or deleted and failed.
    fn block_check_done(&mut self, checked: szfriends_core::store::CheckedFile) {
        let (transfer, conversation) = (checked.transfer_id().to_owned(), checked.conversation_id().to_owned());
        self.finishing.remove(&transfer);
        match self.store.complete_block_check(checked) {
            Ok(_) => {
                // Acknowledged on the friend's live session; without one, their next WANT finds it saved.
                if let (Some(id), Some(wire)) = (self.sessions.live_for(&conversation), unhex(&transfer)) {
                    self.send_ack(id, &wire);
                    self.service(id);
                }
            }
            Err(error) => crate::log!("a file received by blocks did not check: {error}"),
        }
        self.changed();
    }

    /// Whether a transfer's row says "Finishing…": its check has run for more than a second.
    pub(crate) fn shows_finishing(&self, transfer: &str) -> bool {
        self.finishing.get(transfer).is_some_and(|since| since.elapsed() >= FINISHING_AFTER)
    }

    /// When a running check first needs the row to say "Finishing…".
    pub(crate) fn finishing_due(&self) -> Option<std::time::Instant> {
        self.finishing.values().map(|since| *since + FINISHING_AFTER).filter(|at| *at > std::time::Instant::now()).min()
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

    /// The first late part of a block on each lane is answered with a HAVE naming that block on that lane (ADR 0018
    /// § 3): when the lane that completed it went silent with its HAVE, the copy sent again on another lane would
    /// otherwise be dropped unacknowledged, and the transfer would wait for the group to end.
    fn late_part(&mut self, id: u64, lane: u64, transfer: &str, offset: u64) {
        let Some(header) = self.store.offered_tree(transfer) else { return };
        let block = header.geometry.block_of(offset);
        if !self.sessions.groups.late_answered.insert((lane, transfer.to_owned(), block)) {
            return;
        }
        let Some(wire) = unhex(transfer) else { return };
        let to = if self.sessions.map.get(&lane).is_some_and(|s| s.channel.is_established()) { lane } else { id };
        for frame in frames::have(&wire, &[(block, 1)], &[]) {
            self.send_on(to, &frame);
        }
    }

    /// A lane closed: its parts not yet handed out are dropped (the scheduler hears the lane go down from the group
    /// and gives its blocks to the others).
    pub(crate) fn lane_lost(&mut self, head: u64, lane: u64) {
        if let Some(session) = self.sessions.map.get_mut(&head) {
            for send in session.block_senders.values_mut() {
                send.lanes.remove(&lane);
            }
        }
        self.sessions.groups.late_answered.retain(|(l, _, _)| *l != lane);
    }

    /// Every file this session's group sends by blocks: the scheduler (WP2) hears the lanes, the transfers and the
    /// time, and says which lane carries which block; each block is read through its leaf check and cut into its
    /// lane's parts (16 KiB on Bluetooth), which go out while the lane's queue is shallow. Lanes it asks for are dialed
    /// (`lanes.rs`), lanes it gives up on closed.
    pub(crate) fn pump_blocks(&mut self, head: u64) {
        let route = match self.sessions.map.get(&head) {
            Some(s) if s.channel.is_established() && !s.block_senders.is_empty() => s.meta.race_route(&s.channel),
            // Idle: the scheduler stays with its group (and its lanes' measured rates) until the group ends.
            _ => return,
        };
        let now = szfriends_core::session::monotonic_now();
        let offers: Vec<String> = self.sessions.map[&head].block_senders.keys().cloned().collect();
        let schedule = self.schedule(head, route);
        schedule.retain(&offers);
        schedule.scheduler.tick(now);
        let actions = schedule.scheduler.take_actions();
        for action in actions {
            match action {
                Action::Send { lane, transfer, block } => self.assign_block(head, lane, transfer, block),
                Action::Cancel { lane, transfer, block } => {
                    let Some(offer) = self.sessions.groups.schedules.get(&head).and_then(|s| s.name(transfer)) else {
                        continue;
                    };
                    let send = self.sessions.map.get_mut(&head).and_then(|s| s.block_senders.get_mut(&offer));
                    if let Some(queue) = send.and_then(|send| send.lanes.get_mut(&lane)) {
                        queue.retain(|(b, _, _)| *b != block);
                    }
                }
                Action::Lane(LaneRequest::Open { route }) => self.open_lane(head, route),
                Action::Lane(LaneRequest::Close { lane }) => {
                    if lane != head {
                        self.close(lane, CloseReason::Normal);
                    }
                }
            }
        }
        // Parts out, each lane while its queue is shallow; a block's last part tells the scheduler it was sent.
        let lanes: Vec<u64> = self.sessions.groups.live_lanes(head, route).into_iter().map(|(id, _)| id).collect();
        for offer in &offers {
            let key = self.sessions.groups.schedules.get_mut(&head).map(|s| s.key(offer));
            for &lane in &lanes {
                loop {
                    let room = self
                        .sessions
                        .map
                        .get(&lane)
                        .is_some_and(|s| s.channel.is_established() && s.channel.queued_frames().1 < BULK_DEPTH);
                    if !room {
                        break;
                    }
                    let Some(send) = self.sessions.map.get_mut(&head).and_then(|s| s.block_senders.get_mut(offer))
                    else {
                        break;
                    };
                    if lane != head && !send.lanes_ok {
                        break;
                    }
                    let Some((block, part, last)) = send.lanes.get_mut(&lane).and_then(VecDeque::pop_front) else {
                        break;
                    };
                    if let Some(s) = self.sessions.map.get_mut(&lane) {
                        s.channel.send_frame(&part, now);
                    }
                    if let (true, Some(key)) = (last, key) {
                        if let Some(schedule) = self.sessions.groups.schedules.get_mut(&head) {
                            schedule.scheduler.sent(lane, key, block, now);
                        }
                    }
                }
            }
        }
        for &lane in &lanes {
            self.flush_writes(lane);
        }
    }

    /// The scheduler gave `block` of `transfer` to `lane`: read it, check it against its leaf, cut it into the lane's
    /// parts. A block that fails its leaf means the snapshot changed: the transfer fails, as a missing source does.
    fn assign_block(&mut self, head: u64, lane: u64, transfer: u64, block: u32) {
        let Some(offer) = self.sessions.groups.schedules.get(&head).and_then(|s| s.name(transfer)) else { return };
        let route = self.sessions.groups.route_of(head, lane).unwrap_or(RouteMethod::Lan);
        let Some(send) = self.sessions.map.get_mut(&head).and_then(|s| s.block_senders.get_mut(&offer)) else { return };
        let geometry = *send.serve.geometry();
        let loaded = match self.store.read_outgoing_block(&send.record, &geometry, block) {
            Ok(data) => send.serve.load_block(block, data),
            Err(_) => Err(ServeError::Changed),
        };
        if loaded.is_err() {
            if let Some(s) = self.sessions.map.get_mut(&head) {
                s.block_senders.remove(&offer);
            }
            let _ = self.store.snapshot_changed(&offer);
            self.changed();
            return;
        }
        send.serve.set_part_bytes(super::lanes::part_bytes(route));
        let queue = send.lanes.entry(lane).or_default();
        while let Some(part) = send.serve.next_part() {
            queue.push_back((block, part, false));
        }
        if let Some(last) = queue.back_mut() {
            last.2 = true;
        }
    }
}
