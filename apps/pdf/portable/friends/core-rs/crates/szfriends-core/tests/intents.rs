//! The intents of PROTOCOL.md against the fixture scenarios: every line of `fixtures/intents.jsonl` admitted and read
//! as the helper reads it, the field refusals the helper's own suites check (`SZFriendsHelperProcess*.m`), and the
//! replies whose words the presentation gives (`fixtures/replies/`, `frames/reply-error.json`), checked as the
//! Objective-C presentation tests check them.

mod presentation;

use std::collections::{BTreeSet, HashMap};

use presentation::world::*;
use presentation::{fixture, validate_result};
use serde_json::{json, Value};
use szfriends_core::identity::friends_id::WordList;
use szfriends_core::intents::{
    admit, error_frame, ok_frame, parse, Admission, Intent, IntentError, IntentState, LinkPayload, View,
};
use szfriends_core::presentation::mentions::{key_string, mention_link};
use szfriends_core::presentation::{PersonFacts, Relation};

struct World {
    people: HashMap<String, PersonFacts>,
    subscriptions: HashMap<String, String>,
    capabilities: BTreeSet<String>,
    sent: BTreeSet<String>,
}

impl World {
    fn new() -> Self {
        let mut people = presentation::world::people();
        let mut add = |id: &str, name: &str, friends_id: &str, relation: Relation| {
            let person = PersonFacts {
                conversation_id: id.into(),
                name: Some(name.into()),
                friends_id: Some(friends_id.into()),
                relation,
                ..Default::default()
            };
            people.insert(id.into(), person);
        };
        add("c_tomas", "Tomás Rivera", "juniper-spring", Relation::OutgoingRequest);
        add("c_gone", "Gone", "amber-falcon", Relation::Removed);
        add("you", "Raph", "cottage-violet", Relation::Friend);
        let subscriptions = [("s_2", "list"), ("s_4", "conversation"), ("s_6", "details")];
        Self {
            people,
            subscriptions: subscriptions.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            capabilities: ["attach.items", "drop.files", "assistant.chats"].iter().map(|s| s.to_string()).collect(),
            sent: BTreeSet::new(),
        }
    }
}

impl IntentState for World {
    fn relation(&self, conversation_id: &str) -> Option<Relation> {
        self.people.get(conversation_id).map(|p| p.relation)
    }
    fn mention_target(&self, conversation_id: &str) -> Option<(Option<String>, String, [u8; 32])> {
        let person = self.people.get(conversation_id)?;
        Some((person.name.clone(), person.friends_id.clone()?, person.identity_key?))
    }
    fn subscription_view(&self, subscription: &str) -> Option<String> {
        self.subscriptions.get(subscription).cloned()
    }
    fn word_list(&self) -> Option<&WordList> {
        WordList::bundled()
    }
    fn client_capabilities(&self) -> &BTreeSet<String> {
        &self.capabilities
    }
    fn sent_before(&self, client_token: &str) -> bool {
        self.sent.contains(client_token)
    }
}

fn intent(kind: &str, fields: Value) -> Value {
    let mut frame = fields;
    frame["type"] = json!(kind);
    frame["id"] = json!("1");
    frame
}

fn refusal(world: &World, kind: &str, fields: Value) -> (String, Option<String>) {
    let error: IntentError = parse(&intent(kind, fields), world).expect_err("refused");
    (error.code.to_owned(), error.details.get("field").and_then(Value::as_str).map(str::to_owned))
}

fn everything() -> Admission {
    Admission {
        has_store: true,
        store_needs_update: false,
        has_identity: true,
        devices: true,
        links: true,
        removed_computer: false,
        received_folder: true,
        files_again: true,
        notifications: true,
        test_home: true,
    }
}

