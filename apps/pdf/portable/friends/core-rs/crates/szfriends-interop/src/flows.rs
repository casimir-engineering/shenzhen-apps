//! What the Rust peer does with a live session, as the helper's nearby service does (and the Objective-C peer does
//! with the helper's own store): Add by ID answers, and files: OFFER acknowledged and accepted, CHUNKs inside the
//! window, PROGRESS once durable, DONE checked against the whole-file digest and acknowledged, and resume: on every
//! new session the recipient sends PROGRESS for each unfinished inbound transfer and the sender continues from it.

use serde_json::{json, Value};
use szfriends_core::identity::request_by_id;
use szfriends_core::session::{monotonic_now, ChunkReceiver, ChunkSender};
use szfriends_core::store::TransferState;
use szfriends_core::wire::{tag, Frame, FrameType};

use crate::hex_bytes;
use crate::peer::{Outgoing, State};

/// Chunks queued in the channel ahead of the link: enough to keep it busy, few enough that a message overtakes them.
const BULK_DEPTH: usize = 4;
/// As the helper does: when chunks pause (a full window, the end of a file), received bytes are made durable anyway
/// this long after the first unreported one, so the sender's window reopens.
const FLUSH_DELAY: std::time::Duration = std::time::Duration::from_millis(500);

fn id_frame(frame_type: FrameType, id: &[u8]) -> Frame {
    Frame::new(frame_type).with(tag::ID, id.to_vec())
}

impl State {
    pub(crate) fn established(&mut self, id: u64) {
        let now = monotonic_now();
        let Some(session) = self.sessions.get(&id) else { return };
        let channel = &session.channel;
        let remote = channel.remote_identity().copied();
        let event = json!({
            "event": "established",
            "session": id,
            "initiator": channel.is_initiator(),
            "pattern": format!("{:?}", channel.pattern()),
            "remote_identity": remote.map(hex::encode),
            "token": channel.presented_token().map(hex::encode),
            "route": channel.initiator_route() as u8,
            "minor": channel.negotiated_minor(),
        });
        let route = channel.initiator_route();
        let conversation = remote
            .and_then(|key| self.store.person_with_identity_key(&key).ok().flatten())
            .map(|person| person.conversation_id);
        self.emit(event);
        let Some(conversation) = conversation else { return };
        let unfinished = self.store.unfinished_incoming_transfers(&conversation).unwrap_or_default();
        let session = self.sessions.get_mut(&id).expect("looked up above");
        session.conversation = Some(conversation);
        for record in unfinished {
            let offer = hex_bytes(&record.transfer_id).unwrap_or_default();
            let Some(receiver) = ChunkReceiver::for_route(&offer, record.size, record.verified_bytes, route) else {
                continue;
            };
            session.channel.send_frame(&receiver.resume_progress_frame(), now);
            session.receivers.insert(record.transfer_id.clone(), receiver);
        }
    }

    pub(crate) fn frame(&mut self, id: u64, frame: Frame) {
        if self.devices_frame(id, &frame) {
            return;
        }
        let offer = frame.get(tag::ID).map(hex::encode);
        let handled = match (frame.frame_type, offer) {
            (FrameType::Offer, Some(offer)) => self.offer(id, &frame, offer),
            (FrameType::OfferReply, Some(offer)) => self.offer_reply(id, &frame, offer),
            (FrameType::Progress, Some(offer)) => self.progress(id, &frame, offer),
            (FrameType::Chunk, Some(offer)) => self.chunk(id, &frame, offer),
            (FrameType::Done, Some(offer)) => self.done(id, &frame, offer),
            (FrameType::Ack, Some(offer)) => self.acknowledged(id, offer),
            (FrameType::RequestById, _) => self.request_by_id_received(id, &frame),
            _ => false,
        };
        if !handled {
            let bytes = frame.encode().unwrap_or_default();
            self.emit(
                json!({ "event": "frame", "session": id, "type": frame.frame_type as u8, "frame": hex::encode(bytes) }),
            );
        }
    }

