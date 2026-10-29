//! One person's computers end to end between Rust helpers' services in test homes, on a test network of entries on
//! loopback (ADR 0013, ADR 0014): a new computer asks to join by the profile's Friends ID over nearby, the person
//! approves on the computer that has the profile and types the code it shows (a wrong one first); the new computer
//! then holds the profile, both list both computers, and what changes on one (the name, a computer's name, a
//! friend and their messages, a deleted chat, a removal) reaches the other over the session between them.

mod clients;
mod support;

use std::sync::Mutex;

use clients::{join_profile, texts, Client, Temp};
use serde_json::{json, Value};
use szfriends_helper::service::ENV_TEST_LOOPBACK;
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: helpers start one group at a time.
static START: Mutex<()> = Mutex::new(());

fn start(homes: &[&Temp], network: &Temp) -> Vec<Client> {
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &homes[0].0);
    std::env::set_var(ENV_TEST_LOOPBACK, &network.0);
    // Own-device copies between Rust helpers go by blocks (ADR 0018 § 4).
    std::env::set_var(szfriends_helper::service::ENV_TEST_COPIES_BY_BLOCKS, "1");
    homes.iter().map(|home| Client::connect(&home.0)).collect()
}

fn friends_id(client: &mut Client) -> String {
    let profile = client.subscribe("profile", json!({}));
    let data = client.snapshot(&profile, "the profile", |d| d["id"]["friends_id"].is_string());
    data["data"]["id"]["friends_id"].as_str().unwrap().to_owned()
}

fn you_rows(data: &Value) -> Vec<Value> {
    let rows = data["rows"].as_array().cloned().unwrap_or_default();
    rows.into_iter().filter(|r| r["conversation_id"] == "you").collect()
}

fn row_titled<'a>(data: &'a Value, title: &str) -> Option<&'a Value> {
    data["rows"].as_array()?.iter().find(|r| r["title"] == title)
}

#[test]
fn a_new_computer_joins_nearby_and_syncs() {
    let (a, b, network) = (Temp::new("da"), Temp::new("db"), Temp::new("dnet"));
    let mut clients = start(&[&a, &b], &network);
    let (mut bo, mut ada) = (clients.pop().unwrap(), clients.pop().unwrap());
    assert!(ada.welcome["capabilities"].to_string().contains("\"devices\""), "{}", ada.welcome);
    ada.send("set_name", json!({"name": "Ada"}));
    for client in [&mut ada, &mut bo] {
        client.send("activate", json!({}));
    }
    let ada_id = friends_id(&mut ada);
    join_profile(&mut ada, &ada_id, &mut bo);

    // The new computer holds the profile: its name and Friends ID.
    let profile_b = bo.subscribe("profile", json!({}));
    bo.snapshot(&profile_b, "Ada's profile on the new computer", |d| {
        d["id"]["friends_id"] == ada_id.as_str() && texts(d).contains("Ada")
    });
    // Once the You conversation exists (as its first message makes it), it shows once on each, as the You row.
    for home in [&a, &b] {
        let store = rusqlite::Connection::open(home.0.join(szfriends_core::store::DATABASE_NAME)).unwrap();
        szfriends_core::store::sync_history::ensure_you_conversation(&store).unwrap();
    }
    for client in [&mut ada, &mut bo] {
        let list = client.subscribe("list", json!({}));
        let shown = client.snapshot(&list, "the You row", |d| you_rows(d).len() == 1);
        assert_eq!(you_rows(&shown["data"])[0]["kind"], "you");
    }
    // Both list both computers; a name given on one reaches the other.
    bo.send("rename_device", json!({"name": "Workshop PC"}));
    let profile_a = ada.subscribe("profile", json!({}));
    ada.snapshot(&profile_a, "the new computer in Your computers", |d| texts(d).contains("Workshop PC"));
    // The profile's name changed on one computer reaches the other through sync.
    ada.send("set_name", json!({"name": "Ada Lovelace"}));
    bo.snapshot(&profile_b, "the new name on the new computer", |d| texts(d).contains("Ada Lovelace"));
}

