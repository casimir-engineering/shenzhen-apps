//! The client-protocol server (PROTOCOL.md § Framing, § Handshake, § Replies and errors), whatever the transport:
//! one reader thread per connection, frames written whole under a lock, the hello and its handover request, protocol
//! errors ending the connection with a goodbye, and every other intent handed to the [`Presentation`]. Mirrors
//! `SZFriendsIPCServer.m`.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

use serde_json::{json, Value};
use szfriends_contract::framing::{encode, FramingError, LineReader, FRAME_MAX};
use szfriends_contract::handshake::{
    client_info, error_reply, goodbye, hello_versions, ok_reply, protocol_error_goodbye, protocol_unsupported, welcome,
    ClientInfo, GoodbyeReason, HelperFacts, Successor,
};
use szfriends_contract::ids::client_frame_id_is_valid;
use szfriends_contract::lifecycle::{
    embedded_helper_is_newer, handover_build_is_plausible, negotiate, PROTOCOL, PROTOCOL_MIN_MAJOR,
};

use crate::lifecycle::Event;
use crate::log;
use crate::presentation::Presentation;
use crate::transport::{Duplex, Listener, PeerInfo};

/// PROTOCOL.md § Limits.
pub const MAX_CONNECTIONS: usize = 64;
const MAX_OUTSTANDING: usize = 64;
const READ_CHUNK: usize = 64 * 1024;

/// Whether the process at the other end really carries the build it asks to hand over to.
pub type HandoverCheck = Box<dyn Fn(&PeerInfo, u64) -> bool + Send + Sync>;

struct ConnectionState {
    id: u64,
    stream: Arc<dyn Duplex>,
    peer: PeerInfo,
    /// Held while a frame is written, so frames never interleave; `true` once closed.
    writer: Mutex<bool>,
    client: Mutex<Option<ClientInfo>>,
    sent_disable: AtomicBool,
    outstanding: Mutex<HashSet<String>>,
    replied: Condvar,
}

/// One client connection, as the presentation sees it.
#[derive(Clone)]
pub struct Connection(Arc<ConnectionState>);

impl std::fmt::Debug for Connection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Connection").field("id", &self.0.id).field("peer", &self.0.peer).finish()
    }
}

impl Connection {
    pub fn id(&self) -> u64 {
        self.0.id
    }

    pub fn client(&self) -> Option<ClientInfo> {
        self.0.client.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn peer(&self) -> &PeerInfo {
        &self.0.peer
    }

    /// Writes one frame; `false` once the connection is closed or the frame cannot be sent.
    pub fn send(&self, frame: &Value) -> bool {
        let Ok(bytes) = encode(frame) else {
            log!("connection {}: a frame over the cap was not sent", self.0.id);
            return false;
        };
        let closed = self.0.writer.lock().unwrap_or_else(|e| e.into_inner());
        !*closed && self.0.stream.write_all(&bytes).is_ok()
    }

    /// Sends `frame` (a goodbye) and closes; the other end still reads what was written.
    pub fn send_and_close(&self, frame: &Value) {
        let mut closed = self.0.writer.lock().unwrap_or_else(|e| e.into_inner());
        if !*closed {
            if let Ok(bytes) = encode(frame) {
                let _ = self.0.stream.write_all(&bytes);
            }
            *closed = true;
        }
        drop(closed);
        self.0.stream.close();
        self.0.replied.notify_all();
    }

    fn close(&self) {
        *self.0.writer.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.0.stream.close();
        self.0.replied.notify_all();
    }

    fn is_closed(&self) -> bool {
        *self.0.writer.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// The one reply an intent gets. Dropped unanswered, it answers `internal`, so every intent is answered once.
pub struct Reply {
    connection: Connection,
    re: String,
    done: bool,
}

impl std::fmt::Debug for Reply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Reply").field("connection", &self.connection.0.id).field("re", &self.re).finish()
    }
}

impl Reply {
    pub fn ok(mut self, result: Value) {
        self.finish(ok_reply(&self.re, result));
    }

    /// `message` is display-ready text for the person, or `None` when the view has nothing useful to say.
    pub fn error(mut self, code: &str, message: Option<&str>, details: Value) {
        self.finish(error_reply(&self.re, code, message, details));
    }

    fn finish(&mut self, frame: Value) {
        self.done = true;
        let state = &self.connection.0;
        state.outstanding.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.re);
        self.connection.send(&frame);
        state.replied.notify_all();
    }
}

impl Drop for Reply {
    fn drop(&mut self) {
        if !self.done {
            log!("connection {}: intent {} left unanswered", self.connection.0.id, self.re);
            self.finish(error_reply(&self.re, "internal", None, json!({})));
        }
    }
}

