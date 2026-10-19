//! The owner's route order where nearby and online meet: direct on the same network, then peer to peer (a direct
//! Internet connection here), then Bluetooth, then the relay. Two helpers' services in test homes, made friends,
//! first reach each other online through the local Node host and its coturn; then their test networks (or test airs)
//! are joined, as two people walking into the same room. A better nearby route takes over from online; a worse one
//! never does. `make friends-core-rs-online-check` sets `SZFRIENDS_HOST_SERVER_DIR` and `FRIENDS_TEST_COTURN`;
//! without them the test says what is missing and passes.
#![cfg(feature = "online")]

mod clients;
mod support;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use clients::{Client, Temp};
use serde_json::json;
use szfriends_helper::nearby::test_air::ENV_TEST_BLUETOOTH;
use szfriends_helper::service::{seed, BLOCK_DIRECT_FILE, ENV_TEST_HOST_KEYS, ENV_TEST_HOST_LIST, ENV_TEST_LOOPBACK};
use szfriends_helper::state::ENV_STATE_DIR;
use szfriends_interop::host::{self, LocalHost};

const LAN: &str = "Nearby, on your network";
const BLUETOOTH: &str = "Nearby, over Bluetooth";
const DIRECT: &str = "Online, direct";
const RELAY: &str = "Online, through the Friends relay";

/// Copies each side's own entries to the other until dropped: the two test networks (or airs) become one.
struct Joined(Arc<AtomicBool>);

impl Joined {
    fn new(a: PathBuf, b: PathBuf) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let running = stop.clone();
        std::thread::spawn(move || {
            let (mut copied_into_a, mut copied_into_b) = (HashSet::new(), HashSet::new());
            while !running.load(Ordering::SeqCst) {
                copy_own(&a, &b, &copied_into_a, &mut copied_into_b);
                copy_own(&b, &a, &copied_into_b, &mut copied_into_a);
                std::thread::sleep(Duration::from_millis(50));
            }
        });
        Self(stop)
    }
}

impl Drop for Joined {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// Entries written in `from` itself (not ones copied there) reach `to` whenever they change.
fn copy_own(from: &Path, to: &Path, foreign: &HashSet<String>, copied: &mut HashSet<String>) {
    let Ok(entries) = std::fs::read_dir(from) else { return };
    for entry in entries.flatten() {
        let Ok(name) = entry.file_name().into_string() else { continue };
        if name.starts_with('.') || foreign.contains(&name) || !entry.path().is_file() {
            continue;
        }
        let Ok(bytes) = std::fs::read(entry.path()) else { continue };
        if std::fs::read(to.join(&name)).ok().as_deref() == Some(bytes.as_slice()) {
            continue;
        }
        let temporary = to.join(format!(".{name}.copy"));
        if std::fs::write(&temporary, &bytes).is_ok() && std::fs::rename(&temporary, to.join(&name)).is_ok() {
            copied.insert(name);
        }
    }
}

struct Pair {
    ada: Client,
    bo: Client,
    chats: (String, String),
    conversations: (String, String),
    sent: u32,
    /// Last, so the homes outlive the services using them.
    _homes: (Temp, Temp, Temp, Temp),
}

impl Pair {
    /// Ada and Bo, friends, each on a nearby test network (`variable`) of their own until joined.
    fn start(label: &str, variable: &str, relayed: bool) -> Self {
        let homes = (
            Temp::new(&format!("{label}-a")),
            Temp::new(&format!("{label}-b")),
            Temp::new(&format!("{label}-near-a")),
            Temp::new(&format!("{label}-near-b")),
        );
        std::env::set_var(ENV_STATE_DIR, &homes.0 .0);
        let (bo_in_a, ada_in_b) = seed::befriend(&homes.0 .0, &homes.1 .0, ("Ada", "Bo")).expect("befriended");
        if relayed {
            std::fs::write(homes.0 .0.join(BLOCK_DIRECT_FILE), b"").unwrap();
            std::fs::write(homes.1 .0.join(BLOCK_DIRECT_FILE), b"").unwrap();
        }
        std::env::set_var(variable, &homes.2 .0);
        let mut ada = Client::connect(&homes.0 .0);
        std::env::set_var(variable, &homes.3 .0);
        let mut bo = Client::connect(&homes.1 .0);
        std::env::remove_var(variable);
        ada.send("activate", json!({}));
        bo.send("activate", json!({}));
        let open = |client: &mut Client, id: &str| {
            let reply = client.send("open_conversation", json!({"conversation_id": id}));
            reply["subscription"].as_str().unwrap().to_owned()
        };
        let chats = (open(&mut ada, &bo_in_a), open(&mut bo, &ada_in_b));
        Self { ada, bo, chats, conversations: (bo_in_a, ada_in_b), sent: 0, _homes: homes }
    }

