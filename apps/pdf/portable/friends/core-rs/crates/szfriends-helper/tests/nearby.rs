//! Nearby end to end between two Rust helpers' services in test homes, on a test network of entries on loopback
//! (ADR 0004): a person visible for their 5 minutes found by someone browsing, a friend request with matching
//! comparison codes, accepted, then messages both ways once each holds the other's presence secret; Add by ID, its
//! callback becoming a request the asker accepts (no host vouched for the answer), then messages; a declined request;
//! a withdrawn one; a friend removed and asked again, from Nearby or by Friends ID, whose helper never learned of the
//! removal and accepts at once.

mod clients;
mod support;

use std::sync::Mutex;

use clients::{Client, Temp};
use serde_json::{json, Value};
use szfriends_helper::service::ENV_TEST_LOOPBACK;
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: helpers start one pair at a time.
static START: Mutex<()> = Mutex::new(());

/// Bound `_homes` first wherever it is taken apart, so the homes outlive the services using them (Windows keeps a
/// directory whose files are open).
struct Pair {
    a: Client,
    b: Client,
    _homes: (Temp, Temp, Temp),
}

fn start(names: (&str, &str)) -> Pair {
    let homes = (Temp::new("na"), Temp::new("nb"), Temp::new("net"));
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &homes.0 .0);
    std::env::set_var(ENV_TEST_LOOPBACK, &homes.2 .0);
    let mut a = Client::connect(&homes.0 .0);
    let mut b = Client::connect(&homes.1 .0);
    for (client, name) in [(&mut a, names.0), (&mut b, names.1)] {
        client.send("set_name", json!({"name": name}));
        client.send("activate", json!({}));
    }
    Pair { a, b, _homes: homes }
}

fn rows(data: &Value) -> Vec<Value> {
    data["rows"].as_array().cloned().unwrap_or_default()
}

fn row_titled<'a>(data: &'a Value, title: &str) -> Option<&'a Value> {
    data["rows"].as_array()?.iter().find(|r| r["title"] == title)
}

fn friends_id(client: &mut Client) -> String {
    let profile = client.subscribe("profile", json!({}));
    let data = client.snapshot(&profile, "the profile", |d| d["id"]["friends_id"].is_string());
    data["data"]["id"]["friends_id"].as_str().unwrap().to_owned()
}

/// Both sides of a new friendship show the same six digits before anyone accepts.
fn codes_match(a: &mut Client, a_conversation: &str, b: &mut Client, b_conversation: &str) {
    let chat_a = a.send("open_conversation", json!({"conversation_id": a_conversation}))["subscription"].to_string();
    let chat_b = b.send("open_conversation", json!({"conversation_id": b_conversation}))["subscription"].to_string();
    let code = |d: &Value| d["request"]["comparison_code"].as_str().map(str::to_owned);
    let at_a = a.snapshot(chat_a.trim_matches('"'), "a code at A", |d| code(d).is_some());
    let at_b = b.snapshot(chat_b.trim_matches('"'), "a code at B", |d| code(d).is_some());
    assert_eq!(code(&at_a["data"]), code(&at_b["data"]), "the comparison codes match");
}

fn message_both_ways(a: &mut Client, a_conversation: &str, b: &mut Client, b_conversation: &str) {
    let chat_b = b.send("open_conversation", json!({"conversation_id": b_conversation}))["subscription"].to_string();
    let token = "0123456789abcdef0123456789abcdef";
    a.send(
        "send_message",
        json!({"conversation_id": a_conversation, "text": "Hello over nearby", "client_token": token}),
    );
    b.snapshot(chat_b.trim_matches('"'), "the message at B", |d| d.to_string().contains("Hello over nearby"));
    let chat_a = a.send("open_conversation", json!({"conversation_id": a_conversation}))["subscription"].to_string();
    let token = "fedcba9876543210fedcba9876543210";
    b.send("send_message", json!({"conversation_id": b_conversation, "text": "And back", "client_token": token}));
    a.snapshot(chat_a.trim_matches('"'), "the reply at A", |d| d.to_string().contains("And back"));
}

