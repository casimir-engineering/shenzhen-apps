//! Joining a profile nearby (`SZFriendsNearbyService+JoinNearby.m`, `+Join.m`; ADR 0013): the new computer's NN
//! sessions to every device it cannot recognise, as Add by ID's, carrying JOIN frames; every device's side of them;
//! and what the new computer keeps once a device that knew the code welcomed it.
//!
//! Every device answers a request alike (RECEIVED, unless this very device ended that request), so nobody nearby
//! learns which device holds the profile. Only a device holding an approval answers a code with more than RECEIVED,
//! and the new computer takes a profile only from the device that proved it knows the code.

use szfriends_core::identity::chain::DeviceChain;
use szfriends_core::identity::join::{self, EndReason, MessageKind, Receipt, Step};
use szfriends_core::nearby::callbacks::{window, window_end};
use szfriends_core::nearby::limits::{BY_ID_REPLY_LINGER_SECONDS, BY_ID_SESSION_LIFE_SECONDS};
use szfriends_core::nearby::merger::Candidate;
use szfriends_core::presentation::JoiningState;
use szfriends_core::session::HandshakeOptions;
use szfriends_core::store::sync_records::{self, Picture};
use szfriends_core::store::{devices, unix_now};
use szfriends_core::sync::{self, Fields};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType, Pattern};

use super::inbound::clean_name;
use super::Purpose;
use crate::log;
use crate::service::{hex, State};

/// How long a code's dial to one device is not repeated.
const CODE_ATTEMPT_SECONDS: f64 = 60.0;

/// The welcome's profile part: tag-length-value fields as sync's bodies encode them.
const WELCOME_PROFILE_FRAME: u8 = 1;
const WELCOME_PRESENCE_SECRET: u8 = 2;
const WELCOME_DEVICES_SECRET: u8 = 3;

pub(crate) fn join_frame(message: Vec<u8>) -> Frame {
    Frame::new(FrameType::Join).with(tag::JOIN, message)
}

impl State {
    /// One JOIN message on a leg: a nearby NN session, or a pipe through the host (`join_online.rs`).
    pub(crate) fn join_send(&mut self, id: u64, message: Vec<u8>) {
        if !self.devices.pipes.contains_key(&id) {
            self.send_on(id, &join_frame(message));
            return;
        }
        #[cfg(feature = "online")]
        if let Some(online) = &self.online {
            online.join_send(id, vec![message]);
        }
    }

    /// The answer every device gives nearby; online it is silence.
    fn join_received(&mut self, id: u64) {
        if !self.devices.pipes.contains_key(&id) {
            self.send_on(id, &Frame::new(FrameType::Received));
        }
    }

    pub(crate) fn join_close_after(&mut self, id: u64, seconds: f64) {
        if !self.devices.pipes.contains_key(&id) {
            return self.close_after(id, seconds);
        }
        #[cfg(feature = "online")]
        if let Some(online) = &self.online {
            online.join_close(id, seconds);
        }
    }

    pub(crate) fn join_close(&mut self, id: u64) {
        if !self.devices.pipes.contains_key(&id) {
            return self.close(id, CloseReason::Normal);
        }
        self.join_close_after(id, 0.0);
    }

    /// The handshake hash a leg's run is bound to.
    fn join_hash(&self, id: u64) -> Option<Vec<u8>> {
        match self.devices.pipes.get(&id) {
            Some(pipe) => (!pipe.hash.is_empty()).then(|| pipe.hash.clone()),
            None => self.sessions.map.get(&id).and_then(|s| s.channel.handshake_hash().map(|h| h.to_vec())),
        }
    }

