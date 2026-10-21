//! Friends in the app's Rust process: one link per app, shared by every window that joined; the status the page
//! reads; intents checked and routed; the windows' event channels; received files the service offered to open; and
//! Friends links waiting for a window. The Tauri side of Shenzhen 3D's Electron host (`electron/friends/host.cjs`).

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::{json, Value};
use szfriends_helper::client::AppInfo;
use tauri::ipc::Channel;
use tauri::{AppHandle, Manager, Runtime};

use crate::link::{state_text, Connector, Link, LinkEvent, LinkState};
use crate::router::{not_ready, refusal, Delivery, Owner, Routed, Router};
use crate::validate::{validate_intent, FieldError};
use crate::Config;

#[path = "share.rs"]
mod share;
pub use share::{ShareMenu, LINK_DAYS};

const MAX_OFFERED_FILES: usize = 4096;

/// What the app's panel implements, and on a phone `files.share`: received files go to the share sheet.
fn client_capabilities(app: &[String]) -> Vec<String> {
    let mut capabilities = app.to_vec();
    if cfg!(any(target_os = "android", target_os = "ios")) && !capabilities.iter().any(|c| c == "files.share") {
        capabilities.push("files.share".into());
    }
    capabilities
}

#[derive(Default)]
struct State {
    enabled: Option<bool>,
    link: Option<Link>,
    link_state: Option<LinkState>,
    router: Router,
    windows: HashMap<String, Channel<Value>>,
    offered: VecDeque<String>,
    offered_set: HashSet<String>,
    pending_link: Option<String>,
    state_dir: Option<PathBuf>,
    share: share::Share,
}

pub struct Host<R: Runtime> {
    app: AppHandle<R>,
    pub config: Config<R>,
    /// Where Friends' pieces are; None when this build offers no Friends.
    connector: Option<Arc<dyn Connector>>,
    /// Where the bridge keeps the setting and staged files when the app names no place (phones: beside Friends).
    data_dir: Option<PathBuf>,
    available: bool,
    animals: Option<crate::files::AnimalSet>,
    state: Mutex<State>,
}

impl<R: Runtime> std::fmt::Debug for Host<R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Host").field("available", &self.available).finish()
    }
}

