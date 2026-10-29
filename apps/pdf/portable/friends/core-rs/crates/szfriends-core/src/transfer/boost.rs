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

/// One BOOST frame's meaning.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Message {
    Propose { abilities: Abilities },
    Ready { abilities: Abilities },
    Host { link: Link, address: IpAddr, port: u16 },
    End { reason: u8 },
    Decline { reason: u8 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageError {
    NotBoost,
    UnknownStep(u8),
    /// A field the step needs is missing or malformed.
    Missing(u8),
    /// HOST names a link a joining side refuses ([`Link::valid`], [`private_address`]).
    BadLink,
}

/// BOOST for `transfer` (the id of the file it is for).
pub fn encode(transfer: &[u8; 16], message: &Message) -> Frame {
    let frame = Frame::new(FrameType::Boost).with(tag::ID, transfer.to_vec());
    match message {
        Message::Propose { abilities } => {
            frame.with(tag::STEP, [boost_step::PROPOSE]).with(tag::ABILITIES, [abilities.byte()])
        }
        Message::Ready { abilities } => {
            frame.with(tag::STEP, [boost_step::READY]).with(tag::ABILITIES, [abilities.byte()])
        }
        Message::Host { link, address, port } => {
            let address = match address {
                IpAddr::V4(v4) => v4.octets().to_vec(),
                IpAddr::V6(v6) => v6.octets().to_vec(),
            };
            frame
                .with(tag::STEP, [boost_step::HOST])
                .with(tag::NETWORK, link.network.as_bytes().to_vec())
                .with(tag::PASSPHRASE, link.passphrase.as_bytes().to_vec())
                .with(tag::ADDRESS, address)
                .with(tag::PORT, port.to_be_bytes())
        }
        Message::End { reason } => frame.with(tag::STEP, [boost_step::END]).with(tag::REASON, [*reason]),
        Message::Decline { reason } => frame.with(tag::STEP, [boost_step::DECLINE]).with(tag::REASON, [*reason]),
    }
}

/// The transfer and the message of a BOOST the codec accepted.
pub fn decode(frame: &Frame) -> Result<([u8; 16], Message), MessageError> {
    if frame.frame_type != FrameType::Boost {
        return Err(MessageError::NotBoost);
    }
    let field = |t: u8| frame.fields.get(&t).ok_or(MessageError::Missing(t));
    let transfer: [u8; 16] = field(tag::ID)?.as_slice().try_into().map_err(|_| MessageError::Missing(tag::ID))?;
    let byte = |t: u8| field(t).and_then(|v| v.first().copied().ok_or(MessageError::Missing(t)));
    let message = match byte(tag::STEP)? {
        boost_step::PROPOSE => Message::Propose { abilities: Abilities::from_byte(byte(tag::ABILITIES)?) },
        boost_step::READY => Message::Ready { abilities: Abilities::from_byte(byte(tag::ABILITIES)?) },
        boost_step::HOST => {
            let text =
                |t: u8| field(t).and_then(|v| String::from_utf8(v.clone()).map_err(|_| MessageError::Missing(t)));
            let link = Link { network: text(tag::NETWORK)?, passphrase: text(tag::PASSPHRASE)? };
            let address = match field(tag::ADDRESS)?.as_slice() {
                bytes if bytes.len() == 4 => IpAddr::from(<[u8; 4]>::try_from(bytes).expect("4")),
                bytes if bytes.len() == 16 => IpAddr::from(<[u8; 16]>::try_from(bytes).expect("16")),
                _ => return Err(MessageError::Missing(tag::ADDRESS)),
            };
            let port = field(tag::PORT)?;
            let port = u16::from_be_bytes([port[0], port[1]]);
            if !link.valid() || !private_address(&address) || port == 0 {
                return Err(MessageError::BadLink);
            }
            Message::Host { link, address, port }
        }
        boost_step::END => Message::End { reason: byte(tag::REASON).unwrap_or(boost_reason::DONE) },
        boost_step::DECLINE => Message::Decline { reason: byte(tag::REASON).unwrap_or(boost_reason::FAILED) },
        other => return Err(MessageError::UnknownStep(other)),
    };
    Ok((transfer, message))
}

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

    /// The peer's abilities arrived (its PROPOSE, or its READY to this side's PROPOSE): roles, cost, and the
    /// question or READY.
    fn peer_said(&mut self, peer: Abilities, now: Duration) {
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

    fn agree(&mut self, now: Duration) {
        self.sent_ready = true;
        self.phase = Phase::Agreed;
        self.effects.push(Effect::Send(Message::Ready { abilities: self.local }));
        self.both_agreed(now);
    }

    fn both_agreed(&mut self, now: Duration) {
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

    fn end(&mut self, reason: u8, tell: bool, _now: Duration) {
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

// ----- coming back -----

/// What a device writes down before it leaves its Wi-Fi network for a joined link, so it comes back after the boost,
/// after a crash too. Kept in the helper's state directory (`direct-wifi.json`), never sent anywhere.
#[derive(Clone, Debug, PartialEq)]
pub struct Saved {
    /// The network to go back to: the platform's own reference (a name, or Android's network id); `None` when the
    /// device was on no Wi-Fi network, so coming back is only leaving the link.
    pub network: Option<String>,
    /// Its name as the person knows it, for "Couldn't rejoin …".
    pub network_name: Option<String>,
    /// The link joined, so a launch after a crash leaves it only if the device is still on it.
    pub joined: String,
    /// Unix time it left.
    pub left_at: f64,
}

impl Saved {
    pub fn to_json(&self) -> Value {
        json!({
            "version": 1,
            "network": self.network,
            "network_name": self.network_name,
            "joined": self.joined,
            "left_at": self.left_at,
        })
    }

    /// `None` for anything else, a later version included: such a record is left alone.
    pub fn from_json(value: &Value) -> Option<Self> {
        if value.get("version")?.as_u64()? != 1 {
            return None;
        }
        let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
        Some(Self {
            network: text("network"),
            network_name: text("network_name"),
            joined: text("joined").filter(|j| !j.is_empty())?,
            left_at: value.get("left_at")?.as_f64()?,
        })
    }
}

/// Rejoining is tried this many times, this far apart.
pub const REJOIN_TRIES: u32 = 3;
pub const REJOIN_AGAIN_AFTER: Duration = Duration::from_secs(3);
/// After rejoining, the Internet must be back within this long, checked this often.
pub const ONLINE_WITHIN: Duration = Duration::from_secs(20);
pub const CHECK_EVERY: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq)]
pub enum RejoinEffect {
    /// Write the record (before leaving the network).
    Write(Saved),
    /// Leave the joined link (if still on it) and rejoin this network (`None`: only leave).
    Rejoin { network: Option<String>, joined: String },
    /// Is the device online again? Answer with [`Rejoin::online`].
    CheckOnline,
    /// Delete the record: back where it was.
    Forget,
    /// Tell the person their device did not get back on that network (or back online) by itself.
    Tell { network_name: Option<String> },
}

#[derive(Clone, Debug, PartialEq)]
enum RejoinStep {
    Idle,
    /// Off its network, on a joined link (the record is written).
    Away(Saved),
    Rejoining {
        saved: Saved,
        tries: u32,
        at: Duration,
    },
    Checking {
        saved: Saved,
        since: Duration,
        at: Duration,
    },
    /// Gave up and told the person.
    Failed,
}

/// One device's way back to its own Wi-Fi network.
#[derive(Debug)]
pub struct Rejoin {
    step: RejoinStep,
    effects: Vec<RejoinEffect>,
}

impl Default for Rejoin {
    fn default() -> Self {
        Self { step: RejoinStep::Idle, effects: Vec::new() }
    }
}

impl Rejoin {
    /// At launch, with the record a previous run left (it crashed or was killed while away): come back now.
    pub fn launched(record: Option<Saved>, now: Duration) -> Self {
        let mut rejoin = Self::default();
        if let Some(saved) = record {
            rejoin.step = RejoinStep::Away(saved);
            rejoin.come_back(now);
        }
        rejoin
    }

    pub fn away(&self) -> bool {
        !matches!(self.step, RejoinStep::Idle | RejoinStep::Failed)
    }

    pub fn take_effects(&mut self) -> Vec<RejoinEffect> {
        std::mem::take(&mut self.effects)
    }

    /// About to leave the network for a link: the record is written first.
    pub fn leaving(&mut self, saved: Saved) {
        self.effects.push(RejoinEffect::Write(saved.clone()));
        self.step = RejoinStep::Away(saved);
    }

    /// The boost ended (finished, failed, cancelled, slower, the session gone) or the app quits: rejoin now.
    pub fn come_back(&mut self, now: Duration) {
        if let RejoinStep::Away(saved) = &self.step {
            let saved = saved.clone();
            self.effects.push(RejoinEffect::Rejoin { network: saved.network.clone(), joined: saved.joined.clone() });
            self.step = RejoinStep::Rejoining { saved, tries: 1, at: now };
        }
    }

    /// The platform's answer to [`RejoinEffect::Rejoin`].
    pub fn rejoined(&mut self, ok: bool, now: Duration) {
        let RejoinStep::Rejoining { saved, tries, .. } = &self.step else { return };
        let (saved, tries) = (saved.clone(), *tries);
        if ok {
            if saved.network.is_none() {
                // It was on no Wi-Fi network: off the link is back where it was.
                self.done();
            } else {
                self.effects.push(RejoinEffect::CheckOnline);
                self.step = RejoinStep::Checking { saved, since: now, at: now };
            }
        } else if tries >= REJOIN_TRIES {
            self.give_up(&saved);
        } else {
            self.step = RejoinStep::Rejoining { saved, tries, at: now };
        }
    }

    /// The platform's answer to [`RejoinEffect::CheckOnline`].
    pub fn online(&mut self, online: bool, now: Duration) {
        let RejoinStep::Checking { saved, since, .. } = &self.step else { return };
        let (saved, since) = (saved.clone(), *since);
        if online {
            self.done();
        } else if now.saturating_sub(since) >= ONLINE_WITHIN {
            self.give_up(&saved);
        } else {
            self.step = RejoinStep::Checking { saved, since, at: now };
        }
    }

    /// Retries: rejoining again after [`REJOIN_AGAIN_AFTER`], checking again every [`CHECK_EVERY`].
    pub fn tick(&mut self, now: Duration) {
        match &self.step {
            RejoinStep::Rejoining { saved, tries, at } if now.saturating_sub(*at) >= REJOIN_AGAIN_AFTER => {
                let (saved, tries) = (saved.clone(), *tries);
                // A try still unanswered counts as failed after the wait.
                if tries >= REJOIN_TRIES {
                    self.give_up(&saved);
                    return;
                }
                self.effects
                    .push(RejoinEffect::Rejoin { network: saved.network.clone(), joined: saved.joined.clone() });
                self.step = RejoinStep::Rejoining { saved, tries: tries + 1, at: now };
            }
            RejoinStep::Checking { saved, since, at } if now.saturating_sub(*at) >= CHECK_EVERY => {
                let (saved, since) = (saved.clone(), *since);
                if now.saturating_sub(since) >= ONLINE_WITHIN {
                    self.give_up(&saved);
                    return;
                }
                self.effects.push(RejoinEffect::CheckOnline);
                self.step = RejoinStep::Checking { saved, since, at: now };
            }
            _ => {}
        }
    }

    fn done(&mut self) {
        self.effects.push(RejoinEffect::Forget);
        self.step = RejoinStep::Idle;
    }

    fn give_up(&mut self, saved: &Saved) {
        // The record goes too: the person now decides which network to be on, and a later launch must not fight it.
        self.effects.push(RejoinEffect::Forget);
        self.effects.push(RejoinEffect::Tell { network_name: saved.network_name.clone() });
        self.step = RejoinStep::Failed;
    }
}

#[cfg(test)]
mod tests;
