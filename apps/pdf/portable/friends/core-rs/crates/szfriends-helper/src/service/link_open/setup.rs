//! One setup of a download link's opening, and the download it carries (`SZFriendsLinkSetup.m`, opener side): a guest
//! connection to the host, the hello in `link_open`, the sender's challenge answered with the proof, then attempt 1
//! (direct, STUN only) and, when no channel opens within 12 seconds or it fails, attempt 2 through the relay with
//! credentials the host gives this guest. Once a channel opens the sid is let go and the download runs on it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};
use szfriends_online::b64;
use szfriends_online::host::codec::encode;
use szfriends_online::host::websocket::{Endpoint, Roots, Socket, SocketEvent};
use szfriends_online::links::wire::{LinkKeys, NONCE_LENGTH, SIDE_OPENER, SIDE_SENDER};
use szfriends_online::transport::description::Description;
use szfriends_online::transport::{
    ConnEvent, Connection, Kind, Purpose, RelayCredentials, Request, Role, StreamInput, TransportConfig,
};

use super::attempt::{candidate_messages, numeric_stun, remote_technique, Attempt};
use super::download::{Download, Progress, Step};
use super::{GuestHost, Outcome, Sink};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// From the open to the sender's challenge.
const ANSWER_TIMEOUT: f64 = 15.0;
const DIRECT_TIMEOUT: f64 = 12.0;
const RELAY_TIMEOUT: f64 = 25.0;
/// A download that receives nothing this long counts as dropped.
const STALL_TIMEOUT: f64 = 30.0;
const PAYLOAD_MAX: usize = 4096;
const RELAY_REQ: u64 = 2;

pub enum Ended {
    Outcome(Outcome),
    /// The download's connection dropped after the file was asked for: carry on over a new setup.
    Lost,
}

type Handle = Box<dyn FnOnce(&mut Connection) -> Vec<ConnEvent> + Send>;

enum Event {
    Socket(SocketEvent),
    Connection(u64, Handle),
    Stream(StreamInput),
}

pub struct Setup<'a> {
    host: &'a GuestHost,
    keys: LinkKeys,
    opener_nonce: [u8; NONCE_LENGTH],
    generation: u64,
    events: Sender<Event>,
    inbox: Receiver<Event>,
    socket: Option<Socket>,
    sid: Option<String>,
    attempts: HashMap<u64, Attempt>,
    current: Option<u64>,
    deadline: f64,
    download: Option<Download>,
    start: Instant,
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

fn outcome_for(reason: Option<&str>) -> Outcome {
    match reason {
        Some("changed") => Outcome::Changed,
        Some("revoked" | "expired") => Outcome::Ended,
        _ => Outcome::Failed,
    }
}

impl<'a> Setup<'a> {
    pub fn new(link_id: [u8; 16], secret: &[u8; 32], host: &'a GuestHost, generation: u64) -> Self {
        let (events, inbox) = channel();
        let mut opener_nonce = [0u8; NONCE_LENGTH];
        szfriends_core::crypto::random_bytes(&mut opener_nonce);
        Self {
            host,
            keys: LinkKeys::new(link_id, secret),
            opener_nonce,
            generation,
            events,
            inbox,
            socket: None,
            sid: None,
            attempts: HashMap::new(),
            current: None,
            deadline: 0.0,
            download: None,
            start: Instant::now(),
        }
    }

    fn now(&self) -> f64 {
        self.start.elapsed().as_secs_f64()
    }

    pub fn run(mut self, progress: &mut Progress, sink: &Sink, abort: &AtomicBool) -> Ended {
        let ended = self.exchange(progress, sink, abort);
        self.close();
        ended
    }

