//! Words items and list rows share (`SZFriendsSnapshotBuilder+Previews.m`): the row's preview of the latest message
//! ("You: 📎 Supplier contract v3.pdf", "Mei: Can you check pages 3–5?"), event text, the outgoing status a row and a spoken label
//! share, which failures Try again can still change, and why a row refuses dragged files.

use serde_json::{json, Value};

use super::facts::{event, failure, ItemFacts, ItemKind, OutboxState, PersonFacts, Relation, TransferState};
use super::mention_view::MentionDirectory;
use super::text::{composed_range16, from_utf16, is_space_or_newline, utf16};
use super::SnapshotBuilder;

/// Long previews are cut so a list snapshot never carries whole 32 KB messages; views truncate visually anyway.
const PREVIEW_LENGTH: usize = 120;

/// The statuses a list row shows: the item did not arrive. Those still under way say nothing there.
const SHOWN_STATUSES: [&str; 5] = ["failed", "didnt_arrive", "declined_by_them", "declined_by_you", "cancelled"];

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

    /// A friend's list row: their latest message or file, as "You: …" or "Mei: …" (a file as "📎 name", several sent
    /// together as "3 files"), or "No messages yet". Only a status saying it did not arrive shows, first so a narrow
    /// row keeps it; the route icons already say whether the friend is reachable. Spoken, every status follows.
    pub(crate) fn preview(
        &self,
        item: Option<&ItemFacts>,
        person: &PersonFacts,
        directory: Option<&MentionDirectory>,
    ) -> Preview {
        let s = &self.strings;
        let first = self.first_name_for_person(person);
        let who = [("first", first.as_str())];
        let link_file = item.and_then(|item| {
            let link = item.kind == ItemKind::Event && item.event_kind.as_deref() == Some(event::RECEIVED_LINK_FILE);
            link.then(|| item.event_arguments.get("file").cloned().unwrap_or_default())
        });
        let Some(item) = item.filter(|item| item.kind != ItemKind::Event || link_file.is_some()) else {
            let text = s.text("list.subtitle.no_messages");
            return Preview { spoken: s.spoken_fragment(&text), visual: text, explains_route: false };
        };
        let message = item.kind == ItemKind::Message;
        // A mention previews as "@Name", never as its link.
        let (content, said_content) = if message {
            let text = self.preview_text(&self.plain_text_of(item.text.as_deref().unwrap_or(""), directory));
            (text.clone(), text)
        } else if person.last_message_files > 1 {
            let text = s.text_with("preview.files", &[("count", &person.last_message_files.to_string())]);
            (text.clone(), text)
        } else {
            let name = link_file.clone().or_else(|| item.file_name.clone()).unwrap_or_default();
            (s.text_with("preview.file", &[("file", &name)]), name)
        };
        let status = if link_file.is_some() { None } else { self.status_key(item).filter(|s| *s != "waiting") };
        let explains_route = status == Some("queued");
        let said_key = match (item.outgoing, message) {
            (true, true) => "preview.you_said",
            (true, false) => "preview.you_sent",
            (false, true) => "preview.they_said",
            (false, false) => "preview.they_sent",
        };
        let mut said = s.text_with(said_key, &[("first", &first), ("text", &said_content)]);
        let mut visual = if item.outgoing {
            s.text_with("preview.you", &[("text", &content)])
        } else {
            s.text_with("preview.them", &[("first", &first), ("text", &content)])
        };
        if let Some(status) = status {
            let key = if status == "queued" {
                self.waiting_key("preview.status", person)
            } else {
                format!("preview.status.{status}")
            };
            if SHOWN_STATUSES.contains(&status) {
                let shown = s.text_with(&key, &who);
                visual = s.text_with("preview.status_first", &[("status", &shown), ("text", &visual)]);
            }
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
    /// Whether list rows carry `drop_label`: the host takes dropped files (`drop.files`), or holds files the person
    /// sends to someone chosen from the list without any drag (`send.files`: a phone's share sheet).
    pub(crate) fn rows_take_files(&self) -> bool {
        self.audience().has("drop.files") || self.audience().has("send.files")
    }

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
