//! Sessions with nearby devices (`SZFriendsNearbyService+Sessions.m`, `SZFriendsPeerLink.h`): accepted and dialed
//! links, what each is for, which conversation it belongs to once live, the session race (ADR 0001 § Session race),
//! and what happens when one ends.

use crate::nearby::stream::LinkStream;

use szfriends_core::nearby::Method;
use szfriends_core::session::{monotonic_now, ChannelIdentity, SecureChannel, SessionError};
use szfriends_core::store::{unix_now, OutboxEvent, Relation};
use szfriends_core::wire::route::session_a_wins;
use szfriends_core::wire::{CloseReason, Fields, Pattern, RouteMethod};

use super::policy::{key_policy, Hooks};
use crate::service::State;

/// Why a link exists (`SZFriendsLinkPurpose`). A responder link starts Incoming and its handshake says the rest.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Purpose {
    #[default]
    Incoming,
    /// IK to a known person: a friend, or a request in either direction.
    Friend,
    /// XX to a public entry, stopping after its profile.
    Browse,
    /// XX to a public entry, to deliver a friend request.
    Request,
    /// NN carrying one Add by ID request.
    ById,
    /// NN from a new computer: its join request, or a run of the code it was shown.
    Join,
    /// IK to another of our own devices, to sync.
    OwnDevice,
}

/// What the service tracks of one session beside its channel (`SZFriendsPeerLink`).
#[derive(Clone, Debug, Default)]
pub struct LinkMeta {
    pub purpose: Purpose,
    pub dialed_route: RouteMethod,
    pub endpoint: Option<(Method, String)>,
    pub public_entry: bool,
    pub probe: bool,
    pub dial_key: Option<String>,
    pub request_token: Option<[u8; 16]>,
    pub attempt_key: Option<String>,
    pub live: bool,
    pub live_at: Option<f64>,
    pub created_at: f64,
    pub adopted: bool,
    pub superseded: bool,
    pub creates_friendship: bool,
    pub code_started: bool,
    pub comparison_code: Option<String>,
    /// Admitted as someone who is not a friend; counted against the strangers' cap.
    pub stranger: bool,
    /// Let in by our Add by ID token alone: carries friendship creation only until they are a friend.
    pub token_admitted: bool,
    pub answer_for_id: Option<String>,
    pub answer_attested: bool,
    pub by_id_answered: bool,
    /// When the session last moved a request forward (or went live): strangers' idle limit.
    pub last_frame_at: Option<f64>,
    pub profile_received: bool,
    pub request_received: bool,
    pub answer_received: bool,
    /// A stranger's PROFILE before their REQUEST names them.
    pub pending_profile: Option<Fields>,
    /// A close scheduled at this Unix time (an NN session's linger and life).
    pub close_at: Option<f64>,
    /// The listener's admission place, by this session's id.
    pub admitted: bool,
    /// First contact (chain.rs): our chain went before a request or an answer; theirs came before their request.
    pub first_contact_chain_sent: bool,
    /// Our chain went to the friend on this session.
    pub chain_sent: bool,
    pub pending_chain: Option<szfriends_core::identity::chain::DeviceChain>,
}

impl LinkMeta {
    fn race_route(&self, channel: &SecureChannel) -> RouteMethod {
        if channel.is_established() {
            channel.initiator_route()
        } else {
            self.dialed_route
        }
    }
}

/// Whether an end says something about reaching this person rather than a decision (the race, our own close).
fn end_counts(error: Option<&SessionError>) -> bool {
    match error {
        None => false,
        Some(SessionError::PeerClosed(reason)) => {
            *reason != CloseReason::Superseded as u8 && *reason != CloseReason::Expired as u8
        }
        Some(SessionError::Expired) => false,
        Some(_) => true,
    }
}

