//! The link to the Friends service: one connection, its hello, its frames, and reconnection, whatever carries it
//! (ADR 0015 § 3, § 4). The states, the lines a person reads while it is not ready, the backoff and the replies a
//! dropped connection owes are the C client library's (`client/szfriends_client.h`), so a Tauri app behaves like
//! ShenzhenPDF, Shenzhen Files and Shenzhen 3D's Electron app.
//!
//! Where the bytes go is a [`Connector`]'s business: the helper's socket or pipe on a desktop (connect-or-spawn of
//! the app's embedded helper), or the core in this very process on a phone.

#[cfg(any(target_os = "linux", windows))]
pub mod desktop;
#[cfg(any(target_os = "android", target_os = "ios"))]
pub mod embedded;
#[cfg(target_os = "macos")]
pub mod mac;
mod watch;

pub use watch::Patience;
use watch::WATCHED;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{Map, Value};
use szfriends_contract::framing::encode;
use szfriends_contract::lifecycle::{backoff, RETRY_CAP, RETRY_FIRST};
use szfriends_helper::client::{AppInfo, ClientConnection};
use szfriends_helper::stamp::Stamp;
use szfriends_helper::transport::Duplex;

/// The C client library's connection states, by the names its Electron binding reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkState {
    Idle,
    Connecting,
    Handshaking,
    Ready,
    Waiting,
    Incompatible,
    /// Not ready for [`STUCK_AFTER`], or stopped by something that will not pass by itself ([`Trouble`]). The link
    /// keeps trying; the panel says why and what to do instead of "Starting Friends…" without end.
    Unavailable,
}

impl LinkState {
    pub fn name(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Connecting => "connecting",
            Self::Handshaking => "handshaking",
            Self::Ready => "ready",
            Self::Waiting => "waiting",
            Self::Incompatible => "incompatible",
            Self::Unavailable => "unavailable",
        }
    }
}

/// Why Friends is unavailable, as far as the link can tell.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[cfg_attr(not(any(target_os = "linux", windows)), allow(dead_code))] // only the desktop connector finds them
pub enum Trouble {
    /// Nothing more specific: the helper did not start or did not answer.
    #[default]
    Other,
    /// Security software removed or refused the helper (`szfriends_helper::copy::is_blocked`).
    Blocked,
    /// The app runs as administrator and the helper does not, so the app will not talk to it (Windows integrity).
    Elevated,
}

/// How long the link may go without a working helper before the panel stops saying "Starting Friends…" (or showing
/// "Loading…") and says it did not start. A first start copies the helper and checks in; it is ready in a second or
/// two, ten on a slow disk. Working means the helper answered an intent, not only its hello: a helper that welcomes
/// and then stops answering, or leaves again at once, does not count.
pub const STUCK_AFTER: Duration = Duration::from_secs(20);

/// What the person who opened Friends reads while it is not answering. They wonder whether it works and whether
/// they must do something. An incompatible helper asks them to update this app: another app runs a newer Friends,
/// which hands over only to newer builds. One that is unavailable says what stopped it, where the link knows, and
/// what to do; the link keeps trying meanwhile, so Friends appears by itself once the cause is gone.
pub fn state_text(state: LinkState, app_name: &str, trouble: Trouble) -> String {
    let computer = if cfg!(target_os = "macos") { "this Mac" } else { "this computer" };
    match state {
        LinkState::Connecting | LinkState::Handshaking => "Starting Friends…".into(),
        LinkState::Waiting => "Reconnecting to Friends…".into(),
        LinkState::Incompatible => {
            format!("Another app on {computer} uses a newer version of Friends. Update {app_name} to use Friends.")
        }
        LinkState::Unavailable => match trouble {
            Trouble::Blocked if cfg!(windows) => "Security software on this computer stopped Friends from starting. \
                Allow szfriends-helper.exe in it (in Windows Security: Virus & threat protection, Protection history) \
                and Friends starts by itself."
                .into(),
            Trouble::Blocked => format!(
                "Security software on {computer} stopped Friends from starting. Allow szfriends-helper in it and \
                 Friends starts by itself."
            ),
            Trouble::Elevated => {
                format!(
                    "Friends can't start while {app_name} runs as administrator. Quit {app_name} and open it normally."
                )
            }
            Trouble::Other => format!("Friends didn't start. Quit {app_name} and open it again."),
        },
        LinkState::Idle | LinkState::Ready => String::new(),
    }
}

