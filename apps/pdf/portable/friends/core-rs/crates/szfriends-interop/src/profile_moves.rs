//! What joining is for, between whole helpers whichever implementation each is: the person already uses Friends on
//! one computer, with a friend and a chat with them; a new computer or phone joins that profile; then the friend and
//! the chat are on the new one, and what happens on either reaches the other: a message the new one
//! sends the friend shows on the first, the friend's reply reaches both, and a note in You goes each way. Driven
//! through each helper's client protocol, as an app drives it; nearby or through the host, by `wait`.

use std::time::Duration;

use serde_json::{json, Value};

use crate::helpers::Client;

const YOU: &str = "you";

fn texts(data: &Value) -> Vec<String> {
    let items = data["items"].as_array().cloned().unwrap_or_default();
    items.iter().filter_map(|i| i["text"].as_str().map(str::to_owned)).collect()
}

fn says(data: &Value, text: &str) -> bool {
    texts(data).iter().any(|t| t == text)
}

/// The conversation `client`'s list shows for `title`, once it does.
fn conversation(client: &mut Client, title: &str, wait: Duration) -> String {
    let list = client.subscribe("list", json!({}));
    let data = client.snapshot_within(&list, &format!("{title} in the list"), wait, |d| {
        d["rows"].as_array().is_some_and(|rows| rows.iter().any(|r| r["title"] == title))
    });
    client.send("unsubscribe", json!({"subscription": list}));
    let rows = data["rows"].as_array().expect("checked");
    rows.iter().find(|r| r["title"] == title).expect("checked")["conversation_id"].as_str().expect("an id").to_owned()
}

fn send(client: &mut Client, conversation: &str, text: &str) {
    let token: String =
        format!("{:032x}", text.bytes().fold(0u128, |h, b| h.wrapping_mul(131).wrapping_add(b as u128)));
    client.send("send_message", json!({"conversation_id": conversation, "text": text, "client_token": token}));
}

/// `conversation` on `client` holds `text`, within `wait`.
fn shows(client: &mut Client, conversation: &str, text: &str, what: &str, wait: Duration) {
    let chat = client.open(conversation);
    client.snapshot_within(&chat, what, wait, |d| says(d, text));
    client.send("unsubscribe", json!({"subscription": chat}));
}

/// Before joining: `holder` (named `holder_name`) and `friend` (named `friend_name`) are already friends. A message
/// each way; `joiner` joins; then the friend and the chat on both, and the chat and You both ways. (You exists once
/// the profile is on two computers: a profile on one has nowhere to send it.)
pub fn friends_chats_and_you_move(
    holder: &mut Client,
    holder_name: &str,
    joiner: &mut Client,
    friend: &mut Client,
    friend_name: &str,
    wait: Duration,
) {
    let friend_in_holder = conversation(holder, friend_name, wait);
    let holder_in_friend = conversation(friend, holder_name, wait);
    send(holder, &friend_in_holder, "Before joining, from the first computer");
    shows(friend, &holder_in_friend, "Before joining, from the first computer", "the first message", wait);
    send(friend, &holder_in_friend, "Before joining, from the friend");
    shows(holder, &friend_in_holder, "Before joining, from the friend", "the friend's message", wait);

    crate::nearby_devices::join(holder, joiner);

    // The friend and the chat with them are on the new computer.
    let friend_in_joiner = conversation(joiner, friend_name, wait);
    let chat = joiner.open(&friend_in_joiner);
    joiner.snapshot_within(&chat, "the chat's history on the new computer", wait, |d| {
        says(d, "Before joining, from the first computer") && says(d, "Before joining, from the friend")
    });
    joiner.send("unsubscribe", json!({"subscription": chat}));

    // From the new computer: its message reaches the friend and shows on the first computer.
    send(joiner, &friend_in_joiner, "Hello from my new computer");
    shows(friend, &holder_in_friend, "Hello from my new computer", "the new computer's message at the friend", wait);
    shows(holder, &friend_in_holder, "Hello from my new computer", "the new computer's message on the first", wait);
    // The friend's reply reaches both.
    send(friend, &holder_in_friend, "Got it on every computer");
    shows(joiner, &friend_in_joiner, "Got it on every computer", "the friend's reply on the new computer", wait);
    shows(holder, &friend_in_holder, "Got it on every computer", "the friend's reply on the first computer", wait);
    // You, each way.
    send(joiner, YOU, "A note from the new computer");
    shows(holder, YOU, "A note from the new computer", "the new computer's note on the first", wait);
    send(holder, YOU, "A note from the first computer after joining");
    shows(joiner, YOU, "A note from the first computer after joining", "the first computer's note on the new", wait);
}
