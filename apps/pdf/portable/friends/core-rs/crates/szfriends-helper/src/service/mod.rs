//! The Friends service behind the protocol server: identity, store, views, intents and sessions, joined on one
//! thread as the Objective-C helper joins them on its queue (`service/helper/`). The presentation and the intents'
//! field rules are `szfriends-core`'s; this is what acts on them.
//!
//! What it serves today, the first of the helper's areas to come over:
//!
//! - the badge, list, conversation, details, profile, settings and Nearby views, built from the store;
//! - naming, messages and files to friends (offers, accepting, declining, cancelling, resuming), with the outbox's
//!   delivery states, over IK sessions between friends;
//! - nearby ([`nearby`], ADR 0004): discovery on the LAN, presence tags, the hidden and public listeners, friend
//!   requests, Add by ID and visibility; in a test home only test networks (a directory of entries on loopback, or a
//!   test service type), never the person's network;
//! - online ([`online`]): friends over the Internet, only in a test home whose test host list names loopback hosts
//!   (a person's own home would need the host's `wss://`, so messages for friends out of reach wait and say so). A
//!   friend is reached direct on the same network, then peer to peer, then over Bluetooth, then through the relay
//!   (`szfriends_core::wire::route::rank`): the session race keeps the best, and neither side dials a worse route;
//! - one profile on several computers ([`devices`], ADR 0012 to 0014): Your computers, joining over nearby, and sync
//!   with our other devices over the same nearby and online routes (`nearby/join.rs`, `nearby/own.rs`).
//!
//! - links ([`friend_links`], `links.rs`, `link_receive.rs`; PROTOCOL.md § Links): Add from a mention or a friend
//!   link, download links made and served, and download links received through a guest connection to the host.
//!
//! Search answers `unavailable` until its area comes over. Reset Friends replaces the service with a new identity's,
//! so whoever runs it answers that ([`reset`]).

mod again;
mod blocks;
mod boost;
mod device_files;
mod devices;
mod facts;
mod friend_links;
mod intents;
mod lanes;
mod link;
#[cfg(feature = "online")]
mod link_open;
#[cfg(feature = "online")]
mod link_receive;
#[cfg(feature = "online")]
mod links;
pub mod nearby;
mod notifications;
#[cfg(feature = "online")]
mod online;
#[cfg(not(feature = "online"))]
#[path = "online_off.rs"]
mod online;
pub(crate) mod pulls;
pub mod reset;
mod room;
pub mod seed;
mod sessions;
mod transfers;
mod views;

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_contract::handshake::ClientInfo;
use szfriends_core::identity::Identity;
use szfriends_core::presentation::{Audience, Strings};
use szfriends_core::store::Store;
use szfriends_identity::keystore::{IdentityManager, KeyStore, StoreIdentity};

use crate::events::SystemEvent;
use crate::log;
use crate::presentation::Presentation;
use crate::server::{Connection, Reply};

/// The test network a helper in a test home meets others on (a directory of entries on loopback).
pub const ENV_TEST_LOOPBACK: &str = crate::nearby::ENV_TEST_NETWORK;
pub use devices::set_local_device_name;
pub use online::{BLOCK_DIRECT_FILE, ENV_TEST_HOST_KEYS, ENV_TEST_HOST_LIST};
pub use room::TEST_FREE_BYTES_FILE;

/// What the service announces in every welcome (PROTOCOL.md § Capabilities); `nearby.bluetooth` too where this
/// helper has a Bluetooth adapter (not on Windows, nor on Linux without the `bluetooth` feature). `devices`: one
/// profile on several computers, joined and synced over the same nearby and online routes friends use.
/// `received.folder`: received files go to a folder the person can choose (Downloads until they do).
/// `notifications`: this helper decides and posts system notifications (ADR 0017).
const CAPABILITIES: &[&str] = &[
    "nearby.network",
    "messages.status",
    "messages.cancel",
    "mentions",
    "devices",
    "files.again",
    "received.folder",
    "notifications",
];

fn capabilities(bluetooth: bool) -> Vec<String> {
    let mut capabilities: Vec<String> = CAPABILITIES.iter().map(|c| (*c).to_owned()).collect();
    if bluetooth {
        capabilities.insert(1, "nearby.bluetooth".to_owned());
    }
    capabilities
}

