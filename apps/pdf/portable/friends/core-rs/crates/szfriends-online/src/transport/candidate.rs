//! Candidates (`SZFriendsOnlineCandidate.m`, `SZFriendsNATPrediction.m`): strict parsing, address classes, the rules
//! on what is offered and dialled (ADR 0009 § Who may reach the stack, ADR 0011 § VPN and tunnels), the technique of a
//! selected pair, and the candidate lines the NAT techniques make.

use std::net::{IpAddr, SocketAddr};

use super::{Kind, Purpose, Technique};
use crate::nat::endpoint::{canonical, host_text};

const FOUNDATION_MAX: usize = 32;
const LINE_MAX: usize = 512;

/// What an address is for the transport's rules.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AddressClass {
    /// Never sent or dialled: unspecified, multicast, broadcast, link-local, reserved, IPv4-mapped or -compatible
    /// IPv6, site-local, anything outside 2000::/3 and fc00::/7.
    Unusable,
    /// Tests only.
    Loopback,
    /// 10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7.
    Private,
    PublicIpv4,
    GlobalIpv6,
}

pub fn classify_address(ip: IpAddr) -> AddressClass {
    match ip {
        IpAddr::V4(v4) => {
            let b = v4.octets();
            match b {
                [0, ..] => AddressClass::Unusable,
                [127, ..] => AddressClass::Loopback,
                [a, ..] if a >= 224 => AddressClass::Unusable,
                [169, 254, ..] => AddressClass::Unusable,
                [10, ..] => AddressClass::Private,
                [172, b, ..] if b & 0xf0 == 16 => AddressClass::Private,
                [192, 168, ..] => AddressClass::Private,
                [100, b, ..] if b & 0xc0 == 64 => AddressClass::Private,
                _ => AddressClass::PublicIpv4,
            }
        }
        IpAddr::V6(v6) => {
            let b = v6.octets();
            if v6.is_loopback() {
                AddressClass::Loopback
            } else if b[0] & 0xe0 == 0x20 {
                AddressClass::GlobalIpv6
            } else if b[0] & 0xfe == 0xfc {
                AddressClass::Private
            } else {
                AddressClass::Unusable
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CandidateType {
    Host,
    ServerReflexive,
    PeerReflexive,
    Relay,
}

impl CandidateType {
    fn name(self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::ServerReflexive => "srflx",
            Self::PeerReflexive => "prflx",
            Self::Relay => "relay",
        }
    }
}

/// One RFC 8839 candidate, parsed strictly: component 1, UDP or TCP with tcptype so, a numeric address, a port above
/// 0. Re-serialised without "a=", the related address or extensions, so nothing local leaks through raddr.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub foundation: String,
    pub tcp: bool,
    pub priority: u32,
    pub address: SocketAddr,
    pub kind: CandidateType,
    pub related_port: u16,
    pub class: AddressClass,
}

fn ice_chars(text: &str, max: usize) -> bool {
    !text.is_empty() && text.len() <= max && text.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'+' || c == b'/')
}

fn number(text: &str, max: u64) -> Option<u64> {
    if text.is_empty() || text.len() > 10 || !text.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    text.parse::<u64>().ok().filter(|v| *v <= max)
}

impl Candidate {
    /// "candidate:..." or "a=candidate:...".
    pub fn parse(line: &str) -> Option<Self> {
        if line.is_empty() || line.len() > LINE_MAX {
            return None;
        }
        let value = line.strip_prefix("a=").unwrap_or(line).strip_prefix("candidate:")?;
        let tokens: Vec<&str> = value.split(' ').collect();
        if tokens.len() < 8 || tokens.len() % 2 != 0 {
            return None;
        }
        if !ice_chars(tokens[0], FOUNDATION_MAX) || number(tokens[1], 256)? != 1 || tokens[6] != "typ" {
            return None;
        }
        let priority = number(tokens[3], u64::from(u32::MAX))? as u32;
        let port = number(tokens[5], 65535)? as u16;
        let tcp = match tokens[2].to_ascii_uppercase().as_str() {
            "UDP" => false,
            "TCP" => true,
            _ => return None,
        };
        let kind = match tokens[7] {
            "host" => CandidateType::Host,
            "srflx" => CandidateType::ServerReflexive,
            "prflx" => CandidateType::PeerReflexive,
            "relay" => CandidateType::Relay,
            _ => return None,
        };
        // Numeric only, and not canonicalised: an IPv4-mapped IPv6 address stays IPv6 and is unusable.
        let ip = (!tokens[4].contains('%')).then(|| tokens[4].parse::<IpAddr>().ok()).flatten()?;
        if port == 0 {
            return None;
        }
        let (mut related_port, mut tcp_type) = (0u16, None);
        for pair in tokens[8..].chunks(2) {
            if pair[0].is_empty() || pair[1].is_empty() {
                return None;
            }
            match pair[0] {
                "rport" => related_port = number(pair[1], 65535)? as u16,
                "tcptype" => tcp_type = Some(pair[1]),
                _ => {}
            }
        }
        // Only simultaneous-open TCP candidates (RFC 6544 "so").
        if tcp != tcp_type.is_some() || (tcp && tcp_type != Some("so")) {
            return None;
        }
        Some(Self {
            foundation: tokens[0].to_owned(),
            tcp,
            priority,
            address: SocketAddr::new(ip, port),
            kind,
            related_port,
            class: classify_address(ip),
        })
    }

    /// The canonical line, what is sent and applied.
    pub fn line(&self) -> String {
        format!(
            "candidate:{} 1 {} {} {} {} typ {}{}",
            self.foundation,
            if self.tcp { "TCP" } else { "UDP" },
            self.priority,
            self.address.ip(),
            self.address.port(),
            self.kind.name(),
            if self.tcp { " tcptype so" } else { "" }
        )
    }

    /// "UDP address port", to match a selected pair.
    pub fn endpoint(&self) -> String {
        format!("{} {} {}", if self.tcp { "TCP" } else { "UDP" }, self.address.ip(), self.address.port())
    }

    pub fn ipv6(&self) -> bool {
        self.address.is_ipv6()
    }
}

fn address_allowed(class: AddressClass, purpose: Purpose, allow_loopback: bool) -> bool {
    match class {
        AddressClass::Loopback => allow_loopback,
        AddressClass::Private => purpose == Purpose::Friend,
        AddressClass::PublicIpv4 | AddressClass::GlobalIpv6 => true,
        AddressClass::Unusable => false,
    }
}

/// The testing configuration's allowances. `test_links`: tests of links on one computer, whose links may use what a
/// test has (loopback host candidates, a local relay's private relayed address); production never takes these paths.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Allowances {
    pub loopback: bool,
    pub test_links: bool,
}

