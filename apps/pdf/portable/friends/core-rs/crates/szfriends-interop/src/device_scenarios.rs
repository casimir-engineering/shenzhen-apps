//! One person's two devices, whichever implementation each runs (ADR 0012 to 0014): the first device approves, the
//! new one joins with the code it shows, both sync a friend and history each way over IK, an erased chat reaches the
//! other device, and the first device removes the second, which learns it was removed.

use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::{is_event, keys, listen, wait_for, Peer};

const WAIT: Duration = Duration::from_secs(30);

fn state(peer: &mut dyn Peer) -> Value {
    peer.command(json!({ "cmd": "device_state" }))
}

/// Polls `peer`'s state until `check` holds; panics with the last state after the wait.
fn until(peer: &mut dyn Peer, what: &str, check: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + WAIT;
    loop {
        let current = state(peer);
        if check(&current) {
            return current;
        }
        if Instant::now() > deadline {
            panic!("{what} did not happen within {WAIT:?}; state: {current}");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn messages(state: &Value, identity_key: &str) -> Option<Vec<String>> {
    let people = state["people"].as_array()?;
    let person = people.iter().find(|p| p["identity_key"] == identity_key)?;
    Some(person["messages"].as_array()?.iter().filter_map(|m| m.as_str().map(str::to_owned)).collect())
}

fn ok(reply: Value) -> Value {
    assert!(reply.get("error").is_none(), "{reply}");
    reply
}

/// `friend` is the identity and static key, in hex, of someone the first device already knows.
pub fn join_sync_remove(first: &mut dyn Peer, second: &mut dyn Peer, friend: (&str, &str)) {
    let (first_keys, second_keys) = (keys(first), keys(second));
    let (carol, carol_static) = friend;
    ok(first.command(json!({ "cmd": "set_profile", "name": "Mei", "friends_id": "maple-otter" })));
    ok(first.command(json!({ "cmd": "device_genesis", "name": "First computer", "system": "macOS 26.1" })));
    ok(first
        .command(json!({ "cmd": "add_friend", "identity_key": carol, "static_key": carol_static, "name": "Carol" })));
    ok(first.command(json!({ "cmd": "add_message", "identity_key": carol, "id": "m1", "text": "from carol",
        "at": 1_760_000_001.5 })));
    let (port1, port2) = (listen(first), listen(second));

    // Joining: the request shows on the first device, its code goes into the second.
    let started = ok(second.command(json!({ "cmd": "join_start", "friends_id": "maple-otter",
        "name": "Second computer", "system": "Windows 11" })));
    let request_id = started["request_id"].as_str().expect("a request id").to_owned();
    ok(second.command(json!({ "cmd": "join_send_request", "port": port1 })));
    let (mut seen1, mut seen2) = (Vec::new(), Vec::new());
    wait_for(first, &mut seen1, WAIT, "the join request", |e| {
        e["event"] == "join_request" && e["request_id"] == request_id.as_str()
    });
    let code = ok(first.command(json!({ "cmd": "join_approve", "request_id": request_id })))["code"]
        .as_str()
        .expect("a code")
        .to_owned();
    ok(second.command(json!({ "cmd": "join_code", "port": port1, "code": code })));
    let joined = wait_for(second, &mut seen2, WAIT, "joined", is_event("joined", 0));
    assert_eq!(joined["root"], first_keys.identity.as_str(), "the second device joined the first one's profile");
    wait_for(first, &mut seen1, WAIT, "the approval done", is_event("join_approved", 0));
    let on_second = state(second);
    assert_eq!(on_second["profile_name"], "Mei");
    assert_eq!(on_second["devices"].as_array().map(Vec::len), Some(2));

    // Sync: history the first device had reaches the second, and back.
    ok(second.command(json!({ "cmd": "sync_dial", "port": port1, "device_key": first_keys.identity })));
    until(second, "carol's history on the second device", |s| messages(s, carol).is_some_and(|m| m == ["from carol"]));
    ok(second.command(json!({ "cmd": "add_message", "identity_key": carol, "id": "m2", "text": "seen on the second",
        "at": 1_760_000_002.5 })));
    ok(second.command(json!({ "cmd": "capture" })));
    until(first, "the second device's message on the first", |s| {
        messages(s, carol).is_some_and(|m| m == ["from carol", "seen on the second"])
    });

    // Erasing the chat on the second device erases it on the first.
    ok(second.command(json!({ "cmd": "erase_history", "identity_key": carol })));
    until(first, "the erased chat on the first", |s| messages(s, carol).is_some_and(|m| m.is_empty()));
    ok(first.command(json!({ "cmd": "add_message", "identity_key": carol, "id": "m3", "text": "after erasing",
        "at": 1_760_000_003.5 })));
    ok(first.command(json!({ "cmd": "capture" })));
    until(second, "a later message on the second", |s| messages(s, carol).is_some_and(|m| m == ["after erasing"]));

    // Removing the second computer: it learns it from the first, and the first holds it as removed.
    ok(first.command(json!({ "cmd": "revoke_device", "device_key": second_keys.identity })));
    until(second, "the second device removed", |s| s["removed"] == true);
    let on_first = state(first);
    let removed = on_first["devices"]
        .as_array()
        .and_then(|d| d.iter().find(|d| d["key"] == second_keys.identity.as_str()).map(|d| d["state"].clone()));
    assert_eq!(removed, Some(json!(2)), "the first device holds the second as removed: {on_first}");
    let _ = port2;
}
