//! Nearby Friends in the service (`service/helper/nearby/`, ADR 0004): discovery, sessions and requests wired
//! together on the service's thread. The adapters ([`crate::nearby`]) find devices and accept connections; the merger
//! and racer (`szfriends-core::nearby`) decide who is who and what to dial; this decides who may connect, what each
//! session is for, and what friend requests, Add by ID and visibility do.
//!
//! | File | Mirrors | What |
//! |---|---|---|
//! | `mod.rs` | `SZFriendsNearbyService.m`, `…DiscoveryCoordinator.m` | adapters, advertising, windows, visibility |
//! | `policy.rs` | `+KeyPolicy.m` | who may open a session to us |
//! | `links.rs` | `+Sessions.m` | accepting, dialing, going live, the session race |
//! | `dial.rs` | `+Dial.m` | whom to connect to and how |
//! | `inbound.rs` | `+Inbound.m` | requests, answers, presence secrets, profiles |
//! | `by_id.rs` | `+RequestByID.m` | Add by ID nearby |
//! | `people.rs` | `SZFriendsIntentRouter+People.m` | the people intents |
//! | `facts.rs` | `+Facts.m` | what Nearby shows |
//! | `join.rs` | `+Join.m`, `+JoinNearby.m` | joining a profile from a new computer |
//! | `own.rs` | `+Sync.m` | finding, reaching and syncing with our own other devices |
//! | `chain.rs` | `+Chain.m` | our chain to friends, theirs kept, a chain before a first request |
//! | `friend_devices.rs` | `+FriendDevices.m` | finding and reaching friends' other computers |
//! | `removed.rs` | `+Removed.m` | telling a computer we removed that it was removed |

mod by_id;
mod chain;
mod dial;
mod facts;
mod friend_devices;
mod inbound;
mod join;
#[cfg(feature = "online")]
mod join_online;
mod links;
mod own;
mod people;
pub mod policy;
mod removed;

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use szfriends_core::nearby::admission::{Admission, Limits};
use szfriends_core::nearby::callbacks::{window, CallbackSlots, TagMatcher};
use szfriends_core::nearby::merger::Merger;
use szfriends_core::nearby::racer::Racer;
use szfriends_core::nearby::visibility::{Instant, Visibility};
use szfriends_core::nearby::{start_adapter_at_launch, AdapterState, Method, Tag};
use szfriends_core::store::{unix_now, Relation};
use szfriends_core::wire::Fields;

pub use by_id::AnswerAttestation;
pub(crate) use facts::view_route;
pub use links::{LinkMeta, Purpose};

use super::{Input, State};
use crate::nearby::{Adapter, Event};

/// Requests nobody answers lapse; looked at this often.
const EXPIRE_REQUESTS_EVERY: f64 = 60.0;

/// One planned connection attempt (`SZFriendsDialPlan`).
#[derive(Clone, Debug)]
pub struct DialPlan {
    pub method: Method,
    pub endpoint: String,
    pub route: szfriends_core::wire::RouteMethod,
    pub purpose: Purpose,
    pub options: szfriends_core::session::HandshakeOptions,
    pub conversation: Option<String>,
    pub probe: bool,
    /// NN: the Add by ID request it carries; and its one-shot key.
    pub request_token: Option<[u8; 16]>,
    pub attempt_key: Option<String>,
    pub dial_key: String,
}

