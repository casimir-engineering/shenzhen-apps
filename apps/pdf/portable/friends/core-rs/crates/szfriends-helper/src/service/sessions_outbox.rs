//! What a session carries for the person (sessions.rs): the outbox delivered when they are reachable, their messages
//! received, and the acknowledgements both ways.

use super::*;

impl State {
    pub fn deliver_pending(&mut self, id: u64) {
        let Some(conversation) = self.conversation_of(id) else { return };
        if self.sessions.live_for(&conversation) != Some(id) {
            return;
        }
        let Some(person) = self.store.person_with_conversation(&conversation).ok().flatten() else { return };
        // Files asked again of this friend start copying (again.rs).
        self.again_start(id, &conversation);
        // A request accepted on this session: the friend gets our chain now (nearby/chain.rs).
        self.send_chain_to_friend(id);
        let busy: HashSet<String> = self.sessions.map.values().flat_map(|s| s.in_flight.iter().cloned()).collect();
        let mut pending = self.store.pending_outbox(&conversation).unwrap_or_default();
        if person.callback_token.is_some() {
            // Until our acceptance reaches an Add by ID requester, they know us only by its token and keep nothing else
            // we send: it goes first. A friend who removed us and asked again by ID finds what we wrote meanwhile
            // queued ahead of it (PROTOCOL.md remove_friend).
            szfriends_core::wire::order::sort_by_key(&mut pending, |e| {
                !(is_request_answer(e) && answer_kind(e) == "accept")
            });
        }
        for entry in pending {
            if busy.contains(&entry.entry_id) || !deliverable(&entry, &person) {
                continue;
            }
            // A request or an answer may be the first they hear of us: our chain goes first (nearby/chain.rs).
            if matches!(entry.kind, OutboxKind::Request | OutboxKind::Answer) {
                self.send_first_contact_chain(id);
            }
            let Some((wire, frame)) = self.frame_for_entry(&entry, &person) else { continue };
            // Written is committed before the frame goes, so Cancel never reads a message that left as unsent.
            if self.store.apply_outbox_event(&entry.entry_id, OutboxEvent::Written).is_err() {
                continue;
            }
            if !self.send_on(id, &frame) {
                let _ = self.store.apply_outbox_event(&entry.entry_id, OutboxEvent::SessionLost);
                continue;
            }
            let session = self.sessions.map.get_mut(&id).expect("live");
            session.in_flight.insert(entry.entry_id.clone());
            session.expecting.insert(wire, entry.entry_id.clone());
            self.changed();
        }
    }

    pub(super) fn frame_for_entry(&mut self, entry: &OutboxEntry, person: &Person) -> Option<(String, Frame)> {
        let entry_wire = unhex(&entry.entry_id).filter(|w| w.len() == 16);
        match entry.kind {
            OutboxKind::Message => {
                let item =
                    crate::service::facts::item_row(&self.store, &entry.conversation_id, entry.item_id.as_deref()?)?;
                let wire = unhex(&item.item_id)?;
                let millis = (item.sent_at * 1000.0).max(0.0) as u64;
                let frame = Frame::new(FrameType::Message)
                    .with(tag::ID, wire)
                    .with(tag::SENT_AT, millis.to_be_bytes())
                    .with(tag::TEXT, item.body.unwrap_or_default().into_bytes());
                Some((item.item_id, frame))
            }
            OutboxKind::Offer => self.offer_frame(entry),
            OutboxKind::Answer => self.answer_frame(entry),
            OutboxKind::Request => {
                let millis = (entry.created_at * 1000.0).max(0.0) as u64;
                let frame =
                    Frame::new(FrameType::Request).with(tag::ID, entry_wire?).with(tag::SENT_AT, millis.to_be_bytes());
                Some((entry.entry_id.clone(), frame))
            }
            OutboxKind::PresenceSecret => {
                // Only to someone who is a friend now, and our current secret, so a later rotation is never undone.
                if person.relation != Relation::Friend {
                    let _ = self.store.apply_outbox_event(&entry.entry_id, OutboxEvent::Refused);
                    return None;
                }
                let secret = self.store.own_presence_secret()?;
                let frame = Frame::new(FrameType::PresenceSecret).with(tag::ID, entry_wire?).with(tag::SECRET, secret);
                Some((entry.entry_id.clone(), frame))
            }
        }
    }

