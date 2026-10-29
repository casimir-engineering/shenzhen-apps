//! Transfer items (`transferItem:` and its helpers in `SZFriendsSnapshotBuilder+Items.m`): one file offer and its
//! whole life. Estimates appear only on slow routes, where the person may prefer to wait for a faster one.

use serde_json::{json, Map, Value};

use super::facts::{failure, ItemFacts, PersonFacts, Relation, TransferState};
use super::items::without_final_period;
use super::mentions::{key_string, mention_name};
use super::strings::path_extension;
use super::SnapshotBuilder;
use crate::store::SavedPlace;

pub(crate) fn transfer_state_name(state: TransferState) -> &'static str {
    match state {
        TransferState::Queued => "queued",
        TransferState::Offered => "offered",
        TransferState::WaitingForYou => "waiting_for_you",
        TransferState::Sending => "sending",
        TransferState::Receiving => "receiving",
        TransferState::Delivered => "delivered",
        TransferState::Received => "received",
        TransferState::Declined => "declined",
        TransferState::Cancelled => "cancelled",
        TransferState::Failed => "failed",
    }
}

fn non_empty(text: Option<&str>) -> Option<&str> {
    text.filter(|t| !t.is_empty())
}

impl SnapshotBuilder {
    /// Open (for a format this app opens) and Show in Finder, for a file that is on this computer.
    fn file_actions(&self, item: &ItemFacts) -> Vec<Value> {
        let s = &self.strings;
        let mut actions = Vec::new();
        let extension = non_empty(item.file_extension.as_deref())
            .map(str::to_owned)
            .unwrap_or_else(|| path_extension(item.file_name.as_deref().unwrap_or("")))
            .to_lowercase();
        if self.audience().open_formats.contains(&extension) {
            let mut open = self.action("open_file", s.text("action.open"), "link");
            open.insert("path".into(), json!(item.local_path));
            actions.push(Value::Object(open));
        }
        let mut show = self.action("show_file", self.show_file_label(), "link");
        show.insert("path".into(), json!(item.local_path));
        actions.push(Value::Object(show));
        actions
    }

    fn transfer_actions(&self, item: &ItemFacts, person: &PersonFacts) -> Vec<Value> {
        let s = &self.strings;
        // A file this person sent from another of their computers, copied here: here to open, nothing to send.
        if item.outgoing && non_empty(item.local_path.as_deref()).is_some() {
            return self.file_actions(item);
        }
        let mut actions = Vec::new();
        match item.state() {
            TransferState::WaitingForYou => {
                actions.push(Value::Object(self.action("accept_offer", s.text("action.accept"), "primary")));
                actions.push(Value::Object(self.action("decline_offer", s.text("action.decline"), "secondary")));
            }
            TransferState::Queued | TransferState::Offered | TransferState::Sending | TransferState::Receiving => {
                actions.push(Value::Object(self.action("cancel_transfer", s.text("static.cancel"), "link")));
            }
            TransferState::Received if non_empty(item.local_path.as_deref()).is_some() => {
                actions.extend(self.file_actions(item));
            }
            TransferState::Failed => {
                // An incoming file can be fetched again only when its bytes arrived damaged.
                let retry = item.outgoing || item.failure_reason.as_deref() == Some(failure::DIGEST_MISMATCH);
                if retry && self.can_retry(item.failure_reason.as_deref(), person) {
                    actions.push(Value::Object(self.action("retry_item", s.text("action.try_again"), "link")));
                }
            }
            _ => {}
        }
        // Someone who sent a file through a link and is not a friend: Add, as a mention of them would offer it.
        let addable = person.link_contact && person.relation == Relation::Removed && !item.outgoing;
        if let (true, Some(key), Some(id)) = (addable, person.identity_key, non_empty(person.friends_id.as_deref())) {
            let first = self.first_name_for_person(person);
            let mut add =
                self.action("add_from_mention", s.text_with("transfer.action.add", &[("first", &first)]), "link");
            add.insert("friends_id".into(), json!(id));
            add.insert("identity_key".into(), json!(key_string(&key)));
            add.insert("name".into(), json!(mention_name(person.name.as_deref(), Some(id))));
            actions.push(Value::Object(add));
        }
        actions
    }

