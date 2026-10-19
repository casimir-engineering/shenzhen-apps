//! Routes the service's frames to the windows that asked for them; the rules of Shenzhen 3D's Electron router
//! (`electron/friends/router.cjs`), so both shells behave alike. Pure: no Tauri, no sockets.
//!
//! - One link per app, shared by every window that joined.
//! - Each intent remembers the window that sent it; its reply goes back to that window only.
//! - A subscription belongs to the window whose subscribe or open_conversation created it. The service sends the
//!   first snapshot before the reply that names the subscription (PROTOCOL.md § Snapshots), so a snapshot for a
//!   subscription nobody owns yet is held (the latest one only; snapshots are complete) and handed over with the
//!   reply.
//! - The badge is the bridge's own subscription, sent to every window, so many windows cost one subscription.
//! - Subscription ids never survive a reconnect: when the link is no longer ready, every owner is forgotten and the
//!   windows subscribe again once it is.

use std::collections::{HashMap, VecDeque};

use serde_json::{json, Value};
use tokio::sync::oneshot;

/// Who sent an intent: a window (its webview label) or the bridge itself.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Owner {
    Host,
    Window(String),
}

/// What a window's `send` resolves with.
#[derive(Clone, Debug, PartialEq)]
pub struct Routed {
    pub reply: Value,
    pub snapshot: Option<Value>,
}

/// Something to hand to one window or to all.
#[derive(Clone, Debug, PartialEq)]
pub enum Delivery {
    To(String, Value),
    All(Value),
}

const MAX_HELD: usize = 64;
pub const MAX_SUBSCRIPTIONS_PER_WINDOW: usize = 12;

pub fn connection_lost(id: Option<&str>) -> Value {
    json!({"type": "reply", "re": id, "ok": false,
           "error": {"code": "connection_lost", "message": null, "retryable": true, "details": {}}})
}

pub fn not_ready() -> Value {
    json!({"type": "reply", "re": null, "ok": false,
           "error": {"code": "not_ready", "message": null, "retryable": true, "details": {}}})
}

pub fn refusal(code: &str, details: Value) -> Value {
    json!({"type": "reply", "re": null, "ok": false,
           "error": {"code": code, "message": null, "retryable": false, "details": details}})
}

struct Pending {
    owner: Owner,
    kind: String,
    fields: Value,
    resolve: Option<oneshot::Sender<Routed>>,
}

fn creates_subscription(kind: &str) -> bool {
    kind == "subscribe" || kind == "open_conversation"
}

#[derive(Default)]
pub struct Router {
    pending: HashMap<String, Pending>,
    owners: HashMap<String, Owner>,
    /// Snapshots nobody owns yet, oldest first.
    held: VecDeque<(String, Value)>,
    pub welcome: Option<Value>,
    pub badge: Option<Value>,
}

impl std::fmt::Debug for Router {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Router").field("pending", &self.pending.len()).field("owners", &self.owners.len()).finish()
    }
}

impl Router {
    /// Records an intent the link accepted; the receiver resolves once its reply arrives.
    pub fn sent(&mut self, id: &str, owner: Owner, kind: &str, fields: Value) -> oneshot::Receiver<Routed> {
        let (resolve, receiver) = oneshot::channel();
        self.pending.insert(id.to_owned(), Pending { owner, kind: kind.to_owned(), fields, resolve: Some(resolve) });
        receiver
    }

    pub fn subscription_count(&self, owner: &Owner) -> usize {
        let owned = self.owners.values().filter(|o| *o == owner).count();
        let asked = self.pending.values().filter(|p| p.owner == *owner && creates_subscription(&p.kind)).count();
        owned + asked
    }

    pub fn may_add_subscription(&self, owner: &Owner) -> bool {
        self.subscription_count(owner) < MAX_SUBSCRIPTIONS_PER_WINDOW
    }

    /// One frame from the service.
    pub fn frame(&mut self, frame: Value) -> Vec<Delivery> {
        match frame["type"].as_str() {
            Some("welcome") => {
                self.welcome = Some(frame);
                Vec::new()
            }
            Some("reply") => self.reply(frame),
            Some("snapshot") => self.snapshot(frame),
            // goodbye: the link reports the state change that follows; unknown types are ignored.
            _ => Vec::new(),
        }
    }

    fn take_held(&mut self, subscription: &str) -> Option<Value> {
        let index = self.held.iter().position(|(id, _)| id == subscription)?;
        self.held.remove(index).map(|(_, frame)| frame)
    }