/// Everything nearby keeps besides the sessions themselves.
pub struct Nearby {
    pub adapters: Vec<Box<dyn Adapter>>,
    started: HashSet<Method>,
    pub merger: Merger,
    pub racer: Racer,
    pub visibility: Visibility,
    slots: CallbackSlots,
    advertised: Option<(Option<Tag>, Vec<Tag>, bool)>,
    window: i64,
    /// From browse handshakes, by identity key: what a public entry served, and its static key.
    pub public_profiles: HashMap<[u8; 32], (Fields, Option<[u8; 32]>)>,
    /// When a one-shot attempt may be made again ("browse|…", "probe|…", "byid|…"), Unix seconds.
    pub attempts: HashMap<String, f64>,
    pub dialing: HashSet<String>,
    pub retry_after: HashMap<String, f64>,
    pub failures: HashMap<String, u32>,
    pub by_id_senders: HashMap<[u8; 32], f64>,
    /// When REQUEST_BY_ID last went to a device, by token: its callback tags are on the air for hours after.
    pub callback_broadcasts: HashMap<[u8; 16], f64>,
    /// Staggered dials not started yet (due, plan), and dials waiting for their stream.
    pub staged: Vec<(f64, DialPlan)>,
    pub dials: HashMap<u64, DialPlan>,
    next_dial: u64,
    /// Conversations whose entries say Connecting, until when.
    pub connecting: HashMap<String, f64>,
    pub admission: Arc<Mutex<Admission>>,
    pub policy: Arc<Mutex<policy::PolicyView>>,
    /// What public entries served our browse-only handshakes, by session, read once each closes.
    pub browsed: Arc<Mutex<HashMap<u64, Fields>>>,
    states: HashMap<Method, AdapterState>,
    working_since: Option<f64>,
    reconsider_at: Option<f64>,
    expire_at: f64,
    callback_refresh_at: Option<f64>,
    pub shut_down: bool,
}

impl std::fmt::Debug for Nearby {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Nearby").field("adapters", &self.adapters.len()).field("window", &self.window).finish()
    }
}

impl Nearby {
    pub fn new(adapters: Vec<Box<dyn Adapter>>, stored_deadline: Option<f64>) -> Self {
        let states = adapters.iter().map(|a| (a.method(), AdapterState::NotAsked)).collect();
        Self {
            adapters,
            started: HashSet::new(),
            merger: Merger::default(),
            racer: Racer::default(),
            visibility: Visibility::restored(stored_deadline, Instant::now()),
            slots: CallbackSlots::default(),
            advertised: None,
            window: window(unix_now()),
            public_profiles: HashMap::new(),
            attempts: HashMap::new(),
            dialing: HashSet::new(),
            retry_after: HashMap::new(),
            failures: HashMap::new(),
            by_id_senders: HashMap::new(),
            callback_broadcasts: HashMap::new(),
            staged: Vec::new(),
            dials: HashMap::new(),
            next_dial: 0,
            connecting: HashMap::new(),
            admission: Arc::new(Mutex::new(Admission::new(Limits::nearby()))),
            policy: Arc::new(Mutex::new(policy::PolicyView::default())),
            browsed: Arc::new(Mutex::new(HashMap::new())),
            states,
            working_since: None,
            reconsider_at: None,
            expire_at: 0.0,
            callback_refresh_at: None,
            shut_down: false,
        }
    }

    pub fn has_adapter(&self, method: Method) -> bool {
        self.adapters.iter().any(|a| a.method() == method)
    }

    /// What a method shows: unavailable without an adapter (a test home without a test network), else its state.
    pub fn state_of(&self, method: Method) -> AdapterState {
        if !self.has_adapter(method) {
            return AdapterState::Unavailable;
        }
        self.states.get(&method).copied().unwrap_or_default()
    }

    /// Whether this computer accepts nearby connections (`false` where the firewall admits no listener).
    pub fn listening(&self) -> bool {
        self.adapters.iter().all(|a| a.listening())
    }

    pub fn working_since(&self) -> Option<f64> {
        self.working_since
    }

    fn next_dial_id(&mut self) -> u64 {
        self.next_dial += 1;
        self.next_dial
    }
}

impl State {
    /// After the store opened: the adapters the person allowed at launch, the first advertisement.
    pub fn start_nearby(&mut self) {
        self.rebuild_matcher();
        self.refresh_advertisement();
        let asked = self.store.nearby_permissions_requested();
        for index in 0..self.nearby.adapters.len() {
            // Desktop LAN discovery has no permission to read; browsing is the ask (the firewall's included).
            if start_adapter_at_launch(self.nearby.adapters[index].permission(), asked) {
                self.start_adapter(index);
            }
        }
        self.schedule_reconsider();
    }

