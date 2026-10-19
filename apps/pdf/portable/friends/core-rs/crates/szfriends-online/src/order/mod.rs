//! The online order (`SZFriendsOnlineOrder.m`, `+Timers.m`; ADR 0011 § The direct phase, § Leave the relay): when an
//! attempt opens which connection, and when it leaves the relay. Pure: the clock and the jitter are given, so every
//! phase and timer is tested with a scripted clock. The owner carries out each call's actions in this order:
//! StopProbing, CloseDirect, CloseRelay, then OpenDirect, OpenRelay, StartPrediction, StartProbing, then
//! SignalNetworkChange; End closes everything and records the log entry.
//!
//! Phases, as the offerer runs them (the answerer never starts the relay or probing itself; it follows the offerer's
//! signalling and has no timers): Signalling until both descriptions are applied; PlainChecks for 5 s; HardNAT for up
//! to 12 s more when exactly one side maps per destination; Relay once the budget ran out with no other route working;
//! Relayed while the relay carries the stream (direct retried after 30 s, doubling to 300 s, ±20%); Standby while
//! another route carries the session; Direct; Ended.

#[cfg(test)]
mod tests;
mod timers;

use szfriends_wire::route::{rank, RouteMethod};

use crate::nat::classifier::NatClass;
use crate::transport::{Kind, Purpose, Role, Route, Technique};

pub const PLAIN_CHECKS_BUDGET: f64 = 5.0;
pub const HARD_NAT_BUDGET: f64 = 12.0;
pub const RETRY_FIRST: f64 = 30.0;
pub const RETRY_MAX: f64 = 300.0;
pub const RETRY_JITTER: f64 = 0.2;
pub const RETRY_SIGNALLING_LIMIT: f64 = 10.0;

fn better(a: RouteMethod, b: RouteMethod) -> bool {
    rank(a as u8) < rank(b as u8)
}

/// An Internet attempt could still improve on `current` only when it ranks after Internet.
pub fn attempt_worth_starting(current: RouteMethod) -> bool {
    better(RouteMethod::Internet, current)
}

/// Exactly one side maps per destination and the other is known to map independently.
pub fn hard_nat_worth_trying(local: NatClass, remote: NatClass) -> bool {
    let (local_hard, remote_hard) = (local == NatClass::PerDestination, remote == NatClass::PerDestination);
    local_hard != remote_hard && (if local_hard { remote } else { local }) == NatClass::EndpointIndependent
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Signalling,
    PlainChecks,
    HardNat,
    Relay,
    Relayed,
    Standby,
    Direct,
    Ended,
}

/// Recorded in the technique log by number: never renumber.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum EndReason {
    #[default]
    None = 0,
    Closed = 1,
    Superseded = 2,
    Unreachable = 3,
    StreamClosed = 4,
}

/// What the owner does after a call, as bits.
pub mod action {
    pub const STOP_PROBING: u32 = 1 << 0;
    pub const CLOSE_DIRECT: u32 = 1 << 1;
    pub const CLOSE_RELAY: u32 = 1 << 2;
    pub const OPEN_DIRECT: u32 = 1 << 3;
    pub const OPEN_RELAY: u32 = 1 << 4;
    pub const START_PREDICTION: u32 = 1 << 5;
    pub const START_PROBING: u32 = 1 << 6;
    pub const SIGNAL_NETWORK_CHANGE: u32 = 1 << 7;
    pub const END: u32 = 1 << 8;
}

/// What one attempt tried and what connected (ADR 0011 § Technique log): numbers only.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LogEntry {
    pub purpose: Purpose,
    pub role: Role,
    pub local_class: NatClass,
    pub remote_class: NatClass,
    pub techniques_tried: u32,
    pub first_technique: Technique,
    pub final_technique: Technique,
    pub seconds_to_first_stream: f64,
    pub relay_requested: bool,
    pub relay_needed: bool,
    pub left_relay: bool,
    pub direct_retries: u32,
    pub end_reason: EndReason,
}