    fn reply(&mut self, frame: Value) -> Vec<Delivery> {
        let Some(id) = frame["re"].as_str() else { return Vec::new() };
        let Some(mut entry) = self.pending.remove(id) else { return Vec::new() };
        let mut deliveries = Vec::new();
        let mut snapshot = None;
        let subscription = frame["result"]["subscription"].as_str().filter(|_| frame["ok"] == true);
        if let (Some(subscription), true) = (subscription, creates_subscription(&entry.kind)) {
            self.owners.insert(subscription.to_owned(), entry.owner.clone());
            snapshot = self.take_held(subscription);
            if entry.owner == Owner::Host {
                if let Some(held) = snapshot.take().filter(|s| s["view"] == "badge") {
                    deliveries.push(self.badge_snapshot(&held));
                }
            }
        }
        if entry.kind == "unsubscribe" {
            if let Some(subscription) = entry.fields["subscription"].as_str() {
                // Nothing more arrives for it; forget the owner so a later reuse of the id cannot reach the old
                // window.
                if self.owners.get(subscription) == Some(&entry.owner) {
                    self.owners.remove(subscription);
                }
            }
        }
        if let Some(resolve) = entry.resolve.take() {
            let _ = resolve.send(Routed { reply: frame, snapshot });
        }
        deliveries
    }

    fn snapshot(&mut self, frame: Value) -> Vec<Delivery> {
        let Some(subscription) = frame["subscription"].as_str().map(str::to_owned) else { return Vec::new() };
        match self.owners.get(&subscription).cloned() {
            None => {
                self.held.retain(|(id, _)| *id != subscription);
                if self.held.len() >= MAX_HELD {
                    self.held.pop_front();
                }
                self.held.push_back((subscription, frame));
                Vec::new()
            }
            Some(Owner::Host) if frame["view"] == "badge" => vec![self.badge_snapshot(&frame)],
            Some(Owner::Host) => Vec::new(),
            Some(Owner::Window(label)) => vec![Delivery::To(label, json!({"kind": "snapshot", "frame": frame}))],
        }
    }

    fn badge_snapshot(&mut self, frame: &Value) -> Delivery {
        let data = frame.get("data").cloned().unwrap_or(Value::Null);
        self.badge = Some(data.clone()).filter(|d| !d.is_null());
        Delivery::All(json!({"kind": "badge", "data": data}))
    }

    /// A window closed or reloaded: the subscriptions to unsubscribe for it. Its pending intents resolve as lost.
    pub fn drop_owner(&mut self, owner: &Owner) -> Vec<String> {
        let mut subscriptions: Vec<String> =
            self.owners.iter().filter(|(_, o)| *o == owner).map(|(s, _)| s.clone()).collect();
        subscriptions.sort();
        for subscription in &subscriptions {
            self.owners.remove(subscription);
        }
        let lost: Vec<String> =
            self.pending.iter().filter(|(_, p)| p.owner == *owner).map(|(id, _)| id.clone()).collect();
        for id in lost {
            if let Some(mut entry) = self.pending.remove(&id) {
                if let Some(resolve) = entry.resolve.take() {
                    let _ = resolve.send(Routed { reply: connection_lost(Some(&id)), snapshot: None });
                }
            }
        }
        subscriptions
    }

    /// The link left READY: subscriptions are void (the windows subscribe again once it is back).
    pub fn connection_changed(&mut self, ready: bool) -> Vec<Delivery> {
        if ready {
            return Vec::new();
        }
        self.owners.clear();
        self.held.clear();
        self.welcome = None;
        if self.badge.take().is_some() {
            return vec![Delivery::All(json!({"kind": "badge", "data": null}))];
        }
        Vec::new()
    }

    /// Intents whose replies will never come (the link dropped or stopped): each resolves as lost.
    pub fn lose_pending(&mut self) {
        for (id, mut entry) in self.pending.drain() {
            if let Some(resolve) = entry.resolve.take() {
                let _ = resolve.send(Routed { reply: connection_lost(Some(&id)), snapshot: None });
            }
        }
    }

    /// The link was stopped: waiting intents are answered here and every subscription is void.
    pub fn stopped(&mut self) -> Vec<Delivery> {
        self.lose_pending();
        self.connection_changed(false)
    }
}

#[cfg(test)]
#[path = "tests/router.rs"]
mod tests;
