//! What the assistant work added (`SZFriendsPresentationAssistantTests.m`): "Via the assistant" on both sides,
//! Markdown text, rows that say why they refuse dragged files, an unconfirmed Add by ID answer waiting like a request,
//! deletion questions that admit AI chats keep what they quoted, message_status, the queued note naming every app, and
//! Cancel on a message that has not left; and Delete chat history in details and Settings
//! (`SZFriendsPresentationHistoryTests.m`).

mod presentation;

use std::collections::HashMap;

use presentation::validate_snapshot;
use presentation::world::*;
use serde_json::{json, Map, Value};
use szfriends_core::presentation::{
    Audience, IdentityState, ItemFacts, OutboxState, PersonFacts, Picture, ProfileFacts, Relation, SnapshotBuilder,
};

fn item<'a>(conversation: &'a Value, id: &str) -> &'a Value {
    conversation["items"].as_array().unwrap().iter().find(|i| i["item_id"] == id).expect(id)
}

fn conversation(builder: &SnapshotBuilder, person: &PersonFacts, items: &[ItemFacts]) -> Value {
    let data = builder.conversation(person, items, false, None, 0, now());
    validate_snapshot(&data, "conversation", &person.conversation_id);
    data
}

fn with(capability: &str) -> Audience {
    let mut audience = audience();
    audience.capabilities.insert(capability.into());
    audience
}

#[test]
fn assistant_labels() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = people();
    let mei = conversation(&builder, &people["c_mei"], &items_for("c_mei"));
    let (note, contract) = (item(&mei, "m_5f2a90c1"), item(&mei, "t_91c4e2a7"));
    assert_eq!(note["assistant_label"], "Via the assistant");
    assert!(note["accessibility_label"].as_str().unwrap().contains("via the assistant"));
    assert_eq!(contract["assistant_label"], "Via the assistant");
    assert!(contract["accessibility_label"].as_str().unwrap().contains("2.4 MB, via the assistant"));
    assert!(item(&mei, "m_a4109f52")["assistant_label"].is_null(), "Mei typed this herself");
    for message in mei["items"].as_array().unwrap().iter().filter(|i| i["kind"] == "message") {
        assert_eq!(message["text_format"], "markdown");
    }
    // The friend's assistant is named as theirs, so nobody wonders whose it was.
    let kenji = conversation(&builder, &people["c_kenji"], &items_for("c_kenji"));
    let incoming = item(&kenji, "m_1b7e44d9");
    assert_eq!(incoming["assistant_label"], "Via Kenji’s assistant");
    assert!(incoming["accessibility_label"]
        .as_str()
        .unwrap()
        .starts_with("Kenji Sato, 13:09, via Kenji’s assistant: "));
    // A queued message reads its status after the text; the assistant still comes with the time.
    let queued = ItemFacts {
        via_assistant: true,
        ..message("m_q", true, "2026-10-12 14:40", "On my way", Some(OutboxState::Queued))
    };
    let priya = conversation(&builder, &people["c_priya"], &[queued]);
    assert!(item(&priya, "m_q")["accessibility_label"]
        .as_str()
        .unwrap()
        .starts_with("You, 14:40, via the assistant: "));
}

#[test]
fn drop_refusals() {
    if presentation::tree_missing() {
        return;
    }
    let mut people = people();
    people.get_mut("c_priya").unwrap().relation = Relation::Removed;
    people.get_mut("c_daniel").unwrap().relation = Relation::OutgoingRequest;
    people.get_mut("c_mei").unwrap().key_change_pending = true;
    let all = everyone(&people);
    let list = builder(audience()).list(&all, &preview_items(), &profile_raph(), "", now());
    validate_snapshot(&list, "list", "drop refusals");
    let expected: HashMap<&str, &str> = HashMap::from([
        ("c_lena", "Lena isn’t your friend yet"),
        ("c_daniel", "Daniel isn’t your friend yet"),
        ("c_priya", "Priya isn’t your friend"),
        ("c_jonas", "You blocked Jonas"),
        ("c_mei", "Review Mei’s new key first"),
    ]);
    for row in list["rows"].as_array().unwrap() {
        match expected.get(row["conversation_id"].as_str().unwrap()) {
            Some(refusal) => assert!(row["drop_label"].is_null() && row["drop_refusal"] == *refusal, "{row}"),
            None => assert!(row["drop_label"].is_string() && row["drop_refusal"].is_null(), "{row}"),
        }
    }
    let no_drops = Audience { capabilities: ["attach.items".to_owned()].into(), ..audience() };
    let list = builder(no_drops).list(&all, &preview_items(), &profile_raph(), "", now());
    assert!(list["rows"].as_array().unwrap().iter().all(|r| r["drop_label"].is_null() && r["drop_refusal"].is_null()));
}