struct Shared {
    presentation: Arc<dyn Presentation>,
    helper: HelperFacts,
    connections: Mutex<HashMap<u64, Connection>>,
    next_id: AtomicU64,
    events: Mutex<Sender<Event>>,
    successor: Mutex<Option<Successor>>,
    backs_handover: HandoverCheck,
}

/// The server: its connections and the lifecycle's view of them.
#[derive(Clone)]
pub struct Server(Arc<Shared>);

impl std::fmt::Debug for Server {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Server").field("connections", &self.connection_count()).finish()
    }
}

impl Server {
    pub fn new(
        presentation: Arc<dyn Presentation>,
        helper: HelperFacts,
        events: Sender<Event>,
        backs_handover: HandoverCheck,
    ) -> Self {
        Self(Arc::new(Shared {
            presentation,
            helper,
            connections: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(0),
            events: Mutex::new(events),
            successor: Mutex::new(None),
            backs_handover,
        }))
    }

    fn event(&self, event: Event) {
        let _ = self.0.events.lock().unwrap_or_else(|e| e.into_inner()).send(event);
    }

    /// Accepts from `listener` on a thread of its own until it is stopped.
    pub fn serve(&self, listener: Arc<dyn Listener>) -> thread::JoinHandle<()> {
        let server = self.clone();
        thread::Builder::new()
            .name("szfriends-accept".into())
            .spawn(move || loop {
                match listener.accept() {
                    Ok(Some((stream, peer))) => server.add(stream, peer),
                    Ok(None) => return,
                    Err(error) => {
                        log!("accept failed: {error}");
                        thread::sleep(std::time::Duration::from_millis(50));
                    }
                }
            })
            .expect("accept thread")
    }

    /// Serves one connection whose peer already passed the listener's checks.
    pub fn add(&self, stream: Arc<dyn Duplex>, peer: PeerInfo) {
        let id = self.0.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let connection = Connection(Arc::new(ConnectionState {
            id,
            stream,
            peer,
            writer: Mutex::new(false),
            client: Mutex::new(None),
            sent_disable: AtomicBool::new(false),
            outstanding: Mutex::new(HashSet::new()),
            replied: Condvar::new(),
        }));
        {
            let mut connections = self.0.connections.lock().unwrap_or_else(|e| e.into_inner());
            if connections.len() >= MAX_CONNECTIONS {
                drop(connections);
                connection.send_and_close(&goodbye(GoodbyeReason::TooManyClients, None, None));
                return;
            }
            connections.insert(id, connection.clone());
        }
        // Counted from accept, before its hello, so a slow first frame never sees the helper leave.
        self.event(Event::Connections { closed_after_disable: None });
        let server = self.clone();
        let spawned = thread::Builder::new().name(format!("szfriends-client-{id}")).spawn(move || {
            server.read_loop(&connection);
            connection.close();
            server.0.connections.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
            server.0.presentation.disconnected(id);
            let after_disable = connection.0.sent_disable.load(Ordering::SeqCst);
            server.event(Event::Connections { closed_after_disable: Some(after_disable) });
        });
        if spawned.is_err() {
            log!("no thread for connection {id}");
        }
    }

    /// Connections that keep the helper alive: all but those that sent `disable`.
    pub fn active_clients(&self) -> usize {
        let connections = self.0.connections.lock().unwrap_or_else(|e| e.into_inner());
        connections.values().filter(|c| !c.0.sent_disable.load(Ordering::SeqCst)).count()
    }

