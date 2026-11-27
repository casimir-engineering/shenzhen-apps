//! When direct Wi-Fi may be used (ADR 0022, the owner's rule; PROTOCOL.md § Routes).
//!
//! The owner, 2026-11-27: "use wifi direct only if the conditions are matched, which means both devices are not on a
//! wifi, or for 3D if the device is a phone that could have internet access through cellular."
//!
//! Direct Wi-Fi is every link that does not go through a Wi-Fi network's access point: AWDL between Macs and iPhones
//! (Network.framework's peer-to-peer Wi-Fi, the racer's [`super::RouteMethod::PeerToPeerWifi`] route) and ADR 0019's
//! Wi-Fi Direct boost (a phone's group that the other device joins). It shares the radio with the device's Wi-Fi
//! network: on a Mac on Wi-Fi, AWDL took 21 to 33 % of the airtime in 66 to 80 ms stalls (ADR 0021), so it slows the
//! very network it sits beside. So it is used only when, on **each** of the two devices:
//!
//! - the device is on no Wi-Fi network (an Ethernet cable or no network at all), or
//! - the device is a phone running Shenzhen 3D that stays online over mobile data; such a phone may leave its Wi-Fi
//!   for the link, after its person said so where it leaves (the boost's question, or iOS's own Join prompt).
//!
//! Being able to stay on the Wi-Fi network beside the direct link (station and peer-to-peer at once) does not count:
//! that is exactly the shared radio the rule avoids. Each device judges its own side ([`WifiStanding`]) and tells
//! the other: handshake capability bit 6 for sessions and lanes, BOOST's Abilities bit 4 for a boost. Both must say
//! yes ([`direct_wifi_allowed`]); a peer that says nothing (a helper from before this rule) never gets direct Wi-Fi.
//! A device never leaves its network silently. Pure: the platforms hand their answers in.

/// Whether this platform has a peer-to-peer Wi-Fi route the racer can dial (AWDL, through Network.framework's
/// `includePeerToPeer`). Whether it may be used now is [`WifiStanding`]'s.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum P2pWifi {
    /// No peer-to-peer Wi-Fi route on this platform (Windows, Linux, Android: Android's Wi-Fi Direct is the boost's,
    /// never a route the racer dials).
    Unsupported,
    /// The platform has one (macOS, iOS).
    Supported,
}

impl P2pWifi {
    /// This platform's answer at build time.
    pub const PLATFORM: P2pWifi =
        if cfg!(any(target_os = "macos", target_os = "ios")) { P2pWifi::Supported } else { P2pWifi::Unsupported };
}

impl Default for P2pWifi {
    fn default() -> Self {
        Self::PLATFORM
    }
}

/// This device's side of the rule, from the platform.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WifiStanding {
    /// On a Wi-Fi network now (a direct link the device joined for a boost does not count).
    pub on_wifi: bool,
    /// A phone (the core in Shenzhen 3D) that is online over mobile data now.
    pub phone_on_mobile: bool,
}

impl WifiStanding {
    /// Direct Wi-Fi allowed on this device's side: on no Wi-Fi network, or a phone that stays online over mobile data.
    pub fn allows_direct_wifi(self) -> bool {
        !self.on_wifi || self.phone_on_mobile
    }
}

/// Direct Wi-Fi between two devices: only when both sides allow it.
pub fn direct_wifi_allowed(local: bool, peer: bool) -> bool {
    local && peer
}

/// Whether the racer dials this platform's peer-to-peer Wi-Fi route now: the platform has one and this side allows
/// direct Wi-Fi (the peer's side is checked once its handshake says so).
pub fn p2p_wifi_usable(capability: P2pWifi, here: WifiStanding) -> bool {
    capability == P2pWifi::Supported && here.allows_direct_wifi()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_owners_rule() {
        let off = WifiStanding { on_wifi: false, phone_on_mobile: false };
        let on = WifiStanding { on_wifi: true, phone_on_mobile: false };
        let phone = WifiStanding { on_wifi: true, phone_on_mobile: true };
        assert!(off.allows_direct_wifi() && phone.allows_direct_wifi());
        assert!(!on.allows_direct_wifi(), "on Wi-Fi with nothing else: never");
        for (a, b, both) in
            [(off, off, true), (off, phone, true), (phone, phone, true), (on, off, false), (off, on, false)]
        {
            assert_eq!(direct_wifi_allowed(a.allows_direct_wifi(), b.allows_direct_wifi()), both, "{a:?} {b:?}");
        }
    }

    #[test]
    fn the_racer_needs_the_route_and_this_side() {
        let off = WifiStanding::default();
        let on = WifiStanding { on_wifi: true, phone_on_mobile: false };
        assert!(p2p_wifi_usable(P2pWifi::Supported, off));
        assert!(!p2p_wifi_usable(P2pWifi::Supported, on));
        assert!(!p2p_wifi_usable(P2pWifi::Unsupported, off));
        let apple = cfg!(any(target_os = "macos", target_os = "ios"));
        assert_eq!(P2pWifi::default() == P2pWifi::Supported, apple);
    }
}
