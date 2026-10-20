//! The badge and the list (`SZFriendsSnapshotBuilder.m` § Badge, § List): rows sorted by latest interaction, the
//! waiting count, which rows accept drops, and each row's spoken form.

use std::collections::HashMap;

use serde_json::{json, Map, Value};

use super::facts::{IdentityState, ItemFacts, ItemKind, PersonFacts, ProfileFacts, Relation, UpdateNeed};
use super::mention_view::MentionDirectory;
use super::text::{non_empty_trimmed, trim};
use super::SnapshotBuilder;

impl SnapshotBuilder {
    /// The badge: rows waiting for an answer, join requests included.
    pub fn badge(&self, people: &[PersonFacts], join_requests: usize) -> Value {
        let count = join_requests as i64 + people.iter().filter(|p| self.person_waits(p)).count() as i64;
        let s = &self.strings;
        json!({
            "count": count,
            "label": s.badge_label(count),
            "accessibility_label": if count != 0 {
                s.text_count("badge.accessibility", count, &[])
            } else {
                s.text("static.button_label")
            },
        })
    }

    fn waiting_subtitle(&self, person: &PersonFacts, item: Option<&ItemFacts>) -> (String, &'static str) {
        let s = &self.strings;
        if person.relation == Relation::IncomingRequest {
            if let Some(id) = person.unconfirmed_answer_id.as_deref().filter(|id| !id.is_empty()) {
                return (s.text_with("list.subtitle.answer", &[("id", &s.display_id(Some(id)))]), "request");
            }
            return (s.text("list.subtitle.request"), "request");
        }
        if person.key_change_pending {
            let first = self.first_name_for_person(person);
            return (s.text_with("list.subtitle.key_change", &[("first", &first)]), "key_change");
        }
        let one_file = item.filter(|item| {
            person.offers_waiting == 1
                && item.kind == ItemKind::Transfer
                && !item.outgoing
                && item.file_name.as_deref().is_some_and(|n| !n.is_empty())
        });
        if let Some(name) = one_file.and_then(|item| item.file_name.as_deref()) {
            return (s.text_with("list.subtitle.offer", &[("file", name)]), "offer");
        }
        (s.text_count("list.subtitle.offers", person.offers_waiting, &[]), "offer")
    }

    /// An incoming request is answered from the list: Accept and Decline at once, each saying its word on the button
    /// so a first-time reader tells Decline from Block, and Block (its icon alone, red) after a second click.
    fn row_actions(&self, person: &PersonFacts, title: &str) -> Value {
        if person.relation != Relation::IncomingRequest {
            return json!([]);
        }
        let s = &self.strings;
        let who = [("title", title)];
        json!([
            {"action": "accept_request", "icon": "accept", "title": s.text("action.accept"),
             "label": s.text_with("list.action.accept", &who), "arm": null},
            {"action": "decline_request", "icon": "decline", "title": s.text("action.decline"),
             "label": s.text_with("list.action.decline", &who), "arm": null},
            {"action": "block", "icon": "block", "title": null, "label": s.text_with("list.action.block", &who),
             "arm": self.block_arm(title)},
        ])
    }

    fn row(&self, person: &PersonFacts, item: Option<&ItemFacts>, directory: &MentionDirectory, now: f64) -> Value {
        let s = &self.strings;
        let title = self.title_for_person(person);
        let waits = self.person_waits(person);
        let mut explains_route = false;
        let mut waiting_kind = "";
        let (subtitle, spoken) = if waits {
            let (subtitle, kind) = self.waiting_subtitle(person, item);
            waiting_kind = kind;
            let spoken = s.spoken_fragment(&subtitle);
            (subtitle, spoken)
        } else if person.relation == Relation::OutgoingRequest {
            let subtitle = s.text("list.subtitle.request_sent");
            (subtitle.clone(), s.spoken_fragment(&subtitle))
        } else if person.relation == Relation::Blocked {
            let subtitle = s.text("list.subtitle.blocked");
            (subtitle.clone(), s.spoken_fragment(&subtitle))
        } else if person.relation == Relation::Removed && !person.link_contact {
            let subtitle = s.text("list.subtitle.removed");
            (subtitle.clone(), s.spoken_fragment(&subtitle))
        } else {
            let preview = self.preview(item, person, Some(directory));
            explains_route = preview.explains_route;
            (preview.visual, preview.spoken)
        };

        let accepts_drops =
            person.relation == Relation::Friend && !person.key_change_pending && self.audience().has("drop.files");
        let mut said = vec![title.clone()];
        if person.unread_count > 0 {
            said.push(s.text("list.spoken.unread"));
        }
        if !spoken.is_empty() {
            said.push(spoken);
        }
        said.push(s.time_accessibility_label(person.last_interaction_at, now));
        let route = self.spoken_route_for_person(person);
        if waits {
            said.push(s.text("list.spoken.waiting"));
        } else if let Some(route) = route.filter(|r| !explains_route && !r.is_empty()) {
            said.push(route);
        }
        let confirmed = person.friends_id_confirmed && person.friends_id.as_deref().is_some_and(|id| !id.is_empty());
        if confirmed {
            said.push(s.text("list.spoken.id_confirmed"));
        }
        // How a friend nearby was found; nobody else's row says.
        let (found, found_spoken) = if self.shows_found() && person.relation == Relation::Friend {
            self.found(&person.found_methods)
        } else {
            (Value::Null, None)
        };
        said.extend(found_spoken);
        let first = self.first_name_for_person(person);
        let mut row = json!({
            "conversation_id": person.conversation_id,
            "avatar": self.avatar_for_person(person),
            "title": title,
            "subtitle": subtitle,
            "time_label": s.time_label(person.last_interaction_at, now),
            "route": self.route_for_person(person),
            "unread": person.unread_count > 0,
            "waiting": if waits { json!({"kind": waiting_kind, "label": s.text("list.waiting")}) } else { Value::Null },
            "blocked": person.relation == Relation::Blocked,
            "id_confirmed": confirmed,
            "id_confirmed_label": if confirmed { json!(s.text("id.confirmed")) } else { Value::Null },
            // The look is decided here, like every other display choice, so no view infers it from `blocked`.
            "style": if person.relation == Relation::Blocked { "muted" } else { "normal" },
            "drop_label": accepts_drops.then(|| s.text_with("list.drop", &[("first", &first)])),
            "drop_refusal": if accepts_drops { Value::Null } else { self.drop_refusal(person) },
            "accessibility_label": said.join(", "),
            "actions": self.row_actions(person, &title),
        });
        if self.shows_list_menu() {
            row["menu"] = self.row_menu(person);
        }
        if self.shows_found() {
            row["found"] = found;
        }
        row
    }

