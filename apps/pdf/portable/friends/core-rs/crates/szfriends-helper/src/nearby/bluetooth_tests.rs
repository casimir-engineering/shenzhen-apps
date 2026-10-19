//! The Bluetooth adapter against a scripted radio (`SZFriendsBluetoothAdapterTests.m`'s cases): states, a channel per
//! window served whole, the public entry's own channel closed by the deadline, cached reads, two reads at a time,
//! endpoints and dials.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use szfriends_core::nearby::bluetooth::Presence;
use szfriends_core::nearby::{AdapterState, Permission};

use super::*;
use crate::nearby::stream::PlatformStream;
use crate::nearby::Adapter;

type Calls = Arc<Mutex<Vec<String>>>;

struct Script(Calls);

impl Script {
    fn note(&self, call: String) {
        self.0.lock().unwrap().push(call);
    }
}

fn describe(value: &[u8]) -> String {
    let presence = Presence::from_value(value).expect("a valid value");
    let tag = presence.tag.map_or("-".to_owned(), |t| t[0].to_string());
    format!("tag {tag} hidden {} public {}", presence.hidden_psm, presence.public_psm)
}

impl Radio for Script {
    fn permission(&self) -> Permission {
        Permission::Allowed
    }
    fn power_up(&mut self, _reports: RadioReports) {
        self.note("power up".into());
    }
    fn power_down(&mut self) {
        self.note("power down".into());
    }
    fn start_scanning(&mut self) {
        self.note("scan".into());
    }
    fn stop_scanning(&mut self) {
        self.note("stop scan".into());
    }
    fn advertise(&mut self, presence: &[u8], public: Option<&[u8]>) {
        let public = public.map_or("none".to_owned(), describe);
        self.note(format!("advertise [{}] public [{public}]", describe(presence)));
    }
    fn stop_advertising(&mut self) {
        self.note("stop advertising".into());
    }
    fn publish_channel(&mut self, public: bool) {
        self.note(format!("publish {}", if public { "public" } else { "hidden" }));
    }
    fn unpublish_channel(&mut self, psm: u16) {
        self.note(format!("unpublish {psm}"));
    }
    fn read_presence(&mut self, peripheral: &str, public: bool) {
        self.note(format!("read {peripheral} {public}"));
    }
    fn open_channel(&mut self, peripheral: &str, psm: u16, dial: u64) {
        self.note(format!("open {peripheral} {psm} dial {dial}"));
    }
}

struct Rig {
    adapter: BluetoothAdapter,
    calls: Calls,
    events: Arc<Mutex<Vec<String>>>,
    now: Arc<Mutex<f64>>,
}

const START: f64 = 1_800_000_000.0;

fn rig() -> Rig {
    let calls = Calls::default();
    let events = Arc::new(Mutex::new(Vec::new()));
    let seen = events.clone();
    let sink: Arc<Sink> = Arc::new(Box::new(move |event: Event| {
        let line = match event {
            Event::State(_, state) => format!("state {state:?}"),
            Event::Sighted(s) => format!("sighted {} public {}", s.endpoint, s.public),
            Event::Lost(_, endpoint) => format!("lost {endpoint}"),
            other => format!("{other:?}"),
        };
        seen.lock().unwrap().push(line);
    }));
    let now = Arc::new(Mutex::new(START));
    let clock = now.clone();
    let radio = Box::new(Script(calls.clone()));
    let adapter = BluetoothAdapter::with_clock(radio, sink, Box::new(move || *clock.lock().unwrap()));
    Rig { adapter, calls, events, now }
}

impl Rig {
    fn calls(&self) -> Vec<String> {
        std::mem::take(&mut *self.calls.lock().unwrap())
    }

    fn events(&self) -> Vec<String> {
        std::mem::take(&mut *self.events.lock().unwrap())
    }

    fn radio(&mut self, event: RadioEvent) -> Vec<String> {
        let produced = self.adapter.radio_event(event);
        produced
            .into_iter()
            .map(|e| match e {
                Event::Sighted(s) => format!("sighted {} public {}", s.endpoint, s.public),
                Event::Lost(_, endpoint) => format!("lost {endpoint}"),
                Event::Accepted { listener, address, .. } => format!("accepted {listener} {address:?}"),
                other => format!("{other:?}"),
            })
            .collect()
    }

