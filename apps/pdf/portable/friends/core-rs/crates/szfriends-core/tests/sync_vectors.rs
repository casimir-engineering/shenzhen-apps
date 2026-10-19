//! Sync against the Objective-C helper (fixtures/vectors/objc-sync.json): the same store state captured by the Rust
//! engine signs the same events, byte for byte, in the same order, and opens with the same HELLO; the codecs agree.

use std::sync::Arc;

use szfriends_core::identity::chain::DeviceChain;
use szfriends_core::identity::Identity;
use szfriends_core::store::sync_log;
use szfriends_core::store::sync_records::{self, Picture, SyncItem, SyncPerson};
use szfriends_core::store::{devices, Store};
use szfriends_core::sync::{
    adopt_own_devices_secret, decode_vector, encode_vector, Event, Fields, SyncEngine, SyncExchange,
};
use szfriends_vectors::{cases, field, load, text};

fn identity(name: &str) -> Identity {
    let label = |l: String| szfriends_core::crypto::blake2b::<32>(None, &[l.as_bytes()]);
    let mut private = label(format!("{name} static"));
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&label(format!("{name} seed")), &private)
}

#[test]
fn codecs_match_the_helper() {
    let vectors = load("objc-sync.json");
    let codec = &vectors["codec"];
    let mut vector = sync_log::Vector::new();
    vector.insert(identity("bob").public_key(), 7);
    vector.insert(identity("alice").public_key(), 3);
    vector.insert(identity("carol").public_key(), 0);
    assert_eq!(hex::encode(encode_vector(&vector)), text(codec, "vector"));
    let (decoded, used) = decode_vector(&field(codec, "vector")).unwrap();
    assert_eq!(used, field(codec, "vector").len());
    assert_eq!(decoded.len(), 2);
    for case in cases(codec, "refused_vectors") {
        assert_eq!(decode_vector(&field(case, "data")).is_some(), case["decodes"].as_u64() == Some(1));
    }
    let mut fields = Fields::new();
    fields.set_string(1, Some("conversation"));
    fields.set_u64(2, 42);
    fields.set_date(9, Some(1760000000.125 + 0.333));
    fields.set_data(4, Some(&[]));
    assert_eq!(hex::encode(fields.encode()), text(codec, "fields"));
    let own = szfriends_core::crypto::blake2b::<32>(None, &[b"own devices secret"]);
    let presence = szfriends_core::crypto::blake2b::<32>(None, &[b"presence secret"]);
    let bob = identity("bob").public_key();
    let tag = szfriends_core::sync::device_tag_secret(&own, &bob).unwrap();
    assert_eq!(hex::encode(tag), text(codec, "device_tag_secret"));
    let tag = szfriends_core::sync::friend_device_tag_secret(&presence, &bob).unwrap();
    assert_eq!(hex::encode(tag), text(codec, "friend_device_tag_secret"));
}

#[test]
fn the_same_store_captures_into_the_same_events() {
    let vectors = load("objc-sync.json");
    let v = &vectors["capture"];
    let t0 = v["t0"].as_f64().unwrap();
    let mut bytes = [0u8; 8];
    szfriends_core::crypto::random_bytes(&mut bytes);
    let home = std::env::temp_dir().join(format!("szf-sync-vectors-{}", hex::encode(bytes)));
    let store = Store::open(&home).unwrap();
    let alice = Arc::new(identity("alice"));
    let carol = identity("carol");
    let conn = store.connection();
    let chain = DeviceChain::decode(&field(v, "chain"), None).unwrap();
    devices::adopt_own_chain(conn, &chain, &alice.public_key()).unwrap();
    assert!(adopt_own_devices_secret(&store, &field(v, "own_devices_secret")));
    sync_records::set_own_presence_secret(conn, Some(&field(v, "presence_secret"))).unwrap();
    sync_records::set_profile(conn, Some("Alice"), &Picture::animal(1, 7)).unwrap();
    let mut person = SyncPerson::new("carolconv".into(), t0 + 2.0);
    person.identity_key = Some(carol.public_key().to_vec());
    person.static_key = Some(carol.static_public_key().to_vec());
    person.name = Some("Carol".into());
    person.friends_id = Some("maple-otter".into());
    person.picture = Picture::animal(2, 3);
    person.relation = 2;
    person.verified = true;
    person.verified_at = Some(t0 + 1.0);
    person.comparison_code = Some("1234 5678".into());
    person.presence_secret = Some(field(v, "carol_presence"));
    sync_records::sync_save_person(conn, &mut person).unwrap();
    let item = |id: &str, kind: i64, sent: f64, received: f64| SyncItem {
        item_id: id.into(),
        conversation_id: "carolconv".into(),
        kind,
        direction: 0,
        sent_at: t0 + sent,
        received_at: t0 + received,
        text: None,
        transfer_id: None,
        event_kind: None,
        event_arguments: Vec::new(),
        via_assistant: false,
        cancelled: false,
    };
    let message = SyncItem { text: Some("hi / there".into()), ..item("m1", 0, 2.5, 3.0) };
    assert!(sync_records::sync_insert_item(conn, &message).unwrap());
    let event = SyncItem {
        event_kind: Some("friend_added".into()),
        event_arguments: vec![("b".into(), "x\ny\u{e9}".into()), ("name".into(), "Carol/C".into())],
        ..item("e1", 2, 4.0, 4.0)
    };
    assert!(sync_records::sync_insert_item(conn, &event).unwrap());
    conn.execute("UPDATE friends SET unread_count = 0 WHERE conversation_id = 'carolconv'", []).unwrap();
    let mut engine = SyncEngine::new(alice.clone(), home.join("received"));
    engine.clock = Box::new(move || t0 + 100.0);
    let captured = engine.capture_local_changes(&store);
    let logged = sync_log::events_missing_from(store.connection(), &sync_log::Vector::new(), 1000).unwrap();
    let expected = cases(v, "events");
    for (i, (log, want)) in logged.iter().zip(expected).enumerate() {
        let event = Event::from_log(log).unwrap();
        assert_eq!(hex::encode(&log.header), text(want, "header"), "event {i}: {:?} {}", event.kind, event.subject);
        assert_eq!(log.body.as_ref().map(hex::encode).as_deref(), want["body"].as_str(), "event {i} body");
    }
    assert_eq!(logged.len(), expected.len());
    assert_eq!(captured as u64, v["captured"].as_u64().unwrap());
    let mut exchange = SyncExchange::new(identity("bob").public_key());
    exchange.start(&engine, &store);
    assert_eq!(hex::encode(&exchange.take_messages()[0]), text(v, "hello"));
    drop(store);
    let _ = std::fs::remove_dir_all(&home);
}
