//! Sessions and delivery (`SZFriendsNearbyService+Sessions.m`, `+Delivery.m`): each secure channel on its link, the
//! outbox on the one session carrying a conversation (each frame marked Written before it goes, Delivered only on the
//! peer's ACK after their own commit), and what goes back to Queued when a session ends. How sessions start and which
//! one carries a conversation is `nearby/links.rs`; what each frame does is `nearby/inbound.rs` and `transfers.rs`.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use szfriends_core::session::{monotonic_now, transfer_liveness, ChunkReceiver, Event, SecureChannel};
use szfriends_core::store::{
    unix_now, Direction, Item, ItemKind, OutboxEntry, OutboxEvent, OutboxKind, Person, Relation,
};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType};

use super::link::{Link, LinkEvent};
use super::nearby::LinkMeta;
use super::transfers::Outgoing;
use super::{unhex, Input, State};
use crate::log;

pub struct Session {
    pub channel: SecureChannel,
    link: Link,
    pub conversation: Option<String>,
    pub senders: HashMap<String, Outgoing>,
    pub receivers: HashMap<String, ChunkReceiver>,
    /// Fast transfers (ADR 0018, `blocks.rs`): our files this session sends by blocks, and theirs it receives so.
    pub block_senders: HashMap<String, super::blocks::BlockSend>,
    pub block_receivers: HashSet<String>,
    pub flush_due: Option<Instant>,
    /// Wire id (hex) → what its ACK confirms: an outbox entry, or `done:<transfer>`.
    pub expecting: HashMap<String, String>,
    /// Outbox entries written on this session and not yet acknowledged.
    pub in_flight: HashSet<String>,
    pub profile_sent: bool,
    finished: bool,
    pub meta: LinkMeta,
}

#[derive(Default)]
pub struct Sessions {
    pub map: HashMap<u64, Session>,
    /// Lanes and their groups (ADR 0018 § 6, `lanes.rs`).
    pub groups: super::lanes::Groups,
    next: u64,
}

impl Sessions {
    /// The session carrying a conversation's traffic: live, adopted, not superseded.
    /// What a new link `id` for `conversation` meets: nothing (adopt it), a live link with another device of the same
    /// person (both stay, neither supersedes the other: ADR 0016), or one with the same device (settle the race).
    pub fn rival(&self, conversation: &str, id: u64) -> Rival {
        let Some(current) = self.live_for(conversation).filter(|c| *c != id) else { return Rival::None };
        let remote = |id: u64| self.map.get(&id).and_then(|s| s.channel.remote_identity().copied());
        match (remote(id), remote(current)) {
            (Some(new), Some(old)) if new != old => Rival::OtherDevice,
            _ => Rival::Same(current),
        }
    }

    pub fn live_for(&self, conversation_id: &str) -> Option<u64> {
        self.map
            .iter()
            .find(|(_, s)| {
                s.conversation.as_deref() == Some(conversation_id)
                    && s.meta.adopted
                    && !s.meta.superseded
                    && s.channel.is_established()
                    && !s.channel.is_closed()
            })
            .map(|(id, _)| *id)
    }

    pub fn adopted_conversations(&self) -> Vec<String> {
        self.map.values().filter(|s| s.meta.adopted).filter_map(|s| s.conversation.clone()).collect()
    }

    /// Whether any file is moving: a handover waits for it (at most 5 seconds).
    pub fn moving(&self) -> bool {
        self.map.values().any(|s| {
            !s.senders.is_empty()
                || !s.receivers.is_empty()
                || !s.block_senders.is_empty()
                || !s.block_receivers.is_empty()
        })
    }
}

/// Whether an outbox entry may go to this person now (`-entry:isDeliverableTo:`).
pub fn deliverable(entry: &OutboxEntry, person: &Person) -> bool {
    match person.relation {
        Relation::Blocked | Relation::IncomingRequest => false,
        Relation::Friend => true,
        // An Add by ID request whose holder we do not know yet travels over NN, not a session.
        Relation::OutgoingRequest => entry.kind == OutboxKind::Request && person.identity_key.is_some(),
        // Removing someone tells them nothing: only a decline or a withdrawn request still goes.
        Relation::Removed => is_request_answer(entry),
    }
}

