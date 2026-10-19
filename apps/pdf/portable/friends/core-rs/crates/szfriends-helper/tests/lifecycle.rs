//! The lifecycle on a live server with in-memory clients and shortened timings: exit with no client, after the last
//! client, at once after `disable`, and for a handover (waiting for work in flight, at most the deadline), with the
//! goodbyes PROTOCOL.md § Lifecycle names.

mod support;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use support::{pair, Peer};
use szfriends_contract::handshake::{ClientInfo, HelperFacts};
use szfriends_contract::lifecycle::{ExitReason, LifecyclePolicy, PROTOCOL};
use szfriends_helper::events::SystemEvent;
use szfriends_helper::lifecycle::{run, Event, Exit};
use szfriends_helper::presentation::{Presentation, StubPresentation};
use szfriends_helper::server::{Connection, Reply, Server};
use szfriends_helper::transport::{Duplex, Listener, PeerInfo};

#[derive(Default)]
struct FakeListener {
    stopped: Mutex<bool>,
    woken: Condvar,
    stops: AtomicBool,
}

impl Listener for FakeListener {
    fn accept(&self) -> std::io::Result<Option<(Arc<dyn Duplex>, PeerInfo)>> {
        let mut stopped = self.stopped.lock().unwrap();
        while !*stopped {
            stopped = self.woken.wait(stopped).unwrap();
        }
        Ok(None)
    }

    fn stop(&self) {
        *self.stopped.lock().unwrap() = true;
        self.stops.store(true, Ordering::SeqCst);
        self.woken.notify_all();
    }
}

/// The stub, with work in flight while `busy` is set.
#[derive(Default)]
struct Busy {
    stub: StubPresentation,
    busy: AtomicBool,
    shut_down: AtomicBool,
}

impl Presentation for Busy {
    fn welcome(&self, client: &ClientInfo) -> Value {
        self.stub.welcome(client)
    }
    fn intent(&self, connection: &Connection, intent: &Value, reply: Reply) {
        self.stub.intent(connection, intent, reply)
    }
    fn system_event(&self, event: SystemEvent) {
        self.stub.system_event(event)
    }
    fn work_in_flight(&self) -> bool {
        self.busy.load(Ordering::SeqCst)
    }
    fn shutdown(&self) {
        self.shut_down.store(true, Ordering::SeqCst);
    }
}

const BUILD: u64 = 26101701;

fn policy() -> LifecyclePolicy {
    LifecyclePolicy {
        grace: Duration::from_millis(300),
        first_client: Duration::from_millis(600),
        handover_deadline: Duration::from_millis(800),
    }
}

struct Running {
    server: Server,
    presentation: Arc<Busy>,
    events: Sender<Event>,
    listener: Arc<FakeListener>,
    exit: thread::JoinHandle<(Exit, Duration)>,
}

fn start() -> Running {
    let (events, receiver) = channel();
    let presentation = Arc::new(Busy::default());
    let helper = HelperFacts { version: "1.0.0".into(), build_number: BUILD, protocol: PROTOCOL, pid: 1 };
    let server = Server::new(presentation.clone(), helper, events.clone(), Box::new(|_: &PeerInfo, _: u64| true));
    let listener = Arc::new(FakeListener::default());
    let (lifecycle_server, lifecycle_listener) = (server.clone(), listener.clone() as Arc<dyn Listener>);
    let exit = thread::spawn(move || {
        let started = Instant::now();
        let exit = run(&lifecycle_server, &lifecycle_listener, &receiver, policy());
        (exit, started.elapsed())
    });
    Running { server, presentation, events, listener, exit }
}

