//! Route racing (`SZFriendsRouteRacer.m`, ADR 0004 § Route racing): every sighted endpoint of a friend dialed at once
//! with IK, staggered toward the better routes, and a backoff per person, method and tag after a failed handshake, so
//! a device re-advertising someone's captured tag draws each friend's dial rarely. Pure; the clock is an argument.
//! Peer-to-peer Wi-Fi is dialed only where it keeps the device's Wi-Fi connection ([`super::p2p_wifi`]).

use std::collections::HashMap;

use super::callbacks::TagMatcher;
use super::merger::{matched_tag, Candidate};
use super::p2p_wifi::{p2p_wifi_usable, P2pWifi};
use super::{is_better, Method, RouteMethod, Sighting, Tag};

pub const DIAL_DELAY_LAN: f64 = 0.0;
pub const DIAL_DELAY_P2P_WIFI: f64 = 0.15;
pub const DIAL_DELAY_INTERNET: f64 = 0.3;
pub const DIAL_DELAY_BLUETOOTH: f64 = 0.5;
/// ADR 0011's plain-check budget: the relay is never dialed from a sighting before it.
pub const DIAL_DELAY_RELAY: f64 = 5.0;
pub const ENDPOINT_BACKOFF_FIRST_SECONDS: f64 = 2.0;
/// One window, after which tags have rotated.
pub const ENDPOINT_BACKOFF_MAX_SECONDS: f64 = 900.0;
const BACKOFF_ENTRIES_MAX: usize = 1024;

/// The stagger an attempt on `route` waits; None and unknown routes wait like the relay.
pub fn dial_delay(route: RouteMethod) -> f64 {
    match route {
        RouteMethod::Lan => DIAL_DELAY_LAN,
        RouteMethod::PeerToPeerWifi => DIAL_DELAY_P2P_WIFI,
        RouteMethod::Internet => DIAL_DELAY_INTERNET,
        RouteMethod::Bluetooth => DIAL_DELAY_BLUETOOTH,
        RouteMethod::Relay | RouteMethod::None => DIAL_DELAY_RELAY,
    }
}

/// One connection attempt the racer wants made.
#[derive(Clone, Debug, PartialEq)]
pub struct Attempt {
    pub sighting: Sighting,
    pub delay: f64,
}

/// What to do with a handshake that completed while another session may carry the conversation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// The first: carry traffic on it now.
    Adopt,
    /// Faster than the current session: move traffic, close the old one.
    Upgrade,
    /// Slower or a duplicate.
    Close,
}

#[derive(Clone, Copy, Debug)]
struct Backoff {
    failures: u32,
    until: f64,
}

impl Backoff {
    fn stale(&self, now: f64) -> bool {
        self.until + ENDPOINT_BACKOFF_MAX_SECONDS <= now
    }
}

/// See the module documentation.
#[derive(Debug, Default)]
pub struct Racer {
    backoffs: HashMap<String, Backoff>,
    /// method/endpoint → the tag it showed when last handed out, for the failure report naming only the endpoint.
    endpoint_tags: HashMap<String, Tag>,
    /// The platform's answer unless a probe or a test sets another.
    p2p_wifi: P2pWifi,
}

fn endpoint_key(method: Method, endpoint: &str) -> String {
    format!("{}/{endpoint}", method as u8)
}

fn backoff_key(conversation: &str, method: Method, endpoint: &str, tag: Option<&Tag>) -> String {
    let what = match tag {
        Some(tag) => format!("tag:{}", hex::encode(tag)),
        None => format!("endpoint:{endpoint}"),
    };
    format!("{conversation}|{}|{what}", method as u8)
}

impl Racer {
    /// What peer-to-peer Wi-Fi does to this device's Wi-Fi connection; unless it keeps it, those sightings are not
    /// dialed and the next route in the owner's order carries the session.
    pub fn set_p2p_wifi(&mut self, capability: P2pWifi) {
        self.p2p_wifi = capability;
    }

    pub fn p2p_wifi(&self) -> P2pWifi {
        self.p2p_wifi
    }

    fn key_for(&self, endpoint: &str, method: Method, conversation: &str) -> String {
        backoff_key(conversation, method, endpoint, self.endpoint_tags.get(&endpoint_key(method, endpoint)))
    }

    fn backing_off(&self, key: &str, now: f64) -> bool {
        self.backoffs.get(key).is_some_and(|b| b.until > now)
    }