    /// Like Add by ID: every device we cannot recognise, hidden or public, gets an NN session; the request once per
    /// presence window, each code once.
    pub(crate) fn offer_join_nearby(&mut self) {
        let phase = self.devices.phase;
        let Some(joiner) = &self.devices.joiner else { return };
        let code = phase == JoiningState::Checking;
        if !code && !matches!(phase, JoiningState::Waiting | JoiningState::WrongCode | JoiningState::NotReached) {
            return;
        }
        let request = hex(joiner.request_id());
        let generation = self.devices.generation;
        let mut devices: Vec<Candidate> = self.nearby.merger.unmatched().to_vec();
        devices.extend(
            self.nearby.merger.candidates().iter().filter(|c| c.conversation_id.is_none() && c.public).cloned(),
        );
        let now = unix_now();
        for device in devices {
            let Some(sighting) = device.sightings.first().cloned() else { continue };
            let key = if code {
                format!("joincode|{generation}|{}", sighting.endpoint)
            } else {
                format!("join|{request}|{}|{}", sighting.endpoint, window(now))
            };
            if self.nearby.attempts.contains_key(&key) {
                continue;
            }
            self.nearby.attempts.insert(key.clone(), if code { now + CODE_ATTEMPT_SECONDS } else { window_end(now) });
            let options = HandshakeOptions::new(Pattern::NN, sighting.route);
            let mut plan = self.plan(&sighting, Purpose::Join, options);
            plan.attempt_key = Some(key);
            self.dial(plan, 0.0);
        }
    }

    /// The new computer's NN session went live: the request, or a run of the code.
    pub(crate) fn join_leg_live(&mut self, id: u64) {
        self.close_after(id, BY_ID_SESSION_LIFE_SECONDS);
        let Some(session) = self.sessions.map.get(&id) else { return };
        let key = session.meta.attempt_key.clone().unwrap_or_default();
        let hash = session.channel.handshake_hash().copied();
        let area = &self.devices;
        let code_leg = format!("joincode|{}|", area.generation);
        if key.starts_with(&code_leg) {
            let attempt = match (&area.joiner, &area.code, hash) {
                (Some(joiner), Some(code), Some(hash)) if area.phase == JoiningState::Checking => {
                    joiner.attempt(code, &hash, None)
                }
                _ => None,
            };
            let Some(attempt) = attempt else { return self.close(id, CloseReason::Normal) };
            let message = attempt.code_message().to_vec();
            self.devices.attempts.insert(id, attempt);
            self.send_on(id, &join_frame(message));
            return;
        }
        let request = key.starts_with("join|").then(|| area.joiner.as_ref()?.request_message(unix_now())).flatten();
        match request {
            Some(message) => {
                self.send_on(id, &join_frame(message));
            }
            None => self.close(id, CloseReason::Normal),
        }
    }

    /// A JOIN frame on an NN session; `false` for any other session.
    pub(crate) fn join_frame_on(&mut self, id: u64, frame: &Frame) -> bool {
        let Some(session) = self.sessions.map.get(&id) else { return false };
        if session.channel.pattern() != Pattern::NN {
            return false;
        }
        let initiator = session.channel.is_initiator();
        let Some(message) = frame.get(tag::JOIN).map(<[u8]>::to_vec) else {
            self.close(id, CloseReason::Normal);
            return true;
        };
        if initiator {
            self.joining_message(id, &message);
        } else {
            self.approving_message(id, &message);
        }
        true
    }

    /// A new computer's request, nearby or through the host: a join row; the end of it when this device ended it.
    pub(crate) fn join_request_heard(&mut self, message: &[u8]) -> Option<Vec<u8>> {
        if join::message_kind(message) != Some(MessageKind::Request) {
            return None;
        }
        let chain = devices::own_chain(self.store.connection()).ok().flatten();
        let own = self.profile_facts().friends_id;
        let receipt = self.devices.approver.receive_request(message, Some(&own), chain.as_ref(), unix_now());
        if matches!(receipt, Receipt::Added | Receipt::Refreshed) {
            self.changed();
        }
        match receipt {
            Receipt::Ended(reason) => Some(join::ended_message(reason)),
            _ => None,
        }
    }

    /// A JOIN message on any leg: the new computer's side or every device's.
    #[cfg_attr(not(feature = "online"), allow(dead_code))]
    pub(crate) fn join_message_on_leg(&mut self, id: u64, message: &[u8], initiator: bool) {
        if initiator {
            self.joining_message(id, message);
        } else {
            self.approving_message(id, message);
        }
    }

