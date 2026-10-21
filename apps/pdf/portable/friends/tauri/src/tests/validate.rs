//! The bridge's refusals, case for case with Shenzhen 3D's Electron tests (`electron/friends-bridge.test.cjs`), and
//! every intent example of PROTOCOL.md the panel sends.

use serde_json::{json, Value};

use super::*;

fn intents() -> Vec<Value> {
    let text = include_str!("../../../fixtures/intents.jsonl");
    text.lines().filter(|l| !l.is_empty()).map(|l| serde_json::from_str(l).expect("a fixture line")).collect()
}

fn fields_of(intent: &Value) -> Value {
    let mut fields = intent.as_object().expect("an object").clone();
    fields.remove("type");
    fields.remove("id");
    Value::Object(fields)
}

fn rejects(kind: &str, fields: Value, field: &str) {
    assert_eq!(validate_intent(&json!(kind), &fields), Err(FieldError(field.into())), "{kind} {fields}");
}

#[test]
fn every_protocol_intent_example_the_panel_sends_passes_unchanged() {
    let uses_revision = |intent: &Value| {
        let text = intent.to_string();
        text.contains("\"revision\":{") || intent.get("via_assistant").is_some() || intent["view"] == "message_status"
    };
    let mut checked = 0;
    for intent in intents() {
        let kind = intent["type"].as_str().unwrap_or_default();
        if !INTENT_TYPES.contains(&kind) || uses_revision(&intent) {
            continue;
        }
        let fields = fields_of(&intent);
        let passed = validate_intent(&intent["type"], &fields).unwrap_or_else(|e| panic!("{kind}: {e:?}"));
        assert_eq!(Value::Object(passed), fields, "{kind}");
        checked += 1;
    }
    assert!(checked >= 40, "only {checked} intents checked");
    let covered: Vec<Value> = intents().iter().map(|i| i["type"].clone()).collect();
    for kind in INTENT_TYPES {
        assert!(covered.contains(&json!(kind)), "no fixture for {kind}");
        assert!(rule(kind).is_some(), "{kind} has no rule");
    }
}

#[test]
fn intents_the_bridge_owns_assistant_intents_and_revisions_never_come_from_the_page() {
    for kind in ["hello", "disable", "assistant_open_scope", "assistant_search", "assistant_read", "nonsense"] {
        rejects(kind, json!({}), "type");
    }
    let all = intents();
    let with_revision =
        all.iter().find(|i| i["type"] == "send_files" && i.to_string().contains("revision")).expect("a fixture");
    assert!(validate_intent(&json!("send_files"), &fields_of(with_revision)).is_err());
    let via_assistant = all.iter().find(|i| i.get("via_assistant").is_some()).expect("a fixture");
    rejects(via_assistant["type"].as_str().unwrap(), fields_of(via_assistant), "via_assistant");
    rejects("subscribe", json!({"view": "message_status", "params": {"message_ids": ["m_1"]}}), "view");
}

#[cfg(unix)]
#[test]
fn fields_are_checked_for_shape() {
    rejects("accept_offer", json!({"transfer_id": "../etc"}), "transfer_id");
    rejects("accept_offer", json!({"transfer_id": "t_1", "type": "block"}), "type");
    rejects("accept_offer", json!({"transfer_id": "t_1", "id": "9"}), "id");
    rejects("accept_offer", json!({"transfer_id": "t_1", "extra": true}), "extra");
    rejects("accept_offer", json!(["t_1"]), "fields");
    rejects("subscribe", json!({"view": "details"}), "params");
    rejects("subscribe", json!({"view": "list", "params": {"conversation_id": "c_1"}}), "params");
    let file =
        |path: &str| json!({"conversation_id": "c_1", "client_token": "a".repeat(32), "files": [{"path": path}]});
    rejects("send_files", file("relative/file.stl"), "files[0].path");
    rejects("send_files", file("/a/../b.stl"), "files[0].path");
    rejects("send_files", file("/a/./b.stl"), "files[0].path");
    rejects("send_files", file("/a//b.stl"), "files[0].path");
    rejects("send_files", file("/a/b.stl\0"), "files[0].path");
    rejects("send_files", file("/a/"), "files[0].path");
    assert!(validate_intent(&json!("send_files"), &file("/Users/someone/Gearbox.sz3d")).is_ok());
    let mut short = file("/a.stl");
    short["client_token"] = json!("short");
    rejects("send_files", short, "client_token");
    let mut empty = file("/a.stl");
    empty["files"] = json!([]);
    rejects("send_files", empty, "files");
    let mention = json!({"conversation_id": "c_1", "text": "hi", "client_token": "b".repeat(20),
                         "mentions": [{"conversation_id": "c_2", "key": 1}]});
    rejects("send_message", mention, "mentions[0]");
    rejects("set_picture", json!({"picture": {"kind": "image", "data_base64": "AAAA", "path": "/a.png"}}), "picture");
    rejects("set_picture", json!({"picture": {"kind": "image", "data_base64": "not base64!"}}), "picture.data_base64");
    rejects("reset_friends", json!({"confirm": "yes"}), "confirm");
    rejects("remove_friend", json!({"conversation_id": "c_1", "delete_history": "yes"}), "delete_history");
    rejects("remove_friend", json!({"conversation_id": "c_1", "delete_history": null}), "delete_history");
    for fields in [json!({"conversation_id": "c_1"}), json!({"conversation_id": "c_1", "delete_history": true})] {
        assert!(validate_intent(&json!("remove_friend"), &fields).is_ok(), "{fields}");
    }
    rejects("make_download_link", json!({"file": {"path": "/a.sz3d"}, "expires_days": 2}), "expires_days");
    rejects("set_name", json!({"name": "x".repeat(2000)}), "name");
    rejects("set_received_folder", json!({"path": "Downloads"}), "path");
    rejects("set_received_folder", json!({"path": "/Users/someone/../Downloads"}), "path");
    rejects("set_received_folder", json!({"path": 3}), "path");
    rejects("set_received_folder", json!({}), "path");
    assert!(validate_intent(&json!("set_received_folder"), &json!({"path": "/Users/someone/From friends"})).is_ok());
    assert!(validate_intent(&json!("subscribe"), &json!({"view": "received", "params": null})).is_ok());
}