#[test]
fn a_friend_and_their_messages_reach_the_other_computer() {
    let (a, b, c, network) = (Temp::new("fa"), Temp::new("fb"), Temp::new("fc"), Temp::new("fnet"));
    let mut clients = start(&[&a, &b, &c], &network);
    let (mut cy, mut bo, mut ada) = (clients.pop().unwrap(), clients.pop().unwrap(), clients.pop().unwrap());
    for (client, name) in [(&mut ada, Some("Ada")), (&mut bo, None), (&mut cy, Some("Cy"))] {
        if let Some(name) = name {
            client.send("set_name", json!({"name": name}));
        }
        client.send("activate", json!({}));
    }
    let ada_id = friends_id(&mut ada);
    join_profile(&mut ada, &ada_id, &mut bo);

    // Cy and Ada become friends nearby, on Ada's first computer.
    ada.send("start_visibility", json!({}));
    let nearby = cy.subscribe("nearby", json!({}));
    let seen = cy.snapshot(&nearby, "Ada visible to Cy", |d| {
        d["people"].as_array().is_some_and(|p| p.iter().any(|p| p["title"] == "Ada" && p["nearby_id"].is_string()))
    });
    let person = seen["data"]["people"].as_array().unwrap().iter().find(|p| p["title"] == "Ada").unwrap().clone();
    cy.send("send_request", json!({"nearby_id": person["nearby_id"]}));
    let list_a = ada.subscribe("list", json!({}));
    let asked = ada.snapshot(&list_a, "Cy's request at Ada", |d| row_titled(d, "Cy").is_some());
    let cy_in_a = row_titled(&asked["data"], "Cy").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    ada.send("accept_request", json!({"conversation_id": cy_in_a}));
    ada.send("stop_visibility", json!({}));

    let list_c = cy.subscribe("list", json!({}));
    let friends = cy.snapshot(&list_c, "Ada a friend at Cy", |d| {
        row_titled(d, "Ada").is_some_and(|r| r["waiting"].is_null() && r["subtitle"] != "Request sent")
    });
    let ada_in_c = row_titled(&friends["data"], "Ada").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    let token = "0123456789abcdef0123456789abcdef";
    cy.send("send_message", json!({"conversation_id": ada_in_c, "text": "Hello Ada", "client_token": token}));
    let chat_a = ada.send("open_conversation", json!({"conversation_id": cy_in_a}))["subscription"].clone();
    ada.snapshot(chat_a.as_str().unwrap(), "Cy's message at Ada", |d| texts(d).contains("Hello Ada"));

    // Ada's other computer holds Cy as a friend and the conversation, without ever meeting Cy.
    let list_b = bo.subscribe("list", json!({}));
    let synced = bo.snapshot(&list_b, "Cy on the other computer", |d| row_titled(d, "Cy").is_some());
    let cy_in_b = row_titled(&synced["data"], "Cy").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    let chat_b = bo.send("open_conversation", json!({"conversation_id": cy_in_b}))["subscription"].clone();
    bo.snapshot(chat_b.as_str().unwrap(), "Cy's message on the other computer", |d| texts(d).contains("Hello Ada"));

    // Delete chat history on one computer: gone on the other too, while Cy keeps theirs.
    ada.send("delete_history", json!({"conversation_id": cy_in_a}));
    bo.snapshot(chat_b.as_str().unwrap(), "the chat erased on the other computer", |d| !texts(d).contains("Hello Ada"));
    // What comes after the deletion stays; deleting every chat on the other computer reaches the first.
    let token = "fedcba9876543210fedcba9876543210";
    cy.send("send_message", json!({"conversation_id": ada_in_c, "text": "Still there?", "client_token": token}));
    ada.snapshot(chat_a.as_str().unwrap(), "Cy's new message at Ada", |d| texts(d).contains("Still there?"));
    bo.snapshot(chat_b.as_str().unwrap(), "and on the other computer", |d| texts(d).contains("Still there?"));
    bo.send("delete_history", json!({}));
    ada.snapshot(chat_a.as_str().unwrap(), "every chat erased", |d| !texts(d).contains("Still there?"));
    let chat_c = cy.send("open_conversation", json!({"conversation_id": ada_in_c}))["subscription"].clone();
    cy.snapshot(chat_c.as_str().unwrap(), "Cy keeps theirs", |d| texts(d).contains("Hello Ada"));

    // Removing Cy on one computer takes Cy off the other's list too.
    ada.send("remove_friend", json!({"conversation_id": cy_in_a}));
    ada.snapshot(&list_a, "Cy off the list", |d| row_titled(d, "Cy").is_none());
    bo.snapshot(&list_b, "Cy off the other computer's list", |d| row_titled(d, "Cy").is_none());
}

/// One computer whose store keeps a You conversation (from when it had others), with `note` in it when given.
fn single_computer_with_you(label: &str, note: Option<&str>) -> (Client, Temp, Temp) {
    let (home, network) = (Temp::new(label), Temp::new(&format!("{label}net")));
    drop(start(&[&home], &network)); // the home and its identity
    let mut store = szfriends_core::store::Store::open(&home.0).unwrap();
    szfriends_core::store::sync_history::ensure_you_conversation(store.connection()).unwrap();
    if let Some(note) = note {
        let item = szfriends_core::store::Item {
            item_id: "m_note".into(),
            conversation_id: "you".into(),
            kind: szfriends_core::store::ItemKind::Message,
            direction: szfriends_core::store::Direction::Outgoing,
            text: Some(note.into()),
            transfer_id: None,
            sent_at: 1.0e9,
            received_at: 1.0e9,
            via_assistant: false,
        };
        store.insert_item(&item).unwrap();
    }
    drop(store);
    let mut client = start(&[&home], &network).pop().unwrap();
    client.send("set_name", json!({"name": "Ada"}));
    (client, home, network)
}

