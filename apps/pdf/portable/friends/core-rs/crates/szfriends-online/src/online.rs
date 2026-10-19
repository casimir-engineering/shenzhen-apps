//! The online thread: the host connection, the driver's attempts and the download links, joined on one thread as the
//! helper joins them on its queue (`SZFriendsHostCheckIn.m`, `SZFriendsNearbyService+Online.m`). Nothing here runs
//! until [`Online::start`], which the helper calls once the person's Friends is set up; the stack is configured on
//! the first attempt, never at launch.

use std::collections::HashMap;
use std::net::{SocketAddr, ToSocketAddrs};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use szfriends_identity::Identity;

use crate::byid::{IdEvent, IdExchanges, RequestFrame};
use crate::join::{JoinEvent, JoinPipes};

#[path = "online_outcome.rs"]
mod outcome;
use crate::driver::{self, DirectBlocked, Driver, DriverEvent, Friends, SignalHost};
use crate::host::{HostClient, HostInput, HostList};
use crate::links::{LinkEvent, LinkFiles, Links};
use crate::nat::classifier::NatClass;
use crate::signal::items::Item;
use crate::signal::record;
use crate::transport::{ChannelStream, Route, TransportConfig};

/// How long [`Online::stop`] waits for the thread to answer.
const STOP_WAIT: Duration = Duration::from_secs(5);

/// Lookups change only once per host period: a friend is looked up at most once in each.
const LOOKUP_PERIOD: f64 = 60.0;

pub struct OnlineConfig {
    pub identity: Arc<Identity>,
    pub app_version: String,
    pub list: HostList,
    pub pinned: Vec<[u8; 32]>,
    /// Tests: peer connections bind to 127.0.0.1 and accept loopback candidates; no router is asked.
    pub loopback_only: bool,
    pub direct_blocked: Option<DirectBlocked>,
    pub friends: Box<dyn Friends>,
    pub id_provider: crate::host::client::IdProvider,
    pub technique_log: Option<PathBuf>,
    /// The download links this helper serves; none serves none.
    pub links: Option<Box<dyn LinkFiles>>,
    /// Tests: the PEM certificates a `wss://` host must chain to instead of the system's roots.
    pub host_roots: Option<Vec<u8>>,
    /// The person this computer checks in for and their chain (`host::reservation`); none checks in as itself.
    pub membership: Option<crate::host::reservation::Membership>,
    /// Whether the ID from before joining a profile is still to be released (`host::release`).
    pub release_owed: Option<crate::host::release::ReleaseOwed>,
}

impl std::fmt::Debug for OnlineConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OnlineConfig").field("loopback_only", &self.loopback_only).finish()
    }
}

/// What the helper hears.
#[derive(Debug)]
pub enum OnlineEvent {
    Available(bool),
    /// The host reserved this Friends ID, with its attestation when one checked out (`host::attestation`).
    Reserved(String, Option<crate::host::attestation::Attestation>),
    /// The ID from before joining a profile: whether a host confirmed its release.
    PreJoinReleased(bool),
    /// The signed host list changed: attestations are checked against this one from now on.
    HostList(crate::host::HostList),
    /// A connected path to a friend: a new ADR 0001 session; `initiator` sends the preamble.
    Stream {
        friend: [u8; 32],
        stream: ChannelStream,
        route: Route,
        initiator: bool,
    },
    ReachChanged([u8; 32]),
    AttemptEnded {
        friend: [u8; 32],
        entry: crate::order::LogEntry,
    },
    Link(LinkEvent),
    /// Add by ID online: our request delivered or not, or someone's request to us.
    ById(IdEvent),
    /// Joining through the host: a request for every device, a pipe ready, its messages, its end.
    Join(JoinEvent),
    /// The host says another of the person's computers removed this one.
    Removed,
}

/// A change to the links service, run on the online thread.
type LinksChange = Box<dyn FnOnce(&mut Links, &mut HostClient) + Send>;

