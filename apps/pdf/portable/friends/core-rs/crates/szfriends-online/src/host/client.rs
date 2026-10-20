//! The check-in client (ADR 0005 § Check-in; `SZFriendsCheckInClient.m`, `+Reservation.m`): one connection to the
//! highest-priority reachable rendezvous host, a signed check-in that reserves the Friends ID, collision renames,
//! host-list updates and reconnection with jittered backoff. Every answer that changes the Friends ID must carry the
//! host's signature over this connection's challenge. The online side (records, lookups, sids, relay credentials,
//! links) is in `online.rs`. Everything runs on the owner's thread; a generation counter discards what a socket the
//! client gave up on still reports.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Map, Value};
use szfriends_identity::Identity;

use super::codec::{self, checkin_message, protocol_for_challenge, reply_verifies, welcome_body, CHECKIN_DOMAIN};
use super::list::{HostEntry, HostList};
use super::online::OnlineState;
use super::reservation::{CheckedInFor, Membership};
use super::websocket::{Endpoint, Roots, Socket, SocketEvent};
use crate::b64;

/// The host pings every 25 s; so does the client, and a pong missing for 15 s means the connection is gone.
const PING_INTERVAL: f64 = 25.0;
const PONG_TIMEOUT: f64 = 15.0;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
pub(super) const RESERVES_PER_CONNECTION: u32 = 20;

/// What the socket's threads report, back on the owner's thread.
#[derive(Debug)]
pub enum HostInput {
    Connected(u64, Option<Socket>),
    Socket(u64, SocketEvent),
}

/// Where the reader and connector threads report.
pub type HostSink = Arc<dyn Fn(HostInput) + Send + Sync>;

pub use super::outcome::{HostOutcome, Via};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Phase {
    Idle,
    Opening,
    /// Releasing the ID from before joining a profile, before checking in (`release.rs`).
    Releasing,
    CheckingIn,
    CheckedIn,
}

/// Draws a Friends ID: the one the store believes reserved first, then fresh ones after collisions.
pub type IdProvider = Box<dyn FnMut(u32) -> String + Send>;

pub struct HostClient {
    pub(super) identity: Arc<Identity>,
    app_version: String,
    pub(super) list: HostList,
    pinned: Vec<[u8; 32]>,
    sink: HostSink,
    pub(super) id_provider: IdProvider,
    pub reserved: bool,
    pub(super) running: bool,
    pub(super) phase: Phase,
    generation: u64,
    pub(super) socket: Option<Socket>,
    candidates: Vec<(HostEntry, String)>,
    index: usize,
    pub(super) attempt: u32,
    pub(super) retry_at: f64,
    connect_deadline: f64,
    pub(super) challenge: Option<Vec<u8>>,
    pub(super) pending_id: String,
    pub(super) collisions: u32,
    pub(super) reserves: u32,
    /// Who this computer checks in for (reservation.rs); its records are filed under `person_key`.
    pub membership: Option<Membership>,
    pub(super) person_key: [u8; 32],
    pub(super) checked_in_for: Option<CheckedInFor>,
    /// Whether a release of the ID from before joining is owed (`release.rs`); none never releases.
    pub release_owed: Option<super::release::ReleaseOwed>,
    pub(super) release_tried: bool,
    pub(super) releasing: bool,
    /// Reset Friends' release (`release.rs`): its deadline and who hears whether the host confirmed it.
    pub(super) reset: Option<(f64, std::sync::mpsc::Sender<bool>)>,
    next_ping: f64,
    pong_due: f64,
    pub(super) skew: f64,
    pub(super) online: OnlineState,
    pub(super) outcomes: Vec<HostOutcome>,
    pub(super) clock: Arc<dyn Fn() -> f64 + Send + Sync>,
    /// What a `wss://` host's certificate must chain to: the system's roots, or a test's own CA.
    pub tls_roots: Roots,
}

impl std::fmt::Debug for HostClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostClient").field("phase", &self.phase).field("generation", &self.generation).finish()
    }
}

fn jitter() -> f64 {
    let mut bytes = [0u8; 4];
    szfriends_crypto::random_bytes(&mut bytes);
    f64::from(u32::from_be_bytes(bytes)) / 4_294_967_296.0
}

