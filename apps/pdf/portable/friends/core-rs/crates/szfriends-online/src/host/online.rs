//! The check-in client's online side (HOST-PROTOCOL-ONLINE.md; `SZFriendsHostRendezvous.m`,
//! `SZFriendsHostSignaling.m`): whether the connection takes online messages, this device's rendezvous record once
//! per host period, lookups, sids opened and received, their payloads and ends, relay credentials, and download
//! links' registrations. A target that does not answer is never reported: nothing here waits for one.

use std::collections::HashMap;

use serde_json::{json, Map, Value};

use super::client::{HostClient, HostOutcome, Via};
use super::codec::{record_message, RECORD_DOMAIN};
use crate::b64;
use crate::signal::record::{rendezvous_key, SEALED_LENGTH};
use crate::transport::RelayCredentials;

pub const PAYLOAD_MAX: usize = 4096;
pub const MESSAGES_PER_SID: usize = 64;
pub const RECORD_PERIOD: f64 = 60.0;
pub const RECORD_LIFETIME: i64 = 300;
pub const REQUEST_TIMEOUT: f64 = 10.0;
const LOOKUP_KEYS_MAX: usize = 32;

/// A request the host has not answered yet.
#[derive(Debug, Clone)]
pub enum Pending {
    Open { token: u64, deadline: f64 },
    Relay { token: u64, deadline: f64 },
    Lookup { token: u64, deadline: f64 },
}

impl Pending {
    fn deadline(&self) -> f64 {
        match self {
            Self::Open { deadline, .. } | Self::Relay { deadline, .. } | Self::Lookup { deadline, .. } => *deadline,
        }
    }
}

#[derive(Debug)]
pub(super) struct Sid {
    sent: usize,
}

#[derive(Debug, Default)]
pub struct OnlineState {
    pub available: bool,
    host_id: Option<String>,
    relay_uris: Vec<String>,
    pub(super) pending: HashMap<i64, Pending>,
    sids: HashMap<String, Sid>,
    next_req: i64,
    seq: u64,
    publish_at: Option<f64>,
}

impl OnlineState {
    pub fn next_deadline(&self) -> f64 {
        let pending = self.pending.values().map(Pending::deadline).fold(f64::INFINITY, f64::min);
        pending.min(self.publish_at.unwrap_or(f64::INFINITY))
    }
}

fn wall() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

fn fields(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

fn parse_time(text: &str) -> Option<f64> {
    // RFC 3339 UTC: YYYY-MM-DDTHH:MM:SS[.fff]Z, as the host writes its challenge's time.
    let b = text.as_bytes();
    if b.len() < 20 || !text.ends_with('Z') || b[10] != b'T' {
        return None;
    }
    let n = |r: std::ops::Range<usize>| text.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, s) = (n(0..4)?, n(5..7)?, n(8..10)?, n(11..13)?, n(14..16)?, n(17..19)?);
    let fraction = text
        .get(19..text.len() - 1)
        .and_then(|f| f.strip_prefix('.'))
        .map_or(0.0, |f| format!("0.{f}").parse::<f64>().unwrap_or(0.0));
    // Days from the civil date (Howard Hinnant's algorithm).
    let (y, m) = if mo <= 2 { (y - 1, mo + 9) } else { (y, mo - 3) };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some((days * 86400 + h * 3600 + mi * 60 + s) as f64 + fraction)
}

impl HostClient {
    /// Seconds on the host's clock, as its challenge gave it.
    pub fn host_now(&self) -> f64 {
        wall() + self.skew
    }

    pub(super) fn online_challenge(&mut self, message: &Value) {
        let host_time = message.get("time").and_then(Value::as_str).and_then(parse_time);
        let skew = host_time.map_or(0.0, |t| t - wall());
        self.skew = if skew.abs() < 86400.0 { skew } else { 0.0 };
    }

    pub(super) fn online_checked_in(&mut self) {
        if self.online.available {
            return;
        }
        let Some(entry) = self.connected_entry().cloned() else { return };
        let (mut own, mut others) = (Vec::new(), Vec::new());
        for host in self.list.entries.iter().filter(|h| h.relay) {
            for uri in host.turn_uris.iter().filter(|u| u.starts_with("turn:")) {
                if host.id == entry.id {
                    own.push(uri.clone())
                } else {
                    others.push(uri.clone())
                }
            }
        }
        self.online.relay_uris = if own.is_empty() { others } else { own };
        self.online.host_id = Some(entry.id.clone());
        self.online.available = true;
        self.outcomes.push(HostOutcome::Available(true));
        self.online.publish_at = Some(self.now());
    }

    /// The connected host's id while online messages may be sent.
    pub fn host_id(&self) -> Option<&str> {
        self.online.host_id.as_deref().filter(|_| self.online.available)
    }