    fn conversation(&self, id: u64) -> Option<String> {
        self.sessions.get(&id).and_then(|s| s.conversation.clone())
    }

    fn send(&mut self, id: u64, frame: &Frame) {
        if let Some(session) = self.sessions.get_mut(&id) {
            session.channel.send_frame(frame, monotonic_now());
        }
    }

    /// A friend's offer: durably recorded and acknowledged, then accepted at once (the harness says yes to every file).
    fn offer(&mut self, id: u64, frame: &Frame, offer: String) -> bool {
        let Some(conversation) = self.conversation(id) else {
            self.close_for_protocol(id);
            return true;
        };
        let (Some(size), Some(digest), Some(name)) =
            (frame.integer(tag::SIZE), frame.get(tag::DIGEST), frame.text(tag::NAME))
        else {
            return false;
        };
        let digest: [u8; 32] = digest.try_into().expect("the codec checked 32 bytes");
        let file_type = frame.text(tag::FILE_TYPE);
        let recorded =
            self.store.record_incoming_offer(&offer, &conversation, name, file_type, size, &digest, 0.0).is_ok();
        let id_bytes = frame.get(tag::ID).unwrap_or_default().to_vec();
        if !recorded || self.store.accept_transfer(&offer).is_err() {
            self.send(id, &id_frame(FrameType::Ack, &id_bytes));
            let reply = id_frame(FrameType::OfferReply, &id_bytes).with(tag::ACCEPT, [0]);
            self.send(id, &reply);
            return true;
        }
        let route = self.sessions[&id].channel.initiator_route();
        let Some(receiver) = ChunkReceiver::for_route(&id_bytes, size, 0, route) else { return true };
        self.sessions.get_mut(&id).expect("live").receivers.insert(offer.clone(), receiver);
        self.send(id, &id_frame(FrameType::Ack, &id_bytes));
        let reply =
            id_frame(FrameType::OfferReply, &id_bytes).with(tag::ACCEPT, [1]).with(tag::OFFSET, 0u64.to_be_bytes());
        self.send(id, &reply);
        self.emit(json!({ "event": "offer", "session": id, "transfer": offer, "size": size }));
        true
    }

    fn start_sending(&mut self, id: u64, offer: &str, accepted: bool, offset: u64) -> bool {
        let Some(conversation) = self.conversation(id) else { return false };
        match self.store.peer_answered_transfer(offer, accepted, offset, &conversation) {
            Ok(record) if accepted => {
                let route = self.sessions[&id].channel.initiator_route();
                let offer_id = hex_bytes(offer).unwrap_or_default();
                match ChunkSender::for_route(&offer_id, record.size, offset, route) {
                    Some(sender) => {
                        let outgoing = Outgoing { sender, record, done_sent: false };
                        self.sessions.get_mut(&id).expect("live").senders.insert(offer.to_owned(), outgoing);
                        self.emit(json!({ "event": "sending", "session": id, "transfer": offer, "offset": offset }));
                        true
                    }
                    None => false,
                }
            }
            Ok(_) => {
                self.emit(json!({ "event": "declined", "transfer": offer }));
                true
            }
            Err(error) => {
                self.emit(json!({ "event": "transfer_failed", "transfer": offer, "why": error.to_string() }));
                false
            }
        }
    }

    fn offer_reply(&mut self, id: u64, frame: &Frame, offer: String) -> bool {
        let accepted = frame.integer(tag::ACCEPT) == Some(1);
        let offset = frame.integer(tag::OFFSET).unwrap_or(0);
        if !self.start_sending(id, &offer, accepted, offset) {
            self.close_for_protocol(id);
        }
        true
    }

    fn progress(&mut self, id: u64, frame: &Frame, offer: String) -> bool {
        let session = self.sessions.get_mut(&id).expect("live");
        if let Some(outgoing) = session.senders.get_mut(&offer) {
            if outgoing.sender.handle_progress(frame).is_err() {
                self.close_for_protocol(id);
            }
            return true;
        }
        // A new session resuming: the sender continues from the recipient's durable count, if the offer still holds.
        let offset = frame.integer(tag::OFFSET).unwrap_or(0);
        if !self.start_sending(id, &offer, true, offset) {
            self.close_for_protocol(id);
        }
        true
    }

