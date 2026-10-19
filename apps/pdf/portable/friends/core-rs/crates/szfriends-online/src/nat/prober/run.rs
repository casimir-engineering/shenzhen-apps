//! One probing run (`SZFriendsNATProber.m`): the sockets, the probes, the answers, the nomination and the hit.

use std::collections::{HashMap, HashSet};
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::{Hit, ProbeBudget, ProbeError, ProbeRole, ProberConfig, ProberEvent, PROBES_PER_SECOND};
use crate::nat::endpoint::canonical_addr;
use crate::nat::stun;

const ANSWERS_MAX: usize = 64;
const TRIGGERED_MAX: usize = 8;
const TRIGGERED_SENDS: u32 = 5;
const HARD_SOCKETS_MIN: usize = 16;

pub(super) struct Run {
    config: ProberConfig,
    cancel: Arc<AtomicBool>,
    sockets: Vec<UdpSocket>,
    transactions: HashMap<[u8; 12], SocketAddr>,
    nominations: HashSet<[u8; 12]>,
    request_username: String,
    expected_username: String,
    answers: usize,
    triggered: Vec<(usize, SocketAddr, u32, Instant)>,
    triggered_remotes: HashSet<SocketAddr>,
    winner: Option<(usize, SocketAddr)>,
    nomination: Option<(u32, Instant)>,
    nomination_answered: bool,
    probes_sent: usize,
    probed: HashSet<u16>,
    holds_budget: bool,
}

impl Run {
    pub(super) fn new(config: ProberConfig, cancel: Arc<AtomicBool>) -> Self {
        let request_username = format!("{}:{}", config.remote_ufrag, config.local_ufrag);
        let expected_username = format!("{}:{}", config.local_ufrag, config.remote_ufrag);
        Self {
            config,
            cancel,
            sockets: Vec::new(),
            transactions: HashMap::new(),
            nominations: HashSet::new(),
            request_username,
            expected_username,
            answers: 0,
            triggered: Vec::new(),
            triggered_remotes: HashSet::new(),
            winner: None,
            nomination: None,
            nomination_answered: false,
            probes_sent: 0,
            probed: HashSet::new(),
            holds_budget: false,
        }
    }

