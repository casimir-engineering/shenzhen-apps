//! View edge cases beyond the fixtures (`SZFriendsPresentationViewTests.m`): badge counting, list filters, previews
//! and row states, every transfer and message state, links, highlights, request cards and composer hints. Every
//! snapshot built here is also validated against PROTOCOL.md's schemas.

mod presentation;

use std::collections::HashMap;

use presentation::validate_snapshot;
use presentation::world::*;
use serde_json::{json, Value};
use szfriends_core::presentation::{
    event, Audience, IdentityState, ItemFacts, OutboxState, PersonFacts, Picture, Relation, RouteKind, RouteMethod,
    TransferState, UpdateNeed,
};

fn friend(id: &str, name: Option<&str>) -> PersonFacts {
    PersonFacts {
        conversation_id: id.into(),
        name: name.map(str::to_owned),
        friends_id: Some(format!("{id}-id")),
        picture: Picture::animal(1, 7),
        route_kind: RouteKind::Local,
        route_method: RouteMethod::Lan,
        last_interaction_at: hk("2026-10-12 10:00"),
        ..Default::default()
    }
}

fn list(people: &[PersonFacts], items: &HashMap<String, ItemFacts>, query: &str) -> Value {
    let list = builder(audience()).list(people, items, &profile_raph(), query, now());
    validate_snapshot(&list, "list", &format!("list({query})"));
    list
}

fn rows_by_id(list: &Value) -> HashMap<String, Value> {
    list["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| (r["conversation_id"].as_str().unwrap().to_owned(), r.clone()))
        .collect()
}

fn conversation_with(audience: Audience, person: &PersonFacts, items: &[ItemFacts], highlight: Option<&str>) -> Value {
    let data = builder(audience).conversation(person, items, false, highlight, 0, now());
    validate_snapshot(&data, "conversation", &person.conversation_id);
    data
}

fn conversation(person: &PersonFacts, items: &[ItemFacts], highlight: Option<&str>) -> Value {
    conversation_with(audience(), person, items, highlight)
}

fn last_item(data: &Value) -> Value {
    data["items"].as_array().unwrap().last().unwrap().clone()
}

fn action_names(item: &Value) -> Vec<String> {
    item["actions"].as_array().unwrap().iter().map(|a| a["action"].as_str().unwrap().to_owned()).collect()
}

#[test]
fn badge() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let empty = builder.badge(&[], 0);
    assert_eq!((&empty["label"], &empty["accessibility_label"]), (&json!(""), &json!("Friends")));
    let offers = PersonFacts { offers_waiting: 3, ..friend("c_a", Some("Ana")) }; // one row, however many offers
    let blocked = PersonFacts { relation: Relation::Blocked, offers_waiting: 2, ..friend("c_b", Some("Bo")) };
    let badge = builder.badge(&[offers, blocked], 0);
    assert_eq!((&badge["count"], &badge["accessibility_label"]), (&json!(1), &json!("Friends, 1 waiting for you")));
    let many: Vec<PersonFacts> = (0..120)
        .map(|i| PersonFacts { relation: Relation::IncomingRequest, ..friend(&format!("c_{i}"), Some("Someone New")) })
        .collect();
    let badge = builder.badge(&many, 0);
    assert_eq!((&badge["label"], &badge["count"]), (&json!("99+"), &json!(120)));
    validate_snapshot(&badge, "badge", "badge 120");
}