    fn powered(&mut self, tag: u8) {
        self.adapter.advertise(Some([tag; 8]), &[[9; 8]; 4], false);
        self.adapter.start();
        self.radio(RadioEvent::Power(Power::On));
        self.radio(RadioEvent::Published { psm: 0x81, public: false });
        self.calls();
        self.events();
    }
}

#[test]
fn states_follow_the_radio() {
    let mut rig = rig();
    rig.adapter.start();
    assert_eq!(rig.adapter.state(), AdapterState::Starting);
    rig.radio(RadioEvent::Power(Power::Unauthorized));
    assert_eq!(rig.adapter.state(), AdapterState::Denied);
    rig.radio(RadioEvent::Power(Power::Off));
    assert_eq!(rig.adapter.state(), AdapterState::RadioOff);
    rig.radio(RadioEvent::Power(Power::On));
    assert_eq!(rig.adapter.state(), AdapterState::Working);
    rig.adapter.stop();
    assert_eq!(rig.adapter.state(), AdapterState::NotAsked);
    let states: Vec<String> = rig.events().into_iter().filter(|e| e.starts_with("state")).collect();
    assert_eq!(states, ["state Starting", "state Denied", "state RadioOff", "state Working", "state NotAsked"]);
    assert_eq!(rig.adapter.permission(), Permission::Allowed);
}

#[test]
fn each_window_gets_its_own_channel_served_whole() {
    let mut rig = rig();
    rig.adapter.advertise(Some([1; 8]), &[[9; 8]; 4], false);
    rig.adapter.start();
    rig.radio(RadioEvent::Power(Power::On));
    assert_eq!(
        rig.calls(),
        ["power up", "publish hidden", "stop advertising", "advertise [tag 1 hidden 0 public 0] public [none]", "scan"]
    );
    rig.radio(RadioEvent::Published { psm: 0x81, public: false });
    assert_eq!(rig.calls(), ["advertise [tag 1 hidden 129 public 0] public [none]"]);

    // A new window: the old one is served whole until its channel is published.
    rig.adapter.advertise(Some([2; 8]), &[[9; 8]; 4], false);
    assert_eq!(rig.calls(), ["publish hidden", "advertise [tag 1 hidden 129 public 0] public [none]"]);
    rig.radio(RadioEvent::Published { psm: 0x83, public: false });
    assert_eq!(rig.calls(), ["stop advertising", "advertise [tag 2 hidden 131 public 0] public [none]"]);
    // The old channel stays for its overlap, then goes.
    *rig.now.lock().unwrap() += 10.0;
    rig.adapter.tick();
    assert!(rig.calls().is_empty());
    *rig.now.lock().unwrap() += 25.0;
    rig.adapter.tick();
    assert_eq!(rig.calls(), ["unpublish 129", "stop scan", "scan"], "and a fresh scan after 30 s");
}

#[test]
fn the_public_entry_has_its_own_channel_and_the_deadline_closes_it() {
    let mut rig = rig();
    rig.powered(1);
    rig.adapter.advertise(Some([1; 8]), &[[9; 8]; 4], true);
    assert_eq!(rig.calls(), ["publish public", "advertise [tag 1 hidden 129 public 0] public [none]"]);
    rig.radio(RadioEvent::Published { psm: 0x85, public: true });
    assert_eq!(rig.calls(), ["advertise [tag 1 hidden 129 public 0] public [tag - hidden 0 public 133]"]);
    rig.adapter.advertise(Some([1; 8]), &[[9; 8]; 4], false);
    assert_eq!(rig.calls(), ["unpublish 133", "advertise [tag 1 hidden 129 public 0] public [none]"]);
    // A public channel published after the deadline is withdrawn at once.
    rig.adapter.advertise(Some([1; 8]), &[[9; 8]; 4], true);
    rig.adapter.advertise(Some([1; 8]), &[[9; 8]; 4], false);
    rig.calls();
    rig.radio(RadioEvent::Published { psm: 0x87, public: true });
    assert_eq!(rig.calls(), ["unpublish 135"]);
}

