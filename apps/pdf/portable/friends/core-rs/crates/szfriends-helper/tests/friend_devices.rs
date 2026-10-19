//! A person's other computers seen from outside, between Rust helpers' services on a test network of entries on
//! loopback (ADR 0012): a friend keeps the person's chain from a session with their first computer and, with that
//! computer away, reaches their second one by its own tag; and a computer removed while it was away is told so by the
//! computer that removed it, once both are back on the network.

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

/// The id of the first computer a view lists that is not this one.
fn other_computer(data: &Value) -> Option<String> {
    match data {
        Value::Object(map) if map.get("this_computer") == Some(&Value::Bool(false)) => {
            map.get("device_id").and_then(Value::as_str).map(str::to_owned)
        }
        Value::Object(map) => map.values().find_map(other_computer),
        Value::Array(items) => items.iter().find_map(other_computer),
        _ => None,
    }
}

fn named<'a>(d: &'a Value, name: &str) -> Option<&'a Value> {
    d["people"].as_array()?.iter().find(|p| p["title"] == name && p["nearby_id"].is_string())
}

/// `asker` sends a request to `visible`, who accepts it: their conversations, each in the other's list.
fn befriend(visible: &mut Client, visible_name: &str, asker: &mut Client, asker_name: &str) -> (String, String) {
    visible.send("start_visibility", json!({}));
    let nearby = asker.subscribe("nearby", json!({}));
    let seen = asker.snapshot(&nearby, "the visible computer", |d| named(d, visible_name).is_some());
    let nearby_id = named(&seen["data"], visible_name).unwrap()["nearby_id"].clone();
    asker.send("send_request", json!({"nearby_id": nearby_id}));
    let list_v = visible.subscribe("list", json!({}));
    let asked = visible.snapshot(&list_v, "the request", |d| row_titled(d, asker_name).is_some());
    let asker_in_v = row_titled(&asked["data"], asker_name).unwrap()["conversation_id"].as_str().unwrap().to_owned();
    visible.send("accept_request", json!({"conversation_id": asker_in_v}));
    visible.send("stop_visibility", json!({}));
    let list_a = asker.subscribe("list", json!({}));
    let friends = asker.snapshot(&list_a, "now friends", |d| {
        row_titled(d, visible_name).is_some_and(|r| r["waiting"].is_null() && r["subtitle"] != "Request sent")
    });
    let visible_in_a = row_titled(&friends["data"], visible_name).unwrap()["conversation_id"].as_str().unwrap();
    (visible_in_a.to_owned(), asker_in_v)
}

#[test]
fn a_friend_reaches_the_second_computer_while_the_first_is_away() {
    let (a, b, c, network) = (Temp::new("xa"), Temp::new("xb"), Temp::new("xc"), Temp::new("xnet"));
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
    let (ada_in_c, cy_in_a) = befriend(&mut ada, "Ada", &mut cy, "Cy");
    // A first message on the session that carries Ada's chain to Cy.
    let token = |n: u8| format!("{n:02x}").repeat(16);
    cy.send("send_message", json!({"conversation_id": ada_in_c, "text": "Hello Ada", "client_token": token(1)}));
    let chat_a = ada.send("open_conversation", json!({"conversation_id": cy_in_a}))["subscription"].clone();
    ada.snapshot(chat_a.as_str().unwrap(), "Cy's first message", |d| texts(d).contains("Hello Ada"));
    let list_b = bo.subscribe("list", json!({}));
    let synced = bo.snapshot(&list_b, "Cy on the second computer", |d| row_titled(d, "Cy").is_some());
    let cy_in_b = row_titled(&synced["data"], "Cy").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    // The second computer holds Cy as a friend (the chat open to them) and the chat, through sync, before the first
    // one goes: it takes messages only from a friend.
    let chat_b = bo.send("open_conversation", json!({"conversation_id": cy_in_b}))["subscription"].clone();
    bo.snapshot(chat_b.as_str().unwrap(), "Cy a friend on the second computer", |d| {
        d["composer"]["enabled"] == true && texts(d).contains("Hello Ada")
    });

    // Ada's first computer goes away: Cy's next message reaches her second one, by its own tag and static key.
    drop(ada);
    cy.send("send_message", json!({"conversation_id": ada_in_c, "text": "Only the laptop", "client_token": token(2)}));
    let wait = std::time::Duration::from_secs(60);
    bo.snapshot_within(chat_b.as_str().unwrap(), "Cy's message at the second computer", wait, |d| {
        texts(d).contains("Only the laptop")
    });
}

#[test]
fn a_computer_removed_while_away_learns_it_when_it_comes_back() {
    let (a, b, network) = (Temp::new("ra"), Temp::new("rb"), Temp::new("rnet"));
    let mut clients = start(&[&a, &b], &network);
    let (mut bo, mut ada) = (clients.pop().unwrap(), clients.pop().unwrap());
    ada.send("set_name", json!({"name": "Ada"}));
    for client in [&mut ada, &mut bo] {
        client.send("activate", json!({}));
    }
    let ada_id = friends_id(&mut ada);
    join_profile(&mut ada, &ada_id, &mut bo);
    let profile_a = ada.subscribe("profile", json!({}));
    let listed = ada.snapshot(&profile_a, "the second computer listed", |d| other_computer(d).is_some());
    let device = other_computer(&listed["data"]).unwrap();

    // Away when it is removed: nothing reaches it then.
    drop(bo);
    ada.send("revoke_device", json!({"device_id": device}));
    ada.snapshot(&profile_a, "the second computer gone from the list", |d| other_computer(d).is_none());

    let mut bo = start(&[&b], &network).pop().unwrap();
    bo.send("activate", json!({}));
    let list_b = bo.subscribe("list", json!({}));
    let wait = std::time::Duration::from_secs(60);
    let told = bo.snapshot_within(&list_b, "told it was removed", wait, |d| d["state"] == "device_removed");
    assert!(told["data"]["removed"].is_object(), "what the removed computer shows: {told}");
}
