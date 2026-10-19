//! The Mac's side of the bridge: starts `szfriends-testnet guest` in a VM through `prlctl exec`, mirrors the VM
//! helper's entries on Bonjour over lo0 (where the Objective-C helper's test adapter looks) and the Mac's entries into
//! the VM, relays every connection, and hands the test a [`Client`] of the VM's helper.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::process::ChildStdin;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_helper::nearby::dns_sd_cli::DnsSdCli;
use szfriends_helper::nearby::dnssd::{BrowseEvent, DnsSd};

use super::{pump, read_messages, writer, Message};
use crate::helpers::{Client, Process};

/// Where the guest runs.
#[derive(Clone, Debug)]
pub struct Guest {
    /// The Parallels VM's name.
    pub vm: String,
    /// `prlctl exec --current-user` (Windows) rather than as root (the Ubuntu VM's toolchain).
    pub current_user: bool,
    /// The built `szfriends-testnet` inside the VM.
    pub binary: String,
    /// A fresh directory inside the VM for the guest's home, which the guest removes as it exits.
    pub home: String,
    /// `blocked` or `firewall` (`SZFRIENDS_TEST_INBOUND`), or accepting connections.
    pub inbound: Option<String>,
}

type Streams = Arc<Mutex<HashMap<u64, TcpStream>>>;

struct Shared {
    out: Sender<Message>,
    streams: Streams,
    bonjour: Mutex<DnsSdCli>,
    /// Instance names this bridge registered on the Mac, never announced back.
    mirrors: Mutex<HashSet<String>>,
    /// The Mac's entries by name: where they listen.
    entries: Mutex<HashMap<String, Vec<SocketAddr>>>,
    listeners: Mutex<HashMap<String, Arc<AtomicBool>>>,
    next: AtomicU64,
}

/// The guest's standard input, closed on demand: its end is what tells the guest to clean up and exit.
#[derive(Clone)]
struct Input(Arc<Mutex<Option<ChildStdin>>>);

impl Write for Input {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        match self.0.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
            Some(stdin) => stdin.write(bytes),
            None => Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe)),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self.0.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
            Some(stdin) => stdin.flush(),
            None => Ok(()),
        }
    }
}

/// Everything the bridge runs, ended with the client: the Mac's mirrors leave Bonjour, the guest's input closes, and
/// the guest gets a while to close its store and remove its home before `prlctl` is ended.
struct Running {
    process: Process,
    input: Input,
    shared: Arc<Shared>,
}

impl Drop for Running {
    fn drop(&mut self) {
        for stop in self.shared.listeners.lock().unwrap_or_else(|e| e.into_inner()).values() {
            stop.store(true, Ordering::SeqCst);
        }
        self.shared.bonjour.lock().unwrap_or_else(|e| e.into_inner()).stop();
        self.input.0.lock().unwrap_or_else(|e| e.into_inner()).take();
        self.process.wait_for_exit(Duration::from_secs(20));
    }
}

fn mirror(shared: &Arc<Shared>, entry: &Value) {
    let Some(id) = entry["id"].as_str().map(str::to_owned) else { return };
    let txt: Vec<(String, String)> = entry["txt"]
        .as_array()
        .map(|pairs| {
            pairs.iter().filter_map(|p| Some((p[0].as_str()?.to_owned(), p[1].as_str()?.to_owned()))).collect()
        })
        .unwrap_or_default();
    let Ok(listener) = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)) else { return };
    let Ok(port) = listener.local_addr().map(|a| a.port()) else { return };
    let _ = listener.set_nonblocking(true);
    shared.mirrors.lock().unwrap_or_else(|e| e.into_inner()).insert(id.clone());
    if shared.bonjour.lock().unwrap_or_else(|e| e.into_inner()).register(&id, port, &txt).is_err() {
        return;
    }
    let stop = Arc::new(AtomicBool::new(false));
    if let Some(old) = shared.listeners.lock().unwrap_or_else(|e| e.into_inner()).insert(id.clone(), stop.clone()) {
        old.store(true, Ordering::SeqCst);
    }
    let shared = shared.clone();
    std::thread::spawn(move || {
        while !stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let _ = stream.set_nonblocking(false);
                    let connection = shared.next.fetch_add(1, Ordering::SeqCst);
                    let Ok(reader) = stream.try_clone() else { continue };
                    shared.streams.lock().unwrap_or_else(|e| e.into_inner()).insert(connection, stream);
                    let _ = shared.out.send(Message::Open { connection, entry: id.clone() });
                    pump(reader, connection, shared.out.clone());
                }
                Err(_) => std::thread::sleep(Duration::from_millis(30)),
            }
        }
    });
}

