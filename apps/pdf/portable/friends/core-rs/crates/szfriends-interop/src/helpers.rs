//! Whole helpers, driven as an app drives them (PROTOCOL.md): a Rust helper's service in this process, the
//! Objective-C helper as a process of its own in a test home, or a helper inside a VM reached through the test
//! network's bridge. Each speaks the same JSON frames, so one nearby scenario runs between any two of them.
//!
//! A [`Client`] reads frames on a thread of its own, so every wait has a deadline, and [`Client::snapshot`] answers
//! with what a view shows now, never an older state.

use std::io;
#[cfg(target_os = "macos")]
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Child;
#[cfg(target_os = "macos")]
use std::process::{Command, Stdio};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use szfriends_contract::framing::{encode, LineReader};

/// How long one wait lasts before the scenario fails.
const WAIT: Duration = Duration::from_secs(40);

type Writer = Box<dyn FnMut(&[u8]) -> io::Result<()> + Send>;
/// Makes a file of `size` bytes named `name` where this helper can read it; its path there.
type FileMaker = Box<dyn FnMut(&str, usize) -> String + Send>;

/// One app's connection to one helper.
pub struct Client {
    name: String,
    writer: Writer,
    frames: Receiver<Value>,
    next: u64,
    seen: Vec<Value>,
    files: Option<FileMaker>,
    /// The helper's welcome: what it announces.
    pub welcome: Value,
    /// What must live as long as the connection (an in-process service, a child process).
    _keep: Vec<Box<dyn std::any::Any + Send>>,
}

impl std::fmt::Debug for Client {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Client").field("name", &self.name).finish()
    }
}

/// The hello every test client sends.
pub fn hello() -> Value {
    json!({"type": "hello", "id": "1", "protocol": {"major": 1, "minor": 0, "min_major": 1},
        "client": {"app_id": "interop", "app_name": "Shenzhen 3D", "app_version": "1", "toolkit": "tauri",
                   "reveal_in": "Files", "pid": std::process::id()},
        "embedded_helper": null, "capabilities": ["drop.files", "files.again"], "open_formats": ["stl"],
        "locale": "en"})
}

impl Client {
    /// A client over any byte stream: `read` on a thread of its own, `writer` for frames out.
    pub fn over(
        name: &str,
        mut read: impl FnMut(&mut [u8]) -> io::Result<usize> + Send + 'static,
        writer: Writer,
    ) -> Self {
        let (sender, frames) = channel();
        std::thread::spawn(move || {
            let mut reader = LineReader::new();
            let mut buffer = vec![0u8; 65_536];
            loop {
                let n = match read(&mut buffer) {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n,
                };
                let Ok(frames) = reader.push(&buffer[..n]) else { return };
                for frame in frames {
                    if sender.send(frame).is_err() {
                        return;
                    }
                }
            }
        });
        let mut client = Self {
            name: name.to_owned(),
            writer,
            frames,
            next: 1,
            seen: Vec::new(),
            files: None,
            welcome: Value::Null,
            _keep: Vec::new(),
        };
        client.write(&hello());
        let welcome = client.wait("welcome", |f| f["type"] == "welcome");
        assert!(welcome["capabilities"].is_array(), "{name}: a welcome: {welcome}");
        client.welcome = welcome;
        client
    }

    pub fn keep(&mut self, value: Box<dyn std::any::Any + Send>) {
        self._keep.push(value);
    }