enum Input {
    Driver(driver::Input),
    Host(HostInput),
    Reach([u8; 32]),
    NearbyRoutesChanged,
    NetworkChanged,
    MembershipChanged,
    StunResolved(Vec<SocketAddr>),
    Links(LinksChange),
    RequestById(u64, String, RequestFrame),
    JoinRequest(String, Vec<u8>),
    JoinCode(u64, String),
    JoinSend(u64, Vec<Vec<u8>>),
    JoinClose(u64, f64),
    Stop(Sender<()>),
}

/// The handle the helper keeps. Dropping it stops the thread.
#[derive(Debug)]
pub struct Online {
    inbox: Mutex<Sender<Input>>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// Joining: whether this device holds an approval, so answers a new computer's code.
    pub holds_approval: Arc<std::sync::atomic::AtomicBool>,
}

impl Online {
    pub fn start(config: OnlineConfig) -> (Self, Receiver<OnlineEvent>) {
        let (sender, inbox) = channel::<Input>();
        let (events, receiver) = channel();
        let world = World::new(config, sender.clone(), events);
        let holds_approval = world.join.holds_approval.clone();
        // Without the thread nothing happens online; the helper carries on nearby.
        let thread = std::thread::Builder::new().name("szfriends-online".into()).spawn(move || world.run(inbox)).ok();
        (Self { inbox: Mutex::new(sender), thread: Mutex::new(thread), holds_approval }, receiver)
    }

    fn send(&self, input: Input) {
        let _ = self.inbox.lock().unwrap_or_else(|e| e.into_inner()).send(input);
    }

    /// The helper wants a session with this friend and no route ranking before Internet carries one.
    pub fn reach(&self, friend: [u8; 32]) {
        self.send(Input::Reach(friend));
    }

    pub fn nearby_routes_changed(&self) {
        self.send(Input::NearbyRoutesChanged);
    }

    pub fn network_changed(&self) {
        self.send(Input::NetworkChanged);
    }

    /// The profile's chain changed: the host connection checks in again when it was made for another root or chain.
    pub fn membership_changed(&self) {
        self.send(Input::MembershipChanged);
    }

    /// Add by ID online: NN to whoever holds `friends_id`, then the frame `frame` makes for that session; the outcome
    /// comes back as `OnlineEvent::ById(IdEvent::Sent { request, .. })`.
    pub fn request_by_id(&self, request: u64, friends_id: &str, frame: RequestFrame) {
        self.send(Input::RequestById(request, friends_id.to_owned(), frame));
    }

    /// Joining: the new computer's request to every device of `friends_id`.
    pub fn join_request(&self, friends_id: &str, message: Vec<u8>) {
        self.send(Input::JoinRequest(friends_id.to_owned(), message));
    }

    /// Joining: the new computer's code, on a pipe the helper numbers `pipe`.
    pub fn join_code(&self, pipe: u64, friends_id: &str) {
        self.send(Input::JoinCode(pipe, friends_id.to_owned()));
    }

    pub fn join_send(&self, pipe: u64, messages: Vec<Vec<u8>>) {
        self.send(Input::JoinSend(pipe, messages));
    }

    pub fn join_close(&self, pipe: u64, linger: f64) {
        self.send(Input::JoinClose(pipe, linger));
    }

    /// Runs `change` on the links service, on the online thread.
    pub fn links(&self, change: impl FnOnce(&mut Links, &mut HostClient) + Send + 'static) {
        self.send(Input::Links(Box::new(change)));
    }

    /// Ends every attempt, the links and the host connection, and returns once the thread has ended and every
    /// connection it made has been handed for release (`szfriends_datachannel_sys::wait_released` waits for that).
    pub fn stop(&self) {
        let Some(thread) = self.thread.lock().unwrap_or_else(|e| e.into_inner()).take() else { return };
        let (done, wait) = channel();
        self.send(Input::Stop(done));
        // The thread answers just before it returns; one that does not answer is not waited for forever.
        if !matches!(wait.recv_timeout(STOP_WAIT), Err(RecvTimeoutError::Timeout)) {
            let _ = thread.join();
        }
    }
}