#[test]
fn an_unconfirmed_answer_waits_like_a_request() {
    if presentation::tree_missing() {
        return;
    }
    let answer = PersonFacts {
        conversation_id: "c_answer".into(),
        name: Some("Lena".into()),
        relation: Relation::IncomingRequest,
        unconfirmed_answer_id: Some("tulip-canyon".into()),
        request_at: Some(hk("2026-10-12 14:40")),
        last_interaction_at: hk("2026-10-12 14:40"),
        comparison_code: Some("418270".into()),
        ..Default::default()
    };
    let list = builder(audience()).list(std::slice::from_ref(&answer), &preview_items(), &profile_raph(), "", now());
    let row = &list["rows"][0];
    assert_eq!(row["subtitle"], "Answered your request for tulip\u{2011}canyon");
    assert!(row["waiting"]["kind"] == "request" && row["actions"].as_array().unwrap().len() == 3);
    let card = conversation(&builder(audience()), &answer, &[])["request"].clone();
    assert_eq!(card["title"], "Lena answered your request");
    assert!(card["subtitle"].as_str().unwrap().starts_with("You asked for tulip\u{2011}canyon · "));
    assert!(card["footnote"]
        .as_str()
        .unwrap()
        .starts_with("Friends couldn’t confirm that tulip\u{2011}canyon belongs to Lena."));
    assert!(card["direction"] == "incoming" && card["actions"][0]["action"] == "accept_request");
}

#[test]
fn deletion_wording_admits_what_ai_chat_quoted() {
    if presentation::tree_missing() {
        return;
    }
    let all = everyone(&people());
    let with_ai = builder(with("assistant.chats")).settings(&profile_raph(), &all);
    let without = builder(audience()).settings(&profile_raph(), &all);
    validate_snapshot(&with_ai, "settings", "assistant.chats");
    let quoted = "AI chat answers that quoted";
    let body = |s: &Value, part: &str| s[part]["confirm"]["body"].as_str().unwrap().to_owned();
    assert!(body(&with_ai, "history").contains(quoted) && body(&with_ai, "reset").contains(quoted));
    assert!(!body(&without, "history").contains(quoted) && !body(&without, "reset").contains(quoted));
    let broken = ProfileFacts { identity_state: IdentityState::Unavailable, ..profile_raph() };
    let list = builder(with("assistant.chats")).list(&[], &HashMap::new(), &broken, "", now());
    assert!(list["banner"]["action"]["confirm"]["body"].as_str().unwrap().contains(quoted));
}

#[test]
fn message_status_rows() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = people();
    // No delivery record, or nobody to name: no row rather than a guess.
    let unrecorded =
        ItemFacts { conversation_id: Some("c_mei".into()), ..message("m_old", true, "2026-10-01 09:00", "Old", None) };
    let orphan = ItemFacts {
        conversation_id: Some("c_deleted".into()),
        ..message("m_gone", true, "2026-10-01 09:00", "Gone", Some(OutboxState::Queued))
    };
    assert_eq!(builder.message_status_view(&[unrecorded, orphan], &people), json!({"messages": []}));
}

#[test]
fn the_queued_note_names_every_app() {
    if presentation::tree_missing() {
        return;
    }
    let files = Audience { app_name: "Shenzhen Files".into(), ..audience() };
    let priya = conversation(&builder(files.clone()), &people()["c_priya"], &items_for("c_priya"));
    let expected = "Messages and files send when Priya is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open.";
    assert_eq!(priya["composer"]["note"], expected);
    let shared = builder(files).strings().static_strings()["queued_note"].replace("{first}", "Priya");
    assert_eq!(shared, expected, "the hosts' copy says the same");
}

#[test]
fn cancel_while_nothing_has_left() {
    if presentation::tree_missing() {
        return;
    }
    let builder = builder(audience());
    let people = people();
    let states = [
        OutboxState::Queued,
        OutboxState::Connecting,
        OutboxState::Sending,
        OutboxState::Delivered,
        OutboxState::Failed,
    ];
    let mut items: Vec<ItemFacts> =
        states.iter().map(|s| message(&format!("m_{}", *s as i64), true, "2026-10-12 09:00", "Hi", Some(*s))).collect();
    let cancelled =
        ItemFacts { cancelled: true, ..message("m_cancelled", true, "2026-10-12 09:01", "Wrong page", None) };
    items.push(cancelled.clone());
    let mei = conversation(&builder, &people["c_mei"], &items);
    for state in states {
        let built = item(&mei, &format!("m_{}", state as i64));
        let waits = matches!(state, OutboxState::Queued | OutboxState::Connecting);
        let offers = built["actions"].as_array().unwrap().iter().any(|a| a["action"] == "cancel_message");
        assert_eq!(offers, waits, "{state:?}");
    }
    let withdrawn = item(&mei, "m_cancelled");
    assert_eq!(withdrawn["status"], json!({"state": "cancelled", "label": "Cancelled"}));
    assert!(
        withdrawn["actions"] == json!([]) && withdrawn["accessibility_label"] == "You, 09:01: Wrong page. Cancelled."
    );
    let cancelled = ItemFacts { conversation_id: Some("c_mei".into()), ..cancelled };
    assert_eq!(
        builder.message_status_view(std::slice::from_ref(&cancelled), &people),
        json!({"messages": [{"message_id": "m_cancelled", "status": withdrawn["status"]}]})
    );
    assert_eq!(
        builder.row_preview(&cancelled, &people["c_mei"]),
        ("Cancelled · Wrong page".to_owned(), "you said Wrong page, cancelled".to_owned())
    );
    let s = builder.strings();
    let mut details: Map<String, Value> =
        json!({"field": "message_id", "name": "Mei Lin", "friends_id": "orchid-summit", "state": "delivered"})
            .as_object()
            .unwrap()
            .clone();
    assert_eq!(s.error_message("stale", &details).unwrap(), "Mei already has it, so it can’t be cancelled.");
    details.insert("state".into(), json!("sending"));
    assert_eq!(
        s.error_message("stale", &details).unwrap(),
        "It’s already on its way to Mei, so it can’t be cancelled."
    );
    details.remove("name");
    assert!(s.error_message("stale", &details).unwrap().contains("orchid\u{2011}summit,"));
    details.insert("state".into(), json!("failed"));
    assert_eq!(s.error_message("stale", &details), s.error_message("stale", &Map::new()));
}

