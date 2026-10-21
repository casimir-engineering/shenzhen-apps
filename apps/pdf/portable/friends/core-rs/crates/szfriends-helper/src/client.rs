//! The client side, for an app's bridge (the Tauri plugin's client mode) and the helper's own `--handover`:
//! connect with every check of the platform done before a byte is sent, connect-or-spawn with the client library's
//! backoff (PROTOCOL.md § Lifecycle), and the handshake.

use std::collections::VecDeque;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use szfriends_contract::framing::{encode, LineReader};
use szfriends_contract::lifecycle::{backoff, PROTOCOL, PROTOCOL_MIN_MAJOR, RETRY_FIRST};

use crate::copy::{ensure_copy, spawn, EmbeddedHelper};
use crate::stamp::Stamp;
use crate::state::StateDir;
use crate::transport::Duplex;

/// Why a connection was not made.
#[derive(Debug)]
pub enum ConnectError {
    /// Nothing answers: no helper runs (or the one advertised has gone). Connect-or-spawn spawns.
    NoHelper,
    /// Something answered that is not this user's helper, or the way to it is unsafe; nothing was sent. The code
    /// names the check that failed (`peer_uid`, `unsafe_directory`, `pipe_other_owner`, …).
    Refused(&'static str),
    Io(io::Error),
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoHelper => f.write_str("no helper is running"),
            Self::Refused(code) => write!(f, "refused: {code}"),
            Self::Io(error) => write!(f, "{error}"),
        }
    }
}

/// A connection to the helper.
pub struct ClientConnection {
    stream: Arc<dyn Duplex>,
    reader: LineReader,
    frames: VecDeque<Value>,
}

impl std::fmt::Debug for ClientConnection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClientConnection").field("queued", &self.frames.len()).finish()
    }
}

/// Connects to the helper for `state`, refusing anyone else's before sending a byte.
pub fn connect(state: &StateDir) -> Result<ClientConnection, ConnectError> {
    Ok(ClientConnection::new(platform_connect(state)?))
}

#[cfg(target_os = "linux")]
fn platform_connect(state: &StateDir) -> Result<Arc<dyn Duplex>, ConnectError> {
    Ok(Arc::new(crate::linux::ipc::connect(state)?))
}

#[cfg(windows)]
fn platform_connect(state: &StateDir) -> Result<Arc<dyn Duplex>, ConnectError> {
    Ok(Arc::new(crate::windows::ipc::connect(state)?))
}

/// The Rust helper runs on Windows and Linux only; on a Mac the Objective-C helper serves Friends.
#[cfg(not(any(target_os = "linux", windows)))]
fn platform_connect(_state: &StateDir) -> Result<Arc<dyn Duplex>, ConnectError> {
    Err(ConnectError::NoHelper)
}

/// Refusals that mean "no helper of ours is advertised", after which spawning is right (Windows).
const STALE: &str = "not_lock_owner";
const UNREADABLE: &str = "advertised_name";

/// What the app says about itself in `hello`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppInfo {
    pub app_id: String,
    pub app_name: String,
    pub app_version: String,
    pub toolkit: String,
    pub reveal_in: String,
    pub capabilities: Vec<String>,
    pub open_formats: Vec<String>,
    pub locale: String,
    /// The app's URL scheme, sent as hello `client.url_scheme`: where a notification's click opens it (ADR 0017).
    pub url_scheme: Option<String>,
}

impl ClientConnection {
    pub fn new(stream: Arc<dyn Duplex>) -> Self {
        Self { stream, reader: LineReader::new(), frames: VecDeque::new() }
    }

    /// The stream itself, for a bridge that writes intents from other threads while one thread reads (writes must
    /// then be serialised by the caller, so frames never interleave).
    pub fn stream(&self) -> Arc<dyn Duplex> {
        self.stream.clone()
    }

    pub fn send(&self, frame: &Value) -> io::Result<()> {
        let bytes = encode(frame).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        self.stream.write_all(&bytes)
    }

    /// The next frame, or `None` once the helper closed the connection.
    pub fn next_frame(&mut self) -> io::Result<Option<Value>> {
        let mut buffer = [0u8; 16 * 1024];
        while self.frames.is_empty() {
            let read = self.stream.read(&mut buffer)?;
            if read == 0 {
                return Ok(None);
            }
            let frames = self.reader.push(&buffer[..read]).map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
            self.frames.extend(frames);
        }
        Ok(self.frames.pop_front())
    }

