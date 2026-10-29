//! The Rust peer's sessions (peer.rs): accepted, their link events and batches, each one serviced, its events handled,
//! and the transfers a command asks about.

use super::*;

impl State {
    pub(super) fn accept(&mut self, stream: TcpStream) {
        let mut channel = self.responder_channel();
        channel.set_config(self.channel_config());
        let id = self.new_session(channel, stream);
        let session = self.sessions.get_mut(&id).expect("just made");
        session.channel.start(monotonic_now());
        self.emit(json!({ "event": "accepted", "session": id }));
    }

    /// A responder admitting IK from friends and token holders, as the helper's listeners do.
    pub(crate) fn responder_channel(&self) -> SecureChannel {
        let policy = self.policy.clone();
        let decide = Box::new(move |key: Option<&[u8; 32]>, pattern: Pattern, token: Option<&[u8]>| {
            let policy = policy.lock().unwrap();
            match pattern {
                Pattern::IK => {
                    key.is_some_and(|k| policy.friends.contains(k) || policy.own_devices.contains(k))
                        || token.is_some_and(|t| policy.tokens.contains(t))
                }
                Pattern::XX | Pattern::NN => true,
            }
        });
        let identity = ChannelIdentity::new(&self.identity);
        SecureChannel::responder(identity, self.public_profile.clone(), decide)
    }

    pub(super) fn link_event(&mut self, event: LinkEvent) {
        let now = monotonic_now();
        match event {
            LinkEvent::Bytes(id, bytes) => {
                if let Some(s) = self.sessions.get_mut(&id) {
                    s.channel.receive(&bytes, now);
                }
                self.lane_activity(id, true);
            }
            LinkEvent::Eof(id) => {
                if let Some(s) = self.sessions.get_mut(&id) {
                    s.channel.link_closed_by_peer();
                }
            }
            LinkEvent::Written(id) => {
                if let Some(s) = self.sessions.get_mut(&id) {
                    s.channel.write_completed(now);
                }
                self.lane_activity(id, false);
            }
        }
    }

    /// Commits the store batch, then acknowledges and reports each file it saved.
    pub(super) fn end_batch(&mut self) {
        if !std::mem::replace(&mut self.holding, false) {
            return;
        }
        for file in self.store.end_batch().unwrap_or_default() {
            let session = self.sessions.iter().find(|(_, s)| s.conversation.as_deref() == Some(&file.conversation_id));
            let session = session.map(|(id, _)| *id);
            match file.result {
                Ok(path) => {
                    if let (Some(id), Ok(wire)) = (session, hex::decode(&file.transfer_id)) {
                        let ack = Frame::new(szfriends_core::wire::FrameType::Ack).with(tag::ID, wire);
                        if let Some(s) = self.sessions.get_mut(&id) {
                            s.channel.send_frame(&ack, monotonic_now());
                        }
                    }
                    let path = path.to_string_lossy().into_owned();
                    self.emit(json!({ "event": "received_file", "transfer": file.transfer_id, "path": path }));
                }
                Err(error) => self.emit(
                    json!({ "event": "transfer_failed", "transfer": file.transfer_id, "why": error.to_string() }),
                ),
            }
        }
    }

    pub(super) fn service_all(&mut self) {
        let ids: Vec<u64> = self.sessions.keys().copied().collect();
        for id in ids {
            self.service(id);
        }
        self.sessions.retain(|_, s| !s.finished);
    }

    /// Timers, then writes and events until the session has nothing more to say, then the transfers' next chunks.
    pub(super) fn service(&mut self, id: u64) {
        let now = monotonic_now();
        // Files by blocks too (ADR 0018 § 7), as the helper's `block_liveness`, on the group's every lane: both sides
        // of a fast session ping.
        let head = self.head_of(id);
        let (blocks, owed) = self.sessions.get(&head).map_or((false, false), |s| s.blocks.liveness(&self.store));
        if let Some(s) = self.sessions.get_mut(&id) {
            let (keepalive, watch) = transfer_liveness(s.senders.values().map(|o| &o.sender), s.receivers.values());
            s.channel.set_liveness(keepalive || blocks, watch || owed, now);
            s.channel.handle_timeout(now);
        }
        let holding = self.holding;
        loop {
            let Some(s) = self.sessions.get_mut(&id) else { return };
            // Only while not holding: a write taken from the channel must reach the link.
            while let Some(write) = (!holding).then(|| s.channel.poll_transmit()).flatten() {
                s.link.write(write.bytes);
            }
            let Some(event) = s.channel.poll_event() else { break };
            self.handle_event(id, event);
        }
        self.flush_if_due(id);
        self.flush_blocks_if_due();
        self.pump(id);
        self.pump_blocks(id);
        let Some(s) = self.sessions.get_mut(&id) else { return };
        while let Some(write) = (!holding).then(|| s.channel.poll_transmit()).flatten() {
            s.link.write(write.bytes);
        }
        if !holding && s.channel.is_closed() && !s.finished {
            s.finished = true;
            s.link.finish();
        }
    }

    pub(super) fn handle_event(&mut self, id: u64, event: Event) {
        match event {
            Event::Established => {
                self.established(id);
                self.devices_established(id);
            }
            // A lane's frames are its first session's; a PART's HAVE goes back on its lane.
            Event::Frame(frame) if frame.frame_type == szfriends_core::wire::FrameType::Part => {
                let head = self.head_of(id);
                self.part_on(head, id, &frame);
            }
            Event::Frame(frame) => self.frame(self.head_of(id), frame),
            Event::Code(result) => match result {
                Ok(code) => self.emit(json!({ "event": "code", "session": id, "code": code })),
                Err(error) => self.emit(json!({ "event": "code", "session": id, "error": error.code() })),
            },
            Event::Closed(error) => {
                self.lane_closed(id);
                self.devices_closed(id);
                let _ = self.store.flush_progress();
                let reason = match error {
                    Some(SessionError::PeerClosed(reason)) => json!(reason),
                    _ => Value::Null,
                };
                let code = error.map_or(0, SessionError::code);
                let rekeys = self.sessions.get(&id).map(|s| s.channel.rekeys()).unwrap_or_default();
                let rekeys = [rekeys.0, rekeys.1];
                self.emit(
                    json!({ "event": "closed", "session": id, "error": code, "reason": reason, "rekeys": rekeys }),
                );
            }
        }
    }

    pub(crate) fn close_for_protocol(&mut self, id: u64) {
        if let Some(s) = self.sessions.get_mut(&id) {
            s.channel.close_with_reason(CloseReason::ProtocolError, monotonic_now());
        }
    }

    pub(super) fn transfer(&mut self, command: &Value) -> Value {
        match self.store.transfer(command["id"].as_str().unwrap_or_default()) {
            Ok(Some(record)) => json!({
                "state": record.state as i64,
                "verified": record.verified_bytes,
                "received_path": record.received_path.map(|p| p.to_string_lossy().into_owned()),
            }),
            _ => json!({ "error": "no such transfer" }),
        }
    }
}
