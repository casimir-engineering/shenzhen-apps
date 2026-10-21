//! The link against the helper's own protocol server, in memory: hello and welcome, intents and replies,
//! reconnection after the server goes, and `disable` when Friends is turned off.

use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Map, Value};
use szfriends_contract::handshake::HelperFacts;
use szfriends_contract::lifecycle::PROTOCOL;
use szfriends_helper::client::{AppInfo, ClientConnection};
use szfriends_helper::presentation::StubPresentation;
use szfriends_helper::server::Server;
use szfriends_helper::transport::{memory_pair, Duplex, MemoryEnd, PeerInfo};

use super::*;

struct Memory {
    server: Server,
    lifecycle: Mutex<Receiver<szfriends_helper::lifecycle::Event>>,
    /// The helper's side of each connection made, so a test can cut one.
    ends: Mutex<Vec<Arc<MemoryEnd>>>,
}

struct MemoryConnector(Arc<Memory>);

impl Connector for MemoryConnector {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        let (ours, theirs) = memory_pair();
        self.0.ends.lock().unwrap().push(theirs.clone());
        self.0.server.add(theirs, PeerInfo::default());
        Ok(ClientConnection::new(ours))
    }
}

fn memory() -> Arc<Memory> {
    let (sender, receiver) = channel();
    let helper = HelperFacts { version: "1.0".into(), build_number: 1, protocol: PROTOCOL, pid: 1 };
    let server = Server::new(Arc::new(StubPresentation::default()), helper, sender, Box::new(|_, _| false));
    Arc::new(Memory { server, lifecycle: Mutex::new(receiver), ends: Mutex::default() })
}

fn app() -> AppInfo {
    AppInfo {
        app_id: "com.example.test".into(),
        app_name: "Test".into(),
        app_version: "1.0".into(),
        toolkit: "tauri".into(),
        reveal_in: "Files".into(),
        capabilities: vec!["drop.files".into()],
        open_formats: vec!["stl".into()],
        locale: "en".into(),
        url_scheme: None,
    }
}

fn start(memory: &Arc<Memory>) -> (Link, Receiver<LinkEvent>) {
    let (sender, events) = channel();
    let sender = Mutex::new(sender);
    let sink: Sink = Arc::new(move |event| {
        let _ = sender.lock().unwrap().send(event);
    });
    (Link::start(Arc::new(MemoryConnector(memory.clone())), app(), sink), events)
}

fn wait_for(events: &Receiver<LinkEvent>, what: &str, matches: impl Fn(&LinkEvent) -> bool) -> LinkEvent {
    loop {
        match events.recv_timeout(Duration::from_secs(5)) {
            Ok(event) if matches(&event) => return event,
            Ok(_) => continue,
            Err(_) => panic!("no {what}"),
        }
    }
}

fn frame_of(event: LinkEvent) -> Value {
    match event {
        LinkEvent::Frame(frame) => frame,
        LinkEvent::State(state) => panic!("a state, {state:?}"),
    }
}

#[test]
fn the_link_says_hello_sends_intents_and_routes_their_replies() {
    let memory = memory();
    let (link, events) = start(&memory);
    let welcome =
        frame_of(wait_for(&events, "welcome", |e| matches!(e, LinkEvent::Frame(f) if f["type"] == "welcome")));
    assert_eq!(welcome["protocol"]["major"], 1);
    wait_for(&events, "ready", |e| *e == LinkEvent::State(LinkState::Ready));
    let mut fields = Map::new();
    fields.insert("view".into(), json!("badge"));
    let id = link.send("subscribe", &fields).expect("sent");
    let reply =
        frame_of(wait_for(&events, "the reply", |e| matches!(e, LinkEvent::Frame(f) if f["re"] == id.as_str())));
    assert_eq!(reply["ok"], true);
    link.stop(false);
}

#[test]
fn a_dropped_connection_is_reported_and_made_again() {
    let memory = memory();
    let (link, events) = start(&memory);
    wait_for(&events, "ready", |e| *e == LinkEvent::State(LinkState::Ready));
    memory.ends.lock().unwrap()[0].close();
    wait_for(&events, "waiting", |e| *e == LinkEvent::State(LinkState::Waiting));
    assert_eq!(link.send("ping", &Map::new()), None, "nothing waits while not ready");
    wait_for(&events, "ready again", |e| *e == LinkEvent::State(LinkState::Ready));
    assert_eq!(memory.ends.lock().unwrap().len(), 2);
    link.stop(false);
}

#[test]
fn turning_friends_off_tells_the_service() {
    let memory = memory();
    let (link, events) = start(&memory);
    wait_for(&events, "ready", |e| *e == LinkEvent::State(LinkState::Ready));
    link.stop(true);
    let lifecycle = memory.lifecycle.lock().unwrap();
    let disabled = (0..50).any(|_| {
        matches!(lifecycle.recv_timeout(Duration::from_millis(100)), Ok(szfriends_helper::lifecycle::Event::Disable))
    });
    assert!(disabled, "the helper heard disable");
    assert_eq!(state_text(LinkState::Waiting, "Test"), "Reconnecting to Friends…");
    assert!(state_text(LinkState::Incompatible, "Test").ends_with("Update Test to use Friends."));
}