impl LogEntry {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "purpose": self.purpose as u8, "role": self.role as u8, "local_class": self.local_class as u8,
            "remote_class": self.remote_class as u8, "tried": self.techniques_tried,
            "first": self.first_technique as u8, "final": self.final_technique as u8,
            "seconds": self.seconds_to_first_stream, "relay_requested": self.relay_requested,
            "relay_needed": self.relay_needed, "left_relay": self.left_relay, "retries": self.direct_retries,
            "end": self.end_reason as u8,
        })
    }
}

#[derive(Debug)]
pub struct Order {
    role: Role,
    phase: Phase,
    direct_open: bool,
    relay_open: bool,
    probing: bool,
    carrier: Option<Kind>,
    other_route: RouteMethod,
    local_nat: NatClass,
    remote_nat: NatClass,
    hard_nat_pair: Option<(NatClass, NatClass)>,
    phase_deadline: f64,
    retry_running: bool,
    retry_hard_nat_due: bool,
    retry_deadline: f64,
    retry_at: f64,
    retry_interval: f64,
    first_descriptions_at: Option<f64>,
    log: LogEntry,
}

impl Order {
    pub fn new(role: Role, purpose: Purpose) -> Self {
        Self {
            role,
            phase: Phase::Signalling,
            direct_open: true,
            relay_open: false,
            probing: false,
            carrier: None,
            other_route: RouteMethod::None,
            local_nat: NatClass::Unknown,
            remote_nat: NatClass::Unknown,
            hard_nat_pair: None,
            phase_deadline: f64::INFINITY,
            retry_running: false,
            retry_hard_nat_due: false,
            retry_deadline: f64::INFINITY,
            retry_at: f64::INFINITY,
            retry_interval: RETRY_FIRST,
            first_descriptions_at: None,
            log: LogEntry {
                purpose,
                role,
                local_class: NatClass::Unknown,
                remote_class: NatClass::Unknown,
                techniques_tried: 0,
                first_technique: Technique::None,
                final_technique: Technique::None,
                seconds_to_first_stream: -1.0,
                relay_requested: false,
                relay_needed: false,
                left_relay: false,
                direct_retries: 0,
                end_reason: EndReason::None,
            },
        }
    }

