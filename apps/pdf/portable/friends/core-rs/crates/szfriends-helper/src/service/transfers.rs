//! Files between friends (`SZFriendsNearbyService+Transfers.m`, ADR 0001 § Files): our OFFER through the outbox,
//! acknowledged, then answered; their OFFER recorded and acknowledged, then answered by this person (or at once when
//! they accept this friend's files automatically), the answer going through the outbox too; CHUNKs inside the window,
//! PROGRESS once durable, DONE checked against the whole-file digest and acknowledged; and resume: on every new
//! session the recipient sends PROGRESS for each unfinished inbound transfer and the sender continues from it.

use std::time::{Duration, Instant};

use serde_json::json;
use szfriends_core::session::{monotonic_now, ChunkReceiver, ChunkSender};
use szfriends_core::store::disk::OutgoingFile;
use szfriends_core::store::{new_identifier, unix_now, OutboxEntry, OutboxKind, OutboxState, TransferRecord};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType};

use super::{hex, unhex, State};

/// Chunks queued in the channel ahead of the link: enough to keep it busy, few enough that a message overtakes them.
const BULK_DEPTH: usize = 4;
/// When chunks pause, received bytes are made durable anyway this long after the first unreported one.
const FLUSH_DELAY: Duration = Duration::from_millis(500);

pub struct Outgoing {
    pub sender: ChunkSender,
    pub record: TransferRecord,
    pub done_sent: bool,
    /// The snapshot, opened at the first chunk and read at offsets into one buffer.
    file: Option<OutgoingFile>,
    buffer: Vec<u8>,
}

fn id_frame(frame_type: FrameType, id: &[u8]) -> Frame {
    Frame::new(frame_type).with(tag::ID, id.to_vec())
}

impl State {
    /// Queues an answer for the friend (accepting or declining their offer, or cancelling a transfer).
    pub fn queue_answer(&mut self, conversation_id: &str, payload: serde_json::Value) -> bool {
        let entry = OutboxEntry {
            entry_id: new_identifier(),
            conversation_id: conversation_id.to_owned(),
            kind: OutboxKind::Answer,
            state: OutboxState::Queued,
            created_at: unix_now(),
            queued_at: unix_now(),
            attempts: 0,
            item_id: None,
            client_token: None,
            failure_reason: None,
            payload: Some(payload.to_string().into_bytes()),
        };
        let queued = self.store.enqueue(&entry, None).is_ok();
        self.deliver_to(conversation_id);
        queued
    }

    /// Hands the outbox to a live session with this friend, or dials them.
    pub fn deliver_to(&mut self, conversation_id: &str) {
        match self.sessions.live_for(conversation_id) {
            Some(id) => self.deliver_pending(id),
            None => self.schedule_reconsider(),
        }
    }

    pub fn offer_frame(&mut self, entry: &OutboxEntry) -> Option<(String, Frame)> {
        use szfriends_core::store::TransferState::*;
        let record = self.store.transfer(entry.item_id.as_deref()?).ok().flatten()?;
        match record.state {
            Queued | Offered => {}
            Sending | Delivered => {
                // They answered it, so it arrived: the ACK was lost with an earlier session.
                let _ =
                    self.store.apply_outbox_event(&entry.entry_id, szfriends_core::store::OutboxEvent::Acknowledged);
                return None;
            }
            _ => {
                let _ = self.store.apply_outbox_event(&entry.entry_id, szfriends_core::store::OutboxEvent::Refused);
                return None;
            }
        }
        let mut frame = id_frame(FrameType::Offer, &unhex(&record.transfer_id)?)
            .with(tag::NAME, record.file_name.as_bytes().to_vec())
            .with(tag::SIZE, record.size.to_be_bytes())
            .with(tag::DIGEST, record.digest);
        let kind = std::path::Path::new(&record.file_name).extension().and_then(|e| e.to_str()).unwrap_or_default();
        if !kind.is_empty() {
            frame = frame.with(tag::FILE_TYPE, kind.as_bytes().to_vec());
        }
        if let Some(id) = self.sessions.live_for(&record.conversation_id) {
            frame = self.with_tree(id, &record, frame);
        }
        Some((record.transfer_id, frame))
    }

