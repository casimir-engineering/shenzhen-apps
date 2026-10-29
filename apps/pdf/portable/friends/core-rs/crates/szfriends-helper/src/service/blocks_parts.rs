//! A download by blocks as its parts arrive (blocks.rs): each PART checked and written, HAVE and pieces sent back on
//! the lane it came on, and the check that runs before the file is saved ("Finishing…" meanwhile).

use super::*;

impl State {
    /// A PART that came on `lane` of `id`'s group (`id` itself without lanes): its HAVE goes back on that lane, so it
    /// follows the parts and the sender measures that lane's round trip (§ 3, § 7).
    pub(crate) fn part_on(&mut self, id: u64, lane: u64, frame: &Frame) {
        if self.again_block_frame(id, frame) {
            return;
        }
        let (Some(transfer), Some(conversation)) = (Self::block_wire(frame), self.conversation_of(id)) else { return };
        self.part(id, lane, frame, &conversation, &transfer);
    }

    pub(super) fn part(&mut self, id: u64, lane: u64, frame: &Frame, conversation: &str, transfer: &str) {
        // Compressed parts only in a codec that session negotiated, and only if they expand exactly (§ 9.4).
        let negotiated = |codec: u8| self.sessions.map.get(&lane).is_some_and(|s| s.channel.reads_codec(codec));
        if compress::codec_of(frame).is_some_and(|codec| !negotiated(codec)) {
            return self.unsolicited(id);
        }
        let Ok(data) = compress::part_data(frame) else { return self.unsolicited(id) };
        let receiving = self.sessions.map.get(&id).is_some_and(|s| s.block_receivers.contains(transfer));
        let Some(offset) = frame.integer(tag::OFFSET) else { return };
        let data = data.as_ref();
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
            Ok(BlockPart::Pending) => self.pieces_arrived(id, lane, transfer, data.len()),
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
    pub(super) fn blocks_progressed_on(&mut self, id: u64, lane: u64, transfer: &str, conversation: &str) {
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
        // A small file's check takes no time: here, in the store batch, which publishes and acknowledges it.
        if self.store.block_check_is_quick(transfer) {
            let checked = self.store.begin_block_check(transfer, conversation).map(|check| check.run());
            match checked.and_then(|checked| self.store.complete_block_check(checked)) {
                Ok(path) if !path.as_os_str().is_empty() => self.send_ack(id, &wire),
                Ok(_) => {}
                Err(error) => crate::log!("a file received by blocks did not check: {error}"),
            }
            return self.changed();
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
            let _ = input.send(crate::service::Input::Deferred(Box::new(move |state: &mut State| {
                state.block_check_done(checked)
            })));
        });
        if spawned.is_err() {
            self.finishing.remove(transfer);
        }
        self.changed();
    }

    /// The check before saving finished: saved and acknowledged, or deleted and failed.
    pub(super) fn block_check_done(&mut self, checked: szfriends_core::store::CheckedFile) {
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
        let now = std::time::Instant::now();
        let due: Vec<(String, u64, u64)> = self
            .sessions
            .groups
            .piece_due
            .iter()
            .filter(|(_, (at, _, _))| *at <= now)
            .map(|(transfer, (_, id, lane))| (transfer.clone(), *id, *lane))
            .collect();
        for (transfer, id, lane) in due {
            let id = self.head_of(id);
            self.send_pieces(id, lane, &transfer);
        }
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

    /// Pieces arrived in blocks not yet complete: a HAVE naming them at least every 256 KiB of parts, after every
    /// part on Bluetooth (§ 3), so a lost lane costs the sender only what was in flight on it.
    pub(super) fn pieces_arrived(&mut self, id: u64, lane: u64, transfer: &str, bytes: usize) {
        if !self.sessions.map.get(&id).is_some_and(|s| s.channel.pieces()) {
            return;
        }
        let bluetooth = self
            .sessions
            .map
            .get(&lane)
            .is_some_and(|s| s.channel.initiator_route() == szfriends_core::wire::RouteMethod::Bluetooth);
        let count = self.sessions.groups.piece_bytes.entry(transfer.to_owned()).or_default();
        *count += bytes;
        if !bluetooth && *count < PIECE_HAVE_BYTES {
            // Within half a second anyway, as the durability batch's flush (§ 3: "at least every 256 KiB").
            let due = std::time::Instant::now() + PIECE_HAVE_DELAY;
            self.sessions.groups.piece_due.entry(transfer.to_owned()).or_insert((due, id, lane));
            return;
        }
        self.send_pieces(id, lane, transfer);
    }

    /// The pieces not yet reported, in a HAVE on `lane` (the group's first session when it is gone).
    fn send_pieces(&mut self, id: u64, lane: u64, transfer: &str) {
        self.sessions.groups.piece_bytes.insert(transfer.to_owned(), 0);
        self.sessions.groups.piece_due.remove(transfer);
        let pieces = self.store.take_piece_have(transfer);
        if pieces.is_empty() {
            return;
        }
        let Some(wire) = unhex(transfer) else { return };
        let to = if self.sessions.map.get(&lane).is_some_and(|s| s.channel.is_established()) { lane } else { id };
        for frame in frames::have_with_pieces(&wire, &[], &[], &pieces) {
            self.send_on(to, &frame);
        }
    }

    /// The first late part of a block on each lane is answered with a HAVE naming that block on that lane (ADR 0018
    /// § 3): when the lane that completed it went silent with its HAVE, the copy sent again on another lane would
    /// otherwise be dropped unacknowledged, and the transfer would wait for the group to end.
    pub(super) fn late_part(&mut self, id: u64, lane: u64, transfer: &str, offset: u64) {
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
}
