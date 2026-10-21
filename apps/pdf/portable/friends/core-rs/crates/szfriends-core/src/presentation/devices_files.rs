//! Conversations and files on several computers (`SZFriendsSnapshotBuilder+Devices.m` § Conversations, § Files): the
//! You conversation's header and composer, a removed computer's read-only composer, You messages reaching every
//! computer, files another computer holds, and You files copying to the others.

use serde_json::{json, Map, Value};

use super::devices::YOU_ID;
use super::facts::{ItemFacts, ItemKind, PersonFacts, RouteKind, RouteMethod};
use super::SnapshotBuilder;

pub(crate) fn percent_of(fraction: f64) -> i64 {
    ((fraction * 100.0).floor() as i64).clamp(0, 100)
}

impl SnapshotBuilder {
    pub(crate) fn is_you(&self, person: &PersonFacts) -> bool {
        person.conversation_id == YOU_ID
    }

    /// A conversation with what several computers change; without devices facts, as it is.
    pub(crate) fn conversation_with_devices(&self, conversation: Value, person: &PersonFacts) -> Value {
        let Some(facts) = &self.devices else { return conversation };
        let mut result = match conversation {
            Value::Object(map) => map,
            other => return other,
        };
        let s = &self.strings;
        let mut composer = match result.remove("composer") {
            Some(Value::Object(map)) => map,
            _ => Map::new(),
        };
        if self.is_you(person) {
            result.insert(
                "header".into(),
                json!({
                    "title": s.text("you.title"),
                    "subtitle": s.text("you.header.subtitle"),
                    "route": self.route_for_kind(RouteKind::None, RouteMethod::None),
                    "avatar": self.own_avatar_for_you(person),
                    "details_available": false,
                    "accessibility_label": s.text("you.header.accessibility"),
                }),
            );
            result.insert("request".into(), Value::Null);
            composer.insert("placeholder".into(), json!(s.text("you.composer.placeholder")));
            // The note shows only while something here has not reached every computer yet.
            let waiting = result.get("items").and_then(Value::as_array).is_some_and(|items| {
                items.iter().any(|item| {
                    let message = item["status"]["state"] == "queued";
                    let file = item["kind"] == "transfer" && (item["state"] == "queued" || item["state"] == "sending");
                    item["direction"] == "out" && (message || file)
                })
            });
            let note =
                waiting.then(|| s.text_with("you.composer.note.waiting", &[("apps", &s.text("apps.with_friends"))]));
            composer.insert("note".into(), json!(note));
        }
        if facts.removed {
            // Chats stay readable; nothing is sent from here any more.
            composer.insert("visible".into(), json!(false));
            composer.insert("enabled".into(), json!(false));
            composer.insert("accepts_drops".into(), json!(false));
        }
        result.insert("composer".into(), Value::Object(composer));
        Value::Object(result)
    }

    /// An outgoing You message's status, or None when the conversation is not You.
    pub(crate) fn you_status(&self, item: &ItemFacts, person: &PersonFacts) -> Option<Value> {
        let facts = self.devices.as_ref()?;
        if !self.is_you(person) || !item.outgoing || item.kind != ItemKind::Message {
            return None;
        }
        let state = if facts.you_items_everywhere.contains(&item.item_id) { "delivered" } else { "queued" };
        Some(json!({"state": state, "label": self.strings.text(&format!("you.status.{state}"))}))
    }

    pub(crate) fn copy_progress(&self, fraction: f64) -> Value {
        let percent = percent_of(fraction);
        let label = self.strings.text_with("transfer.progress.copying", &[("percent", &percent.to_string())]);
        json!({"fraction": percent as f64 / 100.0, "determinate": true, "accessibility_label": label})
    }