fn mei(relation: Relation) -> PersonFacts {
    PersonFacts {
        conversation_id: "c_mei".into(),
        name: Some("Mei Lin".into()),
        friends_id: Some("jasmine-street".into()),
        picture: Picture::animal(1, 7),
        relation,
        last_interaction_at: hk("2026-10-12 10:00"),
        ..Default::default()
    }
}

fn history_action(audience: Audience, person: &PersonFacts) -> Value {
    let data = builder(audience).details(person, 0, now());
    validate_snapshot(&data, "details", &person.conversation_id);
    data["actions"].as_array().unwrap().iter().find(|a| a["action"] == "delete_history").unwrap().clone()
}

fn says_what_goes_and_stays(body: &str) {
    for part in [
        "messages and file history",
        "deleted from this computer",
        "won’t be sent",
        "keep",
        "Files you received stay in Received files.",
    ] {
        assert!(body.contains(part), "says \"{part}\": {body}");
    }
}

#[test]
fn delete_chat_history_in_details_and_settings() {
    if presentation::tree_missing() {
        return;
    }
    let data = builder(audience()).details(&mei(Relation::Friend), 0, now());
    let action = &data["actions"][0];
    assert!(
        action["action"] == "delete_history"
            && action["label"] == "Delete chat history…"
            && action["style"] == "destructive"
    );
    assert!(action.get("arm").is_none());
    let confirm = &action["confirm"];
    assert_eq!(
        (&confirm["title"], &confirm["confirm_label"]),
        (&json!("Delete your chat history with Mei?"), &json!("Delete History"))
    );
    assert!(confirm["cancel_label"] == "Cancel" && confirm["destructive"] == true);
    let body = confirm["body"].as_str().unwrap();
    says_what_goes_and_stays(body);
    assert!(body.starts_with("Your messages and file history with Mei are deleted from this computer"));
    assert!(body.contains("Mei stays your friend and keeps their own copy of the chat.") && !body.contains("AI chat"));
    assert_eq!(action["note"], "Clears this chat on this computer. Mei stays your friend.");
    let blocked = history_action(audience(), &mei(Relation::Blocked))["confirm"]["body"].clone();
    assert!(blocked.as_str().unwrap().contains("Mei stays blocked") && !blocked.as_str().unwrap().contains("friend"));
    let removed = history_action(audience(), &mei(Relation::Removed));
    assert!(
        !removed["confirm"]["body"].as_str().unwrap().contains("friend")
            && !removed["note"].as_str().unwrap().contains("friend")
    );
    says_what_goes_and_stays(removed["confirm"]["body"].as_str().unwrap());
    let with_ai = history_action(with("assistant.chats"), &mei(Relation::Friend))["confirm"]["body"].clone();
    assert!(with_ai
        .as_str()
        .unwrap()
        .ends_with("AI chat answers that quoted this chat stay in Chats until you delete them there."));

    // Settings says the same things for every chat.
    let all = everyone(&people());
    let plain = builder(audience()).settings(&profile_raph(), &all);
    let ai = builder(with("assistant.chats")).settings(&profile_raph(), &all);
    validate_snapshot(&ai, "settings", "history with AI chat");
    let body = plain["history"]["confirm"]["body"].as_str().unwrap();
    says_what_goes_and_stays(body);
    assert!(body.starts_with("Your messages and file history with every friend are deleted from this computer"));
    assert!(
        body.contains("You keep your friends, and they keep their own copies of your chats.")
            && !body.contains("AI chat")
    );
    let with_ai = ai["history"]["confirm"]["body"].as_str().unwrap();
    says_what_goes_and_stays(with_ai);
    assert!(with_ai.ends_with("AI chat answers that quoted your chats stay in Chats until you delete them there."));
    assert_eq!(plain["history"]["confirm"]["confirm_label"], confirm["confirm_label"], "one confirm button for both");
}
