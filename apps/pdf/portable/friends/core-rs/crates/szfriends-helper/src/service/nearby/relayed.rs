//! The owner's relay rule on the nearby side (ADR 0020; `SZFriendsNearbyService+Relayed.m`): the relay is the last
//! resort, so while it carries a friend's session every direct route keeps being tried, each at most
//! [`RELAY_PROBE_SECONDS`] apart. Once a second: the person's dial backoffs end (an endpoint that failed while they
//! were away is dialed again on the next pass, and a better route found that way wins the session race), Bluetooth
//! scans afresh (a device coming back into range is reported only by a new scan), and every candidate is looked at
//! again. The LAN needs no help: the network's browse reports a device that joins at once.

use super::*;

/// How often, at most, a direct route is tried again while the relay carries a session (ADR 0020).
pub const RELAY_PROBE_SECONDS: f64 = 1.0;

impl State {
    /// Conversations whose session the relay carries now.
    pub(crate) fn relayed_conversations(&self) -> Vec<String> {
        let mut relayed: Vec<String> = self
            .sessions
            .map
            .values()
            .filter(|s| s.meta.adopted && !s.meta.superseded && s.channel.is_established() && !s.channel.is_closed())
            .filter(|s| s.meta.race_route(&s.channel) == szfriends_core::wire::RouteMethod::Relay)
            .filter_map(|s| s.conversation.clone())
            .collect();
        relayed.sort();
        relayed.dedup();
        relayed
    }

    /// Once a second while the relay carries a session: try every direct route again.
    pub(super) fn relay_probe(&mut self, now: f64) {
        if self.nearby.relay_probe_at.is_some_and(|at| at > now) {
            return;
        }
        let relayed = self.relayed_conversations();
        if relayed.is_empty() {
            self.nearby.relay_probe_at = None;
            return;
        }
        self.nearby.relay_probe_at = Some(now + RELAY_PROBE_SECONDS);
        for conversation in &relayed {
            self.nearby.retry_after.remove(conversation);
            self.nearby.racer.end_backoffs(conversation, now);
        }
        for adapter in &mut self.nearby.adapters {
            if adapter.method() == Method::Bluetooth {
                adapter.refresh();
            }
        }
        self.schedule_reconsider();
    }

    /// The next probe, while one is due.
    pub(super) fn relay_probe_wakeup(&self) -> Option<f64> {
        self.nearby.relay_probe_at
    }

    /// A session went live or changed route: probing starts now if the relay carries it.
    pub(crate) fn relay_probe_now(&mut self) {
        if self.nearby.relay_probe_at.is_none() && !self.relayed_conversations().is_empty() {
            self.nearby.relay_probe_at = Some(unix_now());
        }
    }
}
