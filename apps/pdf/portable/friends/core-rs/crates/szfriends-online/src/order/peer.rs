//! What the offerer's signalling asks of the answerer's order (mod.rs): its hard-NAT step, its relay, a new direct
//! connection, and a network change on the answerer's side, which the offerer acts on.

use super::{action, Order, Phase};
use crate::transport::{Role, Technique};

impl Order {
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
}