impl State {
    /// A connection on a listener: a responder whose public profile is served only on the public entry while the 5
    /// minutes last, behind the key policy and the listener's admission limits.
    pub(crate) fn accept_stream(
        &mut self,
        stream: LinkStream,
        route: RouteMethod,
        public: bool,
        listener: &str,
        address: Option<&str>,
    ) {
        if self.nearby.shut_down {
            return;
        }
        let visible = public && self.nearby.visibility.is_visible(szfriends_core::nearby::visibility::Instant::now());
        let profile = visible.then(|| self.profile_fields());
        let id = self.reserve_session_id();
        let policy = key_policy(self.nearby.policy.clone(), id, visible);
        let mut channel = SecureChannel::responder(ChannelIdentity::new(&self.identity), profile, policy);
        channel.set_listener_hooks(Box::new(Hooks { admission: self.nearby.admission.clone(), connection: id }));
        let evicted =
            self.nearby.admission.lock().unwrap_or_else(|e| e.into_inner()).admit(id, listener, address, unix_now());
        for old in evicted {
            self.close(old, CloseReason::Normal);
        }
        let meta = LinkMeta {
            purpose: Purpose::Incoming,
            dialed_route: route,
            public_entry: visible,
            created_at: unix_now(),
            admitted: true,
            ..LinkMeta::default()
        };
        self.adopt_session_id(id, channel, stream, meta);
    }

    /// A dial's stream arrived (or did not).
    pub(crate) fn dialed(&mut self, dial: u64, stream: Option<LinkStream>) {
        let Some(plan) = self.nearby.dials.remove(&dial) else { return };
        let Some(stream) = stream.filter(|_| !self.nearby.shut_down) else {
            self.nearby.dialing.remove(&plan.dial_key);
            self.dial_failed(&plan);
            return;
        };
        let mut channel = SecureChannel::initiator(ChannelIdentity::new(&self.identity), plan.options.clone());
        if plan.options.request_token.is_some() {
            // Answering their Add by ID: the host's word that we hold the ID they asked for, beside our certificate.
            channel.set_local_attestation(self.attestation_for_our_answer());
        }
        let personal = matches!(plan.purpose, Purpose::Friend | Purpose::Request);
        let meta = LinkMeta {
            purpose: plan.purpose,
            dialed_route: plan.route,
            endpoint: Some((plan.method, plan.endpoint.clone())),
            probe: plan.probe,
            dial_key: Some(plan.dial_key.clone()),
            request_token: plan.request_token,
            attempt_key: plan.attempt_key.clone(),
            created_at: unix_now(),
            // The session that creates a friendship runs the code exchange: our XX request, or our IK callback.
            creates_friendship: plan.purpose == Purpose::Request
                || (plan.purpose == Purpose::Friend && plan.options.request_token.is_some()),
            ..LinkMeta::default()
        };
        let id = self.reserve_session_id();
        if plan.purpose == Purpose::Browse {
            // Browsing ends before message 3 would reveal who we are; what the entry served is kept for when the
            // channel closes (`browsed`).
            let browsed = self.nearby.browsed.clone();
            channel.set_profile_decision(Box::new(move |fields: &Fields| {
                browsed.lock().unwrap_or_else(|e| e.into_inner()).insert(id, fields.clone());
                false
            }));
        }
        if self.adopt_session_id(id, channel, stream, meta).is_none() {
            self.nearby.dialing.remove(&plan.dial_key);
            return;
        }
        if let Some(s) = self.sessions.map.get_mut(&id) {
            s.conversation = if personal { plan.conversation.clone() } else { None };
        }
    }

