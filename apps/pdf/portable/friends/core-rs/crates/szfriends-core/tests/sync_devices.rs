//! Two Rust devices of one person in memory: a chain holding both, history and a friend synced each way, a deletion
//! reaching the other device, and a removal: the removed device's later events refused, and it learns it was removed.

use std::path::PathBuf;
use std::sync::Arc;

use szfriends_core::identity::chain::{device_consent, DeviceChain};
use szfriends_core::identity::Identity;
use szfriends_core::store::devices;
use szfriends_core::store::{Direction, Item, ItemKind, Person, Relation, Store};
use szfriends_core::sync::{SyncEngine, SyncExchange};

fn identity(name: &str) -> Identity {
    let label = |l: String| szfriends_core::crypto::blake2b::<32>(None, &[l.as_bytes()]);
    let mut private = label(format!("{name} static"));
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&label(format!("{name} seed")), &private)
}

/// A device's temporary home, removed once everything in it is closed: the last field, so dropped last (Windows does
/// not remove a directory whose store is open).
struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Device {
    store: Store,
    engine: SyncEngine,
    identity: Arc<Identity>,
    _home: Home,
}

impl Device {
    fn new(name: &str) -> Self {
        let mut bytes = [0u8; 8];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let home = std::env::temp_dir().join(format!("szf-sync-{name}-{}", hex::encode(bytes)));
        let store = Store::open(&home).unwrap();
        let identity = Arc::new(identity(name));
        let engine = SyncEngine::new(identity.clone(), home.join("received"));
        Self { store, engine, identity, _home: Home(home) }
    }

    fn message(&mut self, conversation: &str, id: &str, text: &str, at: f64) -> bool {
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

    fn texts(&self, conversation: &str) -> Vec<String> {
        let mut statement = self
            .store
            .connection()
            .prepare("SELECT body FROM messages WHERE conversation_id = ?1 ORDER BY received_at, item_id")
            .unwrap();
        statement.query_map([conversation], |r| r.get(0)).unwrap().map(Result::unwrap).collect()
    }
}

/// Runs an exchange between the two devices until neither has anything more to say.
fn sync(a: &mut Device, b: &mut Device) -> Result<(), String> {
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

fn joined_pair() -> (Device, Device) {
    let a = Device::new("alice");
    let b = Device::new("bob");
    let chain = devices::own_chain_creating_genesis(a.store.connection(), &a.identity, "Alice's Mac", "macOS").unwrap();
    let consent = device_consent(&b.identity, chain.root_key());
    let (key, static_key) = (b.identity.public_key(), b.identity.static_public_key());
    let added = chain.adding(&key, &static_key, &consent, "Bob's PC", "Windows 11", &a.identity, 1.0e9).unwrap();
    devices::merge_own_chain(a.store.connection(), &added).unwrap();
    let received = DeviceChain::decode(added.encoded(), None).unwrap();
    devices::adopt_own_chain(b.store.connection(), &received, &key).unwrap();
    (a, b)
}

#[test]
fn history_and_friends_reach_the_other_device_both_ways() {
    let (mut a, mut b) = joined_pair();
    let mut carol = Person::new(Relation::Friend);
    carol.identity_key = Some(identity("carol").public_key());
    carol.static_key = Some(identity("carol").static_public_key());
    carol.name = Some("Carol".into());
    a.store.save_person(&carol).unwrap();
    a.message(&carol.conversation_id, "m1", "hello from carol", 1.0e9 + 1.0);
    sync(&mut a, &mut b).unwrap();
    let on_b = b.store.person_with_identity_key(&identity("carol").public_key()).unwrap().expect("carol on bob");
    assert_eq!(on_b.name.as_deref(), Some("Carol"));
    assert_eq!(b.texts(&on_b.conversation_id), ["hello from carol"]);
    b.message(&on_b.conversation_id, "m2", "second", 1.0e9 + 2.0);
    sync(&mut a, &mut b).unwrap();
    assert_eq!(a.texts(&carol.conversation_id), ["hello from carol", "second"]);
    // Erase on one, gone on both.
    a.engine.delete_history(&a.store, Some(&carol.conversation_id)).unwrap();
    assert!(a.texts(&carol.conversation_id).is_empty());
    sync(&mut a, &mut b).unwrap();
    assert!(b.texts(&on_b.conversation_id).is_empty());
    // A late copy stays erased.
    assert!(!b.message(&on_b.conversation_id, "m1", "hello again", 1.0e9 + 3.0));
    assert!(b.texts(&on_b.conversation_id).is_empty());
}

#[test]
fn a_removed_device_learns_it_and_its_later_events_count_for_nothing() {
    let (mut a, mut b) = joined_pair();
    let mut carol = Person::new(Relation::Friend);
    carol.identity_key = Some(identity("carol").public_key());
    a.store.save_person(&carol).unwrap();
    sync(&mut a, &mut b).unwrap();
    let chain = devices::own_chain(a.store.connection()).unwrap().unwrap();
    let revoked = chain.revoking(&b.identity.public_key(), &a.identity, 1.0e9 + 5.0).unwrap();
    devices::merge_own_chain(a.store.connection(), &revoked).unwrap();
    a.engine.record_revocation(&a.store, &b.identity.public_key()).unwrap();
    // Bob writes after its removal, before it heard of it.
    let on_b = b.store.person_with_identity_key(&identity("carol").public_key()).unwrap().unwrap();
    b.message(&on_b.conversation_id, "late", "written after removal", 1.0e9 + 6.0);
    let result = sync(&mut a, &mut b);
    assert!(a.texts(&carol.conversation_id).is_empty(), "nothing bob wrote after its removal: {result:?}");
    let own = devices::own_chain(b.store.connection()).unwrap().unwrap();
    assert!(own.revokes(&b.identity.public_key()), "bob holds the chain that removed it");
    assert!(b.engine.root_key(&b.store).is_none());
}

#[test]
fn taking_someone_off_the_list_reaches_the_other_device_and_a_new_request_brings_them_back() {
    let (mut a, mut b) = joined_pair();
    let mut carol = Person::new(Relation::Friend);
    carol.identity_key = Some(identity("carol").public_key());
    a.store.save_person(&carol).unwrap();
    sync(&mut a, &mut b).unwrap();
    // Removed and taken off the list on Alice's Mac.
    carol.relation = Relation::Removed;
    carol.left_list_at = Some(1.0e9 + 10.0);
    a.store.save_person(&carol).unwrap();
    sync(&mut a, &mut b).unwrap();
    let on_b = b.store.person_with_identity_key(&identity("carol").public_key()).unwrap().unwrap();
    assert_eq!((on_b.relation, on_b.left_list_at), (Relation::Removed, Some(1.0e9 + 10.0)));
    // Carol asks again, and Bob's PC hears it first: back on the list on both.
    let mut asking = on_b.clone();
    asking.relation = Relation::IncomingRequest;
    asking.request_at = Some(1.0e9 + 20.0);
    b.store.save_person(&asking).unwrap();
    assert_eq!(b.store.person_with_conversation(&on_b.conversation_id).unwrap().unwrap().left_list_at, None);
    sync(&mut a, &mut b).unwrap();
    let on_a = a.store.person_with_conversation(&carol.conversation_id).unwrap().unwrap();
    assert_eq!((on_a.relation, on_a.left_list_at), (Relation::IncomingRequest, None));
}
