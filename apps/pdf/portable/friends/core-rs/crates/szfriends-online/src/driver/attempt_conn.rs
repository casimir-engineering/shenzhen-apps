//! One attempt's connections (`SZFriendsOnlineAttempt+Connections.m`): opening them for the order, what the transport
//! reports about them, the order's actions and its timers. The order is the one owner of the direct phase's timers.

use szfriends_datachannel_sys::Event;
use szfriends_wire::route::RouteMethod;

use super::attempt::{Attempt, Slot};
use super::{Ctx, Output, CONNECTIONS_MAX, ROUTE_INTERVAL};
use crate::order::action;
use crate::signal::items::{end_reason, tag, Item};
use crate::transport::candidate::{Candidate, CandidateType};
use crate::transport::{ConnEvent, Connection, Kind, Purpose, RelayCredentials, Request, Role, Technique};

impl Attempt {
    /// Every request names this attempt's own peer and purpose (header rule 6).
    pub(super) fn open_slot(
        &mut self,
        ctx: &mut Ctx<'_>,
        kind: Kind,
        number: u8,
        offer: Option<&Item>,
        relay: Option<RelayCredentials>,
        local_port: u16,
    ) -> Option<u8> {
        if self.ended || self.slots.contains_key(&number) {
            return None;
        }
        let blocked = ctx.context.direct_paths_blocked();
        let remote_offer = match offer {
            Some(offer) => {
                let sdp = offer.text(tag::SDP)?.to_owned();
                let fingerprint: [u8; 32] = offer.data(tag::FINGERPRINT)?.try_into().ok()?;
                Some((sdp, fingerprint))
            }
            None => None,
        };
        let request = Request {
            purpose: Purpose::Friend,
            role: self.role,
            kind,
            peer: self.friend.identity_key.to_vec(),
            stun_uri: if kind == Kind::Direct && !blocked { ctx.context.stun_uri() } else { None },
            relay,
            local_port,
            remote_offer,
        };
        let id = ctx.context.next_connection_id();
        let (forward, notice) = (ctx.context.forward(), ctx.context.stream_close_notice(id));
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
        let connection = Connection::open(id, &request, &ctx.context.transport, forward, notice, now).ok()?;
        ctx.context.connections.insert(id, (self.id, number));
        let remote_ready = self.role == Role::Answerer;
        let slot = Slot {
            number,
            kind,
            id,
            connection: Some(connection),
            remote_ready,
            open_streams: 0,
            remote_reflexive: None,
            remote_candidates: 0,
            remote_endpoints: Vec::new(),
        };
        self.slots.insert(number, slot);
        match kind {
            Kind::Direct => self.direct = Some(number),
            Kind::Relay => self.relay = Some(number),
            Kind::ProbeHandover => self.probe = Some(number),
        }
        if remote_ready {
            self.apply_held(ctx, number);
        }
        Some(number)
    }

    fn is_current(&self, number: u8) -> bool {
        [self.direct, self.relay, self.probe].contains(&Some(number))
    }

    fn forget_current(&mut self, number: u8) {
        for current in [&mut self.direct, &mut self.relay, &mut self.probe] {
            if *current == Some(number) {
                *current = None;
            }
        }
    }

    /// Forgotten first, then closed: what it closes reports to a slot that is no longer current.
    pub(super) fn close_slot(&mut self, number: Option<u8>) {
        let Some(number) = number else { return };
        self.forget_current(number);
        if let Some(slot) = self.slots.get_mut(&number) {
            if let Some(mut connection) = slot.connection.take() {
                connection.close();
            }
        }
        self.held.remove(&number);
    }

    fn take_number(&mut self) -> Option<u8> {
        let number = self.next_number;
        self.next_number += 1;
        (number < CONNECTIONS_MAX).then_some(number as u8)
    }

    pub(super) fn answerer_offer_arrived(&mut self, ctx: &mut Ctx<'_>, offer: Item, number: u8, kind: Kind) {
        if number == 0 && kind == Kind::Direct && self.direct.is_none() && self.slots.is_empty() {
            // The first direct connection exists from the start of the attempt.
            if self.open_slot(ctx, kind, 0, Some(&offer), None, 0).is_none() {
                self.finish(ctx);
            }
            return;
        }
        self.offers.insert(kind, (offer, number));
        let actions = match kind {
            Kind::Direct => self.order.peer_opened_direct(),
            Kind::Relay => self.order.peer_opened_relay(),
            Kind::ProbeHandover => {
                self.probe_offer_arrived(ctx);
                0
            }
        };
        self.perform(ctx, actions);
    }