    fn exchange(&mut self, progress: &mut Progress, sink: &Sink, abort: &AtomicBool) -> Ended {
        let url =
            if self.host.url.contains('?') { self.host.url.clone() } else { format!("{}?guest=1", self.host.url) };
        let Some(endpoint) = Endpoint::parse(&url) else { return Ended::Outcome(Outcome::Unavailable) };
        let roots = self.host.roots.clone().map_or(Roots::System, Roots::Pem);
        let events = self.events.clone();
        let socket = Socket::connect(&endpoint, &roots, move |e| drop(events.send(Event::Socket(e))), CONNECT_TIMEOUT);
        let Ok(socket) = socket else { return Ended::Outcome(Outcome::Unavailable) };
        self.socket = Some(socket);
        self.deadline = self.now() + ANSWER_TIMEOUT;
        loop {
            if abort.load(Ordering::SeqCst) {
                if let Some(download) = self.download.as_mut() {
                    download.cancel();
                }
                return Ended::Outcome(Outcome::Failed);
            }
            let wait = (self.deadline - self.now()).clamp(0.0, 0.25);
            let event = match self.inbox.recv_timeout(Duration::from_secs_f64(wait)) {
                Ok(event) => event,
                Err(RecvTimeoutError::Timeout) => {
                    if self.now() >= self.deadline {
                        if let Some(ended) = self.timed_out() {
                            return ended;
                        }
                    }
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => return Ended::Outcome(Outcome::Failed),
            };
            let ended = match event {
                Event::Socket(SocketEvent::Text(text)) => self.host_message(&text),
                Event::Socket(SocketEvent::Closed(_)) => {
                    self.socket = None;
                    // Once a channel is open the host is no longer needed.
                    self.download.is_none().then_some(Ended::Outcome(Outcome::Unavailable))
                }
                Event::Socket(SocketEvent::Pong) => None,
                Event::Connection(id, handle) => self.connection_event(id, handle),
                Event::Stream(StreamInput::Data(record)) => self.record(progress, sink, &record),
                Event::Stream(StreamInput::Closed) => Some(self.dropped()),
            };
            if let Some(ended) = ended {
                return ended;
            }
        }
    }

    fn dropped(&self) -> Ended {
        if self.download.as_ref().is_some_and(|d| d.started) {
            Ended::Lost
        } else {
            Ended::Outcome(Outcome::Failed)
        }
    }

    fn timed_out(&mut self) -> Option<Ended> {
        if self.download.is_some() {
            return Some(self.dropped()); // nothing arrived for the stall timeout
        }
        if !self.keys.has_session() {
            return Some(Ended::Outcome(Outcome::Unavailable));
        }
        let number = self.current.and_then(|id| self.attempts.get(&id)).map_or(0, |a| a.number);
        if number == 1 {
            self.ask_relay();
            return None;
        }
        Some(Ended::Outcome(Outcome::Failed))
    }

    fn ask_relay(&mut self) {
        let Some(sid) = self.sid.clone() else { return };
        self.deadline = self.now() + RELAY_TIMEOUT;
        self.current = None;
        self.send_host("relay_credentials", json!({ "req": RELAY_REQ, "sid": sid }));
    }

    fn send_host(&self, kind: &str, fields: Value) {
        if let Some(socket) = &self.socket {
            socket.send_text(&encode(kind, object(fields)));
        }
    }

    /// A setup payload to the sender, sealed as the opener.
    fn send(&self, message: Value) {
        let (Some(sid), Some(sealed)) = (&self.sid, self.keys.seal_message(&object(message), SIDE_OPENER)) else {
            return;
        };
        if sealed.len() <= PAYLOAD_MAX {
            self.send_host("sig_msg", json!({ "sid": sid, "payload": b64::encode_url(&sealed) }));
        }
    }

    fn host_message(&mut self, text: &str) -> Option<Ended> {
        let message: Value = serde_json::from_str(text).ok()?;
        match message.get("type").and_then(Value::as_str)? {
            "challenge" if self.sid.is_none() => {
                let hello = json!({ "t": "hello", "v": 1, "n": b64::encode_url(&self.opener_nonce) });
                let sealed = self.keys.seal_message(&object(hello), SIDE_OPENER)?;
                let link_id = b64::encode_url(&self.keys.link_id);
                self.send_host(
                    "link_open",
                    json!({ "req": 1, "link_id": link_id, "payload": b64::encode_url(&sealed) }),
                );
                None
            }
            "sig_opened" => {
                if message.get("link_ended").and_then(Value::as_str).is_some() {
                    return Some(Ended::Outcome(Outcome::Ended));
                }
                let sid = message.get("sid").and_then(Value::as_str).filter(|s| b64::decode_url(s, 16).is_some());
                let online = message.get("owner_online") == Some(&Value::Bool(true));
                match sid.filter(|_| online) {
                    Some(sid) => {
                        self.sid = Some(sid.to_owned());
                        None
                    }
                    // The sender's computer is not connected now: said at once rather than waited for.
                    None => Some(Ended::Outcome(Outcome::Unavailable)),
                }
            }
            "sig_refused" => Some(Ended::Outcome(Outcome::Unavailable)),
            "sig_closed" => self.download.is_none().then_some(Ended::Outcome(Outcome::Unavailable)),
            "sig_msg" => {
                let payload = b64::decode_value(message.get("payload"), 0)?;
                self.payload(&payload)
            }
            "relay_credentials_result" => self.relay_credentials(&message),
            "relay_refused" => (self.download.is_none()).then_some(Ended::Outcome(Outcome::Failed)),
            _ => None,
        }
    }

    fn payload(&mut self, payload: &[u8]) -> Option<Ended> {
        let message = self.keys.open_message(payload, SIDE_SENDER)?;
        let kind = message.get("t").and_then(Value::as_str).unwrap_or_default();
        if kind == "end" {
            return Some(Ended::Outcome(outcome_for(message.get("reason").and_then(Value::as_str))));
        }
        if !self.keys.has_session() {
            let sender: Option<[u8; NONCE_LENGTH]> = b64::decode_array(message.get("n"));
            let echoed = message.get("o").and_then(Value::as_str) == Some(&b64::encode_url(&self.opener_nonce));
            let sender = sender.filter(|_| kind == "challenge" && echoed)?;
            self.keys.set_nonces(self.opener_nonce, sender);
            let proof = self.keys.proof()?;
            self.send(json!({ "t": "proof", "mac": b64::encode_url(&proof) }));
            return self.open_attempt(1, None).err();
        }
        let current = self.current?;
        let attempt = self.attempts.get_mut(&current)?;
        if message.get("a").and_then(Value::as_u64) != Some(u64::from(attempt.number)) {
            return None;
        }
        match (kind, message.get("sdp").and_then(Value::as_str)) {
            ("answer", Some(sdp)) if !attempt.answered => {
                let description = Description::parse(sdp).ok()?;
                attempt.connection.apply_answer(sdp, &description.fingerprint).ok()?;
                attempt.answered = true;
                for line in std::mem::take(&mut attempt.held) {
                    let _ = attempt.connection.add_remote_candidate(&line, remote_technique(&line));
                }
            }
            ("cand", _) => {
                let lines = message.get("c").and_then(Value::as_array).cloned().unwrap_or_default();
                for line in lines.iter().take(64).filter_map(|c| c.get(0).and_then(Value::as_str)) {
                    if attempt.answered {
                        let _ = attempt.connection.add_remote_candidate(line, remote_technique(line));
                    } else if attempt.held.len() < 64 {
                        attempt.held.push(line.to_owned());
                    }
                }
            }
            _ => {}
        }
        None
    }

    fn relay_credentials(&mut self, message: &Value) -> Option<Ended> {
        if self.download.is_some() || message.get("req").and_then(Value::as_u64) != Some(RELAY_REQ) {
            return None;
        }
        let uris: Vec<String> = message
            .get("ice_servers")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(|u| u.as_str().map(str::to_owned)).collect())
            .unwrap_or_default();
        let credentials = (|| {
            Some(RelayCredentials {
                turn_uri: szfriends_online::driver::context::first_turn_over_udp(&uris)?,
                username: message.get("username")?.as_str()?.to_owned(),
                credential: message.get("credential")?.as_str()?.to_owned(),
                expires: message.get("expires")?.as_f64()?,
            })
        })();
        let Some(credentials) = credentials else { return Some(Ended::Outcome(Outcome::Failed)) };
        self.open_attempt(2, Some(credentials)).err()
    }