fn test_relay_allowed(candidate: &Candidate, allow: Allowances) -> bool {
    allow.loopback
        && allow.test_links
        && candidate.kind == CandidateType::Relay
        && candidate.class == AddressClass::Private
}

/// The technique a local candidate is offered with, or `None` when it is never sent. `interface_ok` says whether the
/// interface holding a host candidate's address may offer it (VPN and tunnel interfaces may not).
pub fn local_technique(
    candidate: &Candidate,
    purpose: Purpose,
    kind: Kind,
    interface_ok: bool,
    allow: Allowances,
) -> Technique {
    let class = candidate.class;
    let allow_loopback = allow.loopback;
    if !address_allowed(class, purpose, allow_loopback) && !test_relay_allowed(candidate, allow) {
        return Technique::None;
    }
    if kind == Kind::Relay {
        let relay = candidate.kind == CandidateType::Relay && !candidate.tcp;
        return if relay { Technique::Relay } else { Technique::None };
    }
    if candidate.tcp && kind != Kind::Direct {
        return Technique::None;
    }
    match candidate.kind {
        CandidateType::Host => {
            let test_loopback = class == AddressClass::Loopback && allow_loopback;
            if !test_loopback && !interface_ok {
                return Technique::None;
            }
            if class != AddressClass::GlobalIpv6 && purpose != Purpose::Friend && !(test_loopback && allow.test_links) {
                return Technique::None;
            }
            if candidate.tcp {
                Technique::TcpSimultaneousOpen
            } else if class == AddressClass::GlobalIpv6 {
                Technique::HostIpv6
            } else {
                Technique::HostPrivate
            }
        }
        CandidateType::ServerReflexive => {
            if candidate.tcp {
                Technique::TcpSimultaneousOpen
            } else {
                Technique::ServerReflexive
            }
        }
        CandidateType::PeerReflexive | CandidateType::Relay => Technique::None,
    }
}

