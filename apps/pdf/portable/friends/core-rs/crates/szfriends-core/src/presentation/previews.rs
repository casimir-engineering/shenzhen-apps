//! Words items and list rows share (`SZFriendsSnapshotBuilder+Previews.m`): the row's preview of the latest item
//! ("Sends when Priya is nearby · Supplier contract v3.pdf"), event text, the outgoing status a row and a spoken label
//! share, which failures Try again can still change, and why a row refuses dragged files.

use serde_json::{json, Value};

use super::facts::{failure, ItemFacts, ItemKind, OutboxState, PersonFacts, Relation, TransferState};
use super::mention_view::MentionDirectory;
use super::text::{composed_range16, from_utf16, is_space_or_newline, utf16};
use super::SnapshotBuilder;

/// Long previews are cut so a list snapshot never carries whole 32 KB messages; views truncate visually anyway.
const PREVIEW_LENGTH: usize = 120;

/// A list row's subtitle, its spoken form, and whether it already says the friend is not reachable (a queued item).
pub(crate) struct Preview {
    pub visual: String,
    pub spoken: String,
    pub explains_route: bool,
}

/// Failures that trying again cannot change: the other Mac turned the item down, or the file to send is gone.
fn retry_can_work(failure_reason: Option<&str>) -> bool {
    !matches!(failure_reason, Some(failure::REFUSED | failure::SOURCE_MISSING))
}

impl SnapshotBuilder {
    /// `key` with the failure's own words when the catalog has them, otherwise `key` itself. A refusal toward someone
    /// removed or blocked gets words about what the person did.
    pub(crate) fn key_for_failure(&self, key: &str, failure_reason: Option<&str>, person: &PersonFacts) -> String {
        let Some(reason) = failure_reason.filter(|r| !r.is_empty()) else { return key.to_owned() };
        let specific = format!("{key}.{reason}");
        let ended = match person.relation {
            Relation::Removed => Some("removed"),
            Relation::Blocked => Some("blocked"),
            _ => None,
        };
        if let Some(ended) = ended.filter(|_| reason == failure::REFUSED) {
            let own = format!("{specific}.{ended}");
            if self.strings.has(&own) {
                return own;
            }
        }
        if self.strings.has(&specific) {
            specific
        } else {
            key.to_owned()
        }
    }

    /// Try again shows only while sending to the person can work.
    pub(crate) fn can_retry(&self, failure_reason: Option<&str>, person: &PersonFacts) -> bool {
        person.relation == Relation::Friend && !person.key_change_pending && retry_can_work(failure_reason)
    }

    fn preview_text(&self, text: &str) -> String {
        let collapsed = text.split(is_space_or_newline).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ");
        let units = utf16(&collapsed);
        if units.len() <= PREVIEW_LENGTH {
            return collapsed;
        }
        let (start, end) = composed_range16(&collapsed, 0, PREVIEW_LENGTH);
        format!("{}…", from_utf16(&units[start..end]))
    }

    /// A catalog phrase inside a spoken label, lowered only when it does not open with the person's name or ID.
    pub(crate) fn spoken_phrase(&self, phrase: &str, person: &PersonFacts) -> String {
        let first = self.first_name_for_person(person);
        let opens_with_id = person.friends_id.as_deref().is_some_and(|id| !id.is_empty() && phrase.starts_with(id));
        if (!first.is_empty() && phrase.starts_with(&first)) || opens_with_id {
            return phrase.to_owned();
        }
        self.strings.spoken_fragment(phrase)
    }

    /// Only kinds with a catalog entry are shown.
    pub(crate) fn event_text(&self, item: &ItemFacts, person: &PersonFacts) -> Option<String> {
        let key = format!("event.{}", item.event_kind.as_deref().unwrap_or(""));
        if !self.strings.has(&key) {
            return None;
        }
        let first = self.first_name_for_person(person);
        let mut values = vec![("first", first.as_str())];
        if let Some(file) = item.event_arguments.get("file") {
            values.push(("file", file));
        }
        Some(self.strings.text_with(&key, &values))
    }

