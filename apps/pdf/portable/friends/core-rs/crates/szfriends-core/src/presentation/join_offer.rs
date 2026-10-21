//! Offering the person's existing profile here, and saying how to add another computer or phone
//! (`SZFriendsSnapshotBuilder+Devices.m`, PROTOCOL.md § Joining, Offering it, and § Devices). Two readers: someone
//! setting up this computer or phone who already uses Friends elsewhere, who wonders how to bring those friends and
//! chats here and what it costs; and the person at a computer of the profile, who wonders how to add another one.

use serde_json::{json, Map, Value};

use super::devices::DevicesFacts;
use super::SnapshotBuilder;

impl SnapshotBuilder {
    /// `<key>.phone` on a phone or tablet when the catalog has one ("this device" where a computer says "this
    /// computer"), else `key`.
    pub(crate) fn device_key(&self, key: &str) -> String {
        let phone = format!("{key}.phone");
        if self.on_phone() && self.strings.has(&phone) {
            phone
        } else {
            key.to_owned()
        }
    }

    /// What another computer's system says to the person: a phone's ("Android", "iOS") as a phone ("Android
    /// phone"), a computer's as it is ("macOS 26.1").
    pub(crate) fn device_system_label(&self, system: &str) -> String {
        match phone_system_key(system) {
            Some(key) => self.strings.text(key),
            None => system.to_owned(),
        }
    }

    /// profile.devices.add: what to do there, the ID to type, and Approve here; null on a removed computer.
    pub(crate) fn add_device(&self, facts: &DevicesFacts) -> Value {
        let Some(id) = facts.friends_id.as_deref().filter(|id| !id.is_empty() && !facts.removed) else {
            return Value::Null;
        };
        let s = &self.strings;
        let shown = s.display_id(Some(id));
        json!({
            "title": s.text("devices.add.title"),
            "steps": [
                s.text("devices.add.step.open"),
                s.text_with("devices.add.step.id", &[("id", &shown)]),
                s.text(&self.device_key("devices.add.step.approve")),
            ],
            "friends_id": id,
        })
    }

    /// The button that offers the person's existing profile here: the join view at once while this computer has
    /// nobody to lose, else Reset Friends first, with a confirmation that says what goes, and the join view after it
    /// (`then`, which the view keeps to itself). None where it is not offered.
    fn join_offer_action(&self, style: &str) -> Option<Map<String, Value>> {
        let facts = self.devices.as_ref()?;
        if facts.removed || !(facts.join_offered || facts.join_replaces) {
            return None;
        }
        let label = self.strings.text("join.offer.action");
        if facts.join_offered {
            return Some(self.action("open_join", label, style));
        }
        let mut action = self.action("reset_friends", label, style);
        let id = self.strings.display_id(facts.friends_id.as_deref());
        let body = self.device_key(&self.deletion_body_key("join.offer.confirm.body"));
        let confirm =
            self.confirm("join.offer.confirm.title", &body, "join.offer.confirm.button", &[("id", &id)], true);
        action.insert("confirm".into(), confirm);
        action.insert("then".into(), json!("open_join"));
        Some(action)
    }

    /// settings.join, or None when joining is not offered here.
    pub(crate) fn settings_join(&self) -> Option<Value> {
        let action = self.join_offer_action("secondary")?;
        let s = &self.strings;
        Some(json!({"label": s.text("settings.join.label"), "note": s.text("join.offer.note"), "action": action}))
    }

    /// list.join: while the name prompt shows, and while this computer has nobody in Friends, where someone setting
    /// up a new computer looks first, even once they chose a name.
    pub(crate) fn list_join(&self, name_prompt: bool) -> Value {
        let offered = self.devices.as_ref().is_some_and(|facts| facts.join_offered);
        match self.join_offer_action("link") {
            Some(action) if name_prompt || offered => {
                json!({"note": self.strings.text("join.offer.note"), "action": action})
            }
            _ => Value::Null,
        }
    }
}

/// The catalog key for a phone's system, or None for a computer's.
pub(crate) fn phone_system_key(system: &str) -> Option<&'static str> {
    let lower = system.to_lowercase();
    if lower.starts_with("android") {
        Some("devices.system.android")
    } else if lower.starts_with("ios") || lower.starts_with("ipados") {
        Some("devices.system.ios")
    } else {
        None
    }
}