    /// The STUN URIs of the connected host's entry in the signed list (never the host's answer).
    pub fn stun_uris(&self) -> Vec<String> {
        let Some(id) = self.host_id() else { return Vec::new() };
        let entry = self.list.entries.iter().find(|e| e.id == id);
        entry.map(|e| e.turn_uris.iter().filter(|u| u.starts_with("stun:")).cloned().collect()).unwrap_or_default()
    }

    pub(super) fn connection_closed_online(&mut self) {
        let was = self.online.available;
        let pending: Vec<Pending> = self.online.pending.drain().map(|(_, p)| p).collect();
        for pending in pending {
            self.fail_pending(pending);
        }
        for sid in std::mem::take(&mut self.online.sids).into_keys() {
            self.outcomes.push(HostOutcome::SidEnded { sid });
        }
        self.online.available = false;
        self.online.host_id = None;
        self.online.publish_at = None;
        if was {
            self.outcomes.push(HostOutcome::Available(false));
        }
    }

    fn fail_pending(&mut self, pending: Pending) {
        self.outcomes.push(match pending {
            Pending::Open { token, .. } => {
                HostOutcome::Opened { token, sid: None, owner_online: false, link_ended: None }
            }
            Pending::Relay { token, .. } => HostOutcome::Relay { token, credentials: None },
            Pending::Lookup { token, .. } => HostOutcome::Records { token, blobs: None },
        });
    }

    fn add_pending(&mut self, pending: Pending) -> i64 {
        self.online.next_req += 1;
        let req = self.online.next_req;
        self.online.pending.insert(req, pending);
        req
    }

    fn take_pending(&mut self, message: &Value) -> Option<Pending> {
        let req = message.get("req").and_then(Value::as_i64)?;
        self.online.pending.remove(&req)
    }

    pub(super) fn tick_online(&mut self, now: f64) {
        let expired: Vec<i64> =
            self.online.pending.iter().filter(|(_, p)| p.deadline() <= now).map(|(req, _)| *req).collect();
        for req in expired {
            if let Some(pending) = self.online.pending.remove(&req) {
                self.fail_pending(pending);
            }
        }
        if self.online.available && self.online.publish_at.is_some_and(|at| at <= now) {
            // Once per period, at a random moment in the first half of the next one.
            let host_now = self.host_now();
            let next_period = ((host_now / RECORD_PERIOD).floor() + 1.0) * RECORD_PERIOD;
            let mut b = [0u8; 1];
            szfriends_crypto::random_bytes(&mut b);
            let offset = 1.0 + f64::from(b[0]) / 255.0 * (RECORD_PERIOD / 2.0 - 2.0);
            self.online.publish_at = Some(now + (next_period + offset - host_now));
            self.outcomes.push(HostOutcome::PublishDue);
        }
    }

    /// Publishes this device's freshly sealed record under its person's rendezvous key.
    pub fn publish(&mut self, sealed: &[u8]) {
        let Some(host_id) = self.host_id().map(str::to_owned) else { return };
        if sealed.len() != SEALED_LENGTH {
            return;
        }
        let rdv_key = rendezvous_key(&self.person_key);
        let millis = (wall() * 1000.0) as u64;
        self.online.seq = (self.online.seq + 1).max(millis);
        let expires = self.host_now().floor() as i64 + RECORD_LIFETIME;
        let signed = record_message(&host_id, &rdv_key, self.online.seq, expires, sealed);
        let signature = self.identity.sign(&signed, RECORD_DOMAIN);
        let message = json!({
            "seq": self.online.seq, "expires": expires,
            "sealed": b64::encode_url(sealed), "sig": b64::encode_url(&signature),
        });
        self.send("rdv_publish", fields(message));
    }

    /// Rendezvous keys to 512-byte blobs (a record's or the host's filler), 32 per message; one answer per token.
    pub fn lookup(&mut self, token: u64, keys: &[[u8; 32]]) {
        if !self.online.available || keys.is_empty() || keys.len() > LOOKUP_KEYS_MAX {
            self.outcomes.push(HostOutcome::Records { token, blobs: None });
            return;
        }
        let deadline = self.now() + REQUEST_TIMEOUT;
        let req = self.add_pending(Pending::Lookup { token, deadline });
        let keys: Vec<String> = keys.iter().map(|k| b64::encode_url(k)).collect();
        self.send("rdv_lookup", fields(json!({ "req": req, "keys": keys })));
    }

    fn open_to(&mut self, token: u64, to: Value, payload: &[u8]) {
        if !self.online.available || payload.is_empty() || payload.len() > PAYLOAD_MAX {
            self.outcomes.push(HostOutcome::Opened { token, sid: None, owner_online: false, link_ended: None });
            return;
        }
        let deadline = self.now() + REQUEST_TIMEOUT;
        let req = self.add_pending(Pending::Open { token, deadline });
        self.send("sig_open", fields(json!({ "req": req, "to": to, "payload": b64::encode_url(payload) })));
    }