impl Drop for Online {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The driver's sids, through the host connection.
struct Host<'a> {
    client: &'a mut HostClient,
}

impl SignalHost for Host<'_> {
    fn open(&mut self, attempt: u64, rdv_key: [u8; 32], payload: Vec<u8>) {
        self.client.open_to_rendezvous(attempt, &rdv_key, &payload);
    }

    fn send(&mut self, sid: &str, payload: &[u8]) -> bool {
        self.client.send_payload(sid, payload)
    }

    fn close(&mut self, sid: &str) {
        self.client.close_sid(sid);
    }

    fn request_relay(&mut self, attempt: u64, sid: &str) {
        self.client.request_relay(attempt, sid);
    }
}

struct World {
    host: HostClient,
    driver: Driver,
    links: Links,
    by_id: IdExchanges,
    join: JoinPipes,
    events: Sender<OnlineEvent>,
    inbox: Sender<Input>,
    lookups: HashMap<u64, [u8; 32]>,
    last_lookup: HashMap<[u8; 32], f64>,
    next_lookup: u64,
    loopback_only: bool,
    start: Instant,
}

impl World {
    fn new(config: OnlineConfig, inbox: Sender<Input>, events: Sender<OnlineEvent>) -> Self {
        let sink_inbox = Mutex::new(inbox.clone());
        let sink: driver::Sink = Arc::new(move |input| {
            let _ = sink_inbox.lock().unwrap_or_else(|e| e.into_inner()).send(Input::Driver(input));
        });
        let transport = if config.loopback_only { TransportConfig::loopback() } else { TransportConfig::default() };
        let mut driver = Driver::new(config.identity.clone(), transport, config.loopback_only, config.friends, sink);
        driver.context.direct_blocked = config.direct_blocked;
        driver.context.log_path = config.technique_log;
        let host_inbox = Mutex::new(inbox.clone());
        let host_sink: crate::host::HostSink = Arc::new(move |input| {
            let _ = host_inbox.lock().unwrap_or_else(|e| e.into_inner()).send(Input::Host(input));
        });
        let start = Instant::now();
        let clock = Arc::new(move || start.elapsed().as_secs_f64());
        let host = HostClient::new(
            config.identity.clone(),
            &config.app_version,
            config.list,
            config.pinned,
            host_sink,
            config.id_provider,
            clock,
        );
        let mut host = host;
        if let Some(pem) = config.host_roots {
            host.tls_roots = crate::host::websocket::Roots::Pem(pem);
        }
        host.membership = config.membership;
        host.release_owed = config.release_owed;
        let mut links = Links::new(config.identity, config.links, config.loopback_only);
        let link_inbox = Mutex::new(inbox.clone());
        links.forward = Some(Arc::new(move |id, event| {
            let input = Input::Driver(driver::Input::Connection(id, event));
            let _ = link_inbox.lock().unwrap_or_else(|e| e.into_inner()).send(input);
        }));
        Self {
            host,
            driver,
            links,
            by_id: IdExchanges::default(),
            join: JoinPipes::default(),
            events,
            inbox,
            lookups: HashMap::new(),
            last_lookup: HashMap::new(),
            next_lookup: 1u64 << 48,
            loopback_only: config.loopback_only,
            start,
        }
    }

    fn now(&self) -> f64 {
        self.start.elapsed().as_secs_f64()
    }

