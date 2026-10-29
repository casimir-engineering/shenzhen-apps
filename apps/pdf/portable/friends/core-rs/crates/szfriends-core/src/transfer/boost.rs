//! The Wi-Fi Direct boost (ADR 0019), sans-IO: when two friends' devices found each other only by Bluetooth and are
//! not on the same network, a large transfer may move over a direct Wi-Fi link that one device hosts and the other
//! joins, after the person on each device that would lose its Internet connection said Go faster.
//!
//! Four pieces, each pure and tested here; the helpers move frames, call the platform and keep the record on disk:
//!
//! - **When** ([`worth_it`], [`not_on_same_network`]): Bluetooth carries the group alone, the network had its chances,
//!   and the direct link would save at least [`SAVES_AT_LEAST`] seconds of this transfer.
//! - **Who hosts and who is asked** ([`role`], [`Cost`]): the pairing that takes fewer devices off their Wi-Fi, and a
//!   question only on a device whose Wi-Fi is its only way online.
//! - **The negotiation** ([`Boost`]): BOOST frames on the group's existing encrypted session (PROPOSE, READY, HOST,
//!   END, DECLINE). The network name and the one-time passphrase ([`Link`]) are random per boost and travel only in
//!   HOST, inside the Noise session; the joining side then dials an ordinary lane, whose token binds it to that same
//!   session (ADR 0018 § 6), so it reaches the same identity or nothing.
//! - **Coming back** ([`Rejoin`], [`Saved`]): the network to go back to is written down before leaving it, the device
//!   rejoins it as soon as the boost ends for any reason, on the next launch after a crash too, then checks it is
//!   online again and says so when it is not.

use std::net::IpAddr;
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_wire::consts::{boost_ability, boost_reason, boost_step, BOOST_PASSPHRASE_MAX, BOOST_PASSPHRASE_MIN};
use szfriends_wire::{tag, Frame, FrameType};

// ----- when -----

/// The group must have been on Bluetooth alone this long with the friend's device nowhere on the network.
pub const BLUETOOTH_ONLY_FOR: Duration = Duration::from_secs(10);
/// Or this many lane dials on the network must have failed since the group formed.
pub const NETWORK_TRIES: u32 = 3;
/// The boost is proposed only when it saves at least this many seconds of the transfer.
pub const SAVES_AT_LEAST: f64 = 20.0;
/// Hosting, joining and the lane's handshake, as the estimate counts them.
pub const SETUP_SECONDS: f64 = 15.0;
/// What the estimate assumes a direct link moves, in bytes per second: well under what Wi-Fi Direct does, so the
/// question never promises more than happens.
pub const DIRECT_BYTES_PER_SECOND: f64 = 8e6;
/// Bluetooth's rate until a lane measured it (the scheduler's typical figure).
pub const BLUETOOTH_BYTES_PER_SECOND: f64 = 0.15e6;
/// After the direct lane is up this long, it must be faster than Bluetooth or the boost ends.
pub const MEASURE_FOR: Duration = Duration::from_secs(6);
/// From both sides agreeing to the lane being up, at most this long.
pub const LINK_WITHIN: Duration = Duration::from_secs(45);

/// How long the transfer takes over Bluetooth, and with the boost (setup included), in seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Estimate {
    pub bluetooth_seconds: f64,
    pub direct_seconds: f64,
}

impl Estimate {
    pub fn saved_seconds(&self) -> f64 {
        self.bluetooth_seconds - self.direct_seconds
    }
}

/// What `remaining` bytes cost over Bluetooth at `bluetooth_rate` (bytes per second; 0 when not measured yet) and
/// over the direct link.
pub fn estimate(remaining: u64, bluetooth_rate: f64) -> Estimate {
    let rate = if bluetooth_rate > 0.0 { bluetooth_rate } else { BLUETOOTH_BYTES_PER_SECOND };
    let bytes = remaining as f64;
    Estimate { bluetooth_seconds: bytes / rate, direct_seconds: SETUP_SECONDS + bytes / DIRECT_BYTES_PER_SECOND }
}

/// The estimate when the boost saves at least [`SAVES_AT_LEAST`] seconds; `None` for anything smaller.
pub fn worth_it(remaining: u64, bluetooth_rate: f64) -> Option<Estimate> {
    let estimate = estimate(remaining, bluetooth_rate);
    (estimate.saved_seconds() >= SAVES_AT_LEAST).then_some(estimate)
}

