//! The Rust peer online (`tests/online_interop.rs`), the same commands and events as the Objective-C peer's online mode
//! (`tools/objc-session-peer/SZFSessionPeerOnline.m`): `szfriends-online` checking in with the local Node host, its
//! driver in loopback test mode, and every stream it opens made a session as the helper makes one, IK initiator on the
//! offerer's side and responder on the other.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use szfriends_core::session::{monotonic_now, ChannelIdentity, HandshakeOptions, SecureChannel};
use szfriends_core::wire::{Pattern, RouteMethod};
use szfriends_online::driver::{Friends, OnlineFriend};
use szfriends_online::host::list::{pinned_keys, HostList};
use szfriends_online::links::{DownloadLink, LinkEvent, LinkFiles};
use szfriends_online::{Online, OnlineConfig, OnlineEvent};

use crate::hex_bytes;
use crate::link::Link;
use crate::peer::{Input, State};

#[derive(Default)]
pub(crate) struct Directory {
    friends: HashMap<[u8; 32], OnlineFriend>,
    own_secret: Option<[u8; 32]>,
}

struct Shared(Arc<Mutex<Directory>>);

impl Friends for Shared {
    fn friend(&self, key: &[u8; 32]) -> Option<OnlineFriend> {
        self.0.lock().unwrap().friends.get(key).cloned()
    }

    fn nearby_route(&self, _: &[u8; 32]) -> RouteMethod {
        RouteMethod::None
    }

    fn own_presence_secret(&self) -> Option<[u8; 32]> {
        self.0.lock().unwrap().own_secret
    }
}

type Served = Arc<Mutex<Vec<DownloadLink>>>;

struct ServedLinks(Served);

impl LinkFiles for ServedLinks {
    fn links(&self) -> Vec<DownloadLink> {
        self.0.lock().unwrap().clone()
    }
}

/// What the peer holds while online.
pub(crate) struct OnlinePart {
    online: Online,
    directory: Arc<Mutex<Directory>>,
    block: Arc<AtomicBool>,
    served: Served,
}

fn key32(value: &Value) -> Option<[u8; 32]> {
    value.as_str().and_then(hex_bytes).and_then(|b| b.try_into().ok())
}

fn random_id() -> String {
    let mut bytes = [0u8; 12];
    szfriends_core::crypto::random_bytes(&mut bytes);
    let word = |b: &[u8]| b.iter().map(|x| char::from(b'a' + x % 26)).collect::<String>();
    format!("{}-{}", word(&bytes[..6]), word(&bytes[6..]))
}

pub(crate) fn start(state: &mut State, command: &Value, input: Sender<Input>) -> Value {
    if state.online.is_some() {
        return json!({ "error": "already online" });
    }
    let list = std::fs::read(command["list"].as_str().unwrap_or_default()).unwrap_or_default();
    let keys = std::fs::read(command["keys"].as_str().unwrap_or_default()).unwrap_or_default();
    let Some((pinned, _)) = pinned_keys(&keys) else { return json!({ "error": "no keys" }) };
    let Some(list) = HostList::from_signed(&list, &pinned).filter(HostList::is_loopback_only) else {
        return json!({ "error": "the list does not verify or names a non-loopback host" });
    };
    let mut directory = Directory { own_secret: key32(&command["presence_secret"]), ..Directory::default() };
    for entry in command["friends"].as_array().cloned().unwrap_or_default() {
        let (Some(identity_key), Some(static_key)) = (key32(&entry["identity_key"]), key32(&entry["static_key"]))
        else {
            return json!({ "error": "bad friend" });
        };
        let presence_secret = key32(&entry["presence_secret"]);
        let friend = OnlineFriend { identity_key, static_key, presence_secret, request_token: None, root_key: None };
        directory.friends.insert(identity_key, friend);
        state.add_policy_friend(identity_key);
    }
    let directory = Arc::new(Mutex::new(directory));
    let block = Arc::new(AtomicBool::new(command["block_direct"].as_bool().unwrap_or(false)));
    let blocked = block.clone();
    let served: Served = Arc::default();
    let config = OnlineConfig {
        identity: Arc::new(state.identity_copy()),
        app_version: "26.10.17-1".into(),
        list,
        pinned,
        loopback_only: true,
        direct_blocked: Some(Arc::new(move || blocked.load(Ordering::SeqCst))),
        friends: Box::new(Shared(directory.clone())),
        id_provider: Box::new(|_| random_id()),
        technique_log: None,
        links: Some(Box::new(ServedLinks(served.clone()))),
        host_roots: None,
        membership: None,
        release_owed: None,
    };
    let (online, events) = Online::start(config);
    std::thread::spawn(move || {
        for event in events {
            if input.send(Input::Online(event)).is_err() {
                return;
            }
        }
    });
    state.online = Some(OnlinePart { online, directory, block, served });
    json!({})
}