    /// Answers carry their verdict in the entry's payload.
    pub fn answer_frame(&mut self, entry: &OutboxEntry) -> Option<(String, Frame)> {
        let payload: serde_json::Value = serde_json::from_slice(entry.payload.as_deref()?).ok()?;
        if payload.get("transfer_id").is_none() {
            // Answers about the friendship itself carry the entry's own id.
            let wire = unhex(&entry.entry_id)?;
            let frame_type = match payload["frame"].as_str()? {
                "accept" => FrameType::Accept,
                "decline" => FrameType::Decline,
                "cancel" => FrameType::Cancel,
                _ => {
                    let _ = self.store.apply_outbox_event(&entry.entry_id, szfriends_core::store::OutboxEvent::Refused);
                    return None;
                }
            };
            return Some((entry.entry_id.clone(), id_frame(frame_type, &wire)));
        }
        let transfer = payload["transfer_id"].as_str()?.to_owned();
        let wire = unhex(&transfer)?;
        let frame = match payload["frame"].as_str()? {
            "cancel" => id_frame(FrameType::Cancel, &wire),
            "offer_reply" if payload["accept"] == true => {
                let record = self.store.transfer(&transfer).ok().flatten()?;
                // Receiving from here: the chunks that follow have somewhere to go.
                let id = self.sessions.live_for(&entry.conversation_id)?;
                if let Some(reply) = self.blocks_reply(id, &transfer, &entry.conversation_id) {
                    return Some((transfer, reply));
                }
                let route = self.chunk_route(id);
                let receiver = ChunkReceiver::for_route(&wire, record.size, record.verified_bytes, route)?;
                self.sessions.map.get_mut(&id)?.receivers.insert(transfer.clone(), receiver);
                id_frame(FrameType::OfferReply, &wire)
                    .with(tag::ACCEPT, [1])
                    .with(tag::OFFSET, record.verified_bytes.to_be_bytes())
            }
            "offer_reply" => id_frame(FrameType::OfferReply, &wire).with(tag::ACCEPT, [0]),
            _ => return None,
        };
        Some((transfer, frame))
    }

    /// Their offer: recorded and acknowledged; accepted at once only when they accept this friend's files.
    pub fn offer(&mut self, id: u64, frame: &Frame, conversation: &str, wire: String) {
        let (Some(size), Some(digest), Some(name)) =
            (frame.integer(tag::SIZE), frame.get(tag::DIGEST), frame.text(tag::NAME))
        else {
            return;
        };
        let Ok(digest) = <[u8; 32]>::try_from(digest) else { return };
        let file_type = frame.text(tag::FILE_TYPE);
        let recorded =
            self.store.record_incoming_offer(&wire, conversation, name, file_type, size, &digest, unix_now());
        if recorded.is_ok() {
            self.offered_tree(id, frame, conversation, &wire);
        }
        let bytes = frame.get(tag::ID).unwrap_or_default().to_vec();
        self.send_on(id, &id_frame(FrameType::Ack, &bytes));
        let Ok(record) = recorded else {
            self.send_on(id, &id_frame(FrameType::OfferReply, &bytes).with(tag::ACCEPT, [0]));
            return;
        };
        let automatic = self.store.person_with_conversation(conversation).ok().flatten().is_some_and(|p| p.auto_accept);
        if automatic && record.state == szfriends_core::store::TransferState::WaitingForYou {
            self.accept_offer(&record.transfer_id, true);
        }
        self.changed();
    }

    /// This person (or their auto-accept) takes a friend's offer.
    pub fn accept_offer(&mut self, transfer_id: &str, automatically: bool) -> bool {
        let Ok(Some(record)) = self.store.transfer(transfer_id) else { return false };
        if self.store.accept_transfer(transfer_id).is_err() {
            return false;
        }
        if automatically {
            let _ = self
                .store
                .connection()
                .execute("UPDATE transfers SET accepted_automatically = 1 WHERE transfer_id = ?1", [transfer_id]);
        }
        let queued = self.queue_answer(
            &record.conversation_id,
            json!({"frame": "offer_reply", "transfer_id": transfer_id, "accept": true}),
        );
        // The answer first, then where the download stands: a sender starts on the PROGRESS that follows (the
        // Objective-C helper's does), whatever the answer itself says.
        if let Some(id) = self.sessions.live_for(&record.conversation_id) {
            let now = monotonic_now();
            if let Some(session) = self.sessions.map.get_mut(&id) {
                if let Some(receiver) = session.receivers.get(transfer_id) {
                    let progress = receiver.resume_progress_frame();
                    session.channel.send_frame(&progress, now);
                }
            }
        }
        queued
    }

