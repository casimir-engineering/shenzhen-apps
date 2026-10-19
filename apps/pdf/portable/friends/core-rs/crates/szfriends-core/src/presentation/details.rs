//! Friend details and the person's own profile (`SZFriendsSnapshotBuilder+Details.m`). A friend's new key is never
//! accepted silently: details shows the key change with an explicit choice. Comparison codes show only while a live
//! session has one, because a code compared against a stale screen proves nothing.

use serde_json::{json, Map, Value};

use super::avatar::Picture;
use super::facts::{IdState, IdentityState, PersonFacts, ProfileFacts, Relation};
use super::routes::ShownRoute;
use super::strings::Values;
use super::text::non_empty_trimmed;
use super::SnapshotBuilder;

impl SnapshotBuilder {
    fn verification(&self, person: &PersonFacts, now: f64) -> Value {
        let s = &self.strings;
        let first = self.first_name_for_person(person);
        if person.verified {
            let label = match person.verified_at {
                Some(at) => s.text_with("verification.verified_on", &[("day", &s.day_phrase(at, now))]),
                None => s.text("verification.verified"),
            };
            return json!({"state": "verified", "label": label, "body": null, "comparison_code": null, "action": null});
        }
        let live = matches!(self.shown_route(person), ShownRoute::Local | ShownRoute::Online);
        let code = person.comparison_code.as_deref().filter(|c| live && c.encode_utf16().count() == 6);
        let action = match code {
            Some(_) if person.relation == Relation::Friend => {
                Value::Object(self.action("mark_verified", s.text("verification.codes_match"), "primary"))
            }
            _ => Value::Null,
        };
        let body = if code.is_some() { "verification.body.compare" } else { "verification.body.later" };
        json!({
            "state": "unverified",
            "label": s.text("verification.unverified"),
            "body": s.text_with(body, &[("first", &first)]),
            "comparison_code": code.map(|c| s.grouped_comparison_code(c)),
            "action": action,
        })
    }

    /// Delete chat history… for one person, asking first: what goes, where the person stays, the files received, and,
    /// for a host whose AI chat may have quoted the chat, the answers there.
    fn delete_history_action(&self, person: &PersonFacts, who: Values) -> Value {
        let s = &self.strings;
        let friend = person.relation == Relation::Friend;
        let stays = match person.relation {
            Relation::Friend => "details.history.confirm.stays.friend",
            Relation::Blocked => "details.history.confirm.stays.blocked",
            _ => "details.history.confirm.stays",
        };
        // On several computers the chat goes from every one of them, and the words say so.
        let every = if self.deletes_on_every_computer() { ".devices" } else { "" };
        let goes = format!("details.history.confirm.goes{every}");
        let mut body =
            vec![s.text_with(&goes, who), s.text_with(stays, who), s.text_with("details.history.confirm.files", who)];
        if self.audience().has("assistant.chats") {
            body.push(s.text_with("details.history.confirm.assistant", who));
        }
        let mut confirm = self.confirm(
            "details.history.confirm.title",
            "details.history.confirm.goes",
            "settings.history.confirm.button",
            who,
            true,
        );
        confirm["body"] = json!(body.join(" "));
        let mut action = self.action("delete_history", s.text("details.history.action"), "destructive");
        let note = if friend { "details.history.note.friend" } else { "details.history.note" };
        action.insert("note".into(), json!(s.text_with(&format!("{note}{every}"), who)));
        action.insert("confirm".into(), confirm);
        Value::Object(action)
    }