/// One frame from the service, or a change of state.
#[derive(Clone, Debug, PartialEq)]
pub enum LinkEvent {
    Frame(Value),
    State(LinkState),
}

pub type Sink = Arc<dyn Fn(LinkEvent) + Send + Sync>;

/// Why a connection was not made this time, and what kind of trouble that is. Either way the link retries with
/// backoff until stopped.
#[derive(Debug)]
pub struct NotConnected(pub String, pub Trouble);

impl NotConnected {
    pub fn because(why: impl Into<String>) -> Self {
        Self(why.into(), Trouble::Other)
    }
}

/// Makes one connection, ready for its hello.
pub trait Connector: Send + Sync + 'static {
    fn connect(&self) -> Result<ClientConnection, NotConnected>;
    /// The embedded helper's stamp, sent in hello so an older running helper hands over to it.
    fn embedded(&self) -> Option<Stamp> {
        None
    }
    /// The app came to the foreground or left it (phones; a desktop helper does not follow one app).
    #[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
    fn foreground(&self, _in_front: bool) {}
    /// The helper stopped answering: end it so the next connect starts a new one. Whether one was ended.
    fn end_unresponsive(&self) -> bool {
        false
    }
}

struct Shared {
    state: Option<LinkState>,
    stream: Option<Arc<dyn Duplex>>,
    trouble: Trouble,
    /// Since when no helper has worked (answered an intent); reset by an answer.
    since: Instant,
    /// When the current hello was sent, while handshaking.
    hello_at: Option<Instant>,
    /// Watched intents not answered yet, by id, with when they were sent.
    outstanding: std::collections::HashMap<String, Instant>,
    /// When the last heartbeat went out.
    pinged_at: Option<Instant>,
    /// When this connection became ready.
    ready_at: Option<Instant>,
    /// How long a connection must stay ready before its answers count as a working helper (a helper that crashes
    /// right after each welcome is not one).
    settle: Duration,
    /// The watchdog dropped this connection because the helper stopped answering.
    stalled: bool,
}

impl Default for Shared {
    fn default() -> Self {
        Self {
            state: None,
            stream: None,
            trouble: Trouble::Other,
            since: Instant::now(),
            hello_at: None,
            outstanding: std::collections::HashMap::new(),
            pinged_at: None,
            ready_at: None,
            settle: Patience::DEFAULT.hello,
            stalled: false,
        }
    }
}

struct Inner {
    connector: Arc<dyn Connector>,
    app: AppInfo,
    sink: Sink,
    shared: Mutex<Shared>,
    write: Mutex<()>,
    wake: Condvar,
    stopped: AtomicBool,
    next_id: AtomicU64,
}

/// A running link. Dropping it does not stop it; [`Link::stop`] does.
#[derive(Clone)]
pub struct Link(Arc<Inner>);

impl std::fmt::Debug for Link {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Link").field("state", &self.state()).finish()
    }
}

impl Link {
    /// Starts connecting on a thread of its own; events go to `sink` on that thread.
    pub fn start(connector: Arc<dyn Connector>, app: AppInfo, sink: Sink) -> Self {
        let inner = Arc::new(Inner {
            connector,
            app,
            sink,
            shared: Mutex::new(Shared::default()),
            write: Mutex::new(()),
            wake: Condvar::new(),
            stopped: AtomicBool::new(false),
            next_id: AtomicU64::new(1),
        });
        let link = Self(inner);
        let running = link.clone();
        let spawned = std::thread::Builder::new().name("szfriends-link".into()).spawn(move || running.run());
        if spawned.is_err() {
            link.set_state(LinkState::Waiting);
        }
        link
    }

