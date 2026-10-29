//! Shared by the presentation suites: the golden fixtures, a strict JSON comparison, PROTOCOL.md's schemas, the animal
//! set from the repository, and the World behind the fixtures (`world.rs`).

#![allow(dead_code)]

pub mod items;
pub mod schema;
pub mod world;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::Value;
use szfriends_core::presentation::{AnimalSet, PersonFacts};
use szfriends_core::store::{Person, Store};

pub fn friends_dir() -> PathBuf {
    szfriends_vectors::friends_dir()
}

/// The files outside `fixtures/` these suites read: PROTOCOL.md's schemas, the animal set, and the helper's catalog and
/// store headers they are compared with.
const TREE: [&str; 5] = [
    "PROTOCOL.md",
    "avatars/animals/manifest.json",
    "service/presentation/SZFriendsCatalog.m",
    "service/store/SZFriendsOutbox.h",
    "service/store/SZFriendsTransfers.h",
];

/// True, after saying so, where the tree is a copy without those files (the VM and Android runs ship `fixtures/` and
/// the helper files the earlier suites read): the presentation is pure Rust with no platform code, and runs in full
/// wherever the repository is.
pub fn tree_missing() -> bool {
    let missing: Vec<&str> = TREE.iter().copied().filter(|path| !friends_dir().join(path).exists()).collect();
    if !missing.is_empty() {
        eprintln!("skipped: {} not in this copy of portable/friends", missing.join(", "));
    }
    !missing.is_empty()
}

fn read(relative: &str) -> String {
    let path = friends_dir().join(relative);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// The real animal set from the repository: an animal avatar's color is its manifest color, so the fixtures must
/// agree with the manifest, not with a copy of it.
pub fn animal_set() -> AnimalSet {
    static SET: OnceLock<AnimalSet> = OnceLock::new();
    SET.get_or_init(|| AnimalSet::from_manifest(&read("avatars/animals/manifest.json")).expect("the animal set"))
        .clone()
}

/// fixtures/<relative> as JSON.
pub fn fixture(relative: &str) -> Value {
    serde_json::from_str(&read(&format!("fixtures/{relative}"))).unwrap_or_else(|e| panic!("{relative}: {e}"))
}

/// Strict JSON comparison: objects by keys, booleans distinct from numbers, numbers by value. The first difference's
/// path and values, or None when equal.
pub fn difference(actual: &Value, expected: &Value, path: &str) -> Option<String> {
    match (actual, expected) {
        (Value::Object(a), Value::Object(e)) => {
            let mut keys: Vec<&String> = a.keys().chain(e.keys()).collect();
            keys.sort();
            keys.dedup();
            for key in keys {
                let child = format!("{path}.{key}");
                match (a.get(key), e.get(key)) {
                    (None, Some(e)) => return Some(format!("{child}: missing (expected {e})")),
                    (Some(a), None) => return Some(format!("{child}: unexpected {a}")),
                    (Some(a), Some(e)) => {
                        if let Some(d) = difference(a, e, &child) {
                            return Some(d);
                        }
                    }
                    (None, None) => {}
                }
            }
            None
        }
        (Value::Array(a), Value::Array(e)) => {
            for i in 0..a.len().max(e.len()) {
                let child = format!("{path}[{i}]");
                if i >= a.len() || i >= e.len() {
                    return Some(format!("{child}: array lengths {} vs {}", a.len(), e.len()));
                }
                if let Some(d) = difference(&a[i], &e[i], &child) {
                    return Some(d);
                }
            }
            None
        }
        (Value::Number(a), Value::Number(e)) if a.as_f64() == e.as_f64() => None,
        _ if actual == expected => None,
        _ => Some(format!("{path}:\n  built    {actual}\n  expected {expected}")),
    }
}

pub fn schemas() -> &'static schema::Schemas {
    static SCHEMAS: OnceLock<schema::Schemas> = OnceLock::new();
    SCHEMAS.get_or_init(|| {
        let schemas = schema::Schemas::parse(&read("PROTOCOL.md"));
        assert!(schemas.len() >= 10, "PROTOCOL.md schemas did not load");
        schemas
    })
}

/// Keys looked up but missing from the catalog, and placeholders left unfilled, so far in this run: a typo in a key
/// fails here instead of showing the key to someone. Keys under "test." are looked up on purpose.
pub fn expect_no_missing_keys(label: &str) {
    let missing: Vec<String> =
        szfriends_core::presentation::catalog::missing_keys().into_iter().filter(|k| !k.starts_with("test.")).collect();
    assert!(missing.is_empty(), "{label}: catalog keys looked up but missing: {}", missing.join(", "));
}