fn read(rig: &mut Rig, peripheral: &str, tag: u8, public_psm: u16) -> Vec<String> {
    let value = Presence::new(Some([tag; 8]), &[], 0x91, 0).value();
    let public_value = (public_psm != 0).then(|| Presence::public(public_psm).value());
    rig.radio(RadioEvent::Read { peripheral: peripheral.into(), value: Some(value), public_value })
}

#[test]
fn devices_are_read_two_at_a_time_and_cached_for_their_window() {
    let mut rig = rig();
    rig.powered(1);
    for peripheral in ["p1", "p2", "p3"] {
        assert!(rig.radio(RadioEvent::Discovered { peripheral: peripheral.into(), public: false }).is_empty());
    }
    assert_eq!(rig.calls(), ["read p1 false", "read p2 false"]);
    assert_eq!(read(&mut rig, "p1", 7, 0), ["sighted bluetooth:p1 public false"]);
    assert_eq!(rig.calls(), ["read p3 false"]);
    // Seen again within its window: the cached value, no read.
    let again = rig.radio(RadioEvent::Discovered { peripheral: "p1".into(), public: false });
    assert_eq!(again, ["sighted bluetooth:p1 public false"]);
    assert!(rig.calls().is_empty());
    read(&mut rig, "p2", 8, 0);
    read(&mut rig, "p3", 9, 0);
    // Now advertising its public entry: read again, both values; then visibility ends.
    rig.radio(RadioEvent::Discovered { peripheral: "p1".into(), public: true });
    assert_eq!(rig.calls(), ["read p1 true"]);
    let both = read(&mut rig, "p1", 7, 0x93);
    assert_eq!(both, ["sighted bluetooth:p1 public false", "sighted bluetooth:p1/public public true"]);
    rig.radio(RadioEvent::Discovered { peripheral: "p1".into(), public: false });
    let hidden_only = read(&mut rig, "p1", 7, 0);
    assert_eq!(hidden_only, ["sighted bluetooth:p1 public false", "lost bluetooth:p1/public"]);
    // A new window makes the cache stale.
    *rig.now.lock().unwrap() += 900.0;
    rig.calls();
    rig.radio(RadioEvent::Discovered { peripheral: "p1".into(), public: false });
    assert_eq!(rig.calls(), ["read p1 false"]);
    // A failed read is not a sighting.
    let failed = rig.radio(RadioEvent::Read { peripheral: "p1".into(), value: None, public_value: None });
    assert!(failed.is_empty());
}

#[test]
fn dials_open_the_channel_an_endpoint_names() {
    let mut rig = rig();
    rig.powered(1);
    rig.radio(RadioEvent::Discovered { peripheral: "p1".into(), public: true });
    read(&mut rig, "p1", 7, 0x93);
    rig.calls();
    assert!(rig.adapter.dial("bluetooth:p1", 4));
    assert!(rig.adapter.dial("bluetooth:p1/public", 5));
    assert!(!rig.adapter.dial("bluetooth:p9", 6));
    assert!(!rig.adapter.dial("n:p1", 7));
    assert_eq!(rig.calls(), ["open p1 145 dial 4", "open p1 147 dial 5"]);
}

#[test]
fn channels_are_accepted_only_while_running() {
    let mut rig = rig();
    rig.powered(1);
    let (stream, _other) = PlatformStream::pair();
    let accepted = rig.radio(RadioEvent::Accepted {
        stream: LinkStream::Platform(stream),
        public: false,
        peer: Some("AA:BB".into()),
    });
    assert_eq!(accepted, ["accepted bluetooth hidden Some(\"AA:BB\")"]);
    rig.adapter.stop();
    let closed = Arc::new(AtomicBool::new(false));
    let flag = closed.clone();
    let (stream, _incoming) = PlatformStream::new(Box::new(move |bytes| {
        if bytes.is_none() {
            flag.store(true, Ordering::SeqCst);
        }
    }));
    let refused = rig.radio(RadioEvent::Accepted { stream: LinkStream::Platform(stream), public: true, peer: None });
    assert!(refused.is_empty());
    assert!(closed.load(Ordering::SeqCst), "the other side is told the end");
}
