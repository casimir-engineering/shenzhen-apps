//! The Bluetooth presence characteristic against the Objective-C helper's own (fixtures/vectors/objc-bluetooth.json):
//! the same fixed UUIDs, the same bytes out, the same values accepted and refused.

use serde_json::Value;
use szfriends_core::nearby::bluetooth::{self, Presence};
use szfriends_core::nearby::Tag;
use szfriends_vectors::{bytes, cases, field, flag, load, number, text};

fn tag(value: &Value) -> Tag {
    bytes(value).try_into().expect("8 bytes")
}

fn presence(case: &Value) -> Presence {
    let tags: Vec<Tag> = case["callback_tags"].as_array().expect("tags").iter().map(tag).collect();
    let presence_tag = (!case["tag"].is_null()).then(|| tag(&case["tag"]));
    Presence::new(presence_tag, &tags, number(case, "hidden_psm") as u16, number(case, "public_psm") as u16)
}

#[test]
fn uses_the_helpers_uuids() {
    let uuids = &load("objc-bluetooth.json")["uuids"];
    assert_eq!(text(uuids, "service"), bluetooth::SERVICE_UUID);
    assert_eq!(text(uuids, "public"), bluetooth::PUBLIC_UUID);
    assert_eq!(text(uuids, "presence_characteristic"), bluetooth::PRESENCE_CHARACTERISTIC_UUID);
    assert_eq!(text(uuids, "public_characteristic"), bluetooth::PUBLIC_CHARACTERISTIC_UUID);
}

#[test]
fn encodes_as_the_helper_does() {
    for case in cases(&load("objc-bluetooth.json"), "encode") {
        assert_eq!(presence(case).value(), field(case, "value"), "{}", text(case, "name"));
    }
}

#[test]
fn accepts_and_refuses_what_the_helper_does() {
    for case in cases(&load("objc-bluetooth.json"), "decode") {
        let decoded = Presence::from_value(&field(case, "value"));
        assert_eq!(decoded.is_some(), flag(case, "accepted"), "{}", text(case, "name"));
        if let Some(decoded) = decoded {
            assert_eq!(decoded, presence(&case["decoded"]), "{}", text(case, "name"));
        }
    }
}