fn handle(shared: &Arc<Shared>, message: Message, client: &Sender<Vec<u8>>, replies: &Sender<Value>) {
    match message {
        Message::Announce(entry) => mirror(shared, &entry),
        Message::Withdraw(id) => {
            if let Some(stop) = shared.listeners.lock().unwrap_or_else(|e| e.into_inner()).remove(&id) {
                stop.store(true, Ordering::SeqCst);
            }
            shared.bonjour.lock().unwrap_or_else(|e| e.into_inner()).unregister(&id);
        }
        Message::Open { connection, entry } => {
            let addresses = shared.entries.lock().unwrap_or_else(|e| e.into_inner()).get(&entry).cloned();
            let stream = addresses.and_then(|a| szfriends_helper::nearby::connect_any(&a, Duration::from_secs(5)));
            match stream.and_then(|s| Some((s.try_clone().ok()?, s))) {
                Some((reader, stream)) => {
                    shared.streams.lock().unwrap_or_else(|e| e.into_inner()).insert(connection, stream);
                    pump(reader, connection, shared.out.clone());
                }
                None => {
                    let _ = shared.out.send(Message::Close { connection });
                }
            }
        }
        Message::Data { connection, bytes } => {
            let mut table = shared.streams.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(stream) = table.get_mut(&connection) {
                if stream.write_all(&bytes).is_err() {
                    table.remove(&connection);
                }
            }
        }
        Message::Close { connection } => {
            if let Some(stream) = shared.streams.lock().unwrap_or_else(|e| e.into_inner()).remove(&connection) {
                let _ = stream.shutdown(Shutdown::Write);
            }
        }
        Message::Client(bytes) => {
            let _ = client.send(bytes);
        }
        Message::Reply(reply) => {
            let _ = replies.send(reply);
        }
        Message::Command(_) => {}
    }
}

/// Asks the guest something and waits for its answer.
struct Commands {
    out: Sender<Message>,
    replies: Mutex<std::sync::mpsc::Receiver<Value>>,
    counter: AtomicU64,
}

impl Commands {
    fn ask(&self, mut command: Value) -> Value {
        let id = self.counter.fetch_add(1, Ordering::SeqCst);
        command["id"] = json!(id);
        let _ = self.out.send(Message::Command(command));
        let replies = self.replies.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            let reply = replies.recv_timeout(Duration::from_secs(30)).expect("the guest answers");
            if reply["id"] == id {
                return reply;
            }
        }
    }
}

/// Kept by the client so [`guest_firewall_rules`] can ask.
struct GuestCommands(Arc<Commands>);

/// How many inbound firewall rules the guest's Windows holds (`None` elsewhere).
pub fn guest_firewall_rules(client: &Client) -> Option<u64> {
    let commands = client.kept::<GuestCommands>()?;
    commands.0.ask(json!({"cmd": "firewall_rules"}))["rules"].as_u64()
}

