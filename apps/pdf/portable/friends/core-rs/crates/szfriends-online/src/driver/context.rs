//! What every attempt shares (`SZFriendsOnlineContext.m`): the identity, the transport's configuration, the host's
//! STUN servers as numeric addresses, this network's NAT class, the clock, the technique log, the test hooks, and
//! the way back to the online thread for what the stack and the NAT techniques report.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use szfriends_datachannel_sys::Event;
use szfriends_identity::Identity;
use szfriends_wire::route::RouteMethod;

use super::Input;
use crate::nat::classifier::{ClassCache, Classification, NatClass};
use crate::nat::prober::ProberEvent;
use crate::order::LogEntry;
use crate::transport::{RelayCredentials, TransportConfig};

/// How many attempts the technique log keeps.
const LOG_CAPACITY: usize = 200;

/// A friend as the driver needs one (`SZFriendsOnlineFriend`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OnlineFriend {
    pub identity_key: [u8; 32],
    /// The X25519 key IK message 1 is sealed to.
    pub static_key: [u8; 32],
    /// Theirs, which their rendezvous record is sealed under.
    pub presence_secret: Option<[u8; 32]>,
    /// Presented in IK message 1 while our acceptance of their Add by ID has not reached them.
    pub request_token: Option<[u8; 16]>,
    /// The person's root key when `identity_key` is one of their other devices.
    pub root_key: Option<[u8; 32]>,
}

/// What the driver asks the helper (`SZFriendsOnlineDriverDelegate`), answered from what the helper last told it.
pub trait Friends: Send {
    /// The friend this identity key names now, or `None`: unknown, removed, blocked, a key change waiting. Pure.
    fn friend(&self, identity_key: &[u8; 32]) -> Option<OnlineFriend>;
    /// The best route carrying a session with this friend that no online attempt made (nearby), or None.
    fn nearby_route(&self, identity_key: &[u8; 32]) -> RouteMethod;
    /// This device's presence secret, which its rendezvous record is sealed under.
    fn own_presence_secret(&self) -> Option<[u8; 32]>;
    /// Someone answering an Add by ID of ours with its token (`-friendAnsweringWithIdentityKey:token:`): admitted only
    /// for an unexpired request of ours with a slot for this key. Their static key comes from their certificate.
    fn answering(&self, identity_key: &[u8; 32], token: &[u8]) -> Option<OnlineFriend> {
        let _ = (identity_key, token);
        None
    }
}

/// Where what the stack, the prober and the classifier report goes: the online thread's inbox.
pub type Sink = Arc<dyn Fn(Input) + Send + Sync>;

/// Tests only: no direct candidate is sent or applied while this answers `true`.
pub type DirectBlocked = Arc<dyn Fn() -> bool + Send + Sync>;

pub struct Context {
    pub identity: Arc<Identity>,
    pub transport: TransportConfig,
    pub loopback_only: bool,
    pub direct_blocked: Option<DirectBlocked>,
    pub stun_primary: Option<SocketAddr>,
    pub stun_secondary: Option<SocketAddr>,
    pub inbox: Sink,
    pub log: Vec<LogEntry>,
    pub log_path: Option<std::path::PathBuf>,
    /// Which attempt and connection number each connection id belongs to.
    pub connections: HashMap<u64, (u64, u8)>,
    next_connection: u64,
    classes: ClassCache,
    classifying: bool,
    network: String,
    start: Instant,
    random_state: u64,
}

impl std::fmt::Debug for Context {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Context").field("loopback_only", &self.loopback_only).finish()
    }
}

impl Context {
    pub fn new(identity: Arc<Identity>, transport: TransportConfig, loopback_only: bool, inbox: Sink) -> Self {
        let mut seed = [0u8; 8];
        szfriends_crypto::random_bytes(&mut seed);
        Self {
            identity,
            transport,
            loopback_only,
            direct_blocked: None,
            stun_primary: None,
            stun_secondary: None,
            inbox,
            log: Vec::new(),
            log_path: None,
            connections: HashMap::new(),
            next_connection: 1,
            classes: ClassCache::default(),
            classifying: false,
            network: network_key(loopback_only),
            start: Instant::now(),
            random_state: u64::from_le_bytes(seed) | 1,
        }
    }

    /// Seconds on a clock that never goes back.
    pub fn now(&self) -> f64 {
        self.start.elapsed().as_secs_f64()
    }