#[test]
fn every_example_intent_reads_as_the_helper_reads_it() {
    if presentation::tree_missing() {
        return;
    }
    let world = World::new();
    let text = std::fs::read_to_string(presentation::friends_dir().join("fixtures/intents.jsonl")).unwrap();
    let mut kinds = BTreeSet::new();
    for line in text.lines().filter(|l| !l.is_empty()) {
        let frame: Value = serde_json::from_str(line).unwrap();
        let kind = frame["type"].as_str().unwrap().to_owned();
        if kind.starts_with("assistant_") {
            // A helper without assistant.scopes answers them unknown_intent.
            assert_eq!(admit(&kind, everything()).unwrap_err().code, "unknown_intent", "{line}");
            continue;
        }
        admit(&kind, everything()).unwrap_or_else(|e| panic!("{line}: {e:?}"));
        let parsed = parse(&frame, &world).unwrap_or_else(|e| panic!("{line}: {e:?}"));
        kinds.insert(kind);
        match parsed {
            Intent::SendMessage { text, attachments, .. } if frame["mentions"].is_array() => {
                // The @ chip became Mei's mention, written from this computer's own data.
                let mei = mention_link("Mei Lin", "jasmine-street", &key(KEY_MEI)).unwrap();
                assert_eq!(text, format!("{mei} has the bracket drawing. Ask her for rev B."));
                assert!(attachments.is_empty());
            }
            Intent::SendMessage { attachments, .. } if frame["attachments"].is_array() => {
                assert_eq!(attachments.len(), 1);
                assert_eq!(attachments[0].display_name.as_deref(), Some("Supplier contract v3.pdf"));
            }
            Intent::OpenLink { link: LinkPayload::Friend { friends_id, name, identity_key, .. }, .. } => {
                assert_eq!((friends_id.as_str(), name.as_str()), ("bonfire-otter", "Leo Park"));
                assert_eq!(key_string(&identity_key), KEY_LEO);
            }
            Intent::Subscribe { view: View::MessageStatus, message_ids, .. } => {
                assert_eq!(message_ids.unwrap().len(), 3);
            }
            Intent::JoinProfile { friends_id } => assert_eq!(friends_id, "cottage-violet"),
            Intent::SetReceivedFolder { path } => assert_eq!(path, "/Users/raph/Documents/From friends"),
            Intent::SearchMessages { limit, .. } => assert!(limit == 20 || limit == 50 || limit == 10),
            Intent::SetFocus { conversation_id } => {
                assert!(conversation_id.is_none() || conversation_id.as_deref() == Some("c_mei"))
            }
            Intent::SetNotifications { enabled, preview, background } => {
                assert_eq!((enabled, preview, background), (Some(true), Some(false), None))
            }
            Intent::TestNotificationResponse { key, reply_text } => {
                assert_eq!((key.as_str(), reply_text.as_deref()), ("message:i_81f2", Some("On it")))
            }
            _ => {}
        }
    }
    assert!(kinds.len() >= 49, "every intent the helper takes has an example: {}", kinds.len());
}

#[test]
fn gates() {
    if presentation::tree_missing() {
        return;
    }
    assert_eq!(admit("frobnicate", everything()).unwrap_err().code, "unknown_intent");
    let m1 = Admission { devices: false, ..everything() };
    assert_eq!(admit("join_profile", m1).unwrap_err().code, "unknown_intent", "devices only when announced");
    let no_links = Admission { links: false, ..everything() };
    assert_eq!(admit("open_link", no_links).unwrap_err().code, "unknown_intent", "links only when announced");
    assert!(admit("add_from_mention", no_links).is_ok(), "mentions are not links");
    let no_folder = Admission { received_folder: false, ..everything() };
    assert_eq!(admit("set_received_folder", no_folder).unwrap_err().code, "unknown_intent", "only when announced");
    let no_again = Admission { files_again: false, ..everything() };
    assert_eq!(admit("fetch_from_friend", no_again).unwrap_err().code, "unknown_intent", "only when announced");
    let quiet = Admission { notifications: false, ..everything() };
    for kind in ["set_focus", "set_notifications", "allow_notifications", "test_notification_response"] {
        assert_eq!(admit(kind, quiet).unwrap_err().code, "unknown_intent", "{kind} only with notifications");
    }
    let person_home = Admission { test_home: false, ..everything() };
    assert_eq!(admit("test_notification_response", person_home).unwrap_err().code, "unknown_intent");
    assert!(admit("set_focus", person_home).is_ok());
    let removed = Admission { removed_computer: true, ..everything() };
    let error = admit("send_message", removed).unwrap_err();
    assert_eq!(error.code, "not_allowed");
    let strings = builder(audience());
    let frame = error_frame("1", &error, strings.strings());
    assert!(frame["error"]["message"].as_str().unwrap().len() > 10, "{frame}");
    assert!(admit("search_messages", removed).is_ok() && admit("reset_friends", removed).is_ok());
    let no_identity = Admission { has_identity: false, ..everything() };
    assert_eq!(admit("send_message", no_identity).unwrap_err().code, "identity_unavailable");
    assert!(admit("delete_history", no_identity).is_ok());
    let no_store = Admission { has_store: false, has_identity: false, ..everything() };
    assert_eq!(admit("search_messages", no_store).unwrap_err().code, "internal");
    let newer = Admission { store_needs_update: true, ..no_store };
    assert_eq!(admit("search_messages", newer).unwrap_err().code, "not_allowed");
    assert!(admit("subscribe", no_store).is_ok());
}