    /// Every device's side: the same answer from all, unless this one ended that very request.
    fn approving_message(&mut self, id: u64, message: &[u8]) {
        let now = unix_now();
        let chain = devices::own_chain(self.store.connection()).ok().flatten();
        let reply = match join::message_kind(message) {
            Some(MessageKind::Request) => self.join_request_heard(message),
            Some(MessageKind::Code) => {
                let hash = self.join_hash(id);
                let approval = match (&chain, hash) {
                    (Some(chain), Some(hash)) => {
                        self.devices.approver.approval(message, &hash, chain.root_key(), now, None)
                    }
                    _ => Err(None),
                };
                self.changed();
                match approval {
                    Ok(approval) => {
                        let reply = approval.reply_message.clone();
                        self.devices.approvals.insert(id, approval);
                        self.join_send(id, reply);
                        return;
                    }
                    Err(reason) => reason.map(join::ended_message),
                }
            }
            Some(MessageKind::Confirm) => return self.approving_confirmed(id, message, chain, now),
            _ => return self.join_close(id),
        };
        match reply {
            Some(ended) => self.join_send(id, ended),
            None => self.join_received(id),
        };
        self.join_close_after(id, BY_ID_REPLY_LINGER_SECONDS);
    }

    /// The new computer proved the code: the chain gains it, is stored, and goes to it with the welcome.
    fn approving_confirmed(&mut self, id: u64, message: &[u8], chain: Option<DeviceChain>, now: f64) {
        let approval = self.devices.approvals.remove(&id);
        let profile = self.welcome_profile();
        let state = match sync_records::profile_value(self.store.connection(), "friends_id_state") {
            Ok(rusqlite::types::Value::Integer(state)) => state,
            _ => 0,
        };
        let welcome = match (approval, chain, profile) {
            (Some(mut approval), Some(chain), Some(profile)) => self
                .devices
                .approver
                .welcome(message, &mut approval, &chain, &profile, state, now)
                .map(|w| (w, approval.request_id)),
            _ => None,
        };
        self.join_close_after(id, BY_ID_REPLY_LINGER_SECONDS);
        self.changed();
        let Some((welcome, request)) = welcome else { return };
        // Stored first: a welcome never goes out for a device this profile does not hold.
        if devices::merge_own_chain(self.store.connection(), &welcome.chain).is_err() {
            log!("could not store the chain for a joining computer");
            return;
        }
        for part in welcome.parts {
            self.join_send(id, part);
        }
        self.devices.approver.finish(&request);
        log!("a new computer joined this profile");
        self.own_devices_changed();
    }

    /// The PROFILE friends receive, the presence secret friends find us by and the secret our own devices find each
    /// other by, so the new computer reaches friends and syncs with us at once.
    fn welcome_profile(&mut self) -> Option<Vec<u8>> {
        let mut frame = Frame::new(FrameType::Profile);
        frame.fields = self.profile_fields();
        let presence = self.store.ensure_own_presence_secret().ok()?;
        let devices_secret = sync::own_devices_secret_in_store(&self.store, true)?;
        let mut fields = Fields::new();
        fields.set_data(WELCOME_PROFILE_FRAME, Some(&frame.encode().ok()?));
        fields.set_data(WELCOME_PRESENCE_SECRET, Some(&presence));
        fields.set_data(WELCOME_DEVICES_SECRET, Some(&devices_secret));
        Some(fields.encode())
    }

    /// The new computer's side of a run.
    fn joining_message(&mut self, id: u64, message: &[u8]) {
        let Some(attempt) = self.devices.attempts.get_mut(&id) else {
            // A request's session: the only answer that says anything is that this very request ended.
            let ended = join::end_reason(message);
            if let Some(reason) = ended.filter(|_| self.devices.joiner.is_some()) {
                if self.devices.phase != JoiningState::Checking {
                    self.join_ended(reason);
                }
            }
            return self.join_close(id);
        };
        let step = attempt.receive(message);
        if let Step::Send(reply) = step {
            self.join_send(id, reply);
            return;
        }
        if matches!(step, Step::Wait) {
            return;
        }
        self.devices.attempts.remove(&id);
        self.join_close(id);
        match step {
            Step::Joined { chain, profile, friends_id_state } => self.complete_join(&chain, &profile, friends_id_state),
            Step::WrongCode if self.devices.phase == JoiningState::Checking => {
                self.devices.phase = JoiningState::WrongCode;
                self.changed();
            }
            Step::Ended(reason) => self.join_ended(reason),
            _ => {}
        }
    }

