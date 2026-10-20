//! The Settings section and local search results (`SZFriendsSnapshotBuilder+Settings.m`). Settings describes what each
//! choice does from the person's side; the Enable checkbox and its disclosure belong to the host, because they show
//! while Friends is off and no helper runs.

use std::collections::HashMap;

use serde_json::{json, Value};

use super::facts::{PersonFacts, ProfileFacts, Relation, SearchHitFacts};
use super::text::{composed_range16, from_utf16, non_empty_trimmed, utf16};
use super::SnapshotBuilder;
use crate::store::{PhoneFolder, ReceivedFallback, ReceivedFile};

/// Names spelled out in the automatic-acceptance summary before it switches to a count.
const NAMED_AUTO_ACCEPT_LIMIT: usize = 3;
/// Context around the first match, so a hit deep inside a long message still shows why it matched.
const EXCERPT_CONTEXT: usize = 60;

impl SnapshotBuilder {
    fn auto_accept_note(&self, enabled: &[&PersonFacts], friend_count: usize) -> String {
        let s = &self.strings;
        if friend_count == 0 {
            return s.text("settings.auto.note.no_friends");
        }
        if enabled.is_empty() {
            return s.text("settings.auto.note.none");
        }
        if enabled.len() == friend_count && friend_count > 1 {
            return s.text("settings.auto.note.all");
        }
        let names: Vec<String> = enabled.iter().map(|p| self.title_for_person(p)).collect();
        let who = if names.len() <= NAMED_AUTO_ACCEPT_LIMIT {
            s.joined_list(&names)
        } else {
            let mut shown = names[..NAMED_AUTO_ACCEPT_LIMIT - 1].to_vec();
            shown.push(s.text_count("settings.auto.others", (names.len() - shown.len()) as i64, &[]));
            s.joined_list(&shown)
        };
        let key = if enabled.len() == friend_count { "settings.auto.note.only" } else { "settings.auto.note.some" };
        s.text_with(key, &[("names", &who)])
    }

    /// Where received files are saved: the folder, Show in Finder and, with the helper capability `received.folder`,
    /// its name and Change… (neither path nor buttons on a phone, whose place Friends does not change).
    fn received_folder(&self, profile: &ProfileFacts) -> Value {
        let s = &self.strings;
        let folder = &profile.received;
        let reveal = |path: &str| {
            let mut reveal = self.action("show_file", self.show_file_label(), "secondary");
            reveal.insert("path".into(), json!(path));
            Value::Object(reveal)
        };
        if !self.audience().helper_has("received.folder") {
            return json!({
                "label": s.text("settings.received.label"),
                "note": s.text("settings.received.note"),
                "action": folder.path.as_deref().map_or(Value::Null, reveal),
            });
        }
        let (value, note) = match folder.phone {
            Some(PhoneFolder::AppFiles) => {
                (Some(self.audience().app_name.clone()), s.text("settings.received.note.ios"))
            }
            Some(PhoneFolder::Downloads) => {
                (Some(s.text("settings.received.default")), s.text("settings.received.note"))
            }
            // Kept in the app, where no folder shows: each file's Share… is the way out.
            Some(PhoneFolder::App) => (None, s.text("settings.received.note")),
            None => (
                Some(folder.chosen_name.clone().unwrap_or_else(|| s.text("settings.received.default"))),
                s.text("settings.received.note"),
            ),
        };
        // The last file went elsewhere because this folder could not take it: said until one is saved here.
        let note = match folder.fallback {
            Some(ReceivedFallback::Downloads) => s.text("settings.received.note.fallback.downloads"),
            Some(ReceivedFallback::Kept) => {
                s.text_with("settings.received.note.fallback.kept", &[("app", &self.audience().app_name)])
            }
            None => note,
        };
        let path = folder.path.as_deref().filter(|_| folder.phone.is_none() && !self.on_phone());
        let change = path.map(|_| {
            Value::Object(self.action("choose_received_folder", s.text("settings.received.change"), "secondary"))
        });
        let mut row = json!({
            "label": s.text("settings.received.label"),
            "note": note,
            "path": path,
            "action": path.map_or(Value::Null, reveal),
            "change": change,
        });
        if let Some(value) = value {
            row["value"] = json!(value);
        }
        row
    }

    /// The words that say history goes from every computer, on several.
    pub(crate) fn every_computer_key(&self, key: &str) -> String {
        if self.deletes_on_every_computer() {
            format!("{key}.devices")
        } else {
            key.to_owned()
        }
    }

    /// A Delete history or Reset confirmation body for this audience: ".assistant" when its AI chat may have quoted
    /// Friends chats, whose answers stay there.
    pub(crate) fn deletion_body_key(&self, key: &str) -> String {
        if self.audience().has("assistant.chats") {
            format!("{key}.assistant")
        } else {
            key.to_owned()
        }
    }

