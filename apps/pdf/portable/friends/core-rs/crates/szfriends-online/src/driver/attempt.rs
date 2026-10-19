//! One attempt toward one friend (`SZFriendsOnlineAttempt.m`): its signalling here, IK message 1 carrying the offer,
//! the answer in message 2, then Noise transport messages carrying descriptions, candidates, NAT classes and the
//! order's signals, several items per payload so the host's 64 messages per sid go far. Its connections and the
//! order's actions are in `attempt_conn.rs`, the NAT techniques in `attempt_nat.rs`.
//!
//! Gating (lead decision 6): the offerer applies nothing remote until `read_reply` has authenticated the friend; the
//! answerer exists only once the signalling session authenticated message 1 and the friend policy allowed it.

use std::collections::HashMap;
use std::net::SocketAddr;

use super::context::{Context, OnlineFriend};
use super::{Ctx, ANSWER_TIMEOUT};
use crate::nat::classifier::NatClass;
use crate::nat::prober::{Hit, Prober};
use crate::order::{Order, Phase};
use crate::signal::items::{self, tag, Item, ItemType};
use crate::signal::SignalingSession;
use crate::transport::{Connection, Kind, Purpose, Role, Technique};

/// Remote items kept for a connection that cannot take them yet: never an unbounded queue a peer could fill.
const HELD_ITEMS_MAX: usize = 64;

/// One connection of the attempt, by its number in the signalling.
#[derive(Debug)]
pub(super) struct Slot {
    pub number: u8,
    pub kind: Kind,
    pub id: u64,
    pub connection: Option<Connection>,
    /// The offerer applied the authenticated answer; the answerer applied the offer.
    pub remote_ready: bool,
    pub open_streams: usize,
    pub remote_reflexive: Option<SocketAddr>,
    pub remote_candidates: usize,
    pub remote_endpoints: Vec<SocketAddr>,
}

/// The current sid: the host's, or a test's.
#[derive(Debug, Clone)]
pub(super) struct Channel {
    pub sid: String,
    pub ended: bool,
}

#[derive(Debug)]
pub struct Attempt {
    pub id: u64,
    pub(super) friend: OnlineFriend,
    pub(super) role: Role,
    pub order: Order,
    pub(super) session: Option<SignalingSession>,
    pub(super) channel: Option<Channel>,
    pub(super) opening: bool,
    pub(super) replied: bool,
    pub(super) initial_items: Option<Vec<Item>>,
    pub(super) slots: HashMap<u8, Slot>,
    pub(super) direct: Option<u8>,
    pub(super) relay: Option<u8>,
    pub(super) probe: Option<u8>,
    pub(super) next_number: usize,
    pub(super) held: HashMap<u8, Vec<Item>>,
    pub(super) offers: HashMap<Kind, (Item, u8)>,
    pub(super) outgoing: Vec<Item>,
    pub(super) remote_nat: NatClass,
    pub(super) remote_step: i16,
    pub(super) answer_deadline: f64,
    pub(super) prober: Option<Prober>,
    pub(super) probe_remote: Option<SocketAddr>,
    pub(super) probe_waits_for_remote: bool,
    pub(super) prediction_pending: bool,
    pub(super) probe_hit: Option<Hit>,
    pub(super) ended: bool,
    pub(super) answered: bool,
    pub(super) connected: bool,
    pub(super) last_route_check: f64,
}

impl Attempt {
    fn with(id: u64, friend: OnlineFriend, role: Role) -> Self {
        Self {
            id,
            friend,
            role,
            order: Order::new(role, Purpose::Friend),
            session: None,
            channel: None,
            opening: false,
            replied: false,
            initial_items: None,
            slots: HashMap::new(),
            direct: None,
            relay: None,
            probe: None,
            next_number: 0,
            held: HashMap::new(),
            offers: HashMap::new(),
            outgoing: Vec::new(),
            remote_nat: NatClass::Unknown,
            remote_step: 0,
            answer_deadline: f64::INFINITY,
            prober: None,
            probe_remote: None,
            probe_waits_for_remote: false,
            prediction_pending: false,
            probe_hit: None,
            ended: false,
            answered: false,
            connected: false,
            last_route_check: 0.0,
        }
    }

    pub fn offerer(id: u64, friend: OnlineFriend) -> Self {
        Self::with(id, friend, Role::Offerer)
    }