/// What the helper knows of a friend's device right now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Situation {
    /// Every live session of the group runs over Bluetooth.
    pub bluetooth_only: bool,
    /// How long the group has run over Bluetooth alone.
    pub bluetooth_only_for: Duration,
    /// The friend's device is seen on the local network (or by peer-to-peer Wi-Fi) now.
    pub seen_on_network: bool,
    /// Lane dials to the friend's device on the network that failed since the group formed.
    pub network_failures: u32,
}

/// The two devices found each other only by Bluetooth and are not on the same network: the device was never seen on
/// the network in [`BLUETOOTH_ONLY_FOR`], or it was and [`NETWORK_TRIES`] dials there failed.
pub fn not_on_same_network(situation: &Situation) -> bool {
    situation.bluetooth_only
        && situation.bluetooth_only_for >= BLUETOOTH_ONLY_FOR
        && (!situation.seen_on_network || situation.network_failures >= NETWORK_TRIES)
}

// ----- who hosts, who is asked -----

/// What a device can do with direct Wi-Fi (BOOST's Abilities).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Abilities {
    /// It can host a link others join by name and passphrase (an Android group owner).
    pub host: bool,
    /// It can join such a link.
    pub join: bool,
    /// Hosting keeps it on its own Wi-Fi network (station and group at once).
    pub host_keeps_wifi: bool,
    /// Joining keeps it on its own Wi-Fi network (a Wi-Fi Direct client beside the station).
    pub join_keeps_wifi: bool,
}

impl Abilities {
    /// Android: hosts as a group owner and joins as a Wi-Fi Direct client; both keep its Wi-Fi where the hardware
    /// runs station and P2P at once (`concurrent`).
    pub fn android(concurrent: bool) -> Self {
        Self { host: true, join: true, host_keeps_wifi: concurrent, join_keeps_wifi: concurrent }
    }

    /// A Mac or an iPhone: joins only, as a Wi-Fi client, which takes it off its own network.
    pub fn joins_only() -> Self {
        Self { join: true, ..Self::default() }
    }

    pub fn byte(self) -> u8 {
        let mut byte = 0;
        for (on, bit) in [
            (self.host, boost_ability::HOST),
            (self.join, boost_ability::JOIN),
            (self.host_keeps_wifi, boost_ability::HOST_KEEPS_WIFI),
            (self.join_keeps_wifi, boost_ability::JOIN_KEEPS_WIFI),
        ] {
            if on {
                byte |= bit;
            }
        }
        byte
    }

    /// Unknown bits are ignored.
    pub fn from_byte(byte: u8) -> Self {
        Self {
            host: byte & boost_ability::HOST != 0,
            join: byte & boost_ability::JOIN != 0,
            host_keeps_wifi: byte & boost_ability::HOST_KEEPS_WIFI != 0,
            join_keeps_wifi: byte & boost_ability::JOIN_KEEPS_WIFI != 0,
        }
    }

    /// Anything at all: a device that can neither host nor join never proposes or agrees.
    pub fn any(self) -> bool {
        self.host || self.join
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Host,
    Join,
}

/// This side's role, the same on both sides: of the pairings that work, the one that takes fewer devices off their
/// Wi-Fi; on a tie, the side whose identity key sorts first hosts. `None` when neither pairing works (two Macs, a Mac
/// and an iPhone: they have AWDL instead, which needs none of this).
pub fn role(local: Abilities, peer: Abilities, local_sorts_first: bool) -> Option<Role> {
    let cost = |host: Abilities, joiner: Abilities| u8::from(!host.host_keeps_wifi) + u8::from(!joiner.join_keeps_wifi);
    let local_hosts = (local.host && peer.join).then(|| cost(local, peer));
    let peer_hosts = (peer.host && local.join).then(|| cost(peer, local));
    match (local_hosts, peer_hosts) {
        (Some(a), Some(b)) if a == b => Some(if local_sorts_first { Role::Host } else { Role::Join }),
        (Some(a), Some(b)) => Some(if a < b { Role::Host } else { Role::Join }),
        (Some(_), None) => Some(Role::Host),
        (None, Some(_)) => Some(Role::Join),
        (None, None) => None,
    }
}

/// How this device is online right now, from the platform.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Connectivity {
    /// On a Wi-Fi network.
    pub on_wifi: bool,
    /// Its name, when the platform tells it (shown to the person on this device only, never sent anywhere).
    pub wifi_name: Option<String>,
    /// Also online by cable.
    pub wired: bool,
    /// Also online by mobile data.
    pub mobile: bool,
}

