//! A client of an in-process Friends service, as the protocol server serves an app, and temporary test homes: what
//! the service's end-to-end suites share. And the exchange several run: a message each way with the outbox's states,
//! then a file offered, accepted, received whole and acknowledged.

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use szfriends_contract::handshake::HelperFacts;
use szfriends_contract::lifecycle::PROTOCOL;
use szfriends_helper::server::Server;
use szfriends_helper::service::{seed, Service};
use szfriends_helper::transport::PeerInfo;

use crate::support::{self, pair, Peer};

pub struct Temp(pub PathBuf);

impl Temp {
    pub fn new(label: &str) -> Self {
        let mut random = [0u8; 8];
        szfriends_crypto::random_bytes(&mut random);
        let name: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("szf-service-{label}-{name}"));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        support::remove_tree(&self.0);
    }
}

/// A client of one service: frames out, frames in (read on a thread of their own, so a wait can time out).
pub struct Client {
    end: std::sync::Arc<support::End>,
    frames: Receiver<Value>,
    next: u64,
    seen: Vec<Value>,
    service: std::sync::Arc<Service>,
    /// The service's welcome: its capabilities and strings.
    pub welcome: Value,
}

/// How long a wait for a frame lasts before the test fails.
const WAIT: Duration = Duration::from_secs(30);

/// The service closes its store before the test's home is removed (Windows keeps an open database's files).
impl Drop for Client {
    fn drop(&mut self) {
        szfriends_helper::presentation::Presentation::shutdown(&*self.service);
    }
}

impl Client {
    pub fn connect(home: &Path) -> Self {
        Self::connect_with(home, &["drop.files", "mentions"])
    }

    /// A client that declares `capabilities` in its hello.
    pub fn connect_with(home: &Path, capabilities: &[&str]) -> Self {
        let service = Service::start(home, seed::test_key_store(home)).expect("the service starts");
        let (sender, _events) = channel();
        let facts = HelperFacts { version: "1.0".into(), build_number: 1, protocol: PROTOCOL, pid: 1 };
        let server = Server::new(service.clone(), facts, sender, Box::new(|_, _| false));
        let (ours, theirs) = pair();
        server.add(theirs, PeerInfo::default());
        let end = ours.clone();
        let (sender, frames) = channel();
        std::thread::spawn(move || {
            let mut peer = Peer::new(ours);
            while let Some(frame) = peer.next() {
                if sender.send(frame).is_err() {
                    return;
                }
            }
        });
        let mut client = Self { end, frames, next: 1, seen: Vec::new(), service, welcome: Value::Null };
        let hello = json!({"type": "hello", "id": "1", "protocol": {"major": 1, "minor": 0, "min_major": 1},
            "client": {"app_id": "test", "app_name": "Shenzhen 3D", "app_version": "1", "toolkit": "tauri",
                       "reveal_in": "Files", "pid": 1},
            "capabilities": capabilities, "open_formats": ["stl"], "locale": "en"});
        client.write(&hello);
        let welcome = client.wait("welcome", |f| f["type"] == "welcome");
        assert!(welcome["strings"].as_object().is_some_and(|s| !s.is_empty()), "the welcome carries the strings");
        client.welcome = welcome;
        std::mem::forget(server);
        client
    }

    fn write(&self, frame: &Value) {
        use szfriends_helper::transport::Duplex;
        self.end.write_all(&szfriends_contract::framing::encode(frame).unwrap()).unwrap();
    }

    /// One more frame, or `None` once `deadline` passed.
    fn receive(&mut self, deadline: Instant) -> Option<Value> {
        let left = deadline.saturating_duration_since(Instant::now());
        match self.frames.recv_timeout(left) {
            Ok(frame) => Some(frame),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => panic!("the connection closed"),
        }
    }

    pub fn wait(&mut self, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
        if let Some(index) = self.seen.iter().position(&matches) {
            return self.seen.remove(index);
        }
        let deadline = Instant::now() + WAIT;
        while let Some(frame) = self.receive(deadline) {
            if matches(&frame) {
                return frame;
            }
            self.seen.push(frame);
        }
        panic!("no {what}; seen {:?}", self.seen.iter().rev().take(3).collect::<Vec<_>>())
    }

