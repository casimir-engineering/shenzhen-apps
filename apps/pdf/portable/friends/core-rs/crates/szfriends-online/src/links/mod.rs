//! Download links served from this core (`SZFriendsLinkService.m`, `SZFriendsLinkSetup.m`; PROTOCOL.md § Links, Browser
//! downloads): each live link registered with the host on every connection, and each opening answered through its sid.
//! The sender stays silent to a hello that does not open, creates no peer connection until the opener has proved the
//! link secret, answers each attempt it is offered (attempt 2 through the relay), and once a channel opens sends the
//! file in records the opener grants credit for (`upload.rs`).

mod attempt;
mod upload;
pub mod wire;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{json, Map, Value};
use szfriends_datachannel_sys::Event;
use szfriends_identity::Identity;

use crate::host::HostClient;
use crate::transport::connection::Forward;
use crate::transport::description::Description;
use crate::transport::{ConnEvent, Connection, Kind, Purpose, RelayCredentials, Request, Role, TransportConfig};
use attempt::{attempt_number, remote_technique, Attempt};
use wire::{LinkKeys, NONCE_LENGTH, SIDE_OPENER, SIDE_SENDER};

const SETUP_TIMEOUT: f64 = 60.0;
/// Connection ids of links never meet the driver's.
const CONNECTION_IDS: u64 = 1 << 40;
/// Relay requests of links never meet the driver's attempts.
const RELAY_TOKENS: u64 = 1 << 56;
/// Candidates held for an attempt waiting for relay credentials (a connection applies no more than this either).
const HELD_MAX: usize = crate::transport::candidate::REMOTE_CANDIDATE_MAX + 1;

/// One live download link as the store holds it.
#[derive(Clone, Debug)]
pub struct DownloadLink {
    pub link_id: [u8; 16],
    pub secret: [u8; 32],
    /// The file served: a snapshot in the state directory, or the original while it is unchanged.
    pub path: PathBuf,
    pub name: String,
    pub size: u64,
    pub sha256: [u8; 32],
    pub blake2b: [u8; 32],
    pub media_type: String,
    /// Unix seconds.
    pub expires: f64,
    pub sender_name: String,
    pub sender_friends_id: String,
    pub thumbnail: Option<Vec<u8>>,
}

/// Where the links come from (the store), asked on the online thread.
pub trait LinkFiles: Send {
    /// Every link held, an expired one too until the store lets it go.
    fn links(&self) -> Vec<DownloadLink>;
    /// Whether the file a link serves is no longer the one it was made for.
    fn changed(&self, link: &DownloadLink) -> bool {
        let _ = link;
        false
    }
    /// Why ended links ended, for the host to tell whoever opens one.
    fn tombstones(&self) -> Vec<Tombstone> {
        Vec::new()
    }
}

/// A link that ended: its id's hash (`link_tombstone_hash`), "revoked" or "expired", and until when (Unix seconds).
#[derive(Clone, Debug, PartialEq)]
pub struct Tombstone {
    pub hash: [u8; 32],
    pub reason: String,
    pub until: f64,
}

/// How long a refused opener's sid stays, so the `end` reaches it before the sid does.
const END_LINGER: f64 = 2.0;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkEvent {
    /// Someone proved a link's secret and a channel opened.
    Opened([u8; 16]),
    /// A download completed (the opener's "done").
    Downloaded([u8; 16]),
}

#[derive(Debug)]
struct Setup {
    keys: LinkKeys,
    link: DownloadLink,
    proven: bool,
    refused: bool,
    ended: bool,
    stream_opened: bool,
    attempts: HashMap<u8, Attempt>,
    deadline: f64,
}

