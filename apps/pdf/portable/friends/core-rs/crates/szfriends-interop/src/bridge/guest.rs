//! The VM's side of the bridge (`szfriends-testnet guest <home>`): a Rust helper's service in this process, in a test
//! home, on a loopback test network in `<home>/net`; the Mac's entries mirrored there by listeners of the bridge's own;
//! and everything relayed over standard input and output. When the input ends, the service closes its store and the
//! home is removed, so nothing stays behind in the VM.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_helper::nearby::registry::{read_entries, remove_entry, write_entry, Entry};
use szfriends_helper::transport::Duplex;

use super::{pump, read_messages, writer, Message};

/// Connections this side opens are numbered from here; the Mac's from 1.
const GUEST_CONNECTIONS: u64 = 1 << 62;

type Streams = Arc<Mutex<HashMap<u64, TcpStream>>>;

struct Mirror {
    stop: Arc<AtomicBool>,
}

impl Drop for Mirror {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

fn mirror(
    net: &Path,
    entry: &Value,
    out: &Sender<Message>,
    streams: &Streams,
    next: &Arc<AtomicU64>,
) -> Option<Mirror> {
    let id = entry["id"].as_str()?.to_owned();
    let mut txt = Vec::new();
    for pair in entry["txt"].as_array()? {
        txt.push((pair[0].as_str()?.to_owned(), pair[1].as_str()?.to_owned()));
    }
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).ok()?;
    listener.set_nonblocking(true).ok()?;
    let port = listener.local_addr().ok()?.port();
    if let Err(error) = write_entry(net, &Entry { name: id.clone(), port, txt }) {
        eprintln!("szfriends-testnet: the mirror of {id} was not written: {error}");
        return None;
    }
    let stop = Arc::new(AtomicBool::new(false));
    let (thread_stop, out, streams, next) = (stop.clone(), out.clone(), streams.clone(), next.clone());
    std::thread::spawn(move || {
        while !thread_stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let _ = stream.set_nonblocking(false);
                    let connection = GUEST_CONNECTIONS + next.fetch_add(1, Ordering::SeqCst);
                    let Ok(reader) = stream.try_clone() else { continue };
                    streams.lock().unwrap_or_else(|e| e.into_inner()).insert(connection, stream);
                    let _ = out.send(Message::Open { connection, entry: id.clone() });
                    pump(reader, connection, out.clone());
                }
                Err(_) => std::thread::sleep(Duration::from_millis(30)),
            }
        }
    });
    Some(Mirror { stop })
}

/// Announces the helper's own entries in `net` (never the mirrors) as they come, change and go.
fn watch(net: PathBuf, mirrors: Arc<Mutex<HashSet<String>>>, out: Sender<Message>) {
    std::thread::spawn(move || {
        let mut known: HashMap<String, Entry> = HashMap::new();
        loop {
            let ours = mirrors.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let now: HashMap<String, Entry> =
                read_entries(&net).into_iter().filter(|(name, _)| !ours.contains(name)).collect();
            for (name, entry) in &now {
                if known.get(name) != Some(entry) {
                    let message = json!({"id": name, "name": name, "port": entry.port, "txt": entry.txt});
                    if out.send(Message::Announce(message)).is_err() {
                        return;
                    }
                }
            }
            for name in known.keys().filter(|n| !now.contains_key(*n)) {
                let _ = out.send(Message::Withdraw(name.clone()));
            }
            known = now;
            std::thread::sleep(Duration::from_millis(150));
        }
    });
}

/// The guest's answer to a command from the Mac.
fn answer(files: &Path, command: &Value) -> Value {
    match command["cmd"].as_str() {
        Some("make_file") => make_file(files, command),
        Some("firewall_rules") => json!({"id": command["id"], "rules": firewall_rules()}),
        _ => json!({"id": command["id"]}),
    }
}

/// How many inbound rules Windows' firewall holds (none elsewhere): the helper must never add one.
fn firewall_rules() -> Value {
    #[cfg(windows)]
    return szfriends_helper_sys::firewall::policy().map_or(Value::Null, |p| json!(p.inbound_rules.len()));
    #[cfg(not(windows))]
    Value::Null
}

fn make_file(directory: &Path, command: &Value) -> Value {
    let name = command["name"].as_str().unwrap_or("file.bin");
    let size = command["size"].as_u64().unwrap_or(0) as usize;
    let _ = std::fs::create_dir_all(directory);
    let path = directory.join(name);
    let content: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
    let written = std::fs::write(&path, content).is_ok();
    json!({"id": command["id"], "path": written.then(|| path.to_string_lossy().into_owned())})
}