    pub fn open_to_rendezvous(&mut self, token: u64, rdv_key: &[u8; 32], payload: &[u8]) {
        self.open_to(token, json!({ "rdv_key": b64::encode_url(rdv_key) }), payload);
    }

    /// Add by ID online: the holder of a reserved Friends ID.
    pub fn open_to_friends_id(&mut self, token: u64, friends_id: &str, payload: &[u8]) {
        self.open_to(token, json!({ "friends_id": friends_id }), payload);
    }

    /// Protocol 3: a join request to every device of the Friends ID's holder.
    pub fn open_to_join(&mut self, token: u64, friends_id: &str, payload: &[u8]) {
        self.open_to(token, json!({ "join": friends_id }), payload);
    }

    pub fn open_to_link(&mut self, token: u64, link_id: &[u8; 16], payload: &[u8]) {
        self.open_to(token, json!({ "link_id": b64::encode_url(link_id) }), payload);
    }

    /// One payload on a sid; `false`, sending nothing, once ended, for a bad size or for the 65th.
    pub fn send_payload(&mut self, sid: &str, payload: &[u8]) -> bool {
        let ok = payload.len() <= PAYLOAD_MAX && !payload.is_empty();
        let Some(state) = self.online.sids.get_mut(sid).filter(|s| ok && s.sent < MESSAGES_PER_SID) else {
            return false;
        };
        state.sent += 1;
        self.send("sig_msg", fields(json!({ "sid": sid, "payload": b64::encode_url(payload) })))
    }

    /// Ends this side of a sid: nothing more arrives.
    pub fn close_sid(&mut self, sid: &str) {
        if self.online.sids.remove(sid).is_some() {
            self.send("sig_close", fields(json!({ "sid": sid })));
        }
    }

    /// Relay credentials for a live sid (relay_credentials for an unknown one would close the connection).
    pub fn request_relay(&mut self, token: u64, sid: &str) {
        if !self.online.available || !self.online.sids.contains_key(sid) {
            self.outcomes.push(HostOutcome::Relay { token, credentials: None });
            return;
        }
        let deadline = self.now() + REQUEST_TIMEOUT;
        let req = self.add_pending(Pending::Relay { token, deadline });
        self.send("relay_credentials", fields(json!({ "req": req, "sid": sid })));
    }

    pub fn register_link(&mut self, link_id: &[u8; 16], expires: i64) {
        if self.online.available {
            self.send("link_register", fields(json!({ "link_id": b64::encode_url(link_id), "expires": expires })));
        }
    }

    /// `link_tombstones`, at most 64 a message, each never past the host's 31 days by its own clock.
    pub fn send_link_tombstones(&mut self, tombstones: &[crate::links::Tombstone]) {
        if !self.online.available {
            return;
        }
        let (host_now, now) = (self.host_now(), wall());
        let items: Vec<Value> = tombstones
            .iter()
            .filter(|t| matches!(t.reason.as_str(), "revoked" | "expired"))
            .filter_map(|t| {
                let left = (t.until - now).min(31.0 * 86_400.0 - 300.0);
                (left > 1.0).then(|| {
                    json!({
                        "hash": b64::encode_url(&t.hash),
                        "reason": t.reason,
                        "until": (host_now + left).floor() as i64,
                    })
                })
            })
            .collect();
        for batch in items.chunks(64) {
            self.send("link_tombstones", fields(json!({ "tombstones": batch })));
        }
    }

    pub fn unregister_link(&mut self, link_id: &[u8; 16]) {
        if self.online.available {
            self.send("link_unregister", fields(json!({ "link_id": b64::encode_url(link_id) })));
        }
    }