#[test]
fn field_refusals() {
    if presentation::tree_missing() {
        return;
    }
    let world = World::new();
    let field = |code: &str, name: &str| (code.to_owned(), Some(name.to_owned()));
    assert_eq!(refusal(&world, "subscribe", json!({"view": "bogus"})), field("invalid_field", "view"));
    for ids in [
        json!([]),
        json!((0..17).map(|i| format!("m_{i}")).collect::<Vec<_>>()),
        json!([42]),
        json!([""]),
        json!("m_reply"),
    ] {
        let params = json!({"view": "message_status", "params": {"message_ids": ids}});
        assert_eq!(refusal(&world, "subscribe", params), field("invalid_field", "params.message_ids"));
    }
    let details = json!({"view": "details", "params": {"conversation_id": "c_nobody"}});
    assert_eq!(refusal(&world, "subscribe", details), field("not_found", "params.conversation_id"));
    assert_eq!(refusal(&world, "set_name", json!({"name": "Mei\u{7}"})).0, "name_invalid");
    assert_eq!(refusal(&world, "set_focus", json!({})), field("invalid_field", "conversation_id"));
    assert_eq!(refusal(&world, "set_focus", json!({"conversation_id": 3})), field("invalid_field", "conversation_id"));
    assert_eq!(refusal(&world, "set_notifications", json!({"preview": "no"})), field("invalid_field", "preview"));
    assert_eq!(refusal(&world, "dismiss_banner", json!({"kind": "other"})), field("invalid_field", "kind"));
    let click = json!({"key": "message:i_1", "action": "press"});
    assert_eq!(refusal(&world, "test_notification_response", click), field("invalid_field", "action"));
    let empty = json!({"key": "message:i_1", "action": "reply", "text": " "});
    assert_eq!(refusal(&world, "test_notification_response", empty), field("invalid_field", "text"));
    assert_eq!(refusal(&world, "set_name", json!({"name": "x".repeat(41)})).0, "name_invalid");
    assert!(matches!(parse(&intent("set_name", json!({"name": "  Mei  "})), &world),
                     Ok(Intent::SetName { name: Some(n) }) if n == "Mei"));
    assert!(matches!(parse(&intent("set_name", json!({"name": ""})), &world), Ok(Intent::SetName { name: None })));
    assert_eq!(refusal(&world, "add_by_id", json!({"friends_id": "not-a-real-id"})), field("id_invalid", "friends_id"));
    assert_eq!(refusal(&world, "open_conversation", json!({"conversation_id": "c_nobody"})).0, "not_found");
    let send = |id: &str, token: &str| json!({"conversation_id": id, "text": "hi", "client_token": token});
    assert_eq!(refusal(&world, "send_message", send("c_tomas", "token-0123456789abcdef")).0, "not_friends");
    assert_eq!(refusal(&world, "send_message", send("c_jonas", "token-0123456789abcdef")).0, "blocked");
    assert_eq!(refusal(&world, "send_message", send("c_mei", "short")), field("invalid_field", "client_token"));
    assert_eq!(refusal(&world, "reset_friends", json!({"confirm": "nope"})), field("invalid_field", "confirm"));
    assert_eq!(refusal(&world, "deny_join", json!({})), field("invalid_field", "join_id"));
    assert_eq!(refusal(&world, "enter_join_code", json!({"code": 4831})), field("invalid_field", "code"));
    assert_eq!(
        refusal(&world, "set_filter", json!({"subscription": "s_4", "query": "x"})),
        field("not_allowed", "subscription")
    );
    assert_eq!(refusal(&world, "load_earlier", json!({"subscription": "s_9"})), field("not_found", "subscription"));
    assert_eq!(
        refusal(&world, "search_messages", json!({"query": "x", "limit": null})),
        field("invalid_field", "limit")
    );
    assert_eq!(
        refusal(&world, "make_download_link", json!({"file": {"path": "/a.pdf"}, "expires_days": 2})),
        field("invalid_field", "expires_days")
    );
    assert_eq!(refusal(&world, "receive_link", json!({"payload": "f.AQ"})), field("invalid_field", "payload"));
    let files = json!({"conversation_id": "c_mei", "client_token": "token-0123456789abcdef",
                       "files": (0..101).map(|i| json!({"path": format!("/f{i}")})).collect::<Vec<_>>()});
    assert_eq!(refusal(&world, "send_files", files).0, "too_many_files");
    let relative = json!({"conversation_id": "c_mei", "client_token": "token-0123456789abcdef",
                          "files": [{"path": "/ok.pdf"}, {"path": "relative.pdf"}]});
    assert_eq!(refusal(&world, "send_files", relative), field("invalid_field", "files[1]"));
    // remove_friend takes anyone off the list but You; delete_history is a bool when present.
    for id in ["c_mei", "c_tomas", "c_gone", "c_jonas"] {
        assert!(
            matches!(
                parse(&intent("remove_friend", json!({"conversation_id": id})), &world),
                Ok(Intent::RemoveFriend { delete_history: false, .. })
            ),
            "{id}"
        );
    }
    assert!(matches!(
        parse(&intent("remove_friend", json!({"conversation_id": "c_gone", "delete_history": true})), &world),
        Ok(Intent::RemoveFriend { delete_history: true, .. })
    ));
    assert!(matches!(
        parse(&intent("remove_friend", json!({"conversation_id": "c_gone", "delete_history": null})), &world),
        Ok(Intent::RemoveFriend { delete_history: false, .. })
    ));
    assert_eq!(refusal(&world, "remove_friend", json!({"conversation_id": "you"})), ("not_allowed".to_owned(), None));
    assert_eq!(
        refusal(&world, "remove_friend", json!({"conversation_id": "c_nobody"})),
        field("not_found", "conversation_id")
    );
    for value in [json!("yes"), json!(1), json!({})] {
        let fields = json!({"conversation_id": "c_mei", "delete_history": value});
        assert_eq!(refusal(&world, "remove_friend", fields), field("invalid_field", "delete_history"));
    }
    // Only a client whose app has an assistant may say its assistant wrote something.
    let mut plain = World::new();
    plain.capabilities.clear();
    let via = json!({"conversation_id": "c_mei", "text": "hi", "client_token": "token-0123456789abcdef",
                     "via_assistant": true});
    assert_eq!(refusal(&plain, "send_message", via), field("not_allowed", "via_assistant"));
}