fn client(running: &Running, embedded_build: Option<u64>) -> Peer {
    let (ours, theirs) = pair();
    running.server.add(theirs, PeerInfo::default());
    let mut peer = Peer::new(ours);
    let embedded =
        embedded_build.map(|b| json!({"version": "1.0.1", "build_number": b, "protocol": {"major": 1, "minor": 0}}));
    peer.send(&json!({"type": "hello", "id": "1", "protocol": {"major": 1, "minor": 0, "min_major": 1},
        "client": {"app_id": "a", "app_name": "A", "app_version": "1", "toolkit": "t", "reveal_in": "r"},
        "embedded_helper": embedded, "capabilities": [], "open_formats": [], "locale": "en"}));
    assert_eq!(peer.next().unwrap()["type"], "welcome");
    peer
}

#[test]
fn nobody_comes() {
    let running = start();
    let (exit, after) = running.exit.join().unwrap();
    assert_eq!(exit, Exit::Policy(ExitReason::NoClient));
    assert!(after >= Duration::from_millis(600), "{after:?}");
    assert!(running.listener.stops.load(Ordering::SeqCst) && running.presentation.shut_down.load(Ordering::SeqCst));
}

#[test]
fn the_last_client_leaves_then_the_grace_period() {
    let running = start();
    let first = client(&running, None);
    thread::sleep(Duration::from_millis(700));
    assert!(!running.exit.is_finished(), "a client keeps it past the first-client deadline");
    let second = client(&running, None);
    first.end.close();
    thread::sleep(Duration::from_millis(400));
    assert!(!running.exit.is_finished(), "one client is still there");
    let left = Instant::now();
    second.end.close();
    let (exit, _) = running.exit.join().unwrap();
    assert_eq!(exit, Exit::Policy(ExitReason::Idle));
    assert!(left.elapsed() >= Duration::from_millis(300));
}

#[test]
fn the_last_app_turning_friends_off_ends_it_at_once() {
    let running = start();
    let mut client = client(&running, None);
    client.send(&json!({"type": "disable", "id": "2"}));
    assert_eq!(client.next().unwrap()["ok"], true, "the reply comes before the goodbye");
    assert_eq!(client.next().unwrap()["reason"], "shutdown");
    let (exit, _) = running.exit.join().unwrap();
    assert_eq!(exit, Exit::Policy(ExitReason::Disabled));
}

#[test]
fn a_handover_waits_for_work_in_flight_then_says_goodbye_to_everyone() {
    let running = start();
    running.presentation.busy.store(true, Ordering::SeqCst);
    let mut bystander = client(&running, None);
    let asked = Instant::now();
    let mut successor = client(&running, Some(BUILD + 1));
    assert!(support::eventually(|| running.listener.stops.load(Ordering::SeqCst)), "no new clients");
    for peer in [&mut bystander, &mut successor] {
        let bye = peer.next().unwrap();
        assert_eq!(
            bye,
            json!({"type": "goodbye", "reason": "handover", "message": null,
                               "successor": {"version": "1.0.1", "build_number": BUILD + 1}, "error": null})
        );
    }
    assert!(asked.elapsed() >= Duration::from_millis(800), "waited the deadline for the busy transfer");
    assert_eq!(running.exit.join().unwrap().0, Exit::Policy(ExitReason::Handover));

    let running = start();
    let mut asking = client(&running, Some(BUILD + 2));
    assert_eq!(asking.next().unwrap()["reason"], "handover", "nothing in flight: at once");
    assert_eq!(running.exit.join().unwrap().0, Exit::Policy(ExitReason::Handover));
}

#[test]
fn shutdown_and_system_events() {
    let running = start();
    let mut client = client(&running, None);
    running.events.send(Event::System(SystemEvent::Sleep)).unwrap();
    running.events.send(Event::System(SystemEvent::Wake)).unwrap();
    assert!(support::eventually(|| running.presentation.stub.system_events().len() == 2));
    running.events.send(Event::Shutdown).unwrap();
    assert_eq!(client.next().unwrap()["reason"], "shutdown");
    assert_eq!(running.exit.join().unwrap().0, Exit::Shutdown);
}
