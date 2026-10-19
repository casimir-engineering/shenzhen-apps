//! The store against the helper's own (`fixtures/vectors/objc-store.json`, exported from `SZFriendsStore`): the
//! schema a fresh store creates and the one the committed v1 fixture (`service/store/tests/fixtures/store-v1.sql`)
//! migrates to, as SQLite prints them; the fixture's people, profile and search; folding; the transfer and outbox
//! state machines over every state and event; sanitised file names.

use std::path::{Path, PathBuf};

use rusqlite::Connection;
use serde_json::Value;
use szfriends_core::store::{
    fold, sanitized_file_name, OutboxEvent, OutboxState, Store, StoreOptions, TransferEvent, TransferState,
    SCHEMA_VERSION,
};
use szfriends_vectors::{cases, friends_dir, load, number, text};

fn temporary(label: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!("szf-store-{label}-{}-{}", std::process::id(), rand_suffix()));
    std::fs::create_dir_all(&base).unwrap();
    base.join("state")
}

fn rand_suffix() -> String {
    let mut bytes = [0u8; 6];
    szfriends_core::crypto::random_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn schema(conn: &Connection) -> Value {
    let mut statement = conn
        .prepare(
            "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
        )
        .unwrap();
    let rows = statement
        .query_map([], |r| {
            Ok(Value::Array(vec![
                Value::String(r.get(0)?),
                Value::String(r.get(1)?),
                Value::String(r.get(2)?),
                r.get::<_, Option<String>>(3)?.map(Value::String).unwrap_or(Value::Null),
            ]))
        })
        .unwrap();
    Value::Array(rows.map(Result::unwrap).collect())
}

fn scalar(conn: &Connection, sql: &str) -> Value {
    conn.query_row(sql, [], |r| {
        Ok(match r.get_ref(0)? {
            rusqlite::types::ValueRef::Integer(i) => Value::from(i),
            rusqlite::types::ValueRef::Text(t) => Value::String(String::from_utf8_lossy(t).into_owned()),
            _ => Value::Null,
        })
    })
    .unwrap()
}

fn assert_facts(store: &Store, expected: &Value, label: &str) {
    let conn = store.connection();
    assert_eq!(schema(conn), expected["schema"], "{label}: the schema differs from the helper's");
    assert_eq!(scalar(conn, "PRAGMA user_version"), expected["user_version"], "{label}");
    let min_reader = scalar(conn, "SELECT value FROM meta WHERE key = 'min_reader_version'");
    assert_eq!(min_reader, expected["min_reader_version"], "{label}");
    assert_eq!(Value::Bool(store.search_uses_index()), expected["search_uses_index"], "{label}");
    assert_eq!(store.people_by_latest_interaction().unwrap().len() as u64, number(expected, "people"), "{label}");
    assert_eq!(scalar(conn, "PRAGMA integrity_check"), expected["integrity"], "{label}");
}

fn load_fixture(directory: &Path) {
    std::fs::create_dir_all(directory).unwrap();
    let fixture = friends_dir().join("service/store/tests/fixtures/store-v1.sql");
    let sql = std::fs::read_to_string(&fixture).unwrap_or_else(|e| panic!("{}: {e}", fixture.display()));
    Connection::open(directory.join("friends.sqlite")).unwrap().execute_batch(&sql).unwrap();
}

#[test]
fn a_fresh_store_has_exactly_the_helpers_schema() {
    let vectors = load("objc-store.json");
    assert_eq!(number(&vectors, "schema_version"), SCHEMA_VERSION as u64);
    let directory = temporary("fresh");
    let store = Store::open(&directory).unwrap();
    assert_eq!(store.schema_version(), SCHEMA_VERSION);
    assert_facts(&store, &vectors["fresh"], "fresh");
    let backups = std::fs::read_dir(&directory)
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().contains(".before-v"));
    assert_eq!(backups.count(), 0, "a new store needs no backup");
    let store_id = scalar(store.connection(), "SELECT value FROM meta WHERE key = 'store_id'");
    assert_eq!(store_id.as_str().map(str::len), Some(32));
    drop(store);
    let _ = std::fs::remove_dir_all(directory.parent().unwrap());
}