pub struct Links {
    identity: Arc<Identity>,
    files: Option<Box<dyn LinkFiles>>,
    transport: TransportConfig,
    setups: HashMap<String, Setup>,
    connections: HashMap<u64, String>,
    relays: HashMap<u64, (String, u8)>,
    next_id: u64,
    pub forward: Option<Forward>,
    pub stun_uri: Option<String>,
    events: Vec<LinkEvent>,
    finished: Arc<std::sync::Mutex<Vec<LinkEvent>>>,
    /// Setups whose upload ended (completed or not), by sid: their connection goes with them.
    uploads_ended: Arc<std::sync::Mutex<Vec<String>>>,
    start: std::time::Instant,
}

impl std::fmt::Debug for Links {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Links").field("setups", &self.setups.len()).finish()
    }
}

fn object(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

fn wall() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

impl Setup {
    fn new(keys: LinkKeys, link: DownloadLink, deadline: f64) -> Self {
        Self {
            keys,
            link,
            proven: false,
            refused: false,
            ended: false,
            stream_opened: false,
            attempts: HashMap::new(),
            deadline,
        }
    }
}

impl Links {
    pub fn new(identity: Arc<Identity>, files: Option<Box<dyn LinkFiles>>, loopback_only: bool) -> Self {
        let mut transport = if loopback_only { TransportConfig::loopback() } else { TransportConfig::default() };
        transport.links_use_local_addresses = loopback_only;
        Self {
            identity,
            files,
            transport,
            setups: HashMap::new(),
            connections: HashMap::new(),
            relays: HashMap::new(),
            next_id: CONNECTION_IDS,
            forward: None,
            stun_uri: None,
            events: Vec::new(),
            finished: Arc::new(std::sync::Mutex::new(Vec::new())),
            uploads_ended: Arc::new(std::sync::Mutex::new(Vec::new())),
            start: std::time::Instant::now(),
        }
    }

    fn now(&self) -> f64 {
        self.start.elapsed().as_secs_f64()
    }

    pub fn take_events(&mut self) -> Vec<LinkEvent> {
        let mut events = std::mem::take(&mut self.events);
        events.extend(self.finished.lock().unwrap_or_else(|e| e.into_inner()).drain(..));
        events
    }

    fn live(&self) -> Vec<DownloadLink> {
        let now = wall();
        self.files.as_ref().map(|f| f.links()).unwrap_or_default().into_iter().filter(|l| l.expires > now).collect()
    }

    /// Every live link, on each host connection (and again whenever the links change).
    pub fn register_all(&mut self, host: &mut HostClient) {
        // Tombstones first: one also ends the host's binding of a link it still holds.
        let tombstones = self.files.as_ref().map(|f| f.tombstones()).unwrap_or_default();
        host.send_link_tombstones(&tombstones);
        for link in self.live() {
            host.register_link(&link.link_id, link.expires as i64);
        }
    }

    pub fn registered(&mut self, _link_id: [u8; 16], _ok: bool) {}

    pub fn owns_connection(&self, id: u64) -> bool {
        self.connections.contains_key(&id)
    }

    /// An open via a link id: a hello for a link we hold gets the challenge; anything else gets no answer at all.
    pub fn incoming(
        &mut self,
        host: &mut HostClient,
        sid: String,
        link_id: [u8; 16],
        payload: &[u8],
        stun: Option<String>,
    ) {
        self.stun_uri = stun;
        let held = self.files.as_ref().map(|f| f.links()).unwrap_or_default();
        let Some(link) = held.into_iter().find(|l| l.link_id == link_id) else {
            host.close_sid(&sid);
            return;
        };
        let mut keys = LinkKeys::new(link_id, &link.secret);
        let hello = keys.open_message(payload, SIDE_OPENER);
        let opener: Option<[u8; NONCE_LENGTH]> = hello
            .as_ref()
            .filter(|h| h.get("t").and_then(Value::as_str) == Some("hello") && h.get("v") == Some(&json!(1)))
            .and_then(|h| crate::b64::decode_value(h.get("n"), NONCE_LENGTH))
            .and_then(|n| n.try_into().ok());
        let Some(opener) = opener else {
            host.close_sid(&sid);
            return;
        };
        if link.expires <= wall() {
            // Held a little longer than it works: the opener, who holds the secret, hears why at once.
            let end = keys.seal_message(&object(json!({ "t": "end", "reason": "expired" })), SIDE_SENDER);
            if end.is_some_and(|end| host.send_payload(&sid, &end)) {
                let mut setup = Setup::new(keys, link, self.now() + END_LINGER);
                setup.refused = true;
                self.setups.insert(sid, setup);
            } else {
                host.close_sid(&sid);
            }
            return;
        }
        let mut sender = [0u8; NONCE_LENGTH];
        szfriends_crypto::random_bytes(&mut sender);
        let challenge = object(json!({
            "t": "challenge", "o": crate::b64::encode_url(&opener), "n": crate::b64::encode_url(&sender),
        }));
        let Some(sealed) = keys.seal_message(&challenge, SIDE_SENDER) else { return };
        keys.set_nonces(opener, sender);
        if !host.send_payload(&sid, &sealed) {
            return;
        }
        let setup = Setup::new(keys, link, self.now() + SETUP_TIMEOUT);
        self.setups.insert(sid, setup);
    }

    fn send(host: &mut HostClient, sid: &str, setup: &Setup, message: Value) -> bool {
        setup.keys.seal_message(&object(message), SIDE_SENDER).is_some_and(|sealed| host.send_payload(sid, &sealed))
    }

    pub fn payload(&mut self, host: &mut HostClient, sid: &str, payload: &[u8]) {
        let now = self.now();
        let Some(setup) = self.setups.get_mut(sid).filter(|s| !s.ended && !s.refused) else { return };
        let Some(message) = setup.keys.open_message(payload, SIDE_OPENER) else { return };
        let kind = message.get("t").and_then(Value::as_str).unwrap_or("").to_owned();
        if !setup.proven {
            let proof = crate::b64::decode_value(message.get("mac"), 32);
            if kind != "proof" || !proof.is_some_and(|p| setup.keys.verify_proof(&p)) {
                // Whoever this is did not prove the secret: no answer, no connection.
                self.end(host, sid);
                return;
            }
            setup.proven = true;
            // Before any connection exists: a file that changed since the link was made is not served.
            if self.files.as_ref().is_some_and(|f| f.changed(&setup.link)) {
                Self::send(host, sid, setup, json!({ "t": "end", "reason": "changed" }));
                setup.refused = true;
                setup.deadline = now + END_LINGER;
            }
            return;
        }
        let Some(number) = attempt_number(message.get("a")) else { return };
        match (kind.as_str(), message.get("sdp").and_then(Value::as_str)) {
            ("offer", Some(sdp)) if !setup.attempts.contains_key(&number) => {
                let relay = message.get("relay") == Some(&Value::Bool(true));
                self.answer_offer(host, sid, sdp.to_owned(), number, relay);
            }
            ("cand", _) => {
                let lines: Vec<Option<String>> = if message.get("end") == Some(&Value::Bool(true)) {
                    vec![None]
                } else {
                    let candidates = message.get("c").and_then(Value::as_array).cloned().unwrap_or_default();
                    candidates.iter().take(64).filter_map(|c| c.get(0)?.as_str().map(|s| Some(s.to_owned()))).collect()
                };
                for line in lines {
                    self.apply_candidate(sid, number, line);
                }
            }
            _ => {}
        }
        self.flush(host, sid);
    }

    /// A new attempt replaces the earlier one, as the page drops its own.
    fn answer_offer(&mut self, host: &mut HostClient, sid: &str, sdp: String, number: u8, relay: bool) {
        let Some(setup) = self.setups.get_mut(sid) else { return };
        for (_, mut older) in setup.attempts.drain() {
            if let Some(mut connection) = older.connection.take() {
                connection.close();
            }
            self.connections.remove(&older.id);
        }
        if !relay {
            self.open_attempt(sid, number, None, sdp);
            return;
        }
        let placeholder = Attempt::new(number, 0, Some(sdp));
        setup.attempts.insert(number, placeholder);
        let token = RELAY_TOKENS + self.next_id;
        self.next_id += 1;
        self.relays.insert(token, (sid.to_owned(), number));
        host.request_relay(token, sid);
    }

    /// `true` when the token was one of ours.
    pub fn relay_credentials(
        &mut self,
        host: &mut HostClient,
        token: u64,
        credentials: Option<RelayCredentials>,
    ) -> bool {
        let Some((sid, number)) = self.relays.remove(&token) else { return false };
        let Some(credentials) = credentials else { return true }; // the opener's own timer decides
        let Some(placeholder) = self.setups.get_mut(&sid).and_then(|s| s.attempts.remove(&number)) else { return true };
        let held = placeholder.held;
        if let Some(offer) = placeholder.offer {
            self.open_attempt(&sid, number, Some(credentials), offer);
        }
        for line in held {
            self.apply_candidate(&sid, number, line);
        }
        self.flush(host, &sid);
        true
    }

    fn open_attempt(&mut self, sid: &str, number: u8, relay: Option<RelayCredentials>, offer: String) {
        let (Some(setup), Some(forward)) = (self.setups.get_mut(sid), self.forward.clone()) else { return };
        let Ok(description) = Description::parse(&offer) else { return };
        let request = Request {
            purpose: Purpose::Link,
            role: Role::Answerer,
            kind: if relay.is_some() { Kind::Relay } else { Kind::Direct },
            peer: setup.keys.link_id.to_vec(),
            stun_uri: if relay.is_some() { None } else { self.stun_uri.clone() },
            relay: relay.clone(),
            local_port: 0,
            remote_offer: Some((offer, description.fingerprint)),
        };
        let id = self.next_id;
        self.next_id += 1;
        let notice: Arc<dyn Fn() + Send + Sync> = Arc::new(|| {});
        let Ok(connection) = Connection::open(id, &request, &self.transport, forward, notice, wall()) else { return };
        let mut attempt = Attempt::new(number, id, None);
        attempt.connection = Some(connection);
        setup.attempts.insert(number, attempt);
        self.connections.insert(id, sid.to_owned());
    }

    /// A candidate line, or `None` for the end of the other side's.
    fn apply_candidate(&mut self, sid: &str, number: u8, line: Option<String>) {
        let Some(attempt) = self.setups.get_mut(sid).and_then(|s| s.attempts.get_mut(&number)) else { return };
        let Some(connection) = attempt.connection.as_mut() else {
            if attempt.held.len() < HELD_MAX {
                attempt.held.push(line);
            }
            return;
        };
        if let Some(line) = line {
            let _ = connection.add_remote_candidate(&line, remote_technique(&line));
        }
    }

    pub fn connection_event(&mut self, host: &mut HostClient, id: u64, event: Event) {
        let Some(sid) = self.connections.get(&id).cloned() else { return };
        let Some(setup) = self.setups.get_mut(&sid) else { return };
        let Some(number) = setup.attempts.values().find(|a| a.id == id).map(|a| a.number) else { return };
        let events = setup.attempts.get_mut(&number).and_then(|a| a.connection.as_mut()).map(|c| c.handle(event));
        for event in events.unwrap_or_default() {
            self.conn_event(host, &sid, number, event);
        }
        self.flush(host, &sid);
    }

    fn conn_event(&mut self, host: &mut HostClient, sid: &str, number: u8, event: ConnEvent) {
        let Some(setup) = self.setups.get_mut(sid) else { return };
        let Some(attempt) = setup.attempts.get_mut(&number) else { return };
        match event {
            ConnEvent::Description { sdp, .. } => {
                attempt.mid = Description::parse(&sdp).map_or_else(|_| "0".to_owned(), |d| d.mid);
                attempt.described = true;
                let message = json!({ "t": "answer", "a": number, "sdp": sdp });
                Self::send(host, sid, setup, message);
            }
            ConnEvent::Candidate { line, .. } => attempt.outgoing.push((line, attempt.mid.clone())),
            ConnEvent::GatheringDone => attempt.local_ended = true,
            ConnEvent::Stream { stream, .. } => {
                if setup.stream_opened || setup.ended {
                    stream.writer.close();
                    return;
                }
                setup.stream_opened = true;
                for (other, attempt) in setup.attempts.iter_mut() {
                    if *other != number {
                        if let Some(mut connection) = attempt.connection.take() {
                            connection.close();
                        }
                        self.connections.remove(&attempt.id);
                    }
                }
                let Some(key) = setup.keys.content_key(number) else {
                    stream.writer.close();
                    self.uploads_ended.lock().unwrap_or_else(|e| e.into_inner()).push(sid.to_owned());
                    return;
                };
                self.events.push(LinkEvent::Opened(setup.link.link_id));
                let metadata = upload::metadata(&self.identity, &setup.link);
                let (ended, sid) = (self.uploads_ended.clone(), sid.to_owned());
                let on_end = Box::new(move || ended.lock().unwrap_or_else(|e| e.into_inner()).push(sid));
                upload::spawn(stream, setup.link.clone(), metadata, key, self.finished.clone(), on_end);
            }
            ConnEvent::RouteChanged(_) | ConnEvent::StreamClosed => {}
            ConnEvent::Failed(_) => {
                if let Some(mut connection) = attempt.connection.take() {
                    connection.close();
                }
                self.connections.remove(&attempt.id);
            }
        }
    }

    /// Local candidates go in batches, each attempt's after its description, and its end after its last batch.
    fn flush(&mut self, host: &mut HostClient, sid: &str) {
        let Some(setup) = self.setups.get_mut(sid).filter(|s| !s.ended) else { return };
        for message in attempt::candidate_messages(setup.attempts.values_mut()) {
            Self::send(host, sid, setup, message);
        }
    }

    fn end(&mut self, host: &mut HostClient, sid: &str) {
        if let Some(mut setup) = self.setups.remove(sid) {
            setup.ended = true;
            for attempt in setup.attempts.values_mut() {
                if let Some(mut connection) = attempt.connection.take() {
                    connection.close();
                }
                self.connections.remove(&attempt.id);
            }
        }
        self.relays.retain(|_, (relay_sid, _)| relay_sid != sid);
        host.close_sid(sid);
    }

    /// The sid ended: once a channel is open the host is no longer needed.
    pub fn sid_ended(&mut self, sid: &str) {
        if let Some(setup) = self.setups.get_mut(sid) {
            if !setup.stream_opened {
                setup.deadline = 0.0;
            }
        }
    }

    pub fn next_deadline(&self) -> f64 {
        self.setups.values().filter(|s| !s.stream_opened).map(|s| s.deadline).fold(f64::INFINITY, f64::min)
    }

    /// Setups and connection ids still held (tests: none once every upload has ended).
    pub fn held(&self) -> (usize, usize) {
        (self.setups.len(), self.connections.len())
    }

    pub fn tick(&mut self, host: &mut HostClient) {
        // An upload that ended takes its setup, its connection and its connection id with it.
        let ended: Vec<String> = std::mem::take(&mut *self.uploads_ended.lock().unwrap_or_else(|e| e.into_inner()));
        for sid in ended {
            self.end(host, &sid);
        }
        let now = self.now();
        let due: Vec<String> = self
            .setups
            .iter()
            .filter(|(_, s)| !s.stream_opened && s.deadline <= now)
            .map(|(sid, _)| sid.clone())
            .collect();
        for sid in due {
            self.end(host, &sid);
        }
    }

    pub fn stop(&mut self, host: &mut HostClient) {
        let sids: Vec<String> = self.setups.keys().cloned().collect();
        for sid in sids {
            self.end(host, &sid);
        }
    }
}
