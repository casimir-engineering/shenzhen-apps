//! The LAN adapter (`SZFriendsNetworkAdapter.m`, ADR 0004 § Decision): a hidden entry and, during the person's 5
//! minutes, a public one, each a TCP listener registered under a random instance name, and a browser for others.
//!
//! Each presence window gets a fresh hidden listener, port and name (Review amendments, 3): the old entry leaves the
//! air at once and its listener keeps accepting for a short overlap, for a friend already connecting to it. Within a
//! window the TXT may change (callback slots, the public entry) on the same listener. Our own recent names are never
//! sighted. Where the firewall admits no listener (ADR 0015 § 15), nothing is registered: this computer still finds
//! others and dials them, and nobody finds it. That is decided again before every new hidden listener (each window)
//! and whenever the adapter is set up again (a network change, waking), since a rule or a profile may have changed.
//! Where the platform listens and connects itself (iOS, for peer-to-peer
//! Wi-Fi), each entry is its own platform listener: a rotated entry is withdrawn from the air at once and closed after
//! the same overlap, and dials go through the platform.

use std::collections::{HashMap, VecDeque};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use szfriends_core::nearby::callbacks::window;
use szfriends_core::nearby::firewall::Inbound;
use szfriends_core::nearby::txt::{self, random_instance_name};
use szfriends_core::nearby::{AdapterState, Method, Sighting, Tag};
use szfriends_core::store::unix_now;
use szfriends_core::wire::RouteMethod;

use super::dnssd::{BrowseEvent, DnsSd};
pub use super::listeners::Binding;
use super::listeners::Listener;
use super::{Adapter, Event, Sink};
use crate::log;

/// Our recent instance names: a rotated name lingers in other browsers' results for a moment.
const OWN_NAMES_REMEMBERED: usize = 8;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// A failing browser or listener is set up again after this.
const RETRY_DELAY: Duration = Duration::from_secs(5);

/// Reads where listeners may bind now, and why nobody nearby can connect when nowhere (Windows: the firewall's
/// current policy).
pub type Rebind = Box<dyn Fn() -> (Binding, Inbound) + Send>;

struct Entry {
    listener: Option<Listener>,
    name: String,
    key: Vec<u8>,
}

/// See the module documentation.
pub struct LanAdapter {
    backend: Box<dyn DnsSd>,
    binding: Binding,
    /// Why nobody nearby can connect while the binding is nowhere.
    inbound: Inbound,
    rebind: Option<Rebind>,
    sink: Arc<Sink>,
    running: bool,
    browser_ready: bool,
    denied: bool,
    /// The platform said its Wi-Fi is off (BrowseEvent::Radio).
    radio_off: bool,
    failed_at: Option<Instant>,
    hidden: Option<Entry>,
    retiring: Vec<(Listener, Instant)>,
    /// Platform entries off the air, still accepting until their overlap ends.
    withdrawn: Vec<(String, Instant)>,
    public: Option<Entry>,
    tag: Option<Tag>,
    slots: Vec<Tag>,
    public_on: bool,
    own_names: VecDeque<String>,
    endpoints: HashMap<String, Vec<SocketAddr>>,
}

impl std::fmt::Debug for LanAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LanAdapter").field("running", &self.running).field("binding", &self.binding).finish()
    }
}

fn endpoint_id(name: &str) -> String {
    format!("n:{name}")
}

impl LanAdapter {
    pub fn new(backend: Box<dyn DnsSd>, binding: Binding, sink: Arc<Sink>) -> Self {
        Self {
            backend,
            inbound: if binding == Binding::Nowhere { Inbound::NoRule } else { Inbound::Open },
            binding,
            rebind: None,
            sink,
            running: false,
            browser_ready: false,
            denied: false,
            radio_off: false,
            failed_at: None,
            hidden: None,
            retiring: Vec::new(),
            withdrawn: Vec::new(),
            public: None,
            tag: None,
            slots: Vec::new(),
            public_on: false,
            own_names: VecDeque::new(),
            endpoints: HashMap::new(),
        }
    }

    /// Decides the binding again before each new hidden listener and each set-up.
    pub fn with_rebind(mut self, rebind: Rebind) -> Self {
        (self.binding, self.inbound) = rebind();
        self.rebind = Some(rebind);
        self
    }

    /// Reads the binding again; entries made under another one leave the air with their listeners.
    fn rebind(&mut self) {
        let Some((binding, inbound)) = self.rebind.as_ref().map(|rebind| rebind()) else { return };
        if binding == self.binding {
            if inbound != self.inbound {
                // Same binding, another reason (a network that became public): the Nearby line follows.
                self.inbound = inbound;
                self.report_state();
            }
            return;
        }
        self.inbound = inbound;
        log!("nearby network: listening {}", if binding == Binding::Nowhere { "nowhere now" } else { "again" });
        self.binding = binding;
        for entry in [self.hidden.take(), self.public.take()].into_iter().flatten() {
            self.backend.unregister(&entry.name);
        }
        self.retiring.clear();
        // Nearby's line about this computer accepting connections follows.
        self.report_state();
    }