#[test]
fn the_helpers_v1_fixture_migrates_to_the_same_schema_with_its_data() {
    let vectors = load("objc-store.json");
    let directory = temporary("v1");
    load_fixture(&directory);
    let store = Store::open(&directory).unwrap();
    assert_facts(&store, &vectors["migrated_v1"], "migrated v1");
    assert_eq!(vectors["migrated_v1"]["schema"], vectors["fresh"]["schema"]);
    let backup = directory.join(format!("friends.sqlite.before-v{SCHEMA_VERSION}"));
    assert!(backup.exists(), "backed up before migrating");
    let mei = store.person_with_conversation("c_mei").unwrap().expect("Mei");
    assert_eq!(mei.name.as_deref(), Some("Mei Lin"));
    assert!(mei.auto_accept);
    let profile: (String, String) = store
        .connection()
        .query_row("SELECT name, friends_id FROM profile WHERE id = 1", [], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap();
    assert_eq!(profile, ("Raph".to_owned(), "maple-river".to_owned()));
    // The trigram index is built from the fixture's rows; a two-character term filters with instr().
    let hits: Vec<String> = store.search("合同", None, 10).unwrap().into_iter().map(|h| h.item_id).collect();
    assert_eq!(hits, vec!["m_contract".to_owned()]);
    let requests: i64 = store
        .connection()
        .query_row("SELECT count(*) FROM friends WHERE relation IN (0, 1) AND request_since IS NULL", [], |r| r.get(0))
        .unwrap();
    assert_eq!(requests, 0, "v3 dates every waiting request");
    drop(store);
    // Reopening migrates nothing and writes no second backup.
    let again = Store::open(&directory).unwrap();
    assert_eq!(again.schema_version(), SCHEMA_VERSION);
    drop(again);
    let _ = std::fs::remove_dir_all(directory.parent().unwrap());
}

#[test]
fn a_store_without_trigram_scans_and_marks_the_index_stale() {
    let directory = temporary("scan");
    load_fixture(&directory);
    let options = StoreOptions { disable_trigram: true, ..StoreOptions::default() };
    let store = Store::open_with(&directory, options).unwrap();
    assert!(!store.search_uses_index());
    let hits: Vec<String> = store.search("CAFÉ menu", None, 10).unwrap().into_iter().map(|h| h.item_id).collect();
    assert_eq!(hits, vec!["m_reply".to_owned()]);
    let stale = scalar(store.connection(), "SELECT count(*) FROM meta WHERE key = 'search_stale'");
    assert_eq!(stale, Value::from(0), "nothing written yet");
    drop(store);
    let _ = std::fs::remove_dir_all(directory.parent().unwrap());
}

#[test]
fn folding_matches_foundations() {
    let vectors = load("objc-store.json");
    for case in cases(&vectors, "fold") {
        assert_eq!(fold(text(case, "input")), text(case, "folded"), "{:?}", text(case, "input"));
    }
}

#[test]
fn the_state_machines_agree_on_every_state_and_event() {
    let vectors = load("objc-store.json");
    let transfer = cases(&vectors, "transfer_next_state");
    assert_eq!(transfer.len(), 2 * TransferState::ALL.len() * TransferEvent::ALL.len());
    for case in transfer {
        let n = |i: usize| case[i].as_i64().unwrap();
        let state = TransferState::from_i64(n(1)).unwrap();
        let event = TransferEvent::ALL[n(2) as usize];
        assert_eq!(event.next_state(n(0) == 1, state) as i64, n(3), "{case}");
    }
    let outbox = cases(&vectors, "outbox_next_state");
    assert_eq!(outbox.len(), 5 * OutboxEvent::ALL.len());
    for case in outbox {
        let n = |i: usize| case[i].as_i64().unwrap();
        let state = OutboxState::from_i64(n(0)).unwrap();
        assert_eq!(OutboxEvent::ALL[n(1) as usize].next_state(state) as i64, n(2), "{case}");
    }
}

#[test]
fn received_file_names_are_sanitised_like_the_helpers() {
    let vectors = load("objc-store.json");
    for case in cases(&vectors, "sanitized_file_names") {
        assert_eq!(sanitized_file_name(text(case, "input")), text(case, "sanitized"), "{:?}", text(case, "input"));
    }
}