    pub fn state(&self) -> LinkState {
        self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).state.unwrap_or(LinkState::Idle)
    }

    /// What stopped Friends, while [`LinkState::Unavailable`].
    pub fn trouble(&self) -> Trouble {
        self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).trouble
    }

    /// Sends one intent; its id, or None unless the link is ready (the service owns every queue, so nothing waits
    /// here).
    pub fn send(&self, kind: &str, fields: &Map<String, Value>) -> Option<String> {
        let stream = {
            let shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
            if shared.state != Some(LinkState::Ready) {
                return None;
            }
            shared.stream.clone()?
        };
        let id = (self.0.next_id.fetch_add(1, Ordering::Relaxed) + 1).to_string();
        let mut frame = fields.clone();
        frame.insert("type".into(), Value::from(kind));
        frame.insert("id".into(), Value::from(id.clone()));
        let bytes = encode(&Value::Object(frame)).ok()?;
        if WATCHED.contains(&kind) {
            self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).outstanding.insert(id.clone(), Instant::now());
        }
        let _writing = self.0.write.lock().unwrap_or_else(|e| e.into_inner());
        stream.write_all(&bytes).ok()?;
        Some(id)
    }

    /// Stops for good: tells the service when Friends was turned off (`disable`, after which a helper with no other
    /// app exits), then closes. Quitting is not turning Friends off: the helper keeps serving other apps.
    pub fn stop(&self, disabling: bool) {
        if disabling {
            let _ = self.send("disable", &Map::new());
        }
        self.0.stopped.store(true, Ordering::SeqCst);
        let stream = self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).stream.take();
        if let Some(stream) = stream {
            stream.close();
        }
        self.0.wake.notify_all();
    }

    fn stopped(&self) -> bool {
        self.0.stopped.load(Ordering::SeqCst)
    }

    fn set_state(&self, state: LinkState) {
        {
            let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
            if shared.state == Some(state) {
                return;
            }
            // Unavailable holds through the retries' own states until the link is ready, so the panel's line does
            // not flicker back to "Starting Friends…" every few seconds.
            let retrying = matches!(state, LinkState::Connecting | LinkState::Handshaking | LinkState::Waiting);
            if shared.state == Some(LinkState::Unavailable) && retrying {
                return;
            }
            shared.state = Some(state);
        }
        (self.0.sink)(LinkEvent::State(state));
    }

    /// Ready: the one state that ends Unavailable from inside the loop.
    fn set_ready(&self) {
        {
            let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
            if shared.state == Some(LinkState::Ready) {
                return;
            }
            shared.state = Some(LinkState::Ready);
        }
        (self.0.sink)(LinkEvent::State(LinkState::Ready));
    }

    /// Sleeps `delay` unless stopped first.
    fn pause(&self, delay: Duration) {
        let shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
        let _ = self.0.wake.wait_timeout_while(shared, delay, |_| !self.stopped());
    }

    fn run(&self) {
        self.run_with(Patience::DEFAULT)
    }

    /// Since when no helper has worked.
    fn not_working_for(&self) -> Duration {
        self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).since.elapsed()
    }

    /// Unavailable, announced again when the reason changed (the panel reads the reason with the state).
    fn set_unavailable(&self, trouble: Trouble, why: &str) {
        let changed = {
            let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
            let changed = shared.state != Some(LinkState::Unavailable) || shared.trouble != trouble;
            shared.trouble = trouble;
            if changed {
                shared.state = None;
            }
            changed
        };
        if changed {
            log(&format!("Friends is unavailable ({trouble:?}) after {} s: {why}", self.not_working_for().as_secs()));
        }
        self.set_state(LinkState::Unavailable);
    }

    /// The connection loop with its watchdog; `patience` is [`Patience::DEFAULT`] except in tests.
    fn run_with(&self, patience: Patience) {
        self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).settle = patience.hello;
        let watching = self.clone();
        let _ = std::thread::Builder::new().name("szfriends-link-watch".into()).spawn(move || watching.watch(patience));
        self.connect_loop(patience.stuck_after)
    }

    fn connect_loop(&self, stuck_after: Duration) {
        let mut base = RETRY_FIRST;
        let mut logged = String::new(); // the last reason logged: each new one once, not every retry
        while !self.stopped() {
            self.set_state(LinkState::Connecting);
            let (quick, trouble) = match self.0.connector.connect() {
                Ok(connection) => (self.serve(connection, &mut base), Trouble::Other),
                Err(NotConnected(why, trouble)) => {
                    if why != logged {
                        log(&format!("Friends is not connected: {why}"));
                        logged = why;
                    }
                    (false, trouble)
                }
            };
            if self.stopped() {
                break;
            }
            let stalled = {
                let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
                shared.outstanding.clear();
                shared.hello_at = None;
                shared.pinged_at = None;
                shared.ready_at = None;
                std::mem::take(&mut shared.stalled)
            };
            if stalled {
                // A helper that took the connection and then stopped answering: end it, so the next connect starts
                // a new one instead of reaching the same silent one again.
                if self.0.connector.end_unresponsive() {
                    log("ended the helper that stopped answering; starting a new one");
                }
            }
            let state = self.state();
            if state != LinkState::Incompatible {
                let stuck = trouble != Trouble::Other || self.not_working_for() >= stuck_after;
                if stuck {
                    let why = if logged.is_empty() { "the helper did not answer".to_owned() } else { logged.clone() };
                    self.set_unavailable(trouble, &why);
                } else {
                    self.set_state(LinkState::Waiting);
                }
            }
            let mut random = [0u8; 4];
            szfriends_crypto::random_bytes(&mut random);
            let (delay, next) = backoff(if quick { RETRY_FIRST } else { base }, u32::from_le_bytes(random));
            base = next;
            self.pause(delay);
        }
        let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
        shared.stream = None;
        shared.state = Some(LinkState::Idle);
    }

    /// Hello, then frames until the connection ends; whether to reconnect at once (the helper handed over).
    fn serve(&self, mut connection: ClientConnection, base: &mut Duration) -> bool {
        self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).stream = Some(connection.stream());
        if self.stopped() {
            connection.close();
            return false;
        }
        self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).hello_at = Some(Instant::now());
        self.set_state(LinkState::Handshaking);
        let embedded = self.0.connector.embedded();
        let answer = match connection.hello(&self.0.app, embedded.as_ref()) {
            Ok(answer) => answer,
            Err(_) => return false,
        };
        if answer["type"] != "welcome" {
            let code = answer["error"]["code"].as_str().unwrap_or_default();
            if code == "protocol_unsupported" {
                // A newer helper that cannot speak with this app: wait long, it may hand over or go.
                self.set_state(LinkState::Incompatible);
                *base = RETRY_CAP * 15;
            }
            connection.close();
            return false;
        }
        if answer["service"] == "not_started" {
            // The helper runs, but its Friends service could not open the identity or the store (its log says why);
            // it tries again as apps connect. Not a working helper: the panel says Friends didn't start meanwhile.
            log("the helper's Friends service has not started; connecting again");
            connection.close();
            return false;
        }
        *base = RETRY_FIRST;
        (self.0.sink)(LinkEvent::Frame(answer));
        {
            let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
            shared.trouble = Trouble::Other;
            shared.hello_at = None;
        }
        self.set_ready();
        {
            let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
            shared.ready_at = Some(Instant::now());
            shared.pinged_at = Some(Instant::now());
        }
        let mut handover = false;
        while let Ok(Some(frame)) = connection.next_frame() {
            if frame["type"] == "goodbye" {
                handover = frame["reason"] == "handover";
            }
            if frame["type"] == "reply" {
                // An answer from a connection that stayed up: this helper works. (The heartbeat's reply names no
                // request of the app's: dropped there.)
                let mut shared = self.0.shared.lock().unwrap_or_else(|e| e.into_inner());
                if shared.ready_at.is_some_and(|at| at.elapsed() >= shared.settle) {
                    shared.since = Instant::now();
                }
                if let Some(re) = frame["re"].as_str() {
                    shared.outstanding.remove(re);
                }
            }
            (self.0.sink)(LinkEvent::Frame(frame));
        }
        connection.close();
        self.0.shared.lock().unwrap_or_else(|e| e.into_inner()).stream = None;
        handover
    }
}

/// Where the plugin's log lines also go: the app's own log directory, set once Friends is located. A Windows app has
/// no console, so stderr alone would lose them; the helper keeps its own log (`helper.log` in the Friends home).
static LOG_FILE: OnceLock<PathBuf> = OnceLock::new();
/// A log file past this size starts again, the old one kept as `.1`.
const LOG_LIMIT: u64 = 1024 * 1024;

/// Sends the plugin's log lines to `path` too (`<app log dir>/friends.log`); the first call wins.
pub fn log_to(path: PathBuf) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > LOG_LIMIT) {
        let _ = std::fs::rename(&path, path.with_extension("log.1"));
    }
    let _ = LOG_FILE.set(path);
}

/// The plugin's log line: stderr, and the log file once there is one.
pub fn log(line: &str) {
    eprintln!("szfriends: {line}");
    if let Some(path) = LOG_FILE.get() {
        use std::io::Write;
        let seconds = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{seconds} [{}] {line}", std::process::id());
        }
    }
}

#[cfg(test)]
#[path = "../tests/link.rs"]
mod tests;