/// `1 + jitter × (min(300, 2^attempt) − 1)` seconds.
pub fn backoff(attempt: u32, jitter: f64) -> f64 {
    let cap = if attempt >= 9 { 300.0 } else { f64::from(1u32 << attempt).min(300.0) };
    1.0 + jitter.clamp(0.0, 1.0) * (cap - 1.0)
}

impl HostClient {
    pub fn new(
        identity: Arc<Identity>,
        app_version: &str,
        list: HostList,
        pinned: Vec<[u8; 32]>,
        sink: HostSink,
        id_provider: IdProvider,
        clock: Arc<dyn Fn() -> f64 + Send + Sync>,
    ) -> Self {
        let person_key = identity.public_key();
        Self {
            identity,
            app_version: app_version.to_owned(),
            list,
            pinned,
            sink,
            id_provider,
            reserved: false,
            running: false,
            phase: Phase::Idle,
            generation: 0,
            socket: None,
            candidates: Vec::new(),
            index: 0,
            attempt: 0,
            retry_at: f64::INFINITY,
            connect_deadline: f64::INFINITY,
            challenge: None,
            pending_id: String::new(),
            collisions: 0,
            reserves: 0,
            membership: None,
            person_key,
            checked_in_for: None,
            release_owed: None,
            release_tried: false,
            releasing: false,
            reset: None,
            next_ping: f64::INFINITY,
            pong_due: f64::INFINITY,
            skew: 0.0,
            online: OnlineState::default(),
            outcomes: Vec::new(),
            clock,
            tls_roots: Roots::System,
        }
    }

    pub(super) fn now(&self) -> f64 {
        (self.clock)()
    }

    pub fn take_outcomes(&mut self) -> Vec<HostOutcome> {
        std::mem::take(&mut self.outcomes)
    }

    pub fn start(&mut self) {
        if self.running {
            return;
        }
        self.running = true;
        self.attempt = 0;
        self.begin_round();
    }

    pub fn stop(&mut self) {
        self.running = false;
        self.close_socket();
        self.retry_at = f64::INFINITY;
    }

    pub(super) fn is_running(&self) -> bool {
        self.running
    }

    /// Checks in again from the start (another person or chain to check in for).
    pub(super) fn restart(&mut self) {
        self.close_socket();
        self.attempt = 0;
        self.retry_at = f64::INFINITY;
        self.begin_round();
    }

    /// A network change: reconnect at once if waiting to retry.
    pub fn network_changed(&mut self) {
        if self.running && self.retry_at.is_finite() {
            self.attempt = 0;
            self.retry_at = f64::INFINITY;
            self.begin_round();
        }
    }

    pub(super) fn begin_round(&mut self) {
        self.releasing = self.reset.is_some() || self.release_due();
        self.candidates = self
            .list
            .entries
            .iter()
            .filter(|e| e.rendezvous)
            .flat_map(|e| e.urls.iter().map(move |u| (e.clone(), u.clone())))
            .collect();
        self.index = 0;
        self.connect_candidate();
    }

    fn connect_candidate(&mut self) {
        if self.index >= self.candidates.len() && self.reset.is_some() {
            return self.finish_release(None);
        }
        if self.index >= self.candidates.len() {
            // Every host failed: stay quiet and try again later. Nearby is unaffected.
            self.schedule_retry();
            return;
        }
        self.close_socket();
        let generation = self.generation;
        let url = self.candidates[self.index].1.clone();
        self.phase = Phase::Opening;
        self.connect_deadline = self.now() + CONNECT_TIMEOUT.as_secs_f64();
        let (sink, roots) = (self.sink.clone(), self.tls_roots.clone());
        std::thread::spawn(move || {
            let reader = sink.clone();
            let socket = Endpoint::parse(&url).and_then(|endpoint| {
                let events = move |event| reader(HostInput::Socket(generation, event));
                Socket::connect(&endpoint, &roots, events, CONNECT_TIMEOUT).ok()
            });
            sink(HostInput::Connected(generation, socket));
        });
    }

    pub(super) fn candidate_failed(&mut self) {
        self.close_socket();
        self.index += 1;
        self.connect_candidate();
    }

    fn schedule_retry(&mut self) {
        self.retry_at = self.now() + backoff(self.attempt, jitter());
        self.attempt += 1;
    }

