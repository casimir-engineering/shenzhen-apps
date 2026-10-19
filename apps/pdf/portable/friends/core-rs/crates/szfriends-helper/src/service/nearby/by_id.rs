//! Add by ID nearby (`SZFriendsNearbyService+RequestByID.m`, ADR 0004 § Add by ID nearby): the requester's NN session
//! to every device, the uniform RECEIVED every device answers with, the holder's request row, and the IK callback that
//! presents the requester's token.
//!
//! Anyone who hears the broadcast can answer it, so at most three distinct keys may answer one request (the last only
//! with the host's attestation), each becomes its own unverified person, a session let in by the token alone carries
//! friendship creation only, and the callback secret behind the advertised tags changes every day. An answer showing
//! the host's attestation for the ID asked for is the holder's (an accepted one makes a friend at once); any other
//! becomes a request the person accepts; one showing another key's attestation is refused. Our own answers show ours
//! (`service/online_attestation.rs`). The key policy, which sees no attestation, gives the last slot to nobody.

use szfriends_core::identity::request_by_id;
use szfriends_core::nearby::callbacks::{callback_day, callback_secret_for_day, PendingCallback};
use szfriends_core::nearby::limits::{
    BY_ID_REPLY_LINGER_SECONDS, BY_ID_SENDER_INTERVAL_SECONDS, BY_ID_SESSION_LIFE_SECONDS, CALLBACK_DAY_SECONDS,
};
use szfriends_core::presentation::facts::event::{ADDED_THROUGH_OUR_LINK, ADDED_THROUGH_THEIR_LINK};
use szfriends_core::store::requests::event;
use szfriends_core::store::{unix_now, Person, Relation};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType};

use crate::service::State;

/// What an Add by ID answer's attestation says (`SZFriendsAnswerAttestation`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AnswerAttestation {
    Unattested,
    /// The host's word that this key holds the ID we asked for: kept with the person.
    Attested {
        friends_id: String,
        encoded: Vec<u8>,
        day: String,
    },
    /// Another key's attestation: a copy, never an honest mistake.
    Refused,
}

impl State {
    /// The callback secrets to advertise now: requests nobody answered yet, each with today's secret and when it
    /// last went out. Only in memory: after a restart nothing is advertised until the next broadcast.
    pub(crate) fn advertised_callbacks(&self, now: f64) -> Vec<PendingCallback> {
        let mut callbacks = Vec::new();
        for request in self.store.pending_id_requests(now) {
            let day = callback_day(request.created_at, now);
            let day_start = (request.created_at + day as f64 * CALLBACK_DAY_SECONDS).min(now);
            // A broadcast on an earlier day carried an earlier secret: today's tags wait for today's first one.
            let broadcast = self
                .nearby
                .callback_broadcasts
                .get(&request.request_token)
                .copied()
                .filter(|at| callback_day(request.created_at, *at) == day);
            let Some(secret) = callback_secret_for_day(&request.callback_secret, day) else { continue };
            callbacks.push(PendingCallback {
                secret: secret.to_vec(),
                created_at: request.created_at,
                expires_at: request.expires_at,
                secret_issued_at: day_start,
                last_broadcast_at: broadcast,
            });
        }
        callbacks
    }

    /// REQUEST_BY_ID for our pending request `token`, signed over this NN session's handshake hash, with today's
    /// callback secret; `None` once the request is no longer pending.
    fn request_by_id_frame(&self, token: &[u8; 16], h: &[u8]) -> Option<Frame> {
        let now = unix_now();
        let request = self.store.pending_id_requests(now).into_iter().find(|r| &r.request_token == token)?;
        let secret = callback_secret_for_day(&request.callback_secret, callback_day(request.created_at, now))?;
        let frame = request_by_id::make_frame(&self.identity, &request.target_friends_id, token, &secret, h)?;
        // From a friend link: its invite, bound to this session.
        Some(self.with_invite_proof(frame, &request.conversation_id, h))
    }

