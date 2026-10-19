//! Nearby between two whole helpers (ADR 0004), whichever implementation each is: someone visible for their 5
//! minutes found by someone browsing, a friend request with the same comparison code on both screens, accepted,
//! then messages both ways and a file; Add by ID, answered by its holder's callback, accepted by the asker; and a
//! request declined. Each helper is driven through its client protocol, as an app drives it.

use serde_json::{json, Value};

use crate::helpers::Client;

fn rows(data: &Value) -> Vec<Value> {
    data["rows"].as_array().cloned().unwrap_or_default()
}

fn row_titled(data: &Value, title: &str) -> Option<Value> {
    rows(data).into_iter().find(|r| r["title"] == title)
}

fn waiting_row(data: &Value) -> Option<Value> {
    rows(data).into_iter().find(|r| r["waiting"]["kind"] == "request")
}

fn conversation(row: &Value) -> String {
    row["conversation_id"].as_str().expect("a conversation").to_owned()
}

/// Names both helpers and opens Friends in each (which starts Nearby).
pub fn start(a: &mut Client, a_name: &str, b: &mut Client, b_name: &str) {
    for (client, name) in [(a, a_name), (b, b_name)] {
        client.send("set_name", json!({"name": name}));
        client.send("activate", json!({}));
    }
}

/// The person `title` as `client`'s Nearby lists them, once they appear with a Request action.
pub fn find_visible(client: &mut Client, title: &str) -> Value {
    let nearby = client.subscribe("nearby", json!({}));
    let visible = |d: &Value| {
        let people = d["people"].as_array()?;
        people.iter().find(|p| p["title"] == title && p["action"]["action"] == "send_request").cloned()
    };
    let data = client.snapshot(&nearby, &format!("{title} visible nearby"), |d| visible(d).is_some());
    client.send("unsubscribe", json!({"subscription": nearby}));
    visible(&data).expect("checked")
}

/// The six digits `client`'s request card shows for `conversation`, once there are some.
fn card_code(client: &mut Client, conversation: &str) -> String {
    let chat = client.open(conversation);
    let data = client.snapshot(&chat, "a comparison code", |d| d["request"]["comparison_code"].is_string());
    client.send("unsubscribe", json!({"subscription": chat}));
    data["request"]["comparison_code"].as_str().expect("checked").to_owned()
}

/// The code `client`'s details show for a friend.
fn details_code(client: &mut Client, conversation: &str) -> String {
    let details = client.subscribe("details", json!({"conversation_id": conversation}));
    let data = client.snapshot(&details, "a code in the details", |d| d["verification"]["comparison_code"].is_string());
    client.send("unsubscribe", json!({"subscription": details}));
    data["verification"]["comparison_code"].as_str().expect("checked").to_owned()
}

/// A message from `a` reaches `b` and is delivered; one from `b` reaches `a`; then a file from `a`, accepted by `b`,
/// arrives whole and is delivered.
pub fn talk(a: &mut Client, a_conversation: &str, b: &mut Client, b_conversation: &str) {
    let chat_a = a.open(a_conversation);
    let chat_b = b.open(b_conversation);
    let token = "0123456789abcdef0123456789abcdef";
    a.send(
        "send_message",
        json!({"conversation_id": a_conversation, "text": "Hello from nearby", "client_token": token}),
    );
    b.snapshot(&chat_b, "the message arriving", |d| d.to_string().contains("Hello from nearby"));
    a.snapshot(&chat_a, "the message delivered", |d| {
        d["items"].as_array().is_some_and(|items| {
            items.iter().any(|i| i["text"] == "Hello from nearby" && i["status"]["state"] == "delivered")
        })
    });
    let token = "fedcba9876543210fedcba9876543210";
    b.send("send_message", json!({"conversation_id": b_conversation, "text": "And back again", "client_token": token}));
    a.snapshot(&chat_a, "the reply arriving", |d| d.to_string().contains("And back again"));
    let path = a.make_file("Gearbox.stl", 300_000);
    let files =
        json!({"conversation_id": a_conversation, "files": [{"path": path}], "client_token": "aaaabbbbccccdddd"});
    let transfer = a.send("send_files", files)["transfer_ids"][0].as_str().expect("a transfer").to_owned();
    b.snapshot(&chat_b, "the offer", |d| {
        d.to_string().contains("Gearbox.stl") && d.to_string().contains("accept_offer")
    });
    b.send("accept_offer", json!({"transfer_id": transfer}));
    b.snapshot(&chat_b, "the file received", |d| d.to_string().contains("open_file"));
    a.snapshot(&chat_a, "the file delivered", |d| {
        d["items"]
            .as_array()
            .is_some_and(|items| items.iter().any(|i| i["kind"] == "transfer" && i["state"] == "delivered"))
    });
}

