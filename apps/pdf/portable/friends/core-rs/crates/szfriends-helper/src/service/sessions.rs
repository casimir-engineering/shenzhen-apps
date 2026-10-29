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
        let capabilities =
            if self.fast_transfers { szfriends_core::wire::consts::CAPABILITY_FAST_TRANSFERS } else { 0 };
        channel.set_config(szfriends_core::session::ChannelConfig { capabilities, ..Default::default() });
        let link = match Link::start(id, stream, self.input.clone(), Input::Link) {
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
    }

    pub(super) fn service(&mut self, id: u64) {
        let now = monotonic_now();
        if let Some(s) = self.sessions.map.get_mut(&id) {
            let (keepalive, watch) = transfer_liveness(s.senders.values().map(|o| &o.sender), s.receivers.values());
            s.channel.set_liveness(keepalive, watch, now);
            s.channel.handle_timeout(now);
        }
        loop {
            let Some(s) = self.sessions.map.get_mut(&id) else { return };
            while let Some(write) = s.channel.poll_transmit() {
                s.link.write(write.bytes);
            }
            let Some(event) = s.channel.poll_event() else { break };
            match event {
                Event::Established => self.went_live(id),
                Event::Frame(frame) => self.frame(id, frame),
                Event::Code(result) => self.code_finished(id, result),
                Event::Closed(error) => self.closed(id, error),
            }
        }
        self.flush_if_due(id);
        self.flush_blocks_if_due();
        self.pump(id);
        self.pump_blocks(id);
        let Some(s) = self.sessions.map.get_mut(&id) else { return };
        while let Some(write) = s.channel.poll_transmit() {
            s.link.write(write.bytes);
        }
        if s.channel.is_closed() && !s.finished {
            s.finished = true;
            s.link.finish();
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
            pending.sort_by_key(|e| !(is_request_answer(e) && answer_kind(e) == "accept"));
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

    fn frame_for_entry(&mut self, entry: &OutboxEntry, person: &Person) -> Option<(String, Frame)> {
        let entry_wire = unhex(&entry.entry_id).filter(|w| w.len() == 16);
        match entry.kind {
            OutboxKind::Message => {
                let item = super::facts::item_row(&self.store, &entry.conversation_id, entry.item_id.as_deref()?)?;
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
    pub(super) fn message(&mut self, id: u64, frame: &Frame, conversation: &str, wire: String) {
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

    pub(super) fn send_ack(&mut self, id: u64, wire: &[u8]) {
        self.send_on(id, &Frame::new(FrameType::Ack).with(tag::ID, wire.to_vec()));
    }

    /// The ACK for something this session sent.
    pub(super) fn acknowledged(&mut self, id: u64, conversation: &str, wire: String) {
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

    /// The next time the service should look at its sessions.
    pub fn next_wakeup(&self) -> Duration {
        let now = monotonic_now();
        let timers = self.sessions.map.values().filter_map(|s| s.channel.poll_timeout()).min();
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