    fn start_sending(&mut self, id: u64, offer: &str, accepted: bool, offset: u64) -> bool {
        let Some(conversation) = self.conversation_of(id) else { return false };
        match self.store.peer_answered_transfer(offer, accepted, offset, &conversation) {
            Ok(record) if accepted => {
                let route = self.chunk_route(id);
                let Some(sender) =
                    ChunkSender::for_route(&unhex(offer).unwrap_or_default(), record.size, offset, route)
                else {
                    return false;
                };
                let session = self.sessions.map.get_mut(&id).expect("live");
                session.senders.insert(
                    offer.to_owned(),
                    Outgoing { sender, record, done_sent: false, file: None, buffer: Vec::new() },
                );
                true
            }
            Ok(_) => true,
            Err(_) => false,
        }
    }

    pub fn offer_reply(&mut self, id: u64, frame: &Frame, offer: String) {
        let accepted = frame.integer(tag::ACCEPT) == Some(1);
        let offset = frame.integer(tag::OFFSET).unwrap_or(0);
        if accepted && szfriends_core::transfer::frames::takes_blocks(frame) && self.offer_taken_by_blocks(id, &offer) {
            if let Some(wire) = unhex(&offer) {
                self.send_ack(id, &wire);
            }
            return self.changed();
        }
        // A late or replayed answer (the receiver's outbox sends it again on a new session until we acknowledge it)
        // is stale and changes nothing; it is acknowledged all the same, as the Objective-C helper does, or every new
        // session would carry it again.
        if !self.start_sending(id, &offer, accepted, offset) {
            if let Some(session) = self.sessions.map.get_mut(&id) {
                session.senders.remove(&offer);
            }
        }
        if let Some(wire) = unhex(&offer) {
            self.send_ack(id, &wire);
        }
        self.changed();
    }

    pub fn progress(&mut self, id: u64, frame: &Frame, offer: String) {
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        if let Some(outgoing) = session.senders.get_mut(&offer) {
            if outgoing.sender.handle_progress(frame).is_err() {
                self.close(id, CloseReason::ProtocolError);
            }
            self.changed();
            return;
        }
        // A new session resuming: the sender continues from the recipient's durable count, if the offer still holds.
        let offset = frame.integer(tag::OFFSET).unwrap_or(0);
        if !self.start_sending(id, &offer, true, offset) {
            self.close(id, CloseReason::ProtocolError);
        }
    }

    pub fn chunk(&mut self, id: u64, frame: &Frame, conversation: &str, offer: String) {
        let now = monotonic_now();
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        let Some(receiver) = session.receivers.get_mut(&offer) else {
            // Unsolicited: no CHUNK moves before acceptance.
            return self.close(id, CloseReason::ProtocolError);
        };
        let offset = receiver.received_offset();
        let Ok(data) = receiver.accept_chunk(frame) else { return self.close(id, CloseReason::ProtocolError) };
        match self.store.append_chunk(&offer, offset, data, conversation) {
            Ok(durable) => {
                let session = self.sessions.map.get_mut(&id).expect("live");
                session.flush_due.get_or_insert(Instant::now() + FLUSH_DELAY);
                let receiver = session.receivers.get_mut(&offer).expect("checked");
                if durable > receiver.reported_offset() {
                    if let Some(progress) = receiver.progress_frame(durable) {
                        session.channel.send_frame(&progress, now);
                        self.changed();
                    }
                }
            }
            Err(_) => self.close(id, CloseReason::ProtocolError),
        }
    }

    pub fn done(&mut self, id: u64, frame: &Frame, conversation: &str, offer: String) {
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        let Some(digest) = session.receivers.get(&offer).and_then(|r| r.accept_done(frame).ok()) else {
            return self.close(id, CloseReason::ProtocolError);
        };
        session.receivers.remove(&offer);
        let wire = frame.get(tag::ID).unwrap_or_default().to_vec();
        if self.store.finish_transfer(&offer, &digest, conversation).is_ok() {
            self.send_on(id, &id_frame(FrameType::Ack, &wire));
        }
        self.changed();
    }

    pub fn cancelled(&mut self, conversation: &str, offer: &str) {
        if self.store.peer_cancelled_transfer(offer, conversation).is_ok() {
            for session in self.sessions.map.values_mut() {
                session.senders.remove(offer);
                session.receivers.remove(offer);
                session.block_senders.remove(offer);
                session.block_receivers.remove(offer);
            }
            self.changed();
        }
    }