    /// Something kept with this client, by type.
    pub fn kept<T: 'static>(&self) -> Option<&T> {
        self._keep.iter().find_map(|value| value.downcast_ref::<T>())
    }

    /// Where this helper's files are made (a local directory, or the VM's).
    pub fn set_files(&mut self, files: FileMaker) {
        self.files = Some(files);
    }

    /// A file of `size` bytes this helper can send; its path on the helper's computer.
    pub fn make_file(&mut self, name: &str, size: usize) -> String {
        let files = self.files.as_mut().expect("a place for files");
        files(name, size)
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    fn write(&mut self, frame: &Value) {
        (self.writer)(&encode(frame).expect("a frame")).expect("the helper takes frames");
    }

    fn receive(&mut self, deadline: Instant) -> Option<Value> {
        match self.frames.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(frame) => Some(frame),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => panic!("{}: the connection closed", self.name),
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
        panic!("{}: no {what}", self.name)
    }

    fn intent(&mut self, kind: &str, fields: Value) -> Value {
        self.next += 1;
        let id = self.next.to_string();
        let mut frame = fields;
        frame["type"] = json!(kind);
        frame["id"] = json!(id);
        self.write(&frame);
        self.wait("a reply", |f| f["type"] == "reply" && f["re"] == id.as_str())
    }

    /// An intent that must succeed: its result.
    pub fn send(&mut self, kind: &str, fields: Value) -> Value {
        let reply = self.intent(kind, fields);
        assert_eq!(reply["ok"], true, "{}: {kind}: {reply}", self.name);
        reply["result"].clone()
    }

    /// An intent that must fail: its error code.
    pub fn refused(&mut self, kind: &str, fields: Value) -> String {
        let reply = self.intent(kind, fields);
        assert_eq!(reply["ok"], false, "{}: {kind} was expected to fail: {reply}", self.name);
        reply["error"]["code"].as_str().unwrap_or_default().to_owned()
    }

    pub fn subscribe(&mut self, view: &str, params: Value) -> String {
        let result = self.send("subscribe", json!({"view": view, "params": params}));
        result["subscription"].as_str().expect("a subscription").to_owned()
    }

    pub fn open(&mut self, conversation: &str) -> String {
        let result = self.send("open_conversation", json!({"conversation_id": conversation}));
        result["subscription"].as_str().expect("a subscription").to_owned()
    }

    /// The newest snapshot of `subscription` once it `matches`.
    pub fn snapshot(&mut self, subscription: &str, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
        self.snapshot_within(subscription, what, WAIT, matches)
    }

    /// The same, waiting up to `wait` (what goes through the host can wait out a backoff first).
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
                    self.seen.push(found.clone());
                    return found["data"].clone();
                }
            }
            match self.receive(deadline) {
                Some(frame) => self.seen.push(frame),
                None => {
                    let newest = self.seen.iter().rev().find(|f| of(f)).map(|f| f["data"].to_string());
                    panic!("{}: no {what}; the view shows {}", self.name, newest.unwrap_or_default());
                }
            }
        }
    }
}

/// A Rust helper's service in this process, in a test home, behind its protocol server.
pub fn rust_helper(name: &str, home: &Path) -> Client {
    use szfriends_helper::service::{seed, Service};
    let service = Service::start(home, seed::test_key_store(home)).expect("the service starts");
    let (sender, _events) = channel();
    let facts = szfriends_contract::handshake::HelperFacts {
        version: "1.0".into(),
        build_number: 1,
        protocol: szfriends_contract::lifecycle::PROTOCOL,
        pid: std::process::id(),
    };
    let server = szfriends_helper::server::Server::new(service.clone(), facts, sender, Box::new(|_, _| false));
    let (ours, theirs) = szfriends_helper::transport::memory_pair();
    server.add(theirs, szfriends_helper::transport::PeerInfo::default());
    let (reading, writing) = (ours.clone(), ours);
    let read = move |buffer: &mut [u8]| szfriends_helper::transport::Duplex::read(&*reading, buffer);
    let writer: Writer = Box::new(move |bytes| szfriends_helper::transport::Duplex::write_all(&*writing, bytes));
    std::mem::forget(server);
    let mut client = Client::over(name, read, writer);
    client.keep(Box::new(Shutdown(service)));
    client.set_files(local_files(home.join("outgoing-files")));
    client
}

/// A Rust helper as [`rust_helper`] starts it, with `env` set while it starts (helpers read their test variables
/// as they start) and removed after. The caller sets `SZFRIENDS_STATE_DIR` and keeps other starts out meanwhile.
pub fn rust_helper_with(name: &str, home: &Path, env: &[(&str, &str)]) -> Client {
    for (key, value) in env {
        std::env::set_var(key, value);
    }
    let client = rust_helper(name, home);
    for (key, _) in env {
        std::env::remove_var(key);
    }
    client
}

