//! What Nearby shows (`SZFriendsNearbyService+Facts.m`): people from the merger's identified candidates (friends
//! matched by tag, strangers whose public entry told us who they are), each method's state, the visibility deadline,
//! and whether this computer accepts connections nearby.

use szfriends_core::nearby::visibility::Instant;
use szfriends_core::nearby::Method;
use szfriends_core::presentation::{NearbyFacts, NearbyPersonFacts, Picture, RouteMethod as ViewRoute};
use szfriends_core::store::Relation;
use szfriends_core::wire::{tag, RouteMethod};

use super::inbound::clean_name;
use crate::service::State;

/// A stranger behind a Nearby row, as send_request takes them.
#[derive(Clone, Debug)]
pub struct Stranger {
    pub identity_key: [u8; 32],
    pub static_key: Option<[u8; 32]>,
    pub name: Option<String>,
    pub friends_id: Option<String>,
}

fn view_route(route: RouteMethod) -> ViewRoute {
    match route {
        RouteMethod::Lan => ViewRoute::Lan,
        RouteMethod::PeerToPeerWifi => ViewRoute::PeerToPeerWifi,
        RouteMethod::Bluetooth => ViewRoute::Bluetooth,
        RouteMethod::Internet => ViewRoute::Internet,
        RouteMethod::Relay => ViewRoute::Relay,
        RouteMethod::None => ViewRoute::None,
    }
}

impl State {
    /// What a public entry said about this key: its cleaned name and Friends ID.
    fn described(&self, key: &[u8; 32]) -> (Option<String>, Option<String>, Option<[u8; 32]>) {
        let Some((fields, static_key)) = self.nearby.public_profiles.get(key) else { return (None, None, None) };
        let name = clean_name(fields.get(&tag::NAME).map(Vec::as_slice));
        let typed = fields.get(&tag::FRIENDS_ID).and_then(|b| std::str::from_utf8(b).ok());
        let list = szfriends_identity::friends_id::WordList::bundled();
        let friends_id = typed.and_then(|t| list.and_then(|l| l.normalized_id(t)));
        (name, friends_id, *static_key)
    }

    /// send_request: the stranger behind a Nearby row, or `None` when the row is gone or was never a stranger.
    pub(crate) fn stranger(&self, nearby_id: &str) -> Option<Stranger> {
        let candidate = self.nearby.merger.candidate(nearby_id)?;
        let key = candidate.identity_key.filter(|_| candidate.identified())?;
        let (name, friends_id, static_key) = self.described(&key);
        Some(Stranger { identity_key: key, static_key, name, friends_id })
    }

    /// Nearby's people, one per person; blocked people never appear.
    pub(crate) fn nearby_people(&self) -> Vec<NearbyPersonFacts> {
        let mut people = Vec::new();
        for candidate in self.nearby.merger.identified() {
            let person = match (&candidate.conversation_id, candidate.identity_key) {
                (Some(conversation), _) => self.store.person_with_conversation(conversation).ok().flatten(),
                (None, Some(key)) => self.store.person_with_identity_key(&key).ok().flatten(),
                _ => None,
            };
            if person.as_ref().is_some_and(|p| p.relation == Relation::Blocked) {
                continue;
            }
            let route_method = view_route(candidate.sightings.first().map_or(RouteMethod::None, |s| s.route));
            match person.filter(|p| p.relation != Relation::Removed) {
                Some(person) => people.push(NearbyPersonFacts {
                    nearby_id: None,
                    conversation_id: Some(person.conversation_id.clone()),
                    name: person.name.clone(),
                    friends_id: person.friends_id.clone(),
                    picture: Picture::Placeholder,
                    relation: person.relation,
                    is_stranger: person.relation != Relation::Friend,
                    route_method,
                }),
                None => {
                    // Someone visible for their 5 minutes, described by what their entry served; a removed person
                    // looks the same: either side may ask again.
                    let Some(key) = candidate.identity_key else { continue };
                    let (name, friends_id, _) = self.described(&key);
                    people.push(NearbyPersonFacts {
                        nearby_id: Some(candidate.id.clone()),
                        conversation_id: None,
                        name,
                        friends_id,
                        picture: Picture::Placeholder,
                        relation: Relation::Removed,
                        is_stranger: true,
                        route_method,
                    });
                }
            }
        }
        people
    }

    /// The Nearby view's facts now.
    pub(crate) fn nearby_view_facts(&self) -> NearbyFacts {
        let network = self.nearby.state_of(Method::Network);
        let bluetooth = self.nearby.state_of(Method::Bluetooth);
        // The service's tick clears a deadline as soon as it passes; this only reads it.
        let visible = self.nearby.visibility.deadline().filter(|d| *d > Instant::now().wall);
        NearbyFacts {
            visibility_deadline: visible,
            network_state: network,
            bluetooth_state: bluetooth,
            searching: [network, bluetooth].contains(&szfriends_core::nearby::AdapterState::Working),
            working_since: self.nearby.working_since(),
            people: self.nearby_people(),
            inbound_blocked: !self.nearby.listening(),
            bluetooth_absent: !self.nearby.has_adapter(Method::Bluetooth),
            phone: cfg!(any(target_os = "android", target_os = "ios")),
        }
    }

    /// The route of the session carrying this conversation, for every view's route icon.
    pub(crate) fn live_route(&self, conversation: &str) -> Option<RouteMethod> {
        let id = self.sessions.live_for(conversation)?;
        Some(self.sessions.map[&id].channel.initiator_route())
    }

    pub(crate) fn view_route(route: RouteMethod) -> ViewRoute {
        view_route(route)
    }
}
