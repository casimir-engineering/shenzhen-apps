//! The Nearby tab (`SZFriendsSnapshotBuilder+Nearby.m`). Each discovery method reports its own state, and an
//! unavailable one is never shown as an empty successful search. When the local network cannot work, one prominent
//! card says so with the one action that fixes it, and nothing else on the tab repeats or contradicts it: the
//! visibility line says nothing, the empty state goes when nothing works at all, and Bluetooth is mentioned only while
//! it still finds people. Without a card, when Bluetooth cannot work, one quiet line says who may be missed.

use serde_json::{json, Value};

use super::facts::NEARBY_SEARCHING_SECONDS;
use super::facts::{AdapterState, IdentityState, NearbyFacts, NearbyPersonFacts, ProfileFacts, Relation, RouteMethod};
use super::text::{non_empty_trimmed, trim};
use super::time::rfc3339;
use super::SnapshotBuilder;

fn state_name(state: AdapterState) -> &'static str {
    match state {
        AdapterState::NotAsked => "not_asked",
        AdapterState::Starting => "starting",
        AdapterState::Working => "working",
        AdapterState::Denied => "denied",
        AdapterState::RadioOff => "radio_off",
        AdapterState::Unavailable => "unavailable",
    }
}

fn broken(state: AdapterState) -> bool {
    matches!(state, AdapterState::Denied | AdapterState::RadioOff | AdapterState::Unavailable)
}

impl SnapshotBuilder {
    /// When an empty Nearby stops saying it is looking, if still ahead: the helper rebuilds Nearby then.
    pub fn nearby_refresh_date(&self, nearby: &NearbyFacts, now: f64) -> Option<f64> {
        let bluetooth = nearby.bluetooth_state == AdapterState::Working && !nearby.bluetooth_absent;
        let working = nearby.network_state == AdapterState::Working || bluetooth;
        let end = nearby.working_since.filter(|_| working)? + NEARBY_SEARCHING_SECONDS;
        (end > now).then_some(end)
    }

    /// The `empty` object when no person shows, or null when nothing works or starts (the card above says it all).
    /// `filtered`: people are visible but the filter hides them all. `alert`: the network card is up, so "nobody"
    /// leaves out its body.
    pub fn nearby_empty(&self, nearby: &NearbyFacts, filtered: bool, query: &str, alert: bool, now: f64) -> Value {
        let s = &self.strings;
        let app = [("app", self.audience().app_name.as_str())];
        if filtered {
            let title = s.text_with("search.no_match.title", &[("query", query)]);
            return self.empty(Some("no_match"), title, Some(s.text("search.no_match.body")));
        }
        let bluetooth = if nearby.bluetooth_absent { nearby.network_state } else { nearby.bluetooth_state };
        let states = [nearby.network_state, bluetooth];
        let starting = states.contains(&AdapterState::Starting);
        let working = states.contains(&AdapterState::Working);
        if !working && !starting {
            // The card above (there always is one then) says what is wrong and how to fix it; anything here would
            // only repeat it ("Nearby isn't working right now" under "can't find people on your network").
            return Value::Null;
        }
        // "Nobody" a second after starting is a guess; the first results take a few seconds on any method.
        if !working || self.nearby_refresh_date(nearby, now).is_some() {
            return self.empty(Some("searching"), s.text("nearby.empty.searching.title"), None);
        }
        let body = (!alert).then(|| s.text_with("nearby.empty.nobody.body", &app));
        self.empty(Some("nobody"), s.text("nearby.empty.nobody.title"), body)
    }

    fn visibility(&self, nearby: &NearbyFacts, now: f64) -> Value {
        let s = &self.strings;
        let remaining = nearby.visibility_deadline.map_or(0.0, |deadline| deadline - now);
        if nearby.inbound_blocked && nearby.bluetooth_absent {
            // Nothing nearby can reach this computer, so nothing would see the person.
            return json!({
                "state": "unavailable", "title": null, "body": s.text("visibility.unavailable.firewall"),
                "remaining_label": null, "remaining_accessibility_label": null, "deadline": null, "action": null,
            });
        }
        let bluetooth = if nearby.bluetooth_absent { AdapterState::Unavailable } else { nearby.bluetooth_state };
        let can_advertise = !broken(nearby.network_state) || !broken(bluetooth);
        if remaining > 0.0 && can_advertise {
            return json!({
                "state": "visible",
                "title": s.text("visibility.visible.title"),
                "body": s.text("visibility.visible.body"),
                "remaining_label": s.countdown_label(remaining),
                "remaining_accessibility_label": s.countdown_accessibility_label(remaining),
                "deadline": nearby.visibility_deadline.map(rfc3339),
                "action": self.action("stop_visibility", s.text("visibility.stop"), "secondary"),
            });
        }
        if !can_advertise {
            // Nothing can advertise only while the network is down too, so the card above is up with the one button
            // that fixes it; repeating that here put a second Open Privacy Settings on the tab.
            return json!({
                "state": "unavailable", "title": null, "body": null, "remaining_label": null,
                "remaining_accessibility_label": null, "deadline": null, "action": null,
            });
        }
        json!({
            "state": "hidden", "title": null, "body": s.text("visibility.hidden.body"), "remaining_label": null,
            "remaining_accessibility_label": null, "deadline": null,
            "action": self.action("start_visibility", s.text("visibility.start"), "primary"),
        })
    }

