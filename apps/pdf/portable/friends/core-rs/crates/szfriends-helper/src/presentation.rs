//! What the server asks of the Friends service: the welcome's capabilities and strings, each intent's reply and the
//! snapshots before it, and what to do on system events and at exit. The service (`szfriends-core`'s presentation
//! and intents) implements it; until it lands, [`StubPresentation`] answers with a zero badge, so the transport,
//! lifecycle and handover run end to end.

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde_json::{json, Value};
use szfriends_contract::handshake::ClientInfo;

use crate::events::SystemEvent;
use crate::server::{Connection, Reply};

pub trait Presentation: Send + Sync + 'static {
    /// The welcome's `capabilities`, `limits` and `strings` for this client; the server fills the frozen fields.
    fn welcome(&self, client: &ClientInfo) -> Value;

    /// A client completed its hello.
    fn connected(&self, _connection: &Connection) {}

    /// One intent (never `hello` or `disable`, which the server answers). Exactly one reply through `reply`, now or
    /// later from any thread; snapshots reflecting the intent go through `connection.send` before it. A `Reply`
    /// dropped unanswered answers `internal`.
    fn intent(&self, connection: &Connection, intent: &Value, reply: Reply);

    /// The connection closed; its subscriptions end with it.
    fn disconnected(&self, _connection_id: u64) {}

    /// Sleep, wake or a network change (ADR 0015 § 16).
    fn system_event(&self, _event: SystemEvent) {}

    /// A chunk in flight or a store transaction open: a handover waits for it, at most 5 seconds.
    fn work_in_flight(&self) -> bool {
        false
    }

    /// The helper is about to exit: make progress durable and close sessions.
    fn shutdown(&self) {}
}

/// Until the presentation wave lands: `ping`, `activate` and `unsubscribe` succeed, `badge` subscriptions get the
/// zero badge PROTOCOL.md specifies, other views and intents are not served yet.
#[derive(Debug, Default)]
pub struct StubPresentation {
    next_subscription: AtomicU64,
    subscriptions: Mutex<HashSet<(u64, String)>>,
    events: Mutex<Vec<SystemEvent>>,
}

impl StubPresentation {
    /// The system events received so far (for tests and the log).
    pub fn system_events(&self) -> Vec<SystemEvent> {
        self.events.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn subscribe(&self, connection: &Connection, intent: &Value, reply: Reply) {
        if intent["view"].as_str() != Some("badge") {
            return reply.error("internal", None, json!({}));
        }
        let id = format!("s_{}", self.next_subscription.fetch_add(1, Ordering::Relaxed) + 1);
        self.subscriptions.lock().unwrap_or_else(|e| e.into_inner()).insert((connection.id(), id.clone()));
        let data = json!({"count": 0, "label": "", "accessibility_label": "Friends"});
        connection.send(&json!({"type": "snapshot", "subscription": id, "view": "badge", "rev": 1, "data": data}));
        reply.ok(json!({"subscription": id}));
    }
}

impl Presentation for StubPresentation {
    fn welcome(&self, _client: &ClientInfo) -> Value {
        json!({"capabilities": [], "strings": {}})
    }

    fn intent(&self, connection: &Connection, intent: &Value, reply: Reply) {
        match intent["type"].as_str().unwrap_or_default() {
            "ping" | "activate" => reply.ok(json!({})),
            "subscribe" => self.subscribe(connection, intent, reply),
            "unsubscribe" => {
                let key = (connection.id(), intent["subscription"].as_str().unwrap_or_default().to_owned());
                if self.subscriptions.lock().unwrap_or_else(|e| e.into_inner()).remove(&key) {
                    reply.ok(json!({}))
                } else {
                    reply.error("not_found", None, json!({}))
                }
            }
            _ => reply.error("unknown_intent", None, json!({})),
        }
    }

    fn disconnected(&self, connection_id: u64) {
        self.subscriptions.lock().unwrap_or_else(|e| e.into_inner()).retain(|(id, _)| *id != connection_id);
    }

    fn system_event(&self, event: SystemEvent) {
        self.events.lock().unwrap_or_else(|e| e.into_inner()).push(event);
    }
}
