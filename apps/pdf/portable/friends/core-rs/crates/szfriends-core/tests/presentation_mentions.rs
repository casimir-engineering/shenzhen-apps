//! Mentions as the reader sees them (`SZFriendsPresentationMentionTests.m`): every way a mention resolves, the cards
//! and their actions, previews, search excerpts, and what a client without the `mentions` capability gets instead;
//! then search on a real store, where a message is found by the "@Name" it shows and never by an ID or key.

mod presentation;

use std::collections::HashMap;

use presentation::world::*;
use presentation::{validate_result, validate_snapshot, Scratch};
use serde_json::{json, Value};
use szfriends_core::presentation::mentions::mention_link;
use szfriends_core::presentation::search::{refold, search_messages};
use szfriends_core::presentation::{
    Audience, ItemFacts, MentionDirectory, PersonFacts, Relation, SearchHitFacts, SnapshotBuilder,
};
use szfriends_core::store::{Direction, Item, ItemKind, Person, Store};

fn mention_audience() -> Audience {
    let mut audience = audience();
    audience.capabilities.insert("mentions".into());
    audience
}

fn with_directory(audience: Audience, people: &HashMap<String, PersonFacts>) -> SnapshotBuilder {
    let mut builder = builder(audience);
    builder.mention_directory = Some(MentionDirectory::new(&everyone(people), &profile_raph()));
    builder
}

fn item<'a>(conversation: &'a Value, id: &str) -> &'a Value {
    conversation["items"].as_array().unwrap().iter().find(|i| i["item_id"] == id).expect(id)
}

fn daniel(builder: &SnapshotBuilder, people: &HashMap<String, PersonFacts>) -> Value {
    let built = builder.conversation(&people["c_daniel"], &items_for("c_daniel"), false, None, 2, now());
    validate_snapshot(&built, "conversation", "Daniel's mentions");
    built
}

#[test]
fn each_kind() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let conversation = daniel(&with_directory(mention_audience(), &people), &people);
    let mei = item(&conversation, "m_d0a1");
    // A friend: Raph's name for her, not Daniel's ("Mei"), linking to her conversation.
    assert_eq!(mei["text"], "[@Mei Lin](szfriends:mention?ref=0) has the bracket drawing. Ask her for rev B.");
    assert_eq!(
        (&mei["mentions"][0]["kind"], &mei["mentions"][0]["conversation_id"]),
        (&json!("friend"), &json!("c_mei"))
    );
    assert_eq!(mei["segments"][0], json!({"text": "@Mei Lin", "mention": 0}));
    // Nothing a view shows carries an ID or key, except the stranger card's Add, which must send them.
    let serialized = mei.to_string();
    assert!(!serialized.contains("jasmine") && !serialized.contains(KEY_MEI), "leak: {serialized}");
    let two = &item(&conversation, "m_d0a2")["mentions"];
    assert_eq!((&two[0]["kind"], &two[0]["label"]), (&json!("stranger"), &json!("@Leo Park")));
    assert_eq!((&two[1]["kind"], &two[1]["label"]), (&json!("you"), &json!("@Raph")));
    assert!(two[1]["tooltip"].is_null() && two[1]["card"].is_null());
    let add = &two[0]["card"]["actions"][0];
    assert_eq!(
        add,
        &json!({"action": "add_from_mention", "label": "Add", "style": "primary",
                            "friends_id": "bonfire-otter", "identity_key": KEY_LEO, "name": "Leo Park"})
    );
    assert_eq!(two[0]["card"]["id_label"], "Friends ID bonfire\u{2011}otter");
    let three = &item(&conversation, "m_d0a3")["mentions"];
    let actions: Vec<&Value> = three[0]["card"]["actions"].as_array().unwrap().iter().map(|a| &a["action"]).collect();
    assert_eq!(actions, [&json!("accept_request"), &json!("decline_request"), &json!("block")]);
    assert_eq!(three[0]["card"]["conversation_id"], "c_lena");
    assert!(three[0]["card"]["actions"][2]["arm"].is_object());
    assert_eq!(three[1]["card"]["status_label"], "Blocked");
    assert_eq!(three[1]["card"]["actions"], json!([]));
    // Forged: Kenji's ID under someone else's key is plain text, no link and no card.
    let forged = item(&conversation, "m_d0a4");
    assert!(forged.get("mentions").is_none());
    assert_eq!(forged["text"], "Or ask @Kenji.");
    assert_eq!(forged["segments"], json!([{"text": "Or ask @Kenji."}]));
    // Raph's own message resolves the same way, and its spoken label reads the name.
    let reply = item(&conversation, "m_d0a5");
    assert!(reply["accessibility_label"].as_str().unwrap().contains("Thanks, I’ll ask @Priya Raman too."));
}