/// accept, decline and the withdrawal of our own request: answers about the friendship itself.
pub fn is_request_answer(entry: &OutboxEntry) -> bool {
    if entry.kind != OutboxKind::Answer {
        return false;
    }
    let payload: serde_json::Value =
        entry.payload.as_deref().and_then(|p| serde_json::from_slice(p).ok()).unwrap_or_default();
    payload.get("transfer_id").is_none() && matches!(payload["frame"].as_str(), Some("accept" | "decline" | "cancel"))
}

impl State {
    /// A session id handed out before its channel existed (the key policy names its session).
    pub(super) fn reserve_session_id(&mut self) -> u64 {
        let id = self.sessions.next;
        self.sessions.next += 1;
        id
    }

    pub(super) fn adopt_session_id(
        &mut self,
        id: u64,
        channel: SecureChannel,
        stream: crate::nearby::stream::LinkStream,
        meta: LinkMeta,
    ) -> Option<u64> {
        let mut channel = channel;
        let capabilities = self.session_capabilities;
        channel.set_config(szfriends_core::session::ChannelConfig { capabilities, ..Default::default() });
        let rate = self.route_rates.get(&meta.dialed_route).copied();
        let silence = self.route_silence.clone().map(|path| (path, super::route_name(meta.dialed_route).to_owned()));
        let emulated = (rate.is_some() || silence.is_some()).then_some((rate, silence));
        let link = match Link::start(id, stream, self.input.clone(), Input::Link, emulated) {
            Ok(link) => link,
            Err(error) => {
                log!("session link: {error}");
                return None;
            }
        };
        let session = Session {
            channel,
            link,
            conversation: None,
            senders: HashMap::new(),
            receivers: HashMap::new(),
            block_senders: HashMap::new(),
            block_receivers: HashSet::new(),
            flush_due: None,
            expecting: HashMap::new(),
            in_flight: HashSet::new(),
            profile_sent: false,
            finished: false,
            meta,
        };
        self.sessions.map.insert(id, session);
        let session = self.sessions.map.get_mut(&id).expect("just made");
        session.channel.start(monotonic_now());
        Some(id)
    }

    pub fn link_event(&mut self, event: LinkEvent) {
        let now = monotonic_now();
        match event {
            LinkEvent::Bytes(id, bytes) => {
                if let Some(s) = self.sessions.map.get_mut(&id) {
                    s.channel.receive(&bytes, now);
                }
                self.lane_written(id, true);
            }
            LinkEvent::Eof(id) => {
                if let Some(s) = self.sessions.map.get_mut(&id) {
                    s.channel.link_closed_by_peer();
                }
            }
            LinkEvent::Written(id) => {
                if let Some(s) = self.sessions.map.get_mut(&id) {
                    s.channel.write_completed(now);
                }
                self.lane_written(id, false);
            }
        }
    }

    /// Timers, then writes and events of every session until each has nothing more to say.
    pub fn service_sessions(&mut self) {
        let ids: Vec<u64> = self.sessions.map.keys().copied().collect();
        for id in ids {
            self.service(id);
        }
        self.after_policy();
        self.sessions.map.retain(|_, s| !s.finished);
        if self.pulls.current.is_some() {
            self.reconsider_pulls();
        }
    }