    fn start_adapter(&mut self, index: usize) {
        let adapter = &mut self.nearby.adapters[index];
        let method = adapter.method();
        if !self.nearby.started.insert(method) {
            return;
        }
        if let Some((tag, slots, public)) = &self.nearby.advertised {
            adapter.advertise(*tag, slots, *public);
        }
        adapter.start();
    }

    /// The person opened Friends, or tapped Allow or Try Again: recorded, so the next launch starts Nearby without
    /// waiting; every adapter starts, and one already started that is not asked yet, refused or unavailable starts
    /// again, which is when the system may ask again (Android, until the person refuses for good).
    pub fn activate_nearby(&mut self) {
        if !self.store.nearby_permissions_requested() {
            let _ = self.store.set_nearby_permissions_requested();
        }
        self.refresh_advertisement();
        for index in 0..self.nearby.adapters.len() {
            let method = self.nearby.adapters[index].method();
            let stuck = matches!(
                self.nearby.adapters[index].state(),
                AdapterState::NotAsked | AdapterState::Denied | AdapterState::Unavailable
            );
            if stuck && self.nearby.started.remove(&method) {
                self.nearby.adapters[index].stop();
            }
            self.start_adapter(index);
        }
        self.schedule_reconsider();
        self.changed();
    }

    /// Exit or handover: nothing more is advertised, dialed or accepted.
    pub fn stop_nearby(&mut self) {
        self.nearby.shut_down = true;
        for adapter in &mut self.nearby.adapters {
            adapter.stop();
        }
        self.nearby.started.clear();
        self.nearby.merger.clear();
    }

    /// Sleep is near: what was seen before lingers through its grace; after wake everything is looked for again.
    pub fn restart_nearby_after_wake(&mut self) {
        let _ = self.nearby.visibility.is_visible(Instant::now());
        if self.nearby.visibility.deadline().is_none() {
            let _ = self.store.set_visibility_deadline(None);
        }
        self.rebuild_matcher();
        self.refresh_advertisement();
        let started: Vec<usize> = (0..self.nearby.adapters.len())
            .filter(|i| self.nearby.started.contains(&self.nearby.adapters[*i].method()))
            .collect();
        for index in started {
            let adapter = &mut self.nearby.adapters[index];
            adapter.stop();
            adapter.start();
        }
        self.schedule_reconsider();
        self.changed();
    }

    /// One adapter event, on the service's thread.
    pub fn nearby_event(&mut self, event: Event) {
        if self.nearby.shut_down {
            return;
        }
        match event {
            Event::State(method, state) => {
                self.nearby.states.insert(method, state);
                let working = self.nearby.states.values().any(|s| *s == AdapterState::Working);
                if working && self.nearby.working_since.is_none() {
                    self.nearby.working_since = Some(unix_now());
                } else if !working {
                    self.nearby.working_since = None;
                }
                self.changed();
            }
            Event::Browse(browse) => {
                let mut produced = Vec::new();
                for adapter in self.nearby.adapters.iter_mut().filter(|a| a.method() == Method::Network) {
                    produced.extend(adapter.browse_event(browse.clone()));
                }
                for event in produced {
                    self.nearby_event(event);
                }
            }
            Event::Radio(report) => {
                let adapter = self.nearby.adapters.iter_mut().find(|a| a.method() == Method::Bluetooth);
                let produced = adapter.map(|a| a.radio_event(report)).unwrap_or_default();
                for event in produced {
                    self.nearby_event(event);
                }
            }
            Event::Sighted(sighting) => {
                self.nearby.merger.add_sighting(sighting);
                self.candidates_changed();
            }
            Event::Lost(method, endpoint) => {
                self.nearby.merger.remove_endpoint(&endpoint, method, unix_now());
                self.candidates_changed();
            }
            Event::Accepted { stream, route, public, listener, address } => {
                self.accept_stream(stream, route, public, &listener, address.as_deref());
            }
            Event::Dialed { dial, stream } => self.dialed(dial, stream),
        }
    }

    fn candidates_changed(&mut self) {
        self.schedule_reconsider();
        self.changed();
    }