    pub(super) fn receive_online(&mut self, kind: &str, message: &Value) {
        if !self.online.available {
            return;
        }
        match kind {
            "rdv_published" => {
                let accepted = message.get("accepted") == Some(&Value::Bool(true));
                if !accepted && message.get("reason").and_then(Value::as_str) == Some("stale") {
                    self.online.seq += 3600 * 1000;
                }
            }
            "rdv_records" => self.receive_records(message),
            "sig_opened" | "sig_refused" => self.receive_opened(message, kind == "sig_refused"),
            "sig_incoming" => self.receive_incoming(message),
            "sig_msg" => {
                let sid = message.get("sid").and_then(Value::as_str).filter(|s| self.online.sids.contains_key(*s));
                let payload =
                    b64::decode_value(message.get("payload"), 0).filter(|p| (1..=PAYLOAD_MAX).contains(&p.len()));
                if let (Some(sid), Some(payload)) = (sid, payload) {
                    self.outcomes.push(HostOutcome::Payload { sid: sid.to_owned(), payload });
                }
            }
            "sig_closed" => {
                if let Some(sid) = message.get("sid").and_then(Value::as_str) {
                    if self.online.sids.remove(sid).is_some() {
                        self.outcomes.push(HostOutcome::SidEnded { sid: sid.to_owned() });
                    }
                }
            }
            "relay_credentials_result" | "relay_refused" => self.receive_credentials(message, kind == "relay_refused"),
            "link_registered" => {
                if let Some(link_id) = b64::decode_array::<16>(message.get("link_id")) {
                    let ok = message.get("ok") == Some(&Value::Bool(true));
                    self.outcomes.push(HostOutcome::LinkRegistered { link_id, ok });
                }
            }
            _ => {}
        }
    }

    fn receive_records(&mut self, message: &Value) {
        let Some(Pending::Lookup { token, .. }) = self.take_pending(message) else { return };
        let blobs = message.get("records").and_then(Value::as_array).and_then(|records| {
            records
                .iter()
                .map(|r| r.as_str().and_then(|r| b64::decode_url(r, SEALED_LENGTH)))
                .collect::<Option<Vec<_>>>()
        });
        self.outcomes.push(HostOutcome::Records { token, blobs });
    }

    fn receive_opened(&mut self, message: &Value, refused: bool) {
        let pending = self.take_pending(message);
        let sid = message.get("sid").and_then(Value::as_str).filter(|s| b64::decode_url(s, 16).is_some());
        let Some(Pending::Open { token, .. }) = pending else {
            // An answer to an open this side gave up on: let the host forget the sid now.
            if let Some(sid) = sid.filter(|_| !refused) {
                self.send("sig_close", fields(json!({ "sid": sid })));
            }
            return;
        };
        let link_ended =
            message.get("link_ended").and_then(Value::as_str).filter(|r| matches!(*r, "revoked" | "expired"));
        let sid =
            sid.filter(|s| !refused && link_ended.is_none() && !self.online.sids.contains_key(*s)).map(str::to_owned);
        if let Some(sid) = &sid {
            self.online.sids.insert(sid.clone(), Sid { sent: 0 });
        }
        let owner_online = message.get("owner_online") == Some(&Value::Bool(true));
        let link_ended = link_ended.map(str::to_owned);
        self.outcomes.push(HostOutcome::Opened { token, sid, owner_online, link_ended });
    }

    fn receive_incoming(&mut self, message: &Value) {
        let sid = message.get("sid").and_then(Value::as_str).filter(|s| b64::decode_url(s, 16).is_some());
        let via = match message.get("via").and_then(Value::as_str) {
            Some("rdv") => Via::Rendezvous,
            Some("id") => Via::FriendsId,
            Some("link") => Via::Link,
            Some("join") => Via::Join,
            _ => return,
        };
        let payload = b64::decode_value(message.get("payload"), 0).filter(|p| (1..=PAYLOAD_MAX).contains(&p.len()));
        let link_id = b64::decode_array::<16>(message.get("link_id"));
        let (Some(sid), Some(payload)) = (sid, payload) else { return };
        if (via == Via::Link && link_id.is_none()) || self.online.sids.contains_key(sid) {
            return; // silence: to the caller, exactly as if nobody were here
        }
        self.online.sids.insert(sid.to_owned(), Sid { sent: 0 });
        self.outcomes.push(HostOutcome::Incoming { sid: sid.to_owned(), via, link_id, payload });
    }

    fn receive_credentials(&mut self, message: &Value, refused: bool) {
        let Some(Pending::Relay { token, .. }) = self.take_pending(message) else { return };
        let username = message.get("username").and_then(Value::as_str).filter(|u| !u.is_empty());
        let credential = message.get("credential").and_then(Value::as_str).filter(|c| !c.is_empty());
        let expires = message.get("expires").and_then(Value::as_i64);
        let uri = crate::driver::context::first_turn_over_udp(&self.online.relay_uris);
        let credentials = match (refused, username, credential, expires, uri) {
            (false, Some(username), Some(credential), Some(expires), Some(turn_uri)) => Some(RelayCredentials {
                turn_uri,
                username: username.to_owned(),
                credential: credential.to_owned(),
                expires: expires as f64 - self.skew,
            }),
            _ => None,
        };
        self.outcomes.push(HostOutcome::Relay { token, credentials });
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn host_times() {
        assert_eq!(super::parse_time("1970-01-02T00:00:01Z"), Some(86401.0));
        assert_eq!(super::parse_time("2026-10-14T00:00:00.500Z").map(|t| t.fract()), Some(0.5));
    }
}
