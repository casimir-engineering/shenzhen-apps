//! Linux notifications through `org.freedesktop.Notifications` on the session bus, with the helper's own D-Bus client
//! (`linux/dbus.rs`): `Notify` as "Shenzhen Friends" with its icon and a `default` action, `CloseNotification` to
//! withdraw a conversation's, and `ActionInvoked` heard on the same connection, so a click opens the conversation in
//! the app last used (its executable with the URL, else `xdg-open` or `gio open`). Without a notification service
//! on the bus Settings says so ([`Permission::Unavailable`]).
//!
//! One thread owns the connection: posts and withdrawals reach it over a channel, and between them it listens.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::{icon_file, Notifier, Open, Permission, Request, Responder, Response, APP_NAME};
use crate::linux::dbus::{Bus, Error};
use crate::linux::marshal::Value;

pub const NAME: &str = "org.freedesktop.Notifications";
pub const PATH: &str = "/org/freedesktop/Notifications";
const BUS: &str = "org.freedesktop.DBus";
const BUS_PATH: &str = "/org/freedesktop/DBus";
/// How long the thread listens between looks at its channel.
const LISTEN: Duration = Duration::from_millis(200);
/// How long a call may take (a service the bus starts on demand answers its first call late).
const CALL: Duration = Duration::from_secs(10);
/// How often the service's presence is looked at again, and a lost bus reconnected.
const RECHECK: Duration = Duration::from_secs(30);

const UNKNOWN: u8 = 0;
const AVAILABLE: u8 = 1;
const MISSING: u8 = 2;

enum Command {
    Post(Box<Request>),
    Withdraw(String),
}

/// Posts on the session bus from a thread of its own.
pub struct FreedesktopNotifier {
    commands: Mutex<Sender<Command>>,
    service: Arc<AtomicU8>,
}

impl std::fmt::Debug for FreedesktopNotifier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FreedesktopNotifier").field("service", &self.service.load(Ordering::Relaxed)).finish()
    }
}

impl FreedesktopNotifier {
    /// Starts the thread; it connects when it can and keeps trying while the session has no bus.
    pub fn start(state_dir: &Path, responder: Responder) -> Self {
        let (commands, inbox) = channel();
        let service = Arc::new(AtomicU8::new(UNKNOWN));
        let icon = icon_file(state_dir);
        let shared = service.clone();
        let spawned = std::thread::Builder::new()
            .name("szfriends-notify".into())
            .spawn(move || Poster::new(icon, shared, responder).run(inbox));
        if let Err(error) = spawned {
            crate::log!("no notification thread: {error}");
        }
        Self { commands: Mutex::new(commands), service }
    }

    fn send(&self, command: Command) {
        let _ = self.commands.lock().unwrap_or_else(|e| e.into_inner()).send(command);
    }
}

impl Notifier for FreedesktopNotifier {
    fn post(&self, request: &Request) {
        self.send(Command::Post(Box::new(request.clone())));
    }

    fn withdraw(&self, thread: &str) {
        self.send(Command::Withdraw(thread.to_owned()));
    }

    fn permission(&self) -> Permission {
        match self.service.load(Ordering::Relaxed) {
            MISSING => Permission::Unavailable,
            _ => Permission::NotNeeded,
        }
    }

    fn ask(&self) {}

    fn open(&self, open: &Open) {
        open_url(open);
    }
}

/// `Notify`'s eight arguments for `request`: the app's name and icon, the title, the body (escaped where the service
/// reads markup), the `default` action a click invokes, its category and urgency, and the service's own timeout.
pub fn notify_arguments(request: &Request, icon: Option<&Path>, markup: bool, replaces: u32) -> Vec<Value> {
    let body = if markup { escape_markup(&request.body) } else { request.body.clone() };
    let category = match request.kind {
        "message" => "im.received",
        "file" => "transfer",
        _ => "presence",
    };
    let hint = |key: &str, value: Value| {
        Value::DictEntry(Box::new(Value::Str(key.into())), Box::new(Value::Variant(Box::new(value))))
    };
    let mut hints = vec![hint("category", Value::Str(category.into())), hint("urgency", Value::Byte(1))];
    if let Some(icon) = icon {
        hints.push(hint("image-path", Value::Str(icon.to_string_lossy().into_owned())));
    }
    vec![
        Value::Str(APP_NAME.into()),
        Value::U32(replaces),
        Value::Str(icon.map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()),
        Value::Str(request.title.clone()),
        Value::Str(body),
        Value::Array("s".into(), vec![Value::Str("default".into()), Value::Str(String::new())]),
        Value::Array("{sv}".into(), hints),
        Value::I32(-1),
    ]
}