/// What the boost costs this device's connections, which decides whether its person is asked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cost {
    /// Nothing changes for its connections.
    Nothing,
    /// It leaves its Wi-Fi network but stays online another way: no question, and the transfer's note says so.
    LeavesWifi { network: Option<String>, over_mobile: bool },
    /// It leaves the Wi-Fi network that is its only way online: its person is asked first.
    LeavesInternet { network: Option<String> },
}

impl Cost {
    pub fn of(role: Role, local: Abilities, connectivity: &Connectivity) -> Self {
        let keeps = match role {
            Role::Host => local.host_keeps_wifi,
            Role::Join => local.join_keeps_wifi,
        };
        if keeps || !connectivity.on_wifi {
            return Self::Nothing;
        }
        let network = connectivity.wifi_name.clone().filter(|n| !n.is_empty());
        if connectivity.wired || connectivity.mobile {
            Self::LeavesWifi { network, over_mobile: !connectivity.wired }
        } else {
            Self::LeavesInternet { network }
        }
    }

    pub fn asks(&self) -> bool {
        matches!(self, Self::LeavesInternet { .. })
    }

    pub fn leaves_wifi(&self) -> bool {
        !matches!(self, Self::Nothing)
    }
}

// ----- the link -----

/// A direct link's network name and passphrase, random per boost. The name says nothing about Friends or either
/// person: "DIRECT-" and two characters, as Android requires of a group's name, then eight more.
#[derive(Clone, PartialEq, Eq)]
pub struct Link {
    pub network: String,
    pub passphrase: String,
}

impl std::fmt::Debug for Link {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Link").field("network", &self.network).finish_non_exhaustive()
    }
}

const ALPHANUMERIC: &[u8; 62] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
/// Characters of the passphrase: 20 of 62, about 119 bits.
const PASSPHRASE_CHARACTERS: usize = 20;

impl Link {
    pub fn new() -> Self {
        let mut random = [0u8; 64];
        szfriends_crypto::random_bytes(&mut random);
        Self::from_random(&random)
    }

    /// The link these random bytes make (each byte picks a character; the bias of 256 mod 62 is under 2 %).
    pub fn from_random(random: &[u8; 64]) -> Self {
        let pick = |bytes: &[u8]| -> String {
            bytes.iter().map(|b| char::from(ALPHANUMERIC[usize::from(*b) % ALPHANUMERIC.len()])).collect()
        };
        Self {
            network: format!("DIRECT-{}{}", pick(&random[..2]), pick(&random[2..10])),
            passphrase: pick(&random[10..10 + PASSPHRASE_CHARACTERS]),
        }
    }

    /// What a joining side accepts: a name Android would host ("DIRECT-" and printable ASCII, at most 32 bytes) and
    /// a WPA2 passphrase of printable ASCII.
    pub fn valid(&self) -> bool {
        let printable = |s: &str| s.bytes().all(|b| (0x21..0x7f).contains(&b));
        self.network.starts_with("DIRECT-")
            && self.network.len() <= 32
            && self.network.len() >= 9
            && printable(&self.network)
            && (BOOST_PASSPHRASE_MIN..=BOOST_PASSPHRASE_MAX).contains(&self.passphrase.len())
            && printable(&self.passphrase)
    }
}

impl Default for Link {
    fn default() -> Self {
        Self::new()
    }
}

/// The host's address on its link: a private IPv4 address or an IPv6 link-local or unique local one, so a peer can
/// never send the joining side's lane anywhere else.
pub fn private_address(address: &IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => v4.is_private() || v4.is_link_local(),
        IpAddr::V6(v6) => {
            let first = v6.segments()[0];
            (first & 0xffc0) == 0xfe80 || (first & 0xfe00) == 0xfc00
        }
    }
}

// ----- frames -----

mod frames;
pub use frames::*;

// ----- the negotiation -----

