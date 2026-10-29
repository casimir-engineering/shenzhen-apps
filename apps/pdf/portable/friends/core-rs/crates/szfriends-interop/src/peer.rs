//! The Rust peer: `szfriends-core`'s channel, chunk flow and store on loopback TCP, driven by the same JSON commands
//! as the Objective-C peer (`tools/objc-session-peer`) and reporting the same JSON events (`crate::Peer`). One thread
//! owns every session and the store, as the helper's queue does; links feed it through a channel.

use std::collections::{HashMap, HashSet};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_core::identity::Identity;
use szfriends_core::session::{
    monotonic_now, transfer_liveness, ChannelConfig, ChannelIdentity, ChunkReceiver, ChunkSender, Event,
    HandshakeOptions, SecureChannel, SessionError,
};
use szfriends_core::store::{Person, Relation, Store, TransferRecord};
use szfriends_core::wire::{tag, CloseReason, Fields, Frame, Pattern, RouteMethod};

use crate::link::{Link, LinkEvent};
use crate::{hex_bytes, Peer};

pub(crate) enum Input {
    Command(Value, Sender<Value>),
    Accepted(TcpStream),
    Link(LinkEvent),
    Online(szfriends_online::OnlineEvent),
}

#[derive(Default)]
struct Policy {
    friends: HashSet<[u8; 32]>,
    tokens: HashSet<Vec<u8>>,
    /// Our own other devices, which IK admits like friends (`devices.rs`).
    own_devices: HashSet<[u8; 32]>,
}

pub(crate) struct Outgoing {
    pub(crate) sender: ChunkSender,
    pub(crate) record: TransferRecord,
    pub(crate) done_sent: bool,
}

pub(crate) struct Session {
    pub(crate) channel: SecureChannel,
    link: Link,
    pub(crate) conversation: Option<String>,
    pub(crate) senders: HashMap<String, Outgoing>,
    pub(crate) receivers: HashMap<String, ChunkReceiver>,
    /// When received bytes not yet reported must be flushed (`flows.rs`).
    pub(crate) flush_due: Option<std::time::Instant>,
    finished: bool,
}

pub(crate) struct State {
    identity: Identity,
    pub(crate) store: Store,
    policy: Arc<Mutex<Policy>>,
    public_profile: Option<Fields>,
    rekey_after: Option<u64>,
    pub(crate) sessions: HashMap<u64, Session>,
    next_session: u64,
    input: Sender<Input>,
    events: Sender<Value>,
    pub(crate) online: Option<crate::online::OnlinePart>,
    pub(crate) devices: crate::devices::Devices,
}

/// A Rust peer with its own state directory (a temporary home) and identity, listening only on loopback.
pub struct RustPeer {
    input: Sender<Input>,
    events: Receiver<Value>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl std::fmt::Debug for RustPeer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RustPeer")
    }
}

impl RustPeer {
    pub fn start(home: PathBuf, identity: Identity) -> Self {
        let (input, inbox) = channel();
        let (events_tx, events) = channel();
        let mut store = Store::open(&home).expect("the peer's store opens");
        store.record_identity(&identity.public_key()).expect("a fresh store records its identity");
        let devices = crate::devices::Devices::new(&identity, &home);
        let state = State {
            identity,
            store,
            policy: Arc::default(),
            public_profile: None,
            rekey_after: None,
            sessions: HashMap::new(),
            next_session: 1,
            input: input.clone(),
            events: events_tx,
            online: None,
            devices,
        };
        let thread = std::thread::spawn(move || run(state, inbox));
        Self { input, events, thread: Some(thread) }
    }
}

