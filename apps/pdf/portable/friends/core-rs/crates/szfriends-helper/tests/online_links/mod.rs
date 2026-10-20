//! Links between two Rust helpers online (PROTOCOL.md § Links): a friend link, and a download link received.

use std::path::Path;

use serde_json::{json, Value};
use szfriends_helper::state::ENV_STATE_DIR;

use crate::clients::{texts, Client, Temp};

/// The profile once the host reserved its ID and "Your links" shows the friend link.
fn friend_link_url(client: &mut Client) -> String {
    let profile = client.subscribe("profile", json!({}));
    let data = client.snapshot(&profile, "the friend link", |d| d["links"]["friend"]["url"].is_string());
    data["data"]["links"]["friend"]["url"].as_str().unwrap().to_owned()
}

/// What an app passes on from a link page's URL: its path's letter, a dot and its fragment.
fn payload(url: &str) -> String {
    let (base, fragment) = url.split_once('#').unwrap();
    format!("{}.{fragment}", base.chars().last().unwrap())
}

fn rows(data: &Value) -> Vec<Value> {
    data["rows"].as_array().cloned().unwrap_or_default()
}

/// Ada's friend link opened by Bo: the card, Add, accepted at once on Ada's computer; then reset.
pub fn friend_link() {
    let (a, b) = (Temp::new("flink-a"), Temp::new("flink-b"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    let mut ada = Client::connect(&a.0);
    let mut bo = Client::connect(&b.0);
    assert!(ada.welcome["capabilities"].to_string().contains("\"links\""), "{}", ada.welcome);
    ada.send("set_name", json!({"name": "Ada"}));
    bo.send("set_name", json!({"name": "Bo"}));
    let url = friend_link_url(&mut ada);
    assert!(url.starts_with("http://127.0.0.1:") && url.contains("/f#"), "{url}");
    friend_link_url(&mut bo); // Bo's own ID reserved, so Ada's callback finds him
    let link = payload(&url);
    let card = bo.send("open_link", json!({"payload": link}))["card"].clone();
    assert_eq!(card["kind"], "friend", "{card}");
    assert!(card["title"].as_str().unwrap().contains("Ada"), "{card}");
    assert_eq!(card["actions"][0]["action"], "add_from_link", "{card}");
    let sent = bo.send("add_from_link", json!({"payload": link}));
    assert!(sent["message"].as_str().unwrap().starts_with("Request sent to Ada."), "{sent}");
    // Ada's computer accepts at once: Bo is her friend with no request waiting, and her history says how.
    let list_a = ada.subscribe("list", json!({}));
    let wait = std::time::Duration::from_secs(75);
    let added = ada.snapshot_within(&list_a, "Bo added through the link", wait, |d| {
        rows(d).iter().any(|r| r["title"] == "Bo" && r["waiting"].is_null())
    });
    let bo_in_a = rows(&added["data"]).iter().find(|r| r["title"] == "Bo").unwrap()["conversation_id"].clone();
    let chat = ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].clone();
    ada.snapshot(chat.as_str().unwrap(), "how Bo was added", |d| texts(d).contains("Added through your link"));
    // Bo hears back and is Ada's friend too.
    let list_b = bo.subscribe("list", json!({}));
    let ada_in_b = sent["conversation_id"].as_str().unwrap().to_owned();
    bo.snapshot_within(&list_b, "Ada a friend at Bo", wait, |d| {
        rows(d).iter().any(|r| {
            r["conversation_id"] == ada_in_b.as_str()
                && r["waiting"].is_null()
                && !r["subtitle"].to_string().contains("Request sent")
        })
    });
    // Reset: a new link, the old one no longer Ada's.
    ada.send("reset_friend_link", json!({}));
    let profile = ada.subscribe("profile", json!({}));
    ada.snapshot(&profile, "a new friend link", |d| d["links"]["friend"]["url"].as_str().is_some_and(|u| u != url));
    // Ada opening her own link is told it is hers.
    assert_eq!(ada.refused("open_link", json!({"payload": payload(&url)})), "id_is_yours");
}

/// Ada's download link received by Bo: the file in Bo's chat with Ada, whole, said to come through a link.
pub fn receive_link() {
    let (a, b, files) = (Temp::new("rlink-a"), Temp::new("rlink-b"), Temp::new("rlink-files"));
    std::env::set_var(ENV_STATE_DIR, &a.0);
    let mut ada = Client::connect(&a.0);
    let mut bo = Client::connect(&b.0);
    ada.send("set_name", json!({"name": "Ada"}));
    friend_link_url(&mut ada);
    friend_link_url(&mut bo);
    let path = files.0.join("Site photos.pdf");
    let content: Vec<u8> = (0..200_000u32).map(|i| (i % 253) as u8).collect();
    std::fs::write(&path, &content).unwrap();
    let made = ada.send("make_download_link", json!({"file": {"path": path.to_string_lossy()}, "expires_days": 7}));
    let link = payload(made["url"].as_str().unwrap());
    let card = bo.send("open_link", json!({"payload": link}))["card"].clone();
    assert_eq!(
        (card["kind"].as_str(), card["actions"][0]["action"].as_str()),
        (Some("download"), Some("receive_link"))
    );
    let received = bo.send("receive_link", json!({"payload": link}));
    assert!(received["message"].as_str().unwrap().contains("Site photos.pdf"), "{received}");
    let chat =
        bo.send("open_conversation", json!({"conversation_id": received["conversation_id"]}))["subscription"].clone();
    let done = bo.snapshot(chat.as_str().unwrap(), "the file received through the link", |d| {
        texts(d).contains("Sent you Site photos.pdf through a link") && texts(d).contains("\"received\"")
    });
    let items = done["data"]["items"].as_array().cloned().unwrap_or_default();
    let file = items.iter().find(|i| i["kind"] == "transfer").expect("the file")["file"]["path"].clone();
    assert_eq!(std::fs::read(file.as_str().unwrap()).unwrap(), content, "whole");
    assert_eq!(Path::new(file.as_str().unwrap()).parent(), Some(b.0.join("Downloads").as_path()), "in Downloads");
    // Listed for hosts' recent files, as a link's file.
    let view = bo.send("subscribe", json!({"view": "received"}))["subscription"].clone();
    let listed = bo.snapshot(view.as_str().unwrap(), "the link's file listed", |d| {
        d["files"].as_array().is_some_and(|files| !files.is_empty())
    });
    assert_eq!(listed["data"]["files"][0]["source"], "link");
    assert_eq!(listed["data"]["files"][0]["file_name"], "Site photos.pdf");
    // Ada is not Bo's friend: the file offers Add.
    assert!(items.iter().any(|i| i["actions"].to_string().contains("add_from_mention")), "{items:?}");
    // Revoked: Bo is told it ended.
    ada.send("revoke_link", json!({"link_id": made["link_id"]}));
    std::thread::sleep(std::time::Duration::from_secs(1));
    assert_eq!(bo.refused("receive_link", json!({"payload": link})), "not_found");
}
