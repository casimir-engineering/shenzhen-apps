//! Frames from the other side (`SZFriendsNearbyService+Inbound.m`, `+Limits.m`): requests and their answers,
//! presence secrets and profiles here; messages and files in `sessions.rs` and `transfers.rs`. Each is committed before
//! its ACK goes back. And what someone who is not a friend may cost: a quiet minute or three minutes in all.

use szfriends_core::nearby::limits::{STRANGER_IDLE_SECONDS, STRANGER_SESSION_LIFE_SECONDS};
use szfriends_core::presentation::text::{clusters, is_control_or_format, trim};
use szfriends_core::store::requests::event;
use szfriends_core::store::{unix_now, OutboxEvent, OutboxKind, Person, Relation};
use szfriends_core::wire::{tag, CloseReason, Fields, Frame, FrameType, Pattern};

use crate::service::{hex, State};

/// A name as other people chose it: no control, format or direction-override characters, trimmed, at most 40
/// characters as people count them (`SZFriendsCleanName`).
pub fn clean_name(bytes: Option<&[u8]>) -> Option<String> {
    let text = std::str::from_utf8(bytes?).ok()?;
    let kept: String =
        text.chars().filter(|c| !is_control_or_format(*c) && !matches!(u32::from(*c), 0x2028..=0x2029)).collect();
    let trimmed = trim(&kept);
    let name: String = clusters(trimmed).into_iter().take(40).collect();
    (!name.is_empty()).then_some(name)
}

/// A session let in by our Add by ID token alone carries friendship creation only until that person is a friend.
fn creates_friendship(frame_type: FrameType) -> bool {
    matches!(
        frame_type,
        FrameType::Profile | FrameType::Accept | FrameType::Decline | FrameType::Ack | FrameType::Chain
    )
}

impl State {
    pub(crate) fn frame(&mut self, id: u64, frame: Frame) {
        self.note_frame(id, &frame);
        let Some(session) = self.sessions.map.get(&id) else { return };
        if session.meta.token_admitted {
            if self.session_is_with_friend(id) {
                self.sessions.map.get_mut(&id).expect("looked up").meta.token_admitted = false;
            } else if !creates_friendship(frame.frame_type) {
                return;
            }
        }
        // Copies by blocks between our own devices (ADR 0018 § 4) travel in HASHES, PART and HAVE on their session.
        if matches!(frame.frame_type, FrameType::Hashes | FrameType::Have)
            && self.devices.exchanges.contains_key(&id)
            && self.again_block_frame(id, &frame)
        {
            return;
        }
        // Joining on NN sessions, the chain and sync between our own devices (join.rs, own.rs); a friend's chain, or
        // a stranger's before their request (chain.rs).
        let devices = match frame.frame_type {
            FrameType::Join => self.join_frame_on(id, &frame),
            FrameType::Sync => self.own_device_frame(id, &frame),
            FrameType::Again => {
                self.again_frame(id, &frame);
                true
            }
            FrameType::Chain => {
                self.own_device_frame(id, &frame) || {
                    self.friend_chain_frame(id, &frame);
                    true
                }
            }
            _ => false,
        };
        if devices {
            return;
        }
        let wire = frame.get(tag::ID).map(hex);
        match frame.frame_type {
            FrameType::Received => {
                // Our Add by ID request was received; every device says so alike.
                if let Some(s) = self.sessions.map.get_mut(&id) {
                    s.meta.by_id_answered = true;
                }
                return self.close(id, CloseReason::Normal);
            }
            FrameType::RequestById => return self.received_request_by_id_on(id, &frame),
            FrameType::Ack => {
                if let (Some(wire), Some(conversation)) = (wire, self.conversation_of(id)) {
                    self.acknowledged(id, &conversation, wire);
                }
                return;
            }
            FrameType::Profile => return self.received_profile(id, frame.fields),
            FrameType::Request => return self.received_request(id, &frame),
            _ => {}
        }
        // Everything else comes from someone in the list, never from a stranger's request session.
        let Some(conversation) = self.conversation_of(id) else { return };
        let Some(person) = self.store.person_with_conversation(&conversation).ok().flatten() else { return };
        if person.relation == Relation::Blocked {
            return;
        }
        let Some(wire) = wire else { return };
        match frame.frame_type {
            FrameType::Accept | FrameType::Decline => self.received_answer(id, &frame, person, &wire),
            FrameType::Cancel => self.received_cancel(id, person, &wire),
            FrameType::Message if person.relation == Relation::Friend => self.message(id, &frame, &conversation, wire),
            FrameType::Offer if person.relation == Relation::Friend => self.offer(id, &frame, &conversation, wire),
            FrameType::OfferReply => self.offer_reply(id, &frame, wire),
            FrameType::PresenceSecret => self.received_presence_secret(id, &frame, person, &wire),
            FrameType::Chunk => self.chunk(id, &frame, &conversation, wire),
            FrameType::Progress => self.progress(id, &frame, wire),
            FrameType::Done => self.done(id, &frame, &conversation, wire),
            FrameType::Hashes | FrameType::Want | FrameType::Part | FrameType::Have
                if person.relation == Relation::Friend =>
            {
                self.block_frame(id, &frame, &conversation)
            }
            FrameType::Boost if person.relation == Relation::Friend => self.boost_frame(id, &frame),
            _ => {}
        }
    }