    /// Tags we recognise: friends' presence secrets and Add by ID requesters' callback secrets; never removed or
    /// blocked people. Rebuilt every window and every change to those secrets.
    pub fn rebuild_matcher(&mut self) {
        let people = self.store.people_by_latest_interaction().unwrap_or_default();
        let mut secrets: Vec<(String, Vec<u8>)> = Vec::new();
        for person in people.iter().filter(|p| !matches!(p.relation, Relation::Blocked | Relation::Removed)) {
            if let Some(secret) = person.presence_secret.filter(|_| person.relation == Relation::Friend) {
                secrets.push((person.conversation_id.clone(), secret.to_vec()));
            }
            if let Some(secret) = person.callback_secret {
                secrets.push((person.conversation_id.clone(), secret.to_vec()));
            }
        }
        // Our other devices, as "dev-<key>" (own.rs); friends' other computers; computers we removed.
        secrets.extend(self.own_device_tag_secrets());
        secrets.extend(self.friend_device_tag_secrets());
        secrets.extend(self.removed_device_tag_secrets());
        let pairs = secrets.iter().map(|(c, s)| (c.as_str(), s.as_slice()));
        self.nearby.merger.set_matcher(TagMatcher::new(pairs, unix_now()));
        self.refresh_policy();
        self.schedule_reconsider();
        self.changed();
    }

    /// The key policy's view of the store, kept current: who may open a session to us.
    pub fn refresh_policy(&mut self) {
        let mut fresh = policy::PolicyView::read(&self.store, self.identity.public_key());
        fresh.own_devices = self.devices.engine.other_device_keys(&self.store).into_iter().collect();
        fresh.own_removed = self.own_removed_devices().into_iter().collect();
        for (device, root) in self.friend_device_keys() {
            // A friend's other computer is that friend to the policy.
            if let Some(person) = fresh.people.get(&root).cloned() {
                fresh.people.insert(device, person);
            }
        }
        let mut view = self.nearby.policy.lock().unwrap_or_else(|e| e.into_inner());
        fresh.strangers = std::mem::take(&mut view.strangers);
        fresh.make_room = view.make_room;
        fresh.closed = self.nearby.shut_down;
        *view = fresh;
    }

    /// Our tag for this window, the callback slots and the public entry, to every adapter.
    pub fn refresh_advertisement(&mut self) {
        if self.nearby.shut_down {
            return;
        }
        let now = unix_now();
        let tag =
            self.store.own_presence_secret().map(|secret| szfriends_core::crypto::presence::tag(&secret, window(now)));
        // One of several devices of this profile, not the first: friends find it by a tag of its own (own.rs).
        let tag = self.own_friend_presence_tag(now).or(tag);
        let pending = self.advertised_callbacks(now);
        // Our other devices find this one by a tag only they can match; it takes the first callback slot.
        let mut callbacks: Vec<Tag> = self.own_device_tag(now).into_iter().collect();
        callbacks.extend(szfriends_core::nearby::callbacks::tags_to_advertise(&pending, now));
        self.nearby.callback_refresh_at = szfriends_core::nearby::callbacks::next_change(&pending, now);
        let rotation = tag.map_or_else(|| window(now).to_be_bytes().to_vec(), |t| t.to_vec());
        let slots = self.nearby.slots.slots(&callbacks, &rotation);
        let public = self.nearby.visibility.is_visible(Instant::now()) && self.nearby.listening();
        let advertisement = (tag, slots, public);
        if self.nearby.advertised.as_ref() == Some(&advertisement) {
            return;
        }
        for adapter in &mut self.nearby.adapters {
            adapter.advertise(advertisement.0, &advertisement.1, advertisement.2);
        }
        self.nearby.advertised = Some(advertisement);
    }

    /// start_visibility: the deadline, never extended, stored and advertised at once.
    pub fn start_visibility(&mut self) -> f64 {
        let deadline = self.nearby.visibility.start(Instant::now());
        let _ = self.store.set_visibility_deadline(Some(deadline));
        self.refresh_advertisement();
        self.changed();
        self.store.visibility_deadline().unwrap_or(deadline)
    }

