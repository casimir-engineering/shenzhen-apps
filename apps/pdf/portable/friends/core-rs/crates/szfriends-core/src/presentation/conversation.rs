//! The conversation view (`SZFriendsSnapshotBuilder+Conversation.m`): header, back arrow, items, request card,
//! composer. A pending request replaces history and composer with the request card, whose comparison code both
//! screens show so the two people can check they reached each other. The composer says when queued messages go, from
//! the reader's side, naming every app that runs Friends.

use serde_json::{json, Map, Value};

use super::facts::{ItemFacts, PersonFacts, Relation, RouteKind, RouteMethod};
use super::SnapshotBuilder;

fn is_request(person: &PersonFacts) -> bool {
    matches!(person.relation, Relation::IncomingRequest | Relation::OutgoingRequest)
}

impl SnapshotBuilder {
    fn header(&self, person: &PersonFacts) -> Value {
        let s = &self.strings;
        let title = self.title_for_person(person);
        let details = !is_request(person);
        let blocked = person.relation == Relation::Blocked;
        let subtitle =
            if blocked { Some(s.text("list.subtitle.blocked")) } else { self.route_label_for_person(person) };
        // The line is said as well as shown, whatever it says.
        let said = if blocked {
            subtitle.as_deref().map(|t| s.spoken_fragment(t))
        } else {
            self.spoken_route_for_person(person)
        };
        let said = said.unwrap_or_default();
        let values = [("title", title.as_str()), ("route", said.as_str())];
        let spoken = if details {
            s.text_with(
                if subtitle.is_some() { "header.spoken.route_details" } else { "header.spoken.details" },
                &values,
            )
        } else if subtitle.is_some() {
            s.text_with("header.spoken.route", &values)
        } else {
            title.clone()
        };
        // A blocked friend's line says "Blocked", not how they are connected, so it carries no route icon.
        let route = if blocked {
            self.route_for_kind(RouteKind::None, RouteMethod::None)
        } else {
            self.route_for_person(person)
        };
        json!({
            "title": title,
            "subtitle": subtitle,
            "route": route,
            "avatar": self.avatar_for_person(person),
            "details_available": details,
            "accessibility_label": spoken,
        })
    }

    fn request_card(&self, person: &PersonFacts, now: f64) -> Value {
        if !is_request(person) {
            return Value::Null;
        }
        let s = &self.strings;
        let incoming = person.relation == Relation::IncomingRequest;
        // An unconfirmed answer to our own Add by ID waits like a request, and says what we asked for and why.
        let answer = incoming && person.unconfirmed_answer_id.as_deref().is_some_and(|id| !id.is_empty());
        let title = self.title_for_person(person);
        let first = self.first_name_for_person(person);
        let asked = s.display_id(person.unconfirmed_answer_id.as_deref());
        let values = [("title", title.as_str()), ("first", first.as_str()), ("id", asked.as_str())];
        let mut parts = vec![if answer {
            s.text_with("request.asked_for", &values)
        } else if incoming {
            s.text(if person.request_found_nearby { "request.found_nearby" } else { "request.by_id" })
        } else {
            s.text("request.sent")
        }];
        if let Some(at) = person.request_at {
            parts.push(s.moment_phrase(at, now));
        }
        if let Some(id) = person.friends_id.as_deref().filter(|id| !id.is_empty()) {
            parts.push(s.text_with("id.label", &[("id", &s.display_id(Some(id)))]));
        }
        let mut subtitle = parts.join(" · ");
        if !incoming && parts.len() > 1 {
            // "Request sent · today at 14:40" reads better as "Sent today at 14:40" after the card's title.
            subtitle = s.text_with("request.sent_at", &[("moment", &parts[1])]);
            if let Some(id) = parts.get(2) {
                subtitle.push_str(&format!(" · {id}"));
            }
        }
        let code = person.comparison_code.as_deref().filter(|c| c.encode_utf16().count() == 6);
        let mut actions = Vec::new();
        if incoming {
            actions.push(Value::Object(self.action("accept_request", s.text("action.accept"), "primary")));
            actions.push(Value::Object(self.action("decline_request", s.text("action.decline"), "secondary")));
            // Destructive and armed like the list row's Block, never a link beside Accept and Decline.
            actions.push(Value::Object(self.block_action(&first, s.text_with("action.block", &values))));
        } else {
            actions.push(Value::Object(self.action("cancel_request", s.text("action.cancel_request"), "secondary")));
        }
        let prompt = match (code, incoming) {
            (Some(_), true) => "request.code_prompt.incoming",
            (Some(_), false) => "request.code_prompt.outgoing",
            (None, _) => "request.code_later",
        };
        let (title_key, footnote_key) = if answer {
            ("request.title.answer", "request.footnote.answer")
        } else if incoming {
            ("request.title.incoming", "request.footnote.incoming")
        } else {
            ("request.title.outgoing", "request.footnote.outgoing")
        };
        json!({
            "direction": if incoming { "incoming" } else { "outgoing" },
            "avatar": self.avatar_for_person(person),
            "title": s.text_with(title_key, &values),
            "subtitle": subtitle,
            "code_prompt": s.text_with(prompt, &values),
            "comparison_code": code.map(|c| s.grouped_comparison_code(c)),
            "comparison_code_accessibility_label": code.map(|c| s.spoken_comparison_code(c)),
            "actions": actions,
            "footnote": s.text_with(footnote_key, &values),
        })
    }

