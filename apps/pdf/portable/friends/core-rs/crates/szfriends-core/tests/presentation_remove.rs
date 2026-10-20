//! Removing people from the list (`SZFriendsPresentationRemoveTests.m`): every row's menu and its question for clients
//! that declared `list.menu`, the You row's empty menu, people off the list skipped by the list and the badge, and
//! snapshots for clients without `list.menu` left exactly as they were.
//!
//! The list-menu.json fixture is the list's people with three changed, so one list shows every kind of row: Tulip is a
//! former friend (Removed), Daniel a link contact (Removed, link_contact) and Priya a request this person sent
//! (OutgoingRequest); Kenji is off the list (Removed, left_list). With the You row as devices-list.json has it.

mod presentation;

use std::collections::HashMap;

use presentation::world::*;
use presentation::{expect_fixture, validate_snapshot};
use serde_json::{json, Value};
use szfriends_core::presentation::{Audience, DevicesFacts, PersonFacts, Relation, TransferState};

fn menu_audience() -> Audience {
    let mut audience = audience();
    audience.capabilities.insert("list.menu".into());
    audience
}

fn menu_people() -> HashMap<String, PersonFacts> {
    let mut people = presentation::world::people();
    people.get_mut("c_tulip").unwrap().relation = Relation::Removed;
    let daniel = people.get_mut("c_daniel").unwrap();
    daniel.relation = Relation::Removed;
    daniel.link_contact = true;
    people.get_mut("c_priya").unwrap().relation = Relation::OutgoingRequest;
    let kenji = people.get_mut("c_kenji").unwrap();
    kenji.relation = Relation::Removed;
    kenji.left_list = true;
    people
}

fn you_only() -> DevicesFacts {
    let profile = profile_raph();
    let you = PersonFacts {
        conversation_id: "you".into(),
        name: profile.name,
        friends_id: Some(profile.friends_id),
        picture: profile.picture,
        relation: Relation::Friend,
        last_interaction_at: hk("2026-10-12 15:02"),
        ..Default::default()
    };
    let preview = transfer(
        "t_6a2e9f14",
        true,
        "2026-10-12 15:02",
        "Bracket drawing rev C.pdf",
        41_203_776,
        TransferState::Sending,
    );
    DevicesFacts { now: now(), you: Some(you), you_preview: Some(preview), ..Default::default() }
}

fn menu_list(audience: Audience, people: &[PersonFacts]) -> Value {
    let mut builder = builder(audience);
    builder.devices = Some(you_only());
    let mut list = builder.list(people, &preview_items(), &profile_raph(), "", now());
    list["join_requests"] = json!([]);
    builder.list_with_devices(list, people, "", now())
}

fn row<'a>(list: &'a Value, id: &str) -> Option<&'a Value> {
    list["rows"].as_array().unwrap().iter().find(|r| r["conversation_id"] == id)
}

#[test]
fn every_kind_of_row_has_its_menu() {
    if presentation::tree_missing() {
        return;
    }
    let list = menu_list(menu_audience(), &everyone(&menu_people()));
    expect_fixture(&list, "list-menu.json", "list");
    assert!(row(&list, "c_kenji").is_none(), "someone off the list has no row");
    assert_eq!(row(&list, "you").unwrap()["menu"], json!([]), "the You row's menu is empty");
    let mei = &row(&list, "c_mei").unwrap()["menu"][0];
    assert_eq!(
        (&mei["action"], &mei["label"], &mei["style"]),
        (&json!("remove_friend"), &json!("Remove"), &json!("destructive"))
    );
    assert!(mei["arm"].is_null());
    assert_eq!(mei["confirm"]["option"], json!({"label": "Also delete chat history", "field": "delete_history"}));
    let priya = &row(&list, "c_priya").unwrap()["menu"][0];
    assert_eq!(priya["label"], "Cancel request");
    let confirm = &priya["confirm"];
    assert_eq!(
        (&confirm["title"], &confirm["confirm_label"], &confirm["cancel_label"]),
        (&json!("Cancel your request to Priya?"), &json!("Cancel request"), &json!("Keep request"))
    );
    assert!(confirm["body"].as_str().unwrap().starts_with("Priya won’t get your request, and leaves your list."));
    let jonas = &row(&list, "c_jonas").unwrap()["menu"][0]["confirm"];
    assert!(jonas["body"].as_str().unwrap().starts_with("Jonas leaves your list and stays blocked."), "{jonas}");
    let lena = &row(&list, "c_lena").unwrap()["menu"][0]["confirm"];
    assert_eq!(lena["title"], "Remove Lena?");
    assert!(lena["body"]
        .as_str()
        .unwrap()
        .starts_with("Lena leaves your list. Either of you can send a new request later."));
}