    fn settings_action(&self, target: &str, label_key: &str, style: &str) -> Value {
        let mut action = self.action("open_settings", self.strings.text(label_key), style);
        action.insert("settings_target".into(), json!(target));
        Value::Object(action)
    }

    fn alert(&self, nearby: &NearbyFacts) -> Value {
        let s = &self.strings;
        let app = [("app", self.audience().app_name.as_str())];
        match nearby.network_state {
            AdapterState::Denied => json!({
                "title": s.text_with("alert.network_denied.title", &app),
                "body": s.text_with(
                    if nearby.phone { "alert.network_denied.body.phone" } else { "alert.network_denied.body" },
                    &app,
                ),
                "action": self.settings_action("local_network_privacy", "settings_link.privacy", "secondary"),
            }),
            AdapterState::RadioOff => {
                // Both radios off: the card names both, since the quiet Bluetooth line never shows under a card.
                let both = nearby.bluetooth_state == AdapterState::RadioOff;
                json!({
                    "title": s.text(if both { "alert.radios_off.title" } else { "alert.wifi_off.title" }),
                    "body": s.text(if both { "alert.radios_off.body" } else { "alert.wifi_off.body" }),
                    "action": self.settings_action("wifi", "settings_link.wifi", "secondary"),
                })
            }
            AdapterState::Unavailable => json!({
                "title": s.text_with("alert.network_unavailable.title", &app),
                "body": s.text("alert.network_unavailable.body"),
                "action": self.action("activate", s.text("nearby.try_again"), "secondary"),
            }),
            // Nothing has asked for access yet: Allow starts Nearby, which is when the system asks, the first time.
            AdapterState::NotAsked => json!({
                "title": s.text("alert.not_asked.title"),
                "body": s.text_with(if nearby.phone { "alert.not_asked.body.phone" } else { "alert.not_asked.body" }, &app),
                "action": self.action("activate", s.text("nearby.allow"), "primary"),
            }),
            _ => Value::Null,
        }
    }

    fn note(&self, nearby: &NearbyFacts, alert: bool) -> Value {
        let s = &self.strings;
        let app = [("app", self.audience().app_name.as_str())];
        if nearby.bluetooth_absent {
            // No Bluetooth to speak of; the one line left says why nobody nearby can see this computer.
            let blocked = nearby.inbound_blocked && !alert;
            return if blocked {
                json!({"text": s.text("nearby_inbound_blocked"), "action": null})
            } else {
                Value::Null
            };
        }
        if alert {
            // The card explains the network and has its one fix. Bluetooth is worth a line only while it still finds
            // people, which changes what the person can do; anything else wrong with it would be a second problem
            // and a second button under the first.
            return if nearby.bluetooth_state == AdapterState::Working {
                json!({"text": s.text("note.still_bluetooth"), "action": null})
            } else {
                Value::Null
            };
        }
        if broken(nearby.network_state) {
            return Value::Null;
        }
        match nearby.bluetooth_state {
            AdapterState::RadioOff => json!({
                "text": s.text("note.bluetooth_off"),
                "action": self.settings_action("bluetooth", "settings_link.bluetooth", "link"),
            }),
            AdapterState::Denied => json!({
                "text": s.text_with("note.bluetooth_denied", &app),
                "action": self.settings_action("bluetooth_privacy", "settings_link.privacy", "link"),
            }),
            AdapterState::Unavailable => json!({
                "text": s.text("note.bluetooth_unavailable"),
                "action": self.action("activate", s.text("nearby.try_again"), "link"),
            }),
            AdapterState::NotAsked => json!({
                "text": s.text("note.bluetooth_not_asked"),
                "action": self.action("activate", s.text("nearby.allow"), "link"),
            }),
            _ => Value::Null,
        }
    }

