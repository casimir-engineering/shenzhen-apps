//! A file the person moved or deleted, in snapshots (`SZFriendsSnapshotBuilder+Again.m`, PROTOCOL.md § Getting a file
//! again). The reader is the person who received it: the item says it is not where it was saved anymore and, for a
//! file a friend sent that none of their computers holds, offers Get again from that friend, then says how it is
//! coming or that the friend no longer has it. A file another of the person's computers still holds is shown by
//! `devices_files.rs` ("On Raph’s Mac mini" with Get).

use serde_json::{json, Map, Value};

use super::devices_files::percent_of;
use super::facts::{AgainState, ItemFacts, PersonFacts, Relation};
use super::SnapshotBuilder;

impl SnapshotBuilder {
    /// A transfer item by where its bytes are: here (as built), on another computer (devices), or moved or deleted,
    /// with Get again from the friend who sent it.
    pub(crate) fn transfer_where_it_is(
        &self,
        mut transfer: Map<String, Value>,
        item: &ItemFacts,
        person: &PersonFacts,
    ) -> Map<String, Value> {
        let transfer_id = transfer.get("transfer_id").and_then(Value::as_str).unwrap_or("");
        let on_another_computer = self.devices.as_ref().is_some_and(|facts| facts.files.contains_key(transfer_id));
        if !item.file_missing || on_another_computer {
            return self.transfer_with_devices(transfer, item, person);
        }
        let s = &self.strings;
        let info = transfer.get("file").cloned().unwrap_or(Value::Null);
        let field = |key: &str| info[key].as_str().unwrap_or("").to_owned();
        let name = self.title_for_person(person);
        let sender = if item.outgoing { String::new() } else { name.clone() };
        let (file, kind, size) = (field("name"), field("kind_label"), field("size_label"));
        let apps = s.text("apps.with_friends");
        let percent = percent_of(item.again_fraction).to_string();
        let values = [
            ("sender", sender.as_str()),
            ("file", file.as_str()),
            ("kind", kind.as_str()),
            ("size", size.as_str()),
            ("device", name.as_str()),
            ("name", name.as_str()),
            ("apps", apps.as_str()),
            ("percent", percent.as_str()),
        ];
        // Only a friend's own file comes back from them; anything else stays moved or deleted.
        let from_friend = !item.outgoing && person.relation == Relation::Friend && !self.is_you(person);
        let again = if from_friend { item.again } else { AgainState::None };
        let mut state = "fetching";
        let mut spoken_key = if item.outgoing { "devices.spoken.transfer.out" } else { "devices.spoken.transfer.in" };
        let mut progress = Value::Null;
        let mut actions = json!([self.action("cancel_transfer", s.text("static.cancel"), "link")]);
        let status = match again {
            AgainState::Gone => {
                state = "gone";
                spoken_key = "devices.spoken.transfer.gone";
                actions = json!([]);
                s.text_with("transfer.status.again_gone", &values)
            }
            AgainState::Asked if item.again_connected => {
                progress = self.copy_progress(item.again_fraction);
                spoken_key = "devices.spoken.transfer.fetching";
                s.text_with("transfer.status.fetching", &values)
            }
            AgainState::Asked => {
                let key = if s.reaches_online() {
                    "transfer.status.fetch_waiting.online"
                } else {
                    "transfer.status.fetch_waiting"
                };
                s.text_with(key, &values)
            }
            AgainState::None => {
                state = "missing";
                let offered = from_friend && self.audience().has("files.again");
                actions = if offered {
                    json!([self.action("fetch_from_friend", s.text("transfer.action.again"), "primary")])
                } else {
                    json!([])
                };
                s.text("transfer.status.missing")
            }
        };
        // Said inside a sentence, except "gone", a sentence of its own; the templates end the sentence themselves.
        let said = if state == "gone" { status.clone() } else { s.spoken_fragment(&status) };
        let said = said.strip_suffix('.').unwrap_or(&said).to_owned();
        let mut spoken_values = values.to_vec();
        spoken_values.push(("status", &said));
        transfer.insert("state".into(), json!(state));
        transfer.insert("status_label".into(), json!(status));
        transfer.insert("progress".into(), progress);
        transfer.insert("route_note".into(), Value::Null);
        transfer.insert("actions".into(), actions);
        transfer.insert("accessibility_label".into(), json!(s.text_with(spoken_key, &spoken_values)));
        transfer
    }
}
