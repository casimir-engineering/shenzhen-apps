//! System notifications (ADR 0017, PROTOCOL.md § Notifications): the service decides, a [`Notifier`] posts. On
//! Windows and Linux the helper process posts (toasts, org.freedesktop.Notifications); on phones the Tauri plugin's
//! native code does, through its own `Notifier`; in a test home every request goes to the JSON-lines [`FileSink`].

use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

/// Where a click goes: `url` is `<scheme>://friends/conversation/<id>` (or `<scheme>://friends`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Open {
    pub url: String,
    pub app_id: String,
    /// The app's executable or bundle when known (Linux, Windows); `None` on phones.
    pub app_path: Option<String>,
}

/// Inline reply labels (messages only).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reply {
    pub label: String,
    pub placeholder: String,
    pub send: String,
}

/// One notification, as ADR 0017 § The request gives it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    /// `message:<item id>`, `file:<transfer id>`, `request:<conversation id>:<n>`, `join:<join id>`, `link:<id>`.
    pub key: String,
    /// `message`, `file`, `request`, `link`, `join`.
    pub kind: &'static str,
    /// `messages`, `files`, `requests`.
    pub channel: &'static str,
    pub conversation_id: Option<String>,
    pub thread: String,
    pub title: String,
    pub body: String,
    /// RFC 3339 UTC.
    pub time: String,
    pub reply: Option<Reply>,
    pub open: Open,
}

impl Request {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "key": self.key, "kind": self.kind, "channel": self.channel,
            "conversation_id": self.conversation_id, "thread": self.thread,
            "title": self.title, "body": self.body, "time": self.time,
            "reply": self.reply.as_ref().map(|r| serde_json::json!({
                "label": r.label, "placeholder": r.placeholder, "send": r.send })),
            "open": { "url": self.open.url, "app_id": self.open.app_id, "app_path": self.open.app_path },
        })
    }
}

/// What the system allows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    Granted,
    Denied,
    NotAsked,
    /// Windows, Linux: nothing to ask.
    NotNeeded,
    /// Linux with no notification service on the session bus.
    Unavailable,
}

/// A click or a reply, from the system or `test_notification_response`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Response {
    Open { key: String },
    Reply { key: String, text: String },
}

/// Posts what the service decided. Implementations never block the service for long.
pub trait Notifier: Send + Sync {
    fn post(&self, request: &Request);
    /// Remove delivered notifications of one conversation (read here or elsewhere).
    fn withdraw(&self, thread: &str);
    fn permission(&self) -> Permission;
    /// Ask the system (`allow_notifications`); a no-op where nothing can be asked.
    fn ask(&self);
    /// Route a click the platform does not route by itself (Linux, the sink): open `open.url` in `open.app_path`.
    fn open(&self, open: &Open);
}

/// The test home's sink: `<state dir>/notifications.jsonl`, one JSON object per line. Never touches the system.
#[derive(Debug)]
pub struct FileSink {
    path: PathBuf,
    permission: Permission,
    lock: Mutex<()>,
}

impl FileSink {
    /// `SZFRIENDS_NOTIFY_PERMISSION`: `granted` (default), `denied`, `not_asked`.
    pub fn new(state_dir: &std::path::Path) -> Self {
        let permission = match std::env::var("SZFRIENDS_NOTIFY_PERMISSION").as_deref() {
            Ok("denied") => Permission::Denied,
            Ok("not_asked") => Permission::NotAsked,
            _ => Permission::Granted,
        };
        Self { path: state_dir.join("notifications.jsonl"), permission, lock: Mutex::new(()) }
    }

    fn append(&self, value: serde_json::Value) {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = writeln!(file, "{value}");
        }
    }
}

impl Notifier for FileSink {
    fn post(&self, request: &Request) {
        self.append(request.to_json());
    }
    fn withdraw(&self, thread: &str) {
        self.append(serde_json::json!({ "withdraw": { "thread": thread } }));
    }
    fn permission(&self) -> Permission {
        self.permission
    }
    fn ask(&self) {
        self.append(serde_json::json!({ "asked": true }));
    }
    fn open(&self, open: &Open) {
        self.append(serde_json::json!({ "opened": {
            "url": open.url, "app_id": open.app_id, "app_path": open.app_path } }));
    }
}
