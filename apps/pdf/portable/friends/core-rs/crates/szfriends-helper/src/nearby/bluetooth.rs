//! The Bluetooth adapter (`SZFriendsBluetoothAdapter.m`, ADR 0004 § Decision): advertise the Friends service, scan
//! for it, read each device's presence value, report sightings, and open or accept L2CAP channels. Radio access goes
//! through [`Radio`], so this logic runs unchanged over BlueZ (`bluez`), a phone's own Bluetooth (the app's
//! Kotlin and Swift), and the test air of test homes ([`super::test_air`]). Windows has no Bluetooth method: it offers
//! no LE L2CAP channels to apps.
//!
//! Each presence window gets its own hidden channel, and while visible its own public channel: a PSM kept across the
//! boundary would tie one window's tag to the next. A replaced channel stays published, unadvertised, for a short
//! overlap. While a new window's channels are being published the old window is served whole, so nothing of the new
//! window ever appears beside a channel of the old one.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use szfriends_core::nearby::bluetooth::{self as bt, Presence};
use szfriends_core::nearby::callbacks::window;
use szfriends_core::nearby::{AdapterState, Method, Permission, Sighting, Tag};
use szfriends_core::store::unix_now;
use szfriends_core::wire::RouteMethod;

pub use super::radio::{Power, Radio, RadioEvent, RadioReports};
use super::stream::LinkStream;
use super::{Event, Sink};

#[derive(Debug, Default)]
struct Record {
    presence: Option<Presence>,
    /// From the public characteristic only.
    public_psm: u16,
    read_at: Option<f64>,
    /// What the advertisement said when the value was read.
    read_public: bool,
    reading: bool,
    public_sighted: bool,
    last_seen: f64,
}

/// A channel and the window it was published for.
#[derive(Debug, Default)]
struct Channel {
    psm: u16,
    key: Option<Vec<u8>>,
    in_flight: bool,
    requested_for: Option<Vec<u8>>,
}

/// What reads return: one window's whole value.
#[derive(Debug, Default)]
struct Served {
    key: Option<Vec<u8>>,
    tag: Option<Tag>,
    slots: Vec<Tag>,
    hidden_psm: u16,
    public_psm: u16,
}

/// See the module documentation.
pub struct BluetoothAdapter {
    radio: Box<dyn Radio>,
    sink: Arc<Sink>,
    clock: Box<dyn Fn() -> f64 + Send>,
    running: bool,
    power: Power,
    state: AdapterState,
    hidden: Channel,
    public: Channel,
    served: Served,
    /// Replaced channels in their overlap: psm, public, until.
    retiring: Vec<(u16, bool, f64)>,
    tag: Option<Tag>,
    slots: Vec<Tag>,
    public_on: bool,
    peripherals: HashMap<String, Record>,
    read_queue: VecDeque<String>,
    reads_in_flight: usize,
    scanned_at: f64,
}

impl std::fmt::Debug for BluetoothAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BluetoothAdapter").field("running", &self.running).field("power", &self.power).finish()
    }
}

impl BluetoothAdapter {
    pub fn new(radio: Box<dyn Radio>, sink: Arc<Sink>) -> Self {
        Self::with_clock(radio, sink, Box::new(unix_now))
    }

    pub fn with_clock(radio: Box<dyn Radio>, sink: Arc<Sink>, clock: Box<dyn Fn() -> f64 + Send>) -> Self {
        Self {
            radio,
            sink,
            clock,
            running: false,
            power: Power::Unknown,
            state: AdapterState::NotAsked,
            hidden: Channel::default(),
            public: Channel::default(),
            served: Served::default(),
            retiring: Vec::new(),
            tag: None,
            slots: Vec::new(),
            public_on: false,
            peripherals: HashMap::new(),
            read_queue: VecDeque::new(),
            reads_in_flight: 0,
            scanned_at: 0.0,
        }
    }

    fn set_state(&mut self, state: AdapterState) {
        if state != self.state {
            self.state = state;
            (self.sink)(Event::State(Method::Bluetooth, state));
        }
    }