pub(crate) fn reach(state: &mut State, command: &Value) -> Value {
    match (state.online.as_ref(), key32(&command["identity_key"])) {
        (Some(part), Some(key)) => {
            part.online.reach(key);
            json!({})
        }
        _ => json!({ "error": "not online" }),
    }
}

pub(crate) fn block_direct(state: &mut State, command: &Value) -> Value {
    if let Some(part) = &state.online {
        let on = command["on"].as_bool().unwrap_or(false);
        part.block.store(on, Ordering::SeqCst);
        if !on {
            part.online.network_changed();
        }
    }
    json!({})
}

/// What the links service still holds: `{"setups", "connections"}` (none once every upload has ended).
pub(crate) fn link_held(state: &mut State) -> Value {
    let Some(part) = &state.online else { return json!({ "error": "not online" }) };
    let (sender, held) = std::sync::mpsc::channel();
    part.online.links(move |links, _| {
        let _ = sender.send(links.held());
    });
    match held.recv_timeout(std::time::Duration::from_secs(5)) {
        Ok((setups, connections)) => json!({ "setups": setups, "connections": connections }),
        Err(_) => json!({ "error": "no answer" }),
    }
}

/// A download link to the file at `path`, served from now on: `{"link_id", "secret", "sha256"}`.
pub(crate) fn serve_link(state: &mut State, command: &Value) -> Value {
    let Some(part) = &state.online else { return json!({ "error": "not online" }) };
    let path = std::path::PathBuf::from(command["path"].as_str().unwrap_or_default());
    let Ok(bytes) = std::fs::read(&path) else { return json!({ "error": "no file" }) };
    let sha256: [u8; 32] = <sha2::Sha256 as sha2::Digest>::digest(&bytes).into();
    let (mut link_id, mut secret) = ([0u8; 16], [0u8; 32]);
    szfriends_core::crypto::random_bytes(&mut link_id);
    szfriends_core::crypto::random_bytes(&mut secret);
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
    let link = DownloadLink {
        link_id,
        secret,
        name: path.file_name().map_or_else(|| "file".into(), |n| n.to_string_lossy().into_owned()),
        path,
        size: bytes.len() as u64,
        sha256,
        blake2b: szfriends_core::crypto::blake2b::<32>(None, &[&bytes]),
        media_type: "application/octet-stream".into(),
        expires: now + 3600.0,
        sender_name: "Sender".into(),
        sender_friends_id: String::new(),
        thumbnail: None,
    };
    part.served.lock().unwrap().push(link);
    part.online.links(|links, host| links.register_all(host));
    json!({ "link_id": hex::encode(link_id), "secret": hex::encode(secret), "sha256": hex::encode(sha256) })
}

pub(crate) fn event(state: &mut State, event: OnlineEvent) {
    match event {
        OnlineEvent::Available(available) => state.emit(json!({ "event": "online", "available": available })),
        OnlineEvent::Stream { friend, stream, route, initiator } => {
            let known = state.online.as_ref().and_then(|p| p.directory.lock().unwrap().friends.get(&friend).cloned());
            let Some(known) = known else {
                stream.writer.close();
                return;
            };
            let method = route.method();
            let mut channel = if initiator {
                // As nearby dials a friend: IK to the static key we hold, on the route the stream came by.
                let mut options = HandshakeOptions::new(Pattern::IK, method);
                options.remote_static = Some(known.static_key);
                options.expected_identity = Some(known.identity_key);
                SecureChannel::initiator(ChannelIdentity::new(state.identity_ref()), options)
            } else {
                state.responder_channel()
            };
            channel.set_config(state.config());
            let id = state.next_id();
            let link = Link::start_online(id, stream, state.input_sender(), Input::Link);
            state.insert_session(id, channel, link);
            let route_name = if method == RouteMethod::Relay { "relay" } else { "internet" };
            state.emit(json!({ "event": "online_stream", "session": id, "route": route_name, "initiator": initiator }));
            if let Some(session) = state.sessions.get_mut(&id) {
                session.channel.start(monotonic_now());
            }
        }
        OnlineEvent::AttemptEnded { entry, .. } => {
            state.emit(json!({ "event": "online_attempt", "log": entry.to_json() }));
        }
        OnlineEvent::Link(LinkEvent::Opened(id)) => {
            state.emit(json!({ "event": "link_opened", "link_id": hex::encode(id) }))
        }
        OnlineEvent::Link(LinkEvent::Downloaded(id)) => {
            state.emit(json!({ "event": "link_served", "link_id": hex::encode(id) }));
        }
        OnlineEvent::Reserved(..)
        | OnlineEvent::HostList(_)
        | OnlineEvent::PreJoinReleased(_)
        | OnlineEvent::ReachChanged(_)
        | OnlineEvent::ById(_)
        | OnlineEvent::Join(_)
        | OnlineEvent::Removed => {}
    }
}

pub(crate) fn stop(state: &mut State) {
    if let Some(part) = state.online.take() {
        part.online.stop();
    }
}
