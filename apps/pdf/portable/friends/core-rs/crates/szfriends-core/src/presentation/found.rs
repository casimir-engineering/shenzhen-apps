//! How a nearby person was found (`SZFriendsSnapshotBuilder+Nearby.m` § Found): for clients that declared
//! `nearby.found`, each Nearby row and the list row of a friend seen nearby say which discovery methods see the person
//! now (local network, direct Wi-Fi, Bluetooth), with the route icons and a short label.

use serde_json::{json, Value};

use super::facts::RouteMethod;
use super::shared::route_method_name;
use super::SnapshotBuilder;

/// The methods a row names, in the order they are shown.
const ORDER: [(RouteMethod, &str); 3] = [
    (RouteMethod::Lan, "found.lan"),
    (RouteMethod::PeerToPeerWifi, "found.p2p_wifi"),
    (RouteMethod::Bluetooth, "found.bluetooth"),
];

impl SnapshotBuilder {
    /// Whether this client shows `found` (PROTOCOL.md § Capabilities, `nearby.found`).
    pub(crate) fn shows_found(&self) -> bool {
        self.audience().has("nearby.found")
    }

    /// `found` for a person the discovery methods `methods` see now, and what it adds to the row's spoken form; null
    /// and nothing when no method sees them.
    pub(crate) fn found(&self, methods: &[RouteMethod]) -> (Value, Option<String>) {
        let s = &self.strings;
        let seen: Vec<(RouteMethod, &str)> = ORDER.iter().copied().filter(|(m, _)| methods.contains(m)).collect();
        let words: Vec<String> = seen.iter().map(|(_, key)| s.text(key)).collect();
        let label = match words.as_slice() {
            [] => return (Value::Null, None),
            [one] => one.clone(),
            [first, second] => s.text_with("found.join", &[("first", first), ("second", second)]),
            [first, second, third, ..] => {
                s.text_with("found.join3", &[("first", first), ("second", second), ("third", third)])
            }
        };
        let names: Vec<Value> = seen.iter().map(|(m, _)| route_method_name(*m)).collect();
        let spoken = s.text_with("found.spoken", &[("methods", &label)]);
        (json!({"methods": names, "label": label}), Some(spoken))
    }
}