    fn fresh_name(&mut self) -> String {
        let name = random_instance_name();
        self.own_names.push_back(name.clone());
        if self.own_names.len() > OWN_NAMES_REMEMBERED {
            self.own_names.pop_front();
        }
        name
    }

    fn report_state(&self) {
        (self.sink)(Event::State(Method::Network, self.state()));
    }

    fn fail(&mut self, why: &str) {
        log!("nearby network: {why}");
        self.failed_at = Some(Instant::now());
        self.report_state();
    }

    fn hidden_key(&self) -> Vec<u8> {
        match self.tag {
            Some(tag) => tag.to_vec(),
            None => window(unix_now()).to_be_bytes().to_vec(),
        }
    }

    fn update_hidden(&mut self) {
        let key = self.hidden_key();
        if self.hidden.as_ref().is_none_or(|h| h.key != key) {
            self.rebind();
        }
        if self.binding == Binding::Nowhere {
            return;
        }
        if self.hidden.as_ref().is_some_and(|h| h.key != key) {
            // Off the air at once, still accepting a short while for whoever resolved it just before.
            let old = self.hidden.take().expect("checked");
            if self.binding == Binding::Platform {
                self.backend.withdraw(&old.name);
                self.withdrawn.push((old.name, Instant::now()));
            } else {
                self.backend.unregister(&old.name);
            }
            if let Some(listener) = old.listener {
                self.retiring.push((listener, Instant::now()));
            }
        }
        let fields = txt::fields(self.tag.as_ref(), &self.slots, false);
        if let Some(hidden) = &self.hidden {
            let port = hidden.listener.as_ref().map_or(0, Listener::port);
            if let Err(error) = self.backend.register(&hidden.name.clone(), port, &fields) {
                self.fail(&format!("registration: {error}"));
            }
            return;
        }
        let listener = match self.listener(false) {
            Ok(listener) => listener,
            Err(error) => return self.fail(&format!("hidden listener: {error}")),
        };
        let name = self.fresh_name();
        let port = listener.as_ref().map_or(0, Listener::port);
        self.hidden = Some(Entry { listener, name: name.clone(), key });
        if let Err(error) = self.backend.register(&name, port, &fields) {
            self.fail(&format!("registration: {error}"));
        }
    }

    fn update_public(&mut self) {
        if self.binding == Binding::Nowhere {
            return;
        }
        match (self.public_on, self.public.is_some()) {
            (true, false) => {
                let listener = match self.listener(true) {
                    Ok(listener) => listener,
                    Err(error) => return self.fail(&format!("public listener: {error}")),
                };
                let name = self.fresh_name();
                let fields = txt::fields(None, &[], true);
                if let Err(error) = self.backend.register(&name, listener.as_ref().map_or(0, Listener::port), &fields) {
                    self.fail(&format!("public registration: {error}"));
                }
                self.public = Some(Entry { listener, name, key: Vec::new() });
            }
            (false, true) => {
                // The deadline withdraws the entry and its listener at once.
                let entry = self.public.take().expect("checked");
                self.backend.unregister(&entry.name);
            }
            _ => {}
        }
    }

    /// Our own listener, or none where the platform listens for each entry itself.
    fn listener(&self, public: bool) -> std::io::Result<Option<Listener>> {
        if self.binding == Binding::Platform {
            return Ok(None);
        }
        let id = if public { "public" } else { "hidden" };
        Listener::start(&self.binding, public, id, self.sink.clone()).map(Some)
    }

    fn set_up(&mut self) {
        self.rebind();
        self.browser_ready = false;
        self.failed_at = None;
        self.report_state();
        self.update_hidden();
        self.update_public();
        let sink = self.sink.clone();
        if let Err(error) = self.backend.browse(Box::new(move |event| sink(Event::Browse(event)))) {
            self.fail(&format!("browser: {error}"));
        }
    }

    fn tear_down(&mut self) {
        self.backend.stop();
        self.hidden = None;
        self.public = None;
        self.retiring.clear();
        self.withdrawn.clear();
        // Said out loud rather than dropped, so whoever holds these endpoints starts their grace now.
        for endpoint in self.endpoints.keys() {
            (self.sink)(Event::Lost(Method::Network, endpoint.clone()));
        }
        self.endpoints.clear();
    }
}

impl Adapter for LanAdapter {
    fn method(&self) -> Method {
        Method::Network
    }

    fn state(&self) -> AdapterState {
        if !self.running {
            AdapterState::NotAsked
        } else if self.denied {
            AdapterState::Denied
        } else if self.radio_off {
            AdapterState::RadioOff
        } else if self.failed_at.is_some() {
            AdapterState::Unavailable
        } else if self.browser_ready && (self.hidden.is_some() || self.binding == Binding::Nowhere) {
            AdapterState::Working
        } else {
            AdapterState::Starting
        }
    }

    fn start(&mut self) {
        if self.running {
            return;
        }
        self.running = true;
        self.set_up();
    }