    /// The ACK after our DONE: their device verified the file.
    pub fn transfer_acknowledged(&mut self, id: u64, offer: &str, conversation: &str) {
        if self.store.peer_verified_transfer(offer, conversation).is_ok() {
            if let Some(session) = self.sessions.map.get_mut(&id) {
                session.senders.remove(offer);
                session.block_senders.remove(offer);
            }
            let _ = std::fs::remove_file(self.store.sender_tree_path(offer));
            self.changed();
        }
    }

    /// The route a session's chunk sizes and window follow, as both sides read it (Bluetooth's are
    /// smaller, and a receiver refuses a chunk larger than its route allows).
    fn chunk_route(&self, id: u64) -> szfriends_core::wire::RouteMethod {
        self.sessions.map.get(&id).map_or(szfriends_core::wire::RouteMethod::Lan, |s| s.meta.race_route(&s.channel))
    }

    /// On a new session: PROGRESS for every inbound transfer still Receiving, so the sender continues.
    pub fn resume_incoming(&mut self, id: u64, conversation: &str) {
        let now = monotonic_now();
        let route = self.chunk_route(id);
        for record in self.store.unfinished_incoming_transfers(conversation).unwrap_or_default() {
            if self.finishing.contains_key(&record.transfer_id) || self.resume_blocks(id, &record) {
                continue;
            }
            let offer = unhex(&record.transfer_id).unwrap_or_default();
            let Some(receiver) = ChunkReceiver::for_route(&offer, record.size, record.verified_bytes, route) else {
                continue;
            };
            let Some(session) = self.sessions.map.get_mut(&id) else { return };
            session.channel.send_frame(&receiver.resume_progress_frame(), now);
            session.receivers.insert(record.transfer_id.clone(), receiver);
        }
    }

    /// Makes received bytes durable once a flush came due, and reports them in PROGRESS.
    pub fn flush_if_due(&mut self, id: u64) {
        let now = monotonic_now();
        let due = self.sessions.map.get(&id).and_then(|s| s.flush_due).is_some_and(|at| Instant::now() >= at);
        if !due {
            return;
        }
        let _ = self.store.flush_progress();
        let session = self.sessions.map.get_mut(&id).expect("live");
        session.flush_due = None;
        let offers: Vec<String> = session.receivers.keys().cloned().collect();
        for offer in offers {
            let durable = self.store.transfer(&offer).ok().flatten().map_or(0, |r| r.verified_bytes);
            let session = self.sessions.map.get_mut(&id).expect("live");
            let receiver = session.receivers.get_mut(&offer).expect("listed");
            if durable > receiver.reported_offset() {
                if let Some(progress) = receiver.progress_frame(durable) {
                    session.channel.send_frame(&progress, now);
                }
            }
        }
        self.changed();
    }

    /// The next chunks of every transfer this session sends, while the channel's bulk queue is shallow, then DONE.
    pub fn pump(&mut self, id: u64) {
        let now = monotonic_now();
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        if !session.channel.is_established() {
            return;
        }
        let offers: Vec<String> = session.senders.keys().cloned().collect();
        for offer in offers {
            loop {
                let session = self.sessions.map.get_mut(&id).expect("live");
                if session.channel.queued_frames().1 >= BULK_DEPTH {
                    return;
                }
                let outgoing = session.senders.get_mut(&offer).expect("listed");
                if let Some((offset, length)) = outgoing.sender.next_chunk() {
                    if outgoing.file.is_none() {
                        outgoing.file = self.store.open_outgoing(&outgoing.record).ok();
                    }
                    let Some(file) = &outgoing.file else { return };
                    outgoing.buffer.resize(length, 0);
                    if file.read_at(offset, &mut outgoing.buffer).is_err() {
                        return;
                    }
                    let Some(frame) = outgoing.sender.chunk_frame(&outgoing.buffer) else { return };
                    session.channel.send_frame(&frame, now);
                    continue;
                }
                if outgoing.sender.all_sent() && !outgoing.done_sent {
                    outgoing.done_sent = true;
                    let wire = outgoing.sender.offer_id().to_vec();
                    let done = id_frame(FrameType::Done, &wire).with(tag::DIGEST, outgoing.record.digest);
                    session.channel.send_frame(&done, now);
                    session.expecting.insert(hex(&wire), format!("done:{offer}"));
                }
                break;
            }
        }
    }
}
