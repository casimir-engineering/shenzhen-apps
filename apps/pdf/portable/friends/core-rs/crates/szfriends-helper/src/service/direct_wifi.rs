//! The owner's direct Wi-Fi rule in the Rust helper (ADR 0022, `szfriends_core::nearby::p2p_wifi`): direct Wi-Fi only
//! when neither device is on a Wi-Fi network, or the one that is is a phone on mobile data, both having said so.
//!
//! - This side's answer comes from the platform ([`crate::nearby::platform::PlatformDiscovery::wifi_standing`]: the
//!   phones' plugin); without one it is no. Only iOS has a peer-to-peer Wi-Fi route the racer dials (AWDL); the
//!   desktops have none, and their answer only decides capability bit 6.
//! - Each new handshake sets capability bit 6 while this side allows it; a session or lane on the peer-to-peer
//!   Wi-Fi route is closed as soon as it is up unless both handshakes set it. A boost's lanes are the boost's, which
//!   judged both sides by BOOST's Abilities.
//! - Every tick: the racer learns this side's answer, each sending group's scheduler the pair's, and when this side
//!   stops allowing it (it joined a Wi-Fi network, lost its mobile data), what runs on that route closes.

use szfriends_core::nearby::WifiStanding;
use szfriends_core::store::unix_now;
use szfriends_core::wire::consts::CAPABILITY_DIRECT_WIFI_ALLOWED;
use szfriends_core::wire::{CloseReason, RouteMethod};

use super::State;
use crate::log;

impl State {
    /// This device's side of the rule now, from the platform; `None` where it cannot say.
    pub(crate) fn direct_wifi_standing(&self) -> Option<WifiStanding> {
        crate::nearby::platform::installed().and_then(|platform| platform.wifi_standing())
    }

    fn direct_wifi_here(&self) -> bool {
        self.direct_wifi_standing().is_some_and(WifiStanding::allows_direct_wifi)
    }

    /// Capability bit 6 for a handshake made now.
    pub(crate) fn direct_wifi_capability(&self) -> u32 {
        if self.direct_wifi_here() {
            CAPABILITY_DIRECT_WIFI_ALLOWED
        } else {
            0
        }
    }

    /// The rule for the group whose first session is `head`: both handshakes allowed it and this side still does.
    pub(crate) fn direct_wifi_with(&self, head: u64) -> bool {
        self.direct_wifi_here() && self.sessions.map.get(&head).is_some_and(|s| s.channel.direct_wifi_allowed())
    }

    /// A session or lane that just went live on the peer-to-peer Wi-Fi route without both sides' word.
    pub(crate) fn direct_wifi_refuses(&self, id: u64) -> bool {
        let Some(session) = self.sessions.map.get(&id) else { return false };
        if session.meta.race_route(&session.channel) != RouteMethod::PeerToPeerWifi || self.boost.linking() {
            return false;
        }
        let refused = !session.channel.direct_wifi_allowed();
        if refused {
            log!("direct Wi-Fi: session {id} closed: both devices must allow direct Wi-Fi (on no Wi-Fi network, or a phone on mobile data)");
        }
        refused
    }

    /// Closes a session the owner's rule refuses. Not a failure: the person's backoff stays as it is on both sides,
    /// and the dialer leaves that endpoint off peer-to-peer Wi-Fi for a while (the racer), instead of dialing it,
    /// handshaking and closing again on every pass.
    pub(crate) fn close_under_rule(&mut self, id: u64) {
        let Some(session) = self.sessions.map.get_mut(&id) else { return };
        session.meta.rule_closed = true;
        let name = session.conversation.clone().or_else(|| session.meta.race_name.clone());
        if let (true, Some((method, endpoint)), Some(name)) =
            (session.channel.is_initiator(), session.meta.endpoint.clone(), name)
        {
            self.nearby.racer.note_p2p_refused(&endpoint, method, &name, unix_now());
            if let Some(end) = self.nearby.racer.next_backoff_end(unix_now()) {
                self.schedule_reconsider_after(end - unix_now());
            }
        }
        self.close(id, CloseReason::Normal);
    }

    /// Follows this side's answer: the racer, each group's scheduler, and what runs on the route once it is no.
    pub(crate) fn direct_wifi_tick(&mut self) {
        let standing = self.direct_wifi_standing().unwrap_or(WifiStanding { on_wifi: true, phone_on_mobile: false });
        let before = self.nearby.racer.wifi_standing();
        self.nearby.racer.set_wifi_standing(standing);
        let here = standing.allows_direct_wifi();
        if before.map(WifiStanding::allows_direct_wifi) != Some(here) {
            log!("direct Wi-Fi: {} here", if here { "allowed" } else { "not allowed" });
        }
        let heads: Vec<u64> = self.sessions.groups.schedules.keys().copied().collect();
        for head in heads {
            let allowed = self.direct_wifi_with(head);
            if let Some(schedule) = self.sessions.groups.schedules.get_mut(&head) {
                schedule.scheduler.set_direct_wifi(allowed);
            }
        }
        if here || self.boost.linking() {
            return;
        }
        let on_route: Vec<u64> = self
            .sessions
            .map
            .iter()
            .filter(|(_, s)| s.meta.live && s.meta.our_close.is_none())
            .filter(|(_, s)| s.meta.race_route(&s.channel) == RouteMethod::PeerToPeerWifi)
            .map(|(id, _)| *id)
            .collect();
        for id in on_route {
            log!("direct Wi-Fi: session {id} on it closed: this device no longer allows it");
            self.close(id, CloseReason::Normal);
        }
    }
}
