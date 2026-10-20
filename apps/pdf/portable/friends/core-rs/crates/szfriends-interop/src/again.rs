//! Getting a file again (ADR 0016) between whole helpers, whichever implementation each is, driven through their
//! client protocol as an app drives them. A file the friend sent and the person deleted shows as moved or deleted with
//! Get again, which brings the same bytes back; once the friend changed the file they sent, Get again ends with "Otto
//! doesn’t have this file anymore." On one person's two computers, a file deleted on one shows "On ‹other›" with Get,
//! which copies it back from the other.

use serde_json::{json, Value};

use crate::helpers::Client;

/// The conversation `client`'s list shows for `title`.
pub fn conversation_titled(client: &mut Client, title: &str) -> String {
    let list = client.subscribe("list", json!({}));
    let data = client.snapshot(&list, &format!("{title} in the list"), |d| {
        d["rows"].as_array().is_some_and(|rows| rows.iter().any(|r| r["title"] == title))
    });
    client.send("unsubscribe", json!({"subscription": list}));
    let rows = data["rows"].as_array().expect("checked");
    let row = rows.iter().find(|r| r["title"] == title).expect("checked");
    row["conversation_id"].as_str().expect("a conversation").to_owned()
}

fn item(data: &Value, transfer_id: &str) -> Option<Value> {
    data["items"].as_array()?.iter().find(|i| i["transfer_id"] == transfer_id).cloned()
}

fn has_action(item: &Value, action: &str) -> bool {
    item["actions"].as_array().is_some_and(|actions| actions.iter().any(|a| a["action"] == action))
}

/// The item for `transfer_id` in a fresh view of `conversation` (opened anew, as the person coming back to the chat),
/// once `matches` holds.
pub fn item_when(
    client: &mut Client,
    conversation: &str,
    transfer_id: &str,
    what: &str,
    matches: impl Fn(&Value) -> bool,
) -> Value {
    let chat = client.open(conversation);
    let data = client.snapshot(&chat, what, |d| item(d, transfer_id).is_some_and(|i| matches(&i)));
    client.send("unsubscribe", json!({"subscription": chat}));
    item(&data, transfer_id).expect("checked")
}

/// The path of a file that is here, once the item has one.
fn received_path(client: &mut Client, conversation: &str, transfer_id: &str, what: &str) -> String {
    let found = item_when(client, conversation, transfer_id, what, |i| {
        i["file"]["path"].as_str().is_some_and(|p| std::path::Path::new(p).is_file())
    });
    found["file"]["path"].as_str().expect("checked").to_owned()
}

/// `sender` sends a file in `sender_conversation`; `receiver` accepts it in `receiver_conversation`. Returns the
/// transfer id, the path it was sent from and the path it was saved to.
pub fn send_file(
    sender: &mut Client,
    sender_conversation: &str,
    receiver: &mut Client,
    receiver_conversation: &str,
    name: &str,
) -> (String, String, String) {
    let source = sender.make_file(name, 180_000);
    // One token per file: a send retried with the same token is the same send.
    let token: String = format!("{:0<32}", hex::encode(name.as_bytes())).chars().take(32).collect();
    let files = json!({"conversation_id": sender_conversation, "files": [{"path": source}], "client_token": token});
    let transfer = sender.send("send_files", files)["transfer_ids"][0].as_str().expect("a transfer").to_owned();
    item_when(receiver, receiver_conversation, &transfer, "the offer", |i| has_action(i, "accept_offer"));
    receiver.send("accept_offer", json!({"transfer_id": transfer}));
    let saved = received_path(receiver, receiver_conversation, &transfer, "the file received");
    assert_eq!(std::fs::read(&saved).ok(), std::fs::read(&source).ok(), "the file arrived whole");
    (transfer, source, saved)
}

/// Get again, both outcomes: `receiver` deletes what `sender` sent, gets it again from `sender`; `sender` changes the
/// file it sent; `receiver` deletes it again and hears that `sender` (whose display name is `sender_name`) no longer
/// has it.
pub fn get_again(
    sender: &mut Client,
    sender_name: &str,
    sender_conversation: &str,
    receiver: &mut Client,
    receiver_conversation: &str,
) {
    let (transfer, source, saved) =
        send_file(sender, sender_conversation, receiver, receiver_conversation, "Site photos.stl");
    std::fs::remove_file(&saved).expect("the person deletes the file");
    let missing = item_when(receiver, receiver_conversation, &transfer, "moved or deleted", |i| {
        i["state"] == "missing" && has_action(i, "fetch_from_friend")
    });
    assert_eq!(missing["status_label"], "Moved or deleted", "{missing}");
    assert!(missing["file"]["path"].is_null(), "no path for a file that is gone: {missing}");
    receiver.send("fetch_from_friend", json!({"transfer_id": transfer}));
    let back = received_path(receiver, receiver_conversation, &transfer, "the file got again");
    assert_eq!(std::fs::read(&back).ok(), std::fs::read(&source).ok(), "the same bytes, back again");
    assert_eq!(receiver.refused("fetch_from_friend", json!({"transfer_id": transfer})), "not_allowed", "it is here");

    // The friend edits the file they sent (same size, other bytes): they no longer have what they sent.
    let edited: Vec<u8> = std::fs::read(&source).expect("the source").iter().map(|b| b ^ 0x5a).collect();
    std::fs::write(&source, edited).expect("the friend edits it");
    std::fs::remove_file(&back).expect("the person deletes it again");
    item_when(receiver, receiver_conversation, &transfer, "moved or deleted again", |i| i["state"] == "missing");
    receiver.send("fetch_from_friend", json!({"transfer_id": transfer}));
    let gone = item_when(receiver, receiver_conversation, &transfer, "the friend's answer", |i| i["state"] == "gone");
    assert_eq!(gone["status_label"], format!("{sender_name} doesn’t have this file anymore."), "{gone}");
    assert_eq!(gone["actions"], json!([]), "{gone}");
}

