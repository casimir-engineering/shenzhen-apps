//! Conversation items (`SZFriendsSnapshotBuilder+Items.m`): messages, events, day separators, and the message_status
//! view. Status words are about what happens to the person's message ("Sends when Priya is nearby"), and "Delivered"
//! means it reached their Mac, never that it was read. Transfers are in `transfers.rs`.

use std::collections::HashMap;

use serde_json::{json, Map, Value};

use super::facts::{ItemFacts, ItemKind, OutboxState, PersonFacts};
use super::SnapshotBuilder;

/// A message shows its time only this long after the one before it: a burst reads as one exchange.
const MESSAGE_TIME_GAP: f64 = 5.0 * 60.0;

fn outbox_state_name(state: OutboxState) -> &'static str {
    match state {
        OutboxState::Queued => "queued",
        OutboxState::Connecting => "connecting",
        OutboxState::Sending => "sending",
        OutboxState::Delivered => "delivered",
        OutboxState::Failed => "failed",
    }
}

/// A status inside a spoken template that ends the sentence itself: one period, none after an ellipsis.
pub(crate) fn without_final_period(text: &str) -> String {
    text.strip_suffix('.').or_else(|| text.strip_suffix('…')).unwrap_or(text).to_owned()
}

/// A status said in the middle of a sentence: the ellipsis would be a pause.
fn without_ellipsis(text: &str) -> String {
    text.strip_suffix('…').unwrap_or(text).to_owned()
}

fn ends_sentence(text: &str) -> bool {
    text.chars().last().is_none_or(|c| matches!(c, '.' | '!' | '?' | '…' | '。' | '！' | '？'))
}

impl SnapshotBuilder {
    /// "Via the assistant" on what this person's assistant sent, "Via Kenji's assistant" on what the friend's did.
    pub(crate) fn assistant_label(&self, item: &ItemFacts, person: &PersonFacts) -> Option<String> {
        if !item.via_assistant {
            return None;
        }
        if item.outgoing {
            return Some(self.strings.text("item.assistant.out"));
        }
        Some(self.strings.text_with("item.assistant.in", &[("first", &self.first_name_for_person(person))]))
    }

    /// An outgoing message's status object ({state, label}), the same in its conversation and in message_status;
    /// None for an incoming message, and for one the store has no delivery record of, where no word would be true.
    pub(crate) fn message_status(&self, item: &ItemFacts, person: &PersonFacts) -> Option<Value> {
        if !item.outgoing || item.kind != ItemKind::Message {
            return None;
        }
        if let Some(you) = self.you_status(item, person) {
            return Some(you); // You: on every computer yet?
        }
        if item.cancelled {
            return Some(json!({"state": "cancelled", "label": self.strings.text("message.status.cancelled")}));
        }
        let outbox = item.outbox_state?;
        let mut state = outbox_state_name(outbox);
        let mut key = format!("message.status.{state}");
        if outbox == OutboxState::Failed {
            key = self.key_for_failure(&key, item.failure_reason.as_deref(), person);
        }
        if outbox == OutboxState::Queued {
            // Waiting for the friend: online too once reached online, and connecting while the helper tries.
            key = self.waiting_key("message.status", person);
            if key.ends_with(".connecting") {
                state = "connecting";
            }
        }
        let label = self.strings.text_with(&key, &[("first", &self.first_name_for_person(person))]);
        Some(json!({"state": state, "label": label}))
    }

    /// The message_status view: each of `messages` that is an outgoing message with a delivery record, in the given
    /// order. `people`, keyed by conversation id, names the friend.
    pub fn message_status_view(&self, messages: &[ItemFacts], people: &HashMap<String, PersonFacts>) -> Value {
        let rows: Vec<Value> = messages
            .iter()
            .filter_map(|message| {
                let person = people.get(message.conversation_id.as_deref()?)?;
                let status = self.message_status(message, person)?;
                Some(json!({"message_id": message.item_id, "status": status}))
            })
            .collect();
        json!({"messages": rows})
    }