#[test]
fn a_visible_person_found_asked_and_accepted() {
    let Pair { _homes, a: mut ada, b: mut bo } = start(("Ada", "Bo"));
    // No Bluetooth here: the helper says so, and Nearby says nothing of it.
    let capabilities = bo.welcome["capabilities"].as_array().cloned().unwrap_or_default();
    assert!(!capabilities.contains(&json!("nearby.bluetooth")), "{capabilities:?}");
    let deadline = ada.send("start_visibility", json!({}))["deadline"].clone();
    assert!(deadline.is_string(), "a deadline: {deadline}");
    let nearby = bo.subscribe("nearby", json!({}));
    let seen = bo.snapshot(&nearby, "Ada visible in Bo's Nearby", |d| {
        d["people"].as_array().is_some_and(|p| p.iter().any(|p| p["title"] == "Ada" && p["nearby_id"].is_string()))
    });
    let person = seen["data"]["people"].as_array().unwrap().iter().find(|p| p["title"] == "Ada").unwrap().clone();
    assert_eq!(person["action"]["action"], "send_request", "{person}");
    bo.send("send_request", json!({"nearby_id": person["nearby_id"]}));

    let list_a = ada.subscribe("list", json!({}));
    let asked = ada.snapshot(&list_a, "Bo's request at Ada", |d| row_titled(d, "Bo").is_some());
    let bo_in_a = row_titled(&asked["data"], "Bo").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    let list_b = bo.subscribe("list", json!({}));
    let sent = bo.snapshot(&list_b, "Ada's row at Bo", |d| row_titled(d, "Ada").is_some());
    let ada_in_b = row_titled(&sent["data"], "Ada").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    codes_match(&mut ada, &bo_in_a, &mut bo, &ada_in_b);

    ada.send("accept_request", json!({"conversation_id": bo_in_a}));
    bo.snapshot(&list_b, "Ada a friend at Bo", |d| {
        row_titled(d, "Ada").is_some_and(|r| r["waiting"].is_null() && r["subtitle"] != "Request sent")
    });
    ada.send("stop_visibility", json!({}));
    message_both_ways(&mut ada, &bo_in_a, &mut bo, &ada_in_b);
    assert!(rows(&ada.snapshot(&list_a, "the list", |_| true)["data"]).len() == 1);
}

#[test]
fn add_by_id_answered_and_accepted() {
    let Pair { _homes, a: mut cleo, b: mut dan } = start(("Cleo", "Dan"));
    let dan_id = friends_id(&mut dan);
    let result = cleo.send("add_by_id", json!({"friends_id": dan_id}));
    let dan_in_c = result["conversation_id"].as_str().unwrap().to_owned();
    assert!(result["message"].as_str().is_some_and(|m| m.contains("Request sent")), "{result}");

    let list_d = dan.subscribe("list", json!({}));
    // A request by ID names nobody until its sender's profile arrives: the row waiting for Dan.
    let waiting = |d: &Value| rows(d).into_iter().find(|r| r["waiting"]["kind"] == "request");
    let asked = dan.snapshot(&list_d, "Cleo's request by ID at Dan", |d| waiting(d).is_some());
    let cleo_in_d = waiting(&asked["data"]).unwrap()["conversation_id"].as_str().unwrap().to_owned();
    dan.send("accept_request", json!({"conversation_id": cleo_in_d}));

    // Dan's helper calls Cleo back with her token; no host vouched for the answer, so it is a request Cleo accepts.
    let list_c = cleo.subscribe("list", json!({}));
    let answered = cleo.snapshot(&list_c, "Dan's answer at Cleo", |d| {
        row_titled(d, "Dan").is_some_and(|r| r["actions"].to_string().contains("accept_request"))
    });
    let dan_row = row_titled(&answered["data"], "Dan").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    assert_eq!(dan_row, dan_in_c, "the request's own row took the answering key");
    cleo.send("accept_request", json!({"conversation_id": dan_in_c}));
    // Dan accepted before Cleo saw a card, so both compare the code the callback derived in their details.
    let code = |client: &mut Client, conversation: &str| {
        let details = client.subscribe("details", json!({"conversation_id": conversation}));
        let data =
            client.snapshot(&details, "a code in the details", |d| d["verification"]["comparison_code"].is_string());
        data["data"]["verification"]["comparison_code"].clone()
    };
    assert_eq!(code(&mut cleo, &dan_in_c), code(&mut dan, &cleo_in_d), "the comparison codes match");
    message_both_ways(&mut cleo, &dan_in_c, &mut dan, &cleo_in_d);
}