    /// A friend's session, or one with another of our devices (as the Mac helper's `-linkIsWithFriend:`): neither has
    /// a stranger's limits. A sync session is often quiet for minutes, and closing it would drop a relayed one before
    /// it could move to a direct connection.
    fn session_is_with_friend(&self, id: u64) -> bool {
        let Some(session) = self.sessions.map.get(&id) else { return false };
        if session.channel.pattern() == Pattern::NN {
            return false;
        }
        if session.channel.pattern() == Pattern::IK
            && session.channel.remote_identity().is_some_and(|k| self.is_own_device(k))
        {
            return true;
        }
        let person =
            session.conversation.as_deref().and_then(|c| self.store.person_with_conversation(c).ok().flatten());
        person.is_some_and(|p| p.relation == Relation::Friend)
    }

    /// What moves a request forward restarts a stranger's idle clock: the first PROFILE, REQUEST and answer, an ACK
    /// of something this session sent. Repeating a frame does not.
    fn note_frame(&mut self, id: u64, frame: &Frame) {
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        let meta = &mut session.meta;
        let advances = match frame.frame_type {
            FrameType::Profile => !std::mem::replace(&mut meta.profile_received, true),
            FrameType::Request => !std::mem::replace(&mut meta.request_received, true),
            FrameType::Accept | FrameType::Decline => !std::mem::replace(&mut meta.answer_received, true),
            FrameType::Ack => frame.get(tag::ID).is_some_and(|w| session.expecting.contains_key(&hex(w))),
            _ => false,
        };
        if advances {
            session.meta.last_frame_at = Some(unix_now());
        }
    }

    fn received_profile(&mut self, id: u64, fields: Fields) {
        let person = self.conversation_of(id).and_then(|c| self.store.person_with_conversation(&c).ok().flatten());
        let Some(mut person) = person else {
            // A stranger's request session: kept for the REQUEST that follows.
            if let Some(s) = self.sessions.map.get_mut(&id) {
                s.meta.pending_profile = Some(fields);
            }
            return;
        };
        if !matches!(person.relation, Relation::Friend | Relation::IncomingRequest | Relation::OutgoingRequest) {
            return;
        }
        self.update_person_with_profile(&mut person, &fields);
        if self.store.save_person(&person).is_ok() {
            self.changed();
        }
    }

    /// Name and Friends ID from PROFILE fields, cleaned and checked; not saved.
    pub(crate) fn update_person_with_profile(&self, person: &mut Person, fields: &Fields) {
        person.name = clean_name(fields.get(&tag::NAME).map(Vec::as_slice));
        let typed = fields.get(&tag::FRIENDS_ID).and_then(|b| std::str::from_utf8(b).ok());
        let list = szfriends_identity::friends_id::WordList::bundled();
        if let Some(id) = typed.and_then(|t| list.and_then(|l| l.normalized_id(t))) {
            person.friends_id = Some(id);
        }
    }