    pub(super) fn service(&mut self, id: u64) {
        let now = monotonic_now();
        // What a friend's session brings now is handled in one store batch (ADR 0018 § 9.3: offers, answers, files),
        // committed before that session sends. Joining, our own devices' sync and strangers' sessions keep one
        // transaction per write.
        let mut batched = self.batches_files(id) && self.store.begin_batch().is_ok();
        if let Some(s) = self.sessions.map.get_mut(&id) {
            let (keepalive, watch) = transfer_liveness(s.senders.values().map(|o| &o.sender), s.receivers.values());
            let (blocks, owed) = self.block_liveness(id);
            let s = self.sessions.map.get_mut(&id).expect("looked up");
            s.channel.set_liveness(keepalive || blocks, watch || owed, now);
            s.channel.handle_timeout(now);
        }
        while let Some(s) = self.sessions.map.get_mut(&id) {
            while let Some(write) = (!batched).then(|| s.channel.poll_transmit()).flatten() {
                s.link.write(write.bytes);
            }
            let Some(event) = s.channel.poll_event() else { break };
            match event {
                Event::Established => self.went_live(id),
                // A lane's frames are its group's first session's (lanes.rs); a PART's HAVE goes back on its lane.
                Event::Frame(frame) if frame.frame_type == szfriends_core::wire::FrameType::Part => {
                    let head = self.head_of(id);
                    self.part_on(head, id, &frame);
                }
                Event::Frame(frame) => self.frame(self.head_of(id), frame),
                Event::Code(result) => self.code_finished(id, result),
                Event::Closed(error) => {
                    // What it committed and queued (its CLOSE among them) leaves before the session is let go.
                    if batched {
                        self.end_store_batch();
                        self.flush_writes(id);
                    }
                    self.closed(id, error);
                    batched = false;
                }
            }
        }
        self.flush_if_due(id);
        self.flush_blocks_if_due();
        self.pump(id);
        self.pump_blocks(id);
        self.pump_again(id);
        if batched {
            self.end_store_batch();
        }
        let Some(s) = self.sessions.map.get_mut(&id) else { return };
        while let Some(write) = s.channel.poll_transmit() {
            s.link.write(write.bytes);
        }
        if s.channel.is_closed() && !s.finished {
            s.finished = true;
            s.link.finish();
        }
    }

    /// A friend's IK session, not one with our own devices: what may carry many files at once.
    fn batches_files(&self, id: u64) -> bool {
        let Some(s) = self.sessions.map.get(&id) else { return false };
        s.channel.is_established()
            && s.channel.pattern() == szfriends_core::wire::Pattern::IK
            && s.conversation.is_some()
            && !self.devices.exchanges.contains_key(&id)
    }

    /// Ends the store batch; each file it published is acknowledged now, on its friend's live session.
    pub(super) fn end_store_batch(&mut self) {
        let published = match self.store.end_batch() {
            Ok(published) => published,
            Err(error) => return log!("a store batch did not commit: {error}"),
        };
        for file in published {
            match file.result {
                Ok(_) => {
                    let (Some(id), Some(wire)) =
                        (self.sessions.live_for(&file.conversation_id), unhex(&file.transfer_id))
                    else {
                        continue;
                    };
                    self.send_ack(id, &wire);
                    self.flush_writes(id);
                }
                Err(error) => log!("a received file could not be saved: {error}"),
            }
            self.changed();
        }
    }

    /// Hands a session's queued writes to its link now (parts a group's first session queued on a lane).
    pub(crate) fn flush_writes(&mut self, id: u64) {
        let Some(s) = self.sessions.map.get_mut(&id) else { return };
        while let Some(write) = s.channel.poll_transmit() {
            s.link.write(write.bytes);
        }
    }

    pub fn close(&mut self, id: u64, reason: CloseReason) {
        if let Some(s) = self.sessions.map.get_mut(&id) {
            s.channel.close_with_reason(reason, monotonic_now());
        }
    }

    pub fn close_all_sessions(&mut self) {
        let ids: Vec<u64> = self.sessions.map.keys().copied().collect();
        for id in ids {
            self.close(id, CloseReason::ShuttingDown);
            self.service(id);
        }
    }

    pub fn send_on(&mut self, id: u64, frame: &Frame) -> bool {
        self.sessions.map.get_mut(&id).is_some_and(|s| s.channel.send_frame(frame, monotonic_now()))
    }

