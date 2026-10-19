//! One person's computers end to end between Rust helpers' services in test homes, on a test network of entries on
//! loopback (ADR 0013, ADR 0014): a new computer asks to join by the profile's Friends ID over nearby, the person
//! approves on the computer that has the profile and types the code it shows (a wrong one first); the new computer
//! then holds the profile, both list both computers, and what changes on one (the name, a computer's name, a
//! friend and their messages, a deleted chat) reaches the other over the session between them.

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
    homes.iter().map(|home| Client::connect(&home.0)).collect()
}

fn friends_id(client: &mut Client) -> String {
    let profile = client.subscribe("profile", json!({}));
    let data = client.snapshot(&profile, "the profile", |d| d["id"]["friends_id"].is_string());
    data["data"]["id"]["friends_id"].as_str().unwrap().to_owned()
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
}