    /// The settings view.
    pub fn settings(&self, profile: &ProfileFacts, people: &[PersonFacts]) -> Value {
        let s = &self.strings;
        let name = non_empty_trimmed(profile.name.as_deref());
        let friends: Vec<&PersonFacts> =
            self.people_by_latest_interaction(people).into_iter().filter(|p| p.relation == Relation::Friend).collect();
        let (on, off): (Vec<&PersonFacts>, Vec<&PersonFacts>) = friends.iter().partition(|p| p.auto_accept);
        let switches: Vec<Value> = on
            .iter()
            .chain(off.iter())
            .map(|person| {
                json!({
                    "conversation_id": person.conversation_id,
                    "title": self.title_for_person(person),
                    "avatar": self.avatar_for_person(person),
                    "enabled": person.auto_accept,
                })
            })
            .collect();
        let received = self.received_folder(profile);
        let history_body = self.every_computer_key(&self.deletion_body_key("settings.history.confirm.body"));
        let reset_body = self.deletion_body_key("settings.reset.confirm.body");
        json!({
            "name": {
                "label": s.text("settings.name.label"),
                "note": s.text("settings.name.note"),
                "value": name,
                "placeholder": s.text("footer.name_placeholder"),
            },
            "id": {
                "label": s.text("profile.id.label"),
                "note": s.text("settings.id.note"),
                "friends_id": profile.friends_id,
                "copy_label": s.text("static.copy"),
            },
            "received": received,
            "auto_accept": {
                "label": s.text("settings.auto.label"),
                "note": self.auto_accept_note(&on, on.len() + off.len()),
                "action_label": s.text("settings.auto.action"),
                "friends": switches,
            },
            "history": {
                "label": s.text("settings.history.label"),
                "note": s.text(&self.every_computer_key("settings.history.note")),
                "action_label": s.text("settings.history.action"),
                "confirm": self.confirm("settings.history.confirm.title", &history_body,
                                        "settings.history.confirm.button", &[], true),
            },
            "reset": {
                "label": s.text("settings.reset.label"),
                "note": s.text("settings.reset.note"),
                "action_label": s.text("settings.reset.action"),
                "confirm": self.confirm("settings.reset.confirm.title", &reset_body,
                                        "settings.reset.confirm.button", &[], true),
            },
        })
    }

    /// The `received` view: the files received here, newest first (helper capability `received.folder`).
    pub fn received(&self, files: &[ReceivedFile]) -> Value {
        let files: Vec<Value> = files
            .iter()
            .map(|file| {
                json!({
                    "transfer_id": file.transfer_id,
                    "path": file.path,
                    "file_name": file.file_name,
                    "received_at": file.received_at,
                    "source": file.source.name(),
                })
            })
            .collect();
        json!({ "files": files })
    }

    fn excerpt(&self, hit: &SearchHitFacts) -> Vec<Value> {
        let text = &hit.text;
        let units = utf16(text);
        let length = units.len();
        let mut ranges: Vec<(usize, usize)> =
            hit.match_ranges.iter().copied().filter(|(start, len)| *len > 0 && start + len <= length).collect();
        ranges.sort_by_key(|(start, _)| *start);
        let (mut start, mut end) = (0, length);
        if let Some(first) = ranges.first().filter(|_| length > 2 * EXCERPT_CONTEXT) {
            start = first.0.saturating_sub(EXCERPT_CONTEXT);
            end = length.min(first.0 + first.1 + 2 * EXCERPT_CONTEXT);
            (start, end) = composed_range16(text, start, end);
        }
        let piece = |from: usize, to: usize| from_utf16(&units[from..to]);
        let mut segments = Vec::new();
        let mut cursor = start;
        if start > 0 {
            segments.push(json!({"text": "…"}));
        }
        for (from, len) in ranges {
            if from < cursor || from + len > end {
                continue; // overlapping or outside the window
            }
            if from > cursor {
                segments.push(json!({"text": piece(cursor, from)}));
            }
            segments.push(json!({"text": piece(from, from + len), "match": true}));
            cursor = from + len;
        }
        if cursor < end {
            segments.push(json!({"text": piece(cursor, end)}));
        }
        if end < length {
            segments.push(json!({"text": "…"}));
        }
        if segments.is_empty() {
            segments.push(json!({"text": text}));
        }
        segments
    }

    /// The `result` of a successful search_messages reply (conversation search and Cmd+K). `people`, keyed by
    /// conversation id, names each hit's conversation; mentions show as "@Name" through `mention_directory`.
    pub fn search_result(
        &self,
        hits: &[SearchHitFacts],
        people: &HashMap<String, PersonFacts>,
        more: bool,
        now: f64,
    ) -> Value {
        let s = &self.strings;
        let mut results = Vec::new();
        for stored in hits {
            // A hit that matched only a mention's hidden ID or key is no hit at all.
            let (Some(person), Some(hit)) = (people.get(&stored.conversation_id), self.displayed_hit(stored)) else {
                continue;
            };
            let title = self.title_for_person(person);
            results.push(json!({
                "conversation_id": hit.conversation_id,
                "message_id": hit.item_id,
                "conversation_title": title,
                "avatar": self.avatar_for_person(person),
                "sender_label": if hit.outgoing { s.text("search.sender.you") } else { title.clone() },
                "time_label": s.time_label(hit.sent_at, now),
                "excerpt": self.excerpt(&hit),
            }));
        }
        let empty = results.is_empty().then(|| s.text("search.empty"));
        json!({"results": results, "more": more, "empty_label": empty})
    }
}