#[test]
fn a_declined_and_a_withdrawn_request() {
    let Pair { _homes, a: mut eve, b: mut finn } = start(("Eve", "Finn"));
    eve.send("start_visibility", json!({}));
    let nearby = finn.subscribe("nearby", json!({}));
    let seen = finn.snapshot(&nearby, "Eve visible", |d| {
        d["people"].as_array().is_some_and(|p| p.iter().any(|p| p["title"] == "Eve" && p["nearby_id"].is_string()))
    });
    let person = seen["data"]["people"].as_array().unwrap().iter().find(|p| p["title"] == "Eve").unwrap().clone();
    finn.send("send_request", json!({"nearby_id": person["nearby_id"]}));
    let list_e = eve.subscribe("list", json!({}));
    let asked = eve.snapshot(&list_e, "Finn's request", |d| row_titled(d, "Finn").is_some());
    let finn_in_e = row_titled(&asked["data"], "Finn").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    eve.send("decline_request", json!({"conversation_id": finn_in_e}));
    assert_eq!(eve.refused("accept_request", json!({"conversation_id": finn_in_e})), "stale");
    let list_f = finn.subscribe("list", json!({}));
    let eve_in_f = {
        let data = finn.snapshot(&list_f, "Eve's row at Finn", |d| row_titled(d, "Eve").is_some());
        row_titled(&data["data"], "Eve").unwrap()["conversation_id"].as_str().unwrap().to_owned()
    };
    // The decline reaches Finn: his request is over, and he may ask again.
    finn.snapshot(&list_f, "the decline at Finn", |d| {
        row_titled(d, "Eve").is_none_or(|r| r["subtitle"] != "Request sent")
    });
    assert_eq!(finn.refused("cancel_request", json!({"conversation_id": eve_in_f})), "stale");

    // Asked again, then withdrawn: Eve's request card goes away.
    let seen = finn.snapshot(&nearby, "Eve still visible", |d| {
        d["people"].as_array().is_some_and(|p| p.iter().any(|p| p["title"] == "Eve" && p["nearby_id"].is_string()))
    });
    let person = seen["data"]["people"].as_array().unwrap().iter().find(|p| p["title"] == "Eve").unwrap().clone();
    finn.send("send_request", json!({"nearby_id": person["nearby_id"]}));
    eve.snapshot(&list_e, "Finn asks again", |d| {
        row_titled(d, "Finn").is_some_and(|r| r["actions"].to_string().contains("accept_request"))
    });
    finn.send("cancel_request", json!({"conversation_id": eve_in_f}));
    eve.snapshot(&list_e, "the withdrawal at Eve", |d| {
        row_titled(d, "Finn").is_none_or(|r| !r["actions"].to_string().contains("accept_request"))
    });
}

/// Whoever is visible in `asker`'s Nearby under `title`, asked from there.
fn ask_from_nearby(asker: &mut Client, title: &str) {
    let nearby = asker.subscribe("nearby", json!({}));
    let visible = |d: &Value| {
        d["people"]
            .as_array()
            .and_then(|p| p.iter().find(|p| p["title"] == title && p["nearby_id"].is_string()))
            .cloned()
    };
    let seen = asker.snapshot(&nearby, "visible in Nearby", |d| visible(d).is_some());
    asker.send("send_request", json!({"nearby_id": visible(&seen["data"]).unwrap()["nearby_id"]}));
}

fn friend(d: &Value, title: &str) -> bool {
    row_titled(d, title).is_some_and(|r| r["drop_label"].is_string())
}