    fn received_request(&mut self, id: u64, frame: &Frame) {
        let Some(wire) = frame.get(tag::ID).map(<[u8]>::to_vec) else { return };
        let Some(session) = self.sessions.map.get(&id) else { return };
        let Some(key) = session.channel.remote_identity().copied() else { return };
        let presented_static = session.channel.remote_static().copied();
        let mut person = match session.conversation.clone() {
            Some(conversation) => self.store.person_with_conversation(&conversation).ok().flatten(),
            None => self.store.person_with_identity_key(&key).ok().flatten(),
        };
        // Another computer of someone already in the list, whose chain came first: the same person.
        let first_contact = self.first_contact_root(id);
        if let (None, Some((_, root, _))) = (&person, &first_contact) {
            person = self.store.person_with_identity_key(root).ok().flatten();
        }
        let now = unix_now();
        match person {
            Some(p) if p.relation == Relation::Blocked => {} // dropped; blocked people cannot ask
            Some(p) if p.relation == Relation::Friend => {
                // Still a friend here: they removed us, which we are never told, and ask again (PROTOCOL.md
                // remove_friend), or they repeat a request we accepted. Either way they wait for an answer: it is an
                // acceptance, as accept_request sends, and the conversation goes on. Queued before the ACK.
                let _ = self.store.ensure_own_presence_secret();
                if !self.queue_answer(&p.conversation_id, serde_json::json!({"frame": "accept"})) {
                    return; // no ACK: the requester's outbox tries again
                }
                self.queue_presence_secret(&p.conversation_id);
                self.send_ack(id, &wire);
                self.attach_if_unattached(id, &p.conversation_id);
                self.deliver_acceptance_then_resend(id, &p.conversation_id);
                self.changed();
            }
            Some(mut p) if p.relation == Relation::IncomingRequest => {
                // The same request again: one row, back at the top; its code is never replaced.
                p.request_at = Some(now);
                p.last_interaction_at = now;
                if self.store.save_person(&p).is_err() {
                    return; // no ACK: the requester's outbox tries again
                }
                self.send_ack(id, &wire);
                self.attach_if_unattached(id, &p.conversation_id);
                self.run_code_exchange(id);
                self.changed();
            }
            Some(mut p) if p.relation == Relation::OutgoingRequest => {
                // We asked them too: two requests are two acceptances.
                p.relation = Relation::Friend;
                p.last_interaction_at = now;
                if self.store.save_person(&p).is_err() {
                    return;
                }
                let _ = self.store.record_event(&p.conversation_id, event::NOW_FRIENDS);
                let _ = self.store.ensure_own_presence_secret();
                self.queue_answer(&p.conversation_id, serde_json::json!({"frame": "accept"}));
                self.queue_presence_secret(&p.conversation_id);
                self.finish_request(id, &wire, &p.conversation_id);
            }
            existing => {
                let mut p = existing.unwrap_or_else(|| Person::new(Relation::IncomingRequest));
                // A computer other than their first sent its chain first: the person is its root, dialed at their
                // first computer.
                let first = first_contact.filter(|_| p.identity_key.is_none());
                p.identity_key = Some(first.as_ref().map_or(key, |(_, root, _)| *root));
                if p.static_key.is_none() {
                    p.static_key = first.as_ref().map_or(presented_static, |(_, _, root_static)| Some(*root_static));
                }
                p.relation = Relation::IncomingRequest;
                p.request_at = Some(now);
                p.request_found_nearby = true; // XX on a public entry: they found us nearby
                p.last_interaction_at = now;
                p.comparison_code = None; // a new request gets its own code, exchanged once it is stored
                let pending = self.sessions.map.get_mut(&id).and_then(|s| s.meta.pending_profile.take());
                if let Some(fields) = pending {
                    self.update_person_with_profile(&mut p, &fields);
                }
                if let Err(error) = self.store.save_person(&p) {
                    crate::log!("could not store a friend request: {error}");
                    return;
                }
                if let Some((chain, root, _)) = first {
                    let conn = self.store.connection();
                    let _ = szfriends_core::store::devices::merge_friend_chain(conn, chain.encoded(), &root);
                }
                self.finish_request(id, &wire, &p.conversation_id);
            }
        }
    }

