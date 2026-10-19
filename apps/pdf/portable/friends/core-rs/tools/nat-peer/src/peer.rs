//! One host of the NAT emulator's punching matrix (`tests/nat-emulator/SZFNATPeer.m`), with the Rust core: its online
//! driver, transport, order and NAT techniques in loopback test mode, behind an emulated NAT. The matrix runs it with
//! `DYLD_INSERT_LIBRARIES` naming the emulator's shim, so with `SZFNAT_INSIDE_PORT` set every socket it opens goes
//! through its NAT, exactly as the Objective-C peer's do.
//!
//! The same protocol as the Objective-C peer, so a pair can mix them: signalling on descriptor 3 (OPEN, MSG and
//! CLOSE frames per sid: type, u32be sid, u16be length, payload), relay credentials made as the host makes them,
//! "reach" on stdin, and on stdout one JSON object per line: ready, stream, data (the echo came back), relay (the
//! order asked for it) and ended, each with the attempt's technique log so far.

use std::collections::HashMap;
use std::io::{BufRead, Read, Write};
use std::net::SocketAddr;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use szfriends_identity::Identity;
use szfriends_online::driver::{Driver, DriverEvent, Friends, Input, OnlineFriend, SignalHost};
use szfriends_online::order::LogEntry;
use szfriends_online::transport::{ChannelStream, Route, StreamInput, TransportConfig};
use szfriends_wire::route::RouteMethod;

const OPEN: u8 = 1;
const MESSAGE: u8 = 2;
const CLOSE: u8 = 3;

enum Event {
    Driver(Input),
    Frame(u8, u32, Vec<u8>),
    Reach,
    Quit,
}

fn emit(event: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{event}");
    let _ = out.flush();
}

fn derive(seed: &[u8], label: &str) -> [u8; 32] {
    Sha256::new().chain_update(seed).chain_update(label.as_bytes()).finalize().into()
}

/// The signalling socket the matrix hands over as descriptor 3.
#[allow(unsafe_code)]
fn signal_socket() -> UnixStream {
    use std::os::fd::FromRawFd;
    // SAFETY: the matrix spawns this process with its end of a socket pair on descriptor 3, which nothing else here
    // opens, owns or closes; this is its only owner from now on.
    unsafe { UnixStream::from_raw_fd(3) }
}

struct OneFriend(OnlineFriend);

impl Friends for OneFriend {
    fn friend(&self, key: &[u8; 32]) -> Option<OnlineFriend> {
        (self.0.identity_key == *key).then(|| self.0.clone())
    }

    fn nearby_route(&self, _: &[u8; 32]) -> RouteMethod {
        RouteMethod::None
    }

    fn own_presence_secret(&self) -> Option<[u8; 32]> {
        None
    }
}

struct Channel {
    spoke: bool,
    closed: bool,
    far_ended: bool,
}

/// The host's connection setup, over descriptor 3, as `SZFNATChannel` does it.
struct Host {
    socket: UnixStream,
    channels: HashMap<u32, Channel>,
    next_sid: u32,
    opened: Vec<(u64, String)>,
    relays: Vec<(u64, Option<szfriends_online::transport::RelayCredentials>)>,
    turn: Option<(String, String)>,
}

impl Host {
    fn write(&mut self, kind: u8, sid: u32, payload: &[u8]) {
        let mut frame = vec![kind];
        frame.extend_from_slice(&sid.to_be_bytes());
        frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        frame.extend_from_slice(payload);
        let _ = self.socket.write_all(&frame);
    }
}

impl SignalHost for Host {
    fn open(&mut self, attempt: u64, _rdv_key: [u8; 32], payload: Vec<u8>) {
        let sid = self.next_sid;
        self.next_sid += 2;
        self.channels.insert(sid, Channel { spoke: true, closed: false, far_ended: false });
        self.write(OPEN, sid, &payload);
        self.opened.push((attempt, sid.to_string()));
    }

    fn send(&mut self, sid: &str, payload: &[u8]) -> bool {
        let Ok(number) = sid.parse::<u32>() else { return false };
        let Some(channel) = self.channels.get_mut(&number).filter(|c| !c.closed && !c.far_ended) else { return false };
        if payload.is_empty() || payload.len() > 4096 {
            return false;
        }
        channel.spoke = true;
        self.write(MESSAGE, number, payload);
        true
    }

    // As the host does: an end that never spoke leaves nothing behind for the other to notice.
    fn close(&mut self, sid: &str) {
        let Ok(number) = sid.parse::<u32>() else { return };
        let Some(channel) = self.channels.get_mut(&number).filter(|c| !c.closed) else { return };
        channel.closed = true;
        if channel.spoke && !channel.far_ended {
            self.write(CLOSE, number, &[]);
        }
    }

