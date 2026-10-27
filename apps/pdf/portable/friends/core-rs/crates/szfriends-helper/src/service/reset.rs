//! Reset Friends (PROTOCOL.md `reset_friends`; the Mac helper's `SZFriendsIntentRouter+Reset.m` and
//! `-resetFriendsWithError:`): a new identity and Friends ID. Friends, conversations, pictures, links and the device
//! chains go with the store, so on one of several of the person's computers this one leaves the profile and starts
//! one of its own (ADR 0012: Reset deletes every chain), while the others keep theirs. Received files stay where they
//! were saved.
//!
//! The order is the Mac helper's. The old key goes first: a key store that refuses (locked) changes nothing, and the
//! running service carries on as the same person. Then the Friends host forgets the old identity and frees its ID
//! (`online_release.rs`; at most 5 seconds, and the reset goes ahead unconfirmed offline), unless the ID stays with
//! the person's other computers. Then the service stops as it does at exit (sessions, nearby, online and the store
//! closed), the store goes, and a new service starts with a new identity, its Nearby started as it was before. Then
//! the reply, and every connection is closed with goodbye `reset`, so each page reconnects and subscribes again:
//! every view showed someone who no longer exists.
//!
//! A service cannot replace itself, so whoever runs it answers `reset_friends` before it: [`Resettable`] on Windows
//! and Linux, `PhoneService` on a phone (which also starts again from a store restored without its key).

use std::collections::HashMap;
use std::io::{self, ErrorKind};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

use serde_json::{json, Value};
use szfriends_contract::handshake::{goodbye, ClientInfo, GoodbyeReason};
use szfriends_core::intents::{error_message, IntentError};
use szfriends_core::presentation::Strings;
use szfriends_core::store::ReceivedDefaults;
use szfriends_identity::keystore::{KeyStore, IDENTITY_SECRET_NAME};

use super::Service;
use crate::events::SystemEvent;
use crate::log;
use crate::presentation::{Presentation, StubPresentation};
use crate::server::{Connection, Reply};

/// Makes the key store the identity lives in, for each start of the service.
pub type KeyStores = Arc<dyn Fn() -> Box<dyn KeyStore> + Send + Sync>;

/// What the reset leaves in the state directory: received files (not their unfinished downloads), a test home's
/// Downloads, and what belongs to the key store or to the helper process rather than to the identity: the key
/// store's directory and record (the key itself is deleted through the key store), the helper's copies, lock, pipe
/// directory and log, and a test's switch.
const KEPT: &[&str] = &[
    "received",
    "Downloads",
    "keys",
    "keystore",
    "helper",
    "ipc",
    "helper.lock",
    "helper.log",
    "helper.log.1",
    super::BLOCK_DIRECT_FILE,
];

/// Removes the store and everything else of the identity's in `state_dir`, keeping received files.
pub fn remove_store(state_dir: &Path) -> io::Result<()> {
    for entry in std::fs::read_dir(state_dir)? {
        let entry = entry?;
        if KEPT.iter().any(|kept| entry.file_name() == *kept) {
            continue;
        }
        if entry.file_type()?.is_dir() {
            std::fs::remove_dir_all(entry.path())?;
        } else {
            std::fs::remove_file(entry.path())?;
        }
    }
    match std::fs::remove_dir_all(state_dir.join("received").join(".partial")) {
        Err(error) if error.kind() != ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

/// Whether the person confirmed (`confirm` is `"reset"`); anything else is refused with `invalid_field`.
pub fn confirmed(intent: &Value, reply: Reply) -> Option<Reply> {
    if intent["confirm"] == "reset" {
        return Some(reply);
    }
    reply.error("invalid_field", None, json!({"field": "confirm"}));
    None
}

/// Why a reset stopped.
#[derive(Debug)]
enum Failure {
    /// The key store kept the old identity: nothing changed.
    IdentityKept,
    /// The old identity is gone but its store could not be removed.
    StoreKept,
}

impl Failure {
    /// The reply, worded for the person: `internal`, with `identity_not_removed` when nothing changed.
    fn reply(&self, connection: &Connection, reply: Reply) {
        let mut error = IntentError::new("internal");
        if matches!(self, Self::IdentityKept) {
            error.details.insert("reason".into(), json!("identity_not_removed"));
        }
        let audience = connection.client().map(|c| super::audience(&c, &[])).unwrap_or_default();
        let message = error_message(&error, &Strings::new(audience));
        reply.error(error.code, message.as_deref(), Value::Object(error.details));
    }
}

/// The old identity's end: its key, then the `running` service, then its store. Whether Nearby had been activated
/// (the person had opened Friends), so the new identity's service starts it the same way.
fn take_down(state_dir: &Path, keys: &dyn KeyStore, running: Option<&Service>) -> Result<bool, Failure> {
    if let Err(error) = keys.delete(IDENTITY_SECRET_NAME) {
        log!("reset stopped, the identity could not be removed: {error:?}");
        return Err(Failure::IdentityKept);
    }
    let activated = running.is_some_and(Service::stop);
    if let Err(error) = remove_store(state_dir) {
        log!("reset failed, the store was not removed: {error}");
        return Err(Failure::StoreKept);
    }
    Ok(activated)
}

/// What serves behind a protocol server: the service, or what explains why there is none.
pub trait Serving {
    fn service(&self) -> Option<Arc<Service>>;
}

/// The whole reset, for whoever runs the service in `serving`: the old identity goes, `start` makes what serves the
/// new one (Nearby started as it was), then the reply, then goodbye `reset` on every connection. Nothing reaches the
/// old service once it is going: `serving` stays locked until the new one is in its place.
pub fn reset<T: Serving>(
    serving: &RwLock<T>,
    start: impl FnOnce() -> T,
    (state_dir, keys): (&Path, &dyn KeyStore),
    connections: &Connections,
    (connection, reply): (&Connection, Reply),
) {
    let mut serving = serving.write().unwrap_or_else(|e| e.into_inner());
    let outcome = take_down(state_dir, keys, serving.service().as_deref());
    if let Err(Failure::IdentityKept) = outcome {
        drop(serving);
        return Failure::IdentityKept.reply(connection, reply);
    }
    *serving = start();
    if let (Ok(true), Some(service)) = (&outcome, serving.service()) {
        service.activate_nearby();
    }
    drop(serving);
    match outcome {
        Ok(_) => reply.ok(json!({})),
        Err(failure) => failure.reply(connection, reply),
    }
    for connection in connections.all() {
        connection.send_and_close(&goodbye(GoodbyeReason::Reset, None, None));
    }
}

/// The connections a reset closes: every one that said hello, whatever served it.
#[derive(Debug, Default)]
pub struct Connections(Mutex<HashMap<u64, Connection>>);

impl Connections {
    pub fn add(&self, connection: &Connection) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).insert(connection.id(), connection.clone());
    }

    pub fn remove(&self, connection_id: u64) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).remove(&connection_id);
    }

    pub fn all(&self) -> Vec<Connection> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect()
    }
}