/// Ada visible, Bo asks, Ada accepts, a message each way: (Bo's conversation at Ada, Ada's at Bo, the two lists).
fn befriended(ada: &mut Client, bo: &mut Client) -> (String, String, String, String) {
    ada.send("start_visibility", json!({}));
    ask_from_nearby(bo, "Ada");
    let list_a = ada.subscribe("list", json!({}));
    let asked = ada.snapshot(&list_a, "Bo's request at Ada", |d| row_titled(d, "Bo").is_some());
    let bo_in_a = row_titled(&asked["data"], "Bo").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    ada.send("accept_request", json!({"conversation_id": bo_in_a}));
    ada.send("stop_visibility", json!({}));
    let list_b = bo.subscribe("list", json!({}));
    let data = bo.snapshot(&list_b, "Ada a friend at Bo", |d| friend(d, "Ada"));
    let ada_in_b = row_titled(&data["data"], "Ada").unwrap()["conversation_id"].as_str().unwrap().to_owned();
    message_both_ways(ada, &bo_in_a, bo, &ada_in_b);
    (bo_in_a, ada_in_b, list_a, list_b)
}

#[test]
fn a_removed_friend_asked_again_accepts_at_once_and_the_conversation_goes_on() {
    let Pair { _homes, a: mut ada, b: mut bo } = start(("Ada", "Bo"));
    let (bo_in_a, ada_in_b, list_a, list_b) = befriended(&mut ada, &mut bo);

    // Ada removes Bo, which tells him nothing: he writes to her meanwhile, and it waits.
    ada.send("remove_friend", json!({"conversation_id": bo_in_a}));
    ada.snapshot(&list_a, "Bo off Ada's list", |d| row_titled(d, "Bo").is_none());
    let token = "0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a";
    bo.send("send_message", json!({"conversation_id": ada_in_b, "text": "Still there?", "client_token": token}));

    // Bo is visible and Ada asks again. His helper still has her as a friend: it accepts at once, so no request
    // waits at Bo, and Ada's row is a friend again, in the same conversation.
    bo.send("start_visibility", json!({}));
    ask_from_nearby(&mut ada, "Bo");
    let again = ada.snapshot(&list_a, "Bo a friend again at Ada", |d| friend(d, "Bo"));
    assert_eq!(row_titled(&again["data"], "Bo").unwrap()["conversation_id"], bo_in_a.as_str());
    let at_b = bo.snapshot(&list_b, "Bo's list", |_| true);
    assert!(row_titled(&at_b["data"], "Ada").is_some_and(|r| r["waiting"].is_null()), "{}", at_b["data"]);
    bo.send("stop_visibility", json!({}));

    // What Bo wrote while removed arrives, and so does what he writes now.
    let chat_a = ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].to_string();
    let token = "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b";
    bo.send("send_message", json!({"conversation_id": ada_in_b, "text": "Good to be back", "client_token": token}));
    ada.snapshot(chat_a.trim_matches('"'), "both of Bo's messages at Ada", |d| {
        let text = d.to_string();
        text.contains("Still there?") && text.contains("Good to be back")
    });
}

#[test]
fn someone_removed_who_removes_too_and_asks_again_is_an_ordinary_request() {
    let Pair { _homes, a: mut ada, b: mut bo } = start(("Ada", "Bo"));
    let (bo_in_a, ada_in_b, _, list_b) = befriended(&mut ada, &mut bo);
    // Bo removes Ada; Ada, never told, removes Bo too and asks him again (Bo asked first, so Ada asks now: neither
    // listener takes more XX from one address in a minute than its admissions allow).
    bo.send("remove_friend", json!({"conversation_id": ada_in_b}));
    ada.send("remove_friend", json!({"conversation_id": bo_in_a}));
    // Bo's removal ended their session, which Ada's helper holds against dialing him for up to half a minute; a
    // restart forgets that, as it would long before anyone asks again.
    drop(ada);
    let mut ada = {
        let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var(ENV_STATE_DIR, &_homes.0 .0);
        std::env::set_var(ENV_TEST_LOOPBACK, &_homes.2 .0);
        Client::connect(&_homes.0 .0)
    };
    let list_a = ada.subscribe("list", json!({}));
    ada.snapshot(&list_a, "Bo off Ada's list", |d| row_titled(d, "Bo").is_none());
    bo.send("start_visibility", json!({}));
    ask_from_nearby(&mut ada, "Bo");
    // Bo gets an ordinary request card, on Ada's old row; accepting it makes them friends again.
    let asked = bo.snapshot(&list_b, "Ada's new request at Bo", |d| {
        row_titled(d, "Ada").is_some_and(|r| r["actions"].to_string().contains("accept_request"))
    });
    assert_eq!(row_titled(&asked["data"], "Ada").unwrap()["conversation_id"], ada_in_b.as_str());
    bo.send("accept_request", json!({"conversation_id": ada_in_b}));
    bo.send("stop_visibility", json!({}));
    ada.snapshot(&list_a, "Bo a friend again at Ada", |d| friend(d, "Bo"));
    let chat_b = bo.send("open_conversation", json!({"conversation_id": ada_in_b}))["subscription"].to_string();
    let token = "0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c";
    ada.send("send_message", json!({"conversation_id": bo_in_a, "text": "Friends again", "client_token": token}));
    bo.snapshot(chat_b.trim_matches('"'), "Ada's message at Bo", |d| d.to_string().contains("Friends again"));
}