impl<R: Runtime> Host<R> {
    pub fn new(app: AppHandle<R>, config: Config<R>, located: Option<crate::Located>) -> Arc<Self> {
        let available = located.is_some();
        let (connector, state_dir, animals, data_dir) = match located {
            Some(l) => (Some(l.connector), Some(l.state_dir), l.animals.map(crate::files::AnimalSet::new), l.data_dir),
            None => (None, None, None, None),
        };
        let state = State { state_dir, ..State::default() };
        Arc::new(Self { app, config, connector, data_dir, available, animals, state: Mutex::new(state) })
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn state_dir(&self) -> Option<PathBuf> {
        self.lock().state_dir.clone()
    }

    fn settings_file(&self) -> Option<PathBuf> {
        let directory = self.config.data_dir.clone().or_else(|| self.data_dir.clone());
        let directory = directory.or_else(|| self.app.path().app_config_dir().ok());
        directory.map(|d| d.join("friends.json"))
    }

    pub fn outgoing(&self) -> Option<PathBuf> {
        let directory = self.config.data_dir.clone().or_else(|| self.data_dir.clone());
        let directory = directory.or_else(|| self.app.path().app_data_dir().ok());
        directory.map(|d| d.join("Friends").join("Outgoing"))
    }

    fn read_enabled(&self) -> bool {
        if let Some(enabled) = self.lock().enabled {
            return enabled;
        }
        let stored = self
            .settings_file()
            .and_then(|f| std::fs::read_to_string(f).ok())
            .and_then(|text| serde_json::from_str::<Value>(&text).ok());
        // Enable Shenzhen Friends is on by default.
        let enabled = stored.is_none_or(|v| v["enabled"] != false);
        self.lock().enabled = Some(enabled);
        enabled
    }

    pub fn status(&self) -> Value {
        let state = self.lock();
        let link_state = state.link_state.unwrap_or(LinkState::Idle);
        let welcome = state.router.welcome.as_ref();
        json!({
            "available": self.available,
            "enabled": state.enabled != Some(false),
            "attached": state.link.is_some(),
            "state": link_state.name(),
            "text": state_text(link_state, &self.config.app_name),
            "strings": welcome.map_or(Value::Null, |w| w["strings"].clone()),
            "capabilities": welcome.map_or(json!([]), |w| w.get("capabilities").cloned().unwrap_or(json!([]))),
            "limits": welcome.map_or(Value::Null, |w| w.get("limits").cloned().unwrap_or(Value::Null)),
            "badge": state.router.badge.clone(),
        })
    }

    fn deliver(&self, deliveries: Vec<Delivery>) {
        let state = self.lock();
        for delivery in deliveries {
            match delivery {
                Delivery::To(label, event) => {
                    if let Some(channel) = state.windows.get(&label) {
                        let _ = channel.send(event);
                    }
                }
                Delivery::All(event) => {
                    for channel in state.windows.values() {
                        let _ = channel.send(event.clone());
                    }
                }
            }
        }
    }

    fn announce(&self) {
        let status = self.status();
        self.deliver(vec![Delivery::All(json!({"kind": "status", "status": status}))]);
        self.refresh_share_menu();
    }

    /// A window's page joined (after its first paint): its events go to `channel`, and the first join attaches.
    pub fn join(self: &Arc<Self>, label: &str, channel: Channel<Value>) -> Value {
        let (ready, has_link) = {
            let mut state = self.lock();
            state.windows.insert(label.to_owned(), channel);
            (state.link_state == Some(LinkState::Ready), state.link.is_some())
        };
        if !has_link && self.available {
            self.attach();
        }
        if ready {
            self.offer_pending_link();
        }
        self.status()
    }

    fn attach(self: &Arc<Self>) {
        if !self.read_enabled() {
            return;
        }
        let mut state = self.lock();
        if state.link.is_some() {
            return;
        }
        let Some(connector) = self.connector.clone() else { return };
        let app = AppInfo {
            app_id: self.config.app_id.clone(),
            app_name: self.config.app_name.clone(),
            app_version: self.config.app_version.clone(),
            toolkit: "tauri".into(),
            reveal_in: crate::reveal_in().into(),
            capabilities: client_capabilities(&self.config.capabilities),
            open_formats: self.config.open_formats.clone(),
            locale: self.config.locale.clone(),
            url_scheme: None,
        };
        let host = Arc::downgrade(self);
        let sink: crate::link::Sink = Arc::new(move |event| {
            if let Some(host) = host.upgrade() {
                host.on_event(event);
            }
        });
        state.link = Some(Link::start(connector, app, sink));
        drop(state);
        if let Some(outgoing) = self.outgoing() {
            std::thread::spawn(move || crate::files::sweep_outgoing(&outgoing));
        }
        self.announce();
    }

    /// Turning Friends off tells the service (`disable`), after which a helper no other app needs exits.
    fn detach(&self, disabling: bool) {
        let mut state = self.lock();
        let Some(link) = state.link.take() else { return };
        link.stop(disabling);
        let deliveries = state.router.stopped();
        state.link_state = Some(LinkState::Idle);
        drop(state);
        self.deliver(deliveries);
    }

    fn on_event(self: &Arc<Self>, event: LinkEvent) {
        match event {
            LinkEvent::Frame(frame) => {
                if frame["type"] == "snapshot" {
                    self.offer(&frame);
                }
                let deliveries = self.lock().router.frame(frame);
                self.deliver(deliveries);
            }
            LinkEvent::State(link_state) => {
                let ready = link_state == LinkState::Ready;
                let deliveries = {
                    let mut state = self.lock();
                    state.link_state = Some(link_state);
                    let deliveries = state.router.connection_changed(ready);
                    if !ready {
                        state.router.lose_pending();
                    }
                    deliveries
                };
                self.deliver(deliveries);
                if ready {
                    self.send_from_host("subscribe", json!({"view": "badge"}));
                }
                self.announce();
                if ready {
                    self.offer_pending_link();
                }
            }
        }
    }

    fn send_from_host(&self, kind: &str, fields: Value) {
        let mut state = self.lock();
        let Some(link) = state.link.clone() else { return };
        let map = fields.as_object().cloned().unwrap_or_default();
        if let Some(id) = link.send(kind, &map) {
            drop(state.router.sent(&id, Owner::Host, kind, fields));
        }
    }

    /// Received files the service offered to open, newest kept; Open opens only these, so a page cannot ask for any
    /// other file on the disk.
    fn offer(&self, frame: &Value) {
        let mut found = Vec::new();
        crate::files::openable_paths(&frame["data"], &mut found, 0);
        if found.is_empty() {
            return;
        }
        let mut state = self.lock();
        for file in found {
            if state.offered_set.insert(file.clone()) {
                state.offered.push_back(file);
            } else {
                state.offered.retain(|f| *f != file);
                state.offered.push_back(file);
            }
            if state.offered.len() > MAX_OFFERED_FILES {
                if let Some(oldest) = state.offered.pop_front() {
                    state.offered_set.remove(&oldest);
                }
            }
        }
    }

    /// The bundled animal set, beside the helper (desktops) or in the app's resources (phones).
    pub fn animals(&self) -> Option<&crate::files::AnimalSet> {
        self.animals.as_ref()
    }

    pub fn was_offered(&self, file: &str) -> bool {
        self.lock().offered_set.contains(file)
    }

    pub async fn send(self: &Arc<Self>, label: &str, kind: &Value, fields: &Value) -> Value {
        let fields = match validate_intent(kind, fields) {
            Ok(fields) => fields,
            Err(FieldError(field)) => return json!({"reply": refusal("invalid_field", json!({"field": field}))}),
        };
        let kind = kind.as_str().unwrap_or_default();
        let owner = Owner::Window(label.to_owned());
        let receiver = {
            let mut state = self.lock();
            let Some(link) = state.link.clone().filter(|_| state.link_state == Some(LinkState::Ready)) else {
                return json!({"reply": not_ready()});
            };
            let subscribes = kind == "subscribe" || kind == "open_conversation";
            if subscribes && !state.router.may_add_subscription(&owner) {
                return json!({"reply": refusal("too_many_subscriptions", json!({}))});
            }
            let Some(id) = link.send(kind, &fields) else { return json!({"reply": not_ready()}) };
            state.router.sent(&id, owner, kind, Value::Object(fields))
        };
        match receiver.await {
            Ok(Routed { reply, snapshot: Some(snapshot) }) => json!({"reply": reply, "snapshot": snapshot}),
            Ok(Routed { reply, snapshot: None }) => json!({"reply": reply}),
            Err(_) => json!({"reply": crate::router::connection_lost(None)}),
        }
    }

    pub fn set_enabled(self: &Arc<Self>, enabled: bool) -> Value {
        self.lock().enabled = Some(enabled);
        if let Some(file) = self.settings_file() {
            if let Some(parent) = file.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(&file, format!("{}\n", json!({"enabled": enabled})));
        }
        if enabled {
            if !self.lock().windows.is_empty() {
                self.attach();
            }
        } else {
            self.detach(true);
        }
        self.announce();
        self.status()
    }

    /// A window closed or its page started again: its subscriptions go with it.
    pub fn forget(&self, label: &str) {
        self.forget_shareable(label);
        self.refresh_share_menu();
        let subscriptions = {
            let mut state = self.lock();
            if state.windows.remove(label).is_none() {
                return;
            }
            state.router.drop_owner(&Owner::Window(label.to_owned()))
        };
        for subscription in subscriptions {
            self.send_from_host("unsubscribe", json!({"subscription": subscription}));
        }
    }

    /// A Friends link opened in this app (PROTOCOL.md § Links): given to the focused window once Friends is ready.
    pub fn open_link(self: &Arc<Self>, url: &str) -> bool {
        let Some(payload) = crate::urls::link_payload(url, &self.config.link_scheme) else { return false };
        if !self.available {
            return false;
        }
        self.lock().pending_link = Some(payload);
        self.offer_pending_link();
        true
    }

    fn offer_pending_link(&self) {
        let mut state = self.lock();
        if state.link_state != Some(LinkState::Ready) || state.windows.is_empty() {
            return;
        }
        let focused = self
            .app
            .webview_windows()
            .into_iter()
            .find(|(label, w)| state.windows.contains_key(label) && w.is_focused().unwrap_or(false))
            .map(|(label, _)| label);
        let Some(label) = focused.or_else(|| state.windows.keys().next().cloned()) else { return };
        if let Some(payload) = state.pending_link.take() {
            if let Some(channel) = state.windows.get(&label) {
                let _ = channel.send(json!({"kind": "link", "payload": payload}));
            }
        }
    }

    /// The app came to the foreground or left it (phones).
    #[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
    pub fn foreground(&self, in_front: bool) {
        if let Some(connector) = &self.connector {
            connector.foreground(in_front);
        }
    }

    /// The app is quitting: the helper keeps serving other apps and exits on its own when none remains.
    pub fn dispose(&self) {
        self.detach(false);
    }
}