pub(crate) enum Input {
    Connected(Connection),
    Intent(Connection, Value, Reply),
    Disconnected(u64),
    System(SystemEvent),
    Nearby(crate::nearby::Event),
    Link(link::LinkEvent),
    #[cfg(feature = "online")]
    Online(szfriends_online::OnlineEvent),
    /// A click or a reply on a notification, from the system's notifier.
    Notify(crate::notify::Response),
    /// Work that finished off the service's thread, to be completed on it.
    Deferred(Box<dyn FnOnce(&mut State) + Send>),
    Shutdown(Sender<()>),
}

/// The service, shared by the protocol server's threads; all work happens on its own thread.
pub struct Service {
    input: Mutex<Sender<Input>>,
    busy: Arc<AtomicBool>,
    identity_key: Option<[u8; 32]>,
    capabilities: Vec<String>,
}

impl std::fmt::Debug for Service {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Service").field("busy", &self.busy.load(Ordering::Relaxed)).finish()
    }
}

/// Why the service could not start; the helper then serves the stub, which says nothing is there.
#[derive(Debug)]
pub enum StartError {
    Identity(String),
    Store(String),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Identity(why) => write!(f, "identity: {why}"),
            Self::Store(why) => write!(f, "store: {why}"),
        }
    }
}

/// The audience a connection's snapshots are worded for.
pub(crate) fn audience(client: &ClientInfo, capabilities: &[String]) -> Audience {
    Audience {
        app_name: client.app_name.clone(),
        reveal_in: client.reveal_in.clone(),
        locale: client.locale.clone(),
        capabilities: client.capabilities.clone(),
        open_formats: client.open_formats.clone(),
        helper_capabilities: capabilities.iter().cloned().collect(),
        time_zone: local_time_zone(),
    }
}

/// This computer's time zone, so a time reads as the clock here does ("Today at 14:40"), daylight saving
/// included; UTC only where the system cannot say.
pub(crate) fn local_time_zone() -> szfriends_core::presentation::time::TimeZone {
    szfriends_core::presentation::time::TimeZone::from_fn(|instant| {
        szfriends_helper_sys::local_time::utc_offset_at(instant.floor() as i64).unwrap_or(0)
    })
}

impl Service {
    /// Loads the identity for the store in `state_dir` (creating both on a first start), opens the store and starts
    /// the service's thread.
    /// Received files go to `$SZFRIENDS_DOWNLOADS_DIR` or `Downloads` inside `state_dir` until the person chooses a
    /// folder: what tests and in-process services get. A helper for the person's own home passes their Downloads
    /// with [`Service::start_with`].
    pub fn start(state_dir: &Path, keys: Box<dyn KeyStore>) -> Result<Arc<Self>, StartError> {
        Self::start_with(state_dir, keys, szfriends_core::store::ReceivedDefaults::contained(state_dir))
    }

    /// As [`Service::start`], with where received files go until the person chooses a folder.
    pub fn start_with(
        state_dir: &Path,
        keys: Box<dyn KeyStore>,
        received: szfriends_core::store::ReceivedDefaults,
    ) -> Result<Arc<Self>, StartError> {
        std::fs::create_dir_all(state_dir).map_err(|e| StartError::Store(e.to_string()))?;
        let recorded = Store::identity_of(state_dir).map_err(|e| StartError::Store(e.to_string()))?;
        let manager = IdentityManager::new(Keys(keys));
        let (identity, _) = manager.load_or_create(recorded).map_err(|e| StartError::Identity(format!("{e:?}")))?;
        let options = szfriends_core::store::StoreOptions { received: Some(received), ..Default::default() };
        let mut store = Store::open_with(state_dir, options).map_err(|e| StartError::Store(e.to_string()))?;
        if recorded == StoreIdentity::NoStore {
            store.record_identity(&identity.public_key()).map_err(|e| StartError::Store(e.to_string()))?;
        }
        Ok(Self::run(identity, store))
    }

    fn run(identity: Identity, store: Store) -> Arc<Self> {
        let (input, inbox) = channel();
        let busy = Arc::new(AtomicBool::new(false));
        let identity_key = Some(identity.public_key());
        let state = State::new(identity, store, input.clone(), busy.clone());
        let capabilities = state.capabilities.clone();
        let spawned = std::thread::Builder::new().name("szfriends-service".into()).spawn(move || run(state, inbox));
        if let Err(error) = spawned {
            log!("no service thread: {error}");
        }
        Arc::new(Self { input: Mutex::new(input), busy, identity_key, capabilities })
    }