    fn join_ended(&mut self, reason: EndReason) {
        self.devices.phase = match reason {
            EndReason::Denied => JoiningState::Denied,
            EndReason::Expired => JoiningState::Expired,
            EndReason::TooManyAttempts => JoiningState::TooManyAttempts,
        };
        self.devices.generation += 1;
        self.end_join_legs();
        self.changed();
    }

    /// The profile's name and ID, checked as any PROFILE is, become this computer's own, with the secrets friends
    /// and our devices find it by; only for the ID the person typed.
    fn complete_join(&mut self, chain: &DeviceChain, profile: &[u8], friends_id_state: u8) {
        let welcome = Fields::decode(profile);
        let frame = welcome.as_ref().and_then(|w| w.data(WELCOME_PROFILE_FRAME)).and_then(|d| Frame::decode(d).ok());
        let frame = frame.filter(|f| f.frame_type == FrameType::Profile);
        let presence = welcome.as_ref().and_then(|w| w.data(WELCOME_PRESENCE_SECRET)).filter(|p| p.len() == 32);
        let devices_secret = welcome.as_ref().and_then(|w| w.data(WELCOME_DEVICES_SECRET)).filter(|d| d.len() == 32);
        let name = frame.as_ref().and_then(|f| clean_name(f.get(tag::NAME)));
        let friends_id = frame.as_ref().and_then(|f| f.text(tag::FRIENDS_ID)).map(str::to_owned);
        let typed = self.devices.joiner.as_ref().map(|j| j.friends_id().to_owned());
        let me = self.identity.public_key();
        let conn = self.store.connection();
        let adopted = friends_id.is_some()
            && friends_id == typed
            && presence.is_some()
            && devices_secret.is_some()
            && devices::adopt_own_chain(conn, chain, &me).is_ok();
        if !adopted {
            log!("could not take the profile after joining");
            self.devices.phase = JoiningState::NotReached;
            return self.changed();
        }
        let _ = sync_records::set_profile(conn, name.as_deref(), &Picture::placeholder());
        let _ = sync_records::set_profile_value(conn, "friends_id", friends_id.unwrap_or_default().into());
        let _ = sync_records::set_profile_value(conn, "friends_id_state", i64::from(friends_id_state).into());
        let _ = sync_records::set_own_presence_secret(conn, presence);
        sync::adopt_own_devices_secret(&self.store, devices_secret.unwrap_or_default());
        // Checked in for the person from now on, after this computer's own ID from before is released (owed until a
        // host confirms it, across launches).
        let _ = szfriends_core::store::sync_log::set_state(conn, super::super::devices::PRE_JOIN_RELEASE, 1.into());
        self.devices.phase = JoiningState::Joined;
        self.devices.generation += 1;
        self.devices.joiner = None;
        self.devices.code = None;
        self.end_join_legs();
        log!("this computer joined a profile");
        self.own_devices_changed();
        self.people_changed();
    }

    /// The new computer's sessions carrying a code end: a new request or code starts afresh.
    pub(crate) fn end_join_legs(&mut self) {
        let ids: Vec<u64> = self.devices.attempts.drain().map(|(id, _)| id).collect();
        for id in ids {
            self.join_close(id);
        }
    }

    /// A session ended: an approval nobody confirmed was spent, a run of the code is over.
    pub(crate) fn join_session_closed(&mut self, id: u64) {
        self.devices.attempts.remove(&id);
        if let Some(mut approval) = self.devices.approvals.remove(&id) {
            self.devices.approver.abandon(&mut approval, unix_now());
            self.changed();
        }
    }

    /// Joining's timers: a code nobody answered, join rows that expire by themselves.
    pub(crate) fn join_tick(&mut self, now: f64) {
        if let Some((generation, _)) = self.devices.code_deadline.filter(|(_, at)| *at <= now) {
            self.devices.code_deadline = None;
            if generation == self.devices.generation && self.devices.phase == JoiningState::Checking {
                self.devices.phase = JoiningState::NotReached;
                self.end_join_legs();
                self.changed();
            }
        }
        if self.devices.refresh_at.is_some_and(|at| at <= now) {
            self.devices.refresh_at = None;
            self.changed();
        }
    }
}
