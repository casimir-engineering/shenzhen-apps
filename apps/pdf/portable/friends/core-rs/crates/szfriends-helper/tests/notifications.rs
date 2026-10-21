//! System notifications end to end (ADR 0017 § Verification, the Rust helper's half): helpers' services in test homes
//! on the loopback test network, each posting to its home's JSON-lines sink (`notifications.jsonl`), never to the
//! system. Three apps on one helper and a friend sending a message and an offer post one request each; a focused
//! window, previews off, reading, clicks and replies; a request and its acceptance; the person's own other computer
//! and a computer asking to join; the ask card and Settings' block.

mod clients;
mod support;

use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use clients::{join_profile, texts, Client, Temp};
use serde_json::{json, Value};
use szfriends_helper::presentation::Presentation;
use szfriends_helper::service::{seed, Service, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: helpers start one group at a time.
static START: Mutex<()> = Mutex::new(());

const PDF: (&str, &str, Option<&str>) = ("com.intuition.shenzhenpdf", "ShenzhenPDF", Some("shenzhenpdf"));
const FILES: (&str, &str, Option<&str>) = ("com.intuition.shenzhenfiles", "Shenzhen Files", Some("shenzhenfiles"));
const THREE_D: (&str, &str, Option<&str>) = ("com.shenzhen3d.viewer", "Shenzhen 3D", Some("shenzhen3d"));

/// Every whole line the sink in `home` holds: one the helper is still writing has no newline yet and is left for the
/// next read.
fn sink(home: &Path) -> Vec<Value> {
    let text = std::fs::read_to_string(home.join("notifications.jsonl")).unwrap_or_default();
    let whole = text.rfind('\n').map_or("", |end| &text[..end]);
    whole.lines().filter(|l| !l.is_empty()).map(|l| serde_json::from_str(l).expect("a JSON line")).collect()
}

/// The first line from index `from` on that `matches`, waiting for it.
fn line(home: &Path, from: usize, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(found) = sink(home).into_iter().skip(from).find(&matches) {
            return found;
        }
        assert!(Instant::now() < deadline, "no {what}; the sink holds {:?}", sink(home));
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn requests(home: &Path) -> Vec<Value> {
    sink(home).into_iter().filter(|l| l["key"].is_string()).collect()
}

fn send_text(client: &mut Client, conversation: &str, text: &str) {
    let mut token = [0u8; 16];
    szfriends_crypto::random_bytes(&mut token);
    let token: String = token.iter().map(|b| format!("{b:02x}")).collect();
    client.send("send_message", json!({"conversation_id": conversation, "text": text, "client_token": token}));
}

fn delivered(client: &mut Client, chat: &str, text: &str) {
    client.snapshot(chat, "delivered", |d| {
        d["items"].as_array().is_some_and(|items| {
            items.iter().any(|i| i.to_string().contains(text) && i["status"].to_string().contains("delivered"))
        }) || (texts(d).contains(text) && texts(d).contains("\"delivered\""))
    });
}

#[test]
fn three_apps_on_one_helper_post_once_and_follow_focus_previews_reading_and_clicks() {
    let (a, b, net) = (Temp::new("na"), Temp::new("nb"), Temp::new("nnet"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &net.0);
    std::env::remove_var("SZFRIENDS_NOTIFY_PERMISSION");
    let (bo_in_a, ada_in_b) = seed::befriend(&a.0, &b.0, ("Ada", "Bo")).expect("befriended");
    let mut ada = Client::connect(&a.0);
    let service: std::sync::Arc<dyn Presentation> =
        Service::start(&b.0, seed::test_key_store(&b.0)).expect("Bo's service");
    let server = Client::server(service.clone());
    let focus = &["notifications.focus", "notifications.ask"];
    let mut pdf = Client::join_as(&server, service.clone(), focus, PDF);
    let mut three = Client::join_as(&server, service.clone(), &[], THREE_D);
    let mut files = Client::join_as(&server, service.clone(), focus, FILES);
    drop(guard);
    assert!(pdf.welcome["capabilities"].to_string().contains("\"notifications\""), "{}", pdf.welcome);
    for client in [&mut ada, &mut pdf, &mut three, &mut files] {
        client.send("activate", json!({}));
    }

    // Settings: this computer's switches, nothing to ask (a test home's permission is granted).
    let settings = pdf.subscribe("settings", json!({}));
    let shown = pdf.snapshot(&settings, "Settings' notifications", |d| d["notifications"].is_object());
    let block = &shown["data"]["notifications"];
    assert_eq!(block["label"], "Notifications");
    assert_eq!(block["enabled"], json!({"label": "Show notifications", "value": true}));
    assert_eq!(block["preview"]["value"], true);
    assert_eq!((block["note"].as_str(), block["action"].is_null()), (Some(""), true), "{block}");
    assert!(block.get("background").is_none(), "only for hosts that can stay running");

    // A message: one request for the three apps, opening the app used last (Shenzhen Files activated last).
    let chat =
        ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].as_str().unwrap().to_owned();
    send_text(&mut ada, &bo_in_a, "Can you check the bracket?");
    let message = line(&b.0, 0, "the message's request", |l| l["kind"] == "message");
    assert_eq!(message["channel"], "messages");
    assert_eq!(message["title"], "Ada");
    assert_eq!(message["body"], "Can you check the bracket?");
    assert_eq!(message["conversation_id"], ada_in_b.as_str());
    assert_eq!(message["thread"], ada_in_b.as_str());
    assert!(message["key"].as_str().unwrap().starts_with("message:"), "{message}");
    assert!(message["time"].as_str().unwrap().ends_with('Z'), "{message}");
    assert_eq!(message["reply"], json!({"label": "Reply", "placeholder": "Message Ada", "send": "Send"}));
    let url = format!("shenzhenfiles://friends/conversation/{ada_in_b}");
    assert_eq!(message["open"], json!({"url": url, "app_id": FILES.0, "app_path": null}));
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(requests(&b.0).len(), 1, "one request, however many apps: {:?}", sink(&b.0));

    // A file offered: "Ada wants to send you Bracket.step".
    let source = a.0.join("Bracket.step");
    std::fs::write(&source, b"solid").unwrap();
    let offer = json!({"conversation_id": bo_in_a, "files": [{"path": source}], "client_token": "aaaabbbbccccdddd"});
    ada.send("send_files", offer);
    let file = line(&b.0, 0, "the offer's request", |l| l["kind"] == "file");
    assert_eq!((file["channel"].as_str(), file["title"].as_str()), (Some("files"), Some("Ada")));
    assert_eq!(file["body"], "Ada wants to send you Bracket.step");
    assert!(file["reply"].is_null() && file["key"].as_str().unwrap().starts_with("file:"), "{file}");

    // A window showing the conversation: nothing.
    pdf.send("set_focus", json!({"conversation_id": ada_in_b}));
    let before = sink(&b.0).len();
    send_text(&mut ada, &bo_in_a, "While you look");
    delivered(&mut ada, &chat, "While you look");
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(sink(&b.0).len(), before, "focused: {:?}", sink(&b.0));
    pdf.send("set_focus", json!({"conversation_id": null}));

    // Previews off: who, never what.
    pdf.send("set_notifications", json!({"preview": false}));
    let before = sink(&b.0).len();
    send_text(&mut ada, &bo_in_a, "Secret plans");
    let hidden = line(&b.0, before, "the hidden message", |l| l["kind"] == "message");
    assert_eq!((hidden["title"].as_str(), hidden["body"].as_str()), (Some("Ada"), Some("New message")));
    assert!(!std::fs::read_to_string(b.0.join("notifications.jsonl")).unwrap().contains("Secret plans"));
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(b.0.join("notify-settings.json")).unwrap()).unwrap();
    assert_eq!(saved["preview"], false, "kept on this computer: {saved}");
    pdf.send("set_notifications", json!({"preview": true}));

    // A click opens the app used last (ShenzhenPDF, which focused the conversation) on that conversation.
    let key = hidden["key"].as_str().unwrap().to_owned();
    three.send("test_notification_response", json!({"key": key, "action": "open"}));
    let opened = line(&b.0, 0, "the routed click", |l| l["opened"].is_object());
    let url = format!("shenzhenpdf://friends/conversation/{ada_in_b}");
    assert_eq!(opened["opened"], json!({"url": url, "app_id": PDF.0, "app_path": null}));
    assert_eq!(
        three.refused("test_notification_response", json!({"key": "message:nope", "action": "open"})),
        "not_found"
    );

    // A reply is sent in that conversation, which is then read: its notifications go.
    let before = sink(&b.0).len();
    three.send("test_notification_response", json!({"key": key, "action": "reply", "text": "On it"}));
    ada.snapshot(&chat, "Bo's reply at Ada", |d| texts(d).contains("On it"));
    let withdrawn = line(&b.0, before, "the withdrawal after the reply", |l| l["withdraw"].is_object());
    assert_eq!(withdrawn["withdraw"]["thread"], ada_in_b.as_str());

    // Opened in an app: read, withdrawn.
    let before = sink(&b.0).len();
    send_text(&mut ada, &bo_in_a, "One more thing");
    line(&b.0, before, "another message", |l| l["kind"] == "message");
    let before = sink(&b.0).len();
    files.send("open_conversation", json!({"conversation_id": ada_in_b}));
    line(&b.0, before, "the withdrawal after reading", |l| l["withdraw"]["thread"] == ada_in_b.as_str());

    // An app that does not say what its window shows, holding the conversation open, counts as looking at it.
    three.send("open_conversation", json!({"conversation_id": ada_in_b}));
    let before = requests(&b.0).len();
    send_text(&mut ada, &bo_in_a, "Seen in Shenzhen 3D");
    delivered(&mut ada, &chat, "Seen in Shenzhen 3D");
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(requests(&b.0).len(), before, "an open conversation in an older app is focus");
    drop((three, files, pdf));
}

#[test]
fn the_ask_card_and_the_permission_line() {
    let (home, net) = (Temp::new("ask"), Temp::new("asknet"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &home.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &net.0);
    std::env::set_var("SZFRIENDS_NOTIFY_PERMISSION", "not_asked");
    let mut mac = Client::connect_with(&home.0, &["notifications.ask", "notifications.focus"]);
    std::env::remove_var("SZFRIENDS_NOTIFY_PERMISSION");
    drop(guard);
    let list = mac.subscribe("list", json!({}));
    let first = mac.snapshot(&list, "the list", |d| d["state"].is_string());
    assert!(first["data"]["banner"].is_null(), "nothing is asked before Friends is used: {}", first["data"]["banner"]);
    mac.send("activate", json!({}));
    let card = mac.snapshot(&list, "the ask card", |d| d["banner"]["kind"] == "notifications");
    let banner = &card["data"]["banner"];
    assert_eq!(banner["text"], "Get a notification when friends send you a message or a file.");
    assert_eq!(banner["action"], json!({"action": "allow_notifications", "label": "Turn On", "style": "primary"}));
    assert_eq!(
        banner["dismiss"],
        json!({"action": "dismiss_banner", "label": "Not Now", "style": "link", "kind": "notifications"})
    );
    let settings = mac.subscribe("settings", json!({}));
    let shown = mac.snapshot(&settings, "the permission line", |d| d["notifications"].is_object());
    let block = &shown["data"]["notifications"];
    assert_eq!(block["note"], "Friends hasn’t asked to show notifications yet.");
    assert_eq!(block["action"], json!({"action": "allow_notifications", "label": "Allow", "style": "secondary"}));

    mac.send("allow_notifications", json!({}));
    line(&home.0, 0, "the ask", |l| l["asked"] == true);
    mac.send("dismiss_banner", json!({"kind": "notifications"}));
    mac.snapshot(&list, "Not Now, for good", |d| d["banner"].is_null());
    mac.send("set_notifications", json!({"enabled": false}));
    mac.snapshot(&settings, "switched off", |d| d["notifications"]["enabled"]["value"] == false);
    let saved = std::fs::read_to_string(home.0.join("notify-settings.json")).unwrap();
    assert!(saved.contains("\"ask_dismissed\":true") && saved.contains("\"enabled\":false"), "{saved}");
    assert_eq!(mac.refused("set_notifications", json!({"enabled": "yes"})), "invalid_field");
}

#[test]
fn a_request_and_its_acceptance_each_notify_the_one_they_concern() {
    let homes = (Temp::new("ra"), Temp::new("rb"), Temp::new("rnet"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &homes.0 .0);
    std::env::set_var(ENV_TEST_LOOPBACK, &homes.2 .0);
    std::env::remove_var("SZFRIENDS_NOTIFY_PERMISSION");
    let focus = ["notifications.focus"];
    let mut ada = Client::connect_with(&homes.0 .0, &focus);
    let mut bo = Client::connect_with(&homes.1 .0, &focus);
    drop(guard);
    for (client, name) in [(&mut ada, "Ada"), (&mut bo, "Bo")] {
        client.send("set_name", json!({"name": name}));
        client.send("activate", json!({}));
    }
    ada.send("start_visibility", json!({}));
    let nearby = bo.subscribe("nearby", json!({}));
    let seen = bo.snapshot(&nearby, "Ada nearby", |d| {
        d["people"].as_array().is_some_and(|p| p.iter().any(|p| p["title"] == "Ada" && p["nearby_id"].is_string()))
    });
    let person = seen["data"]["people"].as_array().unwrap().iter().find(|p| p["title"] == "Ada").unwrap().clone();
    bo.send("send_request", json!({"nearby_id": person["nearby_id"]}));

    let request = line(&homes.0 .0, 0, "Bo's request at Ada", |l| l["kind"] == "request");
    assert_eq!((request["title"].as_str(), request["body"].as_str()), (Some("Bo"), Some("Wants to be friends")));
    assert_eq!(request["channel"], "requests");
    let bo_in_a = request["conversation_id"].as_str().unwrap().to_owned();
    assert!(request["key"].as_str().unwrap().starts_with(&format!("request:{bo_in_a}:")), "{request}");
    ada.send("accept_request", json!({"conversation_id": bo_in_a}));
    let accepted = line(&homes.1 .0, 0, "the acceptance at Bo", |l| l["kind"] == "request");
    assert_eq!(accepted["body"], "Accepted your friend request");
    assert_eq!(accepted["title"], "Ada");
    ada.send("stop_visibility", json!({}));
    assert!(
        requests(&homes.0 .0).iter().all(|r| r["body"] != "Accepted your friend request"),
        "Ada accepted it herself"
    );
    assert!(requests(&homes.1 .0).iter().all(|r| r["body"] != "Wants to be friends"), "Bo asked, nobody asked Bo");
}

#[test]
fn the_persons_own_computers_never_notify_what_they_did() {
    let (a, b, c, net) = (Temp::new("oa"), Temp::new("ob"), Temp::new("oc"), Temp::new("onet"));
    let guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &a.0);
    std::env::set_var(ENV_TEST_LOOPBACK, &net.0);
    std::env::remove_var("SZFRIENDS_NOTIFY_PERMISSION");
    let focus = ["notifications.focus"];
    let mut ada = Client::connect_with(&a.0, &focus);
    let mut other = Client::connect_with(&b.0, &focus);
    let mut cy = Client::connect_with(&c.0, &focus);
    drop(guard);
    for (client, name) in [(&mut ada, Some("Ada")), (&mut other, None), (&mut cy, Some("Cy"))] {
        if let Some(name) = name {
            client.send("set_name", json!({"name": name}));
        }
        client.send("activate", json!({}));
    }
    let profile = ada.subscribe("profile", json!({}));
    let ada_id = ada.snapshot(&profile, "Ada's ID", |d| d["id"]["friends_id"].is_string())["data"]["id"]["friends_id"]
        .as_str()
        .unwrap()
        .to_owned();
    join_profile(&mut ada, &ada_id, &mut other);
    let join = line(&a.0, 0, "the computer asking to join", |l| l["kind"] == "join");
    assert!(join["title"].as_str().unwrap().ends_with(" wants to join your profile"), "{join}");
    assert_eq!(join["body"], "Approve it in Friends only if you’re setting it up now.");
    assert!(join["conversation_id"].is_null() && join["reply"].is_null(), "{join}");
    assert_eq!(join["open"]["url"], "shenzhen3d://friends");

    // Cy and Ada become friends on Ada's first computer.
    ada.send("start_visibility", json!({}));
    let nearby = cy.subscribe("nearby", json!({}));
    let seen = cy.snapshot(&nearby, "Ada visible to Cy", |d| {
        d["people"].as_array().is_some_and(|p| p.iter().any(|p| p["title"] == "Ada" && p["nearby_id"].is_string()))
    });
    let person = seen["data"]["people"].as_array().unwrap().iter().find(|p| p["title"] == "Ada").unwrap().clone();
    cy.send("send_request", json!({"nearby_id": person["nearby_id"]}));
    let request = line(&a.0, 0, "Cy's request", |l| l["kind"] == "request");
    let cy_in_a = request["conversation_id"].as_str().unwrap().to_owned();
    ada.send("accept_request", json!({"conversation_id": cy_in_a}));
    ada.send("stop_visibility", json!({}));
    let list_b = other.subscribe("list", json!({}));
    other.snapshot(&list_b, "Cy on the other computer", |d| texts(d).contains("Cy"));

    // Ada writes to Cy from her first computer: her other computer hears of it by sync, and says nothing.
    send_text(&mut ada, &cy_in_a, "From my laptop");
    let list_c = cy.subscribe("list", json!({}));
    cy.snapshot(&list_c, "Ada's message at Cy", |d| texts(d).contains("From my laptop"));
    other.snapshot(&list_b, "Ada's own message on the other computer", |d| texts(d).contains("From my laptop"));
    std::thread::sleep(Duration::from_millis(1500));
    assert!(requests(&b.0).iter().all(|r| r["kind"] != "message"), "her own message: {:?}", requests(&b.0));
    assert!(requests(&a.0).iter().all(|r| r["kind"] != "message"));
    // Cy answers: fresh news on the computer it reached, and on the other by sync.
    let ada_in_c = cy.snapshot(&list_c, "Ada", |d| texts(d).contains("Ada"))["data"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["title"] == "Ada")
        .unwrap()["conversation_id"]
        .as_str()
        .unwrap()
        .to_owned();
    send_text(&mut cy, &ada_in_c, "Got it");
    let at_first = line(&a.0, 0, "Cy's message at the first computer", |l| l["kind"] == "message");
    assert_eq!((at_first["title"].as_str(), at_first["body"].as_str()), (Some("Cy"), Some("Got it")));
}