fn leo(relation: Relation) -> PersonFacts {
    PersonFacts {
        conversation_id: "c_leo".into(),
        name: Some("Leo".into()),
        friends_id: Some("bonfire-otter".into()),
        identity_key: Some(key(KEY_LEO)),
        relation,
        last_interaction_at: hk("2026-10-10 09:00"),
        ..Default::default()
    }
}

/// One message from Daniel naming Leo, built for `people` as Raph sees them.
fn leo_mention(people: &HashMap<String, PersonFacts>) -> Value {
    let link = mention_link("Leo Park", "bonfire-otter", &key(KEY_LEO)).unwrap();
    let message = message("m_leo", false, "2026-10-12 10:41", &link, None);
    let builder = with_directory(mention_audience(), people);
    let built = builder.conversation(&people["c_daniel"], &[message], false, None, 0, now());
    validate_snapshot(&built, "conversation", "a mention of Leo");
    item(&built, "m_leo")["mentions"][0].clone()
}

#[test]
fn what_is_between_them_decides_the_card() {
    if presentation::tree_missing() {
        return;
    }
    let mut people = people();
    let mention = leo_mention(&people);
    assert_eq!(mention["tooltip"], "Leo Park isn’t your friend yet");
    assert!(mention["card"]["status_label"].is_null() && mention["card"]["conversation_id"].is_null());
    people.insert("c_leo".into(), leo(Relation::OutgoingRequest));
    let mention = leo_mention(&people);
    assert_eq!(mention["card"]["status_label"], "Request sent");
    assert_eq!(mention["card"]["actions"], json!([]));
    assert_eq!(mention["tooltip"], "You asked Leo Park to be friends");
    people.insert("c_leo".into(), leo(Relation::Removed));
    assert_eq!(leo_mention(&people)["card"]["actions"][0]["action"], "add_from_mention");
    // A friend shows under Raph's own name for him; the card is gone.
    people.insert("c_leo".into(), leo(Relation::Friend));
    let mention = leo_mention(&people);
    assert_eq!((&mention["kind"], &mention["label"]), (&json!("friend"), &json!("@Leo")));
    assert_eq!(mention["tooltip"], "Open your chat with Leo");
    // The host vouched that bonfire-otter now belongs to someone else: no Add, and the card says why.
    people.remove("c_leo");
    let holder = PersonFacts {
        conversation_id: "c_holder".into(),
        identity_key: Some(key(KEY_FORGED)),
        friends_id_confirmed: true,
        ..leo(Relation::Removed)
    };
    people.insert("c_holder".into(), holder);
    let mention = leo_mention(&people);
    assert_eq!(mention["card"]["actions"], json!([]));
    assert_eq!(
        mention["card"]["status_label"],
        "This link no longer matches Leo Park: bonfire\u{2011}otter belongs to someone else now."
    );
}

#[test]
fn plain_text_cases() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let own_id = mention_link("Raph", "cottage-violet", &key(KEY_LEO)).unwrap();
    let mei = mention_link("Mei", "jasmine-street", &key(KEY_MEI)).unwrap();
    let message = message("m_x", false, "2026-10-12 10:41", &format!("{own_id} and {mei}"), None);
    let builder = with_directory(mention_audience(), &people);
    let built = builder.conversation(&people["c_daniel"], std::slice::from_ref(&message), false, None, 0, now());
    let x = item(&built, "m_x");
    assert_eq!(x["text"], "@Raph and [@Mei Lin](szfriends:mention?ref=0)", "the next link is still ref 0");
    assert_eq!(x["mentions"].as_array().unwrap().len(), 1);
    let bare = builder_without_directory();
    let built = bare.conversation(&people["c_daniel"], &[message], false, None, 0, now());
    let x = item(&built, "m_x");
    assert_eq!(x["text"], "@Raph and @Mei", "no directory: the sender's names as text");
    assert!(x.get("mentions").is_none());
}