#[test]
fn list_rows() {
    if presentation::tree_missing() {
        return;
    }
    let all = everyone(&people());
    let items = preview_items();
    let rows = |query: &str| list(&all, &items, query)["rows"].as_array().unwrap().clone();
    assert_eq!(rows("MEI").iter().map(|r| r["conversation_id"].clone()).collect::<Vec<_>>(), [json!("c_mei")]);
    assert_eq!(rows("jasmine street").len(), 1, "an ID typed with a space");
    let none = list(&all, &items, " zzz ");
    assert_eq!(none["rows"], json!([]));
    assert_eq!(none["empty"]["kind"], "no_match");
    assert!(none["empty"]["title"].as_str().unwrap().contains("“zzz”"));
    let tomas = friend("c_tomas", Some("Tomás Rivera"));
    assert_eq!(list(&[tomas], &HashMap::new(), "tomas")["rows"].as_array().unwrap().len(), 1, "diacritics");
    let tied = list(&[friend("c_z", Some("Zed")), friend("c_a", Some("Ann"))], &HashMap::new(), "");
    assert_eq!(tied["rows"][0]["conversation_id"], "c_a", "ties ordered by id");

    let blocked =
        PersonFacts { relation: Relation::Blocked, offers_waiting: 1, ..friend("c_blocked", Some("Bo Block")) };
    let outgoing = PersonFacts {
        relation: Relation::OutgoingRequest,
        route_kind: RouteKind::None,
        ..friend("c_out", Some("Olu Out"))
    };
    let removed = PersonFacts { relation: Relation::Removed, ..friend("c_removed", Some("Rae Removed")) };
    let key_change = PersonFacts { key_change_pending: true, ..friend("c_key", Some("Kim Key")) };
    let offers = PersonFacts { offers_waiting: 3, ..friend("c_offers", Some("Ola Offers")) };
    let by_id = rows_by_id(&list(&[blocked, outgoing, removed, key_change, offers], &HashMap::new(), ""));
    let b = &by_id["c_blocked"];
    assert!(b["blocked"] == true && b["subtitle"] == "Blocked" && b["waiting"].is_null() && b["drop_label"].is_null());
    let o = &by_id["c_out"];
    assert_eq!((&o["subtitle"], &o["route"]["label"]), (&json!("Request sent"), &Value::Null));
    assert_eq!(o["accessibility_label"], "Olu Out, request sent, 10:00");
    assert!(by_id["c_removed"]["subtitle"] == "No longer friends" && by_id["c_removed"]["drop_label"].is_null());
    assert_eq!(by_id["c_key"]["waiting"]["kind"], "key_change");
    assert_eq!(by_id["c_key"]["subtitle"], "Key changed. Check it’s really Kim");
    assert_eq!(by_id["c_offers"]["subtitle"], "Sent you 3 files");

    // Previews: a queued message says when it goes and drops the route; long text is cut to one line.
    let mei = PersonFacts { last_preview_item_id: Some("m_q".into()), ..friend("c_mei2", Some("Mei Lin")) };
    let preview = |item: ItemFacts| {
        let items = HashMap::from([("m_q".to_owned(), item)]);
        list(std::slice::from_ref(&mei), &items, "")["rows"][0].clone()
    };
    let row = preview(message("m_q", true, "2026-10-12 10:00", "hi", Some(OutboxState::Queued)));
    assert_eq!(row["subtitle"], "Sends when Mei is nearby · hi");
    assert_eq!(row["accessibility_label"], "Mei Lin, you said hi, it sends when Mei is nearby, 10:00");
    let long_text: String = "word \n".chars().cycle().take(300).collect();
    let row = preview(message("m_q", false, "2026-10-12 10:00", &long_text, None));
    let subtitle = row["subtitle"].as_str().unwrap();
    assert!(
        subtitle.encode_utf16().count() <= 121 && subtitle.ends_with('…') && !subtitle.contains('\n'),
        "{subtitle}"
    );
    let row = preview(event_item("e_k", "2026-10-12 10:00", event::KEY_CHANGED));
    assert!(row["accessibility_label"].as_str().unwrap().starts_with("Mei Lin, Mei’s key changed"));

    // Without drop.files the rows refuse drops.
    let no_drops = Audience { capabilities: Default::default(), ..audience() };
    let plain = builder(no_drops).list(&[mei], &HashMap::new(), &profile_raph(), "", now());
    assert!(plain["rows"][0]["drop_label"].is_null());
}