    /// PROTOCOL.md transfer thumbnail: the PNG views load in place of the type icon, or null.
    fn thumbnail(&self, item: &ItemFacts) -> Value {
        match non_empty(item.thumbnail_path.as_deref()) {
            Some(path) if item.thumbnail_width > 0 && item.thumbnail_height > 0 => json!({
                "path": path,
                "width": item.thumbnail_width,
                "height": item.thumbnail_height,
                "source": if item.thumbnail_from_sender { "sender" } else { "local" },
            }),
            _ => Value::Null,
        }
    }

    pub(crate) fn transfer_item(&self, item: &ItemFacts, person: &PersonFacts) -> Map<String, Value> {
        let s = &self.strings;
        let name = item.file_name.clone().unwrap_or_default();
        let kind_label = s.kind_label(&name, item.file_extension.as_deref());
        let size = s.size_label(item.file_size);
        let state = item.state();
        let automatic = item.accepted_automatically && !item.outgoing;
        let moving = matches!(state, TransferState::Sending | TransferState::Receiving);
        let waiting = matches!(state, TransferState::WaitingForYou | TransferState::Offered);
        let remaining = item.file_size.saturating_sub(item.bytes_done);
        // Floor, so the bar and the percentage never claim 100% before the digest has been checked.
        let percent = if item.file_size > 0 {
            ((item.bytes_done as f64 * 100.0 / item.file_size as f64).floor() as i64).min(100)
        } else {
            0
        };
        let timed = moving && item.bytes_per_second > 0.0;
        // On the relay the time left never assumes more than the relay allows.
        let rate = s.estimate_bytes_per_second(item.bytes_per_second, item.transfer_route);
        let verb = if state == TransferState::Sending { "sending" } else { "receiving" };
        let direction = if item.outgoing { "out" } else { "in" };
        let note = (waiting || moving)
            .then(|| s.transfer_estimate(remaining, item.bytes_per_second, item.transfer_route))
            .flatten();
        let note_spoken = waiting
            .then(|| s.transfer_estimate_accessibility(remaining, item.bytes_per_second, item.transfer_route))
            .flatten();
        let first = self.first_name_for_person(person);
        let sender = self.title_for_person(person);
        let percent_text = percent.to_string();
        let automatic_text = if automatic { format!(", {}", s.text("transfer.auto")) } else { String::new() };
        let note_text = note_spoken.map(|n| format!(", {n}")).unwrap_or_default();
        let (mut duration, mut left) = (String::new(), String::new());
        if timed {
            duration = s.duration_label(remaining as f64 / rate);
            let spoken = s.duration_accessibility_label(remaining as f64 / rate);
            left = format!(", {}", s.text_with("transfer.left.spoken", &[("duration", &spoken)]));
        }
        let mut extra = String::new();
        let mut status_key = format!("transfer.status.{}", transfer_state_name(state));
        let finishing = item.finishing && state == TransferState::Receiving;
        if finishing {
            status_key = "transfer.finishing".into();
        } else if moving {
            status_key = format!("transfer.status.{verb}{}", if timed { "_timed" } else { "" });
        } else if state == TransferState::WaitingForYou && item.asked_because_disk_low {
            status_key = "transfer.status.disk_low".into();
            extra = format!(". {}", s.text("transfer.disk_low.spoken"));
        } else if state == TransferState::Queued && item.outgoing {
            status_key = self.waiting_key("transfer.status", person);
        } else if matches!(state, TransferState::Declined | TransferState::Failed) {
            status_key = format!("{status_key}.{direction}");
        }
        let failed = state == TransferState::Failed;
        if failed {
            status_key = self.key_for_failure(&status_key, item.failure_reason.as_deref(), person);
        }
        // A received file says which folder it is in; one kept in the store's own folder stays "Received".
        let here =
            state == TransferState::Received && !item.outgoing && non_empty(item.local_path.as_deref()).is_some();
        let folder = item.saved_in.as_ref().filter(|_| here).and_then(|place| match place {
            SavedPlace::Downloads => Some(s.text("settings.received.default")),
            SavedPlace::AppFiles => Some(self.audience().app_name.clone()),
            SavedPlace::Folder(name) => Some(name.clone()).filter(|n| !n.is_empty()),
        });
        if folder.is_some() {
            status_key = "transfer.status.received.saved".into();
        }
        let mut values: Vec<(&str, &str)> = vec![
            ("first", &first),
            ("sender", &sender),
            ("file", &name),
            ("kind", &kind_label),
            ("size", &size),
            ("percent", &percent_text),
            ("auto", &automatic_text),
            ("note", &note_text),
            ("left", &left),
            ("extra", &extra),
        ];
        if timed {
            values.push(("duration", &duration));
        }
        if let Some(folder) = &folder {
            values.push(("folder", folder));
        }
        let status = s.text_with(&status_key, &values);
        let status_spoken = without_final_period(&status); // the spoken templates end the sentence themselves
        values.push(("status", &status_spoken));
        let mut spoken_key = format!("transfer.spoken.{direction}.{}", transfer_state_name(state));
        if failed {
            spoken_key = self.key_for_failure(&spoken_key, item.failure_reason.as_deref(), person);
        }
        if folder.is_some() {
            spoken_key = "transfer.spoken.in.received.saved".into();
        }
        if finishing {
            spoken_key = "transfer.spoken.in.finishing".into();
        }
        let assistant = self.assistant_label(item, person);
        // Every spoken template lists "{file}, {kind}, {size}", so the assistant is said right after the file's facts.
        let said_size = assistant.as_ref().map(|a| format!("{size}, {}", s.spoken_fragment(a)));
        let mut said = values.clone();
        if let Some(said_size) = &said_size {
            said.retain(|(k, _)| *k != "size");
            said.push(("size", said_size));
        }
        let spoken = s.text_with(&spoken_key, &said);
        let mut meta = s.text_with("transfer.meta", &[("kind", &kind_label), ("size", &size)]);
        if automatic {
            meta = s.text_with("preview.with_status", &[("text", &meta), ("status", &s.text("transfer.auto"))]);
        }
        let progress = if finishing {
            json!({"fraction": 1.0, "determinate": true, "accessibility_label": s.text("transfer.progress.finishing")})
        } else if moving {
            json!({
                "fraction": percent as f64 / 100.0,
                "determinate": item.file_size > 0,
                "accessibility_label": s.text_with(&format!("transfer.progress.{verb}"), &values),
            })
        } else {
            Value::Null
        };
        // Received here, or sent from another of this person's computers and copied here (only a copy has a path).
        let local_path = non_empty(item.local_path.as_deref());
        let here = local_path.filter(|_| item.outgoing || state == TransferState::Received);
        let extension = non_empty(item.file_extension.as_deref()).map(str::to_lowercase);
        let mut transfer = Map::new();
        transfer.insert("kind".into(), json!("transfer"));
        transfer.insert("item_id".into(), json!(item.item_id));
        transfer.insert("transfer_id".into(), json!(item.transfer_id.as_ref().unwrap_or(&item.item_id)));
        transfer.insert("direction".into(), json!(direction));
        transfer.insert(
            "file".into(),
            json!({
                "name": name,
                "kind_label": kind_label,
                "size_label": size,
                "size_bytes": item.file_size,
                "path": here,
                "type_identifier": non_empty(item.file_type_identifier.as_deref()),
                "extension": extension,
            }),
        );
        transfer.insert("thumbnail".into(), self.thumbnail(item));
        transfer.insert("meta_label".into(), json!(meta));
        transfer.insert("state".into(), json!(transfer_state_name(state)));
        transfer.insert("status_label".into(), json!(status));
        transfer.insert("route_note".into(), json!(note));
        transfer.insert("progress".into(), progress);
        transfer.insert("actions".into(), Value::Array(self.transfer_actions(item, person)));
        transfer.insert("assistant_label".into(), json!(assistant));
        transfer.insert("time_label".into(), json!(s.clock_label(item.sent_at)));
        transfer.insert("accessibility_label".into(), json!(spoken));
        // A file on another of the person's computers, one copying to them, or one moved or deleted (again.rs).
        self.transfer_where_it_is(transfer, item, person)
    }
}