    fn send(&self, input: Input) {
        let _ = self.input.lock().unwrap_or_else(|e| e.into_inner()).send(input);
    }

    /// This helper's identity key.
    pub fn identity_key(&self) -> Option<[u8; 32]> {
        self.identity_key
    }

    /// Stops the service for Reset Friends ([`reset`]): the host releases this identity first (bounded; see
    /// `online_release.rs`), then sessions, nearby and online close as at exit, and the store is closed before it
    /// returns. Whether the person had opened Friends here (Nearby activated).
    pub fn stop(&self) -> bool {
        let (tell, told) = channel();
        self.send(Input::Deferred(Box::new(move |state| {
            state.release_identity_for_reset();
            let _ = tell.send(state.store.nearby_permissions_requested());
        })));
        let activated = told.recv_timeout(STOP_WAIT).unwrap_or(false);
        let (done, wait) = channel();
        self.send(Input::Shutdown(done));
        let _ = wait.recv_timeout(STOP_WAIT);
        activated
    }

    /// Starts Nearby in full, as the person opening Friends does (`activate`).
    pub fn activate_nearby(&self) {
        self.send(Input::Deferred(Box::new(State::activate_nearby)));
    }

    /// Puts a host's own notifier in place (a phone's native code: ADR 0017 § The request). Every request the
    /// service decides from now on goes to it; until one is installed a phone posts nothing.
    pub fn install_notifier(&self, notifier: Arc<dyn crate::notify::Notifier>) {
        self.send(Input::Deferred(Box::new(move |state| state.install_notifier(notifier))));
    }

    /// A click (`Open`) or an inline reply (`Reply`) on a notification the notifier posted, as the system reported
    /// it. Open needs nothing more where the system opens the request's URL itself (phones, Windows); a reply is sent
    /// in that conversation and marks it read.
    pub fn notification_response(&self, response: crate::notify::Response) {
        self.send(Input::Notify(response));
    }
}

/// How long a reset waits for the service to stop: its store must be closed before it is removed.
const STOP_WAIT: Duration = Duration::from_secs(10);

impl Presentation for Service {
    fn welcome(&self, client: &ClientInfo) -> Value {
        let strings = Strings::new(audience(client, &self.capabilities));
        json!({"capabilities": self.capabilities, "strings": strings.static_strings()})
    }

    fn connected(&self, connection: &Connection) {
        self.send(Input::Connected(connection.clone()));
    }

    fn intent(&self, connection: &Connection, intent: &Value, reply: Reply) {
        self.send(Input::Intent(connection.clone(), intent.clone(), reply));
    }

    fn disconnected(&self, connection_id: u64) {
        self.send(Input::Disconnected(connection_id));
    }

    fn system_event(&self, event: SystemEvent) {
        self.send(Input::System(event));
    }

    fn work_in_flight(&self) -> bool {
        self.busy.load(Ordering::SeqCst)
    }

    fn shutdown(&self) {
        let (done, wait) = channel();
        self.send(Input::Shutdown(done));
        let _ = wait.recv_timeout(Duration::from_secs(2));
    }
}

/// One client's subscriptions and wording.
pub(crate) struct Client {
    pub connection: Connection,
    pub audience: Audience,
    pub subscriptions: HashMap<String, views::Subscription>,
}

/// Everything the service's thread owns.
/// A test home's switch for fast transfers (ADR 0018 § 1): "0" plays a helper without them.
pub const ENV_TEST_FAST_TRANSFERS: &str = "SZFRIENDS_TEST_FAST_TRANSFERS";
/// A test home's switch for Get again and own-device copies by blocks: "0" asks for them by offset.
pub const ENV_TEST_COPIES_BY_BLOCKS: &str = "SZFRIENDS_TEST_COPIES_BY_BLOCKS";
/// A test home's switch for lanes (ADR 0018 § 6): "0" opens and admits none.
pub const ENV_TEST_LANES: &str = "SZFRIENDS_TEST_LANES";
/// A test home's switches for AES-GCM lanes and compressed parts (ADR 0018 § 9.2, § 9.4): "0" leaves that bit out of
/// the handshake, so the pair runs without it (the bench's before and after).
pub const ENV_TEST_AES_LANES: &str = "SZFRIENDS_TEST_AES_LANES";
pub const ENV_TEST_COMPRESSED_PARTS: &str = "SZFRIENDS_TEST_COMPRESSED_PARTS";
/// A test home's emulated route rates, `lan=1250000,bluetooth=175000` (bytes per second each side writes at), so
/// lanes over several routes can be measured on one computer (WP5's bench emulates one route at a time).
pub const ENV_TEST_ROUTE_RATES: &str = "SZFRIENDS_TEST_ROUTE_RATES";
/// A test home's file: while it names a route (`lan`, `bluetooth`, …), links on it write nothing (out of range).
pub const ENV_TEST_ROUTE_SILENCE: &str = "SZFRIENDS_TEST_ROUTE_SILENCE";