    fn banner(&self, profile: &ProfileFacts) -> Value {
        let s = &self.strings;
        if profile.identity_state == IdentityState::Unavailable {
            let mut reset = self.action("reset_friends", s.text("settings.reset.action"), "destructive");
            let body = self.deletion_body_key("settings.reset.confirm.body");
            let confirm =
                self.confirm("settings.reset.confirm.title", &body, "settings.reset.confirm.button", &[], true);
            reset.insert("confirm".into(), confirm);
            return json!({"kind": "identity_unavailable", "text": s.text("banner.identity_unavailable"),
                          "action": reset});
        }
        if profile.update_need != UpdateNeed::None {
            let key =
                if profile.update_need == UpdateNeed::Online { "banner.update_online" } else { "banner.update_store" };
            let text = s.text_with(key, &[("app", &self.audience().app_name)]);
            return json!({"kind": "update_required", "text": text, "action": null});
        }
        if let Some(old) = profile.previous_friends_id.as_deref().filter(|id| !id.is_empty()) {
            let id = s.display_id(Some(&profile.friends_id));
            let text = s.text_with("banner.id_changed", &[("id", &id), ("old", &s.display_id(Some(old)))]);
            let action = self.action("dismiss_banner", s.text("banner.ok"), "link");
            return json!({"kind": "id_changed", "text": text, "action": action});
        }
        Value::Null
    }

    /// The list. `preview_items` is keyed by item id: each row describes `preview_items[person.last_preview_item_id]`.
    /// Previews resolve mentions against the very people and profile this list shows.
    pub fn list(
        &self,
        people: &[PersonFacts],
        preview_items: &HashMap<String, ItemFacts>,
        profile: &ProfileFacts,
        query: &str,
        now: f64,
    ) -> Value {
        let s = &self.strings;
        let directory = MentionDirectory::new(people, profile);
        let mut rows = Vec::new();
        // Someone taken off the list stays in the facts, so their open conversation, details or a search still finds
        // them; the list skips them.
        for person in self.people_by_latest_interaction(people) {
            if person.left_list || !self.matches_query(person.name.as_deref(), person.friends_id.as_deref(), query) {
                continue;
            }
            let item = person.last_preview_item_id.as_ref().and_then(|id| preview_items.get(id));
            let mut row = self.row(person, item, &directory, now);
            if let (Some(mentionable), Value::Object(map)) = (self.mentionable(person), &mut row) {
                map.insert("mentionable".into(), json!(mentionable)); // the @ picker's people
            }
            rows.push(row);
        }
        let empty = if !rows.is_empty() {
            Value::Null
        } else if people.iter().all(|p| p.left_list) {
            self.empty(None, s.text("list.empty.title"), Some(s.text("list.empty.body")))
        } else {
            let title = s.text_with("search.no_match.title", &[("query", trim(query))]);
            self.empty(Some("no_match"), title, Some(s.text("search.no_match.body")))
        };
        let prompt = if non_empty_trimmed(profile.name.as_deref()).is_some() {
            Value::Null
        } else {
            let id = s.display_id(Some(&profile.friends_id));
            json!({
                "title": s.text("name_prompt.title"),
                "placeholder": s.text("name.placeholder"),
                "note": s.text_with("name_prompt.note", &[("id", &id)]),
            })
        };
        let mut list = Map::new();
        list.insert("query".into(), json!(query));
        list.insert("banner".into(), self.banner(profile));
        list.insert("name_prompt".into(), prompt);
        list.insert("rows".into(), Value::Array(rows));
        list.insert("empty".into(), empty);
        list.insert("footer".into(), self.footer(profile));
        Value::Object(list)
    }
}
