//! Online friends state by state (`SZFriendsPresentationOnlineTests.m`), joining in every state
//! (`...JoinTests.m`), the person who sent a file through a link (`...LinksTests.m`), and the words of several
//! computers (`...DevicesTests.m`): reader words only, every several-computer history line saying where it reaches.

mod presentation;

use std::collections::HashMap;

use presentation::validate_snapshot;
use presentation::world::*;
use serde_json::{json, Value};
use szfriends_core::presentation::catalog;
use szfriends_core::presentation::{
    event, Audience, ItemFacts, JoinRequestFacts, JoiningFacts, JoiningState, OnlineReach, PersonFacts, Relation,
    RouteKind, RouteMethod, Strings, TransferState,
};

fn online_audience() -> Audience {
    let mut audience = audience();
    audience.helper_capabilities = ["nearby.network", "host.checkin", "online"].iter().map(|s| s.to_string()).collect();
    audience
}

fn priya(reach: OnlineReach) -> PersonFacts {
    PersonFacts { online_reach: reach, ..people()["c_priya"].clone() }
}

fn conversation(audience: Audience, person: &PersonFacts, items: &[ItemFacts], label: &str) -> Value {
    let data = builder(audience).conversation(person, items, false, None, 2, now());
    validate_snapshot(&data, "conversation", label);
    data
}

fn item<'a>(conversation: &'a Value, id: &str) -> &'a Value {
    conversation["items"].as_array().unwrap().iter().find(|i| i["item_id"] == id).expect(id)
}

#[test]
fn m1_says_nothing_of_online() {
    if presentation::tree_missing() {
        return;
    }
    let data = conversation(audience(), &priya(OnlineReach::Connecting), &items_for("c_priya"), "m1 connecting");
    assert_eq!(data["header"]["route"], json!({"kind": "offline", "method": null, "label": "Not nearby right now"}));
    assert_eq!(
        data["composer"]["note"],
        "Messages and files send when Priya is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open."
    );
    assert_eq!(item(&data, "m_c4d27a19")["status"]["label"], "Sends when Priya is nearby");
    let data = conversation(audience(), &priya(OnlineReach::Unreachable), &[], "m1 unreachable");
    assert_eq!(data["header"]["subtitle"], "Not nearby right now");
    assert_eq!(
        Strings::new(audience()).static_strings()["queued_note"],
        "Messages and files send when {first} is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open."
    );
}

#[test]
fn online_routes() {
    if presentation::tree_missing() {
        return;
    }
    let mut mei = PersonFacts { route_method: RouteMethod::Internet, ..people()["c_mei"].clone() };
    let data = conversation(online_audience(), &mei, &[], "mei direct");
    assert_eq!(data["header"]["route"], json!({"kind": "online", "method": "internet", "label": "Online, direct"}));
    assert_eq!(data["header"]["accessibility_label"], "Mei Lin, online, direct, show details");
    let details = builder(online_audience()).details(&mei, 0, now());
    validate_snapshot(&details, "details", "details direct");
    assert_eq!(details["route"]["kind"], "online");
    // Even an M1 build's words would not call an Internet session nearby.
    assert_eq!(conversation(audience(), &mei, &[], "m1 internet")["header"]["subtitle"], "Online, direct");
    mei.route_method = RouteMethod::Relay;
    let data = conversation(online_audience(), &mei, &[], "mei relay");
    assert_eq!(
        data["header"]["route"],
        json!({"kind": "online", "method": "relay", "label": "Online, through the Friends relay"})
    );
    assert!(data["composer"]["note"].is_null(), "no note while online");
}

#[test]
fn connecting() {
    if presentation::tree_missing() {
        return;
    }
    let data = conversation(online_audience(), &priya(OnlineReach::Connecting), &items_for("c_priya"), "connecting");
    let header = &data["header"];
    assert_eq!(header["route"], json!({"kind": "connecting", "method": null, "label": "Connecting to Priya…"}));
    assert_eq!(header["subtitle"], "Connecting to Priya…");
    assert_eq!(header["accessibility_label"], "Priya Raman, connecting to Priya, show details");
    assert!(data["composer"]["note"].is_null());
    let message = item(&data, "m_c4d27a19");
    assert_eq!(message["status"], json!({"state": "connecting", "label": "Connecting to Priya…"}));
    assert_eq!(message["actions"][0]["action"], "cancel_message");
    assert_eq!(
        message["accessibility_label"],
        "You, 17:58, connecting to Priya: I've marked the new delivery dates on page 4."
    );
    let file = item(&data, "t_6a2f90b8");
    assert_eq!(file["status_label"], "Connecting to Priya…");
    assert_eq!(
        file["accessibility_label"],
        "You are sending Supplier contract v3.pdf, PDF, 2.4 MB. Connecting to Priya."
    );
    let queued = ItemFacts { conversation_id: Some("c_priya".into()), ..items_for("c_priya")[3].clone() };
    let people = HashMap::from([("c_priya".to_owned(), priya(OnlineReach::Connecting))]);
    let statuses = builder(online_audience()).message_status_view(&[queued], &people);
    validate_snapshot(&statuses, "message_status", "message_status connecting");
    assert_eq!(statuses["messages"][0]["status"]["state"], "connecting");
    // Only friends are reached online, and a session that is up says how, whatever an attempt does beside it.
    let removed = PersonFacts { relation: Relation::Removed, ..priya(OnlineReach::Connecting) };
    let key_change = PersonFacts { key_change_pending: true, ..priya(OnlineReach::Connecting) };
    let bluetooth = PersonFacts {
        route_kind: RouteKind::Local,
        route_method: RouteMethod::Bluetooth,
        ..priya(OnlineReach::Connecting)
    };
    for (person, kind) in [(removed, "offline"), (key_change, "offline"), (bluetooth, "local")] {
        assert_eq!(conversation(online_audience(), &person, &[], "not connecting")["header"]["route"]["kind"], kind);
    }
}