    fn request_relay(&mut self, attempt: u64, sid: &str) {
        let credentials = self.turn.as_ref().map(|(port, secret)| {
            let expires =
                std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs()) + 300;
            let username = format!("{expires}:szfnat{sid}");
            let mut mac = <Hmac<sha1::Sha1> as Mac>::new_from_slice(secret.as_bytes()).expect("any key");
            mac.update(username.as_bytes());
            szfriends_online::transport::RelayCredentials {
                turn_uri: format!("turn:127.0.0.1:{port}?transport=udp"),
                username,
                credential: szfriends_online::b64::encode_standard(&mac.finalize().into_bytes()),
                expires: expires as f64,
            }
        });
        self.relays.push((attempt, credentials));
    }
}

fn log_fields(entry: &LogEntry) -> serde_json::Map<String, Value> {
    let value = json!({
        "technique": entry.first_technique as u8, "tried": entry.techniques_tried,
        "seconds": entry.seconds_to_first_stream, "relay_requested": entry.relay_requested,
        "local_class": entry.local_class as u8, "remote_class": entry.remote_class as u8, "end": entry.end_reason as u8,
    });
    match value {
        Value::Object(map) => map,
        _ => serde_json::Map::new(),
    }
}

fn spawn_readers(socket: UnixStream, events: Sender<Event>) {
    let frames = events.clone();
    std::thread::spawn(move || {
        let mut socket = socket;
        loop {
            let mut header = [0u8; 7];
            if socket.read_exact(&mut header).is_err() {
                return;
            }
            let sid = u32::from_be_bytes([header[1], header[2], header[3], header[4]]);
            let mut payload = vec![0u8; usize::from(u16::from_be_bytes([header[5], header[6]]))];
            if socket.read_exact(&mut payload).is_err() || frames.send(Event::Frame(header[0], sid, payload)).is_err() {
                return;
            }
        }
    });
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if line.contains("reach") && events.send(Event::Reach).is_err() {
                return;
            }
        }
        let _ = events.send(Event::Quit);
    });
}

struct Peer {
    driver: Driver,
    host: Host,
    friend: [u8; 32],
    offerer: bool,
    reached_at: Option<Instant>,
    stream: Option<(ChannelStream, Route)>,
    ping: Option<Vec<u8>>,
    echo: Vec<u8>,
    reported: (bool, bool),
}

impl Peer {
    fn log(&self) -> Option<LogEntry> {
        self.driver.attempts().next().map(|a| a.order.log_entry())
    }

    fn elapsed(&self) -> f64 {
        self.reached_at.map_or(-1.0, |at| at.elapsed().as_secs_f64())
    }

    /// What the host's side of the setup gave back, and what the driver produced.
    fn settle(&mut self) {
        for (attempt, sid) in std::mem::take(&mut self.host.opened) {
            self.driver.sid_opened(attempt, Some(sid), &mut self.host);
        }
        for (attempt, credentials) in std::mem::take(&mut self.host.relays) {
            self.driver.relay_credentials(attempt, credentials, &mut self.host);
        }
        if let Some(entry) = self.log() {
            if entry.relay_requested && !self.reported.1 {
                self.reported.1 = true;
                let mut event = log_fields(&entry);
                event.insert("event".into(), json!("relay"));
                event.insert("elapsed".into(), json!(self.elapsed()));
                emit(Value::Object(event));
            }
        }
        for event in self.driver.take_events() {
            match event {
                DriverEvent::Stream { stream, route, initiator, .. } => self.stream_opened(stream, route, initiator),
                DriverEvent::AttemptEnded { entry, .. } if !self.reported.0 => {
                    self.reported.0 = true;
                    let mut event = log_fields(&entry);
                    event.insert("event".into(), json!("ended"));
                    emit(Value::Object(event));
                }
                _ => {}
            }
        }
        self.pump_stream();
    }

    fn stream_opened(&mut self, stream: ChannelStream, route: Route, initiator: bool) {
        let mut event = self.log().map(|e| log_fields(&e)).unwrap_or_default();
        event.insert("event".into(), json!("stream"));
        let name = if route.method() == RouteMethod::Relay { "relay" } else { "internet" };
        event.insert("route".into(), json!(name));
        event.insert("initiator".into(), json!(initiator));
        event.insert("elapsed".into(), json!(self.elapsed()));
        emit(Value::Object(event));
        if self.stream.is_some() {
            return; // the first stream carries the check
        }
        if initiator {
            let mut ping = vec![0u8; 16];
            szfriends_crypto::random_bytes(&mut ping);
            stream.writer.write(&ping);
            self.ping = Some(ping);
        }
        self.stream = Some((stream, route));
    }

    /// The initiator's 16 bytes cross both NATs and come back: the path carries data, not just a handshake.
    fn pump_stream(&mut self) {
        let Some((stream, _)) = &self.stream else { return };
        while let Ok(input) = stream.incoming.try_recv() {
            let StreamInput::Data(data) = input else { break };
            if !self.offerer {
                stream.writer.write(&data);
                continue;
            }
            self.echo.extend_from_slice(&data);
        }
        if let Some(ping) = self.ping.clone().filter(|p| self.echo.len() >= p.len()) {
            let mut event = self.log().map(|e| log_fields(&e)).unwrap_or_default();
            event.insert("event".into(), json!("data"));
            event.insert("ok".into(), json!(self.echo[..ping.len()] == ping[..]));
            emit(Value::Object(event));
            self.ping = None;
        }
    }
}

