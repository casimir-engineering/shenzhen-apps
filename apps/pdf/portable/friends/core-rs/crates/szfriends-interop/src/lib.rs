//! Test-only: two Friends peers in sessions on loopback, and what the scenarios between them need. A peer is either the
//! Rust core ([`RustPeer`]) or the Objective-C helper's own session, store and transfer code in a process of its own
//! ([`ObjcPeer`], `tools/objc-session-peer`); both take the same JSON commands and report the same JSON events, so one
//! scenario runs Rust against Rust everywhere and Rust against the helper on a Mac. [`Proxy`] sits between two peers
//! to cut a route or flip a byte. Nothing leaves loopback; every peer has its own temporary home.

pub mod again;
pub mod bridge;
pub mod device_scenarios;
mod devices;
mod devices_join;
mod flows;
pub mod helpers;
pub mod host;
mod link;
pub mod link_scenarios;
pub mod nearby;
pub mod nearby_devices;
mod objc;
mod online;
pub mod online_devices;
pub mod online_scenarios;
mod peer;
mod proxy;
pub mod scenarios;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

pub use objc::ObjcPeer;
pub use peer::RustPeer;
pub use proxy::{Proxy, Tamper};

/// One side of a scenario.
pub trait Peer {
    /// Runs one command and returns its reply.
    fn command(&mut self, command: Value) -> Value;
    /// The next event, or `None` after `timeout`.
    fn next_event(&mut self, timeout: Duration) -> Option<Value>;
}

pub fn hex_bytes(text: &str) -> Option<Vec<u8>> {
    hex::decode(text).ok()
}

/// A fresh empty directory under the system's temporary directory, removed when dropped.
#[derive(Debug)]
pub struct TempHome(PathBuf);

impl TempHome {
    pub fn new(label: &str) -> Self {
        let mut bytes = [0u8; 8];
        szfriends_core::crypto::random_bytes(&mut bytes);
        let path = std::env::temp_dir().join(format!("szf-interop-{label}-{}", hex::encode(bytes)));
        std::fs::create_dir_all(&path).expect("a temporary home");
        Self(path)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempHome {
    fn drop(&mut self) {
        remove_tree(&self.0);
    }
}

/// Removes a test's directory, trying again for a few seconds while Windows still holds a file in it (a database
/// just closed, a process just gone, the indexer or a scanner looking in).
pub fn remove_tree(path: &Path) {
    for attempt in 0..50 {
        match std::fs::remove_dir_all(path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound && attempt < 49 => {
                std::thread::sleep(Duration::from_millis(100));
            }
            _ => return,
        }
    }
}

/// Waits for the first event `matches` accepts, keeping the others it passes in `seen`; panics after `timeout`.
pub fn wait_for(
    peer: &mut dyn Peer,
    seen: &mut Vec<Value>,
    timeout: Duration,
    what: &str,
    matches: impl Fn(&Value) -> bool,
) -> Value {
    if let Some(index) = seen.iter().position(&matches) {
        return seen.remove(index);
    }
    let deadline = Instant::now() + timeout;
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        match peer.next_event(left) {
            Some(event) if matches(&event) => return event,
            Some(event) => seen.push(event),
            None => break,
        }
    }
    panic!("no {what} within {timeout:?}; events so far: {seen:?}")
}

/// Writes `size` bytes no two runs differ in (BLAKE2b in counter mode over `label`) and returns their BLAKE2b-256.
pub fn write_content(path: &Path, label: &str, size: u64) -> [u8; 32] {
    use blake2::digest::{Update, VariableOutput};
    use std::io::Write;
    let mut file = std::io::BufWriter::new(std::fs::File::create(path).expect("content file"));
    let mut digest = blake2::Blake2bVar::new(32).expect("32 bytes");
    let mut written = 0u64;
    let mut block = 0u64;
    let mut buffer = Vec::with_capacity(1 << 20);
    while written < size {
        buffer.clear();
        while buffer.len() < (1 << 20) && written + (buffer.len() as u64) < size {
            let piece = szfriends_core::crypto::blake2b::<64>(None, &[label.as_bytes(), &block.to_be_bytes()]);
            block += 1;
            buffer.extend_from_slice(&piece);
        }
        let take = buffer.len().min((size - written) as usize);
        file.write_all(&buffer[..take]).expect("written");
        digest.update(&buffer[..take]);
        written += take as u64;
    }
    file.flush().expect("flushed");
    let mut out = [0u8; 32];
    digest.finalize_variable(&mut out).expect("32 bytes");
    out
}

/// The identity keys a peer reports for itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Keys {
    pub identity: String,
    pub static_key: String,
}

pub fn keys(peer: &mut dyn Peer) -> Keys {
    let hello = peer.command(json!({ "cmd": "hello" }));
    Keys {
        identity: hello["identity_key"].as_str().expect("identity key").to_owned(),
        static_key: hello["static_key"].as_str().expect("static key").to_owned(),
    }
}

/// Makes `a` and `b` friends of each other, as an accepted request leaves them.
pub fn befriend(a: &mut dyn Peer, b: &mut dyn Peer, names: (&str, &str)) {
    let (ka, kb) = (keys(a), keys(b));
    a.command(
        json!({ "cmd": "add_friend", "identity_key": kb.identity, "static_key": kb.static_key, "name": names.1 }),
    );
    b.command(
        json!({ "cmd": "add_friend", "identity_key": ka.identity, "static_key": ka.static_key, "name": names.0 }),
    );
}

/// IK from `dialer` to the friend listening on `port`.
pub fn dial_ik(dialer: &mut dyn Peer, port: u16, friend: &Keys) -> u64 {
    let reply = dialer.command(json!({
        "cmd": "dial", "port": port, "pattern": "IK", "remote_static": friend.static_key,
        "expected_identity": friend.identity,
    }));
    reply["session"].as_u64().expect("a session")
}

pub fn listen(peer: &mut dyn Peer) -> u16 {
    peer.command(json!({ "cmd": "listen" }))["port"].as_u64().expect("a port") as u16
}

/// Matches an event of `kind` for `session` (any session when 0).
pub fn is_event(kind: &'static str, session: u64) -> impl Fn(&Value) -> bool {
    move |event: &Value| event["event"] == kind && (session == 0 || event["session"] == session)
}
