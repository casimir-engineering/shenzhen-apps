//! What the reader sees, from the helper's UX critique (`SZFriendsPresentationReaderTests.m`): destructive actions
//! armed or confirmed everywhere, Nearby's searching and nobody states, IDs that never break across lines, message
//! times only where they help, list subtitles that lead with their status, and the confirmed-ID mark.

mod presentation;

use std::collections::HashMap;

use presentation::validate_snapshot;
use presentation::world::*;
use serde_json::{json, Value};
use szfriends_core::presentation::catalog;
use szfriends_core::presentation::{
    AdapterState, IdentityState, ItemFacts, NearbyFacts, OutboxState, PersonFacts, Picture, ProfileFacts, Relation,
    RouteKind, RouteMethod, TransferState,
};

fn person(id: &str, name: Option<&str>, friends_id: Option<&str>) -> PersonFacts {
    PersonFacts {
        conversation_id: id.into(),
        name: name.map(str::to_owned),
        friends_id: friends_id.map(str::to_owned),
        picture: Picture::animal(1, 7),
        route_kind: RouteKind::Local,
        route_method: RouteMethod::Lan,
        last_interaction_at: hk("2026-10-12 10:00"),
        ..Default::default()
    }
}

fn details(person: &PersonFacts) -> Value {
    let data = builder(audience()).details(person, 0, now());
    validate_snapshot(&data, "details", &person.conversation_id);
    data
}

fn conversation(person: &PersonFacts, items: &[ItemFacts]) -> Value {
    let data = builder(audience()).conversation(person, items, false, None, 0, now());
    validate_snapshot(&data, "conversation", &person.conversation_id);
    data
}

fn list_row(person: &PersonFacts, preview: Option<ItemFacts>) -> Value {
    let mut person = person.clone();
    let mut items = HashMap::new();
    if let Some(preview) = preview {
        person.last_preview_item_id = Some(preview.item_id.clone());
        items.insert(preview.item_id.clone(), preview);
    }
    let list = builder(audience()).list(&[person.clone()], &items, &profile_raph(), "", now());
    validate_snapshot(&list, "list", &person.conversation_id);
    list["rows"][0].clone()
}

fn named<'a>(actions: &'a Value, name: &str) -> &'a Value {
    actions.as_array().unwrap().iter().find(|a| a["action"] == name).unwrap_or_else(|| panic!("{name}"))
}

fn expect_armed_block(action: &Value, who: &str) {
    assert_eq!(action["style"], "destructive");
    assert_eq!(
        action["arm"],
        json!({"label": "Block?", "accessibility_label": format!("Click again to block {who}"),
                                     "seconds": 4})
    );
}

#[test]
fn destructive_actions() {
    if presentation::tree_missing() {
        return;
    }
    let mut mei = person("c_mei", Some("Mei Lin"), Some("jasmine-street"));
    let actions = details(&mei)["actions"].clone();
    expect_armed_block(named(&actions, "block"), "Mei");
    let remove = named(&actions, "remove_friend");
    assert!(remove["style"] == "destructive" && remove["confirm"]["destructive"] == true);
    assert_eq!(remove["confirm"]["title"], "Remove Mei as a friend?");
    assert_eq!(remove["confirm"]["confirm_label"], "Remove Friend");
    assert!(remove["confirm"]["body"].as_str().unwrap().contains("won’t be sent"));
    mei.key_change_pending = true;
    expect_armed_block(named(&details(&mei)["key_change"]["actions"], "block"), "Mei");
    let lena = PersonFacts {
        relation: Relation::IncomingRequest,
        ..person("c_lena", Some("Lena Weber"), Some("amber-falcon"))
    };
    let card = conversation(&lena, &[])["request"]["actions"].clone();
    expect_armed_block(named(&card, "block"), "Lena");
    assert!(card.as_array().unwrap().iter().all(|a| a["style"] != "link"), "no link on the card");
    let builder = builder(audience());
    let settings = builder.settings(&profile_raph(), &[]);
    assert!(
        settings["history"]["confirm"]["destructive"] == true && settings["reset"]["confirm"]["destructive"] == true
    );
    let broken = ProfileFacts { identity_state: IdentityState::Unavailable, ..profile_raph() };
    let banner = builder.list(&[], &HashMap::new(), &broken, "", now())["banner"].clone();
    assert_eq!(banner["action"]["confirm"]["destructive"], true);
}

fn working(since: Option<f64>) -> NearbyFacts {
    NearbyFacts {
        network_state: AdapterState::Working,
        bluetooth_state: AdapterState::Working,
        searching: true,
        working_since: since,
        ..Default::default()
    }
}

