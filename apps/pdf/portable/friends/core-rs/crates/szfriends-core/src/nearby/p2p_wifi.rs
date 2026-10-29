//! Whether peer-to-peer Wi-Fi may be used here (ADR 0011 § Route rank, PROTOCOL.md § Routes).
//!
//! The rule: a transfer never costs the device its Internet connection without its person's word (the one exception is
//! ADR 0019's Wi-Fi Direct boost, `transfer::boost`, which asks first and comes back by itself; it does not go through
//! the racer). Peer-to-peer Wi-Fi is used only where the
//! platform keeps its normal Wi-Fi connection (the station link to the access point) up at the same time. Anywhere
//! that is unknown, or where the radio would leave the network to make the direct link, the route is skipped and the
//! racer dials the next one in the owner's order (Internet, Bluetooth, relay). Pure: probes hand their answers in.
//!
//! Today only Apple platforms have a peer-to-peer Wi-Fi route (AWDL, through Network.framework's
//! `includePeerToPeer`), and AWDL runs beside the Wi-Fi connection. Windows, Linux and Android have no
//! implementation. What one must check before it reports [`P2pWifi::ConcurrentWithStation`]:
//!
//! - Windows: the adapter and driver report Wi-Fi Direct alongside a station connection (the `Windows.Devices.WiFiDirect`
//!   APIs, `WiFiDirectAdvertisementPublisher` / `WiFiDirectDevice`, on a driver that supports the concurrency).
//!   Never a mobile hotspot or anything that disconnects the current network.
//! - Linux: `iw list` "valid interface combinations" allow a managed interface together with P2P-client or P2P-GO
//!   ([`iw_list_allows_station_with_p2p`]), and the managed connection is never brought down to make room (no
//!   NetworkManager or wpa_supplicant reconfiguration of the station interface).
//! - Android: `PackageManager.FEATURE_WIFI_DIRECT` and `WifiP2pManager`, on a device with documented STA + P2P
//!   concurrency. Never `LocalOnlyHotspot`, `WifiNetworkSpecifier` or anything that drops the station link; a phone
//!   has cellular, but its Wi-Fi Internet is kept too. (The boost hosts and joins Wi-Fi Direct groups for one
//!   transfer at a time; it is not a route the racer dials.)
//!
//! Unsure means [`P2pWifi::Unknown`], which is not used.

/// What this device's peer-to-peer Wi-Fi does to its normal Wi-Fi connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum P2pWifi {
    /// No peer-to-peer Wi-Fi route on this platform.
    Unsupported,
    /// The direct link runs beside the station connection (AWDL; Wi-Fi Direct on hardware that reports concurrency).
    ConcurrentWithStation,
    /// Making the direct link takes the device off its network.
    DropsStation,
    /// Not established either way.
    Unknown,
}

impl P2pWifi {
    /// This platform's answer at build time; a runtime probe may narrow it ([`crate::nearby::racer::Racer::set_p2p_wifi`]).
    pub const PLATFORM: P2pWifi = if cfg!(any(target_os = "macos", target_os = "ios")) {
        P2pWifi::ConcurrentWithStation
    } else {
        // Windows, Linux, Android: no implementation yet (see the module documentation for what one must check).
        P2pWifi::Unsupported
    };
}

impl Default for P2pWifi {
    fn default() -> Self {
        Self::PLATFORM
    }
}

/// `true` only when peer-to-peer Wi-Fi keeps the device's Wi-Fi connection up.
pub fn p2p_wifi_usable(capability: P2pWifi) -> bool {
    capability == P2pWifi::ConcurrentWithStation
}

/// Reads `iw list` output: does any valid interface combination allow a managed (station) interface together with a
/// P2P-client or P2P-GO interface at once? `false` when the section is missing or unreadable.
///
/// A combination looks like `* #{ managed } <= 1, #{ P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1,` followed by
/// `total <= 3, #channels <= 2`. Each `#{ ... } <= n` group admits up to `n` interfaces drawn from its types.
pub fn iw_list_allows_station_with_p2p(iw_list: &str) -> bool {
    let mut in_section = false;
    let mut combination = String::new();
    let mut found = false;
    let mut finish = |combination: &mut String| {
        if !combination.is_empty() {
            found |= combination_allows_station_with_p2p(combination);
            combination.clear();
        }
    };
    for line in iw_list.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("valid interface combinations") {
            in_section = true;
            continue;
        }
        if !in_section {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix('*') {
            finish(&mut combination);
            combination.push_str(rest);
        } else if trimmed.starts_with("total") || (trimmed.starts_with('#') && !combination.is_empty()) {
            combination.push(' ');
            combination.push_str(trimmed);
        } else {
            // The next attribute of the wiphy ends the section.
            finish(&mut combination);
            in_section = false;
        }
    }
    finish(&mut combination);
    found
}