    fn run(mut self, inbox: Receiver<Input>) {
        self.host.start();
        loop {
            let now = self.now();
            let deadline = self.host.next_deadline().min(self.driver.next_deadline()).min(self.links.next_deadline());
            let deadline = deadline.min(self.by_id.next_deadline()).min(self.join.next_deadline());
            let wait = Duration::from_secs_f64((deadline - now).clamp(0.001, 0.25));
            match inbox.recv_timeout(wait) {
                Ok(Input::Stop(done)) => {
                    self.driver.stop(&mut Host { client: &mut self.host });
                    self.links.stop(&mut self.host);
                    self.by_id.stop(&mut self.host);
                    self.join.stop(&mut self.host);
                    self.host.stop();
                    self.forward_driver_events();
                    // Every connection goes now, on this thread, before stop returns: none outlives the stop.
                    drop(self);
                    let _ = done.send(());
                    return;
                }
                Ok(input) => self.handle(input),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            self.host.tick();
            self.driver.tick(&mut Host { client: &mut self.host });
            self.links.tick(&mut self.host);
            let now = self.now();
            self.by_id.tick(&mut self.host, now);
            self.join.tick(&mut self.host, now);
            self.settle();
        }
    }

    fn handle(&mut self, input: Input) {
        match input {
            Input::Driver(driver::Input::Connection(id, event)) if self.links.owns_connection(id) => {
                self.links.connection_event(&mut self.host, id, event);
            }
            Input::Driver(input) => self.driver.input(input, &mut Host { client: &mut self.host }),
            Input::Host(input) => self.host.input(input),
            Input::Reach(friend) => self.reach(friend),
            Input::NearbyRoutesChanged => self.driver.nearby_routes_changed(&mut Host { client: &mut self.host }),
            Input::NetworkChanged => {
                self.host.network_changed();
                self.driver.network_changed(&mut Host { client: &mut self.host });
            }
            Input::MembershipChanged => self.host.membership_changed(),
            Input::StunResolved(servers) => {
                self.driver.context.stun_primary = servers.first().copied();
                self.driver.context.stun_secondary = servers.get(1).copied();
                self.driver.context.measure_nat_class();
            }
            Input::Links(change) => change(&mut self.links, &mut self.host),
            Input::RequestById(request, friends_id, frame) => {
                let now = self.now();
                let started =
                    self.host.is_checked_in() && self.by_id.request(&mut self.host, request, &friends_id, frame, now);
                if !started {
                    let _ = self.events.send(OnlineEvent::ById(IdEvent::Sent { request, received: false }));
                }
            }
            Input::JoinRequest(friends_id, message) => {
                let now = self.now();
                if self.host.is_checked_in() {
                    self.join.request(&mut self.host, &friends_id, &message, now);
                }
            }
            Input::JoinCode(pipe, friends_id) => {
                let now = self.now();
                if !self.host.is_checked_in() || !self.join.code(&mut self.host, pipe, &friends_id, now) {
                    let _ = self.events.send(OnlineEvent::Join(JoinEvent::Ended(pipe)));
                }
            }
            Input::JoinSend(pipe, messages) => {
                self.join.send(&mut self.host, pipe, &messages);
            }
            Input::JoinClose(pipe, linger) => {
                let now = self.now();
                self.join.close(pipe, linger, now);
            }
            Input::Stop(_) => {}
        }
    }

    fn reach(&mut self, friend: [u8; 32]) {
        if !self.host.is_checked_in() || self.host.host_id().is_none() {
            return;
        }
        if self.driver.backed_off(&friend) {
            self.look_up(friend);
            return;
        }
        self.driver.reach_friend(&friend, &mut Host { client: &mut self.host });
    }

    /// While a friend is backed off, their record appearing (they came online) ends the wait.
    fn look_up(&mut self, friend: [u8; 32]) {
        let now = self.now();
        if self.last_lookup.get(&friend).is_some_and(|at| now - at < LOOKUP_PERIOD) {
            return;
        }
        self.last_lookup.insert(friend, now);
        let token = self.next_lookup;
        self.next_lookup += 1;
        self.lookups.insert(token, friend);
        // Filed under the person: a friend's other computer's records are under their root.
        let root = self.driver.friend(&friend).and_then(|f| f.root_key).unwrap_or(friend);
        self.host.lookup(token, &[record::rendezvous_key(&root)]);
    }

    /// Handles what the host and the driver produced until nothing more comes.
    fn settle(&mut self) {
        for _ in 0..64 {
            let outcomes = self.host.take_outcomes();
            if outcomes.is_empty() {
                break;
            }
            for outcome in outcomes {
                self.outcome(outcome);
            }
        }
        self.forward_driver_events();
        for event in self.links.take_events() {
            let _ = self.events.send(OnlineEvent::Link(event));
        }
        for event in self.by_id.take_events() {
            let _ = self.events.send(OnlineEvent::ById(event));
        }
        for event in self.join.take_events() {
            let _ = self.events.send(OnlineEvent::Join(event));
        }
    }

    fn forward_driver_events(&mut self) {
        for event in self.driver.take_events() {
            let event = match event {
                DriverEvent::Stream { friend, stream, route, initiator } => {
                    OnlineEvent::Stream { friend, stream, route, initiator }
                }
                DriverEvent::ReachChanged(friend) => OnlineEvent::ReachChanged(friend),
                DriverEvent::AttemptEnded { friend, entry, .. } => OnlineEvent::AttemptEnded { friend, entry },
            };
            let _ = self.events.send(event);
        }
    }

    fn records(&mut self, token: u64, blobs: Option<Vec<Vec<u8>>>) {
        let Some(friend) = self.lookups.remove(&token) else { return };
        let Some(blob) = blobs.and_then(|b| b.into_iter().next()) else { return };
        let Some(secret) = self.driver.friend(&friend).and_then(|f| f.presence_secret) else { return };
        let window = szfriends_crypto::presence::window_index(wall());
        // Only the friend's own record opens with their secret; the host's filler for someone offline does not.
        if record::open(&blob, &friend, &secret, &[friend], window).is_some() {
            self.driver.friend_appeared(&friend);
            self.driver.reach_friend(&friend, &mut Host { client: &mut self.host });
        }
    }

    /// This device's record for the period: its NAT class only. Candidates stay in the signalling.
    fn publish(&mut self) {
        let Some(secret) = self.driver.own_presence_secret() else { return };
        let context = &mut self.driver.context;
        let (class, step) = (context.nat_class(), context.nat_step());
        let item = Item::nat(class as u8, if class == NatClass::PerDestination { step } else { 0 });
        let identity = context.identity.clone();
        let window = szfriends_crypto::presence::window_index(wall());
        if let Some(sealed) = record::seal(&identity, &identity.public_key(), &secret, window, &[item]) {
            self.host.publish(&sealed);
        }
    }

    /// The connected host's STUN servers from the signed list, resolved off this thread to numeric addresses.
    fn resolve_stun(&mut self) {
        let uris = self.host.stun_uris();
        let (inbox, loopback) = (Mutex::new(self.inbox.clone()), self.loopback_only);
        std::thread::spawn(move || {
            let servers: Vec<SocketAddr> = uris.iter().filter_map(|uri| resolve_stun_uri(uri, loopback)).collect();
            let _ = inbox.lock().unwrap_or_else(|e| e.into_inner()).send(Input::StunResolved(servers));
        });
    }
}

fn wall() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

/// "stun:host[:port]" to its first address (3478 when no port).
fn resolve_stun_uri(uri: &str, loopback: bool) -> Option<SocketAddr> {
    let rest = uri.strip_prefix("stun:").filter(|r| !r.contains('?'))?;
    let (host, port) = match rest.strip_prefix('[') {
        Some(inner) => {
            let (host, tail) = inner.split_once(']')?;
            (host, tail.strip_prefix(':').map_or(Some(3478), |p| p.parse().ok())?)
        }
        None => {
            let (host, port) = rest.split_once(':').map_or((rest, Some(3478)), |(h, p)| (h, p.parse().ok()));
            (host, port?)
        }
    };
    let found = (host, port).to_socket_addrs().ok()?.next()?;
    (!loopback || found.ip().is_loopback()).then_some(found)
}