    pub(super) fn close_socket(&mut self) {
        self.generation += 1;
        if let Some(socket) = self.socket.take() {
            socket.close();
        }
        self.phase = Phase::Idle;
        self.challenge = None;
        self.connect_deadline = f64::INFINITY;
        self.next_ping = f64::INFINITY;
        self.pong_due = f64::INFINITY;
        self.connection_closed_online();
    }

    pub(super) fn send(&self, kind: &str, fields: Map<String, Value>) -> bool {
        self.socket.as_ref().is_some_and(|socket| socket.send_text(&codec::encode(kind, fields)))
    }

    /// What a socket's threads reported.
    pub fn input(&mut self, input: HostInput) {
        match input {
            HostInput::Connected(generation, socket) if generation == self.generation => match socket {
                Some(socket) => {
                    self.socket = Some(socket);
                    self.next_ping = self.now() + PING_INTERVAL;
                }
                None => self.candidate_failed(),
            },
            HostInput::Socket(generation, event) if generation == self.generation => match event {
                SocketEvent::Text(text) => self.receive(&text),
                SocketEvent::Pong => self.pong_due = f64::INFINITY,
                SocketEvent::Closed(Some(super::reservation::CLOSE_DEVICE_REVOKED)) => self.device_revoked(),
                SocketEvent::Closed(_) => self.socket_closed(),
            },
            _ => {}
        }
    }

    fn socket_closed(&mut self) {
        if self.phase == Phase::Releasing && self.reset.is_none() {
            return self.finish_release(None);
        }
        let checked_in = self.phase == Phase::CheckedIn;
        self.close_socket();
        if !checked_in {
            // Before a welcome, a close means this host did not work out: try the next one.
            self.index += 1;
            self.connect_candidate();
            return;
        }
        if self.running {
            self.schedule_retry();
        }
    }

    pub fn next_deadline(&self) -> f64 {
        let mut next = self.retry_at.min(self.connect_deadline).min(self.next_ping).min(self.pong_due);
        next = next.min(self.online.next_deadline()).min(self.reset.as_ref().map_or(f64::INFINITY, |r| r.0));
        next
    }

    pub fn tick(&mut self) {
        let now = self.now();
        if self.retry_at <= now {
            self.retry_at = f64::INFINITY;
            if self.running {
                self.begin_round();
            }
        }
        // Reset Friends' release ends at its own deadline; the one from before joining, at the connection's.
        let release_over = match &self.reset {
            Some((deadline, _)) => *deadline <= now,
            None => self.connect_deadline <= now && self.phase == Phase::Releasing,
        };
        if release_over {
            self.finish_release(None);
        } else if self.connect_deadline <= now && self.phase != Phase::CheckedIn {
            self.candidate_failed();
        }
        if self.pong_due <= now {
            self.socket_closed();
        }
        if self.next_ping <= now {
            if let Some(socket) = &self.socket {
                socket.ping();
                if !self.pong_due.is_finite() {
                    self.pong_due = now + PONG_TIMEOUT;
                }
            }
            self.next_ping = now + PING_INTERVAL;
        }
        self.tick_online(now);
    }

    fn receive(&mut self, text: &str) {
        let Ok(message) = serde_json::from_str::<Value>(text) else { return };
        let Some(kind) = message.get("type").and_then(Value::as_str).map(str::to_owned) else { return };
        match kind.as_str() {
            "challenge" => self.receive_challenge(&message),
            "welcome" if self.phase == Phase::CheckingIn => self.receive_welcome(&message),
            "released" if self.phase == Phase::Releasing => self.finish_release(Some(&message)),
            "reserve_result" if self.phase == Phase::CheckedIn => {
                let body = codec::reserve_result_body(&self.pending_id, &message);
                let verified = self.verifies(&message, &body);
                let result = if verified { message.get("reservation").and_then(Value::as_str) } else { None };
                let (id, proof) = (message.get("friends_id"), message.get("attestation"));
                self.handle_reservation(result.unwrap_or("unavailable"), id, false, proof);
            }
            "host_list" => {
                self.offer_list(message.get("host_list"));
            }
            "error" if message.get("code").and_then(Value::as_str) == Some("device_revoked") => self.device_revoked(),
            _ if self.phase == Phase::CheckedIn => self.receive_online(&kind, &message),
            _ => {}
        }
    }

    /// The host this connection reached, as the signed list describes it.
    pub(super) fn connected_entry(&self) -> Option<&HostEntry> {
        self.candidates.get(self.index).map(|(entry, _)| entry)
    }