    /// A transfer item as several computers show it: a file on another computer, being fetched, or a You file copying.
    pub(crate) fn transfer_with_devices(
        &self,
        mut transfer: Map<String, Value>,
        item: &ItemFacts,
        person: &PersonFacts,
    ) -> Map<String, Value> {
        let Some(facts) = &self.devices else { return transfer };
        let s = &self.strings;
        let transfer_id = transfer.get("transfer_id").and_then(Value::as_str).unwrap_or("").to_owned();
        let file = facts.files.get(&transfer_id);
        let you = self.is_you(person) && item.outgoing;
        if file.is_none() && !you {
            return transfer;
        }
        let info = transfer.get("file").cloned().unwrap_or(Value::Null);
        let field = |key: &str| info[key].as_str().unwrap_or("").to_owned();
        let sender = if item.outgoing { String::new() } else { self.title_for_person(person) };
        let (name, kind, size) = (field("name"), field("kind_label"), field("size_label"));
        let device = file.map(|f| f.device_name.clone()).unwrap_or_default();
        let apps = s.text("apps.with_friends");
        let fraction = match file {
            Some(file) => file.fraction,
            None => facts.you_copying.get(&transfer_id).copied().unwrap_or(0.0),
        };
        let percent = percent_of(fraction).to_string();
        let values = [
            ("sender", sender.as_str()),
            ("file", name.as_str()),
            ("kind", kind.as_str()),
            ("size", size.as_str()),
            ("device", device.as_str()),
            ("apps", apps.as_str()),
            ("percent", percent.as_str()),
        ];
        let mut spoken_key = if item.outgoing { "devices.spoken.transfer.out" } else { "devices.spoken.transfer.in" };
        let mut progress = Value::Null;
        let mut actions = json!([self.action("cancel_transfer", s.text("static.cancel"), "link")]);
        let state = transfer.get("state").cloned().unwrap_or(Value::Null);
        let (state, status) = match file {
            Some(file) if !file.fetching => {
                actions = json!([self.action("fetch_from_device", s.text("transfer.action.fetch"), "primary")]);
                ("on_device", s.text_with("transfer.status.on_device", &values))
            }
            Some(file) if file.holder_connected => {
                progress = self.copy_progress(fraction);
                spoken_key = "devices.spoken.transfer.fetching";
                ("fetching", s.text_with("transfer.status.fetching", &values))
            }
            Some(_) => {
                let key = if s.reaches_online() {
                    "transfer.status.fetch_waiting.online"
                } else {
                    "transfer.status.fetch_waiting"
                };
                ("fetching", s.text_with(key, &values))
            }
            // A You file that will not go keeps its own words.
            None if state == "failed" || state == "cancelled" => return transfer,
            None if facts.you_copying.contains_key(&transfer_id) => {
                progress = self.copy_progress(fraction);
                spoken_key = "you.transfer.spoken.sending";
                ("sending", s.text_with("you.transfer.status.sending", &values))
            }
            None if facts.you_items_everywhere.contains(&item.item_id) => {
                // Nothing left to stop: Open and Show where the copy is here, else nothing.
                let here = item.local_path.as_deref().is_some_and(|p| !p.is_empty());
                actions = if here { transfer.get("actions").cloned().unwrap_or(json!([])) } else { json!([]) };
                ("delivered", s.text("you.transfer.status.delivered"))
            }
            None => {
                spoken_key = "you.transfer.spoken.queued";
                ("queued", s.text("you.transfer.status.queued"))
            }
        };
        // Said inside a sentence, except where the template makes it a sentence of its own; the template ends it.
        let said = if spoken_key == "you.transfer.spoken.queued" { status.clone() } else { s.spoken_fragment(&status) };
        let said = said.strip_suffix('.').unwrap_or(&said).to_owned();
        let mut spoken_values = values.to_vec();
        spoken_values.push(("status", &said));
        transfer.insert("state".into(), json!(state));
        transfer.insert("status_label".into(), json!(status));
        transfer.insert("progress".into(), progress);
        transfer.insert("route_note".into(), Value::Null);
        transfer.insert("actions".into(), actions);
        transfer.insert("accessibility_label".into(), json!(s.text_with(spoken_key, &spoken_values)));
        transfer
    }
}