    /// The handshake completed (initiator) or the initiator's HELLO arrived (responder).
    pub(crate) fn went_live(&mut self, id: u64) {
        let now = unix_now();
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        session.meta.live = true;
        session.meta.live_at = Some(now);
        session.meta.last_frame_at = Some(now);
        if let Some(key) = session.meta.dial_key.take() {
            self.nearby.dialing.remove(&key);
        }
        let session = self.sessions.map.get(&id).expect("looked up");
        let (initiator, pattern) = (session.channel.is_initiator(), session.channel.pattern());
        let meta = session.meta.clone();
        if initiator && meta.purpose == Purpose::Friend {
            if let (Some((method, endpoint)), Some(conversation)) = (&meta.endpoint, &session.conversation) {
                self.nearby.racer.note_succeeded(endpoint, *method, conversation);
            }
        }
        if pattern == Pattern::NN {
            if initiator && meta.purpose == Purpose::Join {
                self.join_leg_live(id);
            } else if initiator {
                self.send_request_by_id(id);
            } else {
                self.close_after(id, szfriends_core::nearby::limits::BY_ID_SESSION_LIFE_SECONDS);
            }
            return;
        }
        if self.chain_refuses_live(id) || self.own_device_live(id) {
            return; // a removed device (chain.rs), or another of our devices: sync (own.rs)
        }
        let session = self.sessions.map.get(&id).expect("looked up");
        let remote = session.channel.remote_identity().copied();
        let token = session.channel.presented_token().map(<[u8]>::to_vec);
        let mut conversation = session.conversation.clone();
        if initiator {
            // An XX request must reach the person whose public entry we browsed, not whoever answers there now.
            let person = conversation.as_deref().and_then(|c| self.store.person_with_conversation(c).ok().flatten());
            if meta.purpose == Purpose::Request && person.and_then(|p| p.identity_key) != remote {
                return self.close(id, CloseReason::Normal);
            }
        } else {
            let person = remote.and_then(|k| self.store.person_with_identity_key(&k).ok().flatten());
            conversation = person.as_ref().map(|p| p.conversation_id.clone());
            if token.is_some() {
                let Some(callback) = self.conversation_for_callback(id) else {
                    return self.close(id, CloseReason::Normal);
                };
                conversation = Some(callback.clone());
                // They call back with our token, so the request reached them.
                self.acknowledge_request_entries(&callback);
                let s = self.sessions.map.get_mut(&id).expect("live");
                s.meta.creates_friendship = true;
                s.meta.token_admitted = person.as_ref().is_none_or(|p| p.relation == Relation::Removed);
            }
            // XX completed on a public entry is a friend request; its session creates the friendship.
            if pattern == Pattern::XX && person.as_ref().is_none_or(|p| p.relation != Relation::Friend) {
                self.sessions.map.get_mut(&id).expect("live").meta.creates_friendship = true;
            }
        }
        let Some(conversation) = conversation else { return }; // a stranger's request: REQUEST says who they are
        if self.key_changed(id, &conversation) {
            return;
        }
        self.attach(id, &conversation);
        self.send_chain_to_friend(id);
        // A responder commits to a code only once the friendship's first step is durable (an XX request after its
        // REQUEST is stored); everyone else starts now.
        if initiator || pattern != Pattern::XX {
            self.run_code_exchange(id);
        }
        if token.is_some() || (initiator && meta.request_token.is_some()) {
            self.refresh_advertisement();
            self.changed();
        }
    }

    /// A known person presenting another static key: never accepted silently; marked for review and closed.
    fn key_changed(&mut self, id: u64, conversation: &str) -> bool {
        let Some(mut person) = self.store.person_with_conversation(conversation).ok().flatten() else { return false };
        let Some(presented) = self.sessions.map.get(&id).and_then(|s| s.channel.remote_static().copied()) else {
            return false;
        };
        // Another of their computers has its own static key in their chain: one that differs is refused, not reviewed.
        if let Some(matches) = self.other_device_static_matches(&person, id) {
            if !matches {
                self.close(id, CloseReason::Normal);
            }
            return !matches;
        }
        match person.static_key {
            None => {
                person.static_key = Some(presented);
                let _ = self.store.save_person(&person);
                false
            }
            Some(known) if known == presented => false,
            Some(_) => {
                if !person.key_change_pending {
                    person.key_change_pending = true;
                    let _ = self.store.save_person(&person);
                    let _ = self.store.record_event(conversation, szfriends_core::store::requests::event::KEY_CHANGED);
                }
                self.close(id, CloseReason::Normal);
                self.changed();
                true
            }
        }
    }

    pub(crate) fn run_code_exchange(&mut self, id: u64) {
        let Some(session) = self.sessions.map.get(&id) else { return };
        if !session.meta.creates_friendship || session.meta.code_started || session.channel.is_closed() {
            return;
        }
        let Some(conversation) = session.conversation.clone() else { return };
        // A stored code is never replaced: every attempt at steering the codes leaves a request row of its own.
        let person = self.store.person_with_conversation(&conversation).ok().flatten();
        if person.is_none_or(|p| p.comparison_code.is_some()) {
            return;
        }
        let session = self.sessions.map.get_mut(&id).expect("looked up");
        session.meta.code_started = true;
        session.channel.run_code_exchange(monotonic_now());
    }

