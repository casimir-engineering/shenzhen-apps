//! Nearby in every pair of method states, details, the profile, Settings and search results
//! (`SZFriendsPresentationPeopleTests.m`), and failed items with the words for each of the store's failure keys and
//! when Try again shows (`SZFriendsPresentationFailureTests.m`).

mod presentation;

use presentation::world::*;
use presentation::{validate_result, validate_snapshot};
use serde_json::{json, Value};
use szfriends_core::presentation::catalog;
use szfriends_core::presentation::{
    failure, AdapterState, IdState, IdentityState, ItemFacts, NearbyFacts, OutboxState, PersonFacts, Picture,
    ProfileFacts, Relation, RouteKind, SearchHitFacts, TransferState,
};

const STATES: [AdapterState; 6] = [
    AdapterState::NotAsked,
    AdapterState::Starting,
    AdapterState::Working,
    AdapterState::Denied,
    AdapterState::RadioOff,
    AdapterState::Unavailable,
];

fn nearby(facts: &NearbyFacts, query: &str, at: f64) -> Value {
    let data = builder(audience()).nearby(facts, &profile_raph(), query, at);
    validate_snapshot(&data, "nearby", &format!("nearby {:?}/{:?}", facts.network_state, facts.bluetooth_state));
    data
}

fn broken(state: AdapterState) -> bool {
    matches!(state, AdapterState::Denied | AdapterState::RadioOff | AdapterState::Unavailable)
}

#[test]
fn nearby_states() {
    if presentation::tree_missing() {
        return;
    }
    for network in STATES {
        for bluetooth in STATES {
            let facts = NearbyFacts { network_state: network, bluetooth_state: bluetooth, ..Default::default() };
            let data = nearby(&facts, "", now());
            let (alert, note) = (!data["alert"].is_null(), !data["note"].is_null());
            let at = format!("{network:?}/{bluetooth:?}");
            if alert && note {
                assert!(data["note"]["text"].as_str().unwrap().contains("Bluetooth"), "{at}: {}", data["note"]);
            }
            if alert && data["empty"].is_object() {
                assert!(data["empty"]["body"].is_null(), "{at}: the card says it");
            }
            let both_off = network == AdapterState::RadioOff && bluetooth == AdapterState::RadioOff;
            if alert && broken(bluetooth) {
                let named = if both_off {
                    !note && data["alert"]["title"].as_str().unwrap().contains("Bluetooth")
                } else {
                    note
                };
                assert!(named, "{at}: Bluetooth's state is named somewhere");
            }
            assert!(!data["empty"].is_null(), "{at} says why nobody shows");
            if broken(network) && broken(bluetooth) {
                assert_eq!(
                    (&data["empty"]["kind"], &data["visibility"]["state"]),
                    (&json!("unavailable"), &json!("unavailable"))
                );
            }
        }
    }
    let mut facts = NearbyFacts { network_state: AdapterState::Starting, ..Default::default() };
    assert_eq!(nearby(&facts, "", now())["empty"]["kind"], "searching");
    facts.network_state = AdapterState::Working;
    facts.bluetooth_state = AdapterState::Working;
    assert_eq!(nearby(&facts, "", now())["empty"]["kind"], "nobody");
    facts.bluetooth_state = AdapterState::Denied;
    let note = nearby(&facts, "", now())["note"].clone();
    assert_eq!(note["action"]["settings_target"], "bluetooth_privacy");
    assert!(note["text"].as_str().unwrap().contains("ShenzhenPDF"));
    facts.network_state = AdapterState::RadioOff;
    facts.bluetooth_state = AdapterState::Working;
    assert_eq!(nearby(&facts, "", now())["alert"]["action"]["settings_target"], "wifi");

    let mut visible = nearby_visible_bluetooth_off();
    let deadline = visible.visibility_deadline.unwrap();
    assert_eq!(nearby(&visible, "", deadline - 1.0)["visibility"]["remaining_label"], "0:01");
    assert_eq!(nearby(&visible, "", deadline + 1.0)["visibility"]["state"], "hidden");
    let none = nearby(&visible, "nobody-here", now());
    assert!(none["empty"]["kind"] == "no_match" && none["people"] == json!([]));
    let lagoon = nearby(&visible, "lagoon", now());
    assert_eq!(lagoon["people"].as_array().unwrap().len(), 1);
    assert_eq!(lagoon["people"][0]["title"], "coral\u{2011}lagoon");
    visible.people[1].relation = Relation::IncomingRequest;
    visible.people[3].relation = Relation::Blocked;
    let data = nearby(&visible, "", now());
    assert_eq!(data["people"].as_array().unwrap().len(), 3, "blocked people never appear");
    assert_eq!(data["people"][1]["status_label"], "Wants to be friends");
    assert!(data["people"][1]["action"].is_null());
    // The helper rebuilds an empty Nearby when "looking" turns into "nobody".
    let builder = builder(audience());
    let since = hk("2026-10-12 14:47:45");
    let working =
        NearbyFacts { network_state: AdapterState::Working, working_since: Some(since), ..Default::default() };
    assert_eq!(builder.nearby_refresh_date(&working, now()), Some(since + 8.0));
    assert_eq!(builder.nearby_refresh_date(&working, since + 9.0), None);
}