    fn with_budget<T>(&self, step: impl FnOnce(&mut ProbeBudget) -> T) -> T {
        let shared = ProbeBudget::shared();
        let budget = self.config.budget.as_deref().unwrap_or(shared);
        step(&mut budget.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn open_socket(&mut self, port: u16) -> Option<usize> {
        let ipv6 = self.config.remote.is_ipv6();
        let host = match (ipv6, self.config.loopback_only) {
            (true, true) => "::1",
            (true, false) => "::",
            (false, true) => "127.0.0.1",
            (false, false) => "0.0.0.0",
        };
        let socket = UdpSocket::bind((host, port)).ok()?;
        socket.set_nonblocking(true).ok()?;
        self.sockets.push(socket);
        Some(self.sockets.len() - 1)
    }

    fn send_request(&mut self, index: usize, to: SocketAddr, nominating: bool) {
        let transaction = stun::random_transaction();
        let key = self.config.remote_password.clone();
        let Some(bytes) =
            stun::binding_request(&transaction, Some((&self.request_username, key.as_bytes())), nominating)
        else {
            return;
        };
        self.transactions.insert(transaction, to);
        if nominating {
            self.nominations.insert(transaction);
        }
        let _ = self.sockets[index].send_to(&bytes, to);
    }

    /// Easy side: the prober socket's public address through the STUN server (loopback tests without one: its own).
    fn prepare(&mut self) -> Option<SocketAddr> {
        let index = self.open_socket(0)?;
        let Some(server) = self.config.stun_server else {
            let port = self.sockets[index].local_addr().ok()?.port();
            let own = SocketAddr::new(crate::nat::endpoint::loopback(self.config.remote.is_ipv6()), port);
            return self.config.loopback_only.then_some(own);
        };
        if !self.config.allows(server) {
            return None;
        }
        let transaction = stun::random_transaction();
        let request = stun::binding_request(&transaction, None, false)?;
        let start = Instant::now();
        let mut sends = [0.0, 0.25, 0.75].into_iter().peekable();
        let mut buffer = [0u8; stun::MESSAGE_MAX + 1];
        while start.elapsed() < Duration::from_millis(1500) && !self.cancel.load(Ordering::SeqCst) {
            if sends.peek().is_some_and(|at| start.elapsed().as_secs_f64() >= *at) {
                sends.next();
                let _ = self.sockets[index].send_to(&request, server);
            }
            match self.sockets[index].recv_from(&mut buffer) {
                Ok((n, from)) if canonical_addr(from) == canonical_addr(server) => {
                    if let Some(m) = stun::parse(&buffer[..n]).filter(|m| m.transaction == transaction) {
                        if m.kind == stun::BINDING_SUCCESS {
                            return m.mapped.map(canonical_addr);
                        }
                    }
                }
                Ok(_) => {}
                Err(_) => std::thread::sleep(Duration::from_millis(2)),
            }
        }
        None
    }

    pub(super) fn run(&mut self, report: &dyn Fn(ProberEvent)) -> Result<Hit, ProbeError> {
        if self.config.role == ProbeRole::Easy {
            let prepared = self.prepare();
            report(ProberEvent::Prepared(prepared));
            if prepared.is_none() {
                return Err(ProbeError::TimedOut);
            }
        }
        if self.cancel.load(Ordering::SeqCst) {
            return Err(ProbeError::Cancelled);
        }
        if !self.config.valid() {
            return Err(ProbeError::Unsupported);
        }
        if !self.config.allows(self.config.remote) || !self.config.remote_was_presented() {
            return Err(ProbeError::AddressRefused);
        }
        if !self.with_budget(|budget| budget.begin(&self.config.peer)) {
            return Err(ProbeError::Budget);
        }
        self.holds_budget = true;
        if self.config.role == ProbeRole::Hard {
            for _ in 0..self.config.socket_count {
                if self.open_socket(0).is_none() {
                    break;
                }
            }
            if self.sockets.len() < HARD_SOCKETS_MIN.min(self.config.socket_count) {
                return Err(ProbeError::Socket);
            }
            for index in 0..self.sockets.len() {
                self.send_request(index, self.config.remote, false);
                self.probes_sent += 1;
            }
        }
        self.probe_loop()
    }

    fn probe_loop(&mut self) -> Result<Hit, ProbeError> {
        let start = Instant::now();
        let interval = Duration::from_secs(1) / PROBES_PER_SECOND;
        let mut next_probe = start;
        let mut linger_until: Option<Instant> = None;
        let mut buffer = [0u8; stun::MESSAGE_MAX + 1];
        loop {
            if self.cancel.load(Ordering::SeqCst) {
                return Err(ProbeError::Cancelled);
            }
            let now = Instant::now();
            if linger_until.is_some_and(|until| now >= until) || self.nomination_answered {
                return Ok(self.hit());
            }
            if now.duration_since(start) >= self.config.duration {
                return Err(ProbeError::TimedOut);
            }
            if self.config.role == ProbeRole::Easy && self.winner.is_none() && now >= next_probe {
                next_probe += interval;
                self.send_random_probe();
            }
            self.repeat_requests(now);
            let mut read_any = false;
            // A selection keeps only the winning socket: the scan starts again over what is left.
            let mut index = 0;
            while index < self.sockets.len() {
                let count = self.sockets.len();
                let Ok((n, from)) = self.sockets[index].recv_from(&mut buffer) else {
                    index += 1;
                    continue;
                };
                read_any = true;
                let packet = buffer[..n].to_vec();
                self.handle(index, &packet, canonical_addr(from));
                if self.sockets.len() != count {
                    index = 0;
                }
            }
            if self.winner.is_some() && linger_until.is_none() {
                linger_until = Some(Instant::now() + self.config.linger);
            }
            if !read_any {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    }

    fn send_random_probe(&mut self) {
        let (low, high) = self.config.port_range;
        let range = usize::from(high - low) + 1;
        if self.probes_sent >= self.config.probe_max || self.probed.len() >= range || self.sockets.is_empty() {
            return;
        }
        let port = loop {
            let mut bytes = [0u8; 4];
            szfriends_crypto::random_bytes(&mut bytes);
            let port = low + (u32::from_be_bytes(bytes) as usize % range) as u16;
            if self.probed.insert(port) {
                break port;
            }
        };
        let to = SocketAddr::new(self.config.remote.ip(), port);
        self.send_request(0, to, false);
        self.probes_sent += 1;
    }

    /// Triggered requests and the nomination, 100 ms apart, until a pair is selected or answered.
    fn repeat_requests(&mut self, now: Instant) {
        let interval = Duration::from_millis(100);
        let mut due = Vec::new();
        for entry in &mut self.triggered {
            if self.winner.is_none() && entry.2 < TRIGGERED_SENDS && now >= entry.3 {
                entry.2 += 1;
                entry.3 = now + interval;
                due.push((entry.0, entry.1));
            }
        }
        for (index, to) in due {
            self.send_request(index, to, false);
        }
        if let (Some((index, to)), Some((sends, at))) = (self.winner, self.nomination) {
            if !self.nomination_answered && sends < TRIGGERED_SENDS && now >= at {
                self.nomination = Some((sends + 1, now + interval));
                self.send_request(index, to, true);
            }
        }
    }

    fn handle(&mut self, index: usize, packet: &[u8], from: SocketAddr) {
        if from.ip() != canonical_addr(self.config.remote).ip() {
            return;
        }
        let Some(message) = stun::parse(packet) else { return };
        if message.kind == stun::BINDING_REQUEST {
            self.handle_request(index, packet, &message, from);
        } else if message.kind == stun::BINDING_SUCCESS {
            self.handle_answer(index, packet, &message, from);
        }
    }

    fn handle_request(&mut self, index: usize, packet: &[u8], message: &stun::Message<'_>, from: SocketAddr) {
        if message.username != Some(self.expected_username.as_bytes()) {
            return;
        }
        let key = self.config.local_password.clone();
        if !stun::check_integrity(packet, message, key.as_bytes()) {
            return;
        }
        if self.winner.is_some_and(|(i, r)| i != index || r != from) || self.answers >= ANSWERS_MAX {
            return;
        }
        let answer = stun::binding_success(&message.transaction, from, Some(key.as_bytes()));
        let _ = self.sockets[index].send_to(&answer, from);
        self.answers += 1;
        if self.config.role == ProbeRole::Hard {
            if message.use_candidate && self.winner.is_none() {
                self.select(index, from);
            }
            return;
        }
        if self.winner.is_some() || self.triggered.len() >= TRIGGERED_MAX || !self.triggered_remotes.insert(from) {
            return;
        }
        self.triggered.push((index, from, 0, Instant::now()));
    }

    fn handle_answer(&mut self, index: usize, packet: &[u8], message: &stun::Message<'_>, from: SocketAddr) {
        if self.transactions.get(&message.transaction).map(|d| canonical_addr(*d)) != Some(from) {
            return;
        }
        let key = self.config.remote_password.clone();
        if !stun::check_integrity(packet, message, key.as_bytes()) || self.config.role != ProbeRole::Easy {
            return;
        }
        if self.winner.is_none() {
            self.select(index, from);
            self.nomination = Some((0, Instant::now()));
        } else if self.nominations.contains(&message.transaction) {
            self.nomination_answered = true;
        }
    }

    /// Keeps only the winning socket; the hit is reported after the linger.
    fn select(&mut self, index: usize, remote: SocketAddr) {
        let winner = self.sockets.swap_remove(index);
        self.sockets.clear();
        self.sockets.push(winner);
        self.triggered.clear();
        self.winner = Some((0, remote));
    }

    fn hit(&self) -> Hit {
        let (index, remote) = self.winner.expect("selected");
        let local_port = self.sockets[index].local_addr().map_or(0, |a| a.port());
        Hit { local_port, remote, probes_sent: self.probes_sent }
    }
}

impl Drop for Run {
    fn drop(&mut self) {
        self.sockets.clear();
        if self.holds_budget {
            self.with_budget(ProbeBudget::end);
        }
    }
}
