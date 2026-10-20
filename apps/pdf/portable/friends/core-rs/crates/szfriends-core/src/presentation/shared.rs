//! Pieces every view shares (`SZFriendsSnapshotBuilder.m` § People, § Shared view pieces): titles, avatars, routes,
//! the back arrow, the footer, actions, confirmations and the armed Block.

use serde_json::{json, Map, Value};

use super::avatar::{initials, placeholder_color, protocol_fields, Picture};
use super::facts::{PersonFacts, ProfileFacts, Relation, RouteKind, RouteMethod};
use super::strings::Values;
use super::text::{contains_folded, is_space, non_empty_trimmed, trim};
use super::SnapshotBuilder;

/// How long Block's armed pill waits for the second click: long enough to move back and click again, short enough
/// that a pill left behind does not turn a later stray click into a block.
const BLOCK_ARM_SECONDS: i64 = 4;

pub(crate) fn route_kind_name(kind: RouteKind) -> &'static str {
    match kind {
        RouteKind::Local => "local",
        RouteKind::Online => "online",
        RouteKind::Offline => "offline",
        RouteKind::None => "none",
    }
}

pub(crate) fn route_method_name(method: RouteMethod) -> Value {
    match method {
        RouteMethod::Lan => json!("lan"),
        RouteMethod::PeerToPeerWifi => json!("p2p_wifi"),
        RouteMethod::Bluetooth => json!("bluetooth"),
        RouteMethod::Internet => json!("internet"),
        RouteMethod::Relay => json!("relay"),
        RouteMethod::None => Value::Null,
    }
}

/// A string, or null.
pub(crate) fn or_null(value: Option<String>) -> Value {
    value.map_or(Value::Null, Value::String)
}

impl SnapshotBuilder {
    /// The name, or the Friends ID in its display form, or "Someone".
    pub(crate) fn title_for_person(&self, person: &PersonFacts) -> String {
        if let Some(name) = non_empty_trimmed(person.name.as_deref()) {
            return name.to_owned();
        }
        match person.friends_id.as_deref().filter(|id| !id.is_empty()) {
            Some(id) => self.strings.display_id(Some(id)),
            None => self.strings.text("person.unnamed"),
        }
    }

    /// What avatar initials come from: the name, or the raw Friends ID (never the display form, whose U+2011 would
    /// hide the second word's initial).
    pub(crate) fn initials_source(&self, name: Option<&str>, friends_id: Option<&str>) -> String {
        non_empty_trimmed(name).unwrap_or(friends_id.unwrap_or("")).to_owned()
    }

    pub(crate) fn first_name_for_person(&self, person: &PersonFacts) -> String {
        self.strings.first_name(person.name.as_deref(), person.friends_id.as_deref())
    }

    /// PROTOCOL.md type.avatar: only the keys defined for the kind, initials, and an animal's manifest color or a
    /// stable color for the person.
    pub(crate) fn avatar_for_picture(&self, picture: &Picture, seed: &str, display_name: &str) -> Value {
        let fields = protocol_fields(picture, self.animal_set.as_ref());
        let kind = fields.get("kind").and_then(Value::as_str).unwrap_or("placeholder").to_owned();
        let mut avatar = Map::new();
        avatar.insert("kind".into(), json!(kind));
        if kind == "animal" {
            avatar.insert("set".into(), fields["set"].clone());
            avatar.insert("index".into(), fields["index"].clone());
        } else if kind == "image" {
            avatar.insert("path".into(), fields["path"].clone());
        }
        avatar.insert("initials".into(), json!(initials(display_name)));
        let color = match fields.get("color") {
            Some(Value::String(color)) if kind == "animal" => color.clone(),
            _ => placeholder_color(seed).to_owned(),
        };
        avatar.insert("color".into(), json!(color));
        Value::Object(avatar)
    }

    pub(crate) fn avatar_for_person(&self, person: &PersonFacts) -> Value {
        let display = self.initials_source(person.name.as_deref(), person.friends_id.as_deref());
        self.avatar_for_picture(&person.picture, &person.conversation_id, &display)
    }

    /// PROTOCOL.md type.route for a live route or none: a method only describes a working route.
    pub(crate) fn route_for_kind(&self, kind: RouteKind, method: RouteMethod) -> Value {
        let live = matches!(kind, RouteKind::Local | RouteKind::Online);
        json!({
            "kind": route_kind_name(kind),
            "method": if live { route_method_name(method) } else { Value::Null },
            "label": if kind == RouteKind::None { Value::Null } else { json!(self.strings.route_label(kind, method)) },
        })
    }

    pub(crate) fn person_waits(&self, person: &PersonFacts) -> bool {
        if person.relation == Relation::Blocked || person.left_list {
            return false;
        }
        person.relation == Relation::IncomingRequest || person.offers_waiting > 0 || person.key_change_pending
    }