    /// Sends `hello` (id `"1"`) and returns the helper's answer: a `welcome`, or the `reply` that refused it.
    pub fn hello(&mut self, app: &AppInfo, embedded: Option<&Stamp>) -> io::Result<Value> {
        let embedded = embedded.map(|stamp| {
            json!({"version": stamp.version, "build_number": stamp.build,
                   "protocol": {"major": PROTOCOL.major, "minor": PROTOCOL.minor}})
        });
        let mut client = json!({"app_id": app.app_id, "app_name": app.app_name, "app_version": app.app_version,
                                "toolkit": app.toolkit, "reveal_in": app.reveal_in, "pid": std::process::id()});
        if let Some(scheme) = &app.url_scheme {
            client["url_scheme"] = json!(scheme);
        }
        self.send(&json!({
            "type": "hello", "id": "1",
            "protocol": {"major": PROTOCOL.major, "minor": PROTOCOL.minor, "min_major": PROTOCOL_MIN_MAJOR},
            "client": client,
            "embedded_helper": embedded,
            "capabilities": app.capabilities, "open_formats": app.open_formats, "locale": app.locale,
        }))?;
        loop {
            match self.next_frame()? {
                Some(frame) if frame["type"] == "welcome" || frame["type"] == "reply" => return Ok(frame),
                Some(_) => continue,
                None => return Err(io::Error::from(io::ErrorKind::UnexpectedEof)),
            }
        }
    }

    /// Ends the connection.
    pub fn close(&self) {
        self.stream.close();
    }
}

/// A small random number for backoff jitter: it only needs to differ between processes.
fn jitter() -> u32 {
    let mut bytes = [0u8; 4];
    szfriends_crypto::random_bytes(&mut bytes);
    u32::from_le_bytes(bytes)
}

/// Connects, spawning the embedded helper's per-user copy when nothing answers, and retrying with the client
/// library's backoff (50 ms, doubling, capped at 2 s) until `patience` runs out. A helper that is refused is never
/// spawned around, except where the advertisement itself names no live helper of ours (Windows `not_lock_owner`: a
/// pipe that outlived its helper; `advertised_name`: a file in a form this build does not write): that is no helper,
/// and the spawned helper writes a new one. The refused pipe is never opened either way.
pub fn connect_or_spawn(
    state: &StateDir,
    embedded: &EmbeddedHelper,
    patience: Duration,
) -> Result<ClientConnection, ConnectError> {
    let deadline = Instant::now() + patience;
    let mut base = RETRY_FIRST;
    loop {
        match connect(state) {
            Ok(connection) => return Ok(connection),
            Err(ConnectError::NoHelper | ConnectError::Refused(STALE | UNREADABLE)) => {
                // Any number of apps may spawn at once; the lock lets one helper win.
                let copy = ensure_copy(state, embedded).map_err(ConnectError::Io)?;
                spawn(&copy, state).map_err(ConnectError::Io)?;
            }
            Err(other) => return Err(other),
        }
        let (delay, next) = backoff(base, jitter());
        base = next;
        if Instant::now() + delay > deadline {
            return connect(state);
        }
        std::thread::sleep(delay);
    }
}

/// What `--handover` found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Handover {
    /// No helper was running.
    NoHelper,
    /// The running helper is this build or newer: nothing to do.
    NotNeeded,
    /// The running helper said goodbye with reason `handover` and left.
    Done,
}

/// `szfriends-helper --handover` (ADR 0015 § 14): connects as a client whose embedded helper is this binary and
/// waits for the running helper's goodbye, so an installer or an AppImage's first start makes an older helper step
/// aside through the protocol. Nothing is stopped by name or process id.
pub fn hand_over(state: &StateDir, own: &Stamp) -> Result<Handover, ConnectError> {
    let mut connection = match connect(state) {
        Ok(connection) => connection,
        Err(ConnectError::NoHelper | ConnectError::Refused(STALE | UNREADABLE)) => return Ok(Handover::NoHelper),
        Err(other) => return Err(other),
    };
    let app = AppInfo {
        app_id: "szfriends-helper".into(),
        app_name: "Shenzhen Friends".into(),
        app_version: own.version.clone(),
        toolkit: "none".into(),
        reveal_in: "none".into(),
        capabilities: Vec::new(),
        open_formats: Vec::new(),
        locale: "en".into(),
        url_scheme: None,
    };
    let answer = connection.hello(&app, Some(own)).map_err(ConnectError::Io)?;
    let scheduled = answer["handover"] == "scheduled" || answer["error"]["details"]["handover"] == "scheduled";
    if !scheduled {
        connection.close();
        return Ok(Handover::NotNeeded);
    }
    // The old helper leaves within its 5 s handover deadline and 1 s flush; past that, give up waiting.
    let gave_up = Arc::new(AtomicBool::new(false));
    let (stream, flag) = (connection.stream.clone(), gave_up.clone());
    std::thread::spawn(move || {
        std::thread::sleep(HANDOVER_PATIENCE);
        flag.store(true, Ordering::SeqCst);
        stream.close();
    });
    loop {
        match connection.next_frame() {
            Ok(Some(frame)) if frame["type"] == "goodbye" && frame["reason"] == "handover" => {
                return Ok(Handover::Done)
            }
            Ok(Some(_)) => continue,
            _ if gave_up.load(Ordering::SeqCst) => {
                return Err(ConnectError::Io(io::Error::from(io::ErrorKind::TimedOut)));
            }
            // Closed without the goodbye: it left all the same.
            Ok(None) | Err(_) => return Ok(Handover::Done),
        }
    }
}

/// How long `--handover` waits for the old helper's goodbye.
const HANDOVER_PATIENCE: Duration = Duration::from_secs(15);