    fn message_item(&self, item: &ItemFacts, person: &PersonFacts, shows_time: bool) -> Map<String, Value> {
        let s = &self.strings;
        // Mentions resolved for this reader; spoken labels read the plain words, "@Mei Lin".
        let resolved = self.resolved_text(item.text.as_deref().unwrap_or(""), self.mention_directory.as_ref(), true);
        let text = &resolved.plain;
        let clock = s.clock_label(item.sent_at);
        let assistant = self.assistant_label(item, person);
        // Every spoken template names the time right after who sent it, so the assistant is said there too.
        let time = match &assistant {
            Some(assistant) => format!("{clock}, {}", s.spoken_fragment(assistant)),
            None => clock.clone(),
        };
        let status = self.message_status(item, person);
        let mut actions = Vec::new();
        let spoken = match &status {
            _ if !item.outgoing => {
                let sender = self.title_for_person(person);
                s.text_with("message.spoken.in", &[("sender", &sender), ("time", &time), ("text", text)])
            }
            // The store has no delivery record for it: say nothing rather than guess.
            None => s.text_with("message.spoken.out_plain", &[("time", &time), ("text", text)]),
            Some(status) => {
                let failed = !item.cancelled && item.outbox_state == Some(OutboxState::Failed);
                // Cancel only while nothing has left this computer, and never once written to a session that dropped.
                let waiting = !item.cancelled
                    && !item.outbox_written
                    && matches!(item.outbox_state, Some(OutboxState::Queued | OutboxState::Connecting));
                let label = status["label"].as_str().unwrap_or_default();
                if failed && self.can_retry(item.failure_reason.as_deref(), person) {
                    actions.push(Value::Object(self.action("retry_item", s.text("action.try_again"), "link")));
                }
                if waiting {
                    actions.push(Value::Object(self.action("cancel_message", s.text("static.cancel"), "link")));
                }
                // A short status reads inline ("delivered"); a sentence about when it will go reads after the message.
                let sentence =
                    item.cancelled || status["state"] == "queued" || item.outbox_state == Some(OutboxState::Failed);
                if sentence {
                    let text = if ends_sentence(text) { text.clone() } else { format!("{text}.") };
                    let status = without_final_period(label);
                    s.text_with("message.spoken.out_sentence", &[("time", &time), ("text", &text), ("status", &status)])
                } else {
                    let status = s.spoken_fragment(&without_ellipsis(label));
                    s.text_with("message.spoken.out", &[("time", &time), ("status", &status), ("text", text)])
                }
            }
        };
        let mut message = Map::new();
        message.insert("kind".into(), json!("message"));
        message.insert("item_id".into(), json!(item.item_id));
        message.insert("direction".into(), json!(if item.outgoing { "out" } else { "in" }));
        message.insert("text".into(), json!(resolved.markdown));
        // People type Markdown; the host renders it, and `segments` stays the plain-text form.
        message.insert("text_format".into(), json!("markdown"));
        message.insert("segments".into(), Value::Array(resolved.segments));
        message.insert("time_label".into(), if shows_time { json!(clock) } else { Value::Null });
        message.insert("status".into(), status.unwrap_or(Value::Null));
        message.insert("assistant_label".into(), json!(assistant));
        message.insert("actions".into(), Value::Array(actions));
        message.insert("accessibility_label".into(), json!(spoken));
        // Only where a mention shows as a link: views match a click on one against `url`.
        if let Some(mentions) = resolved.mentions {
            message.insert("mentions".into(), Value::Array(mentions));
        }
        message
    }

    /// The conversation's items: day separators, messages, transfers and the events the catalog has words for, in
    /// the sender's timestamp order, then by id (ADR 0001), whatever order they came in.
    pub(crate) fn items_for_person(
        &self,
        person: &PersonFacts,
        items: &[ItemFacts],
        highlight_item_id: Option<&str>,
        now: f64,
    ) -> Vec<Value> {
        let s = &self.strings;
        let mut ordered: Vec<&ItemFacts> = items.iter().collect();
        ordered.sort_by(|a, b| {
            a.sent_at
                .partial_cmp(&b.sent_at)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.item_id.cmp(&b.item_id))
        });
        let mut result = Vec::new();
        let mut previous: Option<f64> = None;
        let mut previous_message: Option<f64> = None;
        for item in ordered {
            let new_day = previous.is_none_or(|p| !s.is_same_day(item.sent_at, p));
            // The first message under a day separator always shows its time.
            if new_day {
                previous_message = None;
            }
            let mut entry = match item.kind {
                ItemKind::Message => {
                    let shows_time = previous_message.is_none_or(|p| (item.sent_at - p).abs() >= MESSAGE_TIME_GAP);
                    previous_message = Some(item.sent_at);
                    self.message_item(item, person, shows_time)
                }
                ItemKind::Transfer => self.transfer_item(item, person),
                ItemKind::Event => {
                    let Some(text) = self.event_text(item, person) else { continue };
                    let moment = s.moment_accessibility_phrase(item.sent_at, now);
                    let spoken = s.text_with("event.spoken", &[("text", &text), ("moment", &moment)]);
                    let mut event = Map::new();
                    event.insert("kind".into(), json!("event"));
                    event.insert("item_id".into(), json!(item.item_id));
                    event.insert("text".into(), json!(text));
                    event.insert("time_label".into(), json!(s.clock_label(item.sent_at)));
                    event.insert("accessibility_label".into(), json!(spoken));
                    event
                }
            };
            if new_day {
                result.push(json!({
                    "kind": "day",
                    "item_id": s.day_item_id(item.sent_at),
                    "label": s.day_label(item.sent_at, now),
                    "highlighted": false,
                    "accessibility_label": s.day_accessibility_label(item.sent_at, now),
                }));
            }
            previous = Some(item.sent_at);
            entry.insert("highlighted".into(), json!(highlight_item_id == Some(item.item_id.as_str())));
            result.push(Value::Object(entry));
        }
        result
    }
}