#[test]
fn row_actions() {
    if presentation::tree_missing() {
        return;
    }
    let request = PersonFacts {
        name: None,
        friends_id: Some("tulip-canyon".into()), // unnamed: the ID is the title
        relation: Relation::IncomingRequest,
        ..friend("c_req", None)
    };
    let people = [
        request,
        PersonFacts { offers_waiting: 1, ..friend("c_offers", Some("Ola Offers")) },
        PersonFacts { key_change_pending: true, ..friend("c_key", Some("Kim Key")) },
        PersonFacts { relation: Relation::OutgoingRequest, ..friend("c_out", Some("Olu Out")) },
        PersonFacts { relation: Relation::Blocked, ..friend("c_blocked", Some("Bo Block")) },
        PersonFacts { relation: Relation::Removed, ..friend("c_removed", Some("Rae Removed")) },
        friend("c_friend", Some("Fay")),
    ];
    let by_id = rows_by_id(&list(&people, &HashMap::new(), ""));
    assert_eq!(
        by_id["c_req"]["actions"],
        json!([
            {"action": "accept_request", "icon": "accept", "title": "Accept",
             "label": "Accept tulip\u{2011}canyon’s request", "arm": null},
            {"action": "decline_request", "icon": "decline", "title": "Decline",
             "label": "Decline tulip\u{2011}canyon’s request", "arm": null},
            {"action": "block", "icon": "block", "title": null, "label": "Block tulip\u{2011}canyon",
             "arm": {"label": "Block?", "accessibility_label": "Click again to block tulip\u{2011}canyon",
                     "seconds": 4}},
        ])
    );
    assert_eq!(by_id["c_req"]["waiting"]["kind"], "request");
    for id in ["c_offers", "c_key", "c_out", "c_blocked", "c_removed", "c_friend"] {
        assert_eq!(by_id[id]["actions"], json!([]), "{id} carries no row actions");
    }
}

#[test]
fn list_banners() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let mut profile = profile_id_changed();
    profile.identity_state = IdentityState::Unavailable;
    let list = builder.list(&[], &HashMap::new(), &profile, "", now());
    assert_eq!(list["banner"]["kind"], "identity_unavailable");
    assert_eq!(list["banner"]["action"]["action"], "reset_friends");
    assert_eq!(list["banner"]["action"]["confirm"]["confirm_label"], "Reset Friends");
    assert!(list["footer"]["id_note"].is_null());
    validate_snapshot(&list, "list", "identity banner");
    profile.identity_state = IdentityState::Ready;
    for need in [UpdateNeed::Online, UpdateNeed::Store] {
        profile.update_need = need;
        let list = builder.list(&[], &HashMap::new(), &profile, "", now());
        assert_eq!(list["banner"]["kind"], "update_required");
        assert!(list["banner"]["text"].as_str().unwrap().contains("ShenzhenPDF"));
        validate_snapshot(&list, "list", "update banner");
    }
}

#[test]
fn nearby_only_id_note() {
    if presentation::tree_missing() {
        return;
    }
    // The footer never carries a note about the ID (an unreserved one raised a question it could not answer); a
    // phone's embedded core, which never reaches a Friends server, says on the profile who can add the person.
    let builder = builder(audience());
    let mut profile = profile_raph();
    let list = builder.list(&[], &HashMap::new(), &profile, "", now());
    assert!(list["footer"]["id_note"].is_null());
    profile.nearby_only = true;
    let list = builder.list(&[], &HashMap::new(), &profile, "", now());
    assert!(list["footer"]["id_note"].is_null());
    validate_snapshot(&list, "list", "nearby-only footer");
    let page = builder.profile(&profile, 2);
    assert_eq!(page["id"]["state"], "unreserved");
    assert_eq!(page["id"]["note"], "People near you can add you with it.");
    validate_snapshot(&page, "profile", "nearby-only profile");
}