    /// Opens attempt `number`, dropping any earlier one; the error is how the setup ends when none can be made.
    fn open_attempt(&mut self, number: u8, relay: Option<RelayCredentials>) -> Result<(), Ended> {
        for (_, mut old) in self.attempts.drain() {
            old.connection.close();
        }
        let id = u64::from(number) | (self.generation << 8);
        let mut transport = if self.host.loopback { TransportConfig::loopback() } else { TransportConfig::default() };
        transport.links_use_local_addresses = self.host.loopback;
        let request = Request {
            purpose: Purpose::Link,
            role: Role::Offerer,
            kind: if relay.is_some() { Kind::Relay } else { Kind::Direct },
            peer: self.keys.link_id.to_vec(),
            stun_uri: if relay.is_some() { None } else { numeric_stun(&self.host.stun, self.host.loopback) },
            relay: relay.clone(),
            local_port: 0,
            remote_offer: None,
        };
        let events = self.events.clone();
        let forward: szfriends_online::transport::connection::Forward = Arc::new(move |id, event| {
            let handle: Handle = Box::new(move |connection: &mut Connection| connection.handle(event));
            let _ = events.send(Event::Connection(id, handle));
        });
        let notice: Arc<dyn Fn() + Send + Sync> = Arc::new(|| {});
        let connection = Connection::open(id, &request, &transport, forward, notice, wall())
            .map_err(|_| Ended::Outcome(Outcome::Failed))?;
        let attempt = Attempt {
            number,
            relay: relay.is_some(),
            connection,
            mid: "0".into(),
            described: false,
            answered: false,
            outgoing: Vec::new(),
            held: Vec::new(),
            local_ended: false,
            end_sent: false,
        };
        self.attempts.insert(id, attempt);
        self.current = Some(id);
        self.deadline = self.now() + if relay.is_some() { RELAY_TIMEOUT } else { DIRECT_TIMEOUT };
        Ok(())
    }