    fn chunk(&mut self, id: u64, frame: &Frame, offer: String) -> bool {
        let now = monotonic_now();
        let conversation = self.conversation(id).unwrap_or_default();
        let session = self.sessions.get_mut(&id).expect("live");
        let Some(receiver) = session.receivers.get_mut(&offer) else {
            self.close_for_protocol(id); // unsolicited: no CHUNK moves before acceptance
            return true;
        };
        let offset = receiver.received_offset();
        let Ok(data) = receiver.accept_chunk(frame) else {
            self.close_for_protocol(id);
            return true;
        };
        match self.store.append_chunk(&offer, offset, data, &conversation) {
            Ok(durable) => {
                let session = self.sessions.get_mut(&id).expect("live");
                session.flush_due.get_or_insert(std::time::Instant::now() + FLUSH_DELAY);
                let receiver = session.receivers.get_mut(&offer).expect("checked");
                if durable > receiver.reported_offset() {
                    if let Some(progress) = receiver.progress_frame(durable) {
                        session.channel.send_frame(&progress, now);
                    }
                }
            }
            Err(_) => self.close_for_protocol(id),
        }
        true
    }

    fn done(&mut self, id: u64, frame: &Frame, offer: String) -> bool {
        let conversation = self.conversation(id).unwrap_or_default();
        let session = self.sessions.get_mut(&id).expect("live");
        let Some(digest) = session.receivers.get(&offer).and_then(|r| r.accept_done(frame).ok()) else {
            self.close_for_protocol(id);
            return true;
        };
        session.receivers.remove(&offer);
        let offer_id = frame.get(tag::ID).unwrap_or_default().to_vec();
        match self.store.finish_transfer(&offer, &digest, &conversation) {
            Ok(path) => {
                self.send(id, &id_frame(FrameType::Ack, &offer_id));
                let path = path.to_string_lossy().into_owned();
                self.emit(json!({ "event": "received_file", "transfer": offer, "path": path }));
            }
            Err(error) => {
                self.emit(json!({ "event": "transfer_failed", "transfer": offer, "why": error.to_string() }));
            }
        }
        true
    }

    /// The offer's ACK moves it to Offered; the ACK after DONE says their device verified the file.
    fn acknowledged(&mut self, id: u64, offer: String) -> bool {
        let Ok(Some(record)) = self.store.transfer(&offer) else { return false };
        let Some(conversation) = self.conversation(id) else { return false };
        if !record.outgoing {
            return false;
        }
        match record.state {
            TransferState::Queued => {
                let _ = self.store.mark_offer_delivered(&offer, &conversation);
            }
            TransferState::Sending if self.store.peer_verified_transfer(&offer, &conversation).is_ok() => {
                self.sessions.get_mut(&id).expect("live").senders.remove(&offer);
                self.emit(json!({ "event": "delivered", "transfer": offer }));
            }
            _ => {}
        }
        true
    }

    /// Every device answers an Add by ID at once with RECEIVED, before looking anything up; the harness then reports
    /// the request when its signature verifies for this session.
    fn request_by_id_received(&mut self, id: u64, frame: &Frame) -> bool {
        self.send(id, &Frame::new(FrameType::Received));
        let hash = self.sessions[&id].channel.handshake_hash().copied().unwrap_or([0; 64]);
        if let Some(identity) = request_by_id::verify_frame(frame, &hash) {
            self.emit(json!({
                "event": "request_by_id",
                "session": id,
                "identity_key": hex::encode(identity),
                "static_key": frame.get(tag::STATIC_KEY).map(hex::encode),
                "token": frame.get(tag::TOKEN).map(hex::encode),
                "callback_secret": frame.get(tag::CALLBACK_SECRET).map(hex::encode),
                "friends_id": frame.text(tag::FRIENDS_ID),
            }));
        }
        true
    }

