//! Nearby discovery's pure parts (`service/discovery/`, ADR 0004): what the adapters advertise and read back (TXT
//! fields, callback slots), the merger that turns sightings into one candidate per person, the racer that decides
//! which dials to make and which session wins, the visibility deadline, the admission limits on listeners, the
//! firewall's listen decision (ADR 0015 § 15) and the one-resolve queue phones without a resolve callback need.
//!
//! None of this touches a radio, a socket or a clock: adapters are the platform's (the desktop helper's mDNS and
//! DNS-SD backends, a phone's NsdManager or NWBrowser, Bluetooth), and every time arrives as an argument, so the
//! scripted tests of ADR 0004 § Verification run here as they do against the helper's own merger and racer.
//!
//! Times are Unix seconds (`f64`) as the store keeps them; the continuous clock that cannot be set back is a
//! [`std::time::Duration`] since an arbitrary origin ([`crate::session::monotonic_now`]).

pub mod admission;
pub mod bluetooth;
pub mod callbacks;
pub mod firewall;
pub mod merger;
pub mod p2p_wifi;
pub mod racer;
pub mod resolve_queue;
pub mod txt;
pub mod visibility;

pub use szfriends_wire::RouteMethod;

/// `SZFriendsDiscoveryMethod`: which adapter saw an endpoint.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Method {
    /// LAN and, on Apple systems, peer-to-peer Wi-Fi (DNS-SD).
    Network = 0,
    Bluetooth = 1,
}

/// 8 bytes: a presence tag, or a callback tag of a pending Add by ID.
pub type Tag = [u8; szfriends_crypto::presence::TAG_LEN];

/// One observation of one endpoint by one method (`SZFriendsSighting`). Endpoint ids are opaque handles of the
/// adapter that made them, never identity.
#[derive(Clone, Debug, PartialEq)]
pub struct Sighting {
    pub method: Method,
    pub route: RouteMethod,
    pub endpoint: String,
    /// The device's private presence tag; `None` for a public entry, which carries none.
    pub presence_tag: Option<Tag>,
    /// The callback tags it advertises while its Add by ID requests wait.
    pub callback_tags: Vec<Tag>,
    pub public: bool,
    pub seen_at: f64,
}

/// The route order every comparison uses (ADR 0011 § Route rank): lower is better.
pub fn rank(route: RouteMethod) -> u8 {
    szfriends_wire::route::rank(route as u8)
}

/// `true` when `route` ranks strictly before `other`.
pub fn is_better(route: RouteMethod, other: RouteMethod) -> bool {
    rank(route) < rank(other)
}

/// Peer-to-peer Wi-Fi only where it keeps the device's Wi-Fi connection: the racer's check ([`p2p_wifi`]).
pub use p2p_wifi::{p2p_wifi_usable, P2pWifi};

/// Bonjour's service type. Tests use a type of their own ([`is_test_service_type`]), never this one.
pub const SERVICE_TYPE: &str = "_szfriends._tcp";

/// A test service type the helper honours in a test home (`SZFriendsHelperTestServiceTypeIsValid`): `_<name>._tcp`
/// with 1 to 15 letters, digits or hyphens, and never the production type, so a test helper is never found by, and
/// never answers, a real one on the same network.
pub fn is_test_service_type(service_type: &str) -> bool {
    let Some(name) = service_type.strip_prefix('_').and_then(|rest| rest.strip_suffix("._tcp")) else {
        return false;
    };
    service_type != SERVICE_TYPE
        && (1..=15).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// What the person sees per method (shared with the presentation).
pub use crate::presentation::AdapterState;

/// Permission as an adapter can read it without prompting (`SZFriendsPermission`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    /// No API answers without prompting (Local Network: browsing is the ask).
    Unknown,
    /// Never asked (Bluetooth on Apple systems, a runtime permission on Android).
    NotDetermined,
    Allowed,
    /// Denied or restricted.
    Denied,
}