    pub(super) fn apply_remote_candidate(&mut self, ctx: &mut Ctx<'_>, item: &Item, number: u8) {
        let technique = Technique::from_byte(item.byte(tag::TECHNIQUE)).unwrap_or(Technique::None);
        let blocked = ctx.context.direct_paths_blocked();
        let direct = self.direct;
        let Some(slot) = self.slots.get_mut(&number) else { return };
        let Some(line) = item.text(tag::CANDIDATE) else { return };
        if slot.kind == Kind::ProbeHandover || (blocked && technique != Technique::Relay) {
            return;
        }
        let Some(connection) = slot.connection.as_mut() else { return };
        if connection.add_remote_candidate(line, technique).is_err() {
            return;
        }
        let Some(candidate) = Candidate::parse(line) else { return };
        if !candidate.tcp {
            slot.remote_candidates += 1;
            slot.remote_endpoints.push(candidate.address);
        }
        if candidate.kind == CandidateType::ServerReflexive && slot.remote_reflexive.is_none() {
            slot.remote_reflexive = Some(candidate.address);
            if direct == Some(number) {
                self.predict_if_possible(ctx);
            }
        }
    }

    // --- What the transport reports --------------------------------------------------------------------------

    /// One stack event for the connection numbered `number`.
    pub fn connection_event(&mut self, ctx: &mut Ctx<'_>, number: u8, event: Event) {
        let Some(connection) = self.slots.get_mut(&number).and_then(|s| s.connection.as_mut()) else { return };
        let events = connection.handle(event);
        for event in events {
            if self.ended {
                return;
            }
            self.conn_event(ctx, number, event);
        }
        self.flush(ctx);
    }

    fn conn_event(&mut self, ctx: &mut Ctx<'_>, number: u8, event: ConnEvent) {
        let Some(slot) = self.slots.get(&number) else { return };
        let (kind, id) = (slot.kind, slot.id);
        match event {
            ConnEvent::Description { sdp, fingerprint } => {
                let description = Item::description(number, kind as u8, &sdp, &fingerprint);
                if self.role == Role::Offerer {
                    if self.session.is_none() {
                        self.open_sid(ctx, Some(description));
                    } else {
                        self.send_items(vec![description]);
                    }
                    return;
                }
                if self.replied {
                    self.send_items(vec![description]);
                } else {
                    self.reply_with(ctx, Some(description));
                }
                // The answerer's descriptions are both applied once it sends its answer.
                if self.direct == Some(number) && !self.ended {
                    let (local, now) = (ctx.context.nat_class(), ctx.context.now());
                    let actions = self.order.descriptions_applied(local, self.remote_nat, now);
                    self.perform(ctx, actions);
                }
            }
            ConnEvent::Candidate { line, technique } => {
                if ctx.context.direct_paths_blocked() && technique != Technique::Relay {
                    return;
                }
                self.order.note_technique_tried(technique);
                self.send_items(vec![Item::candidate(number, technique as u8, &line)]);
            }
            ConnEvent::GatheringDone => self.send_items(vec![Item::candidates_end(number)]),
            ConnEvent::Stream { stream, route } => {
                if !self.is_current(number) {
                    stream.writer.close();
                    return;
                }
                if let Some(slot) = self.slots.get_mut(&number) {
                    slot.open_streams += 1;
                }
                self.connected = true;
                let initiator = self.role == Role::Offerer;
                ctx.out.push(Output::Stream { attempt: self.id, friend: self.peer(), stream, route, initiator });
                let (now, random) = (ctx.context.now(), ctx.context.random());
                let actions = self.order.stream_opened(kind, route, now, random);
                self.perform(ctx, actions);
            }
            ConnEvent::RouteChanged(route) => {
                if self.is_current(number) {
                    let (now, random) = (ctx.context.now(), ctx.context.random());
                    let actions = self.order.route_changed(kind, route, now, random);
                    self.perform(ctx, actions);
                }
            }
            ConnEvent::StreamClosed => self.stream_closed(ctx, number),
            ConnEvent::Failed(_) => self.connection_failed(ctx, id, kind),
        }
    }