    /// `session` authenticated `friend` from message 1, whose items are `items`.
    pub fn answerer(id: u64, friend: OnlineFriend, session: SignalingSession, sid: String, items: Vec<Item>) -> Self {
        let mut attempt = Self::with(id, friend, Role::Answerer);
        attempt.session = Some(session);
        attempt.initial_items = Some(items);
        attempt.channel = Some(Channel { sid, ended: false });
        attempt
    }

    pub fn peer(&self) -> [u8; 32] {
        self.friend.identity_key
    }

    /// The key the friend's records are filed under: their root.
    pub fn peer_root(&self) -> [u8; 32] {
        self.friend.root_key.unwrap_or(self.friend.identity_key)
    }

    pub fn role(&self) -> Role {
        self.role
    }

    pub fn ended(&self) -> bool {
        self.ended
    }

    pub fn answered(&self) -> bool {
        self.answered
    }

    pub fn connected(&self) -> bool {
        self.connected
    }

    pub fn sid(&self) -> Option<&str> {
        self.channel.as_ref().map(|c| c.sid.as_str())
    }

    /// The route this attempt's stream carries the session on now.
    pub fn carried_route(&self) -> szfriends_wire::route::RouteMethod {
        use szfriends_wire::route::RouteMethod;
        match self.order.phase() {
            Phase::Direct => RouteMethod::Internet,
            Phase::Relayed => RouteMethod::Relay,
            _ => RouteMethod::None,
        }
    }

    pub fn start(&mut self, ctx: &mut Ctx<'_>) {
        if self.role == Role::Offerer {
            // The offer exists only to be sealed to the friend's static key in IK message 1 (gating rule 1).
            self.answer_deadline = ctx.context.now() + ANSWER_TIMEOUT;
            if self.open_slot(ctx, Kind::Direct, 0, None, None, 0).is_none() {
                self.finish(ctx);
                return;
            }
            self.next_number = 1;
        } else {
            self.answered = true;
            let items = self.initial_items.take().unwrap_or_default();
            self.apply_items(ctx, items);
        }
        self.flush(ctx);
    }

    // --- The sid ------------------------------------------------------------------------------------------------

    /// A sid ends after 120 s or 64 messages. Streams already open keep going; an answerer with no stream has nothing
    /// left once its sid is gone.
    pub fn channel_ended(&mut self, ctx: &mut Ctx<'_>) {
        self.channel = None;
        if self.connected {
            return;
        }
        if self.role == Role::Answerer || !self.answered {
            self.finish(ctx);
        }
    }

    /// Answerer: the same friend opened a new sid for this attempt; its message 1 continues it.
    pub fn continue_with(&mut self, ctx: &mut Ctx<'_>, session: SignalingSession, sid: String, items: Vec<Item>) {
        if self.ended || self.role != Role::Answerer {
            return;
        }
        if let Some(old) = self.channel.take() {
            ctx.host.close(&old.sid);
        }
        self.session = Some(session);
        self.replied = false;
        self.channel = Some(Channel { sid, ended: false });
        self.apply_items(ctx, items);
        if !self.replied {
            self.reply_with(ctx, None);
        }
        self.flush(ctx);
    }

    pub(super) fn nat_item(&self, context: &mut Context) -> Item {
        Item::nat(context.nat_class() as u8, context.nat_step())
    }

    /// Offerer: IK message 1 to the friend's rendezvous key, carrying `description`.
    pub(super) fn open_sid(&mut self, ctx: &mut Ctx<'_>, description: Option<Item>) {
        if self.opening || self.ended {
            return;
        }
        let identity = ctx.context.identity.clone();
        let session = SignalingSession::ik_initiator(
            &identity,
            self.friend.static_key,
            self.friend.identity_key,
            self.friend.request_token,
        );
        let mut items = vec![self.nat_item(ctx.context)];
        let has_description = description.is_some();
        if let Some(description) = description {
            items.insert(0, description);
        }
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let Some((session, message)) = session.and_then(|mut s| s.opening_message(&items, now).ok().map(|m| (s, m)))
        else {
            self.finish(ctx);
            return;
        };
        self.session = Some(session);
        self.opening = true;
        // A new sid must be answered again before it carries anything.
        self.answered = self.answered && !has_description;
        ctx.host.open(self.id, crate::signal::record::rendezvous_key(&self.peer_root()), message);
    }