fn details(person: &PersonFacts, waiting: i64) -> Value {
    let data = builder(audience()).details(person, waiting, now());
    validate_snapshot(&data, "details", &person.conversation_id);
    data
}

#[test]
fn details_edges() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let mut kenji = people["c_kenji"].clone();
    kenji.comparison_code = Some("418270".into());
    let data = details(&kenji, 2);
    assert_eq!(data["verification"]["comparison_code"], "418 270");
    assert_eq!(data["verification"]["action"]["action"], "mark_verified");
    assert_eq!(data["back"]["badge_count"], 2);
    assert_eq!(
        data["back"]["accessibility_label"],
        "Back to the conversation with Kenji, 2 more waiting for you in Friends"
    );
    kenji.route_kind = RouteKind::Offline;
    let data = details(&kenji, 0);
    assert!(data["verification"]["comparison_code"].is_null() && data["verification"]["action"].is_null());
    assert_eq!(
        data["verification"]["body"],
        "Compare codes the next time you’re both online or nearby to be sure this is really Kenji."
    );
    kenji.relation = Relation::Blocked;
    let data = details(&kenji, 0);
    let actions: Vec<&Value> = data["actions"].as_array().unwrap().iter().map(|a| &a["action"]).collect();
    assert_eq!(actions, [&json!("delete_history"), &json!("unblock")]);
    assert_eq!(data["auto_accept"]["available"], false);
    let mut daniel = people["c_daniel"].clone();
    daniel.key_change_pending = true;
    daniel.received_file_count = 1;
    daniel.friends_id = None;
    let data = details(&daniel, 0);
    let actions: Vec<&Value> = data["key_change"]["actions"].as_array().unwrap().iter().map(|a| &a["action"]).collect();
    assert_eq!(actions, [&json!("accept_key_change"), &json!("block")]);
    assert_eq!(data["received"]["label"], "Received from Daniel: 1 file");
    assert!(data["received"]["action"].is_null() && data["friends_id"].is_null());
}

#[test]
fn profile_and_settings() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let profile = ProfileFacts { friends_id_state: IdState::Reserved, ..profile_raph() };
    let data = builder.profile(&profile, 3);
    assert_eq!(
        (&data["id"]["state"], &data["id"]["note"]),
        (&json!("reserved"), &json!("People can add you with it."))
    );
    assert_eq!(data["back"]["accessibility_label"], "Back to Friends, 3 waiting");
    validate_snapshot(&data, "profile", "reserved");
    let mut profile = ProfileFacts { picture: Picture::Placeholder, ..profile_id_changed() };
    let data = builder.profile(&profile, 0);
    assert_eq!(data["id"]["state"], "changed");
    assert!(data["id"]["note"].as_str().unwrap().contains("walnut\u{2011}valley"));
    assert!(
        data["picture"]["selected_index"].is_null()
            && data["id"]["qr_payload"].is_null()
            && data["id"]["qr_label"].is_null()
    );
    assert_eq!(data["id"]["friends_id"], "walnut-garden");
    validate_snapshot(&data, "profile", "changed");
    profile.identity_state = IdentityState::Unavailable;
    assert_eq!(builder.profile(&profile, 0)["id"]["state"], "unavailable");

    let friends: Vec<PersonFacts> = ["Ann Lee", "Bo Chan", "Cy Wu", "Di Ng", "Ed Ho", "Flo Yu"]
        .iter()
        .enumerate()
        .map(|(i, name)| PersonFacts {
            conversation_id: format!("c_{}", &name[..2]),
            name: Some(name.to_string()),
            last_interaction_at: now() - i as f64 * 60.0,
            ..Default::default()
        })
        .collect();
    let note = |people: &[PersonFacts], enabled: usize| {
        let people: Vec<PersonFacts> =
            people.iter().enumerate().map(|(i, p)| PersonFacts { auto_accept: i < enabled, ..p.clone() }).collect();
        let settings = builder.settings(&profile_raph(), &people);
        validate_snapshot(&settings, "settings", "settings");
        settings["auto_accept"]["note"].as_str().unwrap().to_owned()
    };
    assert_eq!(note(&[], 0), "Turn it on for a friend in their details.");
    assert_eq!(note(&friends, 0), "Off. Every file waits for you to accept it.");
    assert_eq!(note(&friends[..1], 1), "From Ann Lee.");
    assert_eq!(note(&friends[..3], 3), "From every friend.");
    assert_eq!(note(&friends, 3), "From Ann Lee, Bo Chan and Cy Wu. Everyone else asks first.");
    assert_eq!(note(&friends, 4), "From Ann Lee, Bo Chan and 2 others. Everyone else asks first.");
}

