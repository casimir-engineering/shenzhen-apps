//! Subscriptions and their snapshots (`SZFriendsSubscriptions.m`, PROTOCOL.md § Snapshots): each subscription's view
//! is built for its client's audience, sent when it differs from the last one sent, with its revision counting up.
//! The first snapshot goes before the reply that names the subscription.

use serde_json::{json, Value};
use szfriends_core::presentation::{NearbyFacts, PersonFacts, ProfileFacts, Relation, SnapshotBuilder};
use szfriends_core::store::sync_log::YOU;
use szfriends_core::store::unix_now;

use super::facts::PAGE;
use super::State;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ViewKind {
    Badge,
    List,
    Nearby,
    Details,
    Profile,
    Settings,
    Join,
    Conversation,
    Received,
}

impl ViewKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Badge => "badge",
            Self::List => "list",
            Self::Nearby => "nearby",
            Self::Details => "details",
            Self::Profile => "profile",
            Self::Settings => "settings",
            Self::Join => "join",
            Self::Conversation => "conversation",
            Self::Received => "received",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        [
            Self::Badge,
            Self::List,
            Self::Nearby,
            Self::Details,
            Self::Profile,
            Self::Settings,
            Self::Join,
            Self::Conversation,
            Self::Received,
        ]
        .into_iter()
        .find(|v| v.name() == name)
    }
}

#[derive(Clone, Debug)]
pub struct Subscription {
    pub view: ViewKind,
    pub conversation_id: Option<String>,
    pub query: String,
    /// How many history items a conversation shows (Show earlier messages adds a page).
    pub limit: usize,
    pub highlight: Option<String>,
    pub rev: u64,
    pub last: Option<Value>,
}

impl Subscription {
    pub fn new(view: ViewKind, conversation_id: Option<String>) -> Self {
        Self { view, conversation_id, query: String::new(), limit: PAGE, highlight: None, rev: 0, last: None }
    }
}

/// Everything one round of views reads, gathered once.
pub struct World {
    /// Everyone a person row may show. The You conversation is never one of them: it shows only as the devices You
    /// row, and without devices facts not at all; its conversation still opens (`you`).
    pub people: Vec<PersonFacts>,
    pub you: Option<PersonFacts>,
    pub profile: ProfileFacts,
    pub now: f64,
    /// With the helper capability `devices`: the profile's computers and the join rows.
    pub devices: Option<szfriends_core::presentation::DevicesFacts>,
    pub join_requests: Vec<szfriends_core::presentation::JoinRequestFacts>,
}

impl State {
    pub fn world(&mut self) -> World {
        let (people, profile, now) = (self.people_facts(), self.profile_facts(), unix_now());
        #[cfg(feature = "online")]
        let profile = {
            let links = self.links_facts(&profile, now);
            szfriends_core::presentation::ProfileFacts { links, ..profile }
        };
        let devices = Some(self.devices_facts(now, &people));
        let join_requests = self.join_request_facts(now);
        let (you, people): (Vec<PersonFacts>, Vec<PersonFacts>) =
            people.into_iter().partition(|p| p.conversation_id == YOU);
        World { people, you: you.into_iter().next(), profile, now, devices, join_requests }
    }

    /// Rows waiting for an answer other than `conversation_id`'s.
    fn waiting_elsewhere(world: &World, conversation_id: Option<&str>) -> i64 {
        world
            .people
            .iter()
            .filter(|p| Some(p.conversation_id.as_str()) != conversation_id)
            .filter(|p| !p.left_list) // off the list: nothing of theirs waits in it
            .filter(|p| p.relation == Relation::IncomingRequest || p.offers_waiting > 0)
            .count() as i64
    }

    fn nearby_facts(&self) -> NearbyFacts {
        self.nearby_view_facts()
    }

    /// One subscription's data now, or None when what it shows is gone (a conversation whose person was removed
    /// from the store).
    pub fn render(&self, builder: &SnapshotBuilder, subscription: &Subscription, world: &World) -> Option<Value> {
        let person = || {
            let id = subscription.conversation_id.as_deref()?;
            world.people.iter().chain(&world.you).find(|p| p.conversation_id == id)
        };
        let elsewhere = Self::waiting_elsewhere(world, subscription.conversation_id.as_deref());
        Some(match subscription.view {
            ViewKind::Badge => builder.badge(&world.people, world.join_requests.len()),
            ViewKind::List => {
                let previews = self.preview_items(&world.people);
                let mut list = builder.list(&world.people, &previews, &world.profile, &subscription.query, world.now);
                if world.devices.is_some() {
                    list["join_requests"] = builder.join_request_rows(&world.join_requests, world.now);
                }
                builder.list_with_devices(list, &world.people, &subscription.query, world.now)
            }
            ViewKind::Nearby => builder.nearby(&self.nearby_facts(), &world.profile, &subscription.query, world.now),
            ViewKind::Details => builder.details(person()?, elsewhere, world.now),
            ViewKind::Profile => builder.profile(&world.profile, elsewhere),
            ViewKind::Settings => builder.settings(&world.profile, &world.people),
            ViewKind::Join => builder.join(&self.joining_facts()),
            ViewKind::Received => builder.received(&self.store.received_files()),
            ViewKind::Conversation => {
                let person = person()?;
                let (items, earlier) = self.conversation_items(&person.conversation_id, subscription.limit);
                let highlight = subscription.highlight.as_deref();
                builder.conversation(person, &items, earlier, highlight, elsewhere, world.now)
            }
        })
    }

    /// Sends `subscription`'s snapshot when it changed; returns whether one was sent.
    pub fn refresh(&mut self, client_id: u64, subscription_id: &str, world: &World) -> bool {
        let Some(client) = self.clients.get(&client_id) else { return false };
        let Some(subscription) = client.subscriptions.get(subscription_id) else { return false };
        let mut builder = SnapshotBuilder::new(client.audience.clone(), None);
        builder.devices = world.devices.clone();
        let Some(data) = self.render(&builder, subscription, world) else { return false };
        if subscription.last.as_ref() == Some(&data) {
            return false;
        }
        let client = self.clients.get_mut(&client_id).expect("looked up above");
        let subscription = client.subscriptions.get_mut(subscription_id).expect("looked up above");
        subscription.rev += 1;
        let frame = json!({"type": "snapshot", "subscription": subscription_id, "view": subscription.view.name(),
                           "rev": subscription.rev, "data": data});
        subscription.last = Some(data);
        client.connection.send(&frame)
    }

    /// Brings every subscription up to date.
    pub fn update_views(&mut self) {
        if self.clients.is_empty() {
            return;
        }
        let world = self.world();
        let all: Vec<(u64, String)> = self
            .clients
            .iter()
            .flat_map(|(id, client)| client.subscriptions.keys().map(move |s| (*id, s.clone())))
            .collect();
        for (client, subscription) in all {
            self.refresh(client, &subscription, &world);
        }
    }

    /// A new subscription for a client; its first snapshot is sent before the caller replies.
    pub fn subscribe(&mut self, client_id: u64, subscription: Subscription) -> Option<String> {
        self.next_subscription += 1;
        let id = format!("s_{}", self.next_subscription);
        let client = self.clients.get_mut(&client_id)?;
        client.subscriptions.insert(id.clone(), subscription);
        let world = self.world();
        self.refresh(client_id, &id, &world);
        Some(id)
    }
}