    fn finish_request(&mut self, id: u64, wire: &[u8], conversation: &str) {
        self.send_ack(id, wire);
        self.attach_if_unattached(id, conversation);
        // Only now, with the request durable and listed, does this side commit to a code: each attempt at matching
        // codes is a request the person sees.
        self.run_code_exchange(id);
        self.people_changed();
    }

    /// What this session wrote before their REQUEST arrived reached someone still waiting for our answer, who drops
    /// it unacknowledged. The acceptance goes first, then those entries again, with the same ids (repeats are
    /// recognised).
    fn deliver_acceptance_then_resend(&mut self, id: u64, conversation: &str) {
        let dropped: Vec<String> =
            self.sessions.map.get(&id).map(|s| s.in_flight.iter().cloned().collect()).unwrap_or_default();
        self.deliver_to(conversation);
        if let Some(session) = self.sessions.map.get_mut(&id) {
            for entry in &dropped {
                session.in_flight.remove(entry);
            }
        }
        for entry in &dropped {
            let _ = self.store.apply_outbox_event(entry, OutboxEvent::SessionLost);
        }
        self.deliver_to(conversation);
    }

    fn attach_if_unattached(&mut self, id: u64, conversation: &str) {
        if self.sessions.map.get(&id).is_some_and(|s| s.conversation.is_none() || !s.meta.adopted) {
            self.attach(id, conversation);
        }
    }

    /// Our request (or Add by ID) reached them: its outbox entries are delivered.
    pub(crate) fn acknowledge_request_entries(&mut self, conversation: &str) {
        for entry in self.store.pending_outbox(conversation).unwrap_or_default() {
            if entry.kind == OutboxKind::Request {
                let _ = self.store.apply_outbox_event(&entry.entry_id, OutboxEvent::Acknowledged);
            }
        }
    }

    fn received_answer(&mut self, id: u64, frame: &Frame, mut person: Person, wire: &str) {
        let accepted = frame.frame_type == FrameType::Accept;
        let session = &self.sessions.map[&id];
        let callback = session.channel.presented_token().is_some();
        let unconfirmed = callback && !session.meta.answer_attested && !person.friends_id_confirmed;
        let bytes = super::super::unhex(wire).unwrap_or_default();
        if person.relation == Relation::OutgoingRequest && accepted && unconfirmed {
            // An ACCEPT on our Add by ID's callback that no host vouched for: anyone nearby who heard the broadcast
            // could have sent it, so it becomes a request the person accepts (ADR 0004 Review amendments, 11).
            let now = unix_now();
            person.relation = Relation::IncomingRequest;
            person.unconfirmed_answer_id = session.meta.answer_for_id.clone();
            person.request_at = Some(now);
            person.request_found_nearby = false;
            person.last_interaction_at = now;
            if self.store.save_person(&person).is_err() {
                return; // no ACK: their outbox sends the answer again
            }
            self.acknowledge_request_entries(&person.conversation_id);
            self.send_ack(id, &bytes);
            self.rebuild_matcher();
            self.refresh_advertisement();
            return self.changed();
        }
        if person.relation == Relation::OutgoingRequest {
            person.relation = if accepted { Relation::Friend } else { Relation::Removed };
            if accepted {
                person.last_interaction_at = unix_now();
            }
            if self.store.save_person(&person).is_err() {
                return;
            }
            self.acknowledge_request_entries(&person.conversation_id);
            if accepted {
                let _ = self.store.record_event(&person.conversation_id, event::NOW_FRIENDS);
                let _ = self.store.ensure_own_presence_secret();
                self.queue_presence_secret(&person.conversation_id);
            }
            // The ACK first: the answer is committed, and a decline ends this session right after.
            self.send_ack(id, &bytes);
            self.rebuild_matcher();
            self.refresh_advertisement();
            self.deliver_pending(id);
            if !accepted {
                self.close_links_people_left();
            }
            return self.changed();
        }
        self.send_ack(id, &bytes);
        if accepted && person.relation == Relation::Friend {
            // They accept someone already our friend: they had removed us and asked again by Friends ID, and took our
            // acceptance, which no host vouched for, as a request to accept. What this session wrote before reached
            // them as a stranger and was dropped unacknowledged: it goes again, with the same ids.
            let conversation = person.conversation_id.clone();
            self.deliver_acceptance_then_resend(id, &conversation);
            return self.changed();
        }
        self.deliver_pending(id);
        self.changed();
    }