/// The peer's thread stops and closes its store before the peer is gone, so its temporary home can be removed
/// (Windows keeps an open database's files; its own sessions keep the thread's inbox open otherwise).
impl Drop for RustPeer {
    fn drop(&mut self) {
        let (reply, answer) = channel();
        if self.input.send(Input::Command(json!({ "cmd": "quit" }), reply)).is_ok() {
            let _ = answer.recv_timeout(Duration::from_secs(30));
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Peer for RustPeer {
    fn command(&mut self, command: Value) -> Value {
        let (reply, answer) = channel();
        self.input.send(Input::Command(command, reply)).expect("the peer runs");
        answer.recv_timeout(Duration::from_secs(60)).expect("the peer answers")
    }

    fn next_event(&mut self, timeout: Duration) -> Option<Value> {
        self.events.recv_timeout(timeout).ok()
    }
}

fn run(mut state: State, inbox: Receiver<Input>) {
    loop {
        let now = monotonic_now();
        let wait = state
            .sessions
            .values()
            .filter_map(|s| s.channel.poll_timeout())
            .min()
            .map_or(Duration::from_millis(50), |at| at.saturating_sub(now).min(Duration::from_millis(50)));
        match inbox.recv_timeout(wait) {
            Ok(Input::Command(command, reply)) => {
                let quit = command["cmd"] == "quit";
                let answer = state.command(&command);
                let _ = reply.send(answer);
                if quit {
                    return;
                }
            }
            Ok(Input::Accepted(stream)) => state.accept(stream),
            Ok(Input::Link(event)) => state.link_event(event),
            Ok(Input::Online(event)) => crate::online::event(&mut state, event),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        state.service_all();
    }
}

fn hex(bytes: &[u8]) -> String {
    hex::encode(bytes)
}

fn key(value: &Value) -> Option<[u8; 32]> {
    value.as_str().and_then(hex_bytes).and_then(|b| b.try_into().ok())
}

impl State {
    pub(crate) fn emit(&self, event: Value) {
        let _ = self.events.send(event);
    }

    fn command(&mut self, command: &Value) -> Value {
        let session = command["session"].as_u64().unwrap_or(0);
        let now = monotonic_now();
        match command["cmd"].as_str().unwrap_or_default() {
            "hello" => json!({
                "identity_key": hex(&self.identity.public_key()),
                "static_key": hex(&self.identity.static_public_key()),
            }),
            "listen" => self.listen(command),
            "public_profile" => {
                let mut fields = Fields::new();
                fields.insert(tag::NAME, command["name"].as_str().unwrap_or_default().as_bytes().to_vec());
                self.public_profile = Some(fields);
                json!({})
            }
            "add_friend" => self.add_friend(command),
            "issue_token" => {
                let token = command["token"].as_str().and_then(hex_bytes).unwrap_or_default();
                self.policy.lock().unwrap().tokens.insert(token);
                json!({})
            }
            "set_rekey" => {
                self.rekey_after = command["bytes"].as_u64();
                json!({})
            }
            "dial" => self.dial(command),
            "send" => {
                let frame = command["frame"].as_str().and_then(hex_bytes).and_then(|b| Frame::decode(&b).ok());
                let sent = match (frame, self.sessions.get_mut(&session)) {
                    (Some(frame), Some(s)) => s.channel.send_frame(&frame, now),
                    _ => false,
                };
                json!({ "sent": sent })
            }
            "code" => {
                if let Some(s) = self.sessions.get_mut(&session) {
                    s.channel.run_code_exchange(now);
                }
                json!({})
            }
            "close" => {
                let reason = command["reason"].as_u64().and_then(|r| CloseReason::from_byte(r as u8));
                if let Some(s) = self.sessions.get_mut(&session) {
                    s.channel.close_with_reason(reason.unwrap_or(CloseReason::Normal), now);
                }
                json!({})
            }
            "abort" => {
                if let Some(s) = self.sessions.get_mut(&session) {
                    s.link.abort();
                }
                json!({})
            }
            "request_by_id" => self.request_by_id(session, command),
            "send_file" => self.send_file(session, command),
            "transfer" => self.transfer(command),
            "online" => crate::online::start(self, command, self.input.clone()),
            "reach" => crate::online::reach(self, command),
            "block_direct" => crate::online::block_direct(self, command),
            "serve_link" => crate::online::serve_link(self, command),
            "link_held" => crate::online::link_held(self),
            "quit" => {
                crate::online::stop(self);
                json!({})
            }
            other => self
                .device_command(other, command)
                .unwrap_or_else(|| json!({ "error": format!("{other} failed or is unknown") })),
        }
    }

    /// On loopback, or on every interface with `"any": true` (the device runs of `tools/transfer-devices.sh`).
    fn listen(&mut self, command: &Value) -> Value {
        let address = if command["any"] == true { "0.0.0.0:0" } else { "127.0.0.1:0" };
        let listener = TcpListener::bind(address).expect("a port");
        let port = listener.local_addr().expect("bound").port();
        let input = self.input.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                if input.send(Input::Accepted(stream)).is_err() {
                    return;
                }
            }
        });
        json!({ "port": port })
    }

    fn add_friend(&mut self, command: &Value) -> Value {
        let (Some(identity), Some(static_key)) = (key(&command["identity_key"]), key(&command["static_key"])) else {
            return json!({ "error": "bad keys" });
        };
        let mut person = match self.store.person_with_identity_key(&identity) {
            Ok(Some(person)) => person,
            _ => Person::new(Relation::Friend),
        };
        person.relation = Relation::Friend;
        person.identity_key = Some(identity);
        person.static_key = Some(static_key);
        person.name = command["name"].as_str().map(str::to_owned);
        if let Err(error) = self.store.save_person(&person) {
            return json!({ "error": error.to_string() });
        }
        self.policy.lock().unwrap().friends.insert(identity);
        json!({ "conversation": person.conversation_id })
    }

    fn channel_config(&self) -> ChannelConfig {
        let mut config = ChannelConfig::default();
        if let Some(bytes) = self.rekey_after {
            config.rekey_after_bytes = bytes;
        }
        config
    }

    fn new_session(&mut self, channel: SecureChannel, stream: TcpStream) -> u64 {
        let id = self.next_id();
        let link = Link::start(id, stream, self.input.clone(), Input::Link).expect("the link starts");
        self.insert_session(id, channel, link);
        id
    }

    pub(crate) fn next_id(&mut self) -> u64 {
        let id = self.next_session;
        self.next_session += 1;
        id
    }

    pub(crate) fn input_sender(&self) -> Sender<Input> {
        self.input.clone()
    }

    pub(crate) fn config(&self) -> ChannelConfig {
        self.channel_config()
    }

    pub(crate) fn identity_ref(&self) -> &Identity {
        &self.identity
    }

    pub(crate) fn identity_copy(&self) -> Identity {
        Identity::from_secret_item(&self.identity.secret_item()).expect("its own item")
    }

    pub(crate) fn add_policy_friend(&mut self, key: [u8; 32]) {
        self.policy.lock().unwrap().friends.insert(key);
    }

    pub(crate) fn insert_session(&mut self, id: u64, channel: SecureChannel, link: Link) {
        let session = Session {
            channel,
            link,
            conversation: None,
            senders: HashMap::new(),
            receivers: HashMap::new(),
            flush_due: None,
            finished: false,
        };
        self.sessions.insert(id, session);
    }

    pub(crate) fn dial(&mut self, command: &Value) -> Value {
        let pattern = match command["pattern"].as_str() {
            Some("XX") => Pattern::XX,
            Some("IK") => Pattern::IK,
            _ => Pattern::NN,
        };
        // The route class this side declares as the initiator (it sets chunk size and window); LAN by default.
        let route = match command["route"].as_str() {
            Some("p2p_wifi") => RouteMethod::PeerToPeerWifi,
            Some("bluetooth") => RouteMethod::Bluetooth,
            Some("internet") => RouteMethod::Internet,
            Some("relay") => RouteMethod::Relay,
            _ => RouteMethod::Lan,
        };
        let mut options = HandshakeOptions::new(pattern, route);
        options.remote_static = key(&command["remote_static"]);
        options.expected_identity = key(&command["expected_identity"]);
        options.request_token = command["token"].as_str().and_then(hex_bytes);
        let Ok(stream) = TcpStream::connect((
            command["host"].as_str().unwrap_or("127.0.0.1"),
            command["port"].as_u64().unwrap_or(0) as u16,
        )) else {
            return json!({ "error": "connect failed" });
        };
        let mut channel = SecureChannel::initiator(ChannelIdentity::new(&self.identity), options);
        channel.set_config(self.channel_config());
        channel.set_local_attestation(command["attestation"].as_str().and_then(hex_bytes));
        if pattern == Pattern::XX {
            channel.set_profile_decision(Box::new(|_| true));
        }
        let id = self.new_session(channel, stream);
        let now = monotonic_now();
        self.sessions.get_mut(&id).expect("just made").channel.start(now);
        json!({ "session": id })
    }

    fn accept(&mut self, stream: TcpStream) {
        let mut channel = self.responder_channel();
        channel.set_config(self.channel_config());
        let id = self.new_session(channel, stream);
        let session = self.sessions.get_mut(&id).expect("just made");
        session.channel.start(monotonic_now());
        self.emit(json!({ "event": "accepted", "session": id }));
    }

    /// A responder admitting IK from friends and token holders, as the helper's listeners do.
    pub(crate) fn responder_channel(&self) -> SecureChannel {
        let policy = self.policy.clone();
        let decide = Box::new(move |key: Option<&[u8; 32]>, pattern: Pattern, token: Option<&[u8]>| {
            let policy = policy.lock().unwrap();
            match pattern {
                Pattern::IK => {
                    key.is_some_and(|k| policy.friends.contains(k) || policy.own_devices.contains(k))
                        || token.is_some_and(|t| policy.tokens.contains(t))
                }
                Pattern::XX | Pattern::NN => true,
            }
        });
        let identity = ChannelIdentity::new(&self.identity);
        SecureChannel::responder(identity, self.public_profile.clone(), decide)
    }

    fn link_event(&mut self, event: LinkEvent) {
        let now = monotonic_now();
        match event {
            LinkEvent::Bytes(id, bytes) => {
                if let Some(s) = self.sessions.get_mut(&id) {
                    s.channel.receive(&bytes, now);
                }
            }
            LinkEvent::Eof(id) => {
                if let Some(s) = self.sessions.get_mut(&id) {
                    s.channel.link_closed_by_peer();
                }
            }
            LinkEvent::Written(id) => {
                if let Some(s) = self.sessions.get_mut(&id) {
                    s.channel.write_completed(now);
                }
            }
        }
    }

    fn service_all(&mut self) {
        let ids: Vec<u64> = self.sessions.keys().copied().collect();
        for id in ids {
            self.service(id);
        }
        self.sessions.retain(|_, s| !s.finished);
    }

    /// Timers, then writes and events until the session has nothing more to say, then the transfers' next chunks.
    fn service(&mut self, id: u64) {
        let now = monotonic_now();
        if let Some(s) = self.sessions.get_mut(&id) {
            let (keepalive, watch) = transfer_liveness(s.senders.values().map(|o| &o.sender), s.receivers.values());
            s.channel.set_liveness(keepalive, watch, now);
            s.channel.handle_timeout(now);
        }
        loop {
            let Some(s) = self.sessions.get_mut(&id) else { return };
            while let Some(write) = s.channel.poll_transmit() {
                s.link.write(write.bytes);
            }
            let Some(event) = s.channel.poll_event() else { break };
            self.handle_event(id, event);
        }
        self.flush_if_due(id);
        self.pump(id);
        let Some(s) = self.sessions.get_mut(&id) else { return };
        while let Some(write) = s.channel.poll_transmit() {
            s.link.write(write.bytes);
        }
        if s.channel.is_closed() && !s.finished {
            s.finished = true;
            s.link.finish();
        }
    }

    fn handle_event(&mut self, id: u64, event: Event) {
        match event {
            Event::Established => {
                self.established(id);
                self.devices_established(id);
            }
            Event::Frame(frame) => self.frame(id, frame),
            Event::Code(result) => match result {
                Ok(code) => self.emit(json!({ "event": "code", "session": id, "code": code })),
                Err(error) => self.emit(json!({ "event": "code", "session": id, "error": error.code() })),
            },
            Event::Closed(error) => {
                self.devices_closed(id);
                let _ = self.store.flush_progress();
                let reason = match error {
                    Some(SessionError::PeerClosed(reason)) => json!(reason),
                    _ => Value::Null,
                };
                let code = error.map_or(0, SessionError::code);
                let rekeys = self.sessions.get(&id).map(|s| s.channel.rekeys()).unwrap_or_default();
                let rekeys = [rekeys.0, rekeys.1];
                self.emit(
                    json!({ "event": "closed", "session": id, "error": code, "reason": reason, "rekeys": rekeys }),
                );
            }
        }
    }

    pub(crate) fn close_for_protocol(&mut self, id: u64) {
        if let Some(s) = self.sessions.get_mut(&id) {
            s.channel.close_with_reason(CloseReason::ProtocolError, monotonic_now());
        }
    }

    fn transfer(&mut self, command: &Value) -> Value {
        match self.store.transfer(command["id"].as_str().unwrap_or_default()) {
            Ok(Some(record)) => json!({
                "state": record.state as i64,
                "verified": record.verified_bytes,
                "received_path": record.received_path.map(|p| p.to_string_lossy().into_owned()),
            }),
            _ => json!({ "error": "no such transfer" }),
        }
    }

    pub(crate) fn set_own_devices(&mut self, keys: Vec<[u8; 32]>) {
        self.policy.lock().unwrap().own_devices = keys.into_iter().collect();
    }

    pub(crate) fn peer_identity(&self) -> &Identity {
        &self.identity
    }
}