    pub(crate) fn code_finished(&mut self, id: u64, result: Result<String, SessionError>) {
        let Ok(code) = result else { return };
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        session.meta.comparison_code = Some(code);
        self.store_comparison_code(id);
    }

    pub(crate) fn store_comparison_code(&mut self, id: u64) {
        let Some(session) = self.sessions.map.get(&id) else { return };
        let (Some(code), Some(conversation)) = (session.meta.comparison_code.clone(), session.conversation.clone())
        else {
            return;
        };
        let Some(mut person) = self.store.person_with_conversation(&conversation).ok().flatten() else { return };
        if person.comparison_code.is_none() {
            person.comparison_code = Some(code);
            let _ = self.store.save_person(&person);
            self.changed();
        }
    }

    /// The link now belongs to this conversation: adopt it, or settle the race with the one carrying it.
    pub(crate) fn attach(&mut self, id: u64, conversation: &str) {
        if let Some(s) = self.sessions.map.get_mut(&id) {
            s.conversation = Some(conversation.to_owned());
        }
        let Some(current) = self.sessions.live_for(conversation).filter(|c| *c != id) else {
            return self.adopt(id);
        };
        let own = self.identity.public_key();
        let initiator_key = |state: &State, link: u64| -> (RouteMethod, Vec<u8>) {
            let s = &state.sessions.map[&link];
            let key = if s.channel.is_initiator() { Some(own) } else { s.channel.remote_identity().copied() };
            (s.meta.race_route(&s.channel), key.map(|k| k.to_vec()).unwrap_or_default())
        };
        let (new_route, new_key) = initiator_key(self, id);
        let (old_route, old_key) = initiator_key(self, current);
        if new_route == old_route && new_key == old_key {
            // One side dialed twice on one class: only that initiator acts, keeping the one carrying traffic.
            if self.sessions.map[&id].channel.is_initiator() {
                self.supersede(id);
            }
            return;
        }
        if session_a_wins(new_route as u8, &new_key, old_route as u8, &old_key) {
            self.supersede(current);
            self.adopt(id);
        } else {
            self.supersede(id);
        }
    }

    fn adopt(&mut self, id: u64) {
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        session.meta.adopted = true;
        let Some(conversation) = session.conversation.clone() else { return };
        self.nearby.failures.remove(&conversation);
        self.nearby.retry_after.remove(&conversation);
        self.send_profile(id);
        self.store_comparison_code(id);
        // Resume and route migration are one mechanism: unfinished downloads announce their durable offsets.
        self.resume_incoming(id, &conversation);
        self.deliver_pending(id);
        self.changed();
    }

    /// The race's loser closes after what it queued; its transfers stop, durable first.
    fn supersede(&mut self, id: u64) {
        let _ = self.store.flush_progress();
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        session.meta.superseded = true;
        session.meta.adopted = false;
        session.senders.clear();
        session.receivers.clear();
        self.close(id, CloseReason::Superseded);
    }

    /// A session ended: what it had in flight goes back to Queued; failures count against the person's backoff.
    pub(crate) fn closed(&mut self, id: u64, error: Option<SessionError>) {
        let _ = self.store.flush_progress();
        self.nearby.admission.lock().unwrap_or_else(|e| e.into_inner()).release(id);
        self.nearby.policy.lock().unwrap_or_else(|e| e.into_inner()).strangers.remove(&id);
        self.session_closed_elsewhere(id);
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        for entry in session.in_flight.drain() {
            let _ = self.store.apply_outbox_event(&entry, OutboxEvent::SessionLost);
        }
        session.senders.clear();
        session.receivers.clear();
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
        if initiator && meta.purpose == Purpose::Friend && !meta.live && error.is_some() {
            if let (Some((method, endpoint)), Some(conversation)) = (&meta.endpoint, &conversation) {
                self.nearby.racer.note_failed(endpoint, *method, conversation, unix_now());
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

fn log_end(meta: &LinkMeta, error: &SessionError) {
    crate::log!(
        "session ended (purpose {:?}, route {:?}, {}): {}",
        meta.purpose,
        meta.dialed_route,
        if meta.live { "live" } else { "handshaking" },
        error.code()
    );
}