#[test]
fn mentions_in_what_is_sent() {
    if presentation::tree_missing() {
        return;
    }
    let mut world = World::new();
    let send = |world: &World, text: &str, mentions: Value| {
        let fields = json!({"conversation_id": "c_daniel", "text": text, "client_token": "token-0123456789abcdef",
                            "mentions": mentions});
        parse(&intent("send_message", fields), world)
    };
    let refused = |result: Result<Intent, IntentError>| {
        let error = result.unwrap_err();
        (error.code, error.details["field"].as_str().unwrap().to_owned())
    };
    assert_eq!(refused(send(&world, "Ask \u{FFFC}", json!([]))), ("invalid_field", "mentions".into()));
    assert_eq!(
        refused(send(&world, "Ask \u{FFFC}", json!([{"conversation_id": "c_gone"}]))),
        ("not_allowed", "mentions[0]".into())
    );
    assert_eq!(
        refused(send(&world, "Ask \u{FFFC}", json!([{"conversation_id": "c_nobody"}]))),
        ("not_found", "mentions[0]".into())
    );
    // What the person typed never becomes a mention, however it looks.
    let typed = mention_link("Kenji", "cedar-lantern", &key(KEY_FORGED)).unwrap();
    let Intent::SendMessage { text, .. } =
        send(&world, &format!("Ask \u{FFFC}, not {typed}"), json!([{"conversation_id": "c_mei"}])).unwrap()
    else {
        panic!("a message")
    };
    let mei = mention_link("Mei Lin", "jasmine-street", &key(KEY_MEI)).unwrap();
    assert_eq!(text, format!("Ask {mei}, not @Kenji"));
    // Sent before with this token: answered with what was sent then, nothing checked twice.
    world.sent.insert("token-0123456789abcdef".into());
    assert!(matches!(send(&world, "Ask \u{FFFC}", json!([])), Ok(Intent::Resend { message: true, .. })));
}