    fn join(&self) -> Joined {
        Joined::new(self._homes.2 .0.clone(), self._homes.3 .0.clone())
    }

    /// A message from Ada, delivered; then Ada's conversation shows `route`.
    fn message_over(&mut self, route: &str) {
        self.sent += 1;
        let text = format!("Message {} from Ada", self.sent);
        let token = format!("{:032x}", self.sent);
        let fields = json!({"conversation_id": self.conversations.0, "text": text, "client_token": token});
        self.ada.send("send_message", fields);
        self.bo.snapshot(&self.chats.1, "the message at Bo", |d| d.to_string().contains(&text));
        self.shows(route);
    }

    fn shows(&mut self, route: &str) {
        let what = format!("Ada's conversation showing {route}");
        self.ada.snapshot(&self.chats.0, &what, |d| d.to_string().contains(route));
    }
}

/// Online direct first; once they share a network, the network carries them.
fn the_network_takes_over_from_a_direct_connection() {
    let mut pair = Pair::start("lan", ENV_TEST_LOOPBACK, false);
    pair.message_over(DIRECT);
    let _joined = pair.join();
    pair.shows(LAN);
    pair.message_over(LAN);
}

/// Through the relay first; once they are in Bluetooth range, Bluetooth carries them.
fn bluetooth_takes_over_from_the_relay() {
    let mut pair = Pair::start("bt-relay", ENV_TEST_BLUETOOTH, true);
    pair.message_over(RELAY);
    let _joined = pair.join();
    pair.shows(BLUETOOTH);
    pair.message_over(BLUETOOTH);
}

/// Online direct first; Bluetooth in range changes nothing, since it ranks after a direct connection.
fn a_direct_connection_keeps_them_when_bluetooth_comes() {
    let mut pair = Pair::start("bt-direct", ENV_TEST_BLUETOOTH, false);
    pair.message_over(DIRECT);
    let _joined = pair.join();
    std::thread::sleep(Duration::from_secs(4));
    pair.message_over(DIRECT);
    let chat = pair.ada.snapshot(&pair.chats.0, "Ada's conversation", |_| true);
    assert!(!chat["data"].to_string().contains(BLUETOOTH), "Bluetooth took over: {}", chat["data"]);
}

#[test]
fn nearby_and_online_keep_the_owners_route_order() {
    let Some(server) = host::server_dir() else {
        eprintln!("SZFRIENDS_HOST_SERVER_DIR is not set: make friends-core-rs-online-check sets it");
        return;
    };
    if let Some(why) = host::unavailable(&server, true) {
        eprintln!("skipped: {why}");
        return;
    }
    let dir = Temp::new("order-host");
    let host = LocalHost::start(&server, &dir.0, true);
    std::env::set_var(ENV_TEST_HOST_LIST, &host.list_path);
    std::env::set_var(ENV_TEST_HOST_KEYS, &host.keys_path);
    the_network_takes_over_from_a_direct_connection();
    bluetooth_takes_over_from_the_relay();
    a_direct_connection_keeps_them_when_bluetooth_comes();
    drop(host);
}
