//! Discovery a phone's platform does for the core (ADR 0015 § 9, § 10): the app's own code (the Tauri plugin's
//! Kotlin and Swift) registers and browses DNS-SD entries (Android's `NsdManager`, Apple's DNS-SD), runs the
//! Bluetooth radio (a [`super::bluetooth::Radio`] whose channels reach the core as platform streams), and asks for
//! permissions when Friends is opened; the core keeps its own listeners and connections and runs everything else as
//! on a desktop. The app installs its [`PlatformDiscovery`] and radio before the core starts; [`super::adapters`]
//! then gives the core a LAN adapter and a Bluetooth adapter over them.

use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, OnceLock};

use szfriends_core::wire::RouteMethod;

use super::dnssd::{BrowseEvent, BrowseSink, DnsSd};
use super::stream::{LinkStream, PlatformStream};
use super::{Event, Sink};

/// What the platform's DNS-SD does for the core. Every method returns at once; results come through [`Reports`].
///
/// Android registers the core's own listeners and resolves addresses the core dials. iOS listens and connects
/// itself ([`PlatformDiscovery::owns_connections`]), because only `NWListener` and `NWConnection` reach peer-to-peer
/// Wi-Fi: each entry is its own listener, found instances are reported without addresses, and connections cross
/// into the core as platform streams.
pub trait PlatformDiscovery: Send + Sync {
    /// Registers `name` of `service_type` ("_szfriends._tcp") at `port` with these TXT fields; again for a new TXT.
    /// Where the platform owns connections, `port` is 0 and the entry is a listener of its own.
    fn register(&self, service_type: &str, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()>;
    fn unregister(&self, name: &str);
    /// Browses `service_type`, resolving each instance (on Android before 14 one at a time, newest sighting first:
    /// `szfriends-core::nearby::resolve_queue`), and reports through `reports` until [`PlatformDiscovery::stop`].
    fn browse(&self, service_type: &str, reports: Reports) -> io::Result<()>;
    fn stop(&self);
    /// Whether the platform listens and connects itself (iOS).
    fn owns_connections(&self) -> bool {
        false
    }
    /// Takes an entry off the air while its listener keeps accepting (until [`PlatformDiscovery::unregister`]).
    fn withdraw(&self, name: &str) {
        self.unregister(name);
    }
    /// Connects to a found instance; the platform answers with [`Reports::opened`] for this `dial`.
    fn connect(&self, name: &str, dial: u64) -> bool {
        let _ = (name, dial);
        false
    }
}

/// Our registered entries and whether each is the public one.
type Names = Arc<Mutex<HashMap<String, bool>>>;

/// Where the platform reports what it found and the connections it made (from any thread).
#[derive(Clone)]
pub struct Reports {
    browse: Arc<BrowseSink>,
    sink: Option<Arc<Sink>>,
    names: Names,
}

impl std::fmt::Debug for Reports {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Reports")
    }
}

impl Reports {
    pub fn ready(&self) {
        (self.browse)(BrowseEvent::Ready);
    }

    /// An instance, resolved: its addresses (with the port) and TXT fields; again whenever any of it changes.
    pub fn found(&self, name: &str, addresses: Vec<SocketAddr>, txt: Vec<(String, Vec<u8>)>) {
        (self.browse)(BrowseEvent::Found { name: name.to_owned(), addresses, txt });
    }

    pub fn lost(&self, name: &str) {
        (self.browse)(BrowseEvent::Lost { name: name.to_owned() });
    }

    /// The person refused local network access (iOS's PolicyDenied): Nearby says so and how to allow it.
    pub fn denied(&self) {
        (self.browse)(BrowseEvent::Denied);
    }

    /// The platform cannot browse now (no network, an error); detail for the log only.
    pub fn failed(&self, why: &str) {
        (self.browse)(BrowseEvent::Failed(why.to_owned()));
    }

    /// An instance the platform reaches itself, with its TXT; `peer_to_peer` when only peer-to-peer Wi-Fi does.
    pub fn found_by_platform(&self, name: &str, txt: Vec<(String, Vec<u8>)>, peer_to_peer: bool) {
        (self.browse)(BrowseEvent::FoundByPlatform { name: name.to_owned(), txt, peer_to_peer });
    }

    /// Someone connected to our entry `name`; `address` is what the per-address admission limit counts.
    pub fn accepted(&self, name: &str, stream: PlatformStream, address: Option<String>, peer_to_peer: bool) {
        let public = self.names.lock().unwrap_or_else(|e| e.into_inner()).get(name).copied();
        let (Some(sink), Some(public)) = (&self.sink, public) else {
            let mut stream = stream;
            return (stream.outgoing)(None);
        };
        let route = if peer_to_peer { RouteMethod::PeerToPeerWifi } else { RouteMethod::Lan };
        let listener = if public { "public" } else { "hidden" }.to_owned();
        let stream = LinkStream::Platform(stream);
        sink(Event::Accepted { stream, route, public, listener, address });
    }