#[test]
fn unreachable_and_offline() {
    if presentation::tree_missing() {
        return;
    }
    let data = conversation(online_audience(), &priya(OnlineReach::Unreachable), &items_for("c_priya"), "unreachable");
    assert_eq!(
        data["header"]["route"],
        json!({"kind": "offline", "method": null, "label": "Couldn’t connect just now"})
    );
    assert_eq!(
        data["composer"]["note"],
        "Couldn’t connect to Priya just now. Friends keeps trying, and sends what’s waiting as soon as it can."
    );
    assert_eq!(
        item(&data, "m_c4d27a19")["status"],
        json!({"state": "queued", "label": "Sends when Priya is online or nearby"})
    );
    assert_eq!(item(&data, "t_6a2f90b8")["status_label"], "Sends when Priya is online or nearby");
    let data = conversation(online_audience(), &priya(OnlineReach::Unknown), &[], "offline");
    assert_eq!(data["header"]["subtitle"], "Not connected right now");
    assert_eq!(
        data["composer"]["note"],
        "Messages and files send when Priya is online or nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open."
    );
    assert_eq!(
        Strings::new(online_audience()).static_strings()["queued_note"],
        "Messages and files send when {first} is online or nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open."
    );
}

#[test]
fn relay_estimates() {
    if presentation::tree_missing() {
        return;
    }
    let s = Strings::new(online_audience());
    // Not measured yet: 4 Mbit/s of payload, what the relay's 5 Mbit/s cap gives.
    assert_eq!(
        s.transfer_estimate(90_000_000, 0.0, RouteMethod::Relay).unwrap(),
        "Through the Friends relay, about 3 min"
    );
    // A burst above the cap is not what the rest of the file gets.
    assert_eq!(
        s.transfer_estimate(18_000_000, 2_000_000.0, RouteMethod::Relay).unwrap(),
        "Through the Friends relay, about 30 s"
    );
    assert_eq!(s.transfer_estimate(18_000_000, 0.0, RouteMethod::Bluetooth).unwrap(), "Over Bluetooth");
    let mut receiving = transfer("t_r", false, "2026-10-12 09:00", "Plan.pdf", 18_000_000, TransferState::Receiving);
    receiving.bytes_per_second = 2_000_000.0;
    receiving.transfer_route = RouteMethod::Relay;
    let data = conversation(online_audience(), &people()["c_mei"], &[receiving], "relay timed");
    assert_eq!(item(&data, "t_r")["status_label"], "Receiving · 0% · about 30 s left");
}

#[test]
fn a_file_being_checked_before_it_is_saved_says_finishing() {
    if presentation::tree_missing() {
        return;
    }
    // PROTOCOL.md § Fast transfers: every block arrived, the whole file's check runs for more than a second.
    let mut finishing =
        transfer("t_f", false, "2026-10-12 09:00", "Scan.step", 8_000_000_000, TransferState::Receiving);
    finishing.bytes_done = 8_000_000_000;
    finishing.bytes_per_second = 90_000_000.0;
    finishing.finishing = true;
    let data = conversation(online_audience(), &people()["c_mei"], &[finishing], "finishing");
    let row = item(&data, "t_f");
    assert_eq!(row["state"], "receiving");
    assert_eq!(row["status_label"], "Finishing…");
    assert_eq!(row["progress"]["fraction"], 1.0);
    assert_eq!(row["progress"]["accessibility_label"], "Finishing");
    assert!(row["accessibility_label"].as_str().unwrap().ends_with(", finishing"), "{}", row["accessibility_label"]);
}