    pub fn role(&self) -> Role {
        self.role
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn end_reason(&self) -> EndReason {
        self.log.end_reason
    }

    pub fn log_entry(&self) -> LogEntry {
        self.log
    }

    fn ended(&self) -> bool {
        self.phase == Phase::Ended
    }

    /// When [`fire_due_timers`](Self::fire_due_timers) next has something to do.
    pub fn next_deadline(&self) -> f64 {
        if self.ended() || self.role != Role::Offerer {
            return f64::INFINITY;
        }
        let mut next = f64::INFINITY;
        if matches!(self.phase, Phase::PlainChecks | Phase::HardNat) {
            next = self.phase_deadline;
        }
        if self.retry_running {
            next = next.min(self.retry_deadline);
        }
        let periodic = matches!(self.phase, Phase::Relayed | Phase::Standby);
        if !self.retry_running && periodic {
            next = next.min(self.retry_at);
        }
        next
    }

    pub fn fire_due_timers(&mut self, now: f64, random: f64) -> u32 {
        let mut actions = 0;
        for _ in 0..4 {
            if self.next_deadline() > now {
                break;
            }
            if self.phase == Phase::PlainChecks && self.phase_deadline <= now {
                actions |= self.plain_checks_ended(now, random);
            } else if self.phase == Phase::HardNat && self.phase_deadline <= now {
                actions |= self.budget_spent(now, random);
            } else if self.retry_running && self.retry_deadline <= now {
                if self.retry_hard_nat_due {
                    self.retry_hard_nat_due = false;
                    self.retry_deadline = now + HARD_NAT_BUDGET;
                    actions |= self.start_hard_nat();
                } else {
                    actions |= self.retry_ended(now, random);
                }
            } else if !self.retry_running
                && self.retry_at <= now
                && matches!(self.phase, Phase::Relayed | Phase::Standby)
            {
                actions |= self.open_retry(now);
            }
        }
        actions
    }

    pub fn descriptions_applied(&mut self, local: NatClass, remote: NatClass, now: f64) -> u32 {
        if self.ended() {
            return 0;
        }
        self.local_nat = local;
        self.remote_nat = remote;
        self.log.local_class = local;
        self.log.remote_class = remote;
        self.first_descriptions_at.get_or_insert(now);
        if self.retry_running {
            self.retry_descriptions_applied(now);
        } else if self.phase == Phase::Signalling {
            self.phase = Phase::PlainChecks;
            if self.role == Role::Offerer {
                self.phase_deadline = now + PLAIN_CHECKS_BUDGET;
            }
        }
        0
    }

    pub fn note_technique_tried(&mut self, technique: Technique) {
        if technique != Technique::None {
            self.log.techniques_tried |= 1 << technique as u32;
        }
    }

    pub fn stream_opened(&mut self, kind: Kind, route: Route, now: f64, random: f64) -> u32 {
        if self.ended() {
            return 0;
        }
        if self.log.first_technique == Technique::None {
            self.log.first_technique = route.technique;
            self.log.seconds_to_first_stream = self.first_descriptions_at.map_or(0.0, |at| (now - at).max(0.0));
        }
        if self.phase == Phase::Direct {
            return 0;
        }
        self.log.final_technique = route.technique;
        if route.method() == RouteMethod::Internet || kind != Kind::Relay {
            return self.become_direct_on(kind);
        }
        self.log.relay_needed = true;
        self.carrier = Some(Kind::Relay);
        if self.other_route_works() {
            return self.leave_relay_for_other_route(now, random);
        }
        self.phase = Phase::Relayed;
        if !self.retry_running {
            self.schedule_periodic_retry(RETRY_FIRST, now, random);
        }
        0
    }

    pub fn route_changed(&mut self, kind: Kind, route: Route, now: f64, random: f64) -> u32 {
        if self.ended() || Some(kind) != self.carrier {
            return 0;
        }
        self.log.final_technique = route.technique;
        if kind != Kind::Relay {
            return 0;
        }
        let direct = route.method() == RouteMethod::Internet;
        if direct && self.phase == Phase::Relayed {
            return self.become_direct_on(kind);
        }
        if !direct && self.phase == Phase::Direct {
            self.phase = Phase::Relayed;
            self.relay_open = true;
            self.schedule_periodic_retry(RETRY_FIRST, now, random);
        }
        0
    }

    pub fn connection_failed(&mut self, kind: Kind, now: f64, random: f64) -> u32 {
        if self.ended() {
            return 0;
        }
        if Some(kind) == self.carrier {
            return self.end_with(EndReason::StreamClosed);
        }
        match kind {
            Kind::Direct => {
                self.direct_open = false;
                if self.retry_running {
                    return self.retry_ended(now, random);
                }
                if self.phase == Phase::Signalling {
                    return self.end_with(EndReason::Unreachable);
                }
                if self.phase == Phase::PlainChecks && self.role == Role::Offerer {
                    return self.plain_checks_ended(now, random);
                }
                if self.phase == Phase::HardNat && !self.probing && self.role == Role::Offerer {
                    return self.budget_spent(now, random);
                }
            }
            Kind::ProbeHandover => {
                let mut actions = self.stop_probing();
                if self.phase == Phase::HardNat && !self.direct_open && self.role == Role::Offerer {
                    actions |= self.budget_spent(now, random);
                }
                return actions;
            }
            Kind::Relay => self.relay_open = false,
        }
        let nothing_left = !self.direct_open && !self.relay_open && !self.retry_running && !self.probing;
        if nothing_left && matches!(self.phase, Phase::Relay | Phase::Relayed) {
            return self.end_with(EndReason::Unreachable);
        }
        0
    }

    pub fn stream_closed(&mut self, kind: Kind) -> u32 {
        if self.ended() || Some(kind) != self.carrier {
            return 0;
        }
        self.end_with(EndReason::StreamClosed)
    }

    fn leave_relay_for_other_route(&mut self, now: f64, random: f64) -> u32 {
        let mut actions = 0;
        if self.relay_open {
            actions |= action::CLOSE_RELAY;
        }
        self.relay_open = false;
        if self.carrier == Some(Kind::Relay) {
            self.carrier = None;
        }
        let scheduled = self.phase == Phase::Relayed && self.retry_at.is_finite();
        self.phase = Phase::Standby;
        if !self.retry_running && !scheduled {
            self.schedule_periodic_retry(RETRY_FIRST, now, random);
        }
        actions
    }

    pub fn other_route_changed(&mut self, route: RouteMethod, now: f64, random: f64) -> u32 {
        self.other_route = route;
        if self.ended() {
            return 0;
        }
        let earlier_internet = route == RouteMethod::Internet && self.phase != Phase::Direct;
        if better(route, RouteMethod::Internet) || earlier_internet {
            return self.end_with(EndReason::Superseded);
        }
        if self.other_route_works() {
            if matches!(self.phase, Phase::Relay | Phase::Relayed) {
                return self.leave_relay_for_other_route(now, random);
            }
            return 0;
        }
        if self.phase == Phase::Standby && self.role == Role::Offerer {
            return self.budget_spent(now, random);
        }
        0
    }

    pub fn network_changed(&mut self, now: f64) -> u32 {
        if self.ended() || self.phase == Phase::Direct {
            return 0;
        }
        if self.role != Role::Offerer {
            return action::SIGNAL_NETWORK_CHANGE;
        }
        match self.phase {
            Phase::Signalling | Phase::PlainChecks | Phase::HardNat => {
                let mut actions = self.stop_probing();
                if self.direct_open {
                    actions |= action::CLOSE_DIRECT;
                }
                self.direct_open = true;
                self.phase = Phase::Signalling;
                self.phase_deadline = f64::INFINITY;
                self.hard_nat_pair = None;
                self.log.direct_retries += 1;
                actions | action::OPEN_DIRECT
            }
            _ => {
                self.retry_interval = RETRY_FIRST / 2.0;
                self.open_retry(now)
            }
        }
    }

    pub fn local_nat_class_changed(&mut self, local: NatClass) -> u32 {
        if !self.ended() {
            self.local_nat = local;
            self.log.local_class = local;
        }
        0
    }

    pub fn probing_ended(&mut self, refused: bool, now: f64, random: f64) -> u32 {
        if self.ended() || !self.probing {
            return 0;
        }
        self.probing = false;
        if refused {
            self.log.techniques_tried &= !(1 << Technique::ProbeHandover as u32);
        }
        if self.phase == Phase::HardNat && self.role == Role::Offerer && !self.direct_open {
            return self.budget_spent(now, random);
        }
        0
    }

    pub fn peer_started_hard_nat(&mut self) -> u32 {
        if self.ended() || self.role != Role::Answerer {
            return 0;
        }
        if matches!(self.phase, Phase::PlainChecks | Phase::Signalling) {
            self.phase = Phase::HardNat;
        } else if !self.retry_running {
            return 0;
        }
        self.start_hard_nat()
    }

    pub fn peer_opened_relay(&mut self) -> u32 {
        if self.ended() || self.role != Role::Answerer || self.relay_open || self.phase == Phase::Direct {
            return 0;
        }
        let actions = self.stop_probing();
        self.relay_open = true;
        self.phase = Phase::Relay;
        self.log.relay_requested = true;
        self.note_technique_tried(Technique::Relay);
        actions | action::OPEN_RELAY
    }

    pub fn peer_opened_direct(&mut self) -> u32 {
        if self.ended() || self.role != Role::Answerer || self.phase == Phase::Direct {
            return 0;
        }
        let mut actions = self.stop_probing();
        if self.direct_open {
            actions |= action::CLOSE_DIRECT;
        }
        self.direct_open = true;
        self.log.direct_retries += 1;
        if matches!(self.phase, Phase::PlainChecks | Phase::HardNat) {
            self.phase = Phase::Signalling;
        } else if self.phase != Phase::Signalling {
            self.retry_running = true;
        }
        actions | action::OPEN_DIRECT
    }

    pub fn peer_network_changed(&mut self, now: f64) -> u32 {
        if self.role != Role::Offerer {
            return 0;
        }
        self.network_changed(now)
    }

    pub fn close(&mut self) -> u32 {
        self.end_with(EndReason::Closed)
    }
}