/// Whether the transport dials a remote candidate.
pub fn may_dial(candidate: &Candidate, purpose: Purpose, kind: Kind, allow: Allowances) -> bool {
    let allowed = address_allowed(candidate.class, purpose, allow.loopback) || test_relay_allowed(candidate, allow);
    if !allowed || candidate.kind == CandidateType::PeerReflexive {
        return false;
    }
    let relay = candidate.kind == CandidateType::Relay;
    if kind == Kind::Relay {
        return relay && !candidate.tcp;
    }
    !candidate.tcp || (kind == Kind::Direct && !relay)
}

/// The technique of a selected pair, by the rule in `SZFriendsOnlineTransport.h`.
pub fn pair_technique(
    local: &Candidate,
    local_technique: Technique,
    remote: &Candidate,
    remote_technique: Technique,
    kind: Kind,
) -> Technique {
    if local.kind == CandidateType::Relay || remote.kind == CandidateType::Relay {
        return Technique::Relay;
    }
    if kind == Kind::ProbeHandover {
        return Technique::ProbeHandover;
    }
    for named in [Technique::PortMapping, Technique::PredictedPort] {
        if local_technique == named || remote_technique == named {
            return named;
        }
    }
    let reflexive = CandidateType::ServerReflexive;
    if local.kind == reflexive
        || remote.kind == reflexive
        || local_technique == Technique::ServerReflexive
        || remote_technique == Technique::ServerReflexive
    {
        return Technique::ServerReflexive;
    }
    if local.kind == CandidateType::PeerReflexive || remote.kind == CandidateType::PeerReflexive {
        return Technique::PeerReflexive;
    }
    if local.class == AddressClass::GlobalIpv6 && remote.class == AddressClass::GlobalIpv6 {
        return Technique::HostIpv6;
    }
    Technique::HostPrivate
}

fn type_preference(kind: CandidateType) -> u32 {
    match kind {
        CandidateType::Host => 126,
        CandidateType::PeerReflexive => 110,
        CandidateType::ServerReflexive => 100,
        CandidateType::Relay => 0,
    }
}

/// One candidate line for this side (`SZFriendsNATCandidateLine`): TCP lines get "tcptype so"; reflexive lines carry
/// raddr 0.0.0.0 (or ::) rport 0; the priority follows RFC 8445 § 5.1.2 with `local_preference`.
pub fn line_for(address: SocketAddr, kind: CandidateType, tcp: bool, local_preference: u16) -> String {
    let priority = (type_preference(kind) << 24) | (u32::from(local_preference) << 8) | 255;
    let ip = canonical(address.ip());
    let foundation = format!("{}{}{}", kind.name(), if tcp { "t" } else { "u" }, if ip.is_ipv6() { '6' } else { '4' });
    let mut line = format!(
        "candidate:{foundation} 1 {} {priority} {} {} typ {}",
        if tcp { "TCP" } else { "UDP" },
        host_text(ip),
        address.port(),
        kind.name()
    );
    if kind != CandidateType::Host {
        line.push_str(if ip.is_ipv6() { " raddr :: rport 0" } else { " raddr 0.0.0.0 rport 0" });
    }
    if tcp {
        line.push_str(" tcptype so");
    }
    line
}