fn nearby(facts: &NearbyFacts, at: f64) -> Value {
    let data = builder(audience()).nearby(facts, &profile_raph(), "", at);
    validate_snapshot(&data, "nearby", "reader nearby");
    data
}

#[test]
fn nearby_looking_then_nobody() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let since = now();
    let data = nearby(&working(Some(since)), since + 3.0);
    assert_eq!(data["empty"]["kind"], "searching");
    assert!(data["empty"]["body"].is_null() && data["status"].is_null());
    assert_eq!(data["empty"]["title"], "Looking for people nearby…");
    assert_eq!(builder.nearby_refresh_date(&working(Some(since)), since + 3.0), Some(since + 8.0));
    let data = nearby(&working(Some(since)), since + 8.0);
    assert!(data["empty"]["kind"] == "nobody" && data["status"].is_null());
    assert_eq!(data["empty"]["body"], "ShenzhenPDF keeps looking while it’s open.");
    assert_ne!(data["empty"]["body"], data["visibility"]["body"]);
    assert_eq!(builder.nearby_refresh_date(&working(Some(since)), since + 8.0), None);
    assert_eq!(nearby(&working(None), since)["empty"]["kind"], "nobody", "no start time: no guessing");
    assert_eq!(nearby(&nearby_visible_bluetooth_off(), since)["status"]["label"], "Still looking");
    let mut off = NearbyFacts {
        network_state: AdapterState::RadioOff,
        bluetooth_state: AdapterState::RadioOff,
        ..Default::default()
    };
    let data = nearby(&off, since);
    assert_eq!(data["alert"]["title"], "Wi-Fi and Bluetooth are off");
    assert!(data["note"].is_null() && data["empty"]["kind"] == "unavailable" && data["empty"]["body"].is_null());
    off.bluetooth_state = AdapterState::Denied;
    let data = nearby(&off, since);
    assert_eq!(data["alert"]["title"], "Wi-Fi is off");
    assert_eq!(data["note"]["text"], "Bluetooth access is off for ShenzhenPDF too.");
    assert_eq!(data["note"]["action"]["settings_target"], "bluetooth_privacy");
    // Without a card (no state reaches this today; the empty state must still be true on its own).
    let radio = builder.nearby_empty(&off, false, "", false, since)["body"].clone();
    off.network_state = AdapterState::Denied;
    let access = builder.nearby_empty(&off, false, "", false, since)["body"].clone();
    assert_eq!(radio, "Turn on Wi-Fi or Bluetooth to find people nearby.");
    assert!(access.as_str().unwrap().contains("Privacy & Security") && !radio.as_str().unwrap().contains("Privacy"));
}

fn has_hyphenated_id(text: &str) -> bool {
    let bytes = text.as_bytes();
    (1..bytes.len().saturating_sub(1))
        .any(|i| bytes[i] == b'-' && bytes[i - 1].is_ascii_lowercase() && bytes[i + 1].is_ascii_lowercase())
}

#[test]
fn ids_never_break() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let list = builder.list(&[], &HashMap::new(), &profile_id_changed(), "", now());
    for text in [&list["banner"]["text"], &list["name_prompt"]["note"], &list["footer"]["id_label"]] {
        let text = text.as_str().unwrap();
        assert!(!has_hyphenated_id(text) && text.contains("walnut\u{2011}garden"), "breakable ID: {text}");
    }
    assert_eq!(list["footer"]["friends_id"], "walnut-garden", "the ID to copy is ASCII");
    assert!(builder.strings().add_by_id_sent_message("willow-breeze", false).contains("willow\u{2011}breeze"));
    let unnamed = person("c_t", None, Some("tulip-canyon"));
    for query in ["tulip-canyon", "tulip\u{2011}canyon", "tulip canyon"] {
        let found = builder.list(std::slice::from_ref(&unnamed), &HashMap::new(), &profile_raph(), query, now());
        assert_eq!(found["rows"].as_array().unwrap().len(), 1, "{query}");
    }
    let row = list_row(&unnamed, None);
    assert_eq!((&row["title"], &row["avatar"]["initials"]), (&json!("tulip\u{2011}canyon"), &json!("TC")));
}

