//! What a listener lets in before a session authenticates (`SZFriendsAdmission.m`; ADR 0001 review item 4, ADR 0004
//! Review amendments, 10 and 14). Pure: connections are ids, times are arguments, and the caller closes what this
//! says to close.
//!
//! Every accepted connection holds a place, per listener and per remote address (an IPv4 address or an IPv6 /64,
//! [`super::txt::admission_key`]), from accept until its responder knows who the initiator is or it closes. Places are
//! never refused, only taken back: a newcomer where a limit is reached closes the oldest connection holding a place
//! there, so a host keeping the places full with silent connections cannot cut friends off; and a connection with no
//! complete message 1 two seconds after accept is closed. Rates count handshakes per minute once the preamble names
//! the pattern, per listener and per address; a full rate refuses like the key policy.

use std::collections::{HashMap, VecDeque};

use szfriends_wire::Pattern;

pub const PENDING_PER_LISTENER_MAX: usize = 32;
pub const PENDING_PER_ADDRESS_MAX: usize = 4;
pub const FIRST_MESSAGE_SECONDS: f64 = 2.0;
const RATE_WINDOW_SECONDS: f64 = 60.0;
const RATE_KEYS_BEFORE_SWEEP: usize = 4096;

/// The numbers (`SZFriendsAdmissionLimits`); 0 means no limit.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Limits {
    pub pending_per_listener: usize,
    pub pending_per_address: usize,
    pub first_message_seconds: f64,
    pub xx_per_minute_per_listener: usize,
    pub xx_per_minute_per_address: usize,
    pub ik_per_minute_per_listener: usize,
    pub ik_per_minute_per_address: usize,
    pub nn_per_minute_per_listener: usize,
    pub nn_per_minute_per_address: usize,
}

impl Default for Limits {
    /// The caps and deadline, and no rates.
    fn default() -> Self {
        Self {
            pending_per_listener: PENDING_PER_LISTENER_MAX,
            pending_per_address: PENDING_PER_ADDRESS_MAX,
            first_message_seconds: FIRST_MESSAGE_SECONDS,
            xx_per_minute_per_listener: 0,
            xx_per_minute_per_address: 0,
            ik_per_minute_per_listener: 0,
            ik_per_minute_per_address: 0,
            nn_per_minute_per_listener: 0,
            nn_per_minute_per_address: 0,
        }
    }
}

impl Limits {
    /// The helper's numbers (`SZFriendsNearbyAdmissionLimits`): XX on the public entry 20 a minute and 3 per
    /// address, NN 60 a minute and 6 per address; IK unlimited (friends dial it; replays are refused anyway).
    pub fn nearby() -> Self {
        Self {
            xx_per_minute_per_listener: 20,
            xx_per_minute_per_address: 3,
            nn_per_minute_per_listener: 60,
            nn_per_minute_per_address: 6,
            ..Self::default()
        }
    }

    fn per_minute(&self, pattern: Pattern) -> (usize, usize) {
        match pattern {
            Pattern::XX => (self.xx_per_minute_per_listener, self.xx_per_minute_per_address),
            Pattern::IK => (self.ik_per_minute_per_listener, self.ik_per_minute_per_address),
            Pattern::NN => (self.nn_per_minute_per_listener, self.nn_per_minute_per_address),
        }
    }
}

#[derive(Clone, Debug)]
struct Place {
    connection: u64,
    listener: String,
    address: Option<String>,
    accepted_at: f64,
    first_message: bool,
    asked: bool,
}

/// See the module documentation.
#[derive(Debug, Default)]
pub struct Admission {
    limits: Limits,
    /// Oldest first.
    places: Vec<Place>,
    rates: HashMap<String, VecDeque<f64>>,
}

fn full(count: usize, limit: usize) -> bool {
    limit > 0 && count >= limit
}

impl Admission {
    pub fn new(limits: Limits) -> Self {
        Self { limits, ..Self::default() }
    }

    pub fn set_limits(&mut self, limits: Limits) {
        self.limits = limits;
    }

    fn take_oldest_when_full(&mut self, limit: usize, test: impl Fn(&Place) -> bool) -> Option<u64> {
        let matching: Vec<usize> = (0..self.places.len()).filter(|i| test(&self.places[*i])).collect();
        let first = *matching.first()?;
        if !full(matching.len(), limit) {
            return None;
        }
        Some(self.places.remove(first).connection)
    }

    /// A connection was accepted: it holds a place now. Returns the connections to close to make room.
    pub fn admit(&mut self, connection: u64, listener: &str, address: Option<&str>, now: f64) -> Vec<u64> {
        let mut evicted = Vec::new();
        if let Some(address) = address {
            // The address first: making room there may also make room on the listener.
            let limit = self.limits.pending_per_address;
            evicted.extend(self.take_oldest_when_full(limit, |p| p.address.as_deref() == Some(address)));
        }
        let limit = self.limits.pending_per_listener;
        evicted.extend(self.take_oldest_when_full(limit, |p| p.listener == listener));
        self.places.push(Place {
            connection,
            listener: listener.to_owned(),
            address: address.map(str::to_owned),
            accepted_at: now,
            first_message: false,
            asked: false,
        });
        evicted
    }

    /// Message 1 arrived complete: the deadline no longer applies.
    pub fn first_message(&mut self, connection: u64) {
        if let Some(place) = self.places.iter_mut().find(|p| p.connection == connection) {
            place.first_message = true;
        }
    }