/// The names `SZFRIENDS_TEST_ROUTE_RATES` and `SZFRIENDS_TEST_ROUTE_SILENCE` use.
pub(crate) fn route_name(route: szfriends_core::wire::RouteMethod) -> &'static str {
    use szfriends_core::wire::RouteMethod;
    match route {
        RouteMethod::Lan => "lan",
        RouteMethod::PeerToPeerWifi => "p2p_wifi",
        RouteMethod::Bluetooth => "bluetooth",
        RouteMethod::Internet => "internet",
        RouteMethod::Relay => "relay",
        RouteMethod::None => "none",
    }
}

fn route_rates(text: &str) -> HashMap<szfriends_core::wire::RouteMethod, f64> {
    use szfriends_core::wire::RouteMethod;
    text.split(',')
        .filter_map(|pair| {
            let (name, rate) = pair.split_once('=')?;
            let route = match name.trim() {
                "lan" => RouteMethod::Lan,
                "p2p_wifi" => RouteMethod::PeerToPeerWifi,
                "bluetooth" => RouteMethod::Bluetooth,
                "internet" => RouteMethod::Internet,
                "relay" => RouteMethod::Relay,
                _ => return None,
            };
            Some((route, rate.trim().parse::<f64>().ok().filter(|r| *r > 0.0)?))
        })
        .collect()
}

pub(crate) struct State {
    pub identity: Identity,
    pub store: Store,
    pub clients: HashMap<u64, Client>,
    pub next_subscription: u64,
    pub input: Sender<Input>,
    pub busy: Arc<AtomicBool>,
    pub sessions: sessions::Sessions,
    pub nearby: nearby::Nearby,
    pub online: Option<online::OnlineRoutes>,
    /// The download links the online thread serves.
    #[cfg(feature = "online")]
    pub links: links::LinkShelf,
    #[cfg(feature = "online")]
    pub links_swept_at: f64,
    /// Download links being received, by number.
    #[cfg(feature = "online")]
    pub link_receipts: HashMap<u64, link_receive::Receipt>,
    #[cfg(feature = "online")]
    pub next_receipt: u64,
    /// What this helper announces.
    pub capabilities: Vec<String>,
    /// The handshake's capability bits ([`szfriends_core::session::local_capabilities`]): none without fast
    /// transfers, which are off only in a test home that plays a released helper (`SZFRIENDS_TEST_FAST_TRANSFERS=0`)
    /// or by the settings key; less a test home's other switches.
    pub session_capabilities: u32,
    /// Files received by blocks whose check before saving is running, since when (`blocks.rs`).
    pub finishing: HashMap<String, std::time::Instant>,
    /// ADR 0019: the Wi-Fi Direct boost (`boost.rs`).
    pub(crate) boost: boost::BoostArea,
    /// Get again and own-device copies asked for by blocks on fast sessions (ADR 0018 § 4), which both helpers
    /// answer. Served by blocks whenever asked; asked for by offset only in a test home that says so
    /// (`SZFRIENDS_TEST_COPIES_BY_BLOCKS=0`).
    pub copies_by_blocks: bool,
    /// ADR 0018 § 6: lanes beside a fast session; off only in a test home (`SZFRIENDS_TEST_LANES=0`).
    pub lanes: bool,
    /// A test home's emulated routes: bytes per second each route's links write at (`SZFRIENDS_TEST_ROUTE_RATES`).
    pub route_rates: HashMap<szfriends_core::wire::RouteMethod, f64>,
    /// A test home's file naming routes to silence (`SZFRIENDS_TEST_ROUTE_SILENCE`), as out of range.
    pub route_silence: Option<std::path::PathBuf>,
    /// One profile on several computers: the join state and the sync engine.
    pub devices: devices::DeviceArea,
    /// Get again: giving friends files again, and copying files again from them.
    pub again: again::AgainArea,
    /// A file pulled from every device that holds it at once (`pulls.rs`).
    pub pulls: pulls::PullArea,
    /// System notifications: what was seen, focus, this device's switches, the notifier.
    pub notify: notifications::NotifyArea,
    /// Something changed since the views were last brought up to date.
    pub dirty: bool,
    /// Answered once the thread has closed the store (shutdown).
    stopped: Option<Sender<()>>,
}

