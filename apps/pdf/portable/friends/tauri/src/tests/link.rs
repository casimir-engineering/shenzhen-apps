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

/// The first event that matches within 10 s, however many others come meanwhile (a link that cycles).
fn wait_for(events: &Receiver<LinkEvent>, what: &str, matches: impl Fn(&LinkEvent) -> bool) -> LinkEvent {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        match events.recv_timeout(left) {
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
    assert_eq!(state_text(LinkState::Waiting, "Test", Trouble::Other), "Reconnecting to Friends…");
    assert!(state_text(LinkState::Incompatible, "Test", Trouble::Other).ends_with("Update Test to use Friends."));
}

/// A connector that never connects, for the reason given.
struct Failing(Trouble);

impl Connector for Failing {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        Err(NotConnected("the helper was not reached".into(), self.0))
    }
}

fn start_failing(trouble: Trouble, stuck_after: Duration) -> (Link, Receiver<LinkEvent>) {
    let (sender, events) = channel();
    let sender = Mutex::new(sender);
    let sink: Sink = Arc::new(move |event| {
        let _ = sender.lock().unwrap().send(event);
    });
    let link = Link(Arc::new(Inner {
        connector: Arc::new(Failing(trouble)),
        app: app(),
        sink,
        shared: Mutex::new(Shared::default()),
        write: Mutex::new(()),
        wake: Condvar::new(),
        stopped: AtomicBool::new(false),
        next_id: AtomicU64::new(1),
    }));
    let running = link.clone();
    std::thread::spawn(move || running.run_with(Patience { stuck_after, ..Patience::DEFAULT }));
    (link, events)
}

#[test]
fn a_helper_that_never_answers_ends_in_unavailable_not_endless_starting() {
    let (link, events) = start_failing(Trouble::Other, Duration::from_millis(300));
    wait_for(&events, "connecting", |e| *e == LinkEvent::State(LinkState::Connecting));
    wait_for(&events, "unavailable", |e| *e == LinkEvent::State(LinkState::Unavailable));
    assert_eq!(link.state(), LinkState::Unavailable);
    // It keeps trying, but the panel's line no longer flips back to "Starting Friends…".
    let flips = (0..20).filter_map(|_| events.recv_timeout(Duration::from_millis(100)).ok()).count();
    assert_eq!(flips, 0, "no state changes while it retries");
    assert_eq!(link.state(), LinkState::Unavailable);
    let text = state_text(link.state(), "Shenzhen 3D", link.trouble());
    assert_eq!(text, "Friends didn't start. Quit Shenzhen 3D and open it again.");
    link.stop(false);
}

#[test]
fn security_software_and_administrator_runs_say_so_at_once() {
    for (trouble, words) in [(Trouble::Blocked, "Security software"), (Trouble::Elevated, "runs as administrator")] {
        let (link, events) = start_failing(trouble, Duration::from_secs(3600));
        wait_for(&events, "unavailable", |e| *e == LinkEvent::State(LinkState::Unavailable));
        assert_eq!(link.trouble(), trouble);
        let text = state_text(LinkState::Unavailable, "Shenzhen 3D", trouble);
        assert!(text.contains(words), "{text}");
        assert!(!text.contains("Starting"), "{text}");
        link.stop(false);
    }
}

/// Fails its first `failures` attempts, then connects to the in-memory helper.
struct Late(std::sync::atomic::AtomicUsize, Arc<Memory>);

impl Connector for Late {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        if self.0.fetch_sub(1, Ordering::SeqCst) > 0 {
            return Err(NotConnected::because("not yet"));
        }
        MemoryConnector(self.1.clone()).connect()
    }
}

#[test]
fn a_link_that_becomes_ready_leaves_unavailable() {
    let memory = memory();
    let (sender, events) = channel();
    let sender = Mutex::new(sender);
    let sink: Sink = Arc::new(move |event| {
        let _ = sender.lock().unwrap().send(event);
    });
    // Fails for about a second (the backoff doubles from 50 ms), past a 200 ms patience.
    let connector = Late(std::sync::atomic::AtomicUsize::new(6), memory.clone());
    let link = Link(Arc::new(Inner {
        connector: Arc::new(connector),
        app: app(),
        sink,
        shared: Mutex::new(Shared::default()),
        write: Mutex::new(()),
        wake: Condvar::new(),
        stopped: AtomicBool::new(false),
        next_id: AtomicU64::new(1),
    }));
    let running = link.clone();
    std::thread::spawn(move || {
        running.run_with(Patience { stuck_after: Duration::from_millis(200), ..Patience::DEFAULT })
    });
    wait_for(&events, "unavailable", |e| *e == LinkEvent::State(LinkState::Unavailable));
    wait_for(&events, "ready", |e| *e == LinkEvent::State(LinkState::Ready));
    assert_eq!(state_text(link.state(), "Test", link.trouble()), "");
    link.stop(false);
}

fn link_with(connector: Arc<dyn Connector>, patience: Patience) -> (Link, Receiver<LinkEvent>) {
    let (sender, events) = channel();
    let sender = Mutex::new(sender);
    let sink: Sink = Arc::new(move |event| {
        let _ = sender.lock().unwrap().send(event);
    });
    let link = Link(Arc::new(Inner {
        connector,
        app: app(),
        sink,
        shared: Mutex::new(Shared::default()),
        write: Mutex::new(()),
        wake: Condvar::new(),
        stopped: AtomicBool::new(false),
        next_id: AtomicU64::new(1),
    }));
    let running = link.clone();
    std::thread::spawn(move || running.run_with(patience));
    (link, events)
}

