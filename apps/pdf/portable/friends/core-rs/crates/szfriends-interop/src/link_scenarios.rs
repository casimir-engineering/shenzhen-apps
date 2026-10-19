//! Links between any two whole helpers online (PROTOCOL.md § Links), driven as apps drive them: one makes a friend
//! link and the other adds from it, accepted at once by the maker; one makes a download link and the other receives
//! the file into its chat with the maker; plain Add by ID through the host makes a friend at once. Run between the
//! Rust helper and the Objective-C helper both ways (`tests/objc_links.rs`).

use serde_json::{json, Value};

use crate::helpers::Client;

/// The profile once the host reserved its ID and "Your links" shows the friend link.
pub fn friend_link_url(client: &mut Client) -> String {
    let profile = client.subscribe("profile", json!({}));
    let data = client.snapshot(&profile, "the friend link", |d| d["links"]["friend"]["url"].is_string());
    data["links"]["friend"]["url"].as_str().unwrap().to_owned()
}

/// What an app passes on from a link page's URL: its path's letter, a dot and its fragment.
pub fn payload(url: &str) -> String {
    let (base, fragment) = url.split_once('#').expect("a fragment");
    format!("{}.{fragment}", base.chars().last().expect("a path"))
}

fn rows(data: &Value) -> Vec<Value> {
    data["rows"].as_array().cloned().unwrap_or_default()
}

/// `maker`'s friend link, named `maker_name`, opened and added by `opener`, named `opener_name`.
pub fn friend_link(maker: &mut Client, maker_name: &str, opener: &mut Client, opener_name: &str) {
    let url = friend_link_url(maker);
    friend_link_url(opener); // the opener's own ID reserved, so the maker's callback finds it
    let link = payload(&url);
    let card = opener.send("open_link", json!({"payload": link}))["card"].clone();
    assert_eq!(card["kind"], "friend", "{card}");
    assert!(card["title"].as_str().unwrap_or_default().contains(maker_name), "{card}");
    let sent = opener.send("add_from_link", json!({"payload": link}));
    let prefix = format!("Request sent to {maker_name}.");
    assert!(sent["message"].as_str().unwrap_or_default().starts_with(&prefix), "{sent}");
    // Accepted at once on the maker's computer, whose history says how.
    let list = maker.subscribe("list", json!({}));
    // Named once the opener's profile arrived on the session the maker opens back.
    let added = maker.snapshot(&list, "the opener added through the link", |d| {
        rows(d).iter().any(|r| r["title"] == opener_name && r["waiting"].is_null())
    });
    let row = rows(&added).into_iter().find(|r| r["title"] == opener_name).expect("the opener's row");
    let chat = maker.open(row["conversation_id"].as_str().unwrap());
    maker.snapshot(&chat, "how they were added", |d| d.to_string().contains("Added through your link"));
    // The opener hears back: friends both ways.
    let conversation = sent["conversation_id"].as_str().unwrap().to_owned();
    let list = opener.subscribe("list", json!({}));
    opener.snapshot(&list, "the maker a friend", |d| {
        rows(d).iter().any(|r| {
            r["conversation_id"] == conversation.as_str()
                && r["waiting"].is_null()
                && !r["subtitle"].to_string().contains("Request sent")
        })
    });
}

/// `maker`'s download link of a file it makes, received whole by `receiver` into its chat with the maker.
pub fn download_link(maker: &mut Client, receiver: &mut Client) {
    friend_link_url(maker);
    friend_link_url(receiver);
    let path = maker.make_file("Site photos.pdf", 300_000);
    let made = maker.send("make_download_link", json!({"file": {"path": path}, "expires_days": 7}));
    let link = payload(made["url"].as_str().expect("a URL"));
    let card = receiver.send("open_link", json!({"payload": link}))["card"].clone();
    assert_eq!(card["kind"], "download", "{card}");
    let received = receiver.send("receive_link", json!({"payload": link}));
    assert!(received["message"].as_str().unwrap_or_default().contains("Site photos.pdf"), "{received}");
    let chat = receiver.open(received["conversation_id"].as_str().unwrap());
    let done = receiver.snapshot(&chat, "the file received through the link", |d| {
        d.to_string().contains("Sent you Site photos.pdf through a link") && d.to_string().contains("\"received\"")
    });
    let items = done["items"].as_array().cloned().unwrap_or_default();
    let file = items.iter().find(|i| i["kind"] == "transfer").expect("the file")["file"]["path"].clone();
    let content: Vec<u8> = (0..300_000).map(|i| (i % 251) as u8).collect();
    assert_eq!(std::fs::read(file.as_str().unwrap()).unwrap(), content, "whole");
}

/// Plain Add by ID through the host: `asker` adds `holder` by the ID the host reserved for them, `holder` accepts,
/// and the answer, which shows the host's attestation of that ID, makes `holder` a friend on `asker`'s side at once
/// (no request to accept); then a message each way.
pub fn add_by_id(asker: &mut Client, holder: &mut Client, holder_name: &str) {
    friend_link_url(asker); // the asker's own ID reserved too, as an app has it before anyone adds anyone
    let profile = holder.subscribe("profile", json!({}));
    let data = holder.snapshot(&profile, "a reserved ID", |d| d["id"]["state"] == "reserved");
    let id = data["id"]["friends_id"].as_str().unwrap().to_owned();
    let holder_in_a = asker.send("add_by_id", json!({"friends_id": id}))["conversation_id"]
        .as_str()
        .expect("a conversation")
        .to_owned();
    let list_h = holder.subscribe("list", json!({}));
    let waiting = |d: &Value| rows(d).into_iter().find(|r| r["waiting"]["kind"] == "request");
    let asked = holder.snapshot(&list_h, "the request by ID, through the host", |d| waiting(d).is_some());
    let asker_in_h = waiting(&asked).expect("checked")["conversation_id"].as_str().expect("an id").to_owned();
    holder.send("accept_request", json!({"conversation_id": asker_in_h}));
    let list_a = asker.subscribe("list", json!({}));
    let row = |d: &Value| rows(d).into_iter().find(|r| r["conversation_id"] == holder_in_a.as_str());
    let answered = asker.snapshot(&list_a, "the holder a friend at once", |d| {
        row(d).is_some_and(|r| {
            r["waiting"].is_null()
                && r["title"] == holder_name
                && !r["subtitle"].to_string().contains("Request sent")
                && !r["actions"].to_string().contains("accept_request")
        })
    });
    let shown = row(&answered).expect("checked");
    assert!(!shown["actions"].to_string().contains("accept_request"), "no request to accept: {shown}");
    let (chat_a, chat_h) = (asker.open(&holder_in_a), holder.open(&asker_in_h));
    let token = "00112233445566778899aabbccddeeff";
    asker.send("send_message", json!({"conversation_id": holder_in_a, "text": "Hello by ID", "client_token": token}));
    holder.snapshot(&chat_h, "the message", |d| d.to_string().contains("Hello by ID"));
    let token = "ffeeddccbbaa99887766554433221100";
    holder.send("send_message", json!({"conversation_id": asker_in_h, "text": "Got it", "client_token": token}));
    asker.snapshot(&chat_a, "the reply", |d| d.to_string().contains("Got it"));
}
