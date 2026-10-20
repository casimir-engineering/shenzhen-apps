//! Rust devices of one person in memory for the sync suites: each with its own store and engine in a temporary home,
//! joined in one chain, and an exchange run between two of them until both are quiet.

#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::Arc;

use szfriends_core::identity::chain::{device_consent, DeviceChain};
use szfriends_core::identity::Identity;
use szfriends_core::store::devices;
use szfriends_core::store::{Direction, Item, ItemKind, Store};
use szfriends_core::sync::{SyncEngine, SyncExchange};

pub fn identity(name: &str) -> Identity {
    let label = |l: String| szfriends_core::crypto::blake2b::<32>(None, &[l.as_bytes()]);
    let mut private = label(format!("{name} static"));
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&label(format!("{name} seed")), &private)
}

/// A device's temporary home, removed once everything in it is closed: the last field, so dropped last (Windows does
/// not remove a directory whose store is open).
pub struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub struct Device {
    pub store: Store,
    pub engine: SyncEngine,
    pub identity: Arc<Identity>,
    pub home: PathBuf,
    _home: Home,
}

impl Device {
    pub fn new(name: &str) -> Self {
        let mut bytes = [0u8; 8];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let home = std::env::temp_dir().join(format!("szf-sync-{name}-{}", hex::encode(bytes)));
        let store = Store::open(&home).unwrap();
        let identity = Arc::new(identity(name));
        let engine = SyncEngine::new(identity.clone(), home.join("received"));
        Self { store, engine, identity, home: home.clone(), _home: Home(home) }
    }

    pub fn message(&mut self, conversation: &str, id: &str, text: &str, at: f64) -> bool {
        let item = Item {
            item_id: id.into(),
            conversation_id: conversation.into(),
            kind: ItemKind::Message,
            direction: Direction::Incoming,
            text: Some(text.into()),
            transfer_id: None,
            sent_at: at,
            received_at: at,
            via_assistant: false,
        };
        self.store.insert_item(&item).unwrap()
    }

    pub fn texts(&self, conversation: &str) -> Vec<String> {
        let mut statement = self
            .store
            .connection()
            .prepare("SELECT body FROM messages WHERE conversation_id = ?1 ORDER BY received_at, item_id")
            .unwrap();
        statement.query_map([conversation], |r| r.get(0)).unwrap().map(Result::unwrap).collect()
    }
}

/// Runs an exchange between the two devices until neither has anything more to say.
pub fn sync(a: &mut Device, b: &mut Device) -> Result<(), String> {
    let mut ab = SyncExchange::new(b.identity.public_key());
    let mut ba = SyncExchange::new(a.identity.public_key());
    a.engine.capture_local_changes(&a.store);
    b.engine.capture_local_changes(&b.store);
    ab.start(&a.engine, &a.store);
    ba.start(&b.engine, &b.store);
    for _ in 0..100 {
        let (to_b, to_a) = (ab.take_messages(), ba.take_messages());
        if to_b.is_empty() && to_a.is_empty() {
            return Ok(());
        }
        for message in to_b {
            ba.receive(&mut b.engine, &b.store, &message).map_err(|e| format!("b: {e}"))?;
        }
        for message in to_a {
            ab.receive(&mut a.engine, &a.store, &message).map_err(|e| format!("a: {e}"))?;
        }
    }
    Err("no quiet".into())
}

pub fn joined_pair() -> (Device, Device) {
    let mut devices = joined(&["alice", "bob"]);
    let b = devices.pop().unwrap();
    (devices.pop().unwrap(), b)
}

/// Devices of one person: the first makes the chain and adds the others, which adopt the whole chain.
pub fn joined(names: &[&str]) -> Vec<Device> {
    let all: Vec<Device> = names.iter().map(|n| Device::new(n)).collect();
    let first = &all[0];
    let mut chain =
        devices::own_chain_creating_genesis(first.store.connection(), &first.identity, "Alice's Mac", "macOS").unwrap();
    for (n, other) in all.iter().enumerate().skip(1) {
        let consent = device_consent(&other.identity, chain.root_key());
        let (key, static_key) = (other.identity.public_key(), other.identity.static_public_key());
        let name = format!("Computer {n}");
        chain = chain.adding(&key, &static_key, &consent, &name, "Windows 11", &first.identity, 1.0e9).unwrap();
        devices::merge_own_chain(first.store.connection(), &chain).unwrap();
    }
    for other in &all[1..] {
        let received = DeviceChain::decode(chain.encoded(), None).unwrap();
        devices::adopt_own_chain(other.store.connection(), &received, &other.identity.public_key()).unwrap();
    }
    all
}