    fn composer_hint(&self) -> Vec<Value> {
        let s = &self.strings;
        let audience = self.audience();
        let mut parts: Vec<(Option<&str>, String)> = Vec::new();
        if audience.has("attach.items") {
            parts.push((Some("#"), s.text("composer.hint.attach")));
        }
        if audience.has("mentions") {
            parts.push((Some("@"), s.text("composer.hint.mention")));
        }
        if audience.has("assistant.drafts") {
            parts.push((Some("/"), s.text("composer.hint.assistant")));
        }
        if audience.has("drop.files") {
            let key = if parts.is_empty() { "composer.hint.drop_alone" } else { "composer.hint.drop" };
            parts.push((None, s.text(key)));
        }
        let mut segments = Vec::new();
        let mut plain = String::new();
        for (i, (key, label)) in parts.iter().enumerate() {
            if i > 0 {
                plain.push_str(" · ");
            }
            if let Some(key) = key {
                if !plain.is_empty() {
                    segments.push(json!({"text": plain}));
                }
                plain.clear();
                segments.push(json!({"text": key, "emphasis": true}));
                plain.push(' ');
            }
            plain.push_str(label);
        }
        if !plain.is_empty() {
            segments.push(json!({"text": plain}));
        }
        segments
    }

    fn composer(&self, person: &PersonFacts) -> Value {
        let s = &self.strings;
        let first = self.first_name_for_person(person);
        let values = [("first", first.as_str())];
        let request = is_request(person);
        let friend = person.relation == Relation::Friend;
        let enabled = friend && !person.key_change_pending;
        let note = match person.relation {
            Relation::Blocked => Some(s.text_with("composer.note.blocked", &values)),
            Relation::Removed => {
                let key = if person.link_contact { "composer.note.link_contact" } else { "composer.note.removed" };
                Some(s.text_with(key, &values))
            }
            _ if person.key_change_pending => Some(s.text_with("composer.note.key_change", &values)),
            Relation::Friend => self.composer_reach_note(person),
            _ => None,
        };
        let mut composer = Map::new();
        composer.insert("visible".into(), json!(!request));
        composer.insert("enabled".into(), json!(enabled));
        composer.insert("placeholder".into(), json!(s.text_with("composer.placeholder", &values)));
        composer.insert("hint".into(), Value::Array(if request { Vec::new() } else { self.composer_hint() }));
        composer.insert("send_label".into(), json!(s.text("composer.send")));
        composer.insert("note".into(), json!(note));
        composer.insert("accepts_drops".into(), json!(enabled && self.audience().has("drop.files")));
        // PROTOCOL.md § Limits: one session frame.
        composer.insert("max_text_bytes".into(), json!(32_768));
        // The @ picker's footer, for clients that show mentions.
        if let Some(note) = self.mention_note(person, enabled) {
            composer.insert("mention_note".into(), note);
        }
        Value::Object(composer)
    }

    pub(crate) fn build_conversation(
        &self,
        person: &PersonFacts,
        items: &[ItemFacts],
        has_earlier: bool,
        highlight_item_id: Option<&str>,
        waiting_elsewhere: i64,
        now: f64,
    ) -> Value {
        let request = is_request(person);
        let rendered = if request { Vec::new() } else { self.items_for_person(person, items, highlight_item_id, now) };
        let highlight_shown = rendered.iter().any(|item| item["highlighted"] == true);
        json!({
            "conversation_id": person.conversation_id,
            "header": self.header(person),
            "back": self.back_to_friends(waiting_elsewhere, self.person_waits(person)),
            "search_placeholder": self.strings.text("static.conversation_search_placeholder"),
            "has_earlier": has_earlier && !request,
            "items": rendered,
            "highlight_item_id": if highlight_shown { json!(highlight_item_id) } else { Value::Null },
            "request": self.request_card(person, now),
            "composer": self.composer(person),
        })
    }
}
