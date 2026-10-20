//! Friends on a phone (ADR 0015 § 3, § 7, § 10, § 17): the service in the app's own process, its key store, a
//! restored store's Start again, and the foreground-only lifecycle.
//!
//! - The identity's key lives in the Android Keystore (a sealed file) or the iOS Keychain (this device only), and the
//!   state directory is kept out of backups (Android's no-backup directory, iOS's excluded-from-backup flag), so a
//!   restored phone starts Friends afresh instead of with somebody else's history.
//! - A store whose key is missing, or that belongs to another key, is never used: [`restored::Restored`] explains it
//!   and offers Start again, which removes the store (keeping received files, as Reset Friends does), then the key,
//!   and starts the service with a new identity.
//! - Friends runs while the app is in the foreground. When the app goes to the background, sessions and transfers
//!   carry on for a grace period; after it, received bytes are made durable at a verified offset (the service's
//!   Sleep). Back in the foreground the service dials its friends again and transfers resume where they stopped.
//!
//! Everything here builds and is tested on any computer; `native.rs` joins it to the app's Kotlin and Swift code.

#[cfg(any(target_os = "android", target_os = "ios"))]
pub mod animals;
pub mod keys;
#[cfg(any(target_os = "android", target_os = "ios"))]
pub mod native;
pub mod received;
pub mod restored;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_contract::handshake::{goodbye, ClientInfo, GoodbyeReason};
use szfriends_core::store::{ReceivedDefaults, Store};
use szfriends_helper::events::SystemEvent;
use szfriends_helper::presentation::{Presentation, StubPresentation};
use szfriends_helper::server::{Connection, Reply};
use szfriends_helper::service::Service;
use szfriends_identity::keystore::{IdentityManager, KeyStore};
use szfriends_identity::IdentityError;

/// How long Friends keeps going after the app leaves the foreground: long enough for switching apps to copy a code
/// or answer a message without cutting a transfer, short enough to stop well before the system suspends the app.
pub const GRACE: Duration = Duration::from_secs(20);

/// Makes the key store the identity lives in, each time the service (re)starts.
pub type Keys = Arc<dyn Fn() -> Box<dyn KeyStore> + Send + Sync>;

/// What runs behind the phone's protocol server now.
enum Current {
    Service(Arc<Service>),
    Restored(Arc<restored::Restored>),
    /// The key store refused (a locked device, a broken Keystore): nothing is created or removed; the panel shows
    /// that Friends is not answering, and the next start tries again.
    Stub(Arc<StubPresentation>),
}

impl Current {
    fn presentation(&self) -> Arc<dyn Presentation> {
        match self {
            Self::Service(s) => s.clone(),
            Self::Restored(r) => r.clone(),
            Self::Stub(s) => s.clone(),
        }
    }
}

#[derive(Default)]
struct Lifecycle {
    /// Bumped on every change, so a grace timer that outlived its background period does nothing.
    generation: u64,
    foreground: bool,
    /// The grace period ended in the background: the service was told to pause.
    paused: bool,
}

/// The service a phone's app runs in-process, with Start again and the foreground lifecycle.
pub struct PhoneService {
    state_dir: PathBuf,
    keys: Keys,
    /// Where received files go (`received.rs`).
    received: ReceivedDefaults,
    current: RwLock<Current>,
    lifecycle: Mutex<Lifecycle>,
    grace: Duration,
}

impl std::fmt::Debug for PhoneService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PhoneService").field("state_dir", &self.state_dir).field("state", &self.state()).finish()
    }
}

/// What the store and key say at a start.
fn begin(state_dir: &Path, keys: &Keys, received: &ReceivedDefaults) -> Current {
    let checked = (|| {
        std::fs::create_dir_all(state_dir).map_err(|_| IdentityError::StoreFailed)?;
        // A store that records no identity is another identity's; one that cannot be opened is no reason to offer
        // Start again (it answers as the key store refusing).
        let recorded = Store::identity_of(state_dir).map_err(|error| match error {
            szfriends_core::store::StoreError::IdentityMismatch => IdentityError::StoreMismatch,
            _ => IdentityError::Unavailable,
        })?;
        IdentityManager::new(Boxed(keys())).load_or_create(recorded)
    })();
    match checked {
        Ok(_) => match Service::start_with(state_dir, keys(), received.clone()) {
            Ok(service) => Current::Service(service),
            Err(error) => {
                crate::link::log(&format!("Friends service not started: {error}"));
                Current::Stub(Arc::default())
            }
        },
        Err(IdentityError::KeyMissing | IdentityError::StoreMismatch) => {
            crate::link::log("the Friends store has no key on this device: Start again is offered");
            Current::Restored(Arc::default())
        }
        Err(error) => {
            crate::link::log(&format!("the Friends key cannot be read: {error}"));
            Current::Stub(Arc::default())
        }
    }
}

impl PhoneService {
    /// Received files stay inside `state_dir` (`Downloads`): what tests get.
    pub fn start(state_dir: PathBuf, keys: Keys) -> Arc<Self> {
        let received = ReceivedDefaults::contained(&state_dir);
        Self::with_grace(state_dir, keys, received, GRACE)
    }

    /// With where received files go on this phone (`received::defaults`).
    pub fn start_with(state_dir: PathBuf, keys: Keys, received: ReceivedDefaults) -> Arc<Self> {
        Self::with_grace(state_dir, keys, received, GRACE)
    }