#[test]
fn a_removed_friend_asked_again_by_friends_id_accepts_at_once() {
    let Pair { _homes, a: mut ada, b: mut bo } = start(("Ada", "Bo"));
    let (bo_in_a, ada_in_b, list_a, _) = befriended(&mut ada, &mut bo);
    let bo_id = friends_id(&mut bo);

    // Ada removes Bo, which tells him nothing: he writes to her meanwhile, and it waits.
    ada.send("remove_friend", json!({"conversation_id": bo_in_a}));
    ada.snapshot(&list_a, "Bo off Ada's list", |d| row_titled(d, "Bo").is_none());
    let token = "0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d";
    bo.send("send_message", json!({"conversation_id": ada_in_b, "text": "Still there?", "client_token": token}));
    // Ada's removal ended their session, which Bo's helper holds against dialing her for up to half a minute; a
    // restart forgets that, as it would long before anyone asks again.
    drop(bo);
    let mut bo = {
        let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var(ENV_STATE_DIR, &_homes.1 .0);
        std::env::set_var(ENV_TEST_LOOPBACK, &_homes.2 .0);
        Client::connect(&_homes.1 .0)
    };
    let list_b = bo.subscribe("list", json!({}));

    // Ada asks again by his Friends ID. His helper still has her as a friend: it answers with an acceptance, so no
    // request waits at Bo. No host vouched for the answer, so Ada accepts it herself (with a host it would be at once);
    // then Ada's row is a friend again, in the same conversation.
    ada.send("add_by_id", json!({"friends_id": bo_id}));
    let answered = ada.snapshot(&list_a, "Bo's answer at Ada", |d| {
        row_titled(d, "Bo").is_some_and(|r| r["actions"].to_string().contains("accept_request"))
    });
    assert_eq!(row_titled(&answered["data"], "Bo").unwrap()["conversation_id"], bo_in_a.as_str());
    ada.send("accept_request", json!({"conversation_id": bo_in_a}));
    let again = ada.snapshot(&list_a, "Bo a friend again at Ada", |d| friend(d, "Bo"));
    assert_eq!(row_titled(&again["data"], "Bo").unwrap()["conversation_id"], bo_in_a.as_str());
    assert_eq!(rows(&again["data"]).len(), 1, "one row for Bo: {}", again["data"]);
    let at_b = bo.snapshot(&list_b, "Bo's list", |_| true);
    assert!(row_titled(&at_b["data"], "Ada").is_some_and(|r| r["waiting"].is_null()), "{}", at_b["data"]);

    // What Bo wrote while removed arrives, and so does what he writes now.
    let chat_a = ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].to_string();
    let token = "0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e";
    bo.send("send_message", json!({"conversation_id": ada_in_b, "text": "Good to be back", "client_token": token}));
    ada.snapshot(chat_a.trim_matches('"'), "both of Bo's messages at Ada", |d| {
        let text = d.to_string();
        text.contains("Still there?") && text.contains("Good to be back")
    });
}
