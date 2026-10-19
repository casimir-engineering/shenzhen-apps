//! The local Friends host for the online suites (as `tests/e2e/SZFriendsE2EOnlineHost.m` starts it): the Node service
//! from `server/friends` with protocol 2 and the relay on, its own STUN port, and a coturn built from pinned source
//! running the host's generated configuration at the 5 Mbit/s cap (`max-bps=625000`). Everything listens on
//! 127.0.0.1; coturn relays from en0's address so every relayed path is relay to relay, as the configuration requires.
//! Two signed lists name it: the service's own (version 1, a port nobody listens on) and the helpers' (version 2, the
//! real port), so the service never pushes its own over the helpers'. Never the production host.

use std::io::{BufRead, BufReader, Write};
use std::net::UdpSocket;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use szfriends_core::identity::Identity;

const TURN_SECRET: &str = "szfriends-interop-online-turn-secret-0123456789";
const EVENTS_PASSWORD: &str = "interopOnlineEventsPassword0123456789ab";
const MAX_BPS: &str = "625000";

/// Where `LocalHost::start` keeps the host's event lines, in its directory.
pub const EVENTS_LOG: &str = "host-events.log";

/// The events the host logged so far under `dir` (one JSON object per line), named `event`.
pub fn events(dir: &Path, event: &str) -> Vec<Value> {
    let text = std::fs::read_to_string(dir.join(EVENTS_LOG)).unwrap_or_default();
    text.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok()).filter(|v| v["event"] == event).collect()
}

/// The host and, when asked, coturn. Dropping it stops both (only the processes it started).
#[derive(Debug)]
pub struct LocalHost {
    host: Child,
    coturn: Option<Child>,
    pub url: String,
    /// The helpers' signed list and pinned keys, as files and as bytes.
    pub list_path: PathBuf,
    pub keys_path: PathBuf,
    pub list: Vec<u8>,
    pub pinned: [u8; 32],
    pub turn_port: u16,
    pub stun_port: u16,
}