pub fn main() {
    let env = |name: &str| std::env::var(name).unwrap_or_default();
    let offerer = env("SZFNAT_ROLE") == "offerer";
    let seed: Vec<u8> = (0..env("SZFNAT_SEED").len() / 2)
        .filter_map(|i| u8::from_str_radix(env("SZFNAT_SEED").get(i * 2..i * 2 + 2)?, 16).ok())
        .collect();
    if seed.len() != 32 {
        eprintln!("szfnat-rust-peer: SZFNAT_SEED must be 64 hex digits");
        std::process::exit(2);
    }
    let (me, them) = if offerer { ("offerer", "answerer") } else { ("answerer", "offerer") };
    let own = Identity::from_secrets(&derive(&seed, &format!("{me} sign")), &derive(&seed, &format!("{me} dh")));
    let other = Identity::from_secrets(&derive(&seed, &format!("{them} sign")), &derive(&seed, &format!("{them} dh")));
    let friend = OnlineFriend {
        identity_key: other.public_key(),
        static_key: other.static_public_key(),
        presence_secret: Some(derive(&seed, &format!("{them} presence"))),
        request_token: None,
        root_key: None,
    };
    let (events, inbox): (Sender<Event>, Receiver<Event>) = channel();
    let sink = Mutex::new(events.clone());
    let sink: szfriends_online::driver::Sink = Arc::new(move |input| {
        let _ = sink.lock().unwrap_or_else(|e| e.into_inner()).send(Event::Driver(input));
    });
    let friend_key = friend.identity_key;
    let mut driver = Driver::new(Arc::new(own), TransportConfig::loopback(), true, Box::new(OneFriend(friend)), sink);
    let stun = |name: &str| env(name).parse::<u16>().ok().map(|p| SocketAddr::from(([127, 0, 0, 1], p)));
    driver.context.stun_primary = stun("SZFNAT_STUN");
    driver.context.stun_secondary = stun("SZFNAT_STUN2");
    let turn =
        Some((env("SZFNAT_TURN_PORT"), env("SZFNAT_TURN_SECRET"))).filter(|(p, s)| !p.is_empty() && !s.is_empty());
    let socket = signal_socket();
    let reader = socket.try_clone().expect("the signalling socket");
    let host = Host {
        socket,
        channels: HashMap::new(),
        next_sid: if offerer { 1 } else { 2 },
        opened: Vec::new(),
        relays: Vec::new(),
        turn,
    };
    spawn_readers(reader, events);
    let mut peer = Peer {
        driver,
        host,
        friend: friend_key,
        offerer,
        reached_at: None,
        stream: None,
        ping: None,
        echo: Vec::new(),
        reported: (false, false),
    };
    // A helper that has been online on this network knows its class already: measure it before the attempt.
    peer.driver.context.measure_nat_class();
    let ready_by = Instant::now() + Duration::from_secs(3);
    let mut ready = false;
    loop {
        if !ready
            && (peer.driver.context.nat_class() != szfriends_online::nat::classifier::NatClass::Unknown
                || Instant::now() >= ready_by)
        {
            ready = true;
            let (class, step) = (peer.driver.context.nat_class(), peer.driver.context.nat_step());
            emit(json!({ "event": "ready", "class": class as u8, "step": step }));
        }
        match inbox.recv_timeout(Duration::from_millis(20)) {
            Ok(Event::Driver(input)) => peer.driver.input(input, &mut peer.host),
            Ok(Event::Frame(kind, sid, payload)) => {
                let known = peer.host.channels.get(&sid).map(|c| (c.closed, c.far_ended));
                match (kind, known) {
                    (OPEN, None) => {
                        peer.host.channels.insert(sid, Channel { spoke: false, closed: false, far_ended: false });
                        peer.driver.incoming(sid.to_string(), &payload, &mut peer.host);
                    }
                    (MESSAGE, Some((false, false))) => {
                        peer.driver.sid_payload(&sid.to_string(), &payload, &mut peer.host)
                    }
                    (CLOSE, Some((false, false))) => {
                        if let Some(channel) = peer.host.channels.get_mut(&sid) {
                            channel.far_ended = true;
                        }
                        peer.driver.sid_ended(&sid.to_string(), &mut peer.host);
                    }
                    _ => {}
                }
            }
            Ok(Event::Reach) => {
                peer.reached_at = Some(Instant::now());
                let key = peer.friend;
                peer.driver.reach_friend(&key, &mut peer.host);
            }
            Ok(Event::Quit) => {
                peer.driver.stop(&mut peer.host);
                std::process::exit(0);
            }
            Err(_) => {}
        }
        peer.driver.tick(&mut peer.host);
        peer.settle();
    }
}
