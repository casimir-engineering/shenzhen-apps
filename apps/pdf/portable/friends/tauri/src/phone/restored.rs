//! A phone's Friends store without its key (ADR 0015 § 17): the files came back from a backup or another device, the
//! key stayed with the old one. Nothing is created or mixed; the views say what happened and offer Start again, and
//! every other intent answers `identity_unavailable` (PROTOCOL.md § Errors).
//!
//! The person reading it is on this phone, wondering why Friends shows nothing they recognise and what Start again
//! will cost them; the words are ADR 0015 § 17's.

use std::collections::HashMap;
use std::sync::Mutex;

use serde_json::{json, Value};
use szfriends_contract::handshake::ClientInfo;
use szfriends_core::presentation::{Audience, IdentityState, ProfileFacts, SnapshotBuilder, Strings};
use szfriends_helper::presentation::Presentation;
use szfriends_helper::server::{Connection, Reply};

pub const BANNER: &str = "Friends can’t continue from a backup on this device. Start again to set up Friends here: \
                          the restored conversations are removed, and your friends will need to accept you again.";
pub const START_AGAIN: &str = "Start again";
/// Under "Your ID" while there is none on this device.
const PROFILE_NOTE: &str = "Friends can’t continue from a backup on this device. Start again in the Friends list to \
                            get an ID here.";
const CONFIRM_TITLE: &str = "Start again?";
const CONFIRM_BODY: &str = "The restored conversations are removed, and your friends will need to accept you again.";

/// The views a restored store still shows.
const VIEWS: &[&str] = &["badge", "list", "profile", "settings"];

/// A connection and its subscriptions (id, view).
type Subscribed = (Connection, Vec<(String, String)>);

/// What the restored state serves until Start again; `reset_friends` is answered by [`super::PhoneService`].
#[derive(Debug, Default)]
pub struct Restored {
    /// Per connection: its audience and its subscriptions (id, view).
    clients: Mutex<HashMap<u64, Subscribed>>,
    next: Mutex<u64>,
}

pub(crate) fn audience(client: &ClientInfo) -> Audience {
    Audience {
        app_name: client.app_name.clone(),
        reveal_in: client.reveal_in.clone(),
        locale: client.locale.clone(),
        capabilities: client.capabilities.clone(),
        open_formats: client.open_formats.clone(),
        ..Audience::default()
    }
}

/// One view's data for `client` while the store has no key.
pub fn view(client: &ClientInfo, view: &str) -> Option<Value> {
    let builder = SnapshotBuilder::new(audience(client), None);
    let profile = ProfileFacts { identity_state: IdentityState::Unavailable, ..ProfileFacts::default() };
    let mut data = match view {
        "badge" => builder.badge(&[], 0),
        "list" => builder.list(&[], &HashMap::new(), &profile, "", 0.0),
        "profile" => builder.profile(&profile, 0),
        "settings" => builder.settings(&profile, &[]),
        _ => return None,
    };
    if view == "profile" {
        data["id"]["note"] = json!(PROFILE_NOTE);
    }
    if view == "list" {
        // Naming yourself, adding friends or an empty list's suggestions mean nothing until Friends starts again.
        data["name_prompt"] = Value::Null;
        data["empty"] = Value::Null;
        data["footer"] = Value::Null;
        data["banner"] = json!({
            "kind": "identity_unavailable",
            "text": BANNER,
            "action": {
                "action": "reset_friends",
                "label": START_AGAIN,
                "style": "primary",
                "confirm": {
                    "title": CONFIRM_TITLE,
                    "body": CONFIRM_BODY,
                    "confirm_label": START_AGAIN,
                    "cancel_label": Strings::new(audience(client)).text("static.cancel"),
                    "destructive": true,
                },
            },
        });
    }
    Some(data)
}

impl Restored {
    fn subscribe(&self, connection: &Connection, intent: &Value, reply: Reply) {
        let Some(client) = connection.client() else { return reply.error("internal", None, json!({})) };
        let name = intent["view"].as_str().unwrap_or_default();
        if !VIEWS.contains(&name) {
            return reply.error("identity_unavailable", None, json!({}));
        }
        let Some(data) = view(&client, name) else { return reply.error("internal", None, json!({})) };
        let id = {
            let mut next = self.next.lock().unwrap_or_else(|e| e.into_inner());
            *next += 1;
            format!("r_{next}")
        };
        self.clients
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(connection.id())
            .or_insert_with(|| (connection.clone(), Vec::new()))
            .1
            .push((id.clone(), name.to_owned()));
        connection.send(&json!({"type": "snapshot", "subscription": id, "view": name, "rev": 1, "data": data}));
        reply.ok(json!({"subscription": id}));
    }
}

impl Presentation for Restored {
    fn welcome(&self, client: &ClientInfo) -> Value {
        json!({"capabilities": [], "strings": Strings::new(audience(client)).static_strings()})
    }

    fn connected(&self, connection: &Connection) {
        self.clients
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(connection.id())
            .or_insert_with(|| (connection.clone(), Vec::new()));
    }

    fn intent(&self, connection: &Connection, intent: &Value, reply: Reply) {
        match intent["type"].as_str().unwrap_or_default() {
            "ping" | "activate" => reply.ok(json!({})),
            "subscribe" => self.subscribe(connection, intent, reply),
            "unsubscribe" => {
                let wanted = intent["subscription"].as_str().unwrap_or_default();
                let mut clients = self.clients.lock().unwrap_or_else(|e| e.into_inner());
                let subscriptions = clients.get_mut(&connection.id()).map(|(_, s)| s);
                match subscriptions.and_then(|s| s.iter().position(|(id, _)| id == wanted).map(|at| s.remove(at))) {
                    Some(_) => reply.ok(json!({})),
                    None => reply.error("not_found", None, json!({})),
                }
            }
            _ => reply.error("identity_unavailable", None, json!({})),
        }
    }

    fn disconnected(&self, connection_id: u64) {
        self.clients.lock().unwrap_or_else(|e| e.into_inner()).remove(&connection_id);
    }
}
