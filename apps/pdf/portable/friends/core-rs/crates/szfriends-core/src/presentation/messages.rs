//! Reply messages (`SZFriendsStrings+Messages.m`, the mention, join and devices messages): `error.message` is shown to
//! the person who tried something, so it says what happened to their action and what they can do. Protocol errors (a
//! view or library bug) and the client-side codes get no text: the view shows its generic failure or the host's own
//! connection line instead.

use serde_json::{Map, Value};

use super::strings::{last_path_component, Strings};

/// Codes whose replies carry no words.
const SILENT: [&str; 8] = [
    "bad_frame",
    "frame_too_large",
    "hello_required",
    "protocol_unsupported",
    "unknown_intent",
    "too_many_subscriptions",
    "not_ready",
    "connection_lost",
];

fn string<'a>(details: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    details.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

impl Strings {
    /// `error.message` for a PROTOCOL.md error code, or None where the view has nothing useful to say. `details`
    /// fills names, files and sizes: `path` or `file_name`, `name`, `needed_bytes`, `retry_after_seconds`, `max`,
    /// `field`, and for a lost `cancel_message` race `state` and `friends_id`.
    pub fn error_message(&self, code: &str, details: &Map<String, Value>) -> Option<String> {
        if code.is_empty() || SILENT.contains(&code) {
            return None;
        }
        let mut values: Vec<(&str, String)> = Vec::new();
        let file_name = string(details, "file_name");
        if let Some(file) = file_name {
            values.push(("file", file.to_owned()));
        } else if let Some(path) = string(details, "path") {
            values.push(("file", last_path_component(path)));
        }
        if let Some(name) = string(details, "name") {
            values.push(("name", name.to_owned()));
        }
        if let Some(needed) = details.get("needed_bytes").and_then(Value::as_f64) {
            values.push(("size", self.size_label(needed as u64)));
        }
        if let Some(seconds) = details.get("retry_after_seconds").and_then(Value::as_f64).filter(|s| *s as i64 > 0) {
            values.push(("seconds", (seconds as i64).to_string()));
        }
        if let Some(max) = details.get("max").filter(|m| m.is_number()) {
            values.push(("max", max.to_string()));
        }
        let has = |key: &str| values.iter().any(|(k, _)| *k == key);
        let borrowed: Vec<(&str, &str)> = values.iter().map(|(k, v)| (*k, v.as_str())).collect();
        let field = details.get("field").and_then(Value::as_str);

        // The more specific wording when the details allow it, the general one otherwise.
        if code == "invalid_field" {
            return match field {
                Some("text") => Some(self.text("error.invalid_field.text")),
                Some("query") => Some(self.text("error.invalid_field.query")),
                Some("payload") => Some(self.text("error.invalid_field.payload")),
                _ => None, // any other field is a view bug; nothing the person can fix
            };
        }
        // cancel_message lost the race: the message had already left, so the reply says where it is.
        let state = details.get("state").and_then(Value::as_str);
        if code == "stale" && field == Some("message_id") {
            if let Some(state @ ("delivered" | "sending" | "sent")) = state {
                let first = self.first_name(string(details, "name"), details.get("friends_id").and_then(Value::as_str));
                return Some(self.text_with(&format!("error.stale.message_{state}"), &[("first", &first)]));
            }
        }
        // set_received_folder: the folder the person picked in Settings.
        if field == Some("received_folder") {
            match code {
                "file_missing" => return Some(self.text("error.received_folder.missing")),
                "not_allowed" => return Some(self.text("error.received_folder.not_allowed")),
                _ => {}
            }
        }
        // A link that was revoked, expired or reset.
        if code == "not_found" && field == Some("payload") {
            return Some(self.text("error.not_found.link"));
        }
        if code == "rate_limited" {
            let key = if has("seconds") { "error.rate_limited.seconds" } else { "error.rate_limited" };
            return Some(self.text_with(key, &borrowed));
        }
        if code == "too_many_files" {
            let key = if has("max") { "error.too_many_files.max" } else { "error.too_many_files" };
            return Some(self.text_with(key, &borrowed));
        }
        if code == "disk_full" {
            // file_name names an incoming offer (accepting it needs space); a path is a file being sent.
            let key = match (file_name.is_some(), has("size"), has("file")) {
                (true, true, _) => "error.disk_full.file_size",
                (true, false, _) => "error.disk_full.file",
                (false, _, true) => "error.disk_full.sending",
                (false, true, false) => "error.disk_full.size",
                (false, false, false) => "error.disk_full",
            };
            return Some(self.text_with(key, &borrowed));
        }
        // A reset that stopped before changing anything, because the old identity could not be removed.
        if code == "internal" && string(details, "reason") == Some("identity_not_removed") {
            // A phone (`files.share`) is no computer, and is unlocked while Friends is in front.
            let phone = self.audience().has("files.share");
            let key =
                if phone { "error.internal.identity_not_removed.phone" } else { "error.internal.identity_not_removed" };
            return Some(self.text(key));
        }
        let mut key = format!("error.{code}");
        if ["already_friends", "blocked", "not_friends", "mention_mismatch"].contains(&code) && has("name") {
            key.push_str(".name");
        }
        if ["file_missing", "folder_not_supported", "source_changed"].contains(&code) && has("file") {
            key.push_str(".file");
        }
        if !self.has(&key) {
            return Some(self.text("error.internal"));
        }
        Some(self.text_with(&key, &borrowed))
    }

    /// add_by_id's result.message: what happens next; with `online`, once this computer reaches friends online.
    pub fn add_by_id_sent_message(&self, friends_id: &str, online: bool) -> String {
        let key = if online { "add_by_id.sent.online" } else { "add_by_id.sent" };
        self.text_with(key, &[("id", &self.display_id(Some(friends_id)))])
    }

    /// add_from_mention's result.message, naming the person as the mention did.
    pub fn add_from_mention_sent_message(&self, name: &str, online: bool) -> String {
        let key = if online { "add_from_mention.sent.online" } else { "add_from_mention.sent" };
        self.text_with(key, &[("name", name)])
    }

    /// The join intents' errors with words of their own (not_found, not_allowed, a code that is not 8 digits).
    pub fn join_error_message(&self, code: &str, field: Option<&str>) -> Option<String> {
        match (code, field) {
            ("not_found", _) => Some(self.text("error.not_found.join")),
            ("not_allowed", _) => Some(self.text("error.not_allowed.join")),
            ("invalid_field", Some("code")) => Some(self.text("error.invalid_field.code")),
            _ => None,
        }
    }

    /// The devices intents' errors with words of their own. `reason`: "device" (revoke_device not_found), "empty"
    /// or "invalid" (rename_device name_invalid), "fetch" (fetch_from_device not_found), "device_removed".
    pub fn devices_error_message(&self, code: &str, reason: &str) -> Option<String> {
        let key = match (code, reason) {
            ("not_found", "device") => "error.not_found.device",
            ("not_found", "fetch") => "error.not_found.fetch",
            ("name_invalid", "empty") => "error.name_invalid.device.empty",
            ("name_invalid", "invalid") => "error.name_invalid.device",
            ("not_allowed", "device_removed") => "error.not_allowed.device_removed",
            _ => return None,
        };
        Some(self.text(key))
    }
}