    fn forget_radio_side(&mut self) {
        self.hidden = Channel::default();
        self.public = Channel::default();
        self.served = Served::default();
        self.retiring.clear();
        self.read_queue.clear();
        self.reads_in_flight = 0;
        for record in self.peripherals.values_mut() {
            record.reading = false;
        }
    }

    /// The window the hidden entry stands for: its presence tag, or the window index without one.
    fn rotation_key(&self) -> Vec<u8> {
        match self.tag {
            Some(tag) => tag.to_vec(),
            None => window((self.clock)()).to_be_bytes().to_vec(),
        }
    }

    fn power_changed(&mut self, power: Power) {
        if !self.running || power == self.power {
            return;
        }
        self.power = power;
        match power {
            Power::On => {
                self.publish_channels();
                self.advertise_now();
                self.radio.start_scanning();
                self.scanned_at = (self.clock)();
                self.set_state(AdapterState::Working);
            }
            Power::Off | Power::Unauthorized | Power::Unsupported => {
                // Channels and advertisements do not survive the radio going away; they come back on power on.
                self.forget_radio_side();
                self.set_state(match power {
                    Power::Off => AdapterState::RadioOff,
                    // Refused, but the system may still ask (Android until the person refuses for good): Nearby
                    // keeps its Allow, which starts the adapter again and so asks again.
                    Power::Unauthorized if self.radio.permission() == Permission::NotDetermined => {
                        AdapterState::NotAsked
                    }
                    Power::Unauthorized => AdapterState::Denied,
                    _ => AdapterState::Unavailable,
                });
            }
            Power::Unknown => self.set_state(AdapterState::Starting),
        }
    }

    fn publish_channels(&mut self) {
        let key = self.rotation_key();
        let hidden = &mut self.hidden;
        if (hidden.psm == 0 || hidden.key.as_ref() != Some(&key)) && !hidden.in_flight {
            hidden.in_flight = true;
            hidden.requested_for = Some(key.clone());
            self.radio.publish_channel(false);
        }
        let public = &mut self.public;
        if self.public_on {
            if (public.psm == 0 || public.key.as_ref() != Some(&key)) && !public.in_flight {
                public.in_flight = true;
                public.requested_for = Some(key);
                self.radio.publish_channel(true);
            }
        } else {
            // The deadline closes the public door at once: the channels go, not only the advertisement.
            if public.psm != 0 {
                self.radio.unpublish_channel(public.psm);
            }
            for (psm, _, _) in self.retiring.iter().filter(|(_, public, _)| *public) {
                self.radio.unpublish_channel(*psm);
            }
            self.retiring.retain(|(_, public, _)| !public);
            self.public.psm = 0;
            self.public.key = None;
        }
    }

    fn advertise_now(&mut self) {
        let key = self.rotation_key();
        let new_window = self.served.key.as_ref() != Some(&key);
        let publishing = self.hidden.in_flight || (self.public_on && self.public.in_flight);
        let holding = new_window && self.served.key.is_some() && publishing;
        if !holding {
            self.served.key = Some(key.clone());
            self.served.tag = self.tag;
            self.served.slots = self.slots.clone();
            // Only channels published for this window: one that failed is served as none, never as the old one.
            self.served.hidden_psm = if self.hidden.key.as_ref() == Some(&key) { self.hidden.psm } else { 0 };
            self.served.public_psm = if self.public.key.as_ref() == Some(&key) { self.public.psm } else { 0 };
        }
        if !self.public_on {
            self.served.public_psm = 0;
        }
        let hidden = Presence::new(self.served.tag, &self.served.slots, self.served.hidden_psm, 0).value();
        // The public UUID goes on the air only with a channel to dial: a reader that saw it without one would cache
        // that answer for minutes.
        let public = (self.served.public_psm != 0).then(|| Presence::public(self.served.public_psm).value());
        // A new window also restarts advertising, so the advertising set is not carried across the boundary either.
        if new_window && !holding {
            self.radio.stop_advertising();
        }
        self.radio.advertise(&hidden, public.as_deref());
    }