    pub fn connection_count(&self) -> usize {
        self.0.connections.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    /// The newest build a client asked to hand over to, once one did.
    pub fn successor(&self) -> Option<Successor> {
        self.0.successor.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn presentation(&self) -> &Arc<dyn Presentation> {
        &self.0.presentation
    }

    /// A goodbye to every connection, each closed after its goodbye is written.
    pub fn broadcast_goodbye(&self, reason: GoodbyeReason, successor: Option<&Successor>) {
        let frame = goodbye(reason, successor, None);
        let connections: Vec<Connection> =
            self.0.connections.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        for connection in connections {
            connection.send_and_close(&frame);
        }
    }

    fn read_loop(&self, connection: &Connection) {
        let mut reader = LineReader::new();
        let mut buffer = vec![0u8; READ_CHUNK];
        loop {
            let read = match connection.0.stream.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(read) => read,
            };
            let frames = match reader.push(&buffer[..read]) {
                Ok(frames) => frames,
                Err(FramingError::FrameTooLarge) => {
                    let details = json!({"max_frame_bytes": FRAME_MAX});
                    return self.protocol_error(connection, "frame_too_large", details);
                }
                Err(FramingError::BadFrame) => return self.protocol_error(connection, "bad_frame", json!({})),
            };
            for frame in frames {
                if !self.frame(connection, &frame) || connection.is_closed() {
                    return;
                }
            }
        }
    }

    fn protocol_error(&self, connection: &Connection, code: &str, details: Value) {
        log!("protocol error {code} on connection {}", connection.0.id);
        connection.send_and_close(&protocol_error_goodbye(code, details));
    }

    /// Handles one frame; `false` when the connection ends.
    fn frame(&self, connection: &Connection, frame: &Value) -> bool {
        let kind = frame["type"].as_str().filter(|t| !t.is_empty());
        let id = frame["id"].as_str().filter(|id| client_frame_id_is_valid(id));
        let (Some(kind), Some(id)) = (kind, id) else {
            self.protocol_error(connection, "bad_frame", json!({}));
            return false;
        };
        if connection.client().is_none() {
            if kind != "hello" {
                connection.send(&error_reply(id, "hello_required", None, json!({})));
                self.protocol_error(connection, "hello_required", json!({}));
                return false;
            }
            return self.hello(connection, frame, id);
        }
        if connection.0.outstanding.lock().unwrap_or_else(|e| e.into_inner()).contains(id) {
            // Two intents with one id would make their replies ambiguous.
            self.protocol_error(connection, "bad_frame", json!({"field": "id"}));
            return false;
        }
        match kind {
            "hello" => {
                connection.send(&error_reply(id, "not_allowed", None, json!({})));
            }
            "disable" => {
                connection.0.sent_disable.store(true, Ordering::SeqCst);
                connection.send(&ok_reply(id, json!({})));
                self.event(Event::Disable);
            }
            _ => {
                self.wait_for_room(connection);
                connection.0.outstanding.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned());
                let reply = Reply { connection: connection.clone(), re: id.to_owned(), done: false };
                self.0.presentation.intent(connection, frame, reply);
            }
        }
        true
    }

    /// Past 64 unanswered intents the connection stops being read until replies catch up.
    fn wait_for_room(&self, connection: &Connection) {
        let mut outstanding = connection.0.outstanding.lock().unwrap_or_else(|e| e.into_inner());
        while outstanding.len() >= MAX_OUTSTANDING && !connection.is_closed() {
            outstanding = connection.0.replied.wait(outstanding).unwrap_or_else(|e| e.into_inner());
        }
    }

    fn hello(&self, connection: &Connection, hello: &Value, id: &str) -> bool {
        let versions = match hello_versions(hello) {
            Ok(versions) => versions,
            Err(field) => return connection.send(&error_reply(id, "invalid_field", None, json!({"field": field}))),
        };
        // Read before negotiation: a newer app can always ask an older helper to step aside.
        let mut requested = false;
        if let Some(embedded) = &versions.embedded_helper {
            let own = &self.0.helper;
            if embedded_helper_is_newer(own.protocol, own.build_number, embedded.protocol, embedded.build_number)
                && self.handover_is_backed(connection, embedded.build_number)
            {
                let mut successor = self.0.successor.lock().unwrap_or_else(|e| e.into_inner());
                if successor.as_ref().is_none_or(|s| embedded.build_number > s.build_number) {
                    *successor =
                        Some(Successor { version: embedded.version.clone(), build_number: embedded.build_number });
                }
                requested = true;
            }
        }
        let scheduled = self.successor().is_some();
        let Some(negotiated) = negotiate(PROTOCOL, PROTOCOL_MIN_MAJOR, versions.protocol, versions.min_major) else {
            let [reply, bye] = protocol_unsupported(id, PROTOCOL.major, PROTOCOL_MIN_MAJOR, scheduled);
            connection.send(&reply);
            connection.send_and_close(&bye);
            if requested {
                self.event(Event::Handover);
            }
            return false;
        };
        let client = match client_info(hello, negotiated) {
            Ok(client) => client,
            Err(field) => return connection.send(&error_reply(id, "invalid_field", None, json!({"field": field}))),
        };
        let extras = self.0.presentation.welcome(&client);
        *connection.0.client.lock().unwrap_or_else(|e| e.into_inner()) = Some(client);
        let sent = connection.send(&welcome(id, negotiated, &self.0.helper, scheduled, extras));
        self.0.presentation.connected(connection);
        // After the welcome, so the asking client reads "scheduled" before any goodbye.
        if requested {
            self.event(Event::Handover);
        }
        sent
    }

    /// A handover goes only to a build that could follow ours and that the asking process really carries, so no
    /// client can make Friends step aside for a successor that never comes.
    fn handover_is_backed(&self, connection: &Connection, claimed: u64) -> bool {
        let own = self.0.helper.build_number;
        if !handover_build_is_plausible(own, claimed) {
            log!("handover refused: build {claimed} is not one that could follow {own}");
            return false;
        }
        if !(self.0.backs_handover)(&connection.0.peer, claimed) {
            log!("handover refused: the asking process does not carry build {claimed}");
            return false;
        }
        true
    }
}