    pub fn conversation_of(&self, id: u64) -> Option<String> {
        self.sessions.map.get(&id).and_then(|s| s.conversation.clone())
    }

    /// The name and Friends ID friends see, as PROFILE fields (also what a public entry serves).
    pub fn profile_fields(&mut self) -> szfriends_core::wire::Fields {
        let profile = self.profile_facts();
        let mut frame = Frame::new(FrameType::Profile);
        if let Some(name) = profile.name.filter(|n| !n.is_empty() && n.len() <= 1024) {
            frame = frame.with(tag::NAME, name.into_bytes());
        }
        if !profile.friends_id.is_empty() && profile.friends_id.len() <= 64 {
            frame = frame.with(tag::FRIENDS_ID, profile.friends_id.into_bytes());
        }
        frame.fields
    }

    /// Our name to friends and requests in either direction, once per session; removed and blocked people never.
    pub fn send_profile(&mut self, id: u64) {
        let Some(session) = self.sessions.map.get(&id) else { return };
        if session.profile_sent || !session.meta.live || session.meta.superseded {
            return;
        }
        let Some(conversation) = session.conversation.clone() else { return };
        let person = self.store.person_with_conversation(&conversation).ok().flatten();
        if !person.is_some_and(|p| {
            matches!(p.relation, Relation::Friend | Relation::OutgoingRequest | Relation::IncomingRequest)
        }) {
            return;
        }
        let mut frame = Frame::new(FrameType::Profile);
        frame.fields = self.profile_fields();
        if self.send_on(id, &frame) {
            if let Some(s) = self.sessions.map.get_mut(&id) {
                s.profile_sent = true;
            }
        }
    }

    /// Everything the outbox holds for this session's person that may go to them now.
    /// The next time the service should look at its sessions.
    pub fn next_wakeup(&self) -> Duration {
        let now = monotonic_now();
        let timers = self.sessions.map.values().filter_map(|s| s.channel.poll_timeout()).chain(self.pull_due()).min();
        let flush = self
            .sessions
            .map
            .values()
            .filter_map(|s| s.flush_due)
            .chain(self.store.block_flush_due())
            .chain(self.finishing_due())
            .min();
        let mut wait = timers.map_or(Duration::from_millis(250), |at| at.saturating_sub(now));
        if let Some(at) = flush {
            wait = wait.min(at.saturating_duration_since(Instant::now()));
        }
        let devices = [self.devices.capture_at, self.devices.code_deadline.map(|(_, at)| at), self.devices.refresh_at];
        if let Some(at) = devices.into_iter().flatten().min_by(f64::total_cmp) {
            wait = wait.min(Duration::from_secs_f64((at - unix_now()).max(0.0)));
        }
        if let Some(at) = self.nearby_wakeup() {
            wait = wait.min(Duration::from_secs_f64((at - unix_now()).max(0.0)));
        }
        wait
    }

    /// Periodic work: nearby's timers, friends online could reach, and what waited too long in the outbox.
    pub fn tick(&mut self) {
        self.nearby_tick();
        self.boost_tick();
        self.reconsider_pulls();
        self.join_tick(unix_now());
        self.sync_tick(unix_now());
        self.reach_online();
        #[cfg(feature = "online")]
        self.sweep_links();
        #[cfg(feature = "online")]
        self.offer_join_online();
        if let Ok(expired) = self.store.expire_outbox(unix_now()) {
            if !expired.is_empty() {
                self.changed();
            }
        }
    }
}

/// An answer entry's frame name ("accept", "decline", "cancel", "offer_reply").
pub fn answer_kind(entry: &OutboxEntry) -> String {
    let payload: serde_json::Value =
        entry.payload.as_deref().and_then(|p| serde_json::from_slice(p).ok()).unwrap_or_default();
    payload["frame"].as_str().unwrap_or_default().to_owned()
}

/// See [`Sessions::rival`].
pub enum Rival {
    None,
    OtherDevice,
    Same(u64),
}

#[path = "sessions_outbox.rs"]
mod outbox;
