//! Hard-NAT probing, the birthday technique (ADR 0011 § Hard NATs, § Probing budget; `SZFriendsNATProber.m`), beside
//! the stack, which has one socket per agent and room for 30 remote candidates. Only one side probes per role:
//!
//! - the hard side (its NAT maps per destination) opens up to 256 UDP sockets and sends one probe from each to the easy
//!   side's prober address, opening 256 mappings on its NAT;
//! - the easy side probes random ports of the hard side's public address from one socket, 100 a second, at most
//!   1,148, within 12 s.
//!
//! Probes are STUN Binding requests under short-term credentials from the attempt's authenticated signalling; a
//! request or answer counts only if its integrity checks and it comes from the peer's address. Both sides answer
//! every valid request (at most 64 a run). The easy side decides the pair, as ICE's controlling side does: the first
//! of its requests whose answer comes back selects it, and it nominates it (USE-CANDIDATE, up to 5 times 100 ms
//! apart); the nomination is the hard side's hit. A side with a pair closes every other socket, answers on the winner
//! for the linger, closes it, and reports the pair, so the probe handover connection can bind its port at once.
//! Probes go only to the public address the authenticated peer presented in this attempt; at most one run per peer
//! per 10 minutes and one at a time per process.

mod run;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use super::endpoint::{canonical_addr, own_addresses, scope, Scope};
use run::Run;

/// Whether this build probes at all: not on phones, where hundreds of sockets and probes a second cost a radio's
/// battery and a carrier's NAT rarely lets them through; a friend behind a hard NAT is reached through the relay there.
pub const AVAILABLE: bool = cfg!(not(any(target_os = "android", target_os = "ios")));
pub const SOCKETS: usize = 256;
pub const PROBE_MAX: usize = 1148;
pub const PROBES_PER_SECOND: u32 = 100;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProbeRole {
    Hard,
    Easy,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProbeError {
    Budget,
    AddressRefused,
    Unsupported,
    TimedOut,
    Socket,
    Cancelled,
}

/// One run per peer per 10 minutes and one at a time per process.
#[derive(Debug, Default)]
pub struct ProbeBudget {
    running: bool,
    last_run: HashMap<Vec<u8>, Instant>,
}

impl ProbeBudget {
    pub fn shared() -> &'static Mutex<ProbeBudget> {
        static SHARED: OnceLock<Mutex<ProbeBudget>> = OnceLock::new();
        SHARED.get_or_init(|| Mutex::new(ProbeBudget::default()))
    }

    pub fn begin(&mut self, peer: &[u8]) -> bool {
        let interval = Duration::from_secs(600);
        if self.running || peer.is_empty() || self.last_run.get(peer).is_some_and(|at| at.elapsed() < interval) {
            return false;
        }
        self.last_run.retain(|_, at| at.elapsed() < interval);
        self.last_run.insert(peer.to_vec(), Instant::now());
        self.running = true;
        true
    }

    pub fn end(&mut self) {
        self.running = false;
    }
}

#[derive(Clone, Debug)]
pub struct ProberConfig {
    pub role: ProbeRole,
    pub peer: Vec<u8>,
    /// Hard side: the easy prober's address. Easy side: the hard side's public address (port ignored).
    pub remote: SocketAddr,
    /// What the peer presented in this attempt's authenticated signalling.
    pub presented: Vec<SocketAddr>,
    /// Easy side: the host's STUN server, to learn the prober socket's public address.
    pub stun_server: Option<SocketAddr>,
    pub local_ufrag: String,
    pub local_password: String,
    pub remote_ufrag: String,
    pub remote_password: String,
    pub duration: Duration,
    pub socket_count: usize,
    pub probe_max: usize,
    pub linger: Duration,
    pub port_range: (u16, u16),
    pub loopback_only: bool,
    /// The budget runs count against: the process's own unless a test gives one.
    pub budget: Option<Arc<Mutex<ProbeBudget>>>,
}

impl ProberConfig {
    pub fn new(role: ProbeRole, peer: Vec<u8>, remote: SocketAddr) -> Self {
        Self {
            role,
            peer,
            remote,
            presented: Vec::new(),
            stun_server: None,
            local_ufrag: String::new(),
            local_password: String::new(),
            remote_ufrag: String::new(),
            remote_password: String::new(),
            duration: Duration::from_secs(12),
            socket_count: SOCKETS,
            probe_max: PROBE_MAX,
            linger: Duration::from_millis(500),
            port_range: (1024, 65535),
            loopback_only: false,
            budget: None,
        }
    }

    fn valid(&self) -> bool {
        let ice = |t: &str, min: usize, max: usize| {
            (min..=max).contains(&t.len()) && t.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'+' || c == b'/')
        };
        !self.peer.is_empty()
            && ice(&self.local_ufrag, 4, 16)
            && ice(&self.remote_ufrag, 4, 16)
            && ice(&self.local_password, 22, 256)
            && ice(&self.remote_password, 22, 256)
            && self.port_range.0 >= 1024
            && self.port_range.1 >= self.port_range.0
            && self.socket_count <= SOCKETS
            && self.probe_max <= PROBE_MAX
            && !self.duration.is_zero()
            && self.duration <= Duration::from_secs(12)
            && self.linger <= Duration::from_secs(1)
    }

    fn allows(&self, address: SocketAddr) -> bool {
        if self.loopback_only {
            return scope(address.ip()) == Scope::Loopback;
        }
        scope(address.ip()) == Scope::Global && !own_addresses().contains(&canonical_addr(address).ip())
    }

    fn remote_was_presented(&self) -> bool {
        let remote = canonical_addr(self.remote);
        self.presented.iter().map(|p| canonical_addr(*p)).any(|p| match self.role {
            ProbeRole::Hard => p == remote,
            ProbeRole::Easy => p.ip() == remote.ip(),
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hit {
    pub local_port: u16,
    pub remote: SocketAddr,
    pub probes_sent: usize,
}

/// What a run reports, once each, in this order.
#[derive(Debug)]
pub enum ProberEvent {
    /// Easy side: the prober socket's public address, for the signalling (or `None`: the run ends next).
    Prepared(Option<SocketAddr>),
    Finished(Result<Hit, ProbeError>),
}

/// A running prober; dropping or cancelling it ends the run (reported as `Cancelled` unless already finished).
#[derive(Debug)]
pub struct Prober {
    cancel: Arc<AtomicBool>,
}

impl Prober {
    pub fn spawn(config: ProberConfig, report: Box<dyn Fn(ProberEvent) + Send>) -> Self {
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        let spawned = std::thread::Builder::new().name("szfriends-prober".into()).spawn(move || {
            let mut run = Run::new(config, flag);
            let result = run.run(&*report);
            drop(run);
            report(ProberEvent::Finished(result));
        });
        if spawned.is_err() {
            cancel.store(true, Ordering::SeqCst);
        }
        Self { cancel }
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
    }
}

impl Drop for Prober {
    fn drop(&mut self) {
        self.cancel();
    }
}