const QUICK: Patience = Patience {
    stuck_after: Duration::from_millis(600),
    hello: Duration::from_millis(300),
    intent: Duration::from_millis(300),
    heartbeat: Duration::from_millis(100),
};

/// A helper that takes every connection and never says a word (a wedged one, left from an earlier launch): it is
/// ended once, then a working one answers.
struct Silent {
    connections: Mutex<Vec<Arc<MemoryEnd>>>,
    ended: std::sync::atomic::AtomicUsize,
    then: Arc<Memory>,
}

impl Connector for Silent {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        if self.ended.load(Ordering::SeqCst) > 0 {
            return MemoryConnector(self.then.clone()).connect();
        }
        let (ours, theirs) = memory_pair();
        self.connections.lock().unwrap().push(theirs);
        Ok(ClientConnection::new(ours))
    }

    fn end_unresponsive(&self) -> bool {
        self.ended.fetch_add(1, Ordering::SeqCst);
        true
    }
}

#[test]
fn a_helper_that_never_answers_its_hello_is_ended_and_replaced() {
    let silent = Arc::new(Silent { connections: Mutex::default(), ended: Default::default(), then: memory() });
    let (link, events) = link_with(silent.clone(), QUICK);
    wait_for(&events, "handshaking", |e| *e == LinkEvent::State(LinkState::Handshaking));
    wait_for(&events, "ready with a new helper", |e| *e == LinkEvent::State(LinkState::Ready));
    assert_eq!(silent.ended.load(Ordering::SeqCst), 1, "the silent helper was ended once");
    link.stop(false);
}

/// Always silent, and nothing to end: the panel must still stop saying "Starting Friends…".
struct AlwaysSilent(Mutex<Vec<Arc<MemoryEnd>>>);

impl Connector for AlwaysSilent {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        let (ours, theirs) = memory_pair();
        self.0.lock().unwrap().push(theirs);
        Ok(ClientConnection::new(ours))
    }
}

#[test]
fn a_hello_that_is_never_answered_ends_in_unavailable() {
    let (link, events) = link_with(Arc::new(AlwaysSilent(Mutex::default())), QUICK);
    wait_for(&events, "unavailable", |e| *e == LinkEvent::State(LinkState::Unavailable));
    assert_eq!(
        state_text(link.state(), "Shenzhen 3D", link.trouble()),
        "Friends didn't start. Quit Shenzhen 3D and open it again."
    );
    link.stop(false);
}

/// Welcomes, then closes at once, every time (a helper that crashes right after its hello).
struct Crashing(Arc<Memory>);

impl Connector for Crashing {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        let connection = MemoryConnector(self.0.clone()).connect()?;
        let end = self.0.ends.lock().unwrap().last().unwrap().clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            end.close();
        });
        Ok(connection)
    }
}

#[test]
fn a_helper_that_leaves_after_every_welcome_ends_in_unavailable() {
    // Each connection is ready for a moment; the old timer started again at every ready and never fired.
    let (link, events) =
        link_with(Arc::new(Crashing(memory())), Patience { heartbeat: Duration::from_secs(60), ..QUICK });
    wait_for(&events, "ready once", |e| *e == LinkEvent::State(LinkState::Ready));
    wait_for(&events, "unavailable", |e| *e == LinkEvent::State(LinkState::Unavailable));
    link.stop(false);
}

/// Welcomes, then never answers an intent (its service stopped): what showed "Loading…" without end.
struct Deaf(Mutex<Vec<Arc<MemoryEnd>>>, std::sync::atomic::AtomicUsize);

impl Connector for Deaf {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        let (ours, theirs) = memory_pair();
        self.0.lock().unwrap().push(theirs.clone());
        // Answers the hello only.
        std::thread::spawn(move || {
            let mut buffer = [0u8; 4096];
            if theirs.read(&mut buffer).unwrap_or(0) > 0 {
                let welcome = json!({"type": "welcome", "re": "1", "protocol": {"major": 1, "minor": 0},
                    "helper": {"version": "1", "build_number": 1}, "capabilities": [], "strings": {}});
                let mut line = serde_json::to_vec(&welcome).unwrap();
                line.push(b'\n');
                let _ = theirs.write_all(&line);
            }
            while theirs.read(&mut buffer).unwrap_or(0) > 0 {}
        });
        Ok(ClientConnection::new(ours))
    }

    fn end_unresponsive(&self) -> bool {
        self.1.fetch_add(1, Ordering::SeqCst);
        false
    }
}

#[test]
fn a_ready_helper_that_stops_answering_is_dropped_and_ends_in_unavailable() {
    let deaf = Arc::new(Deaf(Mutex::default(), Default::default()));
    let (link, events) = link_with(deaf.clone(), QUICK);
    wait_for(&events, "ready", |e| *e == LinkEvent::State(LinkState::Ready));
    let mut fields = Map::new();
    fields.insert("view".into(), json!("list"));
    assert!(link.send("subscribe", &fields).is_some());
    wait_for(&events, "unavailable", |e| *e == LinkEvent::State(LinkState::Unavailable));
    assert!(deaf.1.load(Ordering::SeqCst) >= 1, "the link asked to end the silent helper");
    link.stop(false);
}

#[test]
fn a_working_link_sends_its_heartbeat_and_stays_ready() {
    let memory = memory();
    let (link, events) = link_with(Arc::new(MemoryConnector(memory.clone())), QUICK);
    wait_for(&events, "ready", |e| *e == LinkEvent::State(LinkState::Ready));
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(link.state(), LinkState::Ready, "answered heartbeats keep it ready past every patience");
    link.stop(false);
}
