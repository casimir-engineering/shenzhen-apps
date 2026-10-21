//! One profile on several computers (`SZFriendsSnapshotBuilder+Devices.m`, PROTOCOL.md § Devices): Your computers in
//! the profile, a computer another one removed, the You row, and the list's offer to join (`join_offer.rs`). The
//! reader is the person at one of their own computers: rows and labels speak of computers and of where things go,
//! never of how a computer belongs to the profile. Conversations and files are in `devices_files.rs`.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{json, Map, Value};

use super::facts::{ItemFacts, ItemKind, PersonFacts, RouteKind, RouteMethod};
use super::text::{is_newline, non_empty_trimmed};
use super::SnapshotBuilder;

pub(crate) const YOU_ID: &str = "you";
const DEVICE_NAME_MAX_BYTES: u64 = 64;

/// One computer of the profile as Your computers lists it.
#[derive(Clone, Debug, Default)]
pub struct DeviceFacts {
    /// Opaque, stable for the computer; revoke_device sends it back.
    pub device_id: String,
    /// "Raph’s Mac mini", as the computer named itself.
    pub name: String,
    /// "macOS 26.1".
    pub system: String,
    pub this_computer: bool,
    /// A session with it is live now.
    pub connected: bool,
    /// The last session with it; None: never reached from here.
    pub last_seen_at: Option<f64>,
}

/// A file one of the person's other computers holds and this one does not have yet.
#[derive(Clone, Debug, Default)]
pub struct DeviceFileFacts {
    /// The computer that has it.
    pub device_name: String,
    /// The person pressed Get.
    pub fetching: bool,
    /// A session with that computer is live, so it copies now.
    pub holder_connected: bool,
    /// How much arrived, while it copies.
    pub fraction: f64,
    /// The live session with that computer; None without one.
    pub route: RouteMethod,
}

#[derive(Clone, Debug, Default)]
pub struct DevicesFacts {
    /// The pass's time: when each computer last connected is counted from it.
    pub now: f64,
    /// This computer first, then the others by when they joined; removed computers are left out.
    pub computers: Vec<DeviceFacts>,
    /// Another of the person's computers removed this one: it reads, and sends nothing.
    pub removed: bool,
    /// Joining an existing profile can start at once: this computer has nobody in Friends and no other computer.
    pub join_offered: bool,
    /// Joining is offered after Reset Friends: no other computer, but people in Friends it would lose.
    pub join_replaces: bool,
    /// This profile's Friends ID: what another computer types to join it, and the ID joining here would replace.
    pub friends_id: Option<String>,
    /// The You conversation while its row shows, and its newest item.
    pub you: Option<PersonFacts>,
    pub you_preview: Option<ItemFacts>,
    /// You items every other computer holds, by item id.
    pub you_items_everywhere: BTreeSet<String>,
    /// You files being copied to another computer now, by transfer id: how much of the file that copy has.
    pub you_copying: BTreeMap<String, f64>,
    /// Files on another computer and not here, by transfer id.
    pub files: BTreeMap<String, DeviceFileFacts>,
}

impl SnapshotBuilder {
    /// Whether Delete history speaks of every computer (two or more).
    pub(crate) fn deletes_on_every_computer(&self) -> bool {
        self.devices.as_ref().is_some_and(|d| d.computers.len() >= 2)
    }