    /// The requester's NN session went live: the request goes, its callback tags go on the air for hours.
    pub(crate) fn send_request_by_id(&mut self, id: u64) {
        let Some(session) = self.sessions.map.get(&id) else { return };
        let (Some(token), Some(h)) = (session.meta.request_token, session.channel.handshake_hash().copied()) else {
            return self.close(id, CloseReason::Normal);
        };
        let sent = self.request_by_id_frame(&token, &h).is_some_and(|frame| self.send_on(id, &frame));
        if !sent {
            return self.close(id, CloseReason::Normal);
        }
        self.nearby.callback_broadcasts.insert(token, unix_now());
        self.refresh_advertisement();
        // RECEIVED closes it; a device that never answers is let go.
        self.close_after(id, BY_ID_SESSION_LIFE_SECONDS);
    }

    /// Every device: RECEIVED before any lookup or check, the same bytes from all, the session closed the same moment
    /// after, so neither content nor timing says whether this device holds the ID.
    pub(crate) fn received_request_by_id_on(&mut self, id: u64, frame: &Frame) {
        let Some(session) = self.sessions.map.get(&id) else { return };
        if session.channel.is_initiator() || session.channel.pattern() != szfriends_core::wire::Pattern::NN {
            return;
        }
        let h = session.channel.handshake_hash().copied();
        self.send_on(id, &Frame::new(FrameType::Received));
        self.close_after(id, BY_ID_REPLY_LINGER_SECONDS);
        if let Some(h) = h {
            self.received_request_by_id(frame, &h);
        }
    }

    /// The holder's side, once RECEIVED is on its way: only the holder keeps anything, and only from someone not
    /// blocked and not asking again within the hour.
    pub(crate) fn received_request_by_id(&mut self, frame: &Frame, h: &[u8]) {
        let Some(key) = request_by_id::verify_frame(frame, h).filter(|k| *k != self.identity.public_key()) else {
            return;
        };
        let typed = frame.text(tag::FRIENDS_ID);
        let list = szfriends_identity::friends_id::WordList::bundled();
        let target = typed.and_then(|t| list.and_then(|l| l.normalized_id(t)));
        let own = self.profile_facts().friends_id;
        if target.as_deref() != Some(own.as_str()) {
            return; // non-holders keep nothing
        }
        let now = unix_now();
        if self.nearby.by_id_senders.get(&key).is_some_and(|last| now - last < BY_ID_SENDER_INTERVAL_SECONDS) {
            return;
        }
        let existing = self.store.person_with_identity_key(&key).ok().flatten();
        if existing.as_ref().is_some_and(|p| matches!(p.relation, Relation::Blocked | Relation::Friend)) {
            return; // blocked senders are dropped after the same reply; friends need no request
        }
        self.nearby.by_id_senders.insert(key, now);
        let token = frame.get(tag::TOKEN).and_then(|t| <[u8; 16]>::try_from(t).ok());
        let callback = frame.get(tag::CALLBACK_SECRET).and_then(|s| <[u8; 32]>::try_from(s).ok());
        if let Some(mut asked) =
            existing.clone().filter(|p| p.relation == Relation::IncomingRequest && p.callback_token == token)
        {
            // The same request broadcast again on a later day: only its callback secret is new.
            asked.callback_secret = callback;
            if self.store.save_person(&asked).is_ok() {
                self.rebuild_matcher();
            }
            return;
        }
        let mutual = existing.as_ref().is_some_and(|p| p.relation == Relation::OutgoingRequest);
        // Made through our friend link: accepted at once, as a request we had sent them would make it.
        let invited = !mutual && self.request_uses_live_invite(frame, h);
        let asked_before = existing.as_ref().is_some_and(|p| p.relation == Relation::IncomingRequest);
        let mut person = existing.unwrap_or_else(|| Person::new(Relation::IncomingRequest));
        person.identity_key = Some(key);
        let static_key = frame.get(tag::STATIC_KEY).and_then(|s| <[u8; 32]>::try_from(s).ok());
        match person.static_key {
            Some(known) if Some(known) != static_key => {
                // Another static key certified by the same identity: kept for review, never swapped in.
                person.key_change_pending = true;
            }
            _ => person.static_key = static_key,
        }
        person.callback_token = token;
        person.callback_secret = callback;
        person.relation = if mutual || invited { Relation::Friend } else { Relation::IncomingRequest };
        if !mutual && !asked_before {
            person.comparison_code = None;
        }
        person.request_at = Some(now);
        person.request_found_nearby = false; // by Friends ID: the request card says so
        person.last_interaction_at = now;
        if let Err(error) = self.store.save_person(&person) {
            crate::log!("could not store a request by ID: {error}");
            return;
        }
        if mutual || invited {
            // We had asked them too, or invited them: two requests are two acceptances, and a link is our request.
            let kind = if invited { ADDED_THROUGH_OUR_LINK } else { event::NOW_FRIENDS };
            let _ = self.store.record_event(&person.conversation_id, kind);
            let _ = self.store.ensure_own_presence_secret();
            self.queue_answer(&person.conversation_id, serde_json::json!({"frame": "accept"}));
            self.queue_presence_secret(&person.conversation_id);
        }
        self.people_changed();
    }