    /// The host opened the sid (or not).
    pub fn sid_opened(&mut self, ctx: &mut Ctx<'_>, sid: Option<String>) {
        self.opening = false;
        let Some(sid) = sid.filter(|_| !self.ended) else {
            if !self.ended && !self.connected {
                self.finish(ctx);
            }
            return;
        };
        if let Some(old) = self.channel.replace(Channel { sid, ended: false }) {
            ctx.host.close(&old.sid);
        }
        self.answer_deadline = ctx.context.now() + ANSWER_TIMEOUT;
    }

    /// Answerer: IK message 2, with this side's answer when there is one.
    pub(super) fn reply_with(&mut self, ctx: &mut Ctx<'_>, description: Option<Item>) {
        let mut items = vec![self.nat_item(ctx.context)];
        if let Some(description) = description {
            items.insert(0, description);
        }
        let reply = self.session.as_mut().and_then(|s| s.reply(&items).ok());
        let sent = match (&reply, &self.channel) {
            (Some(reply), Some(channel)) => ctx.host.send(&channel.sid, reply),
            _ => false,
        };
        if !sent {
            self.finish(ctx);
            return;
        }
        self.replied = true;
    }

    // --- Sending ------------------------------------------------------------------------------------------------

    fn can_send(&self) -> bool {
        self.session.as_ref().is_some_and(SignalingSession::is_established)
            && self.channel.as_ref().is_some_and(|c| !c.ended)
            && (self.role == Role::Offerer || self.replied)
    }

    pub(super) fn send_items(&mut self, items: Vec<Item>) {
        if !self.ended {
            self.outgoing.extend(items);
        }
    }

    /// Everything waiting goes in as few payloads as fit (called after each input, so a burst goes together).
    pub fn flush(&mut self, ctx: &mut Ctx<'_>) {
        if self.ended || self.outgoing.is_empty() {
            return;
        }
        if !self.can_send() {
            let established = self.session.as_ref().is_some_and(SignalingSession::is_established);
            let lost = established && self.channel.as_ref().is_none_or(|c| c.ended);
            if self.role == Role::Offerer && lost && !self.opening {
                self.reopen_sid(ctx);
            }
            return;
        }
        let capacity = items::PAYLOAD_MAX - 16;
        let mut batch: Vec<Item> = Vec::new();
        while !self.outgoing.is_empty() {
            batch.push(self.outgoing[0].clone());
            if items::encode(&batch, capacity).is_err() {
                batch.pop();
                if batch.is_empty() {
                    self.outgoing.remove(0); // one item too large on its own: never sendable
                    continue;
                }
                if !self.send_batch(ctx, std::mem::take(&mut batch)) {
                    return;
                }
                continue;
            }
            self.outgoing.remove(0);
        }
        if !batch.is_empty() {
            self.send_batch(ctx, batch);
        }
    }

    fn send_batch(&mut self, ctx: &mut Ctx<'_>, batch: Vec<Item>) -> bool {
        let payload = self.session.as_mut().and_then(|s| s.seal(&batch).ok());
        if let (Some(payload), Some(channel)) = (payload, &self.channel) {
            if ctx.host.send(&channel.sid, &payload) {
                return true;
            }
        }
        // The 65th payload, or an ended sid: what is left goes on the next sid.
        let rest = std::mem::take(&mut self.outgoing);
        self.outgoing = batch;
        self.outgoing.extend(rest);
        if let Some(channel) = self.channel.take() {
            ctx.host.close(&channel.sid);
        }
        if self.role == Role::Offerer {
            self.reopen_sid(ctx);
        }
        false
    }

    /// Offerer only: the newest description waiting goes in the new IK message 1; the rest follows once answered.
    fn reopen_sid(&mut self, ctx: &mut Ctx<'_>) {
        let Some(index) = self.outgoing.iter().rposition(|i| i.kind == ItemType::Description) else { return };
        let description = self.outgoing.remove(index);
        self.open_sid(ctx, Some(description));
    }

    // --- Receiving ----------------------------------------------------------------------------------------------