    /// A friend's message: committed, then acknowledged; a repeat is acknowledged again and kept once.
    pub(in crate::service) fn message(&mut self, id: u64, frame: &Frame, conversation: &str, wire: String) {
        let sent_at = frame.integer(tag::SENT_AT).map_or_else(unix_now, |ms| ms as f64 / 1000.0);
        let item = Item {
            item_id: wire.clone(),
            conversation_id: conversation.to_owned(),
            kind: ItemKind::Message,
            direction: Direction::Incoming,
            text: Some(frame.text(tag::TEXT).unwrap_or_default().to_owned()),
            transfer_id: None,
            sent_at,
            received_at: unix_now(),
            via_assistant: frame.integer(tag::VIA_ASSISTANT) == Some(1),
        };
        if self.store.insert_item(&item).is_ok() {
            self.send_ack(id, &unhex(&wire).unwrap_or_default());
            self.changed();
        }
    }

    pub(in crate::service) fn send_ack(&mut self, id: u64, wire: &[u8]) {
        self.send_on(id, &Frame::new(FrameType::Ack).with(tag::ID, wire.to_vec()));
    }

    /// The ACK for something this session sent.
    pub(in crate::service) fn acknowledged(&mut self, id: u64, conversation: &str, wire: String) {
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        let Some(token) = session.expecting.remove(&wire) else {
            // The ACK of a file received by blocks, on a later session than the one that carried its last block.
            let by_blocks = self.store.transfer(&wire).ok().flatten().is_some_and(|r| {
                r.outgoing
                    && r.state == szfriends_core::store::TransferState::Sending
                    && r.conversation_id == conversation
            }) && self.store.sender_tree_path(&wire).exists();
            if by_blocks {
                self.transfer_acknowledged(id, &wire, conversation);
            }
            return;
        };
        if let Some(transfer) = token.strip_prefix("done:") {
            self.transfer_acknowledged(id, transfer, conversation);
            return;
        }
        session.in_flight.remove(&token);
        let entry = self.store.outbox_entry(&token).ok().flatten();
        if self.store.apply_outbox_event_from(&token, OutboxEvent::Acknowledged, conversation).is_err() {
            return;
        }
        let Some(entry) = entry else { return };
        if entry.kind == OutboxKind::Offer {
            if let Some(transfer) = &entry.item_id {
                let _ = self.store.mark_offer_delivered(transfer, conversation);
            }
        }
        let mut person = self.store.person_with_conversation(conversation).ok().flatten();
        let accepted = entry.kind == OutboxKind::Answer && is_request_answer(&entry) && answer_kind(&entry) == "accept";
        if let Some(p) =
            person.as_mut().filter(|p| accepted && (p.callback_token.is_some() || p.callback_secret.is_some()))
        {
            // The requester knows our key now: the Add by ID token and its callback tags are spent.
            p.callback_token = None;
            p.callback_secret = None;
            if self.store.save_person(p).is_ok() {
                self.rebuild_matcher();
            }
        }
        // A removed person's session stays only to deliver the answer they are waiting for.
        if let Some(p) = person.filter(|p| p.relation == Relation::Removed) {
            let waiting =
                self.store.pending_outbox(conversation).unwrap_or_default().iter().any(|e| deliverable(e, &p));
            let in_flight = self.sessions.map.get(&id).is_some_and(|s| !s.in_flight.is_empty());
            if !waiting && !in_flight {
                self.close(id, CloseReason::Normal);
            }
        }
        self.changed();
    }
}
