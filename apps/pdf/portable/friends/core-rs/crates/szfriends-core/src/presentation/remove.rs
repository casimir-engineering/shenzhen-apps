//! Remove (`SZFriendsSnapshotBuilder+Remove.m`): what a list row's menu offers (clients that declared `list.menu`) and
//! the question Remove asks first, in the menu and in a friend's details. Removing takes the person off the list; it
//! never blocks or unblocks, and the chat history goes too only when the person ticks the option.

use serde_json::{json, Map, Value};

use super::facts::{PersonFacts, Relation};
use super::SnapshotBuilder;

impl SnapshotBuilder {
    /// Whether this client shows each list row's `menu` (PROTOCOL.md § Capabilities, `list.menu`).
    pub(crate) fn shows_list_menu(&self) -> bool {
        self.audience().has("list.menu")
    }

    /// Remove's question for this person: what happens to them, and, when there is chat history, that it stays unless
    /// the option is ticked. An outgoing request is cancelled rather than removed, and the words say so.
    pub(crate) fn remove_confirm(&self, person: &PersonFacts) -> Value {
        let s = &self.strings;
        let first = self.first_name_for_person(person);
        let who: &[(&str, &str)] = &[("first", &first)];
        let request = person.relation == Relation::OutgoingRequest;
        let body_key = match person.relation {
            Relation::OutgoingRequest => "remove.confirm.body.request",
            Relation::Friend => "remove.confirm.body.friend",
            Relation::Blocked => "remove.confirm.body.blocked",
            Relation::IncomingRequest | Relation::Removed => "remove.confirm.body",
        };
        let has_history = person.last_preview_item_id.as_deref().is_some_and(|id| !id.is_empty());
        let mut body = s.text_with(body_key, who);
        if has_history {
            body.push(' ');
            body.push_str(&s.text_with("remove.confirm.history", who));
        }
        let (title, confirm, cancel) = if request {
            ("remove.confirm.title.request", "action.cancel_request", "remove.confirm.keep")
        } else {
            ("remove.confirm.title", "remove.confirm.button", "static.cancel")
        };
        let mut dialog = Map::new();
        dialog.insert("title".into(), json!(s.text_with(title, who)));
        dialog.insert("body".into(), json!(body));
        dialog.insert("confirm_label".into(), json!(s.text(confirm)));
        dialog.insert("cancel_label".into(), json!(s.text(cancel)));
        dialog.insert("destructive".into(), json!(true));
        if has_history {
            dialog
                .insert("option".into(), json!({"label": s.text("remove.confirm.option"), "field": "delete_history"}));
        }
        Value::Object(dialog)
    }

    /// A list row's menu: Remove, or Cancel request for our own request still waiting.
    pub(crate) fn row_menu(&self, person: &PersonFacts) -> Value {
        let key = if person.relation == Relation::OutgoingRequest { "action.cancel_request" } else { "menu.remove" };
        let mut remove = self.action("remove_friend", self.strings.text(key), "destructive");
        remove.insert("note".into(), Value::Null);
        remove.insert("arm".into(), Value::Null);
        remove.insert("confirm".into(), self.remove_confirm(person));
        json!([remove])
    }
}