    /// The connection failed (or its authenticated answer did not apply): it is gone.
    pub(super) fn connection_failed(&mut self, ctx: &mut Ctx<'_>, id: u64, kind: Kind) {
        let Some(number) = self.slots.values().find(|s| s.id == id).map(|s| s.number) else { return };
        let current = self.is_current(number);
        if let Some(mut connection) = self.slots.get_mut(&number).and_then(|s| s.connection.take()) {
            connection.close();
        }
        self.forget_current(number);
        if current && !self.ended {
            let (now, random) = (ctx.context.now(), ctx.context.random());
            let actions = self.order.connection_failed(kind, now, random);
            self.perform(ctx, actions);
        }
    }

    /// A stream this attempt opened closed (its owner closed it, or its path ended).
    pub fn stream_closed(&mut self, ctx: &mut Ctx<'_>, number: u8) {
        if self.ended {
            return;
        }
        let current = self.is_current(number);
        let Some(slot) = self.slots.get_mut(&number) else { return };
        slot.open_streams = slot.open_streams.saturating_sub(1);
        if slot.open_streams == 0 && current {
            let kind = slot.kind;
            let actions = self.order.stream_closed(kind);
            self.perform(ctx, actions);
        }
    }

    // --- The order's actions ----------------------------------------------------------------------------------

    /// In the order the order gives (closes before opens); a step may end the attempt, so each looks first.
    pub(super) fn perform(&mut self, ctx: &mut Ctx<'_>, actions: u32) {
        if self.ended {
            return;
        }
        if actions & action::STOP_PROBING != 0 {
            self.stop_probing();
        }
        let direct_streams = self.direct.and_then(|n| self.slots.get(&n)).map_or(0, |s| s.open_streams);
        if actions & action::CLOSE_DIRECT != 0 && direct_streams == 0 {
            self.close_slot(self.direct);
        }
        if actions & action::CLOSE_RELAY != 0 {
            self.close_slot(self.relay);
        }
        if !self.ended && actions & action::OPEN_DIRECT != 0 {
            self.open_for_order(ctx, Kind::Direct);
        }
        if !self.ended && actions & action::OPEN_RELAY != 0 {
            self.open_relay(ctx);
        }
        if !self.ended && actions & action::START_PREDICTION != 0 {
            self.start_prediction(ctx);
        }
        if !self.ended && actions & action::START_PROBING != 0 {
            self.start_probing(ctx);
        }
        if !self.ended && actions & action::SIGNAL_NETWORK_CHANGE != 0 {
            let number = self.direct.unwrap_or(0);
            self.send_items(vec![Item::start(number, Kind::Direct as u8)]);
        }
        if actions & action::END != 0 {
            self.finish(ctx);
        }
    }

    fn open_for_order(&mut self, ctx: &mut Ctx<'_>, kind: Kind) {
        let opened = if self.role == Role::Offerer {
            self.take_number().and_then(|number| self.open_slot(ctx, kind, number, None, None, 0))
        } else {
            self.offers
                .remove(&kind)
                .and_then(|(offer, number)| self.open_slot(ctx, kind, number, Some(&offer), None, 0))
        };
        if opened.is_none() {
            let (now, random) = (ctx.context.now(), ctx.context.random());
            let actions = self.order.connection_failed(kind, now, random);
            self.perform(ctx, actions);
        }
    }

    /// The relay: credentials for this sid first (only once both ends have spoken), then a new connection with
    /// relay candidates only. The answerer asks for its own and answers the offerer's relay offer.
    fn open_relay(&mut self, ctx: &mut Ctx<'_>) {
        match self.channel.as_ref().filter(|c| !c.ended) {
            Some(channel) => ctx.host.request_relay(self.id, &channel.sid),
            None => {
                let (now, random) = (ctx.context.now(), ctx.context.random());
                let actions = self.order.connection_failed(Kind::Relay, now, random);
                self.perform(ctx, actions);
            }
        }
    }

    pub fn relay_credentials(&mut self, ctx: &mut Ctx<'_>, credentials: Option<RelayCredentials>) {
        if self.ended {
            return;
        }
        let opened = credentials.and_then(|credentials| {
            if self.role == Role::Offerer {
                let number = self.take_number()?;
                self.open_slot(ctx, Kind::Relay, number, None, Some(credentials), 0)
            } else {
                let (offer, number) = self.offers.remove(&Kind::Relay)?;
                self.open_slot(ctx, Kind::Relay, number, Some(&offer), Some(credentials), 0)
            }
        });
        if opened.is_none() {
            let (now, random) = (ctx.context.now(), ctx.context.random());
            let actions = self.order.connection_failed(Kind::Relay, now, random);
            self.perform(ctx, actions);
        }
        self.flush(ctx);
    }