/// `visible` makes themselves visible, `asker` finds them, asks; both show one code; `visible` accepts; then they talk.
pub fn visible_request(asker: &mut Client, asker_name: &str, visible: &mut Client, visible_name: &str) {
    visible.send("start_visibility", json!({}));
    let person = find_visible(asker, visible_name);
    assert_eq!(person["action"]["action"], "send_request", "{person}");
    asker.send("send_request", json!({"nearby_id": person["nearby_id"]}));
    let list_v = visible.subscribe("list", json!({}));
    let asked = visible.snapshot(&list_v, "the request arriving", |d| {
        row_titled(d, asker_name).is_some_and(|r| r["waiting"]["kind"] == "request")
    });
    let asker_in_v = conversation(&row_titled(&asked, asker_name).expect("checked"));
    let list_a = asker.subscribe("list", json!({}));
    let sent = asker.snapshot(&list_a, "the request sent", |d| row_titled(d, visible_name).is_some());
    let visible_in_a = conversation(&row_titled(&sent, visible_name).expect("checked"));
    assert_eq!(card_code(visible, &asker_in_v), card_code(asker, &visible_in_a), "one comparison code on both screens");
    visible.send("accept_request", json!({"conversation_id": asker_in_v}));
    asker.snapshot(&list_a, "the acceptance arriving", |d| {
        row_titled(d, visible_name).is_some_and(|r| r["subtitle"] != "Request sent" && r["actions"] == json!([]))
    });
    visible.send("stop_visibility", json!({}));
    talk(asker, &visible_in_a, visible, &asker_in_v);
}

/// `asker` adds `holder` by Friends ID; `holder` accepts; the callback is a request `asker` accepts (no host vouched
/// for the answer); both show one code; then they talk.
pub fn add_by_id(asker: &mut Client, holder: &mut Client) {
    let profile = holder.subscribe("profile", json!({}));
    let id = holder.snapshot(&profile, "the holder's ID", |d| d["id"]["friends_id"].is_string())["id"]["friends_id"]
        .as_str()
        .expect("checked")
        .to_owned();
    let result = asker.send("add_by_id", json!({"friends_id": id}));
    let holder_in_a = result["conversation_id"].as_str().expect("a conversation").to_owned();
    let list_h = holder.subscribe("list", json!({}));
    let asked = holder.snapshot(&list_h, "the request by ID arriving", |d| waiting_row(d).is_some());
    let asker_in_h = conversation(&waiting_row(&asked).expect("checked"));
    holder.send("accept_request", json!({"conversation_id": asker_in_h}));
    let list_a = asker.subscribe("list", json!({}));
    asker.snapshot(&list_a, "the answer arriving as a request", |d| {
        rows(d).iter().any(|r| {
            r["conversation_id"] == holder_in_a.as_str() && r["actions"].to_string().contains("accept_request")
        })
    });
    asker.send("accept_request", json!({"conversation_id": holder_in_a}));
    assert_eq!(details_code(asker, &holder_in_a), details_code(holder, &asker_in_h), "one comparison code");
    talk(asker, &holder_in_a, holder, &asker_in_h);
}

/// `visible` declines `asker`'s request: the asker's request is over, and they may ask again.
pub fn declined(asker: &mut Client, asker_name: &str, visible: &mut Client, visible_name: &str) {
    visible.send("start_visibility", json!({}));
    let person = find_visible(asker, visible_name);
    asker.send("send_request", json!({"nearby_id": person["nearby_id"]}));
    let list_v = visible.subscribe("list", json!({}));
    let asked = visible.snapshot(&list_v, "the request arriving", |d| {
        row_titled(d, asker_name).is_some_and(|r| r["waiting"]["kind"] == "request")
    });
    let asker_in_v = conversation(&row_titled(&asked, asker_name).expect("checked"));
    visible.send("decline_request", json!({"conversation_id": asker_in_v}));
    let list_a = asker.subscribe("list", json!({}));
    let sent = asker.snapshot(&list_a, "the request sent", |d| row_titled(d, visible_name).is_some());
    let visible_in_a = conversation(&row_titled(&sent, visible_name).expect("checked"));
    // Once the decline arrives, Nearby offers a new request, and withdrawing the old one is stale.
    let again = find_visible(asker, visible_name);
    assert_eq!(again["action"]["action"], "send_request");
    assert_eq!(asker.refused("cancel_request", json!({"conversation_id": visible_in_a})), "stale");
    visible.send("stop_visibility", json!({}));
}
