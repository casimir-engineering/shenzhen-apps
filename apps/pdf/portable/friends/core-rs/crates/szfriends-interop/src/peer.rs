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
    pub(crate) file: Option<szfriends_core::store::disk::OutgoingFile>,
    pub(crate) buffer: Vec<u8>,
}

pub(crate) struct Session {
    pub(crate) channel: SecureChannel,
    link: Link,
    pub(crate) conversation: Option<String>,
    pub(crate) senders: HashMap<String, Outgoing>,
    pub(crate) receivers: HashMap<String, ChunkReceiver>,
    /// When received bytes not yet reported must be flushed (`flows.rs`).
    pub(crate) flush_due: Option<std::time::Instant>,
    /// Files going by blocks on this session (`blocks.rs`).
    pub(crate) blocks: crate::blocks::Blocks,
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
    /// Lane groups (ADR 0018 § 6, `lanes.rs`).
    pub(crate) lanes: crate::lanes::Lanes,
    /// While a store batch is open nothing is written to a link: what it acknowledges is committed first.
    holding: bool,
    /// An input taken while gathering link bytes into a batch, handled next.
    later: std::collections::VecDeque<Input>,
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
            lanes: Default::default(),
            holding: false,
            later: std::collections::VecDeque::new(),
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
        // What arrived is handled in one store batch (ADR 0018 § 9.3), committed before any byte of what it
        // acknowledges is written, as the Rust helper does. One input per batch: a TCP read carries many frames.
        let next = match state.later.pop_front() {
            Some(input) => Ok(input),
            None => inbox.recv_timeout(wait),
        };
        state.holding = state.store.begin_batch().is_ok();
        match next {
            Ok(Input::Command(command, reply)) => {
                let quit = command["cmd"] == "quit";
                let answer = state.command(&command);
                let _ = reply.send(answer);
                if quit {
                    state.end_batch();
                    return;
                }
            }
            Ok(Input::Accepted(stream)) => state.accept(stream),
            Ok(Input::Link(event)) => {
                state.link_event(event);
                // Bytes already read from the links join the same batch, so a burst of small files costs one flush.
                let mut deferred = None;
                for _ in 0..64 {
                    match inbox.try_recv() {
                        Ok(Input::Link(event)) => state.link_event(event),
                        Ok(other) => {
                            deferred = Some(other);
                            break;
                        }
                        Err(_) => break,
                    }
                }
                if let Some(input) = deferred {
                    state.later.push_back(input);
                }
            }
            Ok(Input::Online(event)) => crate::online::event(&mut state, event),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                state.end_batch();
                return;
            }
        }
        state.service_all();
        state.end_batch();
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
                "session_minor": szfriends_core::wire::consts::SESSION_MINOR,
                // `dial` takes "lane_of" (ADR 0018 § 6), and lanes are admitted.
                "lanes": true,
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
            "send_files" => self.send_files(session, command),
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
            // What each group's scheduler and each file sent by blocks hold now (the bench asks when a transfer
            // stalls, for its transcripts).
            "debug" => {
                let groups: serde_json::Map<String, Value> = self
                    .lanes
                    .groups
                    .iter()
                    .map(|(head, group)| (head.to_string(), json!(format!("{:?}", group.scheduler))))
                    .collect();
                let senders: serde_json::Map<String, Value> = self
                    .sessions
                    .iter()
                    .flat_map(|(id, session)| {
                        session.blocks.senders.iter().map(move |(transfer, send)| {
                            let queues: serde_json::Map<String, Value> =
                                send.lanes.iter().map(|(lane, q)| (lane.to_string(), json!(q.len()))).collect();
                            (format!("{id}:{transfer}"), json!({ "queued": queues, "state": send.debug_state() }))
                        })
                    })
                    .collect();
                json!({ "groups": groups, "senders": senders, "head_of": format!("{:?}", self.lanes.head_of) })
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
        let mut config =
            ChannelConfig { capabilities: szfriends_core::session::local_capabilities(true), ..Default::default() };
        // The helper's test switches (ADR 0018 § 9.2, § 9.4), so the bench measures with and without.
        let off = |name: &str| std::env::var_os(name).is_some_and(|v| v == "0");
        use szfriends_core::wire::consts;
        if off("SZFRIENDS_TEST_AES_LANES") {
            config.capabilities &= !consts::CAPABILITY_AES_LANES;
        }
        if off("SZFRIENDS_TEST_COMPRESSED_PARTS") {
            config.capabilities &= !(consts::CAPABILITY_COMPRESSED_PARTS | consts::CAPABILITY_LZ4_PARTS);
        }
        // A phone without zstd: LZ4 only.
        if off("SZFRIENDS_TEST_ZSTD") {
            config.capabilities &= !consts::CAPABILITY_COMPRESSED_PARTS;
        }
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
            blocks: crate::blocks::Blocks::default(),
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
        // A lane of a live fast session (ADR 0018 § 6): its token, reserved under a provisional id until the session
        // exists.
        let lane = command["lane_of"].as_u64().map(|head| (head, u64::MAX - self.next_session));
        if let Some((head, provisional)) = lane {
            match self.reserve_lane(head, provisional, route) {
                Some(token) => {
                    options.lane = Some(token);
                    // ADR 0018 § 9.2: AES-256-GCM when both first handshakes said hardware AES.
                    if self.sessions.get(&head).is_some_and(|s| s.channel.aes_lanes()) {
                        options.cipher = szfriends_core::wire::NoiseCipher::AesGcm;
                    }
                }
                None => return json!({ "error": "no lane: no fast group, or its limits" }),
            }
        }
        let Ok(stream) = TcpStream::connect((
            command["host"].as_str().unwrap_or("127.0.0.1"),
            command["port"].as_u64().unwrap_or(0) as u16,
        )) else {
            if let Some((head, provisional)) = lane {
                self.lane_dial_failed(head, provisional);
            }
            return json!({ "error": "connect failed" });
        };
        let mut channel = SecureChannel::initiator(ChannelIdentity::new(&self.identity), options);
        channel.set_config(self.channel_config());
        channel.set_local_attestation(command["attestation"].as_str().and_then(hex_bytes));
        if pattern == Pattern::XX {
            channel.set_profile_decision(Box::new(|_| true));
        }
        let id = self.new_session(channel, stream);
        if let Some((head, provisional)) = lane {
            self.lane_dialed(head, provisional, id);
        }
        let now = monotonic_now();
        self.sessions.get_mut(&id).expect("just made").channel.start(now);
        json!({ "session": id })
    }

    pub(crate) fn set_own_devices(&mut self, keys: Vec<[u8; 32]>) {
        self.policy.lock().unwrap().own_devices = keys.into_iter().collect();
    }

    pub(crate) fn peer_identity(&self) -> &Identity {
        &self.identity
    }
}

#[path = "peer_sessions.rs"]
mod sessions;
