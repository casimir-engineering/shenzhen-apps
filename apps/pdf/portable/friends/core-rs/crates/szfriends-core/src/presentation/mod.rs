//! Friends' presentation (`service/presentation/`): the string catalog and the builder of display-ready snapshots.
//!
//! Logic lives in the service, not the views. This layer turns plain facts into exactly the `data` objects
//! PROTOCOL.md documents per view: rows already sorted, labels such as "Yesterday" or "Over Bluetooth, about 6 min",
//! countdown text, badge counts and which buttons show. Views render them and nothing more, so the React UI, AppKit
//! and GTK draw the same thing. Pure: no store, radios, sockets or clock reads; time is passed in, so the output is
//! testable against the golden fixtures in `portable/friends/fixtures/snapshots/`, which the suite rebuilds as the
//! same JSON values the Objective-C builder makes.
//!
//! Every user-facing string comes from the catalog ([`catalog`]), written for the person reading it and about what
//! happens to their message ("Sends when Mei is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open").

mod avatar;
pub mod catalog;
mod conversation;
mod details;
mod devices;
mod devices_files;
pub mod facts;
mod found;
mod items;
mod join;
mod join_offer;
mod links;
mod list;
mod mention_view;
pub mod mentions;
mod messages;
mod nearby;
mod previews;
mod remove;
mod routes;
pub mod search;
mod segments;
mod settings;
mod shared;
mod strings;
pub mod text;
pub mod time;
mod transfers;
mod units;

pub use avatar::{initials, placeholder_color, AnimalSet, Picture};
pub use devices::{DeviceFacts, DeviceFileFacts, DevicesFacts};
pub use facts::*;
pub use join::{JoinRequestFacts, JoiningFacts, JoiningState};
pub use mention_view::MentionDirectory;
pub use strings::{Strings, Values};

use serde_json::Value;

/// Builds each view's `data` object exactly as PROTOCOL.md specifies it, for one audience. The helper wraps it in a
/// snapshot frame and sends it only when it differs from the last one sent on that subscription.
#[derive(Clone, Debug)]
pub struct SnapshotBuilder {
    strings: Strings,
    animal_set: Option<AnimalSet>,
    /// What mentions in conversations and search results resolve against; None shows every mention as plain text
    /// under the name its sender wrote. The list resolves its previews against the people and profile it is given.
    pub mention_directory: Option<MentionDirectory>,
    /// One profile on several computers, for an audience whose helper announces "devices"; None keeps every
    /// snapshot as one computer shows it.
    pub devices: Option<DevicesFacts>,
}

impl SnapshotBuilder {
    /// `animal_set`: the set avatars are validated against and colored from (the host's copy of
    /// `avatars/animals/manifest.json`); without one every animal is drawn as a placeholder.
    pub fn new(audience: Audience, animal_set: Option<AnimalSet>) -> Self {
        Self { strings: Strings::new(audience), animal_set, mention_directory: None, devices: None }
    }

    pub fn strings(&self) -> &Strings {
        &self.strings
    }

    pub fn audience(&self) -> &Audience {
        self.strings.audience()
    }

    pub fn animal_set(&self) -> Option<&AnimalSet> {
        self.animal_set.as_ref()
    }

    /// The conversation view; `waiting_elsewhere` counts the rows waiting for an answer other than this one.
    pub fn conversation(
        &self,
        person: &PersonFacts,
        items: &[ItemFacts],
        has_earlier: bool,
        highlight_item_id: Option<&str>,
        waiting_elsewhere: i64,
        now: f64,
    ) -> Value {
        let conversation =
            self.build_conversation(person, items, has_earlier, highlight_item_id, waiting_elsewhere, now);
        self.conversation_with_devices(conversation, person)
    }

    /// The profile view, with Your computers when the builder has devices facts.
    pub fn profile(&self, profile: &ProfileFacts, waiting_elsewhere: i64) -> Value {
        let mut data = self.build_profile(profile, waiting_elsewhere);
        if let (Some(devices), Value::Object(map)) = (&self.devices, &mut data) {
            map.insert("devices".into(), self.devices_section(devices, devices.now));
        }
        data
    }
}