impl State {
    fn new(identity: Identity, mut store: Store, input: Sender<Input>, busy: Arc<AtomicBool>) -> Self {
        let test_home = std::env::var_os(crate::state::ENV_STATE_DIR).is_some();
        let fast_setting = store.fast_transfers_enabled();
        let adapters = crate::nearby::adapters(store.state_dir(), test_home, nearby::sink(input.clone()));
        let nearby = nearby::Nearby::new(adapters, store.visibility_deadline());
        let mut capabilities = capabilities(nearby.has_adapter(szfriends_core::nearby::Method::Bluetooth));
        #[cfg(feature = "online")]
        let links = links::LinkShelf::default();
        #[cfg(feature = "online")]
        let online = online::OnlineRoutes::from_environment(
            &identity,
            &mut store,
            input.clone(),
            Box::new(links.clone()),
            nearby.policy.clone(),
        );
        #[cfg(not(feature = "online"))]
        let online = online::OnlineRoutes::from_environment(&identity, &mut store, input.clone());
        let devices = devices::DeviceArea::new(&identity, store.state_dir().join("received"));
        let responses = std::sync::Mutex::new(input.clone());
        let responder: crate::notify::Responder = Arc::new(move |response| {
            let _ = responses.lock().unwrap_or_else(|e| e.into_inner()).send(Input::Notify(response));
        });
        let notifier = crate::notify::platform_notifier(store.state_dir(), test_home, responder);
        let notify = notifications::NotifyArea::new(&store, test_home, notifier);
        // Links are made for the Friends host's pages, so only a helper that checks in offers them.
        if online.is_some() {
            capabilities.push("links".to_owned());
        }
        let fast_transfers =
            fast_setting && !(test_home && std::env::var_os(ENV_TEST_FAST_TRANSFERS).is_some_and(|v| v == "0"));
        let switched_off = |name: &str| test_home && std::env::var_os(name).is_some_and(|v| v == "0");
        let mut session_capabilities = szfriends_core::session::local_capabilities(fast_transfers);
        // ADR 0019: the Wi-Fi Direct boost, where this device can host or join a direct link.
        let boost = boost::BoostArea::new(store.state_dir(), test_home);
        let lanes = !(test_home && std::env::var_os(ENV_TEST_LANES).is_some_and(|v| v == "0"));
        if fast_transfers && lanes && boost.available() {
            session_capabilities |= szfriends_core::wire::consts::CAPABILITY_DIRECT_WIFI_BOOST;
        }
        if switched_off(ENV_TEST_AES_LANES) {
            session_capabilities &= !szfriends_core::wire::consts::CAPABILITY_AES_LANES;
        }
        if switched_off(ENV_TEST_COMPRESSED_PARTS) {
            use szfriends_core::wire::consts::{CAPABILITY_COMPRESSED_PARTS, CAPABILITY_LZ4_PARTS};
            session_capabilities &= !(CAPABILITY_COMPRESSED_PARTS | CAPABILITY_LZ4_PARTS);
        }
        Self {
            identity,
            store,
            clients: HashMap::new(),
            next_subscription: 0,
            input,
            busy,
            sessions: sessions::Sessions::default(),
            nearby,
            online,
            #[cfg(feature = "online")]
            links,
            #[cfg(feature = "online")]
            links_swept_at: 0.0,
            #[cfg(feature = "online")]
            link_receipts: HashMap::new(),
            #[cfg(feature = "online")]
            next_receipt: 0,
            capabilities,
            finishing: HashMap::new(),
            copies_by_blocks: !(test_home && std::env::var_os(ENV_TEST_COPIES_BY_BLOCKS).is_some_and(|v| v == "0")),
            // The settings key `transfers.fast` (on unless it holds 0), read as the helper starts.
            session_capabilities,
            lanes,
            boost,
            route_rates: if test_home {
                route_rates(&std::env::var(ENV_TEST_ROUTE_RATES).unwrap_or_default())
            } else {
                HashMap::new()
            },
            route_silence: test_home.then(|| std::env::var_os(ENV_TEST_ROUTE_SILENCE).map(Into::into)).flatten(),
            devices,
            again: again::AgainArea::default(),
            pulls: pulls::PullArea::default(),
            notify,
            dirty: false,
            stopped: None,
        }
    }

