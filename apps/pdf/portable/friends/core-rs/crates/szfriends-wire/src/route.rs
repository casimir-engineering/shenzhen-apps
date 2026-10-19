//! Route classes and the session race (ADR 0001 § Session race, ADR 0011 § Route rank).

use std::cmp::Ordering;

/// The route an initiator dialed over, as its handshake payload declares it. Wire values (`SZFriendsRouteMethod`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum RouteMethod {
    #[default]
    None = 0,
    /// Shared network, Wi-Fi or Ethernet.
    Lan = 1,
    /// A direct Wi-Fi link without a shared network (AWDL on Apple platforms only).
    PeerToPeerWifi = 2,
    /// L2CAP; carries traffic only while no Wi-Fi or Internet route works.
    Bluetooth = 3,
    /// A direct Internet connection (IPv6, port mapping, hole punching).
    Internet = 4,
    /// The relay, last resort.
    Relay = 5,
}

impl RouteMethod {
    pub fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::Lan,
            2 => Self::PeerToPeerWifi,
            3 => Self::Bluetooth,
            4 => Self::Internet,
            5 => Self::Relay,
            _ => Self::None,
        }
    }
}

/// The owner's order, which every comparison between routes uses: LAN, peer-to-peer Wi-Fi, Internet, Bluetooth,
/// relay. Lower is better. The wire numbers put Bluetooth (3) before Internet (4), so nothing compares them directly.
/// `None` and any value outside LAN through relay rank after the relay.
pub fn rank(route: u8) -> u8 {
    match route {
        1 => 0,
        2 => 1,
        4 => 2,
        3 => 3,
        5 => 4,
        _ => 5,
    }
}

/// Two live sessions with one friend: `true` keeps session A. Both sides reach the same answer from facts both hold:
/// the better route class as each initiator declared it wins; within a class, the session initiated by the lower
/// Ed25519 identity key (bytewise; a key that is a prefix of the other sorts first). Identical class and key mean
/// one side dialed twice: `true`, and only that initiator acts on it.
pub fn session_a_wins(route_a: u8, initiator_key_a: &[u8], route_b: u8, initiator_key_b: &[u8]) -> bool {
    let (rank_a, rank_b) = (rank(route_a), rank(route_b));
    if rank_a != rank_b {
        return rank_a < rank_b;
    }
    initiator_key_a.cmp(initiator_key_b) != Ordering::Greater
}