/// Starts the guest and the Mac's side; a client of the guest's helper, which ends both when dropped.
pub fn start(name: &str, guest: &Guest, service_type: &str) -> Client {
    // No VM named: the guest runs here, which checks the bridge itself on the Mac.
    let mut command = Command::new(if guest.vm.is_empty() { guest.binary.as_str() } else { "prlctl" });
    if !guest.vm.is_empty() {
        command.arg("exec").arg(&guest.vm);
        if guest.current_user {
            command.arg("--current-user");
        }
        command.arg(&guest.binary);
    }
    command.arg("guest").arg(&guest.home);
    if let Some(inbound) = &guest.inbound {
        command.arg(inbound);
    }
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit()) // the guest helper's log, beside the test's output
        .spawn()
        .expect("prlctl exec starts");
    let (stdin, stdout) = (child.stdin.take().expect("stdin"), child.stdout.take().expect("stdout"));
    let input = Input(Arc::new(Mutex::new(Some(stdin))));
    let out = writer(input.clone());
    let shared = Arc::new(Shared {
        out: out.clone(),
        streams: Arc::new(Mutex::new(HashMap::new())),
        bonjour: Mutex::new(DnsSdCli::new(service_type)),
        mirrors: Mutex::new(HashSet::new()),
        entries: Mutex::new(HashMap::new()),
        listeners: Mutex::new(HashMap::new()),
        next: AtomicU64::new(1),
    });
    let browse_shared = shared.clone();
    let browsed = shared.bonjour.lock().unwrap_or_else(|e| e.into_inner()).browse(Box::new(move |event| match event {
        BrowseEvent::Found { name, addresses, txt } => {
            if browse_shared.mirrors.lock().unwrap_or_else(|e| e.into_inner()).contains(&name) {
                return;
            }
            browse_shared.entries.lock().unwrap_or_else(|e| e.into_inner()).insert(name.clone(), addresses);
            let txt: Vec<(String, String)> =
                txt.into_iter().map(|(k, v)| (k, String::from_utf8_lossy(&v).into_owned())).collect();
            let _ = browse_shared.out.send(Message::Announce(json!({"id": name, "name": name, "txt": txt})));
        }
        BrowseEvent::Lost { name }
            if browse_shared.entries.lock().unwrap_or_else(|e| e.into_inner()).remove(&name).is_some() =>
        {
            let _ = browse_shared.out.send(Message::Withdraw(name));
        }
        _ => {}
    }));
    browsed.expect("browsing Bonjour on lo0");
    let (client_sender, client_bytes) = channel::<Vec<u8>>();
    let (reply_sender, replies) = channel::<Value>();
    let reading = shared.clone();
    std::thread::spawn(move || {
        read_messages(stdout, |message| handle(&reading, message, &client_sender, &reply_sender));
    });
    let mut pending: Vec<u8> = Vec::new();
    let read = move |buffer: &mut [u8]| -> std::io::Result<usize> {
        if pending.is_empty() {
            match client_bytes.recv() {
                Ok(bytes) => pending = bytes,
                Err(_) => return Ok(0),
            }
        }
        let n = buffer.len().min(pending.len());
        buffer[..n].copy_from_slice(&pending[..n]);
        pending.drain(..n);
        Ok(n)
    };
    let client_out = out.clone();
    let writer = Box::new(move |bytes: &[u8]| {
        client_out.send(Message::Client(bytes.to_vec())).map_err(|_| std::io::Error::other("the bridge ended"))
    });
    let mut client = Client::over(name, read, writer);
    let replies = Mutex::new(replies);
    let files_out = out;
    let counter = AtomicU64::new(1);
    let commands = Arc::new(Commands { out: files_out, replies, counter });
    let files = commands.clone();
    client.set_files(Box::new(move |file, size| {
        let reply = files.ask(json!({"cmd": "make_file", "name": file, "size": size}));
        reply["path"].as_str().map(str::to_owned).expect("a file in the VM")
    }));
    client.keep(Box::new(GuestCommands(commands)));
    client.keep(Box::new(Running { process: Process::new(child), input, shared }));
    client
}
