//! remove_friend takes anyone off the list (PROTOCOL.md remove_friend): a friend, a request either way, a former
//! friend, a link contact and a blocked person, who stays blocked. Their history stays unless the intent asks for it
//! to go, and You is never removed.

mod clients;
mod support;

use clients::{texts, Client, Temp};
use serde_json::{json, Value};
use szfriends_core::store::{sync_history, Direction, Item, ItemKind, Person, Relation, Store};
use szfriends_helper::service::{seed, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: one service starts at a time.
static START: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn add(store: &mut Store, name: &str, relation: Relation, key: u8) -> String {
    let mut person = Person::new(relation);
    person.request_found_nearby = relation == Relation::OutgoingRequest; // asked nearby, so it waits for an answer
    person.identity_key = Some([key; 32]);
    person.static_key = Some([key ^ 0xff; 32]);
    person.name = Some(name.into());
    store.save_person(&person).unwrap();
    person.conversation_id
}

fn titles(list: &Value) -> Vec<String> {
    // The You conversation, kept from when this computer had others, is no row here.
    let rows: Vec<Value> = list["rows"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|r| r["conversation_id"] != "you")
        .collect();
    let mut titles: Vec<String> = rows.iter().map(|r| r["title"].as_str().unwrap_or_default().to_owned()).collect();
    titles.sort();
    titles
}

#[test]
fn anyone_but_you_leaves_the_list_and_their_history_goes_only_when_asked() {
    let (a, b, routes) = (Temp::new("ra"), Temp::new("rb"), Temp::new("rroutes"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &routes.0);
    let (bo, _) = seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    let mut store = Store::open(&a.0).unwrap();
    let ines = add(&mut store, "Ines", Relation::IncomingRequest, 3);
    let otto = add(&mut store, "Otto", Relation::OutgoingRequest, 4);
    let rae = add(&mut store, "Rae", Relation::Removed, 5);
    let blake = add(&mut store, "Blake", Relation::Blocked, 6);
    let lin = add(&mut store, "Lin", Relation::Removed, 7);
    store.connection().execute("INSERT INTO link_contacts (conversation_id) VALUES (?1)", [&lin]).unwrap();
    sync_history::ensure_you_conversation(store.connection()).unwrap();
    for (conversation, id) in [(&bo, "m_bo"), (&rae, "m_rae")] {
        let item = Item {
            item_id: id.into(),
            conversation_id: conversation.clone(),
            kind: ItemKind::Message,
            direction: Direction::Incoming,
            text: Some(format!("hello from {id}")),
            transfer_id: None,
            sent_at: 1.0e9,
            received_at: 1.0e9,
            via_assistant: false,
        };
        store.insert_item(&item).unwrap();
    }
    drop(store);
    let mut ada = Client::connect_with(&a.0, &["drop.files", "list.menu"]);
    drop(guard);

    let list = ada.subscribe("list", json!({}));
    let shown = ada.snapshot(&list, "everyone listed", |d| titles(d).len() == 6);
    for row in shown["data"]["rows"].as_array().unwrap().iter().filter(|r| r["conversation_id"] != "you") {
        let menu = &row["menu"][0];
        assert_eq!((&menu["action"], &menu["style"]), (&json!("remove_friend"), &json!("destructive")), "{row}");
        let has_history = row["title"] == "Bo" || row["title"] == "Rae";
        assert_eq!(menu["confirm"]["option"].is_object(), has_history, "{row}");
    }
    let otto_row =
        shown["data"]["rows"].as_array().unwrap().iter().find(|r| r["conversation_id"] == otto.as_str()).unwrap();
    assert_eq!(otto_row["menu"][0]["label"], "Cancel request");

    assert_eq!(ada.refused("remove_friend", json!({"conversation_id": "you"})), "not_allowed");
    assert_eq!(ada.refused("remove_friend", json!({"conversation_id": "c_unknown"})), "not_found");
    assert_eq!(ada.refused("remove_friend", json!({"conversation_id": bo, "delete_history": "yes"})), "invalid_field");

    for conversation in [&bo, &ines, &otto, &blake, &lin] {
        ada.send("remove_friend", json!({"conversation_id": conversation}));
    }
    ada.send("remove_friend", json!({"conversation_id": rae, "delete_history": true}));
    ada.send("remove_friend", json!({"conversation_id": rae})); // already off the list: nothing changes
    ada.snapshot(&list, "nobody listed", |d| titles(d).is_empty());
    // Still there to open: Bo's conversation keeps its history; Rae's went.
    let chat = ada.send("open_conversation", json!({"conversation_id": bo}))["subscription"].clone();
    ada.snapshot(chat.as_str().unwrap(), "Bo's chat kept", |d| texts(d).contains("hello from m_bo"));
    let chat = ada.send("open_conversation", json!({"conversation_id": rae}))["subscription"].clone();
    ada.snapshot(chat.as_str().unwrap(), "Rae's chat deleted", |d| !texts(d).contains("hello from m_rae"));
    drop(ada);

    let store = Store::open(&a.0).unwrap();
    let person = |id: &str| store.person_with_conversation(id).unwrap().unwrap();
    for (id, relation) in [
        (&bo, Relation::Removed),
        (&ines, Relation::IncomingRequest),
        (&otto, Relation::OutgoingRequest),
        (&rae, Relation::Removed),
        (&blake, Relation::Blocked),
        (&lin, Relation::Removed),
    ] {
        let person = person(id);
        let expected = if relation == Relation::Blocked { Relation::Blocked } else { Relation::Removed };
        assert_eq!(person.relation, expected, "{relation:?}");
        assert!(person.left_list_at.is_some(), "{relation:?} off the list");
    }
    let answers: Vec<String> = store
        .connection()
        .prepare("SELECT CAST(payload AS TEXT) FROM outbox WHERE kind = 3 AND conversation_id IN (?1, ?2)")
        .unwrap()
        .query_map([&ines, &otto], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert!(
        answers.iter().any(|a| a.contains("decline")) && answers.iter().any(|a| a.contains("cancel")),
        "{answers:?}"
    );
}