    fn connection_event(&mut self, id: u64, handle: Handle) -> Option<Ended> {
        let attempt = self.attempts.get_mut(&id)?;
        let events = handle(&mut attempt.connection);
        for event in events {
            if let Some(ended) = self.conn_event(id, event) {
                return Some(ended);
            }
        }
        self.flush();
        None
    }

    fn conn_event(&mut self, id: u64, event: ConnEvent) -> Option<Ended> {
        let attempt = self.attempts.get_mut(&id)?;
        match event {
            ConnEvent::Description { sdp, .. } => {
                attempt.mid = Description::parse(&sdp).map_or_else(|_| "0".to_owned(), |d| d.mid);
                attempt.described = true;
                let (number, relay) = (attempt.number, attempt.relay);
                self.send(json!({ "t": "offer", "a": number, "relay": relay, "sdp": sdp }));
            }
            ConnEvent::Candidate { line, .. } => attempt.outgoing.push((line, attempt.mid.clone())),
            ConnEvent::GatheringDone => attempt.local_ended = true,
            ConnEvent::Stream { stream, .. } => {
                if self.download.is_some() {
                    stream.writer.close();
                    return None;
                }
                let key = self.keys.content_key(attempt.number)?;
                // The host is no longer needed: the sid ends, and so does every other attempt.
                let others: Vec<u64> = self.attempts.keys().copied().filter(|other| *other != id).collect();
                for other in others {
                    if let Some(mut old) = self.attempts.remove(&other) {
                        old.connection.close();
                    }
                }
                if let Some(sid) = self.sid.take() {
                    self.send_host("sig_close", json!({ "sid": sid }));
                }
                let events = self.events.clone();
                let incoming = stream.incoming;
                let _ = std::thread::Builder::new().name("szfriends-link-in".into()).spawn(move || {
                    for input in incoming {
                        let closed = input == StreamInput::Closed;
                        if events.send(Event::Stream(input)).is_err() || closed {
                            return;
                        }
                    }
                    let _ = events.send(Event::Stream(StreamInput::Closed));
                });
                self.download = Some(Download::new(stream.writer, key));
                self.deadline = self.now() + STALL_TIMEOUT;
            }
            ConnEvent::Failed(_) | ConnEvent::StreamClosed => {
                if self.download.is_some() {
                    return Some(self.dropped());
                }
                if self.current == Some(id) {
                    // The opener moves on at once rather than waiting out its timer.
                    return if attempt.number == 1 {
                        self.ask_relay();
                        None
                    } else {
                        Some(Ended::Outcome(Outcome::Failed))
                    };
                }
            }
            ConnEvent::RouteChanged(_) => {}
        }
        None
    }

    /// Local candidates go in batches, each attempt's after its description, and its end after its last batch.
    fn flush(&mut self) {
        if self.download.is_some() || self.sid.is_none() {
            return;
        }
        for message in candidate_messages(self.attempts.values_mut()) {
            self.send(message);
        }
    }

    fn record(&mut self, progress: &mut Progress, sink: &Sink, record: &[u8]) -> Option<Ended> {
        let download = self.download.as_mut()?;
        self.deadline = self.start.elapsed().as_secs_f64() + STALL_TIMEOUT;
        match download.record(progress, record, sink.as_ref()) {
            Step::Continue => None,
            Step::Ended(outcome) => Some(Ended::Outcome(outcome)),
        }
    }

    fn close(&mut self) {
        if let Some(download) = self.download.take() {
            download.close();
        }
        if let Some(sid) = self.sid.take() {
            self.send_host("sig_close", json!({ "sid": sid }));
        }
        for (_, mut attempt) in self.attempts.drain() {
            attempt.connection.close();
        }
        if let Some(socket) = self.socket.take() {
            socket.close();
        }
    }
}
