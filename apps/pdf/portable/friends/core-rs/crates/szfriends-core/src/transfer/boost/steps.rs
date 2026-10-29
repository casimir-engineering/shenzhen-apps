//! A boost's negotiation as it moves (boost.rs): the peer's abilities, both sides' agreement, each message, the link
//! hosted or joined, the lane, the rates, and how it ends.

use super::*;

impl Boost {
    /// The peer's abilities arrived (its PROPOSE, or its READY to this side's PROPOSE): roles, cost, and the
    /// question or READY.
    pub(super) fn peer_said(&mut self, peer: Abilities, now: Duration) {
        let Some(role) = role(self.local, peer, self.local_sorts_first).filter(|_| self.local.any()) else {
            self.end(boost_reason::UNSUPPORTED, true, now);
            return;
        };
        self.role = Some(role);
        self.cost = Cost::of(role, self.local, &self.connectivity);
        if self.cost.asks() {
            self.phase = Phase::Asking;
            self.effects.push(Effect::Ask(self.cost.clone()));
        } else {
            self.agree(now);
        }
    }

    pub(super) fn agree(&mut self, now: Duration) {
        self.sent_ready = true;
        self.phase = Phase::Agreed;
        self.effects.push(Effect::Send(Message::Ready { abilities: self.local }));
        self.both_agreed(now);
    }

    pub(super) fn both_agreed(&mut self, now: Duration) {
        if !(self.sent_ready && self.got_ready) {
            return;
        }
        self.agreed_at = Some(now);
        if self.role == Some(Role::Host) {
            let link = Link::new();
            self.link = Some(link.clone());
            self.hosting = true;
            self.phase = Phase::Hosting;
            self.effects.push(Effect::AllowDirectLane(true));
            self.effects.push(Effect::Host(link));
        }
        // Joining waits for the host's HOST.
    }

    /// This device's person answered the question.
    pub fn answer(&mut self, go_faster: bool, now: Duration) {
        if self.phase != Phase::Asking {
            return;
        }
        self.effects.push(Effect::Unask);
        if go_faster {
            self.agree(now);
        } else {
            self.declined_by_person = true;
            self.phase = Phase::Ended;
            self.end_reason = Some(boost_reason::NOT_NOW);
            self.effects.push(Effect::Send(Message::Decline { reason: boost_reason::NOT_NOW }));
        }
    }

    /// A BOOST from the peer for this boost's transfer.
    pub fn message(&mut self, message: Message, now: Duration) {
        if self.phase == Phase::Ended {
            return;
        }
        match message {
            Message::Propose { abilities } if self.phase == Phase::Proposed => {
                // Both proposed at once: each treats the other's PROPOSE as its answer, so both go on.
                self.peer_said(abilities, now);
            }
            Message::Ready { abilities } => {
                if self.role.is_none() {
                    self.peer_said(abilities, now);
                }
                if self.phase != Phase::Ended {
                    self.got_ready = true;
                    self.both_agreed(now);
                }
            }
            Message::Host { link, address, port } => {
                if self.role != Some(Role::Join) || !self.sent_ready || !self.got_ready || self.joining {
                    return;
                }
                self.joining = true;
                self.phase = Phase::Joining;
                self.link = Some(link.clone());
                self.pending_dial = Some((address, port));
                self.effects.push(Effect::AllowDirectLane(true));
                self.effects.push(Effect::Join(link));
            }
            Message::Decline { reason } => {
                if reason == boost_reason::NOT_NOW {
                    self.declined_by_person = true;
                }
                self.end(reason, false, now);
            }
            Message::End { reason } => self.end(reason, false, now),
            Message::Propose { .. } => {}
        }
    }

    /// The host's link is up at `address`, its lane listener at `port`.
    pub fn hosted(&mut self, address: IpAddr, port: u16, _now: Duration) {
        if self.phase != Phase::Hosting {
            return;
        }
        if let Some(link) = self.link.clone() {
            self.effects.push(Effect::Send(Message::Host { link, address, port }));
        }
    }

    /// The joining side is on the host's link: dial the lane.
    pub fn joined(&mut self, _now: Duration) {
        if self.phase != Phase::Joining {
            return;
        }
        if let Some((address, port)) = self.pending_dial {
            self.effects.push(Effect::Dial { address, port });
        }
    }

    /// Hosting, joining or the lane's dial failed.
    pub fn failed(&mut self, now: Duration) {
        self.end(boost_reason::FAILED, true, now);
    }

    /// The direct lane went live.
    pub fn lane_up(&mut self, now: Duration) {
        if matches!(self.phase, Phase::Hosting | Phase::Joining) {
            self.phase = Phase::Direct;
            self.lane_at = Some(now);
        }
    }

    /// The direct lane closed: the boost is over (the transfer goes on over Bluetooth).
    pub fn lane_down(&mut self, now: Duration) {
        if self.phase == Phase::Direct {
            self.end(boost_reason::FAILED, true, now);
        }
    }

    /// The scheduler's measured rates (bytes per second): never slower than without the boost. Once the lane has
    /// had [`MEASURE_FOR`], a direct lane no faster than Bluetooth ends it.
    pub fn rates(&mut self, direct: f64, bluetooth: f64, now: Duration) {
        let measured = self.lane_at.is_some_and(|at| now.saturating_sub(at) >= MEASURE_FOR);
        if self.phase == Phase::Direct && measured && direct <= bluetooth {
            self.end(boost_reason::SLOWER, true, now);
        }
    }

    /// Time passes: a link not up [`LINK_WITHIN`] after both agreed ends the boost.
    pub fn tick(&mut self, now: Duration) {
        let late = self.agreed_at.is_some_and(|at| now.saturating_sub(at) >= LINK_WITHIN);
        if late && matches!(self.phase, Phase::Agreed | Phase::Hosting | Phase::Joining) {
            self.end(boost_reason::FAILED, true, now);
        }
    }

    /// The transfer it was for finished, failed or was cancelled.
    pub fn transfer_ended(&mut self, now: Duration) {
        self.end(boost_reason::TRANSFER_ENDED, true, now);
    }

    /// The app quits: tell the peer if the session still can, and come back.
    pub fn quitting(&mut self, now: Duration) {
        self.end(boost_reason::QUITTING, true, now);
    }

    /// The group's session ended: nothing to tell, only coming back.
    pub fn session_lost(&mut self, now: Duration) {
        self.end(boost_reason::FAILED, false, now);
    }

    pub(super) fn end(&mut self, reason: u8, tell: bool, _now: Duration) {
        if self.phase == Phase::Ended {
            return;
        }
        if self.phase == Phase::Asking {
            self.effects.push(Effect::Unask);
        }
        if tell {
            let message = if self.sent_ready || self.phase == Phase::Proposed {
                Message::End { reason }
            } else {
                Message::Decline { reason }
            };
            self.effects.push(Effect::Send(message));
        }
        if self.hosting || self.joining {
            self.effects.push(Effect::AllowDirectLane(false));
        }
        if self.hosting {
            self.effects.push(Effect::StopHosting);
        }
        if self.joining {
            self.effects.push(Effect::LeaveJoined);
        }
        self.hosting = false;
        self.joining = false;
        self.phase = Phase::Ended;
        self.end_reason = Some(reason);
    }
}