    pub fn stop_visibility(&mut self) {
        self.nearby.visibility.stop();
        let _ = self.store.set_visibility_deadline(None);
        self.refresh_advertisement();
        self.changed();
    }

    /// Relations, secrets or Add by ID requests changed: tags, advertisement, sessions, dials and whom online may
    /// reach follow.
    pub fn people_changed(&mut self) {
        self.rebuild_matcher();
        self.refresh_advertisement();
        self.close_links_people_left();
        let conversations: Vec<String> = self.sessions.adopted_conversations();
        for conversation in conversations {
            self.deliver_to(&conversation);
        }
        self.schedule_reconsider();
        self.reach_online();
        self.changed();
    }

    /// Asks for one pass over every candidate soon (coalesced).
    pub fn schedule_reconsider(&mut self) {
        self.schedule_reconsider_after(0.0);
    }

    pub fn schedule_reconsider_after(&mut self, delay: f64) {
        let at = unix_now() + delay.max(0.0);
        self.nearby.reconsider_at = Some(self.nearby.reconsider_at.map_or(at, |due| due.min(at)));
    }

    /// Periodic nearby work, on every tick of the service's loop.
    pub fn nearby_tick(&mut self) {
        if self.nearby.shut_down {
            return;
        }
        let now = unix_now();
        for adapter in &mut self.nearby.adapters {
            adapter.tick();
        }
        if self.nearby.merger.next_expiry().is_some_and(|at| at <= now) && self.nearby.merger.expire(now) {
            self.candidates_changed();
        }
        let current = window(now);
        if current != self.nearby.window {
            self.window_ended(current);
        }
        if self.nearby.visibility.deadline().is_some() && !self.nearby.visibility.is_visible(Instant::now()) {
            // The deadline stops the public entry on every adapter at once.
            let _ = self.store.set_visibility_deadline(None);
            self.refresh_advertisement();
            self.changed();
        }
        if self.nearby.callback_refresh_at.is_some_and(|at| at <= now) {
            self.refresh_advertisement();
        }
        if now >= self.nearby.expire_at {
            self.nearby.expire_at = now + EXPIRE_REQUESTS_EVERY;
            self.expire_requests(now);
        }
        self.enforce_limits(now);
        self.start_staged_dials(now);
        if self.nearby.reconsider_at.is_some_and(|at| at <= now) {
            self.nearby.reconsider_at = None;
            self.reconsider();
        }
    }

    fn window_ended(&mut self, current: i64) {
        self.nearby.window = current;
        self.rebuild_matcher();
        self.refresh_advertisement();
        let now = unix_now();
        self.nearby.attempts.retain(|_, until| *until >= now);
        // What strangers' public entries said is kept only while the merger still knows them.
        let present: HashSet<[u8; 32]> =
            self.nearby.merger.candidates().iter().filter_map(|c| c.identity_key).collect();
        self.nearby.public_profiles.retain(|key, _| present.contains(key));
    }

    fn expire_requests(&mut self, now: f64) {
        let incoming = self.store.expire_incoming_requests(now).unwrap_or_default();
        let outgoing = self.store.expire_outgoing_requests(now).unwrap_or_default();
        if !incoming.is_empty() || !outgoing.is_empty() {
            self.people_changed();
        }
    }

    /// The next moment nearby has something to do.
    pub fn nearby_wakeup(&self) -> Option<f64> {
        let staged = self.nearby.staged.iter().map(|(due, _)| *due).min_by(f64::total_cmp);
        [self.nearby.reconsider_at, staged, self.nearby.merger.next_expiry()]
            .into_iter()
            .flatten()
            .min_by(f64::total_cmp)
    }
}

/// How the service's input wraps adapter events.
pub(crate) fn sink(input: std::sync::mpsc::Sender<Input>) -> Arc<crate::nearby::Sink> {
    let input = Mutex::new(input);
    Arc::new(Box::new(move |event: Event| {
        let _ = input.lock().unwrap_or_else(|e| e.into_inner()).send(Input::Nearby(event));
    }))
}