    /// The whole reply, refused or not.
    pub fn request(&mut self, kind: &str, fields: Value) -> Value {
        self.next += 1;
        let id = self.next.to_string();
        let mut frame = fields;
        frame["type"] = json!(kind);
        frame["id"] = json!(id);
        self.write(&frame);
        self.wait("a reply", |f| f["type"] == "reply" && f["re"] == id.as_str())
    }

    pub fn send(&mut self, kind: &str, fields: Value) -> Value {
        self.next += 1;
        let id = self.next.to_string();
        let mut frame = fields;
        frame["type"] = json!(kind);
        frame["id"] = json!(id);
        self.write(&frame);
        let reply = self.wait("a reply", |f| f["type"] == "reply" && f["re"] == id.as_str());
        assert_eq!(reply["ok"], true, "{kind}: {reply}");
        reply["result"].clone()
    }

    /// The newest snapshot of `subscription` once it `matches`: what the view shows now, never an older state.
    /// Earlier snapshots of that subscription are dropped with it.
    pub fn snapshot(&mut self, subscription: &str, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
        self.snapshot_within(subscription, what, WAIT, matches)
    }

    /// As `snapshot`, waiting up to `wait`.
    pub fn snapshot_within(
        &mut self,
        subscription: &str,
        what: &str,
        wait: Duration,
        matches: impl Fn(&Value) -> bool,
    ) -> Value {
        let of = |f: &Value| f["type"] == "snapshot" && f["subscription"] == subscription;
        let deadline = Instant::now() + wait;
        loop {
            while let Ok(frame) = self.frames.try_recv() {
                self.seen.push(frame);
            }
            if let Some(index) = self.seen.iter().rposition(of) {
                if matches(&self.seen[index]["data"]) {
                    let found = self.seen.remove(index);
                    self.seen.retain(|f| !of(f));
                    // Kept as the view's current state for the next look.
                    self.seen.push(found.clone());
                    return found;
                }
            }
            match self.receive(deadline) {
                Some(frame) => self.seen.push(frame),
                None => {
                    let newest = self.seen.iter().rev().find(|f| of(f));
                    panic!("no {what}; the view shows {}", newest.map_or("nothing".into(), |f| f["data"].to_string()));
                }
            }
        }
    }
}

impl Client {
    /// An intent expected to fail: its error code.
    pub fn refused(&mut self, kind: &str, fields: Value) -> String {
        self.next += 1;
        let id = self.next.to_string();
        let mut frame = fields;
        frame["type"] = json!(kind);
        frame["id"] = json!(id);
        self.write(&frame);
        let reply = self.wait("a reply", |f| f["type"] == "reply" && f["re"] == id.as_str());
        assert_eq!(reply["ok"], false, "{kind} was expected to fail: {reply}");
        reply["error"]["code"].as_str().unwrap_or_default().to_owned()
    }

    /// Subscribes to a view; the subscription id.
    pub fn subscribe(&mut self, view: &str, params: Value) -> String {
        let reply = self.send("subscribe", json!({"view": view, "params": params}));
        reply["subscription"].as_str().unwrap().to_owned()
    }
}

fn open_file_path(value: &Value) -> Option<String> {
    match value {
        Value::Object(map) if map.get("action").and_then(Value::as_str) == Some("open_file") => {
            map.get("path").and_then(Value::as_str).map(str::to_owned)
        }
        Value::Object(map) => map.values().find_map(open_file_path),
        Value::Array(list) => list.iter().find_map(open_file_path),
        _ => None,
    }
}

pub fn texts(data: &Value) -> String {
    data.to_string()
}