    /// The responder knows who the initiator is, or the connection closed: its place is free.
    pub fn release(&mut self, connection: u64) {
        self.places.retain(|p| p.connection != connection);
    }

    /// Connections without a complete message 1 in time: their places are taken back and they are to be closed.
    pub fn overdue(&mut self, now: f64) -> Vec<u64> {
        let deadline = self.limits.first_message_seconds;
        if deadline <= 0.0 {
            return Vec::new();
        }
        let late: Vec<u64> = self
            .places
            .iter()
            .filter(|p| !p.first_message && now - p.accepted_at >= deadline)
            .map(|p| p.connection)
            .collect();
        self.places.retain(|p| !late.contains(&p.connection));
        late
    }

    /// When the next first-message deadline passes.
    pub fn next_deadline(&self) -> Option<f64> {
        let deadline = self.limits.first_message_seconds;
        (deadline > 0.0)
            .then(|| {
                self.places.iter().filter(|p| !p.first_message).map(|p| p.accepted_at + deadline).min_by(f64::total_cmp)
            })
            .flatten()
    }

    /// The preamble named the pattern: `false` refuses it. One question per connection.
    pub fn admit_pattern(&mut self, connection: u64, pattern: Pattern, now: f64) -> bool {
        let Some(place) = self.places.iter_mut().find(|p| p.connection == connection) else {
            return true; // released already (a friend authenticated): nothing counts it
        };
        if place.asked {
            return false;
        }
        place.asked = true;
        let (listener, address) = (place.listener.clone(), place.address.clone());
        let (per_listener, per_address) = self.limits.per_minute(pattern);
        let listener_key = format!("L{}|{listener}", pattern as u8);
        let address_key = address.map(|a| format!("A{}|{a}", pattern as u8));
        let listener_count = if per_listener > 0 { self.recent(&listener_key, now) } else { 0 };
        let address_count = match (&address_key, per_address) {
            (Some(key), limit) if limit > 0 => self.recent(key, now),
            _ => 0,
        };
        if full(listener_count, per_listener) || full(address_count, per_address) {
            return false;
        }
        if per_listener > 0 {
            self.rates.entry(listener_key).or_default().push_back(now);
        }
        if let (Some(key), true) = (address_key, per_address > 0) {
            self.rates.entry(key).or_default().push_back(now);
        }
        true
    }

    fn recent(&mut self, key: &str, now: f64) -> usize {
        if !self.rates.contains_key(key) && self.rates.len() >= RATE_KEYS_BEFORE_SWEEP {
            self.rates.retain(|_, times| times.back().is_some_and(|newest| now - newest < RATE_WINDOW_SECONDS));
        }
        let times = self.rates.entry(key.to_owned()).or_default();
        while times.front().is_some_and(|t| now - t >= RATE_WINDOW_SECONDS) {
            times.pop_front();
        }
        times.len()
    }

    pub fn pending_on_listener(&self, listener: &str) -> usize {
        self.places.iter().filter(|p| p.listener == listener).count()
    }

    pub fn pending_from_address(&self, address: &str) -> usize {
        self.places.iter().filter(|p| p.address.as_deref() == Some(address)).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_newcomer_takes_the_oldest_place() {
        let mut a = Admission::new(Limits::default());
        for i in 0..4 {
            assert!(a.admit(i, "hidden", Some("4:10.0.0.9"), 0.0).is_empty());
        }
        assert_eq!(a.admit(4, "hidden", Some("4:10.0.0.9"), 0.1), vec![0], "per address");
        assert_eq!(a.pending_from_address("4:10.0.0.9"), 4);
        for i in 5..33 {
            a.admit(i, "hidden", Some(&format!("4:10.0.1.{i}")), 0.2);
        }
        assert_eq!(a.pending_on_listener("hidden"), 32);
        assert_eq!(a.admit(99, "hidden", Some("4:10.0.2.1"), 0.3), vec![1], "per listener");
        assert!(a.admit(100, "public", None, 0.3).is_empty(), "listeners count apart");
    }

    #[test]
    fn silent_connections_lose_their_place() {
        let mut a = Admission::new(Limits::default());
        a.admit(1, "hidden", None, 10.0);
        a.admit(2, "hidden", None, 10.5);
        a.first_message(2);
        assert_eq!(a.next_deadline(), Some(12.0));
        assert!(a.overdue(11.9).is_empty());
        assert_eq!(a.overdue(12.0), vec![1]);
        a.release(2);
        assert_eq!(a.pending_on_listener("hidden"), 0);
    }

    #[test]
    fn rates_per_pattern() {
        let mut a = Admission::new(Limits::nearby());
        for i in 0..6 {
            a.admit(i, "hidden", Some("4:1.2.3.4"), 0.0);
            assert!(a.admit_pattern(i, Pattern::NN, 0.0));
            a.release(i);
        }
        a.admit(7, "hidden", Some("4:1.2.3.4"), 1.0);
        assert!(!a.admit_pattern(7, Pattern::NN, 1.0), "six a minute from one address");
        a.admit(8, "hidden", Some("4:1.2.3.4"), 1.0);
        assert!(a.admit_pattern(8, Pattern::IK, 1.0), "IK unlimited");
        assert!(!a.admit_pattern(8, Pattern::IK, 1.0), "one question per connection");
        a.admit(9, "hidden", Some("4:1.2.3.4"), 61.0);
        assert!(a.admit_pattern(9, Pattern::NN, 61.0), "the minute passed");
    }
}