    fn published(&mut self, psm: u16, public: bool) {
        if !self.running {
            return;
        }
        let now = (self.clock)();
        let overlap = now + bt::CHANNEL_OVERLAP_SECONDS;
        if public {
            self.public.in_flight = false;
            if !self.public_on {
                // Visibility ended while the channel was being published.
                if psm != 0 {
                    self.radio.unpublish_channel(psm);
                }
                return;
            }
            if self.public.psm != 0 && self.public.psm != psm {
                self.retiring.push((self.public.psm, true, overlap));
            }
            self.public.psm = psm;
            self.public.key = self.public.requested_for.take();
        } else {
            self.hidden.in_flight = false;
            // The old window's channel goes either way: replaced, or (publishing failed) the new window is served
            // with no channel rather than beside the old PSM; the next advertisement tries again.
            if self.hidden.psm != 0 && self.hidden.psm != psm {
                self.retiring.push((self.hidden.psm, false, overlap));
            }
            self.hidden.psm = psm;
            self.hidden.key = self.hidden.requested_for.take();
        }
        if self.power != Power::On {
            return;
        }
        // A window may have turned while this was in flight; asking again catches up before anything is served.
        if psm != 0 {
            self.publish_channels();
        }
        self.advertise_now();
    }

    fn discovered(&mut self, peripheral: String, public: bool) -> Vec<Event> {
        if !self.running {
            return Vec::new();
        }
        let now = (self.clock)();
        let record = self.peripherals.entry(peripheral.clone()).or_default();
        record.last_seen = now;
        let fresh = record.presence.is_some()
            && record.read_at.is_some_and(|at| bt::read_is_fresh(at, record.read_public, now, public));
        if fresh {
            return self.report(&peripheral);
        }
        record.read_public = public;
        if record.reading || self.read_queue.contains(&peripheral) {
            return Vec::new();
        }
        self.read_queue.push_back(peripheral);
        self.pump_reads();
        Vec::new()
    }

    fn pump_reads(&mut self) {
        while self.reads_in_flight < bt::MAX_CONCURRENT_READS {
            let Some(peripheral) = self.read_queue.pop_front() else { return };
            let Some(record) = self.peripherals.get_mut(&peripheral) else { continue };
            record.reading = true;
            self.reads_in_flight += 1;
            let public = record.read_public;
            self.radio.read_presence(&peripheral, public);
        }
    }

    fn read(&mut self, peripheral: String, value: Option<Vec<u8>>, public_value: Option<Vec<u8>>) -> Vec<Event> {
        if !self.running {
            return Vec::new();
        }
        let now = (self.clock)();
        let mut events = Vec::new();
        if let Some(record) = self.peripherals.get_mut(&peripheral) {
            if record.reading {
                record.reading = false;
                self.reads_in_flight = self.reads_in_flight.saturating_sub(1);
            }
            if let Some(presence) = value.as_deref().and_then(Presence::from_value) {
                record.presence = Some(presence);
                // Each field from the characteristic that owns it: a public PSM in the hidden value is not one.
                record.public_psm = public_value.as_deref().and_then(Presence::from_value).map_or(0, |p| p.public_psm);
                record.read_at = Some(now);
                events = self.report(&peripheral);
            }
        }
        self.pump_reads();
        events
    }

    fn report(&mut self, peripheral: &str) -> Vec<Event> {
        let Some(record) = self.peripherals.get_mut(peripheral) else { return Vec::new() };
        let Some(presence) = &record.presence else { return Vec::new() };
        let sighting = |endpoint: String, tag: Option<Tag>, callbacks: Vec<Tag>, public: bool| Sighting {
            method: Method::Bluetooth,
            route: RouteMethod::Bluetooth,
            endpoint,
            presence_tag: tag,
            callback_tags: callbacks,
            public,
            seen_at: record.last_seen,
        };
        let hidden = bt::endpoint(peripheral, false);
        let mut events = vec![Event::Sighted(sighting(hidden, presence.tag, presence.callback_tags.clone(), false))];
        let public = bt::endpoint(peripheral, true);
        if record.public_psm != 0 {
            // The public entry is its own endpoint with no tag, as on the network: who it is comes only from the
            // handshake's profile.
            events.push(Event::Sighted(sighting(public, None, Vec::new(), true)));
            record.public_sighted = true;
        } else if record.public_sighted {
            record.public_sighted = false;
            events.push(Event::Lost(Method::Bluetooth, public));
        }
        events
    }