/// One combination: the managed interface and a P2P client/GO interface must fit together, in one group allowing
/// two or more, or in two groups, and the total must allow both.
fn combination_allows_station_with_p2p(combination: &str) -> bool {
    let mut station_groups = Vec::new();
    let mut p2p_groups = Vec::new();
    let mut total = usize::MAX;
    let mut groups = Vec::new();
    let mut rest = combination;
    while let Some(start) = rest.find("#{") {
        let after = &rest[start + 2..];
        let Some(end) = after.find('}') else { break };
        let types: Vec<&str> = after[..end].split(',').map(str::trim).collect();
        let tail = &after[end + 1..];
        let limit = tail.trim_start().strip_prefix("<=").map(str::trim_start).and_then(leading_number);
        let Some(limit) = limit else { return false };
        groups.push((types, limit));
        rest = tail;
    }
    if let Some(at) = combination.find("total <=") {
        match leading_number(combination[at + "total <=".len()..].trim_start()) {
            Some(n) => total = n,
            None => return false,
        }
    }
    for (index, (types, limit)) in groups.iter().enumerate() {
        if *limit == 0 {
            continue;
        }
        if types.contains(&"managed") {
            station_groups.push((index, *limit));
        }
        if types.iter().any(|t| *t == "P2P-client" || *t == "P2P-GO") {
            p2p_groups.push((index, *limit));
        }
    }
    total >= 2 && station_groups.iter().any(|&(s, s_limit)| p2p_groups.iter().any(|&(p, _)| s != p || s_limit >= 2))
}

fn leading_number(text: &str) -> Option<usize> {
    let digits: String = text.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_concurrent_with_station_is_usable() {
        assert!(p2p_wifi_usable(P2pWifi::ConcurrentWithStation));
        for capability in [P2pWifi::Unsupported, P2pWifi::DropsStation, P2pWifi::Unknown] {
            assert!(!p2p_wifi_usable(capability), "{capability:?}");
        }
    }

    #[test]
    fn platform_value() {
        let apple = cfg!(any(target_os = "macos", target_os = "ios"));
        assert_eq!(P2pWifi::default(), P2pWifi::PLATFORM);
        assert_eq!(p2p_wifi_usable(P2pWifi::PLATFORM), apple);
    }

    const INTEL_AX: &str = "Wiphy phy0
\tmax # scan SSIDs: 20
\tvalid interface combinations:
\t\t * #{ managed } <= 1, #{ AP, P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1,
\t\t   total <= 3, #channels <= 2
\tHT Capability overrides:
";

    const STATION_ONLY: &str = "Wiphy phy0
\tvalid interface combinations:
\t\t * #{ managed, P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1,
\t\t   total <= 2, #channels <= 1
\tDevice supports TX status socket option.
";

    const SHARED_GROUP_OF_TWO: &str = "\tvalid interface combinations:
\t\t * #{ managed, P2P-client } <= 2,
\t\t   total <= 2, #channels <= 1
";

    const NO_P2P: &str = "\tvalid interface combinations:
\t\t * #{ managed } <= 1, #{ AP } <= 1,
\t\t   total <= 2, #channels <= 1
\t\t * #{ IBSS } <= 1,
\t\t   total <= 1, #channels <= 1
";

    const TOTAL_ONE: &str = "\tvalid interface combinations:
\t\t * #{ managed } <= 1, #{ P2P-GO } <= 1,
\t\t   total <= 1, #channels <= 1
";

    const SECOND_COMBINATION: &str = "\tvalid interface combinations:
\t\t * #{ IBSS } <= 1,
\t\t   total <= 1, #channels <= 1
\t\t * #{ managed } <= 2, #{ P2P-client, P2P-GO } <= 1,
\t\t   total <= 3, #channels <= 2
\tSupported commands:
";

    #[test]
    fn iw_list_combinations() {
        assert!(iw_list_allows_station_with_p2p(INTEL_AX));
        assert!(iw_list_allows_station_with_p2p(SHARED_GROUP_OF_TWO));
        assert!(iw_list_allows_station_with_p2p(SECOND_COMBINATION));
        assert!(!iw_list_allows_station_with_p2p(STATION_ONLY), "one slot: P2P would replace the station");
        assert!(!iw_list_allows_station_with_p2p(NO_P2P));
        assert!(!iw_list_allows_station_with_p2p(TOTAL_ONE));
        assert!(!iw_list_allows_station_with_p2p(""));
        assert!(!iw_list_allows_station_with_p2p("Wiphy phy0\n\tSupported interface modes:\n\t\t * managed\n"));
    }

    #[test]
    fn iw_list_unreadable_limits_are_refused() {
        let garbled = "\tvalid interface combinations:\n\t\t * #{ managed } <= x, #{ P2P-GO } <= 1,\n";
        assert!(!iw_list_allows_station_with_p2p(garbled));
    }
}