    pub fn with_grace(state_dir: PathBuf, keys: Keys, received: ReceivedDefaults, grace: Duration) -> Arc<Self> {
        let current = begin(&state_dir, &keys, &received);
        let lifecycle = Lifecycle { foreground: true, ..Lifecycle::default() };
        Arc::new(Self {
            state_dir,
            keys,
            received,
            current: RwLock::new(current),
            lifecycle: Mutex::new(lifecycle),
            grace,
        })
    }

    /// "service", "restored" or "stub", for tests and the log.
    pub fn state(&self) -> &'static str {
        match &*self.current.read().unwrap_or_else(|e| e.into_inner()) {
            Current::Service(_) => "service",
            Current::Restored(_) => "restored",
            Current::Stub(_) => "stub",
        }
    }

    fn presentation(&self) -> Arc<dyn Presentation> {
        self.current.read().unwrap_or_else(|e| e.into_inner()).presentation()
    }

    /// Start again: the store goes (received files stay), then the key, then a new identity and store. Every
    /// connection is closed afterwards, so each page reconnects to the new service and subscribes again.
    fn start_again(&self, reply: Reply) {
        let mut current = self.current.write().unwrap_or_else(|e| e.into_inner());
        let Current::Restored(restored) = &*current else { return reply.error("not_allowed", None, json!({})) };
        let restored = restored.clone();
        if let Err(error) = remove_store(&self.state_dir) {
            crate::link::log(&format!("Start again: the store was not removed: {error}"));
            return reply.error("internal", None, json!({}));
        }
        if self.keys.as_ref()().delete(szfriends_identity::keystore::IDENTITY_SECRET_NAME).is_err() {
            return reply.error("internal", None, json!({}));
        }
        *current = begin(&self.state_dir, &self.keys, &self.received);
        drop(current);
        reply.ok(json!({}));
        for connection in restored.connections() {
            connection.send_and_close(&goodbye(GoodbyeReason::Reset, None, None));
        }
    }

    /// The app left the foreground: after the grace period, unless it came back, the service pauses.
    pub fn suspended(self: &Arc<Self>) {
        let generation = {
            let mut lifecycle = self.lifecycle.lock().unwrap_or_else(|e| e.into_inner());
            lifecycle.generation += 1;
            lifecycle.foreground = false;
            lifecycle.generation
        };
        let service = Arc::downgrade(self);
        let grace = self.grace;
        let spawned = std::thread::Builder::new().name("szfriends-grace".into()).spawn(move || {
            std::thread::sleep(grace);
            let Some(service) = service.upgrade() else { return };
            let mut lifecycle = service.lifecycle.lock().unwrap_or_else(|e| e.into_inner());
            if lifecycle.generation == generation && !lifecycle.foreground && !lifecycle.paused {
                lifecycle.paused = true;
                drop(lifecycle);
                service.presentation().system_event(SystemEvent::Sleep);
            }
        });
        if spawned.is_err() {
            self.presentation().system_event(SystemEvent::Sleep);
        }
    }

    /// Back in the foreground: a paused service dials its friends again and resumes transfers.
    pub fn resumed(&self) {
        let paused = {
            let mut lifecycle = self.lifecycle.lock().unwrap_or_else(|e| e.into_inner());
            lifecycle.generation += 1;
            lifecycle.foreground = true;
            std::mem::take(&mut lifecycle.paused)
        };
        if paused {
            self.presentation().system_event(SystemEvent::Wake);
        }
    }

    /// Whether the grace period ended in the background (for tests).
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn paused(&self) -> bool {
        self.lifecycle.lock().unwrap_or_else(|e| e.into_inner()).paused
    }
}

/// A boxed key store, for the generic manager.
struct Boxed(Box<dyn KeyStore>);

impl KeyStore for Boxed {
    fn secret(&self, name: &str) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>, IdentityError> {
        self.0.secret(name)
    }

    fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
        self.0.store(name, secret)
    }

    fn delete(&self, name: &str) -> Result<(), IdentityError> {
        self.0.delete(name)
    }
}

/// Removes the store and what belongs to its identity, keeping received files (`received/`, and `Downloads/` in a
/// test home), as Reset Friends does.
fn remove_store(state_dir: &Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(state_dir)? {
        let entry = entry?;
        if entry.file_name() == "received" || entry.file_name() == "Downloads" {
            continue;
        }
        let kind = entry.file_type()?;
        if kind.is_dir() {
            std::fs::remove_dir_all(entry.path())?;
        } else {
            std::fs::remove_file(entry.path())?;
        }
    }
    Ok(())
}

impl Presentation for PhoneService {
    fn welcome(&self, client: &ClientInfo) -> Value {
        self.presentation().welcome(client)
    }

    fn connected(&self, connection: &Connection) {
        self.presentation().connected(connection);
    }

    fn intent(&self, connection: &Connection, intent: &Value, reply: Reply) {
        if intent["type"] == "reset_friends" && self.state() == "restored" {
            if intent["confirm"] != "reset" {
                return reply.error("invalid_field", None, json!({"field": "confirm"}));
            }
            return self.start_again(reply);
        }
        self.presentation().intent(connection, intent, reply);
    }

    fn disconnected(&self, connection_id: u64) {
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

#[cfg(test)]
#[path = "../tests/phone.rs"]
mod tests;