/// The body markup the specification allows is a small HTML subset: what a friend typed must not become any of it.
pub fn escape_markup(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Opens the conversation: the app last used with the URL, else the desktop's handler for its scheme.
pub fn open_url(open: &Open) {
    let mut attempts: Vec<(PathBuf, Vec<String>)> = Vec::new();
    if let Some(app) = open.app_path.as_deref().map(PathBuf::from).filter(|p| p.is_file()) {
        attempts.push((app, vec![open.url.clone()]));
    }
    attempts.push(("xdg-open".into(), vec![open.url.clone()]));
    attempts.push(("gio".into(), vec!["open".into(), open.url.clone()]));
    for (program, arguments) in attempts {
        match std::process::Command::new(&program)
            .args(&arguments)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
        {
            Ok(mut child) => {
                // Reaped off the caller's thread; the app may run for as long as the person keeps it.
                std::thread::spawn(move || child.wait());
                return;
            }
            Err(error) => {
                crate::log!("could not open a notification's conversation with {}: {error}", program.display())
            }
        }
    }
}

struct Poster {
    icon: Option<PathBuf>,
    service: Arc<AtomicU8>,
    responder: Responder,
    bus: Option<Bus>,
    markup: bool,
    /// The service's ids by thread, and the request key each one stands for.
    ids: HashMap<u32, (String, String)>,
    checked: Option<Instant>,
}

impl Poster {
    fn new(icon: Option<PathBuf>, service: Arc<AtomicU8>, responder: Responder) -> Self {
        Self { icon, service, responder, bus: None, markup: false, ids: HashMap::new(), checked: None }
    }

    fn run(mut self, inbox: Receiver<Command>) {
        loop {
            if self.checked.is_none_or(|at| at.elapsed() >= RECHECK) {
                self.checked = Some(Instant::now());
                self.check();
            }
            loop {
                match inbox.recv_timeout(Duration::ZERO) {
                    Ok(command) => self.handle(command),
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            match self.bus.as_mut() {
                Some(bus) => {
                    let _ = bus.set_timeout(Some(LISTEN));
                    match bus.next_message() {
                        Ok(message) => self.signal(&message),
                        Err(Error::Io(e))
                            if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {}
                        Err(error) => {
                            crate::log!("the session bus closed for notifications: {error}");
                            self.bus = None;
                        }
                    }
                }
                None => match inbox.recv_timeout(LISTEN) {
                    Ok(command) => self.handle(command),
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => return,
                },
            }
        }
    }

    /// Connects when needed and looks whether a notification service answers (running, or started on demand).
    fn check(&mut self) {
        if self.bus.is_none() {
            self.bus = Bus::session().ok();
            if let Some(bus) = self.bus.as_mut() {
                let rule = format!("type='signal',interface='{NAME}',path='{PATH}'");
                let _ = bus.call(BUS, BUS_PATH, BUS, "AddMatch", &[Value::Str(rule)]);
            }
        }
        let Some(bus) = self.bus.as_mut() else {
            self.service.store(MISSING, Ordering::Relaxed);
            return;
        };
        let _ = bus.set_timeout(Some(CALL));
        let owned = matches!(
            bus.call(BUS, BUS_PATH, BUS, "NameHasOwner", &[Value::Str(NAME.into())]).as_deref(),
            Ok([Value::Bool(true), ..])
        );
        let activatable = !owned
            && matches!(bus.call(BUS, BUS_PATH, BUS, "ListActivatableNames", &[]).as_deref(),
                Ok([Value::Array(_, names), ..]) if names.iter().any(|n| n.as_str() == Some(NAME)));
        let available = owned || activatable;
        self.service.store(if available { AVAILABLE } else { MISSING }, Ordering::Relaxed);
        if owned {
            if let Ok([Value::Array(_, capabilities), ..]) =
                bus.call(NAME, PATH, NAME, "GetCapabilities", &[]).as_deref()
            {
                self.markup = capabilities.iter().any(|c| c.as_str() == Some("body-markup"));
            }
        }
    }

    fn handle(&mut self, command: Command) {
        if self.bus.is_none() {
            self.check();
        }
        let Some(bus) = self.bus.as_mut() else { return };
        let _ = bus.set_timeout(Some(CALL));
        match command {
            Command::Post(request) => {
                // A new request for a conversation replaces its last one, as the newest of a burst does.
                let replaces = self.ids.iter().find(|(_, (thread, _))| thread == &request.thread).map(|(id, _)| *id);
                let arguments = notify_arguments(&request, self.icon.as_deref(), self.markup, replaces.unwrap_or(0));
                match bus.call(NAME, PATH, NAME, "Notify", &arguments).as_deref() {
                    Ok([Value::U32(id), ..]) => {
                        if let Some(old) = replaces {
                            self.ids.remove(&old);
                        }
                        self.ids.insert(*id, (request.thread.clone(), request.key.clone()));
                        self.service.store(AVAILABLE, Ordering::Relaxed);
                    }
                    Ok(_) => {}
                    Err(error) => crate::log!("a notification was not shown: {error}"),
                }
            }
            Command::Withdraw(thread) => {
                let ids: Vec<u32> = self.ids.iter().filter(|(_, (t, _))| *t == thread).map(|(id, _)| *id).collect();
                for id in ids {
                    self.ids.remove(&id);
                    let _ = bus.call(NAME, PATH, NAME, "CloseNotification", &[Value::U32(id)]);
                }
            }
        }
    }

    fn signal(&mut self, message: &crate::linux::dbus::Message) {
        if message.is_signal(NAME, "ActionInvoked") {
            if let [Value::U32(id), Value::Str(action), ..] = message.body.as_slice() {
                if action == "default" {
                    if let Some((_, key)) = self.ids.get(id) {
                        (self.responder)(Response::Open { key: key.clone() });
                    }
                }
            }
        } else if message.is_signal(NAME, "NotificationClosed") {
            if let Some(Value::U32(id)) = message.body.first() {
                self.ids.remove(id);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linux::marshal::{Decoder, Encoder};
    use crate::notify::{Open, Request};

    fn request() -> Request {
        Request {
            key: "message:i_81f2".into(),
            kind: "message",
            channel: "messages",
            conversation_id: Some("c_mei".into()),
            thread: "c_mei".into(),
            title: "Mei".into(),
            body: "<b>bold</b> & more".into(),
            time: "2026-10-21T08:12:03Z".into(),
            reply: None,
            open: Open { url: "shenzhen3d://friends/conversation/c_mei".into(), app_id: "x".into(), app_path: None },
        }
    }

    #[test]
    fn notify_carries_the_specifications_eight_arguments() {
        let icon = PathBuf::from("/home/ada/.local/state/friends/notify-icon.png");
        let arguments = notify_arguments(&request(), Some(&icon), true, 7);
        let signature: String = arguments.iter().map(Value::signature).collect();
        assert_eq!(signature, "susssasa{sv}i");
        assert_eq!(arguments[0], Value::Str("Shenzhen Friends".into()));
        assert_eq!(arguments[1], Value::U32(7));
        assert_eq!(arguments[3], Value::Str("Mei".into()));
        assert_eq!(arguments[4], Value::Str("&lt;b&gt;bold&lt;/b&gt; &amp; more".into()), "markup escaped");
        assert_eq!(
            arguments[5],
            Value::Array("s".into(), vec![Value::Str("default".into()), Value::Str(String::new())])
        );
        let plain = notify_arguments(&request(), None, false, 0);
        assert_eq!(plain[4], Value::Str("<b>bold</b> & more".into()), "a service without markup shows the text");
        assert_eq!(plain[2], Value::Str(String::new()));
    }

    #[test]
    fn notify_marshals_and_reads_back() {
        let arguments = notify_arguments(&request(), Some(Path::new("/tmp/i.png")), false, 0);
        let mut encoder = Encoder::new();
        for argument in &arguments {
            encoder.value(argument);
        }
        let bytes = encoder.finish();
        let decoded = Decoder::new(&bytes, false, 0).values("susssasa{sv}i").expect("decodes");
        assert_eq!(decoded, arguments);
        // Little-endian: the app name's length first, then its bytes and the terminating zero.
        assert_eq!(&bytes[..4], &(APP_NAME.len() as u32).to_le_bytes());
        assert_eq!(&bytes[4..4 + APP_NAME.len()], APP_NAME.as_bytes());
    }
}
