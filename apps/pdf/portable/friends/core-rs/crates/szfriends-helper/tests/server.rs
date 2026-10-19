//! The protocol server over in-memory connections: the handshake, protocol errors, intents through the presentation,
//! handover requests and `disable`, as PROTOCOL.md and the Mac helper's IPC tests say.

mod support;

use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;

use serde_json::{json, Value};
use support::{pair, Peer};
use szfriends_contract::handshake::HelperFacts;
use szfriends_contract::lifecycle::PROTOCOL;
use szfriends_helper::lifecycle::Event;
use szfriends_helper::presentation::StubPresentation;
use szfriends_helper::server::{Server, MAX_CONNECTIONS};
use szfriends_helper::transport::PeerInfo;

const BUILD: u64 = 26101701;

fn new_server(backs: bool) -> (Server, Receiver<Event>) {
    let (sender, receiver) = channel();
    let helper = HelperFacts { version: "1.0.0".into(), build_number: BUILD, protocol: PROTOCOL, pid: 77 };
    let check = Box::new(move |_: &PeerInfo, _: u64| backs);
    (Server::new(Arc::new(StubPresentation::default()), helper, sender, check), receiver)
}

fn connect(server: &Server) -> Peer {
    let (ours, theirs) = pair();
    server.add(theirs, PeerInfo::default());
    Peer::new(ours)
}

fn hello(embedded_build: Option<u64>) -> Value {
    let embedded =
        embedded_build.map(|b| json!({"version": "1.0.1", "build_number": b, "protocol": {"major": 1, "minor": 0}}));
    json!({"type": "hello", "id": "1", "protocol": {"major": 1, "minor": 0, "min_major": 1},
           "client": {"app_id": "com.example.app", "app_name": "Shenzhen 3D", "app_version": "1",
                      "toolkit": "webview2", "reveal_in": "File Explorer"},
           "embedded_helper": embedded, "capabilities": [], "open_formats": ["stl"], "locale": "en-GB"})
}

fn drain(receiver: &Receiver<Event>) -> Vec<Event> {
    std::thread::sleep(std::time::Duration::from_millis(50));
    receiver.try_iter().collect()
}

#[test]
fn hello_then_intents_through_the_presentation() {
    let (server, _events) = new_server(true);
    let mut client = connect(&server);
    client.send(&hello(None));
    let welcome = client.next().unwrap();
    assert_eq!((welcome["type"].as_str(), welcome["re"].as_str()), (Some("welcome"), Some("1")));
    assert_eq!(
        welcome["helper"],
        json!({"version": "1.0.0", "build_number": BUILD,
                                         "protocol": {"major": 1, "minor": 0}, "pid": 77})
    );
    assert_eq!(welcome["handover"], "none");
    assert_eq!(welcome["limits"]["max_frame_bytes"], 8388608);

    client.send(&json!({"type": "subscribe", "id": "2", "view": "badge"}));
    let snapshot = client.next().unwrap();
    assert_eq!(snapshot["type"], "snapshot", "the first snapshot comes before the reply");
    assert_eq!(snapshot["data"], json!({"count": 0, "label": "", "accessibility_label": "Friends"}));
    let reply = client.next().unwrap();
    assert_eq!((reply["re"].as_str(), reply["ok"].as_bool()), (Some("2"), Some(true)));
    assert_eq!(reply["result"]["subscription"], snapshot["subscription"]);

    client.send(&json!({"type": "ping", "id": "3"}));
    assert_eq!(client.next().unwrap(), json!({"type": "reply", "re": "3", "ok": true, "result": {}}));
    client.send(&json!({"type": "fly", "id": "4"}));
    assert_eq!(client.next().unwrap()["error"]["code"], "unknown_intent");
    client.send(&json!({"type": "hello", "id": "5"}));
    assert_eq!(client.next().unwrap()["error"]["code"], "not_allowed", "a second hello");
    assert_eq!(server.active_clients(), 1);
}