/// The room two test helpers share: a test air both see over "Bluetooth" (`SZFRIENDS_TEST_BLUETOOTH`), and a hold
/// file keeping their network off until [`Room::network_comes_up`] (`SZFRIENDS_TEST_NETWORK_HOLD`). Pass
/// [`Room::env`] to [`rust_helper_with`] and [`objc_helper_with`], beside each helper's own network variables (a
/// shared `SZFRIENDS_TEST_LOOPBACK` directory, or a test service type). Both helpers honour these in test homes only.
#[derive(Debug)]
pub struct Room {
    air: PathBuf,
    hold: PathBuf,
}

impl Room {
    /// The air directory and hold file under `directory` (made here); the network starts off when `held`.
    pub fn new(directory: &Path, held: bool) -> Self {
        let air = directory.join("air");
        std::fs::create_dir_all(&air).expect("a test air");
        let room = Self { air, hold: directory.join("network-hold") };
        if held {
            room.network_goes_down();
        }
        room
    }

    /// The test air and the hold file, as each helper's environment names them.
    pub fn env(&self) -> Vec<(&'static str, String)> {
        vec![
            (szfriends_helper::nearby::test_air::ENV_TEST_BLUETOOTH, self.air.to_string_lossy().into_owned()),
            (szfriends_helper::nearby::hold::ENV_TEST_NETWORK_HOLD, self.hold.to_string_lossy().into_owned()),
        ]
    }

    /// Removes the hold file: each helper's network adapter starts within about 250 ms, as Wi-Fi coming up.
    pub fn network_comes_up(&self) {
        let _ = std::fs::remove_file(&self.hold);
    }

    /// Puts the hold file back: each helper's network adapter stops again.
    pub fn network_goes_down(&self) {
        std::fs::write(&self.hold, b"").expect("the network hold");
    }

    pub fn air(&self) -> &Path {
        &self.air
    }
}

/// Files made in a local directory.
pub fn local_files(directory: PathBuf) -> FileMaker {
    Box::new(move |name, size| {
        std::fs::create_dir_all(&directory).expect("a directory for files");
        let path = directory.join(name);
        let content: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
        std::fs::write(&path, content).expect("a file");
        path.to_string_lossy().into_owned()
    })
}

/// Closes the service's store when the client goes, so the test home can be removed.
struct Shutdown(Arc<szfriends_helper::service::Service>);

impl Drop for Shutdown {
    fn drop(&mut self) {
        szfriends_helper::presentation::Presentation::shutdown(&*self.0);
    }
}

/// A helper process this test started; ended by its own handle when dropped.
#[derive(Debug)]
pub struct Process(Mutex<Child>, Option<PathBuf>);

impl Process {
    pub fn new(child: Child) -> Self {
        Self(Mutex::new(child), None)
    }

    /// A process whose log (`log`) is printed when a test fails while it runs.
    pub fn with_log(child: Child, log: PathBuf) -> Self {
        Self(Mutex::new(child), Some(log))
    }