    /// A value in [0, 1) for the retry jitter.
    pub fn random(&mut self) -> f64 {
        self.random_state ^= self.random_state << 13;
        self.random_state ^= self.random_state >> 7;
        self.random_state ^= self.random_state << 17;
        (self.random_state >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn next_connection_id(&mut self) -> u64 {
        let id = self.next_connection;
        self.next_connection += 1;
        id
    }

    pub fn direct_paths_blocked(&self) -> bool {
        self.direct_blocked.as_ref().is_some_and(|blocked| blocked())
    }

    /// "stun:<numeric>:<port>" of the primary STUN server.
    pub fn stun_uri(&self) -> Option<String> {
        self.stun_primary.map(|a| match a {
            SocketAddr::V4(v4) => format!("stun:{}:{}", v4.ip(), v4.port()),
            SocketAddr::V6(v6) => format!("stun:[{}]:{}", v6.ip(), v6.port()),
        })
    }

    fn network_key(&self) -> String {
        self.network.clone()
    }

    fn classification(&mut self) -> Option<Classification> {
        let key = self.network_key();
        self.classes.get(&key)
    }

    pub fn nat_class(&mut self) -> NatClass {
        self.classification().map_or(NatClass::Unknown, |c| c.class)
    }

    pub fn nat_step(&mut self) -> i16 {
        self.classification().map_or(0, |c| c.signal_step())
    }

    /// Once per network while the class is unknown: two Binding requests from one socket, on a thread of its own.
    pub fn measure_nat_class(&mut self) {
        let (Some(primary), Some(secondary)) = (self.stun_primary, self.stun_secondary) else { return };
        if self.classifying || self.classification().is_some() {
            return;
        }
        self.classifying = true;
        let (inbox, loopback, network) = (self.inbox.clone(), self.loopback_only, self.network_key());
        let spawned = std::thread::Builder::new().name("szfriends-nat-class".into()).spawn(move || {
            let result = crate::nat::classifier::classify(primary, secondary, loopback);
            inbox(Input::Classified(network, result));
        });
        if spawned.is_err() {
            self.classifying = false;
        }
    }

    /// The classifier finished: `true` when the class is now known for this network.
    pub fn classified(&mut self, network: &str, result: Option<Classification>) -> bool {
        self.classifying = false;
        match result {
            Some(classification) if network == self.network_key() => {
                self.classes.set(network, classification);
                true
            }
            _ => false,
        }
    }

    pub fn network_changed(&mut self) {
        self.classes.network_changed();
        self.network = network_key(self.loopback_only);
    }

    /// What the stack reports for connection `id`, back on the online thread.
    pub fn forward(&self) -> crate::transport::connection::Forward {
        let inbox = self.inbox.clone();
        Arc::new(move |id: u64, event: Event| inbox(Input::Connection(id, event)))
    }

    /// Told when the owner of a stream closes it.
    pub fn stream_close_notice(&self, id: u64) -> Arc<dyn Fn() + Send + Sync> {
        let inbox = self.inbox.clone();
        Arc::new(move || inbox(Input::StreamClosed(id)))
    }

    pub fn prober_report(&self, attempt: u64) -> Box<dyn Fn(ProberEvent) + Send> {
        let inbox = self.inbox.clone();
        Box::new(move |event| inbox(Input::Prober(attempt, event)))
    }

    /// An ended attempt's entry: numbers only, so the file says nothing about who was reached.
    pub fn append_log(&mut self, entry: LogEntry) {
        self.log.push(entry);
        if self.log.len() > LOG_CAPACITY {
            self.log.remove(0);
        }
        if let Some(path) = &self.log_path {
            let json = serde_json::Value::Array(self.log.iter().map(LogEntry::to_json).collect());
            let _ = std::fs::write(path, json.to_string());
        }
    }
}

/// Which network the class was measured on: the source addresses the default routes use (loopback in tests).
fn network_key(loopback_only: bool) -> String {
    if loopback_only {
        return "loopback".into();
    }
    let own: Vec<String> = crate::nat::endpoint::own_addresses().iter().map(ToString::to_string).collect();
    own.join(" ")
}

/// Relay credentials as the host gave them, with the first TURN over UDP URI of the signed list.
pub fn first_turn_over_udp(uris: &[String]) -> Option<String> {
    uris.iter()
        .find(|uri| uri.starts_with("turn:") && uri.find('?').is_none_or(|q| &uri[q..] == "?transport=udp"))
        .cloned()
}

/// What a sid's relay request brings back.
pub type RelayResult = Option<RelayCredentials>;