    fn nearby_person(&self, person: &NearbyPersonFacts) -> Value {
        let s = &self.strings;
        let name = non_empty_trimmed(person.name.as_deref());
        let title = match (name, person.friends_id.as_deref().filter(|id| !id.is_empty())) {
            (Some(name), _) => name.to_owned(),
            (None, Some(id)) => s.display_id(Some(id)),
            (None, None) => s.text("person.unnamed"),
        };
        let friend = !person.is_stranger && person.relation == Relation::Friend;
        let mut status: Option<String> = None;
        let mut action = Value::Null;
        let (subtitle, spoken) = if friend {
            let key = match person.route_method {
                RouteMethod::Bluetooth => "nearby.subtitle.bluetooth",
                RouteMethod::PeerToPeerWifi => "nearby.subtitle.p2p_wifi",
                _ => "nearby.subtitle.lan",
            };
            let subtitle = s.text(key);
            let friend_status = s.text("nearby.status.friend");
            let spoken =
                [title.clone(), s.spoken_fragment(&friend_status), s.spoken_fragment(&subtitle).replace(" · ", ", ")]
                    .join(", ");
            status = Some(friend_status);
            (subtitle, spoken)
        } else {
            let subtitle = s.text(if name.is_some() { "nearby.subtitle.visible" } else { "nearby.subtitle.no_name" });
            match person.relation {
                Relation::OutgoingRequest => status = Some(s.text("nearby.status.request_sent")),
                Relation::IncomingRequest => status = Some(s.text("list.subtitle.request")),
                _ if person.nearby_id.as_deref().is_some_and(|id| !id.is_empty()) => {
                    action = Value::Object(self.action("send_request", s.text("nearby.request"), "primary"));
                }
                _ => {}
            }
            // The status says more than "visible now" once there is one.
            let spoken = format!("{title}, {}", s.spoken_fragment(status.as_deref().unwrap_or(&subtitle)));
            (subtitle, spoken)
        };
        let seed = person.conversation_id.as_deref().or(person.nearby_id.as_deref()).unwrap_or(&title).to_owned();
        let initials_from = self.initials_source(person.name.as_deref(), person.friends_id.as_deref());
        json!({
            "nearby_id": person.nearby_id,
            "conversation_id": person.conversation_id,
            "avatar": self.avatar_for_picture(&person.picture, &seed, &initials_from),
            "title": title,
            "subtitle": subtitle,
            "status_label": status,
            "action": action,
            "accessibility_label": spoken,
        })
    }

    /// The nearby view.
    pub fn nearby(&self, nearby: &NearbyFacts, profile: &ProfileFacts, query: &str, now: f64) -> Value {
        if profile.identity_state == IdentityState::Unavailable {
            return self.nearby_without_identity(nearby, profile, query);
        }
        let s = &self.strings;
        let app = [("app", self.audience().app_name.as_str())];
        let alert = self.alert(nearby);
        let has_alert = !alert.is_null();
        let (mut friends, mut others) = (Vec::new(), Vec::new());
        let mut visible = 0;
        for person in &nearby.people {
            if person.relation == Relation::Blocked {
                continue; // blocked people never appear
            }
            visible += 1;
            if !self.matches_query(person.name.as_deref(), person.friends_id.as_deref(), query) {
                continue;
            }
            // Friends first; everyone else in the order the methods reported them, so rows do not jump around.
            let friend = !person.is_stranger && person.relation == Relation::Friend;
            if friend { &mut friends } else { &mut others }.push(self.nearby_person(person));
        }
        friends.append(&mut others);
        let people = friends;
        let trimmed = trim(query);
        let empty = if people.is_empty() {
            self.nearby_empty(nearby, visible > 0 && !trimmed.is_empty(), trimmed, has_alert, now)
        } else {
            Value::Null
        };
        let method = |name: &str, state: AdapterState| {
            let label = s.text_with(&format!("method.{name}.{}", state_name(state)), &app);
            json!({"method": name, "state": state_name(state), "label": label})
        };
        // Only beside people: an empty list already says whether it is looking; with the card up, the note does.
        let status = if nearby.searching && !has_alert && !people.is_empty() {
            json!({"kind": "searching", "label": s.text("nearby.still_looking")})
        } else {
            Value::Null
        };
        json!({
            "query": query,
            "visibility": self.visibility(nearby, now),
            "methods": if nearby.bluetooth_absent {
                json!([method("network", nearby.network_state)])
            } else {
                json!([method("network", nearby.network_state), method("bluetooth", nearby.bluetooth_state)])
            },
            "alert": alert,
            "note": self.note(nearby, has_alert),
            "status": status,
            "people": people,
            "empty": empty,
            "footer": self.footer(profile),
        })
    }

    /// Without an identity nothing runs: no method was asked for anything, so the tab says what the list's banner
    /// says, reset Friends, and never asks for Local Network or Bluetooth access nobody refused.
    fn nearby_without_identity(&self, nearby: &NearbyFacts, profile: &ProfileFacts, query: &str) -> Value {
        let s = &self.strings;
        let method =
            |name: &str| json!({"method": name, "state": "not_asked", "label": s.text("method.identity_unavailable")});
        let methods = if nearby.bluetooth_absent {
            json!([method("network")])
        } else {
            json!([method("network"), method("bluetooth")])
        };
        json!({
            "query": query,
            "visibility": {
                "state": "unavailable", "title": null, "body": s.text("visibility.unavailable.identity"),
                "remaining_label": null, "remaining_accessibility_label": null, "deadline": null, "action": null,
            },
            "methods": methods,
            "alert": null,
            "note": null,
            "status": null,
            "people": [],
            "empty": self.empty(
                Some("unavailable"),
                s.text("nearby.empty.unavailable.title"),
                Some(s.text("nearby.empty.unavailable.body.identity")),
            ),
            "footer": self.footer(profile),
        })
    }
}