    /// The IK callback after Add by ID presenting our token: which conversation it belongs to, decided and recorded
    /// by the store in one transaction. An answer is confirmed when the request named its key (a mention or a friend
    /// link) or when it shows the host's attestation for the ID we asked for.
    pub(crate) fn conversation_for_callback(&mut self, id: u64) -> Option<String> {
        let session = self.sessions.map.get(&id)?;
        let token = session.channel.presented_token()?.to_vec();
        let key = *session.channel.remote_identity()?;
        let static_key = *session.channel.remote_static()?;
        let presented = session.channel.remote_attestation().map(<[u8]>::to_vec);
        let now = unix_now();
        let request = self.store.id_request_with_token(&token, now);
        // A request from a mention or a friend link names the key that may answer: that key is who was asked for,
        // as a host's word would say, so its answer needs no further confirmation.
        let bound = request.as_ref().is_some_and(|r| {
            r.request_token == super::super::friend_links::mention_request_token(&r.callback_secret, &key)
        });
        let requested = request.map(|r| r.target_friends_id);
        let said = self.judge_answer(presented.as_deref(), requested.as_deref(), &key);
        if said == AnswerAttestation::Refused {
            crate::log!("an Add by ID answer showed another key's attestation; refused");
            return None;
        }
        let attested = matches!(said, AnswerAttestation::Attested { .. });
        let key_known = self.store.person_with_identity_key(&key).ok().flatten().is_some();
        let conversation = match self.store.conversation_for_id_answer(&token, key, static_key, attested, now) {
            Ok(conversation) => conversation,
            Err(error) => {
                crate::log!("an Add by ID answer was not admitted: {error}");
                return None;
            }
        };
        if let AnswerAttestation::Attested { friends_id, encoded, day } = &said {
            if let Err(error) = self.store.confirm_friends_id(&conversation, friends_id, encoded, day) {
                crate::log!("could not record a confirmed Friends ID: {error}");
            }
        } else if !key_known {
            // A new key's row carries the ID we typed: our guess at who would answer, not theirs. Unconfirmed, it
            // would read as this stranger's ID beside the holder's, so it goes; their own PROFILE may name one.
            if let Some(mut person) = self.store.person_with_conversation(&conversation).ok().flatten() {
                if !person.friends_id_confirmed && requested.is_some() && person.friends_id == requested {
                    person.friends_id = None;
                    let _ = self.store.save_person(&person);
                }
            }
        }
        if self.request_token_came_from_link(&token) {
            let _ = self.store.record_event(&conversation, ADDED_THROUGH_THEIR_LINK);
        }
        let session = self.sessions.map.get_mut(&id)?;
        session.meta.answer_for_id = requested;
        session.meta.answer_attested = bound || attested;
        Some(conversation)
    }
}