fn builder_without_directory() -> SnapshotBuilder {
    builder(mention_audience())
}

#[test]
fn a_client_without_mentions() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let builder = with_directory(audience(), &people);
    let conversation = daniel(&builder, &people);
    let mei = item(&conversation, "m_d0a1");
    assert_eq!(mei["text"], "@Mei Lin has the bracket drawing. Ask her for rev B.");
    assert!(mei.get("mentions").is_none());
    assert_eq!(mei["segments"], json!([{"text": "@Mei Lin has the bracket drawing. Ask her for rev B."}]));
    assert!(conversation["composer"].get("mention_note").is_none());
    let list = builder.list(&everyone(&people), &preview_items(), &profile_raph(), "", now());
    assert!(list["rows"].as_array().unwrap().iter().all(|row| row.get("mentionable").is_none()));
}

#[test]
fn composing_mentions_and_previews() {
    if presentation::tree_missing() {
        return;
    }
    let mut people = people();
    let builder = with_directory(mention_audience(), &people);
    let composer = daniel(&builder, &people)["composer"].clone();
    assert_eq!(
        composer["mention_note"],
        "Daniel can click the name to open their chat with that person, or to add \
                                         them if they aren’t friends yet."
    );
    assert!(composer["hint"].as_array().unwrap().contains(&json!({"text": "@", "emphasis": true})));
    let list = builder.list(&everyone(&people), &preview_items(), &profile_raph(), "", now());
    validate_snapshot(&list, "list", "list with mentions");
    let mentionable: HashMap<String, Value> = list["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| (r["conversation_id"].as_str().unwrap().to_owned(), r["mentionable"].clone()))
        .collect();
    assert_eq!(
        (&mentionable["c_mei"], &mentionable["c_lena"], &mentionable["c_jonas"]),
        (&json!(true), &json!(false), &json!(false))
    );
    let lena = builder.conversation(&people["c_lena"], &[], false, None, 1, now());
    assert!(lena["composer"]["mention_note"].is_null(), "no note where nothing can be sent");
    // List previews read "@Name", resolved against the people the list shows, never the link.
    let daniel = people.get_mut("c_daniel").unwrap();
    daniel.last_message_item_id = Some("m_d0a1".into());
    daniel.last_interaction_at = hk("2026-10-12 14:45");
    let mut previews = preview_items();
    previews.insert("m_d0a1".into(), items_for("c_daniel")[0].clone());
    let list = presentation::world::builder(audience()).list(&everyone(&people), &previews, &profile_raph(), "", now());
    let row = list["rows"].as_array().unwrap().iter().find(|r| r["conversation_id"] == "c_daniel").unwrap();
    assert_eq!(row["subtitle"], "Daniel: @Mei Lin has the bracket drawing. Ask her for rev B.");
    assert!(row["accessibility_label"].as_str().unwrap().contains("@Mei Lin has"));
}

fn hit(text: &str, term: &str) -> SearchHitFacts {
    let start = text.find(term).unwrap();
    SearchHitFacts {
        conversation_id: "c_daniel".into(),
        item_id: "m_hit".into(),
        sent_at: hk("2026-10-12 10:40"),
        outgoing: false,
        text: text.into(),
        match_ranges: vec![(text[..start].encode_utf16().count(), term.encode_utf16().count())],
    }
}

#[test]
fn search_excerpts_show_names() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let builder = with_directory(audience(), &people);
    let text = items_for("c_daniel")[0].text.clone().unwrap();
    let hits = [hit(&text, "Mei"), hit(&text, "jasmine"), hit(&text, KEY_MEI), hit(&text, "drawing")];
    let result = builder.search_result(&hits, &people, false, now());
    validate_result(&result, "search_messages", "search with mentions");
    let results = result["results"].as_array().unwrap();
    assert_eq!(results.len(), 2, "the ID and key matches are dropped: {result}");
    assert_eq!(
        results[0]["excerpt"],
        json!([{"text": "@Mei Lin", "match": true},
                                             {"text": " has the bracket drawing. Ask her for rev B."}])
    );
    assert_eq!(
        results[1]["excerpt"],
        json!([{"text": "@Mei Lin has the bracket "}, {"text": "drawing", "match": true},
                                             {"text": ". Ask her for rev B."}])
    );
}