#[test]
fn search_results() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = people();
    let empty = builder.search_result(&[], &people, false, now());
    assert_eq!(empty["empty_label"], "No messages or files match.");
    validate_result(&empty, "search_messages", "empty search");
    let padding: String = "lorem ipsum ".chars().cycle().take(200).collect();
    let deep = SearchHitFacts {
        conversation_id: "c_mei".into(),
        item_id: "m_deep".into(),
        sent_at: hk("2026-10-05 09:00"),
        text: format!("{padding}合同{padding}"),
        match_ranges: vec![(200, 2)],
        ..Default::default()
    };
    let orphan = SearchHitFacts { conversation_id: "c_deleted".into(), ..Default::default() };
    let result = builder.search_result(&[deep, orphan], &people, true, now());
    assert!(result["results"].as_array().unwrap().len() == 1 && result["more"] == true, "orphan hits skipped");
    let excerpt = result["results"][0]["excerpt"].as_array().unwrap();
    assert!(excerpt[0]["text"] == "…" && excerpt.last().unwrap()["text"] == "…");
    assert_eq!(excerpt[2], json!({"text": "合同", "match": true}));
    assert_eq!(result["results"][0]["time_label"], "5 Oct");
    validate_result(&result, "search_messages", "windowed search");
}

fn mei() -> PersonFacts {
    PersonFacts {
        conversation_id: "c_mei5".into(),
        name: Some("Mei Lin".into()),
        friends_id: Some("jasmine-street".into()),
        picture: Picture::animal(1, 7),
        route_kind: RouteKind::Offline,
        last_interaction_at: hk("2026-10-12 10:00"),
        ..Default::default()
    }
}

fn built(person: &PersonFacts, item: ItemFacts) -> Value {
    let data = builder(audience()).conversation(person, std::slice::from_ref(&item), false, None, 0, now());
    validate_snapshot(&data, "conversation", &format!("{} {:?}", item.item_id, item.failure_reason));
    data["items"].as_array().unwrap().last().unwrap().clone()
}

fn retries(item: &Value) -> bool {
    item["actions"].as_array().unwrap().iter().any(|a| a["action"] == "retry_item")
}

fn failed_message(reason: Option<&str>) -> ItemFacts {
    let mut item = message("m_f", true, "2026-09-04 10:15", "Are you free on Thursday?", Some(OutboxState::Failed));
    item.failure_reason = reason.map(str::to_owned);
    item
}

fn failed_transfer(outgoing: bool, reason: Option<&str>) -> ItemFacts {
    let mut item = transfer("t_f", outgoing, "2026-09-04 10:15", "Plan.pdf", 5_000_000, TransferState::Failed);
    item.failure_reason = reason.map(str::to_owned);
    item
}

#[test]
fn message_failures() {
    if presentation::tree_missing() {
        return;
    }
    let mei = mei();
    let item = built(&mei, failed_message(Some(failure::NOT_DELIVERED_30_DAYS)));
    assert_eq!(
        (&item["status"]["state"], &item["status"]["label"]),
        (&json!("failed"), &json!("Not delivered. Stopped trying after 30 days."))
    );
    assert!(retries(&item));
    assert_eq!(
        item["accessibility_label"],
        "You, 10:15: Are you free on Thursday? Not delivered. Stopped trying after 30 days."
    );
    let item = built(&mei, failed_message(Some(failure::REFUSED)));
    assert!(item["status"]["label"] == "Mei couldn’t receive this" && !retries(&item));
    let item = built(&mei, failed_message(Some(failure::SOURCE_MISSING)));
    assert!(item["status"]["label"] == "Not sent because an attachment is no longer available" && !retries(&item));
    for reason in [None, Some("a_reason_from_the_future")] {
        let item = built(&mei, failed_message(reason));
        assert!(item["status"]["label"] == "Not delivered" && retries(&item), "{reason:?}");
    }
    let queued =
        ItemFacts { outbox_state: Some(OutboxState::Queued), ..failed_message(Some(failure::NOT_DELIVERED_30_DAYS)) };
    assert_eq!(
        built(&mei, queued)["status"]["label"],
        "Sends when Mei is nearby",
        "a reason means nothing until failed"
    );
    for relation in [Relation::Blocked, Relation::Removed] {
        let other = PersonFacts { relation, ..mei.clone() };
        assert!(!retries(&built(&other, failed_message(Some(failure::NOT_DELIVERED_30_DAYS)))), "{relation:?}");
        assert!(!retries(&built(&other, failed_transfer(true, None))), "{relation:?} file");
    }
    let changed = PersonFacts { key_change_pending: true, ..mei.clone() };
    assert!(!retries(&built(&changed, failed_message(None))), "a key change to review: no Try again");
    // An outgoing message the store has no delivery record for claims nothing at all.
    let item = built(&mei, message("m_u", true, "2026-10-12 09:00", "Hello", None));
    assert!(item["status"].is_null() && item["actions"] == json!([]));
    assert_eq!(item["accessibility_label"], "You, 09:00: Hello");
}