#[cfg(windows)]
#[test]
fn windows_paths_are_plain_drive_paths() {
    assert!(plain_path(r"C:\Users\someone\Gearbox.sz3d"));
    assert!(plain_path(r"Z:\mapped share\Gearbox.sz3d"));
    // A share's path never reaches the disk, so no page can make Windows sign in to a server of its choosing.
    for path in [r"\\server\share\Gearbox.sz3d", r"\\?\UNC\server\share\a.stl", r"\\.\pipe\x", r"\\?\C:\a.stl"] {
        assert!(!plain_path(path), "{path}");
    }
    for path in [r"C:\a\..\b.stl", r"C:\a\.\b.stl", r"C:\a\\b.stl", r"C:\a\", "C:/a/b.stl", r"a\b", r"\a\b"] {
        assert!(!plain_path(path), "{path}");
    }
}

#[test]
fn only_a_media_store_item_passes_for_a_received_file_without_a_path() {
    assert!(media_store_uri("content://media/external/downloads/42"));
    assert!(media_store_uri("content://media/external_primary/file/7"));
    for uri in [
        "content://com.example.other/file/1",
        "content://media/",
        "content://media/../x",
        "content://media/external//1",
        "content://media/external/downloads/1?x=1",
        "file:///sdcard/Download/a.pdf",
        "/sdcard/Download/a.pdf",
    ] {
        assert!(!media_store_uri(uri), "{uri}");
    }
}

#[test]
fn notification_intents_take_a_conversation_or_none_and_booleans_and_never_a_test_response() {
    for fields in [json!({"conversation_id": "c_mei"}), json!({"conversation_id": null})] {
        assert_eq!(validate_intent(&json!("set_focus"), &fields).map(Value::Object), Ok(fields.clone()));
    }
    rejects("set_focus", json!({}), "conversation_id");
    rejects("set_focus", json!({"conversation_id": "../x"}), "conversation_id");
    rejects("set_focus", json!({"conversation_id": 3}), "conversation_id");
    for fields in [
        json!({"enabled": false}),
        json!({"preview": true}),
        json!({"background": true}),
        json!({"enabled": true, "preview": false}),
    ] {
        assert_eq!(validate_intent(&json!("set_notifications"), &fields).map(Value::Object), Ok(fields.clone()));
    }
    rejects("set_notifications", json!({}), "fields");
    rejects("set_notifications", json!({"enabled": "yes"}), "enabled");
    rejects("set_notifications", json!({"preview": null}), "preview");
    rejects("set_notifications", json!({"sound": true}), "sound");
    assert!(validate_intent(&json!("allow_notifications"), &json!({})).is_ok());
    rejects("allow_notifications", json!({"now": true}), "now");
    assert!(validate_intent(&json!("dismiss_banner"), &json!({"kind": "notifications"})).is_ok());
    rejects("dismiss_banner", json!({"kind": "update_required"}), "kind");
    rejects("test_notification_response", json!({"key": "message:i_1", "action": "open"}), "type");
    assert!(!INTENT_TYPES.contains(&"test_notification_response"));
}