    // --- Timers ------------------------------------------------------------------------------------------------

    /// When [`fire_timers`](Self::fire_timers) next has something to do.
    pub fn next_deadline(&self) -> f64 {
        let answer = if self.answered { f64::INFINITY } else { self.answer_deadline };
        let routes = if self.connected { self.last_route_check + ROUTE_INTERVAL } else { f64::INFINITY };
        self.order.next_deadline().min(answer).min(routes)
    }

    pub fn fire_timers(&mut self, ctx: &mut Ctx<'_>) {
        if self.ended {
            return;
        }
        let now = ctx.context.now();
        if !self.answered && !self.connected && self.answer_deadline <= now {
            // Nobody answered: an offline friend and a refusal look the same, and both end the attempt quietly.
            self.finish(ctx);
            return;
        }
        if !self.answered && self.answer_deadline <= now {
            // A later sid went unanswered while a stream still carries the session: forget that sid.
            self.answer_deadline = f64::INFINITY;
            if let Some(channel) = self.channel.take() {
                ctx.host.close(&channel.sid);
            }
            self.outgoing.clear();
        }
        if self.connected && now >= self.last_route_check + ROUTE_INTERVAL {
            self.last_route_check = now;
            let numbers: Vec<u8> = self.slots.keys().copied().collect();
            for number in numbers {
                let events =
                    self.slots.get_mut(&number).and_then(|s| s.connection.as_mut()).map(Connection::refresh_route);
                for event in events.unwrap_or_default() {
                    self.conn_event(ctx, number, event);
                }
            }
        }
        let random = ctx.context.random();
        let actions = self.order.fire_due_timers(now, random);
        self.perform(ctx, actions);
        self.flush(ctx);
    }

    // --- Inputs from the driver ---------------------------------------------------------------------------------

    pub fn nearby_route_changed(&mut self, ctx: &mut Ctx<'_>, route: RouteMethod) {
        let (now, random) = (ctx.context.now(), ctx.context.random());
        let actions = self.order.other_route_changed(route, now, random);
        self.perform(ctx, actions);
        self.flush(ctx);
    }

    pub fn network_changed(&mut self, ctx: &mut Ctx<'_>) {
        let now = ctx.context.now();
        let actions = self.order.network_changed(now);
        self.perform(ctx, actions);
        self.flush(ctx);
    }

    /// The classifier measured this network: the order's hard-NAT decision uses it, and the friend hears it.
    pub fn local_nat_class_changed(&mut self, ctx: &mut Ctx<'_>) {
        if self.ended {
            return;
        }
        let class = ctx.context.nat_class();
        let actions = self.order.local_nat_class_changed(class);
        self.perform(ctx, actions);
        if self.session.as_ref().is_some_and(crate::signal::SignalingSession::is_established) {
            let item = self.nat_item(ctx.context);
            self.send_items(vec![item]);
        }
        self.flush(ctx);
    }

    pub fn close(&mut self, ctx: &mut Ctx<'_>) {
        if !self.ended {
            self.order.close();
            self.finish(ctx);
        }
    }

    /// Ends everything this attempt holds, says so to the friend when they heard from us, and leaves its log entry.
    pub(super) fn finish(&mut self, ctx: &mut Ctx<'_>) {
        if self.ended {
            return;
        }
        self.order.close();
        let speaking = self.role == Role::Offerer || self.replied;
        let established = self.session.as_ref().is_some_and(crate::signal::SignalingSession::is_established);
        if let (true, true, Some(channel)) = (established, speaking, self.channel.as_ref().filter(|c| !c.ended)) {
            let sid = channel.sid.clone();
            if let Some(end) = self.session.as_mut().and_then(|s| s.seal(&[Item::end(end_reason::DONE)]).ok()) {
                ctx.host.send(&sid, &end);
            }
        }
        self.ended = true;
        self.prober = None;
        let numbers: Vec<u8> = self.slots.keys().copied().collect();
        for number in numbers {
            self.close_slot(Some(number));
        }
        if let Some(channel) = self.channel.take() {
            ctx.host.close(&channel.sid);
        }
        self.outgoing.clear();
        ctx.context.append_log(self.order.log_entry());
        ctx.out.push(Output::Ended(self.id));
    }
}