#[test]
fn withdrawn_by_remove_or_block() {
    if presentation::tree_missing() {
        return;
    }
    for (relation, words) in [
        (Relation::Removed, "Not sent because you removed Mei"),
        (Relation::Blocked, "Not sent because you blocked Mei"),
    ] {
        let person = PersonFacts { relation, ..mei() };
        let message = built(&person, failed_message(Some(failure::REFUSED)));
        let file = built(&person, failed_transfer(true, Some(failure::REFUSED)));
        assert!(message["status"]["label"] == words && !retries(&message));
        assert!(file["status_label"] == words && !retries(&file));
        assert!(file["accessibility_label"].as_str().unwrap().ends_with(&format!("{words}.")));
    }
}

#[test]
fn transfer_failures() {
    if presentation::tree_missing() {
        return;
    }
    let mei = mei();
    let expected = [
        (failure::NOT_DELIVERED_30_DAYS, "Not delivered. Stopped trying after 30 days.", true),
        (failure::REFUSED, "Mei couldn’t receive this file", false),
        (failure::SOURCE_MISSING, "Not sent because this version of the file is no longer available", false),
        (failure::DIGEST_MISMATCH, "Arrived damaged for Mei, so it wasn’t saved", true),
    ];
    for (reason, words, retry) in expected {
        let item = built(&mei, failed_transfer(true, Some(reason)));
        assert!(item["status_label"] == words && retries(&item) == retry, "{reason}");
        let status = words.strip_suffix('.').unwrap_or(words);
        assert_eq!(item["accessibility_label"], format!("You tried to send Plan.pdf, PDF, 5 MB. {status}."));
    }
    let item = built(&mei, failed_transfer(false, Some(failure::DIGEST_MISMATCH)));
    assert!(item["status_label"] == "Arrived damaged, so it wasn’t saved" && retries(&item));
    assert_eq!(item["accessibility_label"], "Mei Lin sent Plan.pdf, PDF, 5 MB. It arrived damaged, so it wasn’t saved");
    let item = built(&mei, failed_transfer(false, None));
    assert!(item["status_label"] == "Didn’t arrive" && !retries(&item));
}

#[test]
fn every_store_failure_key_has_words() {
    if presentation::tree_missing() {
        return;
    }
    // The keys the helper's store declares (`extern NSString *const ...Failure...; // "key"`), and the Rust store's.
    let mut declared = Vec::new();
    for header in ["SZFriendsOutbox.h", "SZFriendsTransfers.h"] {
        let text = std::fs::read_to_string(presentation::friends_dir().join("service/store").join(header)).unwrap();
        for line in text.lines().filter(|l| l.starts_with("extern NSString *const SZFriends") && l.contains("Failure"))
        {
            declared.push(line.split('"').nth(1).unwrap().to_owned());
        }
    }
    declared.sort();
    declared.dedup(); // both stores declare source_missing
    let mut known =
        [failure::NOT_DELIVERED_30_DAYS, failure::REFUSED, failure::SOURCE_MISSING, failure::DIGEST_MISMATCH];
    known.sort();
    assert_eq!(declared, known);
    let catalog = catalog::english();
    for key in known {
        let words = ["message.status.failed", "transfer.status.failed.out", "transfer.status.failed.in"]
            .iter()
            .any(|family| catalog.contains_key(format!("{family}.{key}").as_str()));
        assert!(words, "no words for the store's failure key {key}");
    }
}

#[test]
fn rows_and_back_arrows() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let list = builder(audience()).list(&everyone(&people), &preview_items(), &profile_raph(), "", now());
    for row in list["rows"].as_array().unwrap() {
        let style = if row["blocked"] == true { "muted" } else { "normal" };
        assert_eq!(row["style"], style);
    }
    let builder = builder(audience());
    let back = builder.details(&people["c_mei"], 1, now())["back"].clone();
    assert_eq!(back["badge_label"], "1");
    assert_eq!(back["accessibility_label"], "Back to the conversation with Mei, 1 waiting for you in Friends");
    let back = builder.profile(&profile_raph(), 3)["back"].clone();
    assert!(back["badge_count"] == 3 && back["accessibility_label"] == "Back to Friends, 3 waiting");
}