/// What serves a helper's clients now.
enum Running {
    Service(Arc<Service>),
    /// The identity or the store could not be opened (the log says why).
    Stub(Arc<StubPresentation>),
}

impl Serving for Running {
    fn service(&self) -> Option<Arc<Service>> {
        match self {
            Self::Service(service) => Some(service.clone()),
            Self::Stub(_) => None,
        }
    }
}

impl Running {
    fn start(state_dir: &Path, keys: &KeyStores, received: &ReceivedDefaults) -> Self {
        match Service::start_with(state_dir, keys(), received.clone()) {
            Ok(service) => Self::Service(service),
            Err(error) => {
                log!("Friends service not started: {error}");
                Self::Stub(Arc::new(StubPresentation::failed()))
            }
        }
    }

    fn presentation(&self) -> Arc<dyn Presentation> {
        match self {
            Self::Service(service) => service.clone(),
            Self::Stub(stub) => stub.clone(),
        }
    }
}

/// The Windows and Linux helper's service, which Reset Friends replaces with a new identity's.
pub struct Resettable {
    state_dir: PathBuf,
    keys: KeyStores,
    received: ReceivedDefaults,
    running: RwLock<Running>,
    connections: Connections,
    /// When the service last failed to start; it is tried again as apps connect, at most every few seconds (a store
    /// another program held for a moment, a key store that answered late).
    failed_at: std::sync::Mutex<Option<std::time::Instant>>,
}

impl std::fmt::Debug for Resettable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Resettable").field("state_dir", &self.state_dir).finish()
    }
}

impl Resettable {
    pub fn start(state_dir: PathBuf, keys: KeyStores, received: ReceivedDefaults) -> Arc<Self> {
        let first = Running::start(&state_dir, &keys, &received);
        let failed_at = std::sync::Mutex::new(first.service().is_none().then(std::time::Instant::now));
        let running = RwLock::new(first);
        Arc::new(Self { state_dir, keys, received, running, connections: Connections::default(), failed_at })
    }

    /// While the stub serves, starts the service again (not more often than every 2 s); the connections already
    /// made are handed to it.
    fn start_again(&self) {
        if self.service().is_some() {
            return;
        }
        {
            let mut failed_at = self.failed_at.lock().unwrap_or_else(|e| e.into_inner());
            if failed_at.is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(2)) {
                return;
            }
            *failed_at = Some(std::time::Instant::now());
        }
        let started = Running::start(&self.state_dir, &self.keys, &self.received);
        let Some(service) = started.service() else { return };
        log!("Friends service started on a later try");
        *self.running.write().unwrap_or_else(|e| e.into_inner()) = started;
        *self.failed_at.lock().unwrap_or_else(|e| e.into_inner()) = None;
        for connection in self.connections.all() {
            service.connected(&connection);
        }
    }

    /// The running service; `None` while the stub serves.
    pub fn service(&self) -> Option<Arc<Service>> {
        self.running.read().unwrap_or_else(|e| e.into_inner()).service()
    }

    fn presentation(&self) -> Arc<dyn Presentation> {
        self.running.read().unwrap_or_else(|e| e.into_inner()).presentation()
    }
}

impl Presentation for Resettable {
    fn welcome(&self, client: &ClientInfo) -> Value {
        self.start_again();
        self.presentation().welcome(client)
    }

    fn connected(&self, connection: &Connection) {
        self.connections.add(connection);
        self.presentation().connected(connection);
    }

    fn intent(&self, connection: &Connection, intent: &Value, reply: Reply) {
        if intent["type"] == "reset_friends" {
            if let Some(reply) = confirmed(intent, reply) {
                let start = || Running::start(&self.state_dir, &self.keys, &self.received);
                let keys = (self.keys)();
                reset(&self.running, start, (&self.state_dir, &*keys), &self.connections, (connection, reply));
            }
            return;
        }
        self.presentation().intent(connection, intent, reply);
    }

    fn disconnected(&self, connection_id: u64) {
        self.connections.remove(connection_id);
        self.presentation().disconnected(connection_id);
    }

    fn system_event(&self, event: SystemEvent) {
        self.presentation().system_event(event);
    }

    fn work_in_flight(&self) -> bool {
        self.presentation().work_in_flight()
    }

    fn shutdown(&self) {
        self.presentation().shutdown();
    }
}