    /// Latest interaction first; ties by conversation id, so two snapshots of the same facts never reorder rows.
    pub(crate) fn people_by_latest_interaction<'a>(&self, people: &'a [PersonFacts]) -> Vec<&'a PersonFacts> {
        let mut sorted: Vec<&PersonFacts> = people.iter().collect();
        sorted.sort_by(|a, b| {
            b.last_interaction_at
                .partial_cmp(&a.last_interaction_at)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.conversation_id.cmp(&b.conversation_id))
        });
        sorted
    }

    /// The filter of list and nearby: names and IDs, case, diacritic and width insensitive. U+2011 in the query
    /// matches "-", and "cottage violet" finds cottage-violet.
    pub(crate) fn matches_query(&self, name: Option<&str>, friends_id: Option<&str>, query: &str) -> bool {
        let needle = trim(query);
        if needle.is_empty() {
            return true;
        }
        let needle = needle.replace('\u{2011}', "-");
        if name.is_some_and(|n| !n.is_empty() && contains_folded(n, &needle)) {
            return true;
        }
        let Some(id) = friends_id.filter(|id| !id.is_empty()) else { return false };
        let as_id = needle.split(is_space).collect::<Vec<_>>().join("-");
        contains_folded(id, &needle) || contains_folded(id, &as_id)
    }

    /// The back arrow toward the list. `this_row_waits`: the view's own row waits too, so the count is "more".
    pub(crate) fn back_to_friends(&self, count: i64, this_row_waits: bool) -> Value {
        let label = if count <= 0 {
            self.strings.text("back.friends")
        } else {
            let key = if this_row_waits { "back.friends.more_waiting" } else { "back.friends.waiting" };
            self.strings.text_count(key, count, &[])
        };
        let badge = self.strings.badge_label(count);
        json!({"badge_count": count.max(0), "badge_label": badge, "accessibility_label": label})
    }

    pub(crate) fn footer(&self, profile: &ProfileFacts) -> Value {
        let name = non_empty_trimmed(profile.name.as_deref());
        let display = name.unwrap_or(&profile.friends_id);
        let id = self.strings.display_id(Some(&profile.friends_id));
        json!({
            "avatar": self.avatar_for_picture(&profile.picture, &profile.friends_id, display),
            "name": name,
            "name_placeholder": self.strings.text("footer.name_placeholder"),
            "id_label": self.strings.text_with("id.label", &[("id", &id)]),
            // Nothing while the ID is unreserved: the note raised a question it could not answer. A changed ID is
            // the list's banner; the field stays for views that read it.
            "id_note": Value::Null,
            "friends_id": profile.friends_id,
            "add_label": self.strings.text("footer.add"),
        })
    }

    /// A phone's client (`files.share`): received files go to the system's share sheet there.
    pub(crate) fn on_phone(&self) -> bool {
        self.audience().has("files.share")
    }

    /// `show_file`'s label: "Show in Finder" and its kin, or on a phone "Share…".
    pub(crate) fn show_file_label(&self) -> String {
        if self.on_phone() {
            self.strings.text("action.share")
        } else {
            self.strings.text_with("action.show_in", &[("app", &self.audience().reveal_in)])
        }
    }

    pub(crate) fn action(&self, action: &str, label: String, style: &str) -> Map<String, Value> {
        let mut map = Map::new();
        map.insert("action".into(), json!(action));
        map.insert("label".into(), json!(label));
        map.insert("style".into(), json!(style));
        map
    }

    /// A confirmation dialog from catalog keys filled with `values`.
    pub(crate) fn confirm(&self, title: &str, body: &str, confirm: &str, values: Values, destructive: bool) -> Value {
        json!({
            "title": self.strings.text_with(title, values),
            "body": self.strings.text_with(body, values),
            "confirm_label": self.strings.text_with(confirm, values),
            "cancel_label": self.strings.text("static.cancel"),
            "destructive": destructive,
        })
    }

    pub(crate) fn block_arm(&self, who: &str) -> Value {
        json!({
            "label": self.strings.text("list.action.block.armed"),
            "accessibility_label": self.strings.text_with("list.action.block.armed_spoken", &[("title", who)]),
            "seconds": BLOCK_ARM_SECONDS,
        })
    }

    /// Block anywhere in the dropdown: destructive, and armed like the list row's.
    pub(crate) fn block_action(&self, who: &str, label: String) -> Map<String, Value> {
        let mut block = self.action("block", label, "destructive");
        block.insert("arm".into(), self.block_arm(who));
        block
    }

    pub(crate) fn empty(&self, kind: Option<&str>, title: String, body: Option<String>) -> Value {
        let mut empty = Map::new();
        empty.insert("title".into(), json!(title));
        empty.insert("body".into(), or_null(body));
        if let Some(kind) = kind {
            empty.insert("kind".into(), json!(kind));
        }
        Value::Object(empty)
    }
}
