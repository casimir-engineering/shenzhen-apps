//! Get again end to end (ADR 0016, PROTOCOL.md § Getting a file again) between two Rust helpers' services in test
//! homes on the test network: Bo deletes a file Ada sent, the item says so and offers Get again, and the file comes
//! back from Ada's computer into Bo's Downloads; once Ada has changed the file she sent, it cannot come back.

mod clients;
mod support;

use std::path::Path;
use std::time::{Duration, SystemTime};

use clients::{texts, Client, Temp};
use serde_json::{json, Value};
use szfriends_helper::service::{seed, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;

fn item<'a>(data: &'a Value, transfer: &str) -> Option<&'a Value> {
    data["items"].as_array()?.iter().find(|i| i["transfer_id"] == transfer)
}

/// The path a received item's Open or Show action names.
fn opened(value: &Value) -> Option<String> {
    match value {
        Value::Object(map) if matches!(map.get("action").and_then(Value::as_str), Some("open_file" | "show_file")) => {
            map.get("path").and_then(Value::as_str).map(str::to_owned)
        }
        Value::Object(map) => map.values().find_map(opened),
        Value::Array(list) => list.iter().find_map(opened),
        _ => None,
    }
}

/// Bo's chat with Ada, opened afresh: what it shows of `transfer` once it `matches`.
fn bo_sees(bo: &mut Client, chat: &str, transfer: &str, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
    let subscription = bo.send("open_conversation", json!({"conversation_id": chat}))["subscription"].clone();
    let shown = bo.snapshot(subscription.as_str().unwrap(), what, |d| item(d, transfer).is_some_and(&matches));
    item(&shown["data"], transfer).unwrap().clone()
}

fn token() -> String {
    let mut token = [0u8; 16];
    szfriends_crypto::random_bytes(&mut token);
    token.iter().map(|b| format!("{b:02x}")).collect()
}

fn edit(path: &Path) {
    let mut bytes = std::fs::read(path).unwrap();
    bytes[10] ^= 0xff;
    std::fs::write(path, bytes).unwrap();
    let handle = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    handle.set_modified(SystemTime::now() + Duration::from_secs(5)).unwrap();
}

#[test]
fn a_deleted_file_comes_back_from_the_friend_who_sent_it() {
    let (a, b, routes) = (Temp::new("again-a"), Temp::new("again-b"), Temp::new("again-routes"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &routes.0);
    let (bo_in_a, ada_in_b) = seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    let mut ada = Client::connect_with(&a.0, &["drop.files", "files.again"]);
    let mut bo = Client::connect_with(&b.0, &["drop.files", "files.again"]);
    assert!(bo.welcome["capabilities"].to_string().contains("\"files.again\""), "{}", bo.welcome);
    ada.send("activate", json!({}));
    bo.send("activate", json!({}));

    // Ada sends Bo a file; it arrives whole.
    let source = a.0.join("Documents").join("Shift rota.pdf");
    std::fs::create_dir_all(source.parent().unwrap()).unwrap();
    let content: Vec<u8> = (0..300_000u32).map(|i| (i * 13 % 251) as u8).collect();
    std::fs::write(&source, &content).unwrap();
    let files = json!({"conversation_id": bo_in_a, "files": [{"path": source}], "client_token": token()});
    let transfer = ada.send("send_files", files)["transfer_ids"][0].as_str().unwrap().to_owned();
    let t = transfer.as_str();
    bo_sees(&mut bo, &ada_in_b, t, "the offer", |i| texts(i).contains("accept_offer"));
    bo.send("accept_offer", json!({"transfer_id": t}));
    let received = bo_sees(&mut bo, &ada_in_b, t, "the file received", |i| opened(i).is_some());
    let path = opened(&received).unwrap();
    let chat = ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].clone();
    ada.snapshot(chat.as_str().unwrap(), "delivered at Ada", |d| item(d, t).is_some_and(|i| i["state"] == "delivered"));

    // Nothing to get while it is here, nor for a file that is not in this chat.
    assert_eq!(bo.refused("fetch_from_friend", json!({"transfer_id": t})), "not_allowed");
    let unknown = bo.request("fetch_from_friend", json!({"transfer_id": "t_unknown"}));
    assert_eq!(unknown["error"]["code"], "not_found", "{unknown}");
    assert_eq!(unknown["error"]["message"], "This file isn’t in this chat anymore.", "{unknown}");

    // Bo deletes it: moved or deleted, with Get again; Get again brings it back into Downloads.
    std::fs::remove_file(&path).unwrap();
    let missing = bo_sees(&mut bo, &ada_in_b, t, "moved or deleted", |i| i["state"] == "missing");
    assert_eq!(missing["status_label"], "Moved or deleted");
    assert!(texts(&missing).contains("fetch_from_friend"), "{missing}");
    // No room for it on Bo's computer: Get again says so, and nothing is asked of Ada.
    let room = b.0.join(szfriends_helper::service::TEST_FREE_BYTES_FILE);
    std::fs::write(&room, "1000").unwrap();
    assert_eq!(bo.refused("fetch_from_friend", json!({"transfer_id": t})), "disk_full");
    std::fs::remove_file(&room).unwrap();
    bo.send("fetch_from_friend", json!({"transfer_id": t}));
    let back = bo_sees(&mut bo, &ada_in_b, t, "the file back", |i| i["state"] == "received" && opened(i).is_some());
    let again = opened(&back).unwrap();
    assert_eq!(std::fs::read(&again).unwrap(), content, "the same bytes");
    assert!(Path::new(&again).starts_with(b.0.join("Downloads")), "{again}");

    // Ada edits the file she sent: Bo deletes his copy again, and she no longer has it to give.
    edit(&source);
    std::fs::remove_file(&again).unwrap();
    bo_sees(&mut bo, &ada_in_b, t, "moved or deleted again", |i| i["state"] == "missing");
    bo.send("fetch_from_friend", json!({"transfer_id": t}));
    let gone = bo_sees(&mut bo, &ada_in_b, t, "gone", |i| i["state"] == "gone");
    assert_eq!(gone["status_label"], "Ada doesn’t have this file anymore.");
    assert_eq!(gone["actions"], json!([]));
}