    fn device_row(&self, device: &DeviceFacts, removed: bool, now: f64) -> Value {
        let s = &self.strings;
        let mut spoken: Option<String> = None;
        let (last, state, spoken_key) = if device.this_computer {
            let spoken_key = self.device_key("devices.accessibility.this_computer");
            (s.text(&self.device_key("devices.last.this_computer")), "connected", spoken_key)
        } else if device.connected {
            (s.text("devices.last.now"), "connected", "devices.accessibility.now".to_owned())
        } else if let Some(seen) = device.last_seen_at {
            let ago = (now - seen).max(0.0);
            let minutes = ((ago / 60.0).floor() as i64).max(1);
            let last = if ago < 3600.0 {
                spoken = Some(s.text_count("devices.last.minutes.spoken", minutes, &[]));
                s.text_count("devices.last.minutes", minutes, &[])
            } else {
                spoken = Some(s.time_accessibility_label(seen, now));
                s.time_label(seen, now)
            };
            (last, "not_connected", "devices.accessibility.seen".to_owned())
        } else {
            let spoken_key = self.device_key("devices.accessibility.never");
            (s.text(&self.device_key("devices.last.never")), "never_connected", spoken_key)
        };
        let system = self.device_system_label(&device.system);
        let values =
            [("name", device.name.as_str()), ("system", system.as_str()), ("last", &last), ("device", &device.name)];
        let said_last = spoken.unwrap_or_else(|| last.clone());
        let said = [values[0], values[1], ("last", said_last.as_str()), values[3]];
        let remove = if !device.this_computer && !removed {
            let mut action = self.action("revoke_device", s.text("devices.remove"), "destructive");
            action.insert("device_id".into(), json!(device.device_id));
            let confirm = self.confirm(
                "devices.remove.confirm.title",
                "devices.remove.confirm.body",
                "devices.remove.confirm.button",
                &values,
                true,
            );
            action.insert("confirm".into(), confirm);
            Value::Object(action)
        } else {
            Value::Null
        };
        let rename = if device.this_computer && !removed {
            json!({
                "label": s.text("devices.rename.label"),
                "placeholder": s.text(&self.device_key("devices.rename.placeholder")),
                "button_label": s.text("devices.rename.button"),
                "max_bytes": DEVICE_NAME_MAX_BYTES,
            })
        } else {
            Value::Null
        };
        json!({
            "device_id": device.device_id,
            "name": device.name,
            "system": system,
            "last_connected": last,
            "detail": s.text_with("devices.detail", &values),
            "this_computer": device.this_computer,
            "state": state,
            "accessibility_label": s.text_with(&spoken_key, &said),
            "rename": rename,
            "remove": remove,
        })
    }

    /// profile.devices.
    pub(crate) fn devices_section(&self, facts: &super::DevicesFacts, now: f64) -> Value {
        let rows: Vec<Value> = facts.computers.iter().map(|d| self.device_row(d, facts.removed, now)).collect();
        // "Your computers and phones" once one of them is a phone (on a phone itself, "Your devices").
        let phones = facts.computers.iter().any(|d| super::join_offer::phone_system_key(&d.system).is_some());
        let key = match (self.on_phone(), phones) {
            (true, _) => "devices.title.phone",
            (false, true) => "devices.title.phones",
            (false, false) => "devices.title",
        };
        let title = self.strings.text(key);
        json!({"title": title, "add": self.add_device(facts), "rows": rows})
    }

    fn removed_block(&self) -> Value {
        let s = &self.strings;
        let mut action = self.action("reset_friends", s.text("device_removed.action"), "primary");
        let confirm = self.confirm(
            "device_removed.confirm.title",
            "device_removed.confirm.body",
            "device_removed.confirm.button",
            &[],
            true,
        );
        action.insert("confirm".into(), confirm);
        json!({"title": s.text("device_removed.title"), "body": s.text("device_removed.body"), "action": action})
    }

    fn drop_refusal_on_removed_computer(&self) -> Value {
        if self.audience().has("drop.files") {
            json!(self.strings.text("device_removed.drop_refusal"))
        } else {
            Value::Null
        }
    }

    /// The person's own avatar, exactly as the list's footer draws it.
    pub(crate) fn own_avatar_for_you(&self, you: &PersonFacts) -> Value {
        let name = non_empty_trimmed(you.name.as_deref());
        let seed = you.friends_id.as_deref().unwrap_or(YOU_ID);
        self.avatar_for_picture(&you.picture, seed, name.unwrap_or(you.friends_id.as_deref().unwrap_or("")))
    }

    /// What the You row says of its newest item: the message's words or the file's name.
    fn you_preview_text(&self, item: Option<&ItemFacts>) -> Option<String> {
        let item = item?;
        match item.kind {
            ItemKind::Transfer => item.file_name.clone().filter(|n| !n.is_empty()),
            ItemKind::Message => {
                let text = item.text.as_deref().unwrap_or("").replace('\u{FFFC}', "");
                let joined = text.split(is_newline).collect::<Vec<_>>().join(" ");
                non_empty_trimmed(Some(&joined)).map(str::to_owned)
            }
            ItemKind::Event => None,
        }
    }

