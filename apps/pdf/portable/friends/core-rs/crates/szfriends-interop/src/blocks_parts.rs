//! The bench peer's download by blocks as parts arrive, as the helper's (blocks.rs): pieces and HAVE on the lane a
//! part came on, each PART checked and written, and the durability batches.

use super::*;

impl State {
    /// As the helper's: pieces arrived, reported at least every 256 KiB, after every part on Bluetooth (§ 3).
    pub(super) fn pieces_arrived(&mut self, id: u64, lane: u64, transfer: &str, bytes: usize) {
        if !self.sessions.get(&id).is_some_and(|s| s.channel.pieces()) {
            return;
        }
        let bluetooth = self.sessions.get(&lane).is_some_and(|s| s.channel.initiator_route() == RouteMethod::Bluetooth);
        let count = self.lanes.piece_bytes.entry(transfer.to_owned()).or_default();
        *count += bytes;
        if !bluetooth && *count < PIECE_HAVE_BYTES {
            let due = std::time::Instant::now() + std::time::Duration::from_millis(500);
            self.lanes.piece_due.entry(transfer.to_owned()).or_insert((due, id, lane));
            return;
        }
        self.send_pieces(id, lane, transfer);
    }

    /// The pieces not yet reported, in a HAVE on `lane` (the first session when it is gone).
    fn send_pieces(&mut self, id: u64, lane: u64, transfer: &str) {
        self.lanes.piece_bytes.insert(transfer.to_owned(), 0);
        self.lanes.piece_due.remove(transfer);
        let pieces = self.store.take_piece_have(transfer);
        if pieces.is_empty() {
            return;
        }
        let to = self.reply_lane(id, lane);
        if let Some(wire) = hex_bytes(transfer) {
            for frame in frames::have_with_pieces(&wire, &[], &[], &pieces) {
                self.send_frame(to, &frame);
            }
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
    pub(super) fn reply_lane(&self, id: u64, lane: u64) -> u64 {
        if self.sessions.get(&lane).is_some_and(|s| s.channel.is_established()) {
            lane
        } else {
            id
        }
    }

    pub(super) fn part(&mut self, id: u64, lane: u64, frame: &Frame, conversation: &str, transfer: &str) {
        // Compressed parts only in a codec that session negotiated, and only if they expand exactly (§ 9.4).
        let negotiated = |codec: u8| self.sessions.get(&lane).is_some_and(|s| s.channel.reads_codec(codec));
        if compress::codec_of(frame).is_some_and(|codec| !negotiated(codec)) {
            return self.unsolicited(id);
        }
        let Ok(data) = compress::part_data(frame) else { return self.unsolicited(id) };
        let receiving = self.sessions.get(&id).is_some_and(|s| s.blocks.receivers.contains(transfer));
        let Some(offset) = frame.integer(tag::OFFSET) else { return };
        let data = data.as_ref();
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
            Ok(BlockPart::Pending) => self.pieces_arrived(id, lane, transfer, data.len()),
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
    pub(super) fn blocks_progressed(&mut self, id: u64, transfer: &str, conversation: &str) {
        self.blocks_progressed_on(id, id, transfer, conversation);
    }

    pub(super) fn blocks_progressed_on(&mut self, id: u64, lane: u64, transfer: &str, conversation: &str) {
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
        // Pieces under 256 KiB go within half a second anyway, as the helper's.
        let now = std::time::Instant::now();
        let due: Vec<(String, u64, u64)> = self
            .lanes
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
                .iter()
                .find(|(_, s)| s.blocks.receivers.contains(&transfer))
                .map(|(id, s)| (*id, s.conversation.clone()));
            if let Some((id, Some(conversation))) = found {
                self.blocks_progressed(id, &transfer, &conversation);
            }
        }
    }
}
