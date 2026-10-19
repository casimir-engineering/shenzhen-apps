//! The order's timers and the steps they take (`SZFriendsOnlineOrder+Timers.m`; ADR 0011 § The direct phase).

use szfriends_wire::route::{rank, RouteMethod};

use super::{action, hard_nat_worth_trying, EndReason, Order, Phase, HARD_NAT_BUDGET, PLAIN_CHECKS_BUDGET};
use super::{RETRY_FIRST, RETRY_JITTER, RETRY_MAX, RETRY_SIGNALLING_LIMIT};
use crate::transport::{Kind, Role, Technique};

impl Order {
    pub(super) fn other_route_works(&self) -> bool {
        rank(self.other_route as u8) <= rank(RouteMethod::Relay as u8)
    }

    pub(super) fn end_with(&mut self, reason: EndReason) -> u32 {
        if self.ended() {
            return 0;
        }
        self.stop_probing();
        self.phase = Phase::Ended;
        self.log.end_reason = reason;
        self.direct_open = false;
        self.relay_open = false;
        self.retry_running = false;
        self.carrier = None;
        action::END
    }

    pub(super) fn stop_probing(&mut self) -> u32 {
        if !self.probing {
            return 0;
        }
        self.probing = false;
        action::STOP_PROBING
    }

    pub(super) fn start_hard_nat(&mut self) -> u32 {
        self.hard_nat_pair = Some((self.local_nat, self.remote_nat));
        let mut actions = action::START_PREDICTION;
        self.note_technique_tried(Technique::PredictedPort);
        if !self.probing {
            self.probing = true;
            self.note_technique_tried(Technique::ProbeHandover);
            actions |= action::START_PROBING;
        }
        actions
    }

    pub(super) fn plain_checks_ended(&mut self, now: f64, random: f64) -> u32 {
        let worth = hard_nat_worth_trying(self.local_nat, self.remote_nat);
        self.hard_nat_pair = Some((self.local_nat, self.remote_nat));
        if !worth {
            return self.budget_spent(now, random);
        }
        self.phase = Phase::HardNat;
        self.phase_deadline = now + HARD_NAT_BUDGET;
        self.start_hard_nat()
    }

    pub(super) fn budget_spent(&mut self, now: f64, random: f64) -> u32 {
        let mut actions = self.stop_probing();
        self.phase_deadline = f64::INFINITY;
        if self.other_route_works() {
            self.phase = Phase::Standby;
            if !self.retry_running {
                self.schedule_periodic_retry(RETRY_FIRST, now, random);
            }
            return actions;
        }
        self.phase = Phase::Relay;
        self.retry_at = f64::INFINITY;
        if !self.relay_open {
            self.relay_open = true;
            self.log.relay_requested = true;
            self.note_technique_tried(Technique::Relay);
            actions |= action::OPEN_RELAY;
        }
        actions
    }

    pub(super) fn become_direct_on(&mut self, kind: Kind) -> u32 {
        let mut actions = self.stop_probing();
        if self.log.relay_needed {
            self.log.left_relay = true;
        }
        if kind != Kind::Direct && self.direct_open {
            self.direct_open = false;
            actions |= action::CLOSE_DIRECT;
        }
        if kind != Kind::Relay && self.relay_open {
            self.relay_open = false;
            actions |= action::CLOSE_RELAY;
        }
        self.carrier = Some(kind);
        self.phase = Phase::Direct;
        self.phase_deadline = f64::INFINITY;
        self.retry_at = f64::INFINITY;
        self.retry_deadline = f64::INFINITY;
        self.retry_running = false;
        actions
    }

    pub(super) fn open_retry(&mut self, now: f64) -> u32 {
        let mut actions = self.stop_probing();
        if self.direct_open {
            actions |= action::CLOSE_DIRECT;
        }
        self.direct_open = true;
        self.retry_running = true;
        self.retry_hard_nat_due = false;
        self.retry_deadline = now + RETRY_SIGNALLING_LIMIT;
        self.retry_at = f64::INFINITY;
        self.log.direct_retries += 1;
        actions | action::OPEN_DIRECT
    }

    pub(super) fn retry_ended(&mut self, now: f64, random: f64) -> u32 {
        let mut actions = self.stop_probing();
        if self.direct_open {
            actions |= action::CLOSE_DIRECT;
        }
        self.direct_open = false;
        self.retry_running = false;
        self.retry_deadline = f64::INFINITY;
        if matches!(self.phase, Phase::Relayed | Phase::Standby) {
            self.schedule_periodic_retry((self.retry_interval * 2.0).min(RETRY_MAX), now, random);
        }
        actions
    }

    pub(super) fn schedule_periodic_retry(&mut self, interval: f64, now: f64, random: f64) {
        self.retry_interval = interval.max(RETRY_FIRST);
        if self.role != Role::Offerer {
            self.retry_at = f64::INFINITY;
            return;
        }
        let r = random.clamp(0.0, 1.0);
        self.retry_at = now + self.retry_interval * (1.0 + RETRY_JITTER * (2.0 * r - 1.0));
    }

    pub(super) fn retry_descriptions_applied(&mut self, now: f64) {
        self.retry_deadline = now + PLAIN_CHECKS_BUDGET;
        let pair = (self.local_nat, self.remote_nat);
        let changed = Some(pair) != self.hard_nat_pair;
        self.retry_hard_nat_due =
            self.role == Role::Offerer && changed && hard_nat_worth_trying(self.local_nat, self.remote_nat);
        if !self.retry_hard_nat_due {
            self.hard_nat_pair = Some(pair);
        }
    }
}
