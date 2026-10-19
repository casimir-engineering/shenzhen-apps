//! The handshake frames against PROTOCOL.md's fixtures: what the Rust helper says at hello and goodbye must be the
//! frames the Objective-C helper and the views are tested with.

use serde_json::{json, Value};
use szfriends_contract::handshake::{
    client_info, error_reply, goodbye, hello_versions, protocol_error_goodbye, protocol_unsupported, welcome,
    EmbeddedHelper, GoodbyeReason, HelperFacts, Successor,
};
use szfriends_contract::lifecycle::{ProtocolVersion, PROTOCOL};
use szfriends_vectors::fixtures_dir;

fn frame(name: &str) -> Value {
    let path = fixtures_dir().join("frames").join(format!("{name}.json"));
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("json")
}

#[test]
fn the_fixture_hello_reads_as_the_mac_helper_reads_it() {
    let hello = frame("hello");
    let versions = hello_versions(&hello).expect("versions");
    assert_eq!(versions.protocol, PROTOCOL);
    assert_eq!(versions.min_major, 1);
    let embedded = EmbeddedHelper { version: "26.10.12-1".into(), build_number: 26101201, protocol: PROTOCOL };
    assert_eq!(versions.embedded_helper, Some(embedded));
    let client = client_info(&hello, PROTOCOL).expect("client");
    assert_eq!((client.app_name.as_str(), client.toolkit.as_str()), ("ShenzhenPDF", "appkit"));
    assert!(client.capabilities.contains("drop.files") && client.open_formats.contains("markdown"));
    assert_eq!(client.locale, "en-GB");
}

#[test]
fn a_bad_hello_names_its_field() {
    let hello = frame("hello");
    let with = |pointer: &str, value: Value| {
        let mut copy = hello.clone();
        *copy.pointer_mut(pointer).expect("field") = value;
        copy
    };
    assert_eq!(hello_versions(&with("/protocol/minor", json!(1.5))), Err("protocol"));
    assert_eq!(hello_versions(&with("/protocol/min_major", json!(true))), Err("protocol"));
    assert_eq!(hello_versions(&with("/embedded_helper/build_number", json!(-1))), Err("embedded_helper"));
    assert_eq!(hello_versions(&with("/embedded_helper", json!("26"))), Err("embedded_helper"));
    assert_eq!(hello_versions(&with("/embedded_helper", Value::Null)).unwrap().embedded_helper, None);
    let field = |hello: Value| client_info(&hello, PROTOCOL).unwrap_err();
    assert_eq!(field(with("/client/app_name", json!(""))), "client.app_name");
    assert_eq!(field(with("/client/reveal_in", json!("x".repeat(129)))), "client.reveal_in");
    assert_eq!(field(with("/client", json!([]))), "client");
    assert_eq!(field(with("/capabilities", json!(["a", 1]))), "capabilities");
    assert_eq!(field(with("/open_formats", json!(vec!["pdf"; 513]))), "open_formats");
    assert_eq!(field(with("/locale", json!(7))), "locale");
    let any_toolkit = client_info(&with("/client/toolkit", json!("webview2")), PROTOCOL).unwrap();
    assert_eq!(any_toolkit.toolkit, "webview2");
    let no_locale = client_info(&with("/locale", Value::Null), PROTOCOL).unwrap();
    assert_eq!(no_locale.locale, "en");
    let upper = client_info(&with("/open_formats", json!(["PDF"])), PROTOCOL).unwrap();
    assert!(upper.open_formats.contains("pdf"));
}

#[test]
fn welcome_reply_and_goodbye_are_the_fixtures() {
    let fixture = frame("welcome");
    let helper = HelperFacts { version: "26.10.12-1".into(), build_number: 26101201, protocol: PROTOCOL, pid: 5150 };
    let extras = json!({"capabilities": fixture["capabilities"], "limits": fixture["limits"],
                        "strings": fixture["strings"], "type": "forged", "handover": "forged"});
    assert_eq!(welcome("1", PROTOCOL, &helper, false, extras), fixture);
    let defaults = welcome("1", PROTOCOL, &helper, true, Value::Null);
    assert_eq!(defaults["limits"], fixture["limits"], "PROTOCOL.md's limits by default");
    assert_eq!((defaults["handover"].as_str(), defaults["capabilities"].clone()), (Some("scheduled"), json!([])));

    let successor = Successor { version: "26.10.20-1".into(), build_number: 26102001 };
    assert_eq!(goodbye(GoodbyeReason::Handover, Some(&successor), None), frame("goodbye-handover"));
    let too_large = protocol_error_goodbye("frame_too_large", json!({"max_frame_bytes": 8388608}));
    assert_eq!(too_large, frame("goodbye-protocol-error"));
    let [reply, bye] = protocol_unsupported("1", 1, 1, true);
    assert_eq!(reply, frame("reply-protocol-unsupported"));
    assert_eq!(bye, frame("goodbye-protocol-unsupported"));
    assert_eq!(error_reply("23", "connection_lost", None, Value::Null), frame("reply-connection-lost"));
    let disk = frame("reply-error");
    let message = disk["error"]["message"].as_str();
    assert_eq!(error_reply("16", "disk_full", message, disk["error"]["details"].clone()), disk);
    let older = ProtocolVersion { major: 1, minor: 0 };
    assert_eq!(welcome("9", older, &helper, false, json!({}))["re"], "9");
}