/// On one profile: `first` sends a file to You, which copies to `second` by itself; the person deletes it on
/// `second`, which then shows it on `first` with Get, and Get brings it back.
pub fn get_from_own_computer(first: &mut Client, second: &mut Client) {
    for client in [&mut *first, &mut *second] {
        let list = client.subscribe("list", json!({}));
        client.snapshot(&list, "You in the list", |d| {
            d["rows"].as_array().is_some_and(|rows| rows.iter().any(|r| r["kind"] == "you"))
        });
        client.send("unsubscribe", json!({"subscription": list}));
    }
    let name = format!("Fixture drawing {}.stl", first.name());
    let source = first.make_file(&name, 150_000);
    let token: String = format!("{:0<32}", hex::encode(name.as_bytes())).chars().take(32).collect();
    let files = json!({"conversation_id": "you", "files": [{"path": source}], "client_token": token});
    let transfer = first.send("send_files", files)["transfer_ids"][0].as_str().expect("a transfer").to_owned();
    let copy = received_path(second, "you", &transfer, "the copy on the other computer");
    assert_eq!(std::fs::read(&copy).ok(), std::fs::read(&source).ok(), "copied whole");
    std::fs::remove_file(&copy).expect("the person deletes the copy");
    let elsewhere = item_when(second, "you", &transfer, "on the other computer, with Get", |i| {
        i["state"] == "on_device" && has_action(i, "fetch_from_device")
    });
    assert!(elsewhere["status_label"].as_str().is_some_and(|s| s.starts_with("On ")), "{elsewhere}");
    second.send("fetch_from_device", json!({"transfer_id": transfer}));
    let back = received_path(second, "you", &transfer, "the copy back after Get");
    assert_eq!(std::fs::read(&back).ok(), std::fs::read(&source).ok(), "the same bytes, back again");
}

/// One profile on `a` and `b`, and a friend `f` of `a`'s: a file `f` sends is received on `a` and copied to `b`;
/// deleted on `a`, Get copies it from `b`; deleted on `b`, Get copies it from `a`; deleted on both, `b` gets it
/// again from `f` (`f_name`).
pub fn received_everywhere(a: &mut Client, b: &mut Client, f: &mut Client, f_name: &str, a_name: &str) {
    let f_in_a = conversation_titled(a, f_name);
    let a_in_f = conversation_titled(f, a_name);
    let (transfer, _, on_a) = send_file(f, &a_in_f, a, &f_in_a, "Bracket.stl");
    let f_in_b = conversation_titled(b, f_name);
    let on_b = received_path(b, &f_in_b, &transfer, "the copy on the second computer");

    std::fs::remove_file(&on_a).expect("deleted on the first computer");
    item_when(a, &f_in_a, &transfer, "on the second computer, with Get", |i| {
        i["state"] == "on_device" && has_action(i, "fetch_from_device")
    });
    a.send("fetch_from_device", json!({"transfer_id": transfer}));
    let on_a = received_path(a, &f_in_a, &transfer, "back on the first computer");

    std::fs::remove_file(&on_b).expect("deleted on the second computer");
    item_when(b, &f_in_b, &transfer, "on the first computer, with Get", |i| {
        i["state"] == "on_device" && has_action(i, "fetch_from_device")
    });
    b.send("fetch_from_device", json!({"transfer_id": transfer}));
    let on_b = received_path(b, &f_in_b, &transfer, "back on the second computer");

    std::fs::remove_file(&on_a).expect("deleted on the first computer again");
    std::fs::remove_file(&on_b).expect("and on the second");
    item_when(a, &f_in_a, &transfer, "moved or deleted on the first", |i| i["state"] == "missing");
    item_when(b, &f_in_b, &transfer, "moved or deleted everywhere", |i| {
        i["state"] == "missing" && has_action(i, "fetch_from_friend")
    });
    b.send("fetch_from_friend", json!({"transfer_id": transfer}));
    received_path(b, &f_in_b, &transfer, "got again from the friend");
}
