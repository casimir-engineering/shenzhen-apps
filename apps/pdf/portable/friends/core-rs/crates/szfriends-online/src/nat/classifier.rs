//! The two-port NAT classifier (ADR 0011 § NAT class; `SZFriendsNATClassifier.m`). One UDP socket sends a Binding
//! request to the host's 3478 (coturn) and to its 3479 (the host's own responder), both from the signed host list.
//! One mapped port from both means the NAT maps independently of the destination; two ports mean it maps each
//! destination anew, and their difference gives prediction its step. No answer from 3479, or answers that disagree on
//! the address, leave the class unknown. Answers count only from the server asked, for a transaction this socket sent.

use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

use super::endpoint::{canonical_addr, scope, Scope};
use super::stun;

/// The largest step that counts as a sequential NAT worth predicting (provisional, M0 matrix).
pub const PREDICTABLE_STEP_MAX: i32 = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum NatClass {
    #[default]
    Unknown = 0,
    EndpointIndependent = 1,
    PerDestination = 2,
}

impl NatClass {
    pub fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::EndpointIndependent,
            2 => Self::PerDestination,
            _ => Self::Unknown,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Classification {
    pub class: NatClass,
    pub primary: Option<SocketAddr>,
    pub secondary: Option<SocketAddr>,
    /// For a per-destination NAT, secondary's port minus primary's; 0 otherwise.
    pub step: i32,
}

impl Classification {
    pub fn new(primary: Option<SocketAddr>, secondary: Option<SocketAddr>) -> Self {
        let mut result = Self { primary, secondary, ..Self::default() };
        if let (Some(a), Some(b)) = (primary, secondary) {
            if a.ip() == b.ip() {
                if a.port() == b.port() {
                    result.class = NatClass::EndpointIndependent;
                } else {
                    result.class = NatClass::PerDestination;
                    result.step = i32::from(b.port()) - i32::from(a.port());
                }
            }
        }
        result
    }

    pub fn predictable(&self) -> bool {
        self.class == NatClass::PerDestination && self.step.abs() <= PREDICTABLE_STEP_MAX
    }

    /// The step as the signalling carries it.
    pub fn signal_step(&self) -> i16 {
        if self.class == NatClass::PerDestination {
            self.step.clamp(i32::from(i16::MIN), i32::from(i16::MAX)) as i16
        } else {
            0
        }
    }
}

/// When both requests go again, and the whole budget (provisional: 0.25, 0.75, 1.5 and 2.5 s).
const RETRANSMITS: [f64; 3] = [0.25, 0.75, 1.5];
const BUDGET: f64 = 2.5;

fn allowed(server: SocketAddr, loopback_only: bool) -> bool {
    server.port() != 0
        && if loopback_only { scope(server.ip()) == Scope::Loopback } else { scope(server.ip()) == Scope::Global }
}

/// Runs the classifier, blocking for at most the budget. `None` when neither server answered or a server or the
/// socket was refused.
pub fn classify(primary: SocketAddr, secondary: SocketAddr, loopback_only: bool) -> Option<Classification> {
    let (primary, secondary) = (canonical_addr(primary), canonical_addr(secondary));
    if !allowed(primary, loopback_only)
        || !allowed(secondary, loopback_only)
        || primary.is_ipv4() != secondary.is_ipv4()
    {
        return None;
    }
    let bind = if primary.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let socket = UdpSocket::bind(bind).ok()?;
    let servers = [primary, secondary];
    let transactions = [stun::random_transaction(), stun::random_transaction()];
    let mut mapped: [Option<SocketAddr>; 2] = [None, None];
    let start = Instant::now();
    let mut next_send = 0usize;
    let send = |mapped: &[Option<SocketAddr>; 2]| {
        for i in 0..2 {
            if mapped[i].is_none() {
                if let Some(request) = stun::binding_request(&transactions[i], None, false) {
                    let _ = socket.send_to(&request, servers[i]);
                }
            }
        }
    };
    send(&mapped);
    let mut buffer = [0u8; stun::MESSAGE_MAX + 1];
    loop {
        let elapsed = start.elapsed().as_secs_f64();
        if elapsed >= BUDGET || (mapped[0].is_some() && mapped[1].is_some()) {
            break;
        }
        if next_send < RETRANSMITS.len() && elapsed >= RETRANSMITS[next_send] {
            next_send += 1;
            send(&mapped);
            continue;
        }
        let until = RETRANSMITS.get(next_send).copied().unwrap_or(BUDGET).min(BUDGET);
        let wait = Duration::from_secs_f64((until - elapsed).max(0.005));
        let _ = socket.set_read_timeout(Some(wait));
        let Ok((length, from)) = socket.recv_from(&mut buffer) else { continue };
        let Some(message) = stun::parse(&buffer[..length]) else { continue };
        if message.kind != stun::BINDING_SUCCESS {
            continue;
        }
        let from = canonical_addr(from);
        for i in 0..2 {
            if mapped[i].is_none() && from == servers[i] && message.transaction == transactions[i] {
                mapped[i] = message.mapped.map(canonical_addr);
            }
        }
    }
    (mapped[0].is_some() || mapped[1].is_some()).then(|| Classification::new(mapped[0], mapped[1]))
}

/// The class per network, in memory only; entries expire after 30 minutes and all go at a network change.
#[derive(Debug, Default)]
pub struct ClassCache {
    entries: HashMap<String, (Classification, Instant)>,
}

impl ClassCache {
    pub fn get(&mut self, network: &str) -> Option<Classification> {
        let (classification, at) = *self.entries.get(network)?;
        if at.elapsed() > Duration::from_secs(30 * 60) {
            self.entries.remove(network);
            return None;
        }
        Some(classification)
    }

    pub fn set(&mut self, network: &str, classification: Classification) {
        self.entries.insert(network.to_owned(), (classification, Instant::now()));
    }

    pub fn network_changed(&mut self) {
        self.entries.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classes_from_two_answers() {
        let a: SocketAddr = "198.51.100.1:4000".parse().unwrap();
        assert_eq!(Classification::new(Some(a), Some(a)).class, NatClass::EndpointIndependent);
        let b: SocketAddr = "198.51.100.1:4002".parse().unwrap();
        let per = Classification::new(Some(a), Some(b));
        assert_eq!((per.class, per.step, per.predictable()), (NatClass::PerDestination, 2, true));
        assert_eq!(Classification::new(Some(a), None).class, NatClass::Unknown);
    }

    /// A STUN responder on loopback answering both "ports" from one socket each.
    #[test]
    fn classifies_against_loopback_responders() {
        let servers: Vec<UdpSocket> = (0..2).map(|_| UdpSocket::bind("127.0.0.1:0").unwrap()).collect();
        let addresses: Vec<SocketAddr> = servers.iter().map(|s| s.local_addr().unwrap()).collect();
        for server in servers {
            std::thread::spawn(move || {
                let mut buffer = [0u8; 600];
                while let Ok((n, from)) = server.recv_from(&mut buffer) {
                    if let Some(m) = stun::parse(&buffer[..n]) {
                        let _ = server.send_to(&stun::binding_success(&m.transaction, from, None), from);
                    }
                }
            });
        }
        let result = classify(addresses[0], addresses[1], true).unwrap();
        assert_eq!(result.class, NatClass::EndpointIndependent);
        assert!(classify(addresses[0], addresses[1], false).is_none(), "loopback servers are refused outside tests");
    }
}
