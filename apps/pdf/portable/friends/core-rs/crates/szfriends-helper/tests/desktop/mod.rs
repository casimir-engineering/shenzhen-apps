//! Shared pieces of the tests that run the real helper binary (Linux and Windows): a scratch state directory, the
//! shortened lifecycle, and waiting for a helper to come and go. Only processes these tests start are ever waited
//! for; nothing is killed.

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Once;
use std::time::{Duration, Instant};

use serde_json::Value;
use szfriends_helper::client::{connect, AppInfo, ClientConnection, ConnectError};
use szfriends_helper::stamp::Stamp;
use szfriends_helper::state::{StateDir, ENV_STATE_DIR};

#[path = "../support/remove.rs"]
mod remove;
#[allow(unused_imports)]
pub use remove::remove_tree;

/// Grace 0.5 s, first client 1.5 s, handover deadline 0.25 s.
pub const TIME_SCALE: &str = "0.05";

/// Before any test starts a process: every helper these tests start, directly or through connect-or-spawn,
/// inherits the shortened lifecycle.
pub fn init() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| std::env::set_var("SZFRIENDS_HELPER_TIME_SCALE", TIME_SCALE));
}

/// A directory of the test's own, removed afterwards: once every helper the test saw running from it has exited
/// (on Windows a running executable's file cannot be removed), trying again while Windows still holds a file.
pub struct Scratch(pub PathBuf, std::sync::Mutex<Vec<u32>>);

impl Scratch {
    pub fn new(label: &str) -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!("szfh-{label}-{}-{n}", std::process::id()));
        remove_tree(&path);
        std::fs::create_dir_all(&path).expect("scratch directory");
        Self(path, Default::default())
    }

    pub fn state(&self) -> StateDir {
        StateDir::new(self.0.join("state"))
    }

    /// A helper process (by the pid its welcome gave) to wait for before the directory goes.
    pub fn helper(&self, pid: u32) -> u32 {
        self.1.lock().unwrap_or_else(|e| e.into_inner()).push(pid);
        pid
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let pids = std::mem::take(&mut *self.1.lock().unwrap_or_else(|e| e.into_inner()));
        for pid in pids {
            // Only while that pid still runs an executable from this directory, so a reused pid is never waited on.
            let ours = || process_image(pid).is_some_and(|image| image.starts_with(&self.0));
            eventually(Duration::from_secs(15), || !ours());
        }
        remove_tree(&self.0);
    }
}

pub fn helper_binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_szfriends-helper"))
}

/// Starts `binary` (the helper) for `state`, with `arguments`.
pub fn start(binary: &Path, state: &StateDir, arguments: &[&str]) -> Child {
    init();
    Command::new(binary)
        .args(arguments)
        .env(ENV_STATE_DIR, &state.path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("helper starts")
}

pub fn wait_exit(child: &mut Child, timeout: Duration) -> Option<ExitStatus> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().expect("child status") {
            return Some(status);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    None
}

/// Connects once something answers, within `timeout`.
pub fn wait_connect(state: &StateDir, timeout: Duration) -> ClientConnection {
    let deadline = Instant::now() + timeout;
    loop {
        match connect(state) {
            Ok(connection) => return connection,
            Err(ConnectError::NoHelper) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            Err(other) => panic!("cannot connect: {other}"),
        }
    }
}

pub fn app() -> AppInfo {
    AppInfo {
        app_id: "com.example.helper-test".into(),
        app_name: "Helper test".into(),
        app_version: "1".into(),
        toolkit: "test".into(),
        reveal_in: "Files".into(),
        capabilities: Vec::new(),
        open_formats: vec!["pdf".into()],
        locale: "en".into(),
    }
}

pub fn hello(connection: &mut ClientConnection, embedded: Option<&Stamp>) -> Value {
    let answer = connection.hello(&app(), embedded).expect("hello answered");
    assert_eq!(answer["type"], "welcome", "{answer}");
    answer
}

/// Whether no helper holds the lock for `state` now.
pub fn lock_is_free(state: &StateDir) -> bool {
    #[cfg(target_os = "linux")]
    let taken = szfriends_helper::linux::ipc::acquire_lock(state);
    #[cfg(windows)]
    let taken = szfriends_helper::windows::ipc::acquire_lock(state);
    matches!(taken, Ok(Some(_)))
}

pub fn eventually(timeout: Duration, condition: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    condition()
}

/// The executable process `pid` runs.
pub fn process_image(pid: u32) -> Option<PathBuf> {
    #[cfg(target_os = "linux")]
    return std::fs::read_link(format!("/proc/{pid}/exe")).ok();
    #[cfg(windows)]
    return szfriends_helper_sys::token::process_image(pid);
}

/// The helper's log for `state`, for a failing assertion's message.
pub fn log_of(state: &StateDir) -> String {
    std::fs::read_to_string(state.path.join("helper.log")).unwrap_or_else(|e| format!("(no log: {e})"))
}