/// Where one boost stands on this side.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// This side proposed and waits for the peer's READY or DECLINE.
    Proposed,
    /// Its person is being asked (the transfer shows Go faster and Not now).
    Asking,
    /// This side said READY and waits for the peer's READY (or, joining, its HOST).
    Agreed,
    /// Hosting: the link is being set up, or is up and waits for the lane.
    Hosting,
    /// Joining the host's link, then dialing the lane.
    Joining,
    /// The direct lane carries the transfer.
    Direct,
    /// Over: nothing more happens, apart from coming back ([`Rejoin`]).
    Ended,
}

/// What the helper does for a boost.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    /// Send BOOST with this message on the group's control session.
    Send(Message),
    /// Ask this device's person on the transfer's row (Go faster, Not now).
    Ask(Cost),
    /// Take the question off the row (answered, or the boost ended first).
    Unask,
    /// Host `link`; answer with [`Boost::hosted`] or [`Boost::failed`].
    Host(Link),
    /// Write down the Wi-Fi network to come back to ([`Rejoin::leaving`]), then join `link`; answer with
    /// [`Boost::joined`] or [`Boost::failed`].
    Join(Link),
    /// Dial a lane on the direct link (route peer-to-peer Wi-Fi), bound to the group by its token as any lane is.
    Dial { address: IpAddr, port: u16 },
    /// Whether the scheduler may use a direct Wi-Fi lane on a device where it would otherwise close it.
    AllowDirectLane(bool),
    /// Take the hosted link down.
    StopHosting,
    /// Leave the joined link and go back to the network written down ([`Rejoin::come_back`]).
    LeaveJoined,
}

/// One boost of one group, on one side.
#[derive(Debug)]
pub struct Boost {
    transfer: [u8; 16],
    local: Abilities,
    connectivity: Connectivity,
    local_sorts_first: bool,
    role: Option<Role>,
    cost: Cost,
    phase: Phase,
    sent_ready: bool,
    got_ready: bool,
    link: Option<Link>,
    pending_dial: Option<(IpAddr, u16)>,
    hosting: bool,
    joining: bool,
    agreed_at: Option<Duration>,
    lane_at: Option<Duration>,
    end_reason: Option<u8>,
    declined_by_person: bool,
    effects: Vec<Effect>,
}

impl Boost {
    fn new(transfer: [u8; 16], local: Abilities, connectivity: Connectivity, local_sorts_first: bool) -> Self {
        Self {
            transfer,
            local,
            connectivity,
            local_sorts_first,
            role: None,
            cost: Cost::Nothing,
            phase: Phase::Proposed,
            sent_ready: false,
            got_ready: false,
            link: None,
            pending_dial: None,
            hosting: false,
            joining: false,
            agreed_at: None,
            lane_at: None,
            end_reason: None,
            declined_by_person: false,
            effects: Vec::new(),
        }
    }

    /// This side saw the transfer crawl over Bluetooth ([`worth_it`], [`not_on_same_network`]) and proposes.
    pub fn propose(transfer: [u8; 16], local: Abilities, connectivity: Connectivity, local_sorts_first: bool) -> Self {
        let mut boost = Self::new(transfer, local, connectivity, local_sorts_first);
        boost.effects.push(Effect::Send(Message::Propose { abilities: local }));
        boost
    }

    /// The peer proposed. A transfer this side's person already said Not now to is declined by the helper before
    /// it gets here ([`Boost::declined_by_person`]).
    pub fn proposed(
        transfer: [u8; 16],
        local: Abilities,
        peer: Abilities,
        connectivity: Connectivity,
        local_sorts_first: bool,
        now: Duration,
    ) -> Self {
        let mut boost = Self::new(transfer, local, connectivity, local_sorts_first);
        boost.peer_said(peer, now);
        boost
    }

    pub fn transfer(&self) -> &[u8; 16] {
        &self.transfer
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn role(&self) -> Option<Role> {
        self.role
    }

    pub fn cost(&self) -> &Cost {
        &self.cost
    }

    /// Why it ended, once [`Phase::Ended`].
    pub fn end_reason(&self) -> Option<u8> {
        self.end_reason
    }

    /// This side's person said Not now, or the peer's did: never propose again for this transfer.
    pub fn declined_by_person(&self) -> bool {
        self.declined_by_person
    }

    /// The direct lane is up and carrying the transfer.
    pub fn direct(&self) -> bool {
        self.phase == Phase::Direct
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }

}

mod steps;

// ----- coming back -----

mod rejoin;
pub use rejoin::*;

#[cfg(test)]
mod tests;