    /// The connection a [`PlatformDiscovery::connect`] asked for, or `None`.
    pub fn opened(&self, dial: u64, stream: Option<PlatformStream>) {
        if let Some(sink) = &self.sink {
            sink(Event::Dialed { dial, stream: stream.map(LinkStream::Platform) });
        }
    }
}

static INSTALLED: OnceLock<Arc<dyn PlatformDiscovery>> = OnceLock::new();
/// Makes the app's Bluetooth radio (`super::bluetooth::Radio`) each time the core starts.
pub type RadioFactory = Box<dyn Fn() -> Box<dyn super::bluetooth::Radio> + Send + Sync>;
static RADIO: OnceLock<RadioFactory> = OnceLock::new();

/// The app's discovery, installed once before the core starts.
pub fn install(discovery: Arc<dyn PlatformDiscovery>) -> bool {
    INSTALLED.set(discovery).is_ok()
}

pub fn installed() -> Option<Arc<dyn PlatformDiscovery>> {
    INSTALLED.get().cloned()
}

/// The app's Bluetooth, installed once before the core starts, where the device has it.
pub fn install_radio(factory: RadioFactory) -> bool {
    RADIO.set(factory).is_ok()
}

pub fn radio() -> Option<Box<dyn super::bluetooth::Radio>> {
    RADIO.get().map(|factory| factory())
}

/// The LAN adapter's DNS-SD over the platform's.
pub struct PlatformDnsSd {
    discovery: Arc<dyn PlatformDiscovery>,
    service_type: String,
    names: Names,
    sink: Option<Arc<Sink>>,
}

impl std::fmt::Debug for PlatformDnsSd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PlatformDnsSd").field("service_type", &self.service_type).finish()
    }
}

impl PlatformDnsSd {
    /// `sink` takes the connections a platform that owns them makes.
    pub fn new(discovery: Arc<dyn PlatformDiscovery>, service_type: &str, sink: Option<Arc<Sink>>) -> Self {
        Self { discovery, service_type: service_type.to_owned(), names: Names::default(), sink }
    }