    /// The details view; `waiting_elsewhere` counts rows waiting other than this person's.
    pub fn details(&self, person: &PersonFacts, waiting_elsewhere: i64, now: f64) -> Value {
        let s = &self.strings;
        let first = self.first_name_for_person(person);
        let who: Values = &[("first", &first), ("app", &self.audience().reveal_in)];
        let blocked = person.relation == Relation::Blocked;
        let friend = person.relation == Relation::Friend;
        // Counted like the conversation's arrow: its own row waiting makes the others "more".
        let waiting_key =
            if self.person_waits(person) { "back.conversation.more_waiting" } else { "back.conversation.waiting" };
        let back_label = if waiting_elsewhere > 0 {
            s.text_count(waiting_key, waiting_elsewhere, who)
        } else {
            s.text_with("back.conversation", who)
        };
        let received = if person.received_file_count > 0 {
            // A phone has no folder to show: each received file has Share… in the conversation instead.
            let reveal = person.received_reveal_path.as_deref().filter(|p| !p.is_empty() && !self.on_phone());
            let action = match reveal {
                Some(path) => {
                    let label = s.text_with("action.show_in", &[("app", &self.audience().reveal_in)]);
                    let mut show = self.action("show_file", label, "link");
                    show.insert("path".into(), json!(path));
                    Value::Object(show)
                }
                None => Value::Null,
            };
            json!({
                "label": s.text_count("details.received", person.received_file_count, who),
                "count": person.received_file_count,
                "action": action,
            })
        } else {
            Value::Null
        };
        let key_change = if person.key_change_pending && !blocked {
            json!({
                "title": s.text_with("key_change.title", who),
                "body": s.text_with("key_change.body", who),
                "actions": [
                    self.action("accept_key_change", s.text("key_change.accept"), "primary"),
                    self.block_action(&first, s.text_with("action.block", who)),
                ],
            })
        } else {
            Value::Null
        };
        // Deleting this chat's history comes first: it is the lightest of these and leaves the person where they are.
        let mut actions = vec![self.delete_history_action(person, who)];
        if blocked {
            let mut unblock = self.action("unblock", s.text_with("action.unblock", who), "secondary");
            unblock.insert("note".into(), json!(s.text_with("details.unblock_note", who)));
            actions.push(Value::Object(unblock));
        } else {
            if friend {
                // Ending a friendship cannot be undone from this side, so it asks first.
                let mut remove = self.action("remove_friend", s.text("action.remove"), "destructive");
                remove.insert("note".into(), json!(s.text_with("details.remove_note", who)));
                let confirm = self.confirm(
                    "action.remove.confirm.title",
                    "action.remove.confirm.body",
                    "action.remove.confirm.button",
                    who,
                    true,
                );
                remove.insert("confirm".into(), confirm);
                actions.push(Value::Object(remove));
            }
            let mut block = self.block_action(&first, s.text_with("action.block", who));
            block.insert("note".into(), json!(s.text_with("details.block_note", who)));
            actions.push(Value::Object(block));
        }
        let id = person.friends_id.as_deref().filter(|id| !id.is_empty());
        let confirmed = id.is_some() && person.friends_id_confirmed;
        json!({
            "conversation_id": person.conversation_id,
            "title": self.title_for_person(person),
            "back": {
                "badge_count": waiting_elsewhere.max(0),
                "badge_label": s.badge_label(waiting_elsewhere),
                "accessibility_label": back_label,
            },
            "avatar": self.avatar_for_person(person),
            "route": self.route_for_person(person),
            "friends_id": id,
            "id_label": id.map(|id| s.text_with("id.label", &[("id", &s.display_id(Some(id)))])),
            "id_confirmed": confirmed,
            "id_confirmed_label": confirmed.then(|| s.text("id.confirmed")),
            "copy_id_accessibility_label": id.map(|_| s.text_with("details.copy_id", who)),
            "verification": self.verification(person, now),
            "auto_accept": {
                "available": friend,
                "enabled": friend && person.auto_accept,
                "title": s.text_with("auto_accept.title", who),
                "body": s.text_with("auto_accept.body", who),
            },
            "received": received,
            "key_change": key_change,
            "actions": actions,
        })
    }

    pub(crate) fn build_profile(&self, profile: &ProfileFacts, waiting_elsewhere: i64) -> Value {
        let s = &self.strings;
        let name = non_empty_trimmed(profile.name.as_deref());
        let (state, note) = if profile.identity_state == IdentityState::Unavailable {
            ("unavailable", Some(s.text("id.unavailable")))
        } else if profile.friends_id_state == IdState::Reserved {
            ("reserved", Some(s.text("id.reserved")))
        } else if profile.friends_id_state == IdState::Changed {
            let note = match profile.previous_friends_id.as_deref().filter(|id| !id.is_empty()) {
                Some(old) => {
                    let id = s.display_id(Some(&profile.friends_id));
                    s.text_with("banner.id_changed", &[("id", &id), ("old", &s.display_id(Some(old)))])
                }
                None => s.text("id.changed"),
            };
            ("changed", Some(note))
        } else if profile.nearby_only {
            ("unreserved", Some(s.text("id.nearby")))
        } else {
            ("unreserved", self.id_note(profile))
        };
        let selected = match &profile.picture {
            Picture::Animal { index, .. } => json!(index),
            _ => Value::Null,
        };
        let set = match (self.animal_set(), &profile.picture) {
            (Some(set), _) => set.version,
            (None, Picture::Animal { set, .. }) => *set,
            (None, _) => 1,
        };
        let mut data = Map::new();
        data.insert("title".into(), json!(s.text("profile.title")));
        data.insert("back".into(), self.back_to_friends(waiting_elsewhere, false));
        data.insert(
            "name".into(),
            json!({
                "label": s.text("profile.name.label"),
                "value": name,
                "placeholder": s.text("name.placeholder"),
                "max_length": 40, // PROTOCOL.md § Limits
            }),
        );
        let display = name.unwrap_or(&profile.friends_id);
        data.insert(
            "picture".into(),
            json!({
                "avatar": self.avatar_for_picture(&profile.picture, &profile.friends_id, display),
                "choose_label": s.text("profile.picture.choose"),
                "own_picture_label": s.text("profile.picture.own"),
                "animal_set": set,
                "selected_index": selected,
            }),
        );
        data.insert(
            "id".into(),
            json!({
                "label": s.text("profile.id.label"),
                "friends_id": profile.friends_id,
                "state": state,
                "note": note,
                "copy_label": s.text("static.copy"),
                // No QR yet: nothing can open what it would encode, so a code to scan would invite something that does
                // nothing. PROTOCOL.md § profile keeps the fields for later.
                "qr_label": null,
                "qr_payload": null,
            }),
        );
        data.insert(
            "add".into(),
            json!({
                "label": s.text("profile.add.label"),
                "placeholder": s.text("profile.add.placeholder"),
                "button_label": s.text("profile.add.button"),
                "hint": s.text("profile.add.hint"),
            }),
        );
        if let Some(links) = self.links_section(profile.links.as_ref()) {
            data.insert("links".into(), links);
        }
        Value::Object(data)
    }
}