/// Ada and Bo (homes `a` and `b`, friends already, each with a client) exchange a message each way and a file of
/// `size` bytes, whichever route carries them.
pub fn exchange(a: &Path, b: &Path, ada: &mut Client, bo: &mut Client, conversations: (&str, &str), size: u32) {
    let (bo_in_a, ada_in_b) = conversations;
    let list = ada.send("subscribe", json!({"view": "list"}))["subscription"].as_str().unwrap().to_owned();
    ada.snapshot(&list, "Bo in Ada's list", |d| texts(d).contains("Bo"));
    let chat =
        ada.send("open_conversation", json!({"conversation_id": bo_in_a}))["subscription"].as_str().unwrap().to_owned();
    let token = "0123456789abcdef0123456789abcdef";
    ada.send("send_message", json!({"conversation_id": bo_in_a, "text": "Hello from Ada", "client_token": token}));

    let bo_chat =
        bo.send("open_conversation", json!({"conversation_id": ada_in_b}))["subscription"].as_str().unwrap().to_owned();
    bo.snapshot(&bo_chat, "Ada's message at Bo", |d| texts(d).contains("Hello from Ada"));
    ada.snapshot(&chat, "the message delivered", |d| {
        texts(d).contains("Hello from Ada") && texts(d).contains("\"delivered\"")
    });
    let token = "fedcba9876543210fedcba9876543210";
    bo.send("send_message", json!({"conversation_id": ada_in_b, "text": "Hi Ada, Bo here", "client_token": token}));
    ada.snapshot(&chat, "Bo's reply at Ada", |d| texts(d).contains("Hi Ada, Bo here"));

    let source = a.join("Gearbox.stl");
    let content: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
    std::fs::write(&source, &content).unwrap();
    let path = source.to_str().unwrap();
    let files = json!({"conversation_id": bo_in_a, "files": [{"path": path}], "client_token": "aaaabbbbccccdddd"});
    let transfer = ada.send("send_files", files)["transfer_ids"][0].as_str().unwrap().to_owned();
    bo.snapshot(&bo_chat, "the offer at Bo", |d| texts(d).contains("Gearbox.stl") && texts(d).contains("accept_offer"));
    bo.send("accept_offer", json!({"transfer_id": transfer}));
    let received = bo.snapshot(&bo_chat, "the file received", |d| texts(d).contains("open_file"));
    let received_path = open_file_path(&received["data"]).expect("an Open action");
    assert_eq!(std::fs::read(&received_path).expect("the received file"), content);
    assert!(Path::new(&received_path).starts_with(b), "received into Bo's home");
    ada.snapshot(&chat, "the file delivered", |d| {
        d["items"]
            .as_array()
            .is_some_and(|items| items.iter().any(|i| i["kind"] == "transfer" && i["state"] == "delivered"))
    });
}

fn join_row(data: &Value) -> Option<Value> {
    data["join_requests"].as_array()?.first().cloned()
}

/// A new computer joins Ada's profile: asked by ID, approved on Ada's, a wrong code, then the right one.
pub fn join_profile(ada: &mut Client, ada_id: &str, new: &mut Client) {
    let view = new.subscribe("join", json!({}));
    new.snapshot(&view, "joining offered", |d| d["state"] == "idle");
    new.send("join_profile", json!({"friends_id": ada_id}));
    new.snapshot(&view, "the request on its way", |d| d["state"] == "waiting");

    let list = ada.subscribe("list", json!({}));
    let asked = ada.snapshot(&list, "the new computer's request", |d| join_row(d).is_some());
    let join_id = join_row(&asked["data"]).unwrap()["join_id"].as_str().unwrap().to_owned();
    ada.send("approve_join", json!({"join_id": join_id}));
    let approved = ada.snapshot(&list, "the code shown", |d| join_row(d).is_some_and(|r| r["code"].is_string()));
    let code = join_row(&approved["data"]).unwrap()["code"].as_str().unwrap().replace(' ', "");

    let wrong = if code.starts_with('0') { "11111111" } else { "00000000" };
    new.send("enter_join_code", json!({"code": wrong}));
    new.snapshot(&view, "a wrong code said so", |d| d["state"] == "wrong_code");
    new.send("enter_join_code", json!({"code": code}));
    new.snapshot(&view, "joined", |d| d["state"] == "joined");
    ada.snapshot(&list, "the request answered", |d| join_row(d).is_none());
}