    fn you_row(&self, facts: &DevicesFacts, you: &PersonFacts, now: f64, mentions: bool) -> Value {
        let s = &self.strings;
        let preview = self.you_preview_text(facts.you_preview.as_ref());
        let spoken = match &preview {
            Some(preview) => {
                let time = s.time_accessibility_label(you.last_interaction_at, now);
                s.text_with("you.row.accessibility", &[("preview", preview), ("time", &time)])
            }
            None => s.text("you.row.accessibility.empty"),
        };
        let drops = self.audience().has("drop.files");
        let mut row = Map::new();
        row.insert("conversation_id".into(), json!(YOU_ID));
        row.insert("kind".into(), json!("you"));
        row.insert("avatar".into(), self.own_avatar_for_you(you));
        row.insert("title".into(), json!(s.text("you.title")));
        row.insert("subtitle".into(), json!(preview.unwrap_or_else(|| s.text("you.subtitle.empty"))));
        row.insert("time_label".into(), json!(s.time_label(you.last_interaction_at, now)));
        row.insert("route".into(), self.route_for_kind(RouteKind::None, RouteMethod::None));
        row.insert("unread".into(), json!(you.unread_count > 0));
        row.insert("waiting".into(), Value::Null);
        row.insert("blocked".into(), json!(false));
        row.insert("id_confirmed".into(), json!(false));
        row.insert("id_confirmed_label".into(), Value::Null);
        row.insert("style".into(), json!("normal"));
        let drop_label = (drops && !facts.removed).then(|| s.text("you.drop_label"));
        row.insert("drop_label".into(), json!(drop_label));
        let refusal = if facts.removed { self.drop_refusal_on_removed_computer() } else { Value::Null };
        row.insert("drop_refusal".into(), refusal);
        row.insert("accessibility_label".into(), json!(spoken));
        row.insert("actions".into(), json!([]));
        if self.shows_list_menu() {
            row.insert("menu".into(), json!([])); // nothing to remove: these are the person's own computers
        }
        if self.shows_found() {
            row.insert("found".into(), Value::Null); // this computer is found nowhere
        }
        if mentions {
            row.insert("mentionable".into(), json!(false)); // nobody mentions themselves
        }
        Value::Object(row)
    }

    /// The list with what several computers add: `state`, `removed`, the You row among the others, each row's `kind`,
    /// `join`; on a removed computer no join rows and no drops. Without devices facts, `list`
    /// as it is.
    pub fn list_with_devices(&self, list: Value, people: &[PersonFacts], query: &str, now: f64) -> Value {
        let Some(facts) = &self.devices else { return list };
        let mut result = match list {
            Value::Object(map) => map,
            other => return other,
        };
        result.insert("state".into(), json!(if facts.removed { "device_removed" } else { "normal" }));
        result.insert("removed".into(), if facts.removed { self.removed_block() } else { Value::Null });
        if facts.removed || !result.contains_key("join_requests") {
            result.insert("join_requests".into(), json!([]));
        }
        let latest: std::collections::HashMap<&str, f64> =
            people.iter().map(|p| (p.conversation_id.as_str(), p.last_interaction_at)).collect();
        let mut mentions = false;
        let mut rows: Vec<Value> = Vec::new();
        for base in result.get("rows").and_then(Value::as_array).cloned().unwrap_or_default() {
            let Value::Object(mut row) = base else { continue };
            row.insert("kind".into(), json!("person"));
            mentions = mentions || row.contains_key("mentionable");
            if facts.removed {
                row.insert("drop_label".into(), Value::Null);
                row.insert("drop_refusal".into(), self.drop_refusal_on_removed_computer());
            }
            rows.push(Value::Object(row));
        }
        if let Some(you) = &facts.you {
            if self.matches_query(Some(&self.strings.text("you.title")), None, query) {
                // Among the others by latest interaction, as every row is.
                let index = rows
                    .iter()
                    .take_while(|row| {
                        let id = row["conversation_id"].as_str().unwrap_or("");
                        latest.get(id).is_some_and(|at| *at > you.last_interaction_at)
                    })
                    .count();
                rows.insert(index, self.you_row(facts, you, now, mentions));
                result.insert("empty".into(), Value::Null);
            }
        }
        result.insert("rows".into(), Value::Array(rows));
        let name_prompt = result.get("name_prompt").is_some_and(Value::is_object);
        result.insert("join".into(), self.list_join(name_prompt));
        Value::Object(result)
    }
}
