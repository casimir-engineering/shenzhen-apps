//! Reset Friends on the Windows and Linux helper (`service::reset`), end to end through the protocol server: a new
//! identity at once, the friends gone, received files kept, Nearby started again as it was, every page told to
//! reconnect; and a key store that refuses changes nothing.

mod clients;
mod support;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use clients::{texts, Client, Temp};
use serde_json::{json, Value};
use szfriends_core::store::{ReceivedDefaults, Store};
use szfriends_helper::service::reset::{KeyStores, Resettable};
use szfriends_helper::service::{seed, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;
use szfriends_identity::keystore::KeyStore;
use szfriends_identity::IdentityError;
use zeroize::Zeroizing;

/// The test home's key file; deleting it refused while `locked` (a keyring that refuses).
struct Keys {
    home: PathBuf,
    locked: Arc<AtomicBool>,
}

impl KeyStore for Keys {
    fn secret(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, IdentityError> {
        seed::test_key_store(&self.home).secret(name)
    }

    fn store(&self, name: &str, secret: &[u8]) -> Result<(), IdentityError> {
        seed::test_key_store(&self.home).store(name, secret)
    }

    fn delete(&self, name: &str) -> Result<(), IdentityError> {
        if self.locked.load(Ordering::SeqCst) {
            return Err(IdentityError::StoreFailed);
        }
        seed::test_key_store(&self.home).delete(name)
    }
}

/// The ports the test network's entries name now: one per listener of a running Nearby.
fn ports(routes: &Path) -> BTreeSet<u64> {
    let entries = std::fs::read_dir(routes).map(|d| d.flatten().collect::<Vec<_>>()).unwrap_or_default();
    entries
        .iter()
        .filter(|e| e.file_name().to_string_lossy().ends_with(".entry"))
        .filter_map(|e| std::fs::read(e.path()).ok())
        .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .filter_map(|entry| entry["port"].as_u64())
        .collect()
}

fn until(what: &str, condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !condition() {
        assert!(Instant::now() < deadline, "no {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn reset_friends_replaces_the_identity_at_once_and_starts_nearby_again() {
    let (a, b, routes) = (Temp::new("reset-a"), Temp::new("reset-b"), Temp::new("reset-routes"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &routes.0);
    seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    let locked = Arc::new(AtomicBool::new(false));
    let (home, refuse) = (a.0.clone(), locked.clone());
    let keys: KeyStores = Arc::new(move || Box::new(Keys { home: home.clone(), locked: refuse.clone() }));
    let helper = Resettable::start(a.0.clone(), keys, ReceivedDefaults::contained(&a.0));
    let server = Client::server(helper.clone());
    let mut ada = Client::join(&server, helper.clone(), &["drop.files"]);

    let list = ada.subscribe("list", json!({}));
    ada.snapshot(&list, "Bo in the list", |d| texts(d).contains("Bo"));
    let profile = ada.subscribe("profile", json!({}));
    let before =
        ada.snapshot(&profile, "the ID", |d| d["id"]["friends_id"].is_string())["data"]["id"]["friends_id"].clone();
    ada.send("activate", json!({}));
    until("Nearby on the test network", || !ports(&routes.0).is_empty());
    let old_ports = ports(&routes.0);
    let recorded = Store::identity_of(&a.0).unwrap();
    std::fs::create_dir_all(a.0.join("Downloads")).unwrap();
    std::fs::write(a.0.join("Downloads/Gearbox.step"), b"kept").unwrap();

    // The keyring refuses: nothing changes, and the reply says so.
    locked.store(true, Ordering::SeqCst);
    let refused = ada.request("reset_friends", json!({"confirm": "reset"}));
    assert_eq!(refused["error"]["details"]["reason"], "identity_not_removed", "{refused}");
    assert_eq!(
        refused["error"]["message"],
        "Nothing was reset: Friends couldn’t remove your old ID from this computer. Make sure it’s unlocked, then \
         try again."
    );
    assert_eq!(Store::identity_of(&a.0).unwrap(), recorded);
    let still = ada.subscribe("list", json!({}));
    ada.snapshot(&still, "Bo still in the list", |d| texts(d).contains("Bo"));
    locked.store(false, Ordering::SeqCst);

    assert_eq!(ada.refused("reset_friends", json!({"confirm": "yes"})), "invalid_field");
    ada.send("reset_friends", json!({"confirm": "reset"}));
    let goodbye = ada.wait("goodbye", |f| f["type"] == "goodbye");
    assert_eq!(goodbye["reason"], "reset");
    assert_ne!(Store::identity_of(&a.0).unwrap(), recorded, "a new identity");
    assert_eq!(std::fs::read(a.0.join("Downloads/Gearbox.step")).unwrap(), b"kept", "received files stay");

    // The page reconnects: the new ID at once, no friends, and Nearby running again without being asked.
    let mut again = Client::join(&server, helper.clone(), &["drop.files"]);
    let profile = again.subscribe("profile", json!({}));
    let after = again.snapshot(&profile, "the new ID", |d| d["id"]["friends_id"].is_string())["data"]["id"]
        ["friends_id"]
        .clone();
    assert_ne!(after, before);
    let list = again.subscribe("list", json!({}));
    let shown = again.snapshot(&list, "the list", |d| d.is_object());
    assert!(!texts(&shown["data"]).contains("Bo"), "Bo went with the old identity");
    until("Nearby again on the test network", || ports(&routes.0).iter().any(|port| !old_ports.contains(port)));
    drop(again);
    drop(ada);
    std::mem::forget(server);
}