#[test]
fn joining_in_every_state() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    for state in JoiningState::ALL {
        let data =
            builder.join(&JoiningFacts { state, friends_id: Some("cottage-violet".into()), ..Default::default() });
        validate_snapshot(&data, "join", &format!("{state:?}"));
        let typing = matches!(
            state,
            JoiningState::Waiting | JoiningState::Checking | JoiningState::WrongCode | JoiningState::NotReached
        );
        assert_eq!(!data["code_field"].is_null(), typing, "{state:?}: the code field");
        assert_eq!(!data["id_field"].is_null(), state == JoiningState::Idle, "{state:?}: the ID field");
        if typing {
            assert_eq!(data["code_field"]["enabled"], state != JoiningState::Checking);
        }
    }
    let s = builder.strings();
    assert!(s.join_error_message("invalid_field", Some("code")).unwrap().contains("8 digits"));
    assert!(s.join_error_message("not_allowed", None).is_some() && s.join_error_message("not_found", None).is_some());
    assert!(s.join_error_message("rate_limited", None).is_none(), "the rest keep the general ones");
    // An approval past its time shows nothing to type any more: the row offers Approve again.
    let stale = JoinRequestFacts {
        join_id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9".into(),
        device_name: "Raph’s Mac mini".into(),
        system: "macOS 15.7".into(),
        approved: true,
        code: Some("48312207".into()),
        code_expires_at: Some(now() - 1.0),
        ..Default::default()
    };
    let row = &builder.join_request_rows(&[stale], now())[0];
    assert!(row["state"] == "waiting" && row["code"].is_null());
}

#[test]
fn the_sender_of_a_link_file() {
    if presentation::tree_missing() {
        return;
    }
    let mut audience = audience();
    audience.helper_capabilities.insert("links".into());
    let builder = builder(audience);
    let mut mei = PersonFacts { relation: Relation::Removed, link_contact: true, ..people()["c_mei"].clone() };
    let mut link_event = event_item("e_link", "2026-10-12 14:40", event::RECEIVED_LINK_FILE);
    link_event.event_arguments.insert("file".into(), "Site photos.pdf".into());
    mei.last_preview_item_id = Some("e_link".into());
    mei.last_message_item_id = Some("e_link".into());
    let previews = HashMap::from([("e_link".to_owned(), link_event.clone())]);
    let row = builder.list(std::slice::from_ref(&mei), &previews, &profile_raph(), "", now())["rows"][0].clone();
    assert_eq!(row["subtitle"], "Mei: 📎 Site photos.pdf");
    let file = transfer("t_link", false, "2026-10-12 14:39", "Site photos.pdf", 2_516_582, TransferState::Received);
    let data = builder.conversation(&mei, &[file, link_event.clone()], false, None, 0, now());
    validate_snapshot(&data, "conversation", "link contact");
    let add = data["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|i| i["kind"] == "transfer")
        .flat_map(|i| i["actions"].as_array().unwrap().iter())
        .find(|a| a["action"] == "add_from_mention")
        .cloned()
        .unwrap();
    assert_eq!(
        (&add["label"], &add["friends_id"], &add["identity_key"]),
        (&json!("Add Mei"), &json!("jasmine-street"), &json!(KEY_MEI))
    );
    assert_eq!(data["composer"]["note"], "Add Mei as a friend to send messages.");
    mei.link_contact = false;
    let row = builder.list(&[mei], &previews, &profile_raph(), "", now())["rows"][0].clone();
    assert_eq!(row["subtitle"], "No longer friends", "a removed friend stays as before");
}

#[test]
fn several_computers_in_reader_words() {
    if presentation::tree_missing() {
        return;
    }
    let devices = catalog::part("devices");
    for (key, text) in devices.iter().filter(|(key, _)| key.contains("history")) {
        assert!(text.contains("all your computers") || text.contains("your other computers"), "{key}: {text}");
        assert!(catalog::english().contains_key(key.replace(".devices", "").as_str()), "{key} has no original");
    }
    // Words that describe how computers belong to a profile, which the person never needs.
    let mechanism = ["key", "chain", "token", "revok", "sync", "device", "signature", "authori", "session", "peer"];
    for (key, text) in devices.iter().chain(catalog::part("join").iter()) {
        let read = text.to_lowercase().replace("{device}", "");
        for word in mechanism {
            // On a phone or tablet, "this device" is the plain word for the one in the person's hand.
            if word == "device" && key.ends_with(".phone") {
                continue;
            }
            assert!(!read.contains(word), "{key} says “{word}”: {text}");
        }
    }
    let elsewhere: Vec<&str> =
        ["views", "join", "links"].iter().flat_map(|p| catalog::part(p)).map(|(k, _)| k).collect();
    assert!(devices.iter().all(|(key, _)| !elsewhere.contains(key)), "a key defined twice");
}