impl Drop for LocalHost {
    fn drop(&mut self) {
        for child in [Some(&mut self.host), self.coturn.as_mut()].into_iter().flatten() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn b64(bytes: &[u8]) -> String {
    szfriends_online::b64::encode_url(bytes)
}

fn free_udp_port() -> u16 {
    UdpSocket::bind("127.0.0.1:0").and_then(|s| s.local_addr()).map_or(0, |a| a.port())
}

fn stun_answers(port: u16) -> bool {
    let Ok(socket) = UdpSocket::bind("127.0.0.1:0") else { return false };
    let _ = socket.set_read_timeout(Some(Duration::from_millis(200)));
    let transaction = szfriends_online::nat::stun::random_transaction();
    let Some(request) = szfriends_online::nat::stun::binding_request(&transaction, None, false) else { return false };
    let mut buffer = [0u8; 600];
    socket.send_to(&request, ("127.0.0.1", port)).is_ok() && socket.recv(&mut buffer).is_ok_and(|n| n >= 20)
}

/// en0's IPv4 address, which coturn relays from; loopback when there is none.
fn relay_address() -> String {
    let output = Command::new("/usr/sbin/ipconfig").args(["getifaddr", "en0"]).output();
    output
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_owned())
        .filter(|s| s.parse::<std::net::Ipv4Addr>().is_ok())
        .unwrap_or_else(|| "127.0.0.1".into())
}

fn signed_list(version: i64, url: &str, ice: &[String], host_key: &[u8; 32], signer: &Identity) -> Vec<u8> {
    let payload = json!({
        "version": version, "issued_at": "2026-10-14T00:00:00Z", "new_id_words": 2,
        "hosts": [{"id": "main-hk", "role": "both", "urls": [url], "turn_uris": ice, "region": "Test",
                   "priority": 1, "public_key": b64(host_key)}],
    })
    .to_string();
    let signature = signer.sign(payload.as_bytes(), "SZFriends host list v1\n");
    json!({"payload": b64(payload.as_bytes()), "sigs": [{"key": "primary", "sig": b64(&signature)}]})
        .to_string()
        .into_bytes()
}

/// The PKCS #8 form Node reads an Ed25519 seed from.
fn key_pem(seed: &[u8; 32]) -> String {
    let mut der = vec![0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];
    der.extend_from_slice(seed);
    let body = szfriends_online::b64::encode_standard(&der);
    format!("-----BEGIN PRIVATE KEY-----\n{body}\n-----END PRIVATE KEY-----\n")
}

/// Why the host cannot run here, or `None`.
pub fn unavailable(server: &Path, relay: bool) -> Option<String> {
    if !server.join("node_modules/ws/package.json").exists() {
        return Some("the host service's node_modules are missing (npm ci in server/friends)".into());
    }
    let version = Command::new("node").args(["-e", "process.stdout.write(process.versions.node)"]).output();
    let version = version.ok().and_then(|o| String::from_utf8(o.stdout).ok()).unwrap_or_default();
    let parts: Vec<u32> = version.split('.').filter_map(|p| p.parse().ok()).collect();
    if parts.len() < 2 || parts[0] < 22 || (parts[0] == 22 && parts[1] < 16) {
        return Some(format!("Node.js 22.16 or later is needed (found {version:?})"));
    }
    if relay && coturn_binary().is_none() {
        return Some("set FRIENDS_TEST_COTURN to a turnserver built from pinned source".into());
    }
    None
}

pub fn coturn_binary() -> Option<PathBuf> {
    std::env::var_os("FRIENDS_TEST_COTURN").map(PathBuf::from).filter(|p| p.is_file())
}

pub fn server_dir() -> Option<PathBuf> {
    std::env::var_os("SZFRIENDS_HOST_SERVER_DIR").map(PathBuf::from).filter(|p| p.is_dir())
}

fn start_coturn(binary: &Path, server: &Path, dir: &Path, port: u16) -> Option<Child> {
    let relay = relay_address();
    let mut min = [0u8; 2];
    szfriends_core::crypto::random_bytes(&mut min);
    let min_port = 50000 + u16::from_be_bytes(min) % 10000;
    let options = json!({
        "realm": "friends.test", "secret": TURN_SECRET, "listeningIps": ["127.0.0.1"], "relayIps": [relay],
        "listeningPort": port, "minPort": min_port, "maxPort": min_port + 63,
        "test": {"allowLoopbackPeers": true, "pidfile": dir.join("turnserver.pid")},
    });
    let script =
        "const m = await import(process.argv[1]); process.stdout.write(m.coturnConfig(JSON.parse(process.argv[2])));";
    let output = Command::new("node")
        .args(["--input-type=module", "-e", script])
        .arg(server.join("src/coturn-config.js"))
        .arg(options.to_string())
        .output()
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let lines: Vec<&str> = text.lines().collect();
    // The production limits the relay scenarios run under.
    let expected = [format!("max-bps={MAX_BPS}"), "user-quota=2".into(), format!("allowed-peer-ip={relay}")];
    if !expected.iter().all(|line| lines.contains(&line.as_str())) {
        return None;
    }
    let config = dir.join("turnserver.conf");
    std::fs::write(&config, &text).ok()?;
    let mut child = Command::new(binary)
        .arg("-c")
        .arg(&config)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline {
        if stun_answers(port) {
            return Some(child);
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    None
}

impl LocalHost {
    /// Starts the host (and coturn when `relay`) with its data under `dir`. Panics when they do not start.
    pub fn start(server: &Path, dir: &Path, relay: bool) -> Self {
        let (turn_port, stun_port) = (free_udp_port(), free_udp_port());
        let coturn = relay.then(|| {
            let binary = coturn_binary().expect("FRIENDS_TEST_COTURN names coturn");
            start_coturn(&binary, server, dir, turn_port).expect("coturn answers STUN on loopback")
        });
        let ice = vec![
            format!("stun:127.0.0.1:{turn_port}"),
            format!("stun:127.0.0.1:{stun_port}"),
            format!("turn:127.0.0.1:{turn_port}?transport=udp"),
        ];
        let mut seeds = [[0u8; 32]; 2];
        for seed in &mut seeds {
            szfriends_core::crypto::random_bytes(seed);
        }
        let signer = Identity::from_secrets(&seeds[0], &[9; 32]);
        let host_identity = Identity::from_secrets(&seeds[1], &[9; 32]);
        let host_key = host_identity.public_key();
        let service_list = dir.join("host-list.json");
        std::fs::write(&service_list, signed_list(1, "ws://127.0.0.1:9/v1", &ice, &host_key, &signer)).unwrap();
        let key_file = dir.join("host-key.pem");
        std::fs::write(&key_file, key_pem(&seeds[1])).unwrap();
        let pinned = signer.public_key();
        let mut host = Command::new("node")
            .arg("--disable-warning=ExperimentalWarning")
            .arg(server.join("src/main.js"))
            .env_clear()
            .env("PATH", std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin:/opt/homebrew/bin".into()))
            .envs([
                ("FRIENDS_HOST_ID", "main-hk".to_owned()),
                ("FRIENDS_LISTEN_HOST", "127.0.0.1".into()),
                ("FRIENDS_LISTEN_PORT", "0".into()),
                ("FRIENDS_DATA_DIR", dir.join("host-data").display().to_string()),
                ("FRIENDS_PINNED_KEYS", b64(&pinned)),
                ("FRIENDS_HOST_LIST_FILE", service_list.display().to_string()),
                ("FRIENDS_HOST_KEY_FILE", key_file.display().to_string()),
                ("FRIENDS_IDENTITY_SECRET", "friends-interop-online-identity-secret-0123456789".into()),
                ("FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY", "100".into()),
                ("FRIENDS_MAX_CONNECTIONS_PER_ADDRESS", "100".into()),
                ("FRIENDS_M2", "on".into()),
                ("FRIENDS_STUN_PORTS", stun_port.to_string()),
                ("FRIENDS_STUN_LISTEN", "127.0.0.1".into()),
                ("FRIENDS_TURN_URIS", ice[2].clone()),
                ("FRIENDS_RELAY", "on".into()),
                ("FRIENDS_TURN_SECRET", TURN_SECRET.into()),
                ("FRIENDS_TURN_REALM", "friends.test".into()),
                ("FRIENDS_TURN_LISTEN_IPS", "127.0.0.1".into()),
                ("FRIENDS_TURN_EVENTS_PASSWORD", EVENTS_PASSWORD.into()),
                ("FRIENDS_TURN_EVENTS_PORT", "0".into()),
                ("FRIENDS_TURN_MAX_SESSION_S", "0".into()),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(std::fs::File::create(dir.join("host-stderr.log")).map_or(Stdio::null(), Stdio::from))
            .spawn()
            .expect("node starts the host");
        let stdout = host.stdout.take().expect("piped");
        let (port_tx, port_rx) = std::sync::mpsc::channel();
        // Every event the host logs, for tests that check what it did (`events`).
        let mut events = std::fs::File::create(dir.join(EVENTS_LOG)).ok();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Some(file) = events.as_mut() {
                    let _ = writeln!(file, "{line}");
                }
                let event: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                if event["event"] == "listening" {
                    let _ = port_tx.send(event["port"].as_u64().unwrap_or(0));
                }
            }
        });
        let port = port_rx.recv_timeout(Duration::from_secs(10)).unwrap_or(0);
        let mut this = Self {
            host,
            coturn,
            url: String::new(),
            list_path: dir.join("helper-list.json"),
            keys_path: dir.join("helper-keys.json"),
            list: Vec::new(),
            pinned,
            turn_port,
            stun_port,
        };
        assert!(port > 0, "the host listens on loopback: {}", dir.join("host-stderr.log").display());
        this.url = format!("ws://127.0.0.1:{port}/v1");
        this.list = signed_list(2, &this.url, &ice, &host_key, &signer);
        std::fs::write(&this.list_path, &this.list).unwrap();
        let keys = json!({"keys": [{"name": "primary", "public_key": b64(&pinned), "test": true}]});
        std::fs::write(&this.keys_path, keys.to_string()).unwrap();
        this
    }
}