#[test]
fn on_a_single_computer_an_empty_you_conversation_is_no_row() {
    let (mut ada, _home, _network) = single_computer_with_you("dy0", None);
    let list = ada.subscribe("list", json!({}));
    let shown = ada.snapshot(&list, "the list", |d| d["rows"].is_array());
    assert!(shown["data"]["rows"].as_array().unwrap().is_empty(), "{shown}");
    assert!(shown["data"]["empty"].is_object(), "nobody listed: {shown}");
    let badge = ada.subscribe("badge", json!({}));
    ada.snapshot(&badge, "nothing waits", |d| d["count"] == 0);
}

#[test]
fn on_a_single_computer_your_own_notes_stay_as_the_you_row() {
    let (mut ada, _home, _network) = single_computer_with_you("dy1", Some("Pages 3 to 5"));
    let list = ada.subscribe("list", json!({}));
    let shown = ada.snapshot(&list, "the You row", |d| you_rows(d).len() == 1);
    let rows = shown["data"]["rows"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "only the You row: {shown}");
    let you = &rows[0];
    assert_eq!((&you["kind"], &you["title"], &you["subtitle"]), (&json!("you"), &json!("You"), &json!("Pages 3 to 5")));
    assert_ne!(you["mentionable"], true, "nobody mentions themselves");
    let badge = ada.subscribe("badge", json!({}));
    ada.snapshot(&badge, "nothing waits", |d| d["count"] == 0);
    let chat = ada.send("open_conversation", json!({"conversation_id": "you"}))["subscription"].clone();
    ada.snapshot(chat.as_str().unwrap(), "the note", |d| texts(d).contains("Pages 3 to 5"));
}

/// A copy deleted on the new computer: Get is refused while there is no room for it there (disk_full, as the Mac's
/// helper answers), and copies it back from the first computer once there is.
#[test]
fn get_says_when_there_is_no_room() {
    let (a, b, network) = (Temp::new("ra"), Temp::new("rb"), Temp::new("rnet"));
    let mut clients = start(&[&a, &b], &network);
    let (mut bo, mut ada) = (clients.pop().unwrap(), clients.pop().unwrap());
    for client in [&mut ada, &mut bo] {
        client.send("activate", json!({}));
    }
    let ada_id = friends_id(&mut ada);
    join_profile(&mut ada, &ada_id, &mut bo);
    for home in [&a, &b] {
        let store = rusqlite::Connection::open(home.0.join(szfriends_core::store::DATABASE_NAME)).unwrap();
        szfriends_core::store::sync_history::ensure_you_conversation(&store).unwrap();
    }
    let source = a.0.join("Fixture.stl");
    std::fs::write(&source, vec![7u8; 50_000]).unwrap();
    let files = json!({"conversation_id": "you", "files": [{"path": source}],
                       "client_token": "0123456789abcdef0123456789abcdef"});
    let transfer = ada.send("send_files", files)["transfer_ids"][0].as_str().unwrap().to_owned();
    let path_of = |data: &Value| -> Option<String> {
        let item = data["items"].as_array()?.iter().find(|i| i["transfer_id"] == transfer.as_str())?;
        item["file"]["path"].as_str().map(str::to_owned).filter(|p| std::path::Path::new(p).is_file())
    };
    let chat = bo.send("open_conversation", json!({"conversation_id": "you"}))["subscription"].clone();
    let copied = bo.snapshot(chat.as_str().unwrap(), "the copy on the new computer", |d| path_of(d).is_some());
    std::fs::remove_file(path_of(&copied["data"]).unwrap()).unwrap();
    let room = b.0.join(szfriends_helper::service::TEST_FREE_BYTES_FILE);
    std::fs::write(&room, "49999").unwrap();
    assert_eq!(bo.refused("fetch_from_device", json!({"transfer_id": transfer})), "disk_full");
    std::fs::write(&room, "50000").unwrap();
    bo.send("fetch_from_device", json!({"transfer_id": transfer}));
    let chat = bo.send("open_conversation", json!({"conversation_id": "you"}))["subscription"].clone();
    bo.snapshot(chat.as_str().unwrap(), "the copy back", |d| path_of(d).is_some());
}