    fn names(&self) -> std::sync::MutexGuard<'_, HashMap<String, bool>> {
        self.names.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl DnsSd for PlatformDnsSd {
    fn browse(&mut self, sink: BrowseSink) -> io::Result<()> {
        let reports = Reports { browse: Arc::new(sink), sink: self.sink.clone(), names: self.names.clone() };
        self.discovery.browse(&self.service_type, reports)
    }

    fn register(&mut self, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()> {
        // Known before the platform can report a connection to it.
        let public = txt.iter().any(|(key, value)| key == "p" && value == "1");
        self.names().insert(name.to_owned(), public);
        self.discovery.register(&self.service_type, name, port, txt)
    }

    fn unregister(&mut self, name: &str) {
        self.discovery.unregister(name);
        self.names().remove(name);
    }

    fn stop(&mut self) {
        let names: Vec<String> = self.names().drain().map(|(name, _)| name).collect();
        for name in names {
            self.discovery.unregister(&name);
        }
        self.discovery.stop();
    }

    fn owns_connections(&self) -> bool {
        self.discovery.owns_connections()
    }

    fn withdraw(&mut self, name: &str) {
        self.discovery.withdraw(name);
    }

    fn dial(&mut self, name: &str, dial: u64) -> bool {
        self.discovery.connect(name, dial)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc::channel;

    use super::*;

    #[derive(Default)]
    struct Recorder {
        calls: Mutex<Vec<String>>,
        reports: Mutex<Option<Reports>>,
        owns: bool,
    }

    impl PlatformDiscovery for Recorder {
        fn register(&self, service_type: &str, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()> {
            let fields: Vec<String> = txt.iter().map(|(k, v)| format!("{k}={v}")).collect();
            self.calls.lock().unwrap().push(format!("register {service_type} {name} {port} {}", fields.join(" ")));
            Ok(())
        }

        fn unregister(&self, name: &str) {
            self.calls.lock().unwrap().push(format!("unregister {name}"));
        }

        fn browse(&self, service_type: &str, reports: Reports) -> io::Result<()> {
            self.calls.lock().unwrap().push(format!("browse {service_type}"));
            *self.reports.lock().unwrap() = Some(reports);
            Ok(())
        }

        fn stop(&self) {
            self.calls.lock().unwrap().push("stop".into());
        }

        fn owns_connections(&self) -> bool {
            self.owns
        }

        fn withdraw(&self, name: &str) {
            self.calls.lock().unwrap().push(format!("withdraw {name}"));
        }

        fn connect(&self, name: &str, dial: u64) -> bool {
            self.calls.lock().unwrap().push(format!("connect {name} {dial}"));
            true
        }
    }

    /// iOS: each entry its own listener, found instances without addresses, connections from the platform.
    #[test]
    fn a_platform_that_owns_its_connections() {
        use crate::nearby::lan::{Binding, LanAdapter};
        use crate::nearby::Adapter;
        let recorder = Arc::new(Recorder { owns: true, ..Recorder::default() });
        let (sender, events) = channel();
        let sender = Mutex::new(sender);
        let sink: Arc<Sink> = Arc::new(Box::new(move |event| sender.lock().unwrap().send(event).unwrap()));
        let backend = PlatformDnsSd::new(recorder.clone(), "_szfriends._tcp", Some(sink.clone()));
        let mut lan = LanAdapter::new(Box::new(backend), Binding::Platform, sink);
        lan.advertise(Some([1; 8]), &[[2; 8]; 4], true);
        lan.start();
        let calls = std::mem::take(&mut *recorder.calls.lock().unwrap());
        let registered: Vec<&String> = calls.iter().filter(|c| c.starts_with("register")).collect();
        assert_eq!(registered.len(), 2, "{calls:?}");
        assert!(registered.iter().all(|c| c.split(' ').nth(3) == Some("0")), "no port of ours: {calls:?}");
        let hidden = registered[0].split(' ').nth(2).unwrap().to_owned();
        let public = registered[1].split(' ').nth(2).unwrap().to_owned();

        let reports = recorder.reports.lock().unwrap().clone().unwrap();
        let txt = vec![("v".to_owned(), b"1".to_vec()), ("t".to_owned(), b"0303030303030303".to_vec())];
        reports.found_by_platform("e5f6", txt, true);
        let found = events.try_iter().find_map(|e| if let Event::Browse(b) = e { Some(b) } else { None });
        let found = found.expect("a browse event");
        let sighted = lan.browse_event(found);
        assert!(matches!(&sighted[..], [Event::Sighted(s)] if s.route == RouteMethod::PeerToPeerWifi));
        assert!(lan.dial("n:e5f6", 7));
        assert!(recorder.calls.lock().unwrap().contains(&"connect e5f6 7".to_owned()));

        let (stream, _other) = PlatformStream::pair();
        reports.accepted(&public, stream, Some("fe80::1".into()), false);
        let accepted = events.try_iter().find_map(|e| match e {
            Event::Accepted { public, listener, .. } => Some((public, listener)),
            _ => None,
        });
        assert_eq!(accepted, Some((true, "public".to_owned())));
        let (stream, _other) = PlatformStream::pair();
        reports.accepted("someone-else", stream, None, false);
        let accepted = events.try_iter().any(|e| matches!(e, Event::Accepted { .. }));
        assert!(!accepted, "a connection to an entry we never made is closed");

        // A new window: the old entry leaves the air but keeps accepting for its overlap.
        lan.advertise(Some([4; 8]), &[[2; 8]; 4], true);
        assert!(recorder.calls.lock().unwrap().contains(&format!("withdraw {hidden}")));
        let (stream, _other) = PlatformStream::pair();
        reports.accepted(&hidden, stream, None, false);
        assert!(events.try_iter().any(|e| matches!(e, Event::Accepted { public: false, .. })));
    }

    #[test]
    fn the_platform_registers_browses_and_reports() {
        let recorder = Arc::new(Recorder::default());
        let mut backend = PlatformDnsSd::new(recorder.clone(), "_szfriends._tcp", None);
        let (sender, events) = channel();
        backend.browse(Box::new(move |event| sender.send(event).unwrap())).unwrap();
        backend.register("a1b2", 4242, &[("v".into(), "1".into())]).unwrap();
        backend.register("a1b2", 4242, &[("v".into(), "1".into()), ("p".into(), "1".into())]).unwrap();
        let reports = recorder.reports.lock().unwrap().clone().unwrap();
        reports.ready();
        reports.found("c3d4", vec!["192.168.1.7:5000".parse().unwrap()], vec![("v".into(), b"1".to_vec())]);
        reports.denied();
        reports.lost("c3d4");
        let seen: Vec<BrowseEvent> = events.try_iter().collect();
        assert_eq!(seen[0], BrowseEvent::Ready);
        assert!(matches!(&seen[1], BrowseEvent::Found { name, .. } if name == "c3d4"));
        assert_eq!(seen[2], BrowseEvent::Denied);
        assert_eq!(seen[3], BrowseEvent::Lost { name: "c3d4".into() });
        backend.stop();
        let calls = recorder.calls.lock().unwrap().clone();
        assert_eq!(
            calls,
            [
                "browse _szfriends._tcp",
                "register _szfriends._tcp a1b2 4242 v=1",
                "register _szfriends._tcp a1b2 4242 v=1 p=1",
                "unregister a1b2",
                "stop"
            ]
        );
    }
}