#[test]
fn without_history_the_question_says_nothing_of_it() {
    if presentation::tree_missing() {
        return;
    }
    let mut people = menu_people();
    for person in people.values_mut() {
        person.last_preview_item_id = None;
    }
    let list = menu_list(menu_audience(), &everyone(&people));
    validate_snapshot(&list, "list", "no history");
    for row in list["rows"].as_array().unwrap() {
        for action in row["menu"].as_array().unwrap() {
            let confirm = &action["confirm"];
            assert!(confirm.get("option").is_none() && !confirm["body"].as_str().unwrap().contains("history"), "{row}");
        }
    }
    // Tulip has no name yet, so her Friends ID names her.
    assert_eq!(
        row(&list, "c_tulip").unwrap()["menu"][0]["confirm"],
        json!({"title": "Remove tulip\u{2011}canyon?",
               "body": "tulip\u{2011}canyon leaves your list. Either of you can send a new request later.",
               "confirm_label": "Remove", "cancel_label": "Cancel", "destructive": true})
    );
}

#[test]
fn a_client_without_list_menu_gets_no_menu() {
    if presentation::tree_missing() {
        return;
    }
    let everyone_now = everyone(&presentation::world::people());
    let list = builder(audience()).list(&everyone_now, &preview_items(), &profile_raph(), "", now());
    let with_you = menu_list(audience(), &everyone(&menu_people()));
    for row in list["rows"].as_array().unwrap().iter().chain(with_you["rows"].as_array().unwrap()) {
        assert!(row.get("menu").is_none(), "no menu key: {row}");
    }
}

#[test]
fn someone_off_the_list() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let mut people = presentation::world::people();
    let before = builder.badge(&everyone(&people), 0)["count"].as_i64().unwrap();
    let kenji = people.get_mut("c_kenji").unwrap();
    kenji.relation = Relation::Removed;
    kenji.left_list = true;
    let kenji = kenji.clone();
    assert_eq!(
        builder.badge(&everyone(&people), 0)["count"].as_i64().unwrap(),
        before - 1,
        "his offer no longer counts"
    );
    let list = builder.list(std::slice::from_ref(&kenji), &preview_items(), &profile_raph(), "", now());
    assert!(list["rows"].as_array().unwrap().is_empty());
    assert_eq!(list["empty"]["title"], json!(builder.strings().text("list.empty.title")));
    assert!(list["empty"].get("kind").is_none(), "nobody listed: the empty list");
    let list = builder.list(std::slice::from_ref(&kenji), &preview_items(), &profile_raph(), "Kenji", now());
    assert!(list["rows"].as_array().unwrap().is_empty(), "a filter does not bring him back");
    validate_snapshot(&list, "list", "off the list");
    assert!(builder.details(&kenji, 0, now()).is_object(), "his details still open");
}

#[test]
fn a_friends_details_ask_the_menus_question() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = presentation::world::people();
    let mei = &people["c_mei"];
    let details = builder.details(mei, 0, now());
    let remove = &details["actions"][1];
    assert_eq!((&remove["action"], &remove["label"]), (&json!("remove_friend"), &json!("Remove friend")));
    assert_eq!(remove["note"], "Takes Mei off your list. Mei can send you a new request.");
    let menu = menu_list(menu_audience(), &everyone(&menu_people()));
    assert_eq!(remove["confirm"], row(&menu, "c_mei").unwrap()["menu"][0]["confirm"], "the same question as the menu");
}