/// ADR 0004 § Permissions at launch as one decision: start this adapter before any `activate`? Allowed: yes. Denied
/// or never asked: no. Unknown: only once the store records that the person was asked.
pub fn start_adapter_at_launch(permission: Permission, nearby_permissions_requested: bool) -> bool {
    match permission {
        Permission::Allowed => true,
        Permission::Denied | Permission::NotDetermined => false,
        Permission::Unknown => nearby_permissions_requested,
    }
}

/// The numbers of `SZFriendsNearbyLimits.h` and `SZFriendsDiscovery.h` that the helpers apply alike.
pub mod limits {
    /// Sessions with people who are not friends at once; a newcomer takes the idlest one's place.
    pub const STRANGER_SESSIONS_MAX: usize = 64;
    /// A stranger's session ends this long after the last frame that moved their request forward...
    pub const STRANGER_IDLE_SECONDS: f64 = 60.0;
    /// ...and this long after it went live, whatever it carries.
    pub const STRANGER_SESSION_LIFE_SECONDS: f64 = 180.0;
    /// Someone whose request found us nearby may open IK to the hidden listener this long after it began.
    pub const INCOMING_REQUEST_IK_WINDOW_SECONDS: f64 = 6.0 * 3600.0;
    /// An NN responder closes this long after RECEIVED, alike on every device.
    pub const BY_ID_REPLY_LINGER_SECONDS: f64 = 2.0;
    /// An NN session carries one request, briefly.
    pub const BY_ID_SESSION_LIFE_SECONDS: f64 = 10.0;
    /// Per sender key, one Add by ID request an hour is kept.
    pub const BY_ID_SENDER_INTERVAL_SECONDS: f64 = 3600.0;
    /// An Add by ID request that did not reach a device is tried there again after this.
    pub const BY_ID_RETRY_SECONDS: f64 = 900.0;
    /// A browse that failed is tried again this soon.
    pub const BROWSE_RETRY_SECONDS: f64 = 5.0;
    /// Failed attempts back off per person, doubling from the first to the last.
    pub const DIAL_BACKOFF_FIRST_SECONDS: f64 = 1.0;
    pub const DIAL_BACKOFF_MAX_SECONDS: f64 = 300.0;
    /// A session that stayed up this long was healthy: its end starts the backoff afresh.
    pub const HEALTHY_SESSION_SECONDS: f64 = 30.0;
    /// Entries say Connecting at most this long while a dial is under way.
    pub const CONNECTING_TIMEOUT_SECONDS: f64 = 12.0;
    /// A hidden listener of the last window keeps accepting this long after its entry left the air.
    pub const LISTENER_OVERLAP_SECONDS: f64 = 30.0;
    /// A day of an Add by ID request, which has a callback secret of its own.
    pub const CALLBACK_DAY_SECONDS: f64 = 86_400.0;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_service_types() {
        assert!(is_test_service_type("_szfe0a1b2c3d._tcp"));
        assert!(is_test_service_type("_a-b._tcp"));
        for bad in ["_szfriends._tcp", "szf._tcp", "_._tcp", "_toolongservicename1._tcp", "_a_b._tcp", "_ab._udp"] {
            assert!(!is_test_service_type(bad), "{bad}");
        }
    }

    #[test]
    fn launch_decision() {
        assert!(start_adapter_at_launch(Permission::Allowed, false));
        assert!(!start_adapter_at_launch(Permission::Denied, true));
        assert!(!start_adapter_at_launch(Permission::NotDetermined, true));
        assert!(!start_adapter_at_launch(Permission::Unknown, false));
        assert!(start_adapter_at_launch(Permission::Unknown, true));
    }

    #[test]
    fn rank_is_the_owners_order() {
        use RouteMethod::*;
        let order = [Lan, PeerToPeerWifi, Internet, Bluetooth, Relay, None];
        for pair in order.windows(2) {
            assert!(is_better(pair[0], pair[1]), "{:?} before {:?}", pair[0], pair[1]);
        }
    }
}
