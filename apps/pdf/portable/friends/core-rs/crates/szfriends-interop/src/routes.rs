//! Which route two friends' conversation shows as their surroundings change (a [`Room`]): first only the test air,
//! so they meet and talk over Bluetooth; then the network comes up and the conversation moves to it. The same
//! scenario runs between two Rust helpers (`helpers_nearby.rs`) and a Rust helper and the Objective-C helper
//! (`objc_routes.rs`).

use serde_json::{json, Value};

use crate::helpers::{Client, Room};
use crate::nearby;

pub const LAN: &str = "Nearby, on your network";
pub const BLUETOOTH: &str = "Nearby, over Bluetooth";

/// `client`'s conversation with `title`, from its list.
pub fn conversation_with(client: &mut Client, title: &str) -> String {
    let list = client.subscribe("list", json!({}));
    let rows = |d: &Value| d["rows"].as_array().cloned().unwrap_or_default();
    let data = client.snapshot(&list, &format!("{title} in the list"), |d| rows(d).iter().any(|r| r["title"] == title));
    client.send("unsubscribe", json!({"subscription": list}));
    let row = rows(&data).into_iter().find(|r| r["title"] == title).expect("checked");
    row["conversation_id"].as_str().expect("a conversation").to_owned()
}

/// Waits until the open conversation `chat` shows `route`.
pub fn shows(client: &mut Client, chat: &str, route: &str) -> Value {
    client.snapshot(chat, &format!("the conversation showing {route}"), |d| d.to_string().contains(route))
}

/// A message from `a` arrives at `b` and is delivered.
pub fn message(a: &mut Client, a_chat: &str, a_conversation: &str, b: &mut Client, b_chat: &str, text: &str) {
    // A token per text (distinct texts, at most 16 bytes of them told apart).
    let token: String = format!("{:0<32}", hex::encode(text.as_bytes())).chars().take(32).collect();
    a.send("send_message", json!({"conversation_id": a_conversation, "text": text, "client_token": token}));
    b.snapshot(b_chat, "the message arriving", |d| d.to_string().contains(text));
    a.snapshot(a_chat, "the message delivered", |d| {
        d["items"]
            .as_array()
            .is_some_and(|items| items.iter().any(|i| i["text"] == text && i["status"]["state"] == "delivered"))
    });
}

/// With the network held, `b` is visible over the test air, `a` asks, `b` accepts, and they talk (messages and a
/// file) over Bluetooth, which both conversations show; then the network comes up, both conversations move to it,
/// and a message goes over it.
pub fn bluetooth_then_network(a: &mut Client, a_name: &str, b: &mut Client, b_name: &str, room: &Room) {
    nearby::visible_request(a, a_name, b, b_name);
    let (b_in_a, a_in_b) = (conversation_with(a, b_name), conversation_with(b, a_name));
    let (chat_a, chat_b) = (a.open(&b_in_a), b.open(&a_in_b));
    shows(a, &chat_a, BLUETOOTH);
    shows(b, &chat_b, BLUETOOTH);
    message(a, &chat_a, &b_in_a, b, &chat_b, "Over the air");
    room.network_comes_up();
    shows(a, &chat_a, LAN);
    shows(b, &chat_b, LAN);
    message(b, &chat_b, &a_in_b, a, &chat_a, "Over the network");
    let data = shows(a, &chat_a, LAN);
    assert!(!data.to_string().contains(BLUETOOTH), "still Bluetooth: {data}");
}

/// The profile's own route: `joiner` joins `holder`'s profile with the network held, so the join and the sync after
/// it run over the test air, and the join page says Bluetooth; once the network comes up the sync moves to it, as a
/// friend's conversation does (`bluetooth_then_network`), and a new name still reaches the new computer there.
pub fn join_over_bluetooth_then_network(holder: &mut Client, holder_name: &str, joiner: &mut Client, room: &Room) {
    crate::nearby_devices::join(holder, joiner);
    let join_view = joiner.subscribe("join", json!({}));
    let profile = joiner.subscribe("profile", json!({}));
    let rename = |holder: &mut Client, joiner: &mut Client, name: String| {
        holder.send("set_name", json!({"name": name}));
        joiner.snapshot(&profile, &format!("{name} on the new computer"), |d| d.to_string().contains(&name));
    };
    let shows_route = |joiner: &mut Client, route: &str| {
        joiner.snapshot(&join_view, &format!("the join page showing {route}"), |d| d["route"]["label"] == route)
    };
    // Named once the sync runs over the air: a name given while the new computer's first capture is on its way can
    // lose to the copy that computer took when it joined.
    shows_route(joiner, BLUETOOTH);
    rename(holder, joiner, format!("{holder_name} over the air"));
    room.network_comes_up();
    shows_route(joiner, LAN);
    rename(holder, joiner, format!("{holder_name} over the network"));
    let data = shows_route(joiner, LAN);
    assert!(!data.to_string().contains(BLUETOOTH), "still Bluetooth: {data}");
}