    /// Marks the views for an update after the current input.
    pub fn changed(&mut self) {
        self.dirty = true;
    }

    fn handle(&mut self, input: Input) -> bool {
        match input {
            Input::Connected(connection) => {
                if let Some(client) = connection.client() {
                    let audience = audience(&client, &self.capabilities);
                    let id = connection.id();
                    self.clients.insert(id, Client { connection, audience, subscriptions: HashMap::new() });
                }
            }
            Input::Intent(connection, frame, reply) => self.intent(&connection, &frame, reply),
            Input::Disconnected(id) => {
                self.clients.remove(&id);
                self.notify.disconnected(id);
            }
            Input::Notify(response) => {
                let _ = self.notification_response(response);
            }
            Input::System(event) => self.system_event(event),
            Input::Nearby(event) => self.nearby_event(event),
            Input::Link(event) => self.link_event(event),
            #[cfg(feature = "online")]
            Input::Online(event) => self.online_event(event),
            Input::Deferred(work) => work(self),
            Input::Shutdown(done) => {
                self.boost_quitting();
                drop(self.online.take());
                let _ = self.store.flush_progress();
                self.stop_nearby();
                self.close_all_sessions();
                self.stopped = Some(done);
                return false;
            }
        }
        true
    }

    fn system_event(&mut self, event: SystemEvent) {
        match event {
            // Before sleep, received bytes are made durable at a verified offset; sessions end with the network.
            SystemEvent::Sleep => {
                let _ = self.store.flush_progress();
            }
            SystemEvent::Wake | SystemEvent::NetworkChanged => {
                if let Some(online) = &self.online {
                    online.network_changed();
                }
                self.restart_nearby_after_wake();
            }
        }
    }
}

fn run(mut state: State, inbox: Receiver<Input>) {
    #[cfg(feature = "online")]
    state.refresh_links();
    state.boost_launched();
    state.start_nearby();
    let mut later = std::collections::VecDeque::new();
    loop {
        let wait = state.next_wakeup().min(Duration::from_millis(250));
        let next = match later.pop_front() {
            Some(input) => Ok(input),
            None => inbox.recv_timeout(wait),
        };
        match next {
            Ok(input) => {
                let link = matches!(input, Input::Link(_));
                if !state.handle(input) {
                    break;
                }
                // Bytes already read from the links are handled before the sessions run, so what they carry (a
                // burst of small files) shares one store batch and one flush per session (ADR 0018 § 9.3).
                for _ in 0..64 {
                    if !link {
                        break;
                    }
                    match inbox.try_recv() {
                        Ok(Input::Link(event)) => state.link_event(event),
                        Ok(other) => {
                            later.push_back(other);
                            break;
                        }
                        Err(_) => break,
                    }
                }
            }
            Err(RecvTimeoutError::Timeout) => state.tick(),
            Err(RecvTimeoutError::Disconnected) => break,
        }
        state.service_sessions();
        state.notify_pass(state.dirty);
        if state.dirty {
            state.dirty = false;
            state.schedule_sync_capture();
            state.update_views();
        }
        let moving = state.sessions.moving();
        state.busy.store(moving, Ordering::SeqCst);
    }
    // The store is closed before shutdown is answered, so whoever waited may reopen or remove it at once.
    let stopped = state.stopped.take();
    drop(state);
    if let Some(done) = stopped {
        let _ = done.send(());
    }
}

/// The platform's key store, behind the generic manager.
struct Keys(Box<dyn KeyStore>);

impl KeyStore for Keys {
    fn secret(&self, name: &str) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>, szfriends_identity::IdentityError> {
        self.0.secret(name)
    }

    fn store(&self, name: &str, secret: &[u8]) -> Result<(), szfriends_identity::IdentityError> {
        self.0.store(name, secret)
    }

    fn delete(&self, name: &str) -> Result<(), szfriends_identity::IdentityError> {
        self.0.delete(name)
    }
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub(crate) fn unhex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}