    /// Every endpoint of the candidate, staggered shortest delay first. A friend's public entries are skipped while a
    /// hidden one is known: IK belongs on the hidden listener. Endpoints backing off for this person are left out, and
    /// so are peer-to-peer Wi-Fi ones where that route would cost the device its Wi-Fi connection.
    pub fn attempts(&mut self, candidate: &Candidate, matcher: &TagMatcher, now: f64) -> Vec<Attempt> {
        let has_hidden = candidate.sightings.iter().any(|s| !s.public);
        let skip_public = candidate.conversation_id.is_some() && has_hidden;
        let skip_p2p = !p2p_wifi_usable(self.p2p_wifi);
        let mut seen = Vec::new();
        let mut attempts = Vec::new();
        for sighting in &candidate.sightings {
            if skip_public && sighting.public {
                continue;
            }
            if skip_p2p && sighting.route == RouteMethod::PeerToPeerWifi {
                continue;
            }
            let endpoint = endpoint_key(sighting.method, &sighting.endpoint);
            if let Some(conversation) = candidate.conversation_id.as_deref() {
                let tag = matched_tag(sighting, matcher, conversation);
                let key = backoff_key(conversation, sighting.method, &sighting.endpoint, tag.as_ref());
                if self.backing_off(&key, now) {
                    continue;
                }
                if self.endpoint_tags.len() >= BACKOFF_ENTRIES_MAX && !self.endpoint_tags.contains_key(&endpoint) {
                    self.endpoint_tags.clear();
                }
                match tag {
                    Some(tag) => self.endpoint_tags.insert(endpoint.clone(), tag),
                    None => self.endpoint_tags.remove(&endpoint),
                };
            }
            if seen.contains(&endpoint) {
                continue;
            }
            seen.push(endpoint);
            attempts.push(Attempt { sighting: sighting.clone(), delay: dial_delay(sighting.route) });
        }
        attempts.sort_by(|a, b| a.delay.total_cmp(&b.delay)); // stable: equal delays keep best-route-first
        attempts
    }

    /// A handshake for a person failed at an endpoint: its tag's backoff starts or doubles.
    pub fn note_failed(&mut self, endpoint: &str, method: Method, conversation: &str, now: f64) {
        let key = self.key_for(endpoint, method, conversation);
        let mut backoff = match self.backoffs.get(&key) {
            Some(b) if !b.stale(now) => *b,
            _ => Backoff { failures: 0, until: now },
        };
        backoff.failures += 1;
        let delay = (ENDPOINT_BACKOFF_FIRST_SECONDS * 2f64.powi((backoff.failures - 1).min(20) as i32))
            .min(ENDPOINT_BACKOFF_MAX_SECONDS);
        backoff.until = now + delay;
        self.backoffs.insert(key, backoff);
        if self.backoffs.len() > BACKOFF_ENTRIES_MAX {
            self.prune(now);
        }
    }

    /// A session went live there: its backoff ends.
    pub fn note_succeeded(&mut self, endpoint: &str, method: Method, conversation: &str) {
        let key = self.key_for(endpoint, method, conversation);
        self.backoffs.remove(&key);
    }

    fn prune(&mut self, now: f64) {
        self.backoffs.retain(|_, b| !b.stale(now));
        if self.backoffs.len() <= BACKOFF_ENTRIES_MAX {
            return;
        }
        let mut by_end: Vec<(String, f64)> = self.backoffs.iter().map(|(k, b)| (k.clone(), b.until)).collect();
        by_end.sort_by(|a, b| a.1.total_cmp(&b.1));
        for (key, _) in by_end.iter().take(by_end.len() - BACKOFF_ENTRIES_MAX) {
            self.backoffs.remove(key);
        }
    }

    /// When the earliest running backoff ends.
    pub fn next_backoff_end(&self, now: f64) -> Option<f64> {
        self.backoffs.values().map(|b| b.until).filter(|until| *until > now).min_by(f64::total_cmp)
    }
}

/// When an attempt's delay has passed: start it only while no session exists or it ranks before `current`.
pub fn should_start(attempt: &Attempt, current: RouteMethod) -> bool {
    current == RouteMethod::None || is_better(attempt.sighting.route, current)
}

/// A handshake completed on `route` while `current` carries the session.
pub fn decision(route: RouteMethod, current: RouteMethod) -> Decision {
    if current == RouteMethod::None {
        Decision::Adopt
    } else if route != RouteMethod::None && is_better(route, current) {
        Decision::Upgrade
    } else {
        Decision::Close
    }
}