    fn stop(&mut self) {
        if !self.running {
            return;
        }
        self.running = false;
        self.tear_down();
        self.report_state();
    }

    fn advertise(&mut self, tag: Option<Tag>, slots: &[Tag], public: bool) {
        self.tag = tag;
        self.slots = slots.to_vec();
        self.public_on = public;
        if self.running {
            self.update_hidden();
            self.update_public();
        }
    }

    fn browse_event(&mut self, event: BrowseEvent) -> Vec<Event> {
        if !self.running {
            return Vec::new();
        }
        match event {
            BrowseEvent::Denied => {
                // Inferred only from the system's refusal, never from an empty result (ADR 0004).
                self.denied = true;
                vec![Event::State(Method::Network, self.state())]
            }
            BrowseEvent::Ready => {
                self.browser_ready = true;
                self.denied = false;
                vec![Event::State(Method::Network, self.state())]
            }
            BrowseEvent::Failed(why) => {
                self.fail(&why);
                Vec::new()
            }
            BrowseEvent::Radio(on) => {
                if self.radio_off == !on {
                    return Vec::new();
                }
                self.radio_off = !on;
                vec![Event::State(Method::Network, self.state())]
            }
            BrowseEvent::Found { name, addresses, txt } => {
                if self.own_names.contains(&name) || addresses.is_empty() {
                    return Vec::new();
                }
                let fields = txt.iter().map(|(k, v)| (k.as_str(), v.as_slice()));
                let Some(parsed) = txt::parse(fields) else { return Vec::new() };
                let endpoint = endpoint_id(&name);
                self.endpoints.insert(endpoint.clone(), addresses);
                vec![Event::Sighted(Sighting {
                    method: Method::Network,
                    route: RouteMethod::Lan,
                    endpoint,
                    presence_tag: parsed.tag,
                    callback_tags: parsed.callback_tags,
                    public: parsed.public,
                    seen_at: unix_now(),
                })]
            }
            BrowseEvent::FoundByPlatform { name, txt, peer_to_peer } => {
                if self.own_names.contains(&name) {
                    return Vec::new();
                }
                let fields = txt.iter().map(|(k, v)| (k.as_str(), v.as_slice()));
                let Some(parsed) = txt::parse(fields) else { return Vec::new() };
                let endpoint = endpoint_id(&name);
                self.endpoints.insert(endpoint.clone(), Vec::new());
                vec![Event::Sighted(Sighting {
                    method: Method::Network,
                    route: if peer_to_peer { RouteMethod::PeerToPeerWifi } else { RouteMethod::Lan },
                    endpoint,
                    presence_tag: parsed.tag,
                    callback_tags: parsed.callback_tags,
                    public: parsed.public,
                    seen_at: unix_now(),
                })]
            }
            BrowseEvent::Lost { name } => {
                let endpoint = endpoint_id(&name);
                match self.endpoints.remove(&endpoint) {
                    Some(_) => vec![Event::Lost(Method::Network, endpoint)],
                    None => Vec::new(),
                }
            }
        }
    }

    fn dial(&mut self, endpoint: &str, dial: u64) -> bool {
        let Some(addresses) = self.endpoints.get(endpoint).cloned() else { return false };
        if self.backend.owns_connections() {
            let name = endpoint.strip_prefix("n:").unwrap_or(endpoint);
            return self.backend.dial(name, dial);
        }
        let sink = self.sink.clone();
        let spawned = std::thread::Builder::new().name("szfriends-dial".into()).spawn(move || {
            let stream = super::connect_any(&addresses, CONNECT_TIMEOUT).map(Into::into);
            sink(Event::Dialed { dial, stream });
        });
        spawned.is_ok()
    }

    fn refresh(&mut self) {
        if self.running {
            // A firewall rule may have just been added (Allow on Private Networks): listen at once if it admits.
            let before = self.binding.clone();
            self.rebind();
            if self.binding != before {
                self.update_hidden();
                self.update_public();
            }
            self.backend.refresh();
        }
    }

    fn listening(&self) -> bool {
        self.binding != Binding::Nowhere
    }

    fn inbound(&self) -> Inbound {
        if self.listening() {
            Inbound::Open
        } else {
            self.inbound
        }
    }

    fn tick(&mut self) {
        let overlap = Duration::from_secs_f64(szfriends_core::nearby::limits::LISTENER_OVERLAP_SECONDS);
        self.retiring.retain(|(_, since)| since.elapsed() < overlap);
        let (over, kept): (Vec<_>, Vec<_>) =
            self.withdrawn.drain(..).partition(|(_, since)| since.elapsed() >= overlap);
        self.withdrawn = kept;
        for (name, _) in over {
            self.backend.unregister(&name);
        }
        if self.running && self.failed_at.is_some_and(|at| at.elapsed() >= RETRY_DELAY) {
            // Straight from Unavailable to Starting: Nearby never shows the method as not asked in between.
            self.tear_down();
            self.set_up();
        }
    }
}

#[cfg(test)]
#[path = "lan_tests.rs"]
mod tests;