    /// Waits up to `timeout` for the process to end on its own.
    pub fn wait_for_exit(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut child = self.0.lock().unwrap_or_else(|e| e.into_inner());
        while Instant::now() < deadline {
            if matches!(child.try_wait(), Ok(Some(_))) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        false
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        if let (true, Some(log)) = (std::thread::panicking(), &self.1) {
            let text = std::fs::read_to_string(log).unwrap_or_default();
            let lines: Vec<&str> = text.lines().collect();
            eprintln!("--- {} (last lines)\n{}", log.display(), lines[lines.len().saturating_sub(60)..].join("\n"));
        }
        let mut child = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(target_os = "macos")]
/// `realpath` of the deepest existing ancestor, with the rest appended (PROTOCOL.md § Transport, Canonical form).
fn canonical(path: &Path) -> String {
    let mut existing = path.to_path_buf();
    let mut rest = Vec::new();
    while !existing.exists() {
        rest.push(existing.file_name().map(|n| n.to_owned()).unwrap_or_default());
        if !existing.pop() {
            break;
        }
    }
    let mut full: PathBuf = std::fs::canonicalize(&existing).unwrap_or(existing);
    for part in rest.into_iter().rev() {
        full.push(part);
    }
    full.to_string_lossy().into_owned()
}

/// The Objective-C helper (`build/friends/helper/szfriends-helper`) in a test home, on the loopback Bonjour of
/// `service_type`, connected over its socket.
#[cfg(target_os = "macos")]
pub fn objc_helper(name: &str, binary: &Path, home: &Path, service_type: &str) -> Client {
    objc_helper_with(name, binary, home, &[("SZFRIENDS_TEST_SERVICE_TYPE", service_type)])
}

/// The Objective-C helper in a test home checking in with the test host `list` and `keys` name. Its nearby runs on
/// a test service type of its own, where it meets nobody: the helper plans its online requests with its nearby ones.
#[cfg(target_os = "macos")]
pub fn objc_helper_online(name: &str, binary: &Path, home: &Path, list: &Path, keys: &Path) -> Client {
    let (list, keys, service_type) = (list.to_string_lossy(), keys.to_string_lossy(), test_service_type());
    let environment = [
        ("SZFRIENDS_TEST_HOST_LIST", list.as_ref()),
        ("SZFRIENDS_TEST_HOST_KEYS", keys.as_ref()),
        ("SZFRIENDS_TEST_SERVICE_TYPE", service_type.as_str()),
    ];
    objc_helper_with(name, binary, home, &environment)
}

/// The Objective-C helper in a test home with `env` beside it: a test service type, or a local host's signed list
/// (`SZFRIENDS_TEST_HOST_LIST`, `SZFRIENDS_TEST_HOST_KEYS`) and nothing nearby.
#[cfg(target_os = "macos")]
pub fn objc_helper_with(name: &str, binary: &Path, home: &Path, env: &[(&str, &str)]) -> Client {
    std::fs::create_dir_all(home).expect("a home");
    let temp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
    let child = Command::new(binary)
        .env_clear()
        .env("SZFRIENDS_STATE_DIR", home)
        .env("SZFRIENDS_DOWNLOADS_DIR", home.join("Downloads"))
        .env("SZFRIENDS_KEY_STORE", "file")
        .envs(env.iter().copied())
        .env("HOME", std::env::var("HOME").unwrap_or_default())
        .env("PATH", "/usr/bin:/bin")
        .env("TMPDIR", &temp)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("the Objective-C helper starts");
    let process = Process::with_log(child, home.join("helper.log"));
    let mut client = objc_connect(name, home);
    client.keep(Box::new(process));
    client.set_files(local_files(home.with_extension("files")));
    client
}

/// Waits until the Objective-C helper in `home` says, in a new connection's welcome, that it reaches friends online.
#[cfg(target_os = "macos")]
pub fn objc_wait_online(home: &Path, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        let probe = objc_connect("probe", home);
        if probe.welcome["capabilities"].as_array().is_some_and(|c| c.iter().any(|c| c == "online")) {
            return true;
        }
        drop(probe);
        std::thread::sleep(Duration::from_millis(500));
    }
    false
}

/// A new connection to the Objective-C helper serving `home`.
#[cfg(target_os = "macos")]
fn objc_connect(name: &str, home: &Path) -> Client {
    let temp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
    let user_temp = Command::new("/usr/bin/getconf")
        .arg("DARWIN_USER_TEMP_DIR")
        .output()
        .map_or(temp, |o| String::from_utf8_lossy(&o.stdout).trim().to_owned());
    let (path, _) = szfriends_contract::socket::socket_path(&canonical(home), &user_temp, 104).expect("a socket path");
    let deadline = Instant::now() + Duration::from_secs(10);
    let stream = loop {
        match std::os::unix::net::UnixStream::connect(&path) {
            Ok(stream) => break stream,
            Err(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            Err(error) => panic!("{name}: the helper's socket {path}: {error}"),
        }
    };
    let mut reading = stream.try_clone().expect("a reader");
    let mut writing = stream;
    let writer: Writer = Box::new(move |bytes| writing.write_all(bytes));
    Client::over(name, move |buffer| reading.read(buffer), writer)
}

/// A random test service type no other run shares (`_szfr<8 hex>._tcp`).
pub fn test_service_type() -> String {
    let mut bytes = [0u8; 4];
    szfriends_core::crypto::random_bytes(&mut bytes);
    format!("_szfr{}._tcp", hex::encode(bytes))
}