#[test]
fn protocol_errors_end_the_connection_with_a_goodbye() {
    let (server, _events) = new_server(true);
    let mut early = connect(&server);
    early.send(&json!({"type": "ping", "id": "1"}));
    assert_eq!(early.next().unwrap()["error"]["code"], "hello_required");
    let bye = early.next().unwrap();
    assert_eq!(
        (bye["reason"].as_str(), bye["error"]["code"].as_str()),
        (Some("protocol_error"), Some("hello_required"))
    );
    assert_eq!(early.next(), None, "closed");

    for (bytes, code) in [(&b"[1,2]\n"[..], "bad_frame"), (b"{\"type\":\"hello\"}\n", "bad_frame")] {
        let mut client = connect(&server);
        client.send_raw(bytes);
        assert_eq!(client.next().unwrap()["error"]["code"], code);
        assert_eq!(client.next(), None);
    }
    let mut huge = connect(&server);
    huge.send_raw(&vec![b' '; 8 * 1024 * 1024 + 1]);
    let bye = huge.next().unwrap();
    assert_eq!(bye["error"]["code"], "frame_too_large");
    assert_eq!(bye["error"]["details"]["max_frame_bytes"], 8388608);

    let mut duplicate = connect(&server);
    duplicate.send(&json!({"type": "hello", "id": "1", "protocol": {"major": 1, "minor": 0}}));
    assert_eq!(duplicate.next().unwrap()["error"]["details"]["field"], "protocol", "a bad field keeps it open");
    duplicate.send(&hello(None));
    assert_eq!(duplicate.next().unwrap()["type"], "welcome");
    assert!(support::eventually(|| server.connection_count() == 1), "only the good one is left");
}

#[test]
fn a_newer_build_that_the_client_carries_schedules_a_handover() {
    let (server, events) = new_server(true);
    let mut client = connect(&server);
    client.send(&hello(Some(BUILD + 1)));
    assert_eq!(client.next().unwrap()["handover"], "scheduled");
    assert!(drain(&events).contains(&Event::Handover));
    assert_eq!(server.successor().unwrap().build_number, BUILD + 1);
    let mut later = connect(&server);
    later.send(&hello(None));
    assert_eq!(later.next().unwrap()["handover"], "scheduled", "every later welcome says so");

    for (backs, build) in [(false, BUILD + 1), (true, BUILD), (true, BUILD - 1), (true, BUILD + 10_000 * 100 + 100)] {
        let (server, events) = new_server(backs);
        let mut client = connect(&server);
        client.send(&hello(Some(build)));
        assert_eq!(client.next().unwrap()["handover"], "none", "backed {backs}, build {build}");
        assert!(!drain(&events).contains(&Event::Handover));
    }
}

#[test]
fn no_common_major_still_carries_the_handover() {
    let (server, events) = new_server(true);
    let mut client = connect(&server);
    let mut frame = hello(Some(BUILD + 1));
    frame["protocol"] = json!({"major": 3, "minor": 0, "min_major": 2});
    frame["embedded_helper"]["protocol"] = json!({"major": 3, "minor": 0});
    client.send(&frame);
    let reply = client.next().unwrap();
    assert_eq!(reply["error"]["code"], "protocol_unsupported");
    assert_eq!(reply["error"]["details"], json!({"helper_major": 1, "helper_min_major": 1, "handover": "scheduled"}));
    assert_eq!(client.next().unwrap()["reason"], "protocol_error");
    assert!(drain(&events).contains(&Event::Handover));
}

#[test]
fn disable_releases_the_helper_and_too_many_clients_are_turned_away() {
    let (server, events) = new_server(true);
    let mut client = connect(&server);
    client.send(&hello(None));
    client.next().unwrap();
    client.send(&json!({"type": "disable", "id": "9"}));
    assert_eq!(client.next().unwrap()["ok"], true);
    assert!(drain(&events).contains(&Event::Disable));
    assert_eq!((server.active_clients(), server.connection_count()), (0, 1));

    let (server, _events) = new_server(true);
    let crowd: Vec<Peer> = (0..MAX_CONNECTIONS).map(|_| connect(&server)).collect();
    let mut one_more = connect(&server);
    assert_eq!(one_more.next().unwrap()["reason"], "too_many_clients");
    assert_eq!(server.connection_count(), MAX_CONNECTIONS);
    drop(crowd);
}