/// Runs until standard input ends; the exit status. `inbound` is the test network's `SZFRIENDS_TEST_INBOUND`.
pub fn run(home: &Path, inbound: Option<&str>) -> i32 {
    let (net, state, files) = (home.join("net"), home.join("state"), home.join("files"));
    for directory in [&net, &state] {
        if std::fs::create_dir_all(directory).is_err() {
            return 2;
        }
    }
    std::env::set_var("SZFRIENDS_STATE_DIR", &state);
    std::env::set_var("SZFRIENDS_TEST_LOOPBACK", &net);
    std::env::remove_var("SZFRIENDS_TEST_SERVICE_TYPE");
    match inbound {
        Some(inbound) => std::env::set_var(szfriends_helper::nearby::ENV_TEST_INBOUND, inbound),
        None => std::env::remove_var(szfriends_helper::nearby::ENV_TEST_INBOUND),
    }
    let out = writer(std::io::stdout());
    let service = match szfriends_helper::service::Service::start(
        &state,
        szfriends_helper::service::seed::test_key_store(&state),
    ) {
        Ok(service) => service,
        Err(error) => {
            eprintln!("szfriends-testnet: the service did not start: {error}");
            return 1;
        }
    };
    let (sender, _events) = std::sync::mpsc::channel();
    let facts = szfriends_contract::handshake::HelperFacts {
        version: "1.0".into(),
        build_number: 1,
        protocol: szfriends_contract::lifecycle::PROTOCOL,
        pid: std::process::id(),
    };
    let server = szfriends_helper::server::Server::new(service.clone(), facts, sender, Box::new(|_, _| false));
    let (ours, theirs) = szfriends_helper::transport::memory_pair();
    server.add(theirs, szfriends_helper::transport::PeerInfo::default());
    let (client_reader, client_out) = (ours.clone(), out.clone());
    std::thread::spawn(move || {
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            match client_reader.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(n) => {
                    if client_out.send(Message::Client(buffer[..n].to_vec())).is_err() {
                        return;
                    }
                }
            }
        }
    });
    let mirrors = Arc::new(Mutex::new(HashSet::new()));
    watch(net.clone(), mirrors.clone(), out.clone());
    let streams: Streams = Arc::new(Mutex::new(HashMap::new()));
    let next = Arc::new(AtomicU64::new(1));
    let mut listeners: HashMap<String, Mirror> = HashMap::new();
    read_messages(std::io::stdin(), |message| match message {
        Message::Announce(entry) => {
            let Some(id) = entry["id"].as_str().map(str::to_owned) else { return };
            mirrors.lock().unwrap_or_else(|e| e.into_inner()).insert(id.clone());
            listeners.remove(&id);
            if let Some(mirror) = mirror(&net, &entry, &out, &streams, &next) {
                listeners.insert(id, mirror);
            }
        }
        Message::Withdraw(id) => {
            listeners.remove(&id);
            remove_entry(&net, &id);
            mirrors.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
        }
        Message::Open { connection, entry } => {
            let port = read_entries(&net).get(&entry).map(|e| e.port);
            let stream = port.and_then(|p| {
                TcpStream::connect_timeout(&SocketAddr::from((Ipv4Addr::LOCALHOST, p)), Duration::from_secs(5)).ok()
            });
            match stream.and_then(|s| Some((s.try_clone().ok()?, s))) {
                Some((reader, stream)) => {
                    streams.lock().unwrap_or_else(|e| e.into_inner()).insert(connection, stream);
                    pump(reader, connection, out.clone());
                }
                None => {
                    let _ = out.send(Message::Close { connection });
                }
            }
        }
        Message::Data { connection, bytes } => {
            let mut table = streams.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(stream) = table.get_mut(&connection) {
                if stream.write_all(&bytes).is_err() {
                    table.remove(&connection);
                }
            }
        }
        Message::Close { connection } => {
            if let Some(stream) = streams.lock().unwrap_or_else(|e| e.into_inner()).remove(&connection) {
                let _ = stream.shutdown(Shutdown::Write);
            }
        }
        Message::Client(bytes) => {
            let _ = ours.write_all(&bytes);
        }
        Message::Command(command) => {
            let _ = out.send(Message::Reply(answer(&files, &command)));
        }
        Message::Reply(_) => {}
    });
    // The Mac went away: the store closes, the mirrors leave the network, the home goes.
    drop(listeners);
    szfriends_helper::presentation::Presentation::shutdown(&*service);
    std::mem::forget(server);
    crate::remove_tree(home);
    0
}