/// NATs allocate from the dynamic and registered ranges, never the system ports.
const LOWEST_PREDICTED_PORT: i32 = 1024;
/// A router mapping is the surest reflexive address, a hole-punched one next, a predicted one last.
pub const PREFERENCE_PORT_MAPPING: u16 = 65535;
const PREFERENCE_PREDICTED: u16 = 1000;
/// Remote candidates one peer connection accepts (libjuice), and how many of them prediction may take.
pub const REMOTE_CANDIDATE_MAX: usize = 30;
pub const PREDICTED_CANDIDATE_MAX: usize = 25;

/// Ports reflexive + step, + 2 × step, ... within 1024 to 65535, as many as fit beside the existing candidates.
pub fn predict_ports(reflexive_port: u16, step: i32, existing: usize) -> Vec<u16> {
    let mut ports = Vec::new();
    if step == 0 || step.abs() > crate::nat::classifier::PREDICTABLE_STEP_MAX || reflexive_port == 0 {
        return ports;
    }
    let room = PREDICTED_CANDIDATE_MAX.min(REMOTE_CANDIDATE_MAX.saturating_sub(existing));
    let mut port = i32::from(reflexive_port);
    while ports.len() < room {
        port += step;
        if !(LOWEST_PREDICTED_PORT..=65535).contains(&port) {
            break;
        }
        ports.push(port as u16);
    }
    ports
}

/// The hard side's next mappings as reflexive candidates.
pub fn predicted_candidates(reflexive: SocketAddr, step: i32, existing: usize) -> Vec<String> {
    predict_ports(reflexive.port(), step, existing)
        .into_iter()
        .map(|port| {
            line_for(SocketAddr::new(reflexive.ip(), port), CandidateType::ServerReflexive, false, PREFERENCE_PREDICTED)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_parse_strictly_and_lose_their_related_address() {
        let c = Candidate::parse("a=candidate:1 1 UDP 2122317823 192.168.1.4 5000 typ srflx raddr 10.0.0.1 rport 6000")
            .unwrap();
        assert_eq!(c.line(), "candidate:1 1 UDP 2122317823 192.168.1.4 5000 typ srflx");
        assert_eq!(c.related_port, 6000);
        assert!(Candidate::parse("candidate:1 1 UDP 1 host.local 5000 typ host").is_none());
        assert!(Candidate::parse("candidate:1 2 UDP 1 1.2.3.4 5000 typ host").is_none());
        assert!(Candidate::parse("candidate:1 1 TCP 1 1.2.3.4 5000 typ host tcptype active").is_none());
        assert!(Candidate::parse("candidate:1 1 TCP 1 1.2.3.4 5000 typ host tcptype so").is_some());
        let line = line_for("203.0.113.9:7000".parse().unwrap(), CandidateType::ServerReflexive, false, 1000);
        assert_eq!(line, "candidate:srflxu4 1 UDP 1677977855 203.0.113.9 7000 typ srflx raddr 0.0.0.0 rport 0");
        assert!(Candidate::parse(&line).is_some());
    }

    #[test]
    fn rules_by_purpose_and_kind() {
        let private = Candidate::parse("candidate:1 1 UDP 1 192.168.1.4 5000 typ host").unwrap();
        assert_eq!(
            local_technique(&private, Purpose::Friend, Kind::Direct, true, Allowances::default()),
            Technique::HostPrivate
        );
        assert_eq!(
            local_technique(&private, Purpose::Link, Kind::Direct, true, Allowances::default()),
            Technique::None
        );
        assert_eq!(
            local_technique(&private, Purpose::Friend, Kind::Relay, true, Allowances::default()),
            Technique::None
        );
        let relay = Candidate::parse("candidate:1 1 UDP 1 192.168.1.4 5000 typ relay").unwrap();
        assert!(may_dial(&relay, Purpose::Friend, Kind::Relay, Allowances::default()));
        assert!(!may_dial(&private, Purpose::Friend, Kind::Relay, Allowances::default()));
        assert_eq!(predict_ports(40000, 2, 0).len(), 25);
        assert_eq!(predict_ports(40000, 2, 28), vec![40002, 40004]);
        assert!(predict_ports(40000, 40, 0).is_empty());
    }
}
