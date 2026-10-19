//! The Friends service end to end: two helpers' services in test homes, made friends, reaching each other over the
//! test network on 127.0.0.1, each driven by a client through the protocol server. A message both ways with the
//! outbox's states, and a file offered, accepted, received whole and acknowledged; then each deletes history.

mod clients;
mod support;

use clients::{exchange, texts, Client, Temp};
use serde_json::json;
use szfriends_helper::service::{seed, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: each test's services start with its own test network, one test at a time.
static START: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn two_helpers_exchange_messages_and_a_file_over_the_test_network() {
    let (a, b, routes) = (Temp::new("a"), Temp::new("b"), Temp::new("routes"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &routes.0);
    let (bo_in_a, ada_in_b) = seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    let mut ada = Client::connect(&a.0);
    let mut bo = Client::connect(&b.0);
    drop(guard);
    // Opening Friends starts Nearby (in a test home: the test network only).
    ada.send("activate", json!({}));
    bo.send("activate", json!({}));
    exchange(&a.0, &b.0, &mut ada, &mut bo, (&bo_in_a, &ada_in_b), 300_000);

    // Delete chat history on a computer of its own: gone there, kept by the friend, who stays a friend.
    let kept = found(&b.0, "Gearbox.stl").expect("the received file in Bo's home");
    bo.send("delete_history", json!({"conversation_id": ada_in_b}));
    let chat = bo.send("open_conversation", json!({"conversation_id": ada_in_b}))["subscription"].clone();
    bo.snapshot(chat.as_str().unwrap(), "Bo's chat with Ada emptied", |d| {
        d["items"].as_array().is_some_and(|items| items.is_empty())
    });
    assert!(kept.exists(), "received files stay");
    let chat = ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].clone();
    ada.snapshot(chat.as_str().unwrap(), "Ada keeps hers", |d| texts(d).contains("Hi Ada, Bo here"));
    // Every chat at once.
    ada.send("delete_history", json!({}));
    ada.snapshot(chat.as_str().unwrap(), "Ada's chat emptied", |d| d["items"].as_array().is_some_and(Vec::is_empty));
    assert_eq!(bo.refused("delete_history", json!({"conversation_id": "c_unknown"})), "not_found");
}

#[test]
fn your_computers_and_joining_show_this_computers_real_state() {
    let (home, routes) = (Temp::new("devices"), Temp::new("devices-routes"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &home.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &routes.0);
    let mut client = Client::connect(&home.0);
    drop(guard);
    let list = client.send("subscribe", json!({"view": "list"}))["subscription"].as_str().unwrap().to_owned();
    let shown = client.snapshot(&list, "the list with devices", |d| d["state"] == "normal");
    assert_eq!(shown["data"]["join_requests"], json!([]), "no computer asked to join");
    let join = client.send("subscribe", json!({"view": "join"}))["subscription"].as_str().unwrap().to_owned();
    client.snapshot(&join, "the join view", |d| d.is_object());
    client.send("rename_device", json!({"name": "Workshop PC"}));
    let profile = client.send("subscribe", json!({"view": "profile"}))["subscription"].as_str().unwrap().to_owned();
    client
        .snapshot(&profile, "this computer named in Your computers", |d| texts(&d["devices"]).contains("Workshop PC"));
    client.send("join_profile", json!({"friends_id": "amber-falcon"}));
    client.snapshot(&join, "joining waits for the code", |d| d["state"] == "waiting");
    client.send("cancel_join", json!({}));
    client.snapshot(&join, "joining cancelled", |d| d["state"] != "waiting");
}

/// The first file named `name` under `dir`.
fn found(dir: &std::path::Path, name: &str) -> Option<std::path::PathBuf> {
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if let Some(hit) = found(&path, name) {
                return Some(hit);
            }
        } else if path.file_name().is_some_and(|n| n == name) {
            return Some(path);
        }
    }
    None
}