    pub fn receive_payload(&mut self, ctx: &mut Ctx<'_>, payload: &[u8]) {
        if self.ended {
            return;
        }
        let established = self.session.as_ref().is_some_and(SignalingSession::is_established);
        let items = match self.session.as_mut() {
            // IK message 2: the friend proves its key here, and only then is anything remote applied.
            Some(session) if self.role == Role::Offerer && !established => {
                let read = session.read_reply(payload).ok();
                if read.is_some() {
                    self.answered = true;
                    self.answer_deadline = f64::INFINITY;
                }
                read
            }
            Some(session) => session.open(payload).ok(),
            None => None,
        };
        let Some(items) = items else {
            // A payload that does not open here ends the exchange: nothing in it is trusted.
            self.finish(ctx);
            return;
        };
        self.apply_items(ctx, items);
        self.flush(ctx);
    }

    fn hold(&mut self, item: Item, number: u8) {
        let held = self.held.entry(number).or_default();
        if held.len() < HELD_ITEMS_MAX {
            held.push(item);
        }
    }

    pub(super) fn apply_held(&mut self, ctx: &mut Ctx<'_>, number: u8) {
        if let Some(held) = self.held.remove(&number) {
            self.apply_items(ctx, held);
        }
    }

    pub(super) fn apply_items(&mut self, ctx: &mut Ctx<'_>, items: Vec<Item>) {
        for item in items {
            if self.ended {
                return;
            }
            let number = item.byte(tag::CONNECTION);
            let kind = Kind::from_byte(item.byte(tag::KIND));
            let ready = self.slots.get(&number).map(|s| (s.remote_ready, s.connection.is_some()));
            match item.kind {
                ItemType::Description => {
                    if let Some(kind) = kind {
                        self.apply_description(ctx, &item, number, kind);
                    }
                }
                ItemType::Candidate => {
                    let technique = Technique::from_byte(item.byte(tag::TECHNIQUE));
                    if technique == Some(Technique::ProbeHandover) {
                        // The easy prober's own address, never a candidate for any connection.
                        let line = item.text(tag::CANDIDATE).unwrap_or("");
                        if let Some(c) = crate::transport::candidate::Candidate::parse(line).filter(|c| !c.tcp) {
                            self.prober_address_arrived(ctx, c.address);
                        }
                    } else if ready == Some((true, true)) {
                        self.apply_remote_candidate(ctx, &item, number);
                    } else if ready.is_none_or(|(_, has_connection)| has_connection) {
                        self.hold(item, number);
                    }
                }
                ItemType::CandidatesEnd if ready != Some((true, true)) => self.hold(item, number),
                ItemType::Nat => self.apply_nat(ctx, &item),
                ItemType::Start => {
                    if let Some(kind) = kind {
                        self.apply_start(ctx, kind);
                    }
                }
                ItemType::End => {
                    // The friend's side of this attempt is over (a better route won, or they cancelled).
                    self.finish(ctx);
                    return;
                }
                _ => {}
            }
        }
    }

    fn apply_description(&mut self, ctx: &mut Ctx<'_>, item: &Item, number: u8, kind: Kind) {
        if self.role == Role::Answerer {
            if !self.slots.contains_key(&number) {
                self.answerer_offer_arrived(ctx, item.clone(), number, kind);
            }
            return;
        }
        let (sdp, fingerprint) = (item.text(tag::SDP), item.data(tag::FINGERPRINT).unwrap_or(&[]));
        let Some(slot) = self.slots.get_mut(&number).filter(|s| !s.remote_ready && s.connection.is_some()) else {
            return;
        };
        let applied =
            sdp.is_some_and(|sdp| slot.connection.as_mut().is_some_and(|c| c.apply_answer(sdp, fingerprint).is_ok()));
        if !applied {
            let (id, kind) = (slot.id, slot.kind);
            self.connection_failed(ctx, id, kind);
            return;
        }
        slot.remote_ready = true;
        let slot_kind = slot.kind;
        if slot_kind == Kind::ProbeHandover && self.probe_hit.is_some() {
            self.apply_probe_remote(number);
        } else {
            self.apply_held(ctx, number);
        }
        if self.direct == Some(number) {
            let (local, now) = (ctx.context.nat_class(), ctx.context.now());
            let actions = self.order.descriptions_applied(local, self.remote_nat, now);
            self.perform(ctx, actions);
        }
    }
}
