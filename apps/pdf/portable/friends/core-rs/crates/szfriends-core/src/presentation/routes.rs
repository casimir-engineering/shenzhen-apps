//! How a friend shows connected (`SZFriendsSnapshotBuilder+Routes.m`): in list rows, the conversation header, details
//! and the words about things still waiting to go. The reader wants to know whether their message can reach the
//! friend now: a live session answers by its route; without one, a helper that reaches friends online also says
//! whether it is trying or tried and failed. A helper without "online" never says anything about online.

use serde_json::{json, Value};

use super::facts::{OnlineReach, PersonFacts, Relation, RouteKind, RouteMethod};
use super::SnapshotBuilder;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ShownRoute {
    /// Nothing to show (a request by ID that never connected).
    None,
    /// A nearby session is up.
    Local,
    /// A session over the Internet is up, direct or through the relay.
    Online,
    /// No session; an online attempt is running.
    Connecting,
    /// No session, and nothing says more.
    Offline,
    /// No session; the last online attempt failed, relay included.
    Unreachable,
}

impl SnapshotBuilder {
    pub(crate) fn shown_route(&self, person: &PersonFacts) -> ShownRoute {
        match person.route_kind {
            RouteKind::Local | RouteKind::Online => {
                // The nearby service reports every live session as its route; one over the Internet is not nearby.
                let internet = matches!(person.route_method, RouteMethod::Internet | RouteMethod::Relay);
                if person.route_kind == RouteKind::Online || internet {
                    return ShownRoute::Online;
                }
                return ShownRoute::Local;
            }
            RouteKind::None => return ShownRoute::None,
            RouteKind::Offline => {}
        }
        // Attempts reach friends only, and never one whose new key waits for review.
        if !self.strings.reaches_online() || person.relation != Relation::Friend || person.key_change_pending {
            return ShownRoute::Offline;
        }
        match person.online_reach {
            OnlineReach::Connecting => ShownRoute::Connecting,
            OnlineReach::Unreachable => ShownRoute::Unreachable,
            OnlineReach::Unknown => ShownRoute::Offline,
        }
    }

    /// PROTOCOL.md type.route for a live session that is not with a friend (one of the person's own computers, a code
    /// being checked): nearby or online by its method; None for none.
    pub(crate) fn route_for_live_method(&self, method: RouteMethod) -> Option<Value> {
        let kind = match method {
            RouteMethod::None => return None,
            RouteMethod::Internet | RouteMethod::Relay => RouteKind::Online,
            _ => RouteKind::Local,
        };
        Some(self.route_for_kind(kind, method))
    }

    pub(crate) fn route_label_for_person(&self, person: &PersonFacts) -> Option<String> {
        let s = &self.strings;
        Some(match self.shown_route(person) {
            ShownRoute::None => return None,
            ShownRoute::Local => s.route_label(RouteKind::Local, person.route_method),
            ShownRoute::Online => s.route_label(RouteKind::Online, person.route_method),
            ShownRoute::Connecting => {
                s.text_with("route.connecting", &[("first", &self.first_name_for_person(person))])
            }
            ShownRoute::Unreachable => s.text("route.unreachable"),
            // "Not nearby" would suggest nearby is the only way once friends are reached online too.
            ShownRoute::Offline => s.text(if s.reaches_online() { "route.offline.online" } else { "route.offline" }),
        })
    }

    /// PROTOCOL.md type.route for this person.
    pub(crate) fn route_for_person(&self, person: &PersonFacts) -> Value {
        match self.shown_route(person) {
            ShownRoute::Local => self.route_for_kind(RouteKind::Local, person.route_method),
            ShownRoute::Online => self.route_for_kind(RouteKind::Online, person.route_method),
            ShownRoute::None => self.route_for_kind(RouteKind::None, person.route_method),
            shown => json!({
                // Connecting draws the globe in the colour of a route not up yet; offline and unreachable the dot.
                "kind": if shown == ShownRoute::Connecting { "connecting" } else { "offline" },
                "method": null,
                "label": self.route_label_for_person(person),
            }),
        }
    }

    pub(crate) fn spoken_route_for_person(&self, person: &PersonFacts) -> Option<String> {
        let label = self.route_label_for_person(person).filter(|l| !l.is_empty())?;
        // "connecting to Mei" inside a longer sentence: the ellipsis would read as a pause in the middle of it.
        let label = label.strip_suffix('…').unwrap_or(&label);
        Some(self.strings.spoken_fragment(label))
    }

    /// The catalog key of something outgoing still waiting to go (`family` "message.status", "preview.status" or
    /// "transfer.status"): ".connecting" while an attempt runs, ".queued_online" when friends are reached online too,
    /// ".queued" otherwise.
    pub(crate) fn waiting_key(&self, family: &str, person: &PersonFacts) -> String {
        let suffix = if self.shown_route(person) == ShownRoute::Connecting {
            "connecting"
        } else if self.strings.reaches_online() {
            "queued_online"
        } else {
            "queued"
        };
        format!("{family}.{suffix}")
    }

    /// The composer's note about when things go, or None while a session is up or being made.
    pub(crate) fn composer_reach_note(&self, person: &PersonFacts) -> Option<String> {
        let s = &self.strings;
        let first = self.first_name_for_person(person);
        match self.shown_route(person) {
            ShownRoute::Local | ShownRoute::Online | ShownRoute::Connecting => None,
            ShownRoute::Unreachable => Some(s.text_with("composer.note.unreachable", &[("first", &first)])),
            ShownRoute::None | ShownRoute::Offline => {
                let key = if s.reaches_online() { "static.queued_note.online" } else { "static.queued_note" };
                Some(s.text_with(key, &[("first", &first), ("apps", &s.text("apps.with_friends"))]))
            }
        }
    }
}