#[test]
fn transfers() {
    if presentation::tree_missing() {
        return;
    }
    let mei = friend("c_mei3", Some("Mei Lin"));
    for state in TransferState::ALL {
        for outgoing in [false, true] {
            let mut item = transfer("t_x", outgoing, "2026-10-12 09:00", "Plan.pdf", 5_000_000, state);
            item.bytes_done = 2_000_000;
            item.bytes_per_second = 100_000.0;
            item.transfer_route = RouteMethod::Bluetooth;
            item.local_path = Some("/tmp/received/Plan.pdf".into());
            let built = last_item(&conversation(&mei, &[item], None));
            let spoken = built["accessibility_label"].as_str().unwrap();
            assert!(!spoken.is_empty() && !spoken.contains('{'), "{state:?} spoken: {spoken}");
            assert!(!built["status_label"].as_str().unwrap().contains('{'), "{state:?}");
        }
    }
    let mut offer = transfer("t_o", false, "2026-10-12 09:00", "Plan.pdf", 5_000_000, TransferState::WaitingForYou);
    assert_eq!(
        action_names(&last_item(&conversation(&mei, std::slice::from_ref(&offer), None))),
        ["accept_offer", "decline_offer"]
    );
    offer.asked_because_disk_low = true;
    let status = last_item(&conversation(&mei, &[offer], None))["status_label"].clone();
    assert!(status.as_str().unwrap().starts_with("Waiting for you. "), "disk-low offer says why it asks");
    let mut received = transfer("t_r", false, "2026-10-12 09:00", "Plan.pdf", 5_000_000, TransferState::Received);
    received.local_path = Some("/tmp/received/Plan.pdf".into());
    let item = last_item(&conversation(&mei, std::slice::from_ref(&received), None));
    assert_eq!(action_names(&item), ["open_file", "show_file"]);
    assert_eq!(item["actions"][1]["label"], "Show in Finder");
    assert_eq!(item["file"]["path"], "/tmp/received/Plan.pdf");
    received.file_name = Some("Archive.zip".into());
    received.file_extension = Some("zip".into());
    assert_eq!(action_names(&last_item(&conversation(&mei, &[received], None))), ["show_file"]);
    let mut sending = transfer("t_s", true, "2026-10-12 09:00", "Plan.pdf", 5_000_000, TransferState::Sending);
    sending.bytes_done = 2_000_000;
    sending.bytes_per_second = 25_000.0;
    sending.transfer_route = RouteMethod::Bluetooth;
    let item = last_item(&conversation(&mei, &[sending], None));
    assert_eq!(item["progress"]["fraction"], json!(0.4));
    assert_eq!(item["status_label"], "Sending · 40% · about 2 min left");
    assert_eq!(item["route_note"], "Over Bluetooth, about 2 min");
    assert_eq!(item["progress"]["accessibility_label"], "Sending, 40 percent");
    let failed = transfer("t_f", true, "2026-10-12 09:00", "Plan.pdf", 1, TransferState::Failed);
    assert_eq!(action_names(&last_item(&conversation(&mei, &[failed], None))), ["retry_item"]);
    let mut relayed = transfer("t_y", true, "2026-10-12 09:00", "Plan.pdf", 18_000_000, TransferState::Offered);
    relayed.bytes_per_second = 100_000.0;
    relayed.transfer_route = RouteMethod::Relay;
    assert_eq!(
        last_item(&conversation(&mei, &[relayed], None))["route_note"],
        "Through the Friends relay, about 3 min"
    );
}

#[test]
fn messages_and_days() {
    if presentation::tree_missing() {
        return;
    }
    let mei = friend("c_mei4", Some("Mei Lin"));
    let messages = [
        message("m_1", true, "2026-10-08 09:00", "see https://example.com/plan please", Some(OutboxState::Failed)),
        message("m_2", true, "2026-10-11 09:00", "two", Some(OutboxState::Connecting)),
        message("m_3", true, "2026-10-12 09:00", "three", Some(OutboxState::Sending)),
        event_item("e_new", "2026-10-12 09:30", "a_kind_from_the_future"),
    ];
    let data = conversation(&mei, &messages, Some("m_2"));
    let items = data["items"].as_array().unwrap();
    let kinds: Vec<&Value> = items.iter().map(|i| &i["kind"]).collect();
    assert_eq!(
        kinds,
        ["day", "message", "day", "message", "day", "message"].map(|k| json!(k)).iter().collect::<Vec<_>>()
    );
    assert_eq!(
        [&items[0]["label"], &items[2]["label"], &items[4]["label"]],
        [&json!("Thursday"), &json!("Yesterday"), &json!("Today")]
    );
    assert_eq!(items[1]["segments"].as_array().unwrap().len(), 3);
    assert_eq!(items[1]["segments"][1]["url"], "https://example.com/plan");
    assert_eq!(items[1]["text"], "see https://example.com/plan please");
    assert_eq!(action_names(&items[1]), ["retry_item"]);
    assert_eq!(items[1]["status"]["label"], "Not delivered");
    assert!(items[1]["accessibility_label"].as_str().unwrap().ends_with("please. Not delivered."));
    assert_eq!(items[3]["status"]["label"], "Connecting to Mei…");
    assert!(items[3]["highlighted"] == true && data["highlight_item_id"] == "m_2");
    assert!(conversation(&mei, &messages, Some("m_gone"))["highlight_item_id"].is_null(), "not in the window");
}

