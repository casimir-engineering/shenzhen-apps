//! Bluetooth end to end between two Rust helpers' services in test homes, over the test air (ADR 0004): the same
//! adapter, presence values, channels and sessions a radio carries, with no network method at all. A person visible
//! for their 5 minutes is found, asked and accepted, and messages go both ways over Bluetooth; a radio switched off
//! shows as off. Real radios are tested on hardware only.

mod clients;
mod support;

use std::sync::Mutex;

use clients::{Client, Temp};
use serde_json::{json, Value};
use szfriends_helper::nearby::test_air::{ENV_TEST_BLUETOOTH, ENV_TEST_BLUETOOTH_POWER};
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: helpers start one pair at a time.
static START: Mutex<()> = Mutex::new(());

/// Bound `_homes` first wherever it is taken apart, so the homes outlive the services using them (Windows keeps a
/// directory whose files are open).
struct Pair {
    a: Client,
    b: Client,
    _homes: (Temp, Temp, Temp),
}

fn start(names: (&str, &str), power: Option<&str>) -> Pair {
    let homes = (Temp::new("ba"), Temp::new("bb"), Temp::new("air"));
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &homes.0 .0);
    std::env::set_var(ENV_TEST_BLUETOOTH, &homes.2 .0);
    match power {
        Some(power) => std::env::set_var(ENV_TEST_BLUETOOTH_POWER, power),
        None => std::env::remove_var(ENV_TEST_BLUETOOTH_POWER),
    }
    let mut a = Client::connect(&homes.0 .0);
    let mut b = Client::connect(&homes.1 .0);
    for (client, name) in [(&mut a, names.0), (&mut b, names.1)] {
        client.send("set_name", json!({"name": name}));
        client.send("activate", json!({}));
    }
    Pair { a, b, _homes: homes }
}

fn row_titled<'a>(data: &'a Value, title: &str) -> Option<&'a Value> {
    data["rows"].as_array()?.iter().find(|r| r["title"] == title)
}

fn conversation(client: &mut Client, title: &str) -> String {
    let list = client.subscribe("list", json!({}));
    let data = client.snapshot(&list, "the row", |d| row_titled(d, title).is_some());
    row_titled(&data["data"], title).unwrap()["conversation_id"].as_str().unwrap().to_owned()
}

#[test]
fn a_visible_person_found_asked_and_messaged_over_bluetooth() {
    let Pair { _homes, a: mut ada, b: mut bo } = start(("Ada", "Bo"), None);
    let capabilities = bo.welcome["capabilities"].as_array().cloned().unwrap_or_default();
    assert!(capabilities.contains(&json!("nearby.bluetooth")), "{capabilities:?}");
    let nearby = bo.subscribe("nearby", json!({}));
    bo.snapshot(&nearby, "Bluetooth working at Bo", |d| d.to_string().contains("Looking over Bluetooth"));
    ada.send("start_visibility", json!({}));
    let seen = bo.snapshot(&nearby, "Ada visible over Bluetooth", |d| {
        d["people"].as_array().is_some_and(|p| p.iter().any(|p| p["title"] == "Ada" && p["nearby_id"].is_string()))
    });
    let person = seen["data"]["people"].as_array().unwrap().iter().find(|p| p["title"] == "Ada").unwrap().clone();
    bo.send("send_request", json!({"nearby_id": person["nearby_id"]}));
    let bo_in_a = conversation(&mut ada, "Bo");
    ada.send("accept_request", json!({"conversation_id": bo_in_a}));
    ada.send("stop_visibility", json!({}));
    let ada_in_b = conversation(&mut bo, "Ada");
    let list_b = bo.subscribe("list", json!({}));
    bo.snapshot(&list_b, "Ada a friend at Bo", |d| {
        row_titled(d, "Ada").is_some_and(|r| r["waiting"].is_null() && r["subtitle"] != "Request sent")
    });

    let chat_b = bo.send("open_conversation", json!({"conversation_id": ada_in_b}))["subscription"].to_string();
    let token = "0123456789abcdef0123456789abcdef";
    ada.send(
        "send_message",
        json!({"conversation_id": bo_in_a, "text": "Hello over Bluetooth", "client_token": token}),
    );
    let at_b = bo.snapshot(chat_b.trim_matches('"'), "the message at Bo", |d| {
        d.to_string().contains("Hello over Bluetooth") && d.to_string().contains("Nearby, over Bluetooth")
    });
    assert!(at_b["data"].to_string().contains("Nearby, over Bluetooth"), "the route is Bluetooth");
    let chat_a = ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].to_string();
    let token = "fedcba9876543210fedcba9876543210";
    bo.send("send_message", json!({"conversation_id": ada_in_b, "text": "And back", "client_token": token}));
    ada.snapshot(chat_a.trim_matches('"'), "the reply at Ada", |d| d.to_string().contains("And back"));
}

#[test]
fn a_radio_switched_off_shows_as_off() {
    let Pair { _homes, a: _ada, b: mut bo } = start(("Ada", "Bo"), Some("off"));
    let nearby = bo.subscribe("nearby", json!({}));
    bo.snapshot(&nearby, "Bluetooth off at Bo", |d| d.to_string().contains("Bluetooth is off"));
}