    fn received_cancel(&mut self, id: u64, mut person: Person, wire: &str) {
        let conversation = person.conversation_id.clone();
        let transfer = self.store.transfer(wire).ok().flatten().filter(|t| t.conversation_id == conversation);
        if transfer.is_some() {
            self.cancelled(&conversation, wire);
        } else if person.relation == Relation::IncomingRequest {
            // They withdrew their request; either side may ask again later. Acknowledged before their session ends.
            person.relation = Relation::Removed;
            if self.store.save_person(&person).is_ok() {
                self.send_ack(id, &super::super::unhex(wire).unwrap_or_default());
                return self.people_changed();
            }
        }
        self.send_ack(id, &super::super::unhex(wire).unwrap_or_default());
        self.changed();
    }

    fn received_presence_secret(&mut self, id: u64, frame: &Frame, mut person: Person, wire: &str) {
        let Some(secret) = frame.get(tag::SECRET).and_then(|s| <[u8; 32]>::try_from(s).ok()) else { return };
        if person.relation == Relation::Friend && person.presence_secret != Some(secret) {
            person.presence_secret = Some(secret);
            if self.store.save_person(&person).is_err() {
                return;
            }
            self.rebuild_matcher();
        }
        self.send_ack(id, &super::super::unhex(wire).unwrap_or_default());
    }

    /// Queues our presence secret for a friend; the session fills in the current one.
    pub(crate) fn queue_presence_secret(&mut self, conversation: &str) {
        self.queue_entry(conversation, OutboxKind::PresenceSecret, None);
    }

    /// Strangers' sessions end after a quiet minute and after three minutes in all; scheduled closes happen; the
    /// listeners' first-message deadlines pass; a full strangers' cap makes room.
    pub(crate) fn enforce_limits(&mut self, now: f64) {
        let overdue = self.nearby.admission.lock().unwrap_or_else(|e| e.into_inner()).overdue(now);
        for id in overdue {
            self.close(id, CloseReason::Normal);
        }
        let make_room = std::mem::take(&mut self.nearby.policy.lock().unwrap_or_else(|e| e.into_inner()).make_room);
        let ids: Vec<u64> = self.sessions.map.keys().copied().collect();
        let mut idlest: Option<(u64, f64)> = None;
        for id in ids {
            let with_friend = self.session_is_with_friend(id);
            let Some(session) = self.sessions.map.get_mut(&id) else { continue };
            if session.channel.is_closed() {
                continue;
            }
            if session.meta.close_at.is_some_and(|at| at <= now) {
                session.meta.close_at = None;
                self.close(id, CloseReason::Normal);
                continue;
            }
            // Friends' sessions have no idle limit; anyone else's ends after a quiet minute or three minutes in all.
            if !session.meta.live || with_friend {
                continue;
            }
            let since = session.meta.last_frame_at.or(session.meta.live_at).unwrap_or(session.meta.created_at);
            let born = session.meta.live_at.unwrap_or(session.meta.created_at);
            if session.meta.stranger && idlest.is_none_or(|(_, at)| since < at) {
                idlest = Some((id, since));
            }
            if now - since >= STRANGER_IDLE_SECONDS || now - born >= STRANGER_SESSION_LIFE_SECONDS {
                self.close(id, CloseReason::Normal);
            }
        }
        if make_room {
            if let Some((id, _)) = idlest {
                self.close(id, CloseReason::Normal);
            }
        }
        self.connecting_timed_out(now);
    }

    /// After the policy ran inside a session's bytes: who it marked a stranger is kept on the session.
    pub(crate) fn after_policy(&mut self) {
        let marked: Vec<u64> =
            self.nearby.policy.lock().unwrap_or_else(|e| e.into_inner()).strangers.iter().copied().collect();
        for id in marked {
            if let Some(s) = self.sessions.map.get_mut(&id) {
                s.meta.stranger = true;
            }
        }
    }
}