#[test]
fn requests_and_composer() {
    if presentation::tree_missing() {
        return;
    }
    let olu = PersonFacts {
        relation: Relation::OutgoingRequest,
        request_at: Some(hk("2026-10-12 14:40")),
        route_kind: RouteKind::None,
        ..friend("c_out2", Some("Olu Out"))
    };
    let card = conversation(&olu, &[], None)["request"].clone();
    assert_eq!(card["direction"], "outgoing");
    assert_eq!(action_names(&card), ["cancel_request"]);
    assert!(card["comparison_code"].is_null());
    assert_eq!(card["subtitle"], "Sent today at 14:40 · ID c_out2\u{2011}id");
    assert_eq!(card["code_prompt"], "A code to compare appears when you’re both online or nearby.");
    let by_id = PersonFacts {
        relation: Relation::IncomingRequest,
        request_at: Some(hk("2026-10-11 09:00")),
        ..friend("c_in2", Some("Ines In"))
    };
    let card = conversation(&by_id, &[], None)["request"].clone();
    assert!(card["subtitle"].as_str().unwrap().starts_with("Sent to your ID · yesterday at 09:00"));

    let blocked = PersonFacts { relation: Relation::Blocked, ..friend("c_bl", Some("Bo Block")) };
    let data = conversation(&blocked, &[], None);
    assert!(data["composer"]["enabled"] == false && data["composer"]["accepts_drops"] == false);
    assert_eq!(data["header"]["subtitle"], "Blocked");
    assert_eq!(data["header"]["route"]["kind"], "none");
    assert!(data["header"]["route"]["label"].is_null());
    assert_eq!(data["header"]["accessibility_label"], "Bo Block, blocked, show details");
    let mut near = PersonFacts { route_method: RouteMethod::Bluetooth, ..friend("c_bt", Some("Mei Lin")) };
    let header = conversation(&near, &[], None)["header"].clone();
    assert_eq!(header["route"]["method"], "bluetooth");
    assert_eq!(header["accessibility_label"], "Mei Lin, nearby, over Bluetooth, show details");
    near.route_kind = RouteKind::None;
    assert_eq!(conversation(&near, &[], None)["header"]["accessibility_label"], "Mei Lin, show details");
    let changed = PersonFacts { key_change_pending: true, ..friend("c_kc", Some("Kim Key")) };
    assert!(conversation(&changed, &[], None)["composer"]["note"].as_str().unwrap().contains("key changed"));

    let with = |capabilities: &[&str]| {
        let audience = Audience { capabilities: capabilities.iter().map(|c| c.to_string()).collect(), ..audience() };
        conversation_with(audience, &friend("c_h", Some("Hana")), &[], None)["composer"]["hint"].clone()
    };
    assert_eq!(
        with(&["attach.items", "assistant.drafts", "drop.files"]),
        json!([
            {"text": "Type "}, {"text": "#", "emphasis": true}, {"text": " to attach, "},
            {"text": "/", "emphasis": true}, {"text": " to ask the assistant, or drop files here"},
        ])
    );
    assert_eq!(
        with(&["attach.items", "mentions"]),
        json!([
            {"text": "Type "}, {"text": "#", "emphasis": true}, {"text": " to attach or "},
            {"text": "@", "emphasis": true}, {"text": " to mention someone"},
        ])
    );
    assert_eq!(with(&["drop.files"]), json!([{"text": "Drop files here to send them"}]));
    assert_eq!(with(&[]), json!([]));
}