    fn accepted(&mut self, stream: LinkStream, public: bool, peer: Option<String>) -> Vec<Event> {
        if !self.running {
            close(stream);
            return Vec::new();
        }
        let listener = if public { "bluetooth public" } else { "bluetooth hidden" }.to_owned();
        vec![Event::Accepted { stream, route: RouteMethod::Bluetooth, public, listener, address: peer }]
    }
}

/// Says the end to whoever holds the other side.
fn close(stream: LinkStream) {
    if let LinkStream::Platform(mut stream) = stream {
        (stream.outgoing)(None);
    }
}

impl super::Adapter for BluetoothAdapter {
    fn method(&self) -> Method {
        Method::Bluetooth
    }

    fn state(&self) -> AdapterState {
        self.state
    }

    fn permission(&self) -> Permission {
        self.radio.permission()
    }

    fn start(&mut self) {
        if self.running {
            return;
        }
        self.running = true;
        self.power = Power::Unknown;
        self.set_state(AdapterState::Starting);
        // Even when access was denied: that does not prompt, and the radio tells us when access comes back.
        self.radio.power_up(RadioReports::new(self.sink.clone()));
    }

    fn stop(&mut self) {
        if !self.running {
            return;
        }
        self.running = false;
        self.radio.power_down();
        self.forget_radio_side();
        self.peripherals.clear();
        self.power = Power::Unknown;
        self.set_state(AdapterState::NotAsked);
    }

    fn advertise(&mut self, tag: Option<Tag>, slots: &[Tag], public: bool) {
        self.tag = tag;
        self.slots = slots.to_vec();
        self.public_on = public;
        if self.running && self.power == Power::On {
            self.publish_channels();
            self.advertise_now();
        }
    }

    fn browse_event(&mut self, _event: super::dnssd::BrowseEvent) -> Vec<Event> {
        Vec::new()
    }

    fn radio_event(&mut self, event: RadioEvent) -> Vec<Event> {
        match event {
            RadioEvent::Power(power) => {
                self.power_changed(power);
                Vec::new()
            }
            RadioEvent::Discovered { peripheral, public } => self.discovered(peripheral, public),
            RadioEvent::Read { peripheral, value, public_value } => self.read(peripheral, value, public_value),
            RadioEvent::Published { psm, public } => {
                self.published(psm, public);
                Vec::new()
            }
            RadioEvent::Accepted { stream, public, peer } => self.accepted(stream, public, peer),
        }
    }

    fn dial(&mut self, endpoint: &str, dial: u64) -> bool {
        let Some((peripheral, public)) = bt::parse_endpoint(endpoint) else { return false };
        let Some(record) = self.peripherals.get(peripheral) else { return false };
        let Some(presence) = &record.presence else { return false };
        let psm = if public { record.public_psm } else { presence.hidden_psm };
        if !self.running || self.power != Power::On || psm == 0 {
            return false;
        }
        self.radio.open_channel(peripheral, psm, dial);
        true
    }

    fn refresh(&mut self) {
        if self.running && self.power == Power::On {
            // With duplicates off a running scan reports each device once; a fresh scan reports it again.
            self.radio.stop_scanning();
            self.radio.start_scanning();
            self.scanned_at = (self.clock)();
        }
    }

    fn tick(&mut self) {
        if !self.running || self.power != Power::On {
            return;
        }
        let now = (self.clock)();
        let (due, kept): (Vec<_>, Vec<_>) = self.retiring.drain(..).partition(|(_, _, until)| *until <= now);
        self.retiring = kept;
        for (psm, _, _) in due {
            self.radio.unpublish_channel(psm);
        }
        // A new window needs new channels even when nothing else changed the advertisement.
        let settled = !self.hidden.in_flight && !self.public.in_flight;
        if settled && self.served.key.as_ref() != Some(&self.rotation_key()) {
            self.publish_channels();
            self.advertise_now();
        }
        if now - self.scanned_at >= bt::SCAN_REFRESH_SECONDS {
            self.refresh();
        }
    }
}

#[cfg(test)]
#[path = "bluetooth_tests.rs"]
mod tests;