    /// Makes received bytes durable once a flush came due, and reports them in PROGRESS.
    pub(crate) fn flush_if_due(&mut self, id: u64) {
        let now = monotonic_now();
        let due = self.sessions.get(&id).and_then(|s| s.flush_due).is_some_and(|at| std::time::Instant::now() >= at);
        if !due {
            return;
        }
        let _ = self.store.flush_progress();
        let session = self.sessions.get_mut(&id).expect("live");
        session.flush_due = None;
        let offers: Vec<String> = session.receivers.keys().cloned().collect();
        for offer in offers {
            let durable = self.store.transfer(&offer).ok().flatten().map_or(0, |r| r.verified_bytes);
            let session = self.sessions.get_mut(&id).expect("live");
            let receiver = session.receivers.get_mut(&offer).expect("listed");
            if durable > receiver.reported_offset() {
                if let Some(progress) = receiver.progress_frame(durable) {
                    session.channel.send_frame(&progress, now);
                }
            }
        }
    }

    /// The next chunks of every transfer this session sends, while the channel's bulk queue is shallow, then DONE.
    pub(crate) fn pump(&mut self, id: u64) {
        let now = monotonic_now();
        let Some(session) = self.sessions.get_mut(&id) else { return };
        if !session.channel.is_established() {
            return;
        }
        let offers: Vec<String> = session.senders.keys().cloned().collect();
        for offer in offers {
            loop {
                let session = self.sessions.get_mut(&id).expect("live");
                if session.channel.queued_frames().1 >= BULK_DEPTH {
                    return;
                }
                let outgoing = session.senders.get_mut(&offer).expect("listed");
                if let Some((offset, length)) = outgoing.sender.next_chunk() {
                    let Ok(data) = self.store.read_outgoing(&outgoing.record, offset, length) else { return };
                    let frame = outgoing.sender.chunk_frame(&data).expect("the range it gave");
                    session.channel.send_frame(&frame, now);
                    continue;
                }
                if outgoing.sender.all_sent() && !outgoing.done_sent {
                    outgoing.done_sent = true;
                    let done =
                        id_frame(FrameType::Done, outgoing.sender.offer_id()).with(tag::DIGEST, outgoing.record.digest);
                    session.channel.send_frame(&done, now);
                }
                break;
            }
        }
    }

    pub(crate) fn send_file(&mut self, id: u64, command: &Value) -> Value {
        let Some(conversation) = self.conversation(id) else { return json!({ "error": "not a friend's session" }) };
        let path = std::path::PathBuf::from(command["path"].as_str().unwrap_or_default());
        let record = match self.store.stage_outgoing_file(&path, None, &conversation) {
            Ok(record) => record,
            Err(error) => return json!({ "error": error.to_string() }),
        };
        let offer_id = hex_bytes(&record.transfer_id).unwrap_or_default();
        let offer = id_frame(FrameType::Offer, &offer_id)
            .with(tag::NAME, record.file_name.as_bytes())
            .with(tag::SIZE, record.size.to_be_bytes())
            .with(tag::DIGEST, record.digest);
        self.send(id, &offer);
        json!({ "transfer": record.transfer_id, "size": record.size, "digest": hex::encode(record.digest) })
    }

    pub(crate) fn request_by_id(&mut self, id: u64, command: &Value) -> Value {
        let Some(session) = self.sessions.get(&id) else { return json!({ "sent": false }) };
        let hash = session.channel.handshake_hash().copied().unwrap_or([0; 64]);
        let token = command["token"].as_str().and_then(hex_bytes).unwrap_or_default();
        let callback = command["callback"].as_str().and_then(hex_bytes).unwrap_or_default();
        let friends_id = command["friends_id"].as_str().unwrap_or_default();
        let Some(frame) = request_by_id::make_frame(self.peer_identity(), friends_id, &token, &callback, &hash) else {
            return json!({ "sent": false });
        };
        let sent = self.sessions.get_mut(&id).expect("looked up").channel.send_frame(&frame, monotonic_now());
        json!({ "sent": sent })
    }
}