fn store_with(people: &HashMap<String, PersonFacts>, items: &[(&str, ItemFacts)]) -> (Scratch, Store) {
    let scratch = Scratch::new("search");
    let mut store = Store::open(scratch.0.join("state")).unwrap();
    for facts in people.values() {
        let mut person = Person::new(facts.relation);
        person.conversation_id = facts.conversation_id.clone();
        person.identity_key = facts.identity_key;
        person.name = facts.name.clone();
        store.save_person(&person).unwrap();
    }
    for (conversation, facts) in items {
        let item = Item {
            item_id: facts.item_id.clone(),
            conversation_id: (*conversation).to_owned(),
            kind: ItemKind::Message,
            direction: if facts.outgoing { Direction::Outgoing } else { Direction::Incoming },
            text: facts.text.clone(),
            transfer_id: None,
            sent_at: facts.sent_at,
            received_at: facts.sent_at,
            via_assistant: facts.via_assistant,
        };
        store.insert_item(&item).unwrap();
    }
    (scratch, store)
}

#[test]
fn search_messages_on_a_store() {
    if presentation::tree_missing() {
        return;
    }
    let people = people();
    let mut items: Vec<(&str, ItemFacts)> = items_for("c_mei").into_iter().map(|i| ("c_mei", i)).collect();
    items.extend(items_for("c_daniel").into_iter().map(|i| ("c_daniel", i)));
    let items: Vec<(&str, ItemFacts)> = items.into_iter().filter(|(_, i)| i.text.is_some()).collect();
    let (_scratch, store) = store_with(&people, &items);
    let builder = with_directory(audience(), &people);
    // The reply fixture: "pages" in Mei's conversation.
    let (hits, more) = search_messages(&store, "pages", Some("c_mei"), 20).unwrap();
    let result = builder.search_result(&hits, &people, more, now());
    let expected = &presentation::fixture("replies/search_messages.json")["result"];
    if let Some(d) = presentation::difference(&result, expected, "result") {
        panic!("search_messages result differs at {d}");
    }
    // Before the refold the index holds each mention's ID: the row it finds matches nothing anyone sees, so no hit...
    let raw = store.search("jasmine", Some(&["c_daniel".to_owned()]), 20).unwrap();
    assert_eq!(raw.len(), 1, "the store alone finds the ID");
    assert!(search_messages(&store, "jasmine", Some("c_daniel"), 20).unwrap().0.is_empty());
    // ...and a hit whose match is only in a link shows nothing either, wherever it comes from.
    let hidden = hit(raw[0].text.as_str(), "jasmine");
    assert_eq!(builder.search_result(&[hidden], &people, false, now())["results"], json!([]));
    // ...and after it the store finds a message only by what it shows: the name, never the ID or key.
    assert!(refold(&store).unwrap() > 0 && refold(&store).unwrap() == 0, "refolded once");
    assert!(search_messages(&store, "jasmine", None, 20).unwrap().0.is_empty());
    assert!(search_messages(&store, &KEY_MEI[..12], None, 20).unwrap().0.is_empty());
    let (hits, _) = search_messages(&store, "mei", Some("c_daniel"), 20).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].match_ranges, [(1, 4)], "the label inside its brackets");
    let result = builder.search_result(&hits, &people, false, now());
    assert_eq!(result["results"][0]["excerpt"][0], json!({"text": "@Mei Lin", "match": true}));
    // A search that only an empty query would match returns nothing, and the page says when there is more.
    assert!(search_messages(&store, "  ", None, 20).unwrap().0.is_empty());
    let (hits, more) = search_messages(&store, "a", None, 1).unwrap();
    assert!(hits.len() == 1 && more);
}