#[test]
fn message_times() {
    if presentation::tree_missing() {
        return;
    }
    let mei = person("c_m", Some("Mei Lin"), Some("jasmine-street"));
    let items = [
        message("m_1", false, "2026-10-11 23:58", "late", None),
        message("m_2", true, "2026-10-12 00:01", "after midnight", Some(OutboxState::Delivered)),
        message("m_3", false, "2026-10-12 00:04", "three minutes on", None),
        transfer("t_1", false, "2026-10-12 00:05", "Plan.pdf", 1000, TransferState::Received),
        message("m_4", false, "2026-10-12 00:09", "five minutes after the last message", None),
        message("m_5", true, "2026-10-12 00:13:59", "four fifty-nine", Some(OutboxState::Delivered)),
    ];
    let data = conversation(&mei, &items);
    let by_id: HashMap<&str, &Value> =
        data["items"].as_array().unwrap().iter().map(|i| (i["item_id"].as_str().unwrap(), i)).collect();
    let expected = [
        ("m_1", json!("23:58")),
        ("m_2", json!("00:01")),
        ("m_3", Value::Null),
        ("t_1", json!("00:05")),
        ("m_4", json!("00:09")),
        ("m_5", Value::Null),
    ];
    for (id, time) in expected {
        assert_eq!(by_id[id]["time_label"], time, "{id}");
    }
    assert!(by_id["m_3"]["accessibility_label"].as_str().unwrap().contains("00:04"));
}

#[test]
fn status_first_subtitles() {
    if presentation::tree_missing() {
        return;
    }
    let priya = person("c_p", Some("Priya Raman"), Some("silver-ocean"));
    let row =
        list_row(&priya, Some(transfer("t_q", true, "2026-10-12 09:00", "Plan.pdf", 1000, TransferState::Queued)));
    assert_eq!(row["subtitle"], "Sends when Priya is nearby · Plan.pdf");
    assert!(row["accessibility_label"].as_str().unwrap().contains("you sent Plan.pdf, it sends when Priya is nearby"));
    let mut automatic = transfer("t_a", false, "2026-10-12 09:00", "Guide.pdf", 1000, TransferState::Received);
    automatic.accepted_automatically = true;
    assert_eq!(list_row(&priya, Some(automatic))["subtitle"], "Accepted automatically · Guide.pdf");
    let failed = message("m_f", true, "2026-10-12 09:00", "hello", Some(OutboxState::Failed));
    assert_eq!(list_row(&priya, Some(failed))["subtitle"], "Not sent · hello");
    let delivered = message("m_d", true, "2026-10-12 09:00", "hi", Some(OutboxState::Delivered));
    assert_eq!(list_row(&priya, Some(delivered))["subtitle"], "You: hi");
}

#[test]
fn id_confirmed() {
    if presentation::tree_missing() {
        return;
    }
    let mut answer = PersonFacts { relation: Relation::OutgoingRequest, ..person("c_a", None, Some("tulip-canyon")) };
    let row = list_row(&answer, None);
    assert!(row["id_confirmed"] == false && row["id_confirmed_label"].is_null());
    answer.friends_id_confirmed = true;
    let row = list_row(&answer, None);
    assert!(row["id_confirmed"] == true && row["id_confirmed_label"] == "ID confirmed by the Friends server");
    assert!(row["accessibility_label"].as_str().unwrap().ends_with(", ID confirmed"));
    answer.relation = Relation::Friend;
    let data = details(&answer);
    assert!(data["id_confirmed"] == true && !data["id_confirmed_label"].as_str().unwrap().is_empty());
    answer.friends_id = None; // no ID, nothing to confirm
    assert_eq!(details(&answer)["id_confirmed"], false);
}

#[test]
fn reader_strings() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let settings = builder.settings(&profile_raph(), &[]);
    assert_eq!(settings["name"]["note"], "The name your friends see.");
    let profile = builder.profile(&profile_raph(), 0);
    assert_eq!(profile["picture"]["choose_label"], "Change picture…");
    assert_eq!(
        profile["id"]["note"],
        "Your ID works nearby now. If it’s already taken, you’ll get a new one the next \
                                       time ShenzhenPDF reaches the Friends server."
    );
    let picture = builder.strings().error_message("picture_invalid", &Default::default()).unwrap();
    assert!(picture.contains("picture under 5 MB"));
    let denied = nearby(&nearby_local_network_denied(), now());
    assert_eq!(denied["alert"]["title"], "ShenzhenPDF can’t find people on your network");
    assert!(denied["alert"]["body"].as_str().unwrap().contains("in System Settings › Privacy"));
    // A phone has no System Settings: the same card names its Settings app.
    let on_phone = NearbyFacts { phone: true, ..nearby_local_network_denied() };
    let phone = nearby(&on_phone, now());
    assert!(phone["alert"]["body"].as_str().unwrap().contains("in Settings › Privacy & Security"), "{phone}");
    assert!(!phone.to_string().contains("System Settings"), "{phone}");
    for (key, value) in catalog::english() {
        assert!(!value.to_lowercase().contains("photo") || value.contains("photos"), "{key}: \"photo\" for a picture");
        assert!(!value.contains('\''), "{key} has a straight apostrophe: {value}");
    }
}