/// Validates a view's data against PROTOCOL.md's schema blocks, as the frame that carries it.
pub fn validate_snapshot(data: &Value, view: &str, label: &str) {
    let frame = serde_json::json!({"type": "snapshot", "subscription": "s_1", "view": view, "rev": 1, "data": data});
    let errors = schemas().validate(&frame, &["frame.snapshot", &format!("snapshot.{view}")], label);
    assert!(errors.is_empty(), "{label}:\n{}", errors.join("\n"));
    expect_no_missing_keys(label);
}

/// Validates a reply's result against PROTOCOL.md's schema blocks.
pub fn validate_result(result: &Value, intent: &str, label: &str) {
    let frame = serde_json::json!({"type": "reply", "re": "1", "ok": true, "result": result});
    let errors = schemas().validate(&frame, &["frame.reply", &format!("result.{intent}")], label);
    assert!(errors.is_empty(), "{label}:\n{}", errors.join("\n"));
    expect_no_missing_keys(label);
}

/// Compares a built view with fixtures/snapshots/<fixture> and validates it, as every fixture test does.
pub fn expect_fixture(built: &Value, fixture_name: &str, view: &str) {
    let expected = &fixture(&format!("snapshots/{fixture_name}"))["data"];
    if let Some(d) = difference(built, expected, "data") {
        panic!("{fixture_name} differs at {d}");
    }
    validate_snapshot(built, view, fixture_name);
}

/// A scratch state directory, removed afterwards.
pub struct Scratch(pub PathBuf);

impl Scratch {
    pub fn new(label: &str) -> Self {
        let mut bytes = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("szf-presentation-{label}-{}-{suffix}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The people as the helper reads them: what the store keeps of each written to a fresh store and read back, then the
/// facts the store does not hold (routes, pictures, verification, previews) added from the World, as the helper adds
/// them from discovery and sessions. Fails when the store gives back anything else than what went in.
pub fn through_store(people: &HashMap<String, PersonFacts>) -> HashMap<String, PersonFacts> {
    let scratch = Scratch::new("people");
    let mut store = Store::open(scratch.0.join("state")).expect("a store");
    for facts in people.values() {
        let mut person = Person::new(facts.relation);
        person.conversation_id = facts.conversation_id.clone();
        person.identity_key = facts.identity_key;
        person.friends_id = facts.friends_id.clone();
        person.name = facts.name.clone();
        person.auto_accept = facts.auto_accept;
        person.comparison_code = facts.comparison_code.clone();
        person.last_interaction_at = facts.last_interaction_at;
        person.unread_count = facts.unread_count;
        store.save_person(&person).expect("saved");
    }
    let mut read = HashMap::new();
    for stored in store.people_by_latest_interaction().expect("people") {
        let scripted = &people[&stored.conversation_id];
        let from_store = PersonFacts::from_store(&stored);
        assert_eq!(
            (&from_store.name, &from_store.friends_id, from_store.identity_key, from_store.relation),
            (&scripted.name, &scripted.friends_id, scripted.identity_key, scripted.relation)
        );
        assert_eq!(
            (
                from_store.auto_accept,
                &from_store.comparison_code,
                from_store.last_interaction_at,
                from_store.unread_count
            ),
            (scripted.auto_accept, &scripted.comparison_code, scripted.last_interaction_at, scripted.unread_count)
        );
        let merged = PersonFacts {
            picture: scripted.picture.clone(),
            route_kind: scripted.route_kind,
            route_method: scripted.route_method,
            online_reach: scripted.online_reach,
            verified: scripted.verified,
            verified_at: scripted.verified_at,
            friends_id_confirmed: scripted.friends_id_confirmed,
            key_change_pending: scripted.key_change_pending,
            offers_waiting: scripted.offers_waiting,
            last_preview_item_id: scripted.last_preview_item_id.clone(),
            last_message_item_id: scripted.last_message_item_id.clone(),
            last_message_files: scripted.last_message_files,
            request_at: scripted.request_at,
            request_found_nearby: scripted.request_found_nearby,
            unconfirmed_answer_id: scripted.unconfirmed_answer_id.clone(),
            received_file_count: scripted.received_file_count,
            received_reveal_path: scripted.received_reveal_path.clone(),
            link_contact: scripted.link_contact,
            ..from_store
        };
        read.insert(merged.conversation_id.clone(), merged);
    }
    assert_eq!(read.len(), people.len());
    read
}