    fn receive_challenge(&mut self, message: &Value) {
        if self.phase != Phase::Opening {
            return;
        }
        let Some(entry) = self.connected_entry().cloned() else { return };
        let nonce = b64::decode_value(message.get("nonce"), 32);
        // The signature names the host id from the signed list; a host answering under another name gets nothing.
        let Some(nonce) = nonce.filter(|_| message.get("host_id").and_then(Value::as_str) == Some(entry.id.as_str()))
        else {
            self.candidate_failed();
            return;
        };
        self.challenge = Some(nonce.clone());
        if self.releasing {
            self.phase = Phase::Releasing;
            return self.send_release(&entry.id, &nonce);
        }
        self.online_challenge(message);
        let friends_id = (self.id_provider)(0);
        self.pending_id = friends_id.clone();
        self.collisions = 0;
        self.reserves = 0;
        let protocol = protocol_for_challenge(message);
        let (root, chain) = self.person_for(protocol);
        self.checking_in_for(protocol, root, chain.as_deref());
        let signed = checkin_message(
            &entry.id,
            &nonce,
            &self.identity.public_key(),
            &friends_id,
            self.reserved,
            &self.app_version,
            protocol,
            self.list.version,
            Some(&root),
            chain.as_deref(),
        );
        let signature = self.identity.sign(&signed, CHECKIN_DOMAIN);
        self.phase = Phase::CheckingIn;
        let mut fields = json!({
            "identity_key": b64::encode_url(&self.identity.public_key()),
            "friends_id": friends_id,
            "reserved": self.reserved,
            "app_version": self.app_version,
            "protocol": protocol,
            "list_version": self.list.version,
            "sig": b64::encode_url(&signature),
        });
        if protocol >= codec::DEVICES_PROTOCOL {
            fields["root_key"] = Value::String(b64::encode_url(&root));
            if let Some(chain) = &chain {
                fields["chain"] = Value::String(b64::encode_url(chain));
            }
        }
        if let Value::Object(fields) = fields {
            self.send("checkin", fields);
        }
    }

    pub(super) fn verifies(&self, message: &Value, body: &[String]) -> bool {
        match (self.connected_entry(), &self.challenge) {
            (Some(entry), Some(challenge)) => reply_verifies(message, body, challenge, &entry.public_key),
            _ => false,
        }
    }

    fn receive_welcome(&mut self, message: &Value) {
        self.connect_deadline = f64::INFINITY;
        self.phase = Phase::CheckedIn;
        let verified = self.verifies(message, &welcome_body(&self.pending_id, message));
        // A list carries its own signature, so it is offered whether or not the welcome verified.
        if self.offer_list(message.get("host_list")) {
            return;
        }
        let result = if verified { message.get("reservation").and_then(Value::as_str) } else { None };
        self.handle_reservation(
            result.unwrap_or("unavailable"),
            message.get("friends_id"),
            true,
            message.get("attestation"),
        );
        if self.phase == Phase::CheckedIn && message.get("online") == Some(&Value::Bool(true)) {
            self.online_checked_in();
        }
    }

    /// `true` when the new list moved the preferred host elsewhere and the client is reconnecting to it.
    fn offer_list(&mut self, envelope: Option<&Value>) -> bool {
        let Some(envelope) = envelope.filter(|e| e.is_object()) else { return false };
        let Some(list) = HostList::from_signed(envelope.to_string().as_bytes(), &self.pinned) else { return false };
        if list.version <= self.list.version {
            return false;
        }
        self.list = list;
        self.outcomes.push(HostOutcome::ListChanged(self.list.clone()));
        if !self.running || self.phase != Phase::CheckedIn {
            return false;
        }
        let first = self.list.entries.iter().filter(|e| e.rendezvous).flat_map(|e| e.urls.first()).next().cloned();
        if first.as_deref() == self.candidates.get(self.index).map(|(_, url)| url.as_str()) {
            return false;
        }
        self.close_socket();
        self.attempt = 0;
        self.begin_round();
        true
    }

    /// The signed list this client goes by now (a newer one replaces it at a check-in).
    pub fn list(&self) -> &HostList {
        &self.list
    }

    pub fn is_checked_in(&self) -> bool {
        self.phase == Phase::CheckedIn
    }
}