    /// The outgoing status suffix a list row and a spoken label share; None when nothing needs saying.
    fn status_key(&self, item: &ItemFacts) -> Option<&'static str> {
        if item.kind == ItemKind::Message {
            if !item.outgoing {
                return None;
            }
            if item.cancelled {
                return Some("cancelled");
            }
            return match item.outbox_state {
                Some(OutboxState::Queued) => Some("queued"),
                Some(OutboxState::Failed) => Some("failed"),
                _ => None,
            };
        }
        Some(match item.state() {
            TransferState::Queued => "queued",
            TransferState::Offered => "offered",
            TransferState::Sending => "sending",
            TransferState::Receiving => "receiving",
            TransferState::Declined if item.outgoing => "declined_by_them",
            TransferState::Declined => "declined_by_you",
            TransferState::Cancelled => "cancelled",
            TransferState::Failed if item.outgoing => "failed",
            TransferState::Failed => "didnt_arrive",
            TransferState::Received if item.accepted_automatically => "auto",
            TransferState::WaitingForYou => "waiting",
            _ => return None,
        })
    }

    pub(crate) fn preview(
        &self,
        item: Option<&ItemFacts>,
        person: &PersonFacts,
        directory: Option<&MentionDirectory>,
    ) -> Preview {
        let s = &self.strings;
        let first = self.first_name_for_person(person);
        let who = [("first", first.as_str())];
        let Some(item) = item else {
            return Preview { visual: String::new(), spoken: String::new(), explains_route: false };
        };
        if item.kind == ItemKind::Event {
            let text = self.event_text(item, person).unwrap_or_default();
            let spoken = self.spoken_phrase(&text, person);
            return Preview { visual: text, spoken, explains_route: false };
        }
        let message = item.kind == ItemKind::Message;
        // A mention previews as "@Name", never as its link.
        let content = if message {
            self.preview_text(&self.plain_text_of(item.text.as_deref().unwrap_or(""), directory))
        } else {
            item.file_name.clone().unwrap_or_default()
        };
        let mut status = self.status_key(item);
        let explains_route = status == Some("queued");
        let mut visual = content.clone();
        let mut said = content.clone();
        if item.outgoing {
            visual = s.text_with("preview.you", &[("text", &content)]);
            let key = if message { "preview.you_said" } else { "preview.you_sent" };
            said = s.text_with(key, &[("text", &content)]);
        } else if !message && status == Some("waiting") {
            visual = s.text_with("list.subtitle.offer", &[("file", &content)]);
            said = s.spoken_fragment(&visual);
            status = None;
        }
        if let Some(status) = status {
            // Status first, so a narrow row cut short still says whether it went; spoken, it follows the content.
            let key = if status == "queued" {
                self.waiting_key("preview.status", person)
            } else {
                format!("preview.status.{status}")
            };
            let shown = s.text_with(&key, &who);
            visual = s.text_with("preview.status_first", &[("status", &shown), ("text", &content)]);
            let said_status = s.text_with(&format!("{key}.spoken"), &who);
            said = s.text_with("preview.with_status.spoken", &[("text", &said), ("status", &said_status)]);
        }
        Preview { visual, spoken: said, explains_route }
    }

    /// A list row's subtitle for `item` and its spoken form, mentions resolved through `mention_directory`.
    pub fn row_preview(&self, item: &ItemFacts, person: &PersonFacts) -> (String, String) {
        let preview = self.preview(Some(item), person, self.mention_directory.as_ref());
        (preview.visual, preview.spoken)
    }

    /// Why a row will not take dragged files, or null when no file can be dragged in this client at all.
    pub(crate) fn drop_refusal(&self, person: &PersonFacts) -> Value {
        if !self.audience().has("drop.files") {
            return Value::Null;
        }
        let key = match person.relation {
            Relation::IncomingRequest | Relation::OutgoingRequest => "list.drop_refusal.request",
            Relation::Removed => "list.drop_refusal.removed",
            Relation::Blocked => "list.drop_refusal.blocked",
            Relation::Friend => "list.drop_refusal.key_change",
        };
        json!(self.strings.text_with(key, &[("first", &self.first_name_for_person(person))]))
    }
}
