//! A link that ends (links.rs): what its session had in flight goes back, failures count against the person's backoff,
//! and sessions closed when their people left or at a set time.

use super::*;

impl State {
    /// A session ended: what it had in flight goes back to Queued; failures count against the person's backoff.
    pub(crate) fn closed(&mut self, id: u64, error: Option<SessionError>) {
        let _ = self.store.flush_progress();
        self.lane_closed(id);
        self.nearby.admission.lock().unwrap_or_else(|e| e.into_inner()).release(id);
        self.nearby.policy.lock().unwrap_or_else(|e| e.into_inner()).strangers.remove(&id);
        self.session_closed_elsewhere(id);
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        for entry in session.in_flight.drain() {
            let _ = self.store.apply_outbox_event(&entry, OutboxEvent::SessionLost);
        }
        session.senders.clear();
        session.receivers.clear();
        session.block_senders.clear();
        let receiving: Vec<String> = session.block_receivers.drain().collect();
        self.store.blocks_session_ended(&receiving);
        let meta = session.meta.clone();
        let conversation = session.conversation.clone();
        let (initiator, was_adopted) = (session.channel.is_initiator(), session.meta.adopted);
        session.meta.adopted = false;
        if let Some(key) = &meta.dial_key {
            self.nearby.dialing.remove(key);
        }
        if let (Some(error), false) = (&error, meta.probe) {
            log_end(&meta, error);
        }
        if meta.purpose == Purpose::Browse {
            let fields = self.nearby.browsed.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
            let session = &self.sessions.map[&id];
            let (key, static_key) =
                (session.channel.remote_identity().copied(), session.channel.remote_static().copied());
            match (fields, key, &meta.endpoint) {
                (Some(fields), Some(key), Some((method, endpoint))) => {
                    self.browsed_profile(*method, endpoint, key, static_key, fields);
                }
                (_, _, Some((_, endpoint))) => self.browse_failed(endpoint),
                _ => {}
            }
        }
        if meta.purpose == Purpose::ById && !meta.by_id_answered {
            if let Some(key) = &meta.attempt_key {
                self.by_id_attempt_failed(key);
            }
        }
        if initiator && matches!(meta.purpose, Purpose::Friend | Purpose::OwnDevice) && !meta.live && error.is_some() {
            if let (Some((method, endpoint)), Some(name)) =
                (&meta.endpoint, conversation.as_ref().or(meta.race_name.as_ref()))
            {
                self.nearby.racer.note_failed(endpoint, *method, name, unix_now());
                if let Some(end) = self.nearby.racer.next_backoff_end(unix_now()) {
                    self.schedule_reconsider_after(end - unix_now());
                }
            }
        }
        if let Some(conversation) = &conversation {
            if !meta.probe && !meta.superseded && end_counts(error.as_ref()) && (meta.live || initiator) {
                self.note_failure(conversation, meta.live_at);
            }
            if was_adopted {
                // A standby session (the responder's copy of a double dial) takes over at once.
                let standby = self.sessions.map.iter().find(|(other, s)| {
                    **other != id
                        && s.meta.live
                        && !s.meta.superseded
                        && !s.channel.is_closed()
                        && s.conversation.as_deref() == Some(conversation)
                });
                if let Some((other, _)) = standby {
                    let other = *other;
                    self.adopt(other);
                }
            }
            self.deliver_to(conversation);
        }
        self.schedule_reconsider();
        self.changed();
    }

    /// Sessions with people who are now blocked, gone, or removed with nothing left to deliver, end.
    pub(crate) fn close_links_people_left(&mut self) {
        let links: Vec<(u64, String)> =
            self.sessions.map.iter().filter_map(|(id, s)| Some((*id, s.conversation.clone()?))).collect();
        for (id, conversation) in links {
            let person = self.store.person_with_conversation(&conversation).ok().flatten();
            let done = match &person {
                None => true,
                Some(p) if p.relation == Relation::Blocked => true,
                Some(p) if p.relation == Relation::Removed => {
                    let waiting = self.store.pending_outbox(&conversation).unwrap_or_default();
                    let in_flight = self.sessions.map.get(&id).is_some_and(|s| !s.in_flight.is_empty());
                    !waiting.iter().any(|e| crate::service::sessions::deliverable(e, p)) && !in_flight
                }
                _ => false,
            };
            if done {
                self.close(id, CloseReason::Normal);
            }
        }
    }

    /// Closes the session at a later time unless it closed meanwhile.
    pub(crate) fn close_after(&mut self, id: u64, seconds: f64) {
        if let Some(s) = self.sessions.map.get_mut(&id) {
            let at = unix_now() + seconds;
            s.meta.close_at = Some(s.meta.close_at.map_or(at, |due| due.min(at)));
        }
    }
}