#[test]
fn replies_in_the_presentations_words() {
    if presentation::tree_missing() {
        return;
    }
    let world = World::new();
    let builder = builder(audience());
    let strings = builder.strings();
    let add_by_id = fixture("replies/add_by_id.json");
    let Intent::AddById { friends_id } =
        parse(&intent("add_by_id", json!({"friends_id": "willow-breeze"})), &world).unwrap()
    else {
        panic!("add_by_id")
    };
    assert_eq!(json!(strings.add_by_id_sent_message(&friends_id, false)), add_by_id["result"]["message"]);
    let online = strings.add_by_id_sent_message("willow-breeze", true);
    assert_eq!(
        online,
        "Request sent to willow\u{2011}breeze. They’ll get it while ShenzhenPDF, Shenzhen Files or \
         Shenzhen 3D is open for both of you, and you’ll be friends once they accept."
    );
    let mention = fixture("replies/add_from_mention.json");
    let fields = json!({"friends_id": "bonfire-otter", "identity_key": KEY_LEO, "name": "Leo Park"});
    let Intent::AddFromMention { name, .. } = parse(&intent("add_from_mention", fields), &world).unwrap() else {
        panic!("add_from_mention")
    };
    assert_eq!(json!(strings.add_from_mention_sent_message(&name, false)), mention["result"]["message"]);
    validate_result(&mention["result"], "add_from_mention", "add_from_mention reply");
    // Refused, it names the person as the mention did; the wire details stay machine-readable.
    let mismatch =
        IntentError::new("mention_mismatch").worded(szfriends_core::intents::Wording::Named("Leo Park".into()));
    let frame = error_frame("52", &mismatch, strings);
    assert_eq!(frame["error"]["message"], "This link no longer matches Leo Park, so no request was sent.");
    assert_eq!(frame["error"]["details"], json!({}));

    // open_link's card from the payload the intent carries.
    let open = fixture("replies/open_link.json");
    let payload = "f.AbTdSXSAjDJSLILKcnTFnJ61gwHnPY127KX0X8oI-0OqyMnKy8zNzs_Q0dLT1NXW1w1ib25maXJlLW90dGVyCExlbyBQYXJr";
    let Intent::OpenLink { link: LinkPayload::Friend { name, friends_id, .. }, payload } =
        parse(&intent("open_link", json!({"payload": payload})), &world).unwrap()
    else {
        panic!("open_link")
    };
    let card = builder.friend_link_card(Some(&name), &friends_id, &payload, false);
    for key in ["kind", "title", "subtitle", "note", "actions"] {
        assert_eq!(card[key], open["result"]["card"][key], "card {key}");
    }
    validate_result(&json!({"card": card}), "open_link", "friend card");
    let already = builder.friend_link_card(Some(""), "bonfire-otter", &payload, true);
    assert_eq!(already["title"], "You’re already friends with bonfire\u{2011}otter");
    assert_eq!(already["actions"], json!([]));
    let download = builder.download_link_card("d.x");
    validate_result(&json!({"card": download}), "open_link", "download card");
    assert_eq!(download["actions"][0]["action"], "receive_link");
    let made = fixture("replies/make_download_link.json");
    assert_eq!(json!(builder.download_link_made_message(now() + 7.0 * 86_400.0)), made["result"]["message"]);
    assert_eq!(
        builder.link_receiving_message("Site photos.pdf", Some("Mei Wong")),
        "Receiving Site photos.pdf from Mei Wong. You’ll find it in your chat with Mei once it arrives."
    );
    assert!(builder.link_request_sent_message("Leo Park", false).contains("as soon as Friends reaches them"));

    // Replies as frames.
    assert_eq!(ok_frame("2", None), json!({"type": "reply", "re": "2", "ok": true, "result": {}}));
    let unknown = error_frame("3", &IntentError::new("unknown_intent"), strings);
    assert_eq!(unknown["error"], json!({"code": "unknown_intent", "message": null, "retryable": false, "details": {}}));
    let join = parse(&intent("enter_join_code", json!({"code": 4831})), &world).unwrap_err();
    assert!(error_frame("4", &join, strings)["error"]["message"].as_str().unwrap().contains("8 digits"));
}

#[test]
fn a_friend_link_payload_parses_back_and_leaves_out_a_name_that_does_not_fit() {
    use szfriends_core::intents::{base64url_encode, friend_link_payload, parse_link_payload, LinkPayload};
    assert_eq!(base64url_encode(b""), "");
    assert_eq!(base64url_encode(b"f"), "Zg");
    assert_eq!(base64url_encode(b"fo"), "Zm8");
    assert_eq!(base64url_encode(&[0xfb, 0xff]), "-_8");
    let payload = friend_link_payload(&[7; 32], &[9; 16], "brave-otter", "Mei Chen").unwrap();
    let parsed = parse_link_payload(&payload).unwrap();
    let expected = LinkPayload::Friend {
        identity_key: [7; 32],
        invite_token: [9; 16],
        friends_id: "brave-otter".into(),
        name: "Mei Chen".into(),
    };
    assert_eq!(parsed, expected);
    let long = "M".repeat(161);
    let Some(LinkPayload::Friend { name, .. }) =
        parse_link_payload(&friend_link_payload(&[7; 32], &[9; 16], "brave-otter", &long).unwrap())
    else {
        panic!("a payload")
    };
    assert!(name.is_empty(), "left out, not cut");
    assert!(friend_link_payload(&[7; 32], &[9; 16], "Brave Otter", "Mei").is_none());
}
