//! Friends reached over the Internet (`SZFriendsNearbyService+Online.m`): the service gives `szfriends-online` the
//! friends and our other devices it may reach and the routes outside it, asks it for a session with every one who
//! has something waiting, and makes each stream it opens a session exactly like a nearby one: IK initiator on the
//! side that offered, the friends-only responder on the other. The session race keeps the best route in the owner's
//! order (direct on the same network, peer to peer, Bluetooth, the relay): online is asked to reach a friend only
//! while the session carrying them ranks after a direct Internet connection, and the driver ends its attempt once a
//! better route carries them.
//!
//! What starts it: a person's own home checks in with the bundled signed list over `wss://`, as the Mac helper does. A
//! test home (`$SZFRIENDS_STATE_DIR`) never does: it goes online only when `$SZFRIENDS_TEST_HOST_LIST` and
//! `$SZFRIENDS_TEST_HOST_KEYS` name a signed list of loopback hosts, as the Mac helper's tests give theirs, with
//! `$SZFRIENDS_TEST_HOST_CA` naming the CA a `wss://` test host's certificate chains to.

use std::collections::HashMap;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use szfriends_core::identity::Identity;
use szfriends_core::nearby::is_better;
use szfriends_core::session::{ChannelIdentity, HandshakeOptions, SecureChannel};
use szfriends_core::store::{devices, unix_now, Relation, Store};
use szfriends_core::wire::{Pattern, RouteMethod};
use szfriends_online::byid::IdEvent;
use szfriends_online::driver::{Friends, OnlineFriend};
use szfriends_online::host::list::{bundled, pinned_keys, HostList};
use szfriends_online::{Online, OnlineConfig, OnlineEvent};

#[path = "online_attestation.rs"]
mod attestation;
#[path = "online_people.rs"]
mod people;
#[path = "online_release.rs"]
mod release;
use people::{friends, membership, Person};

use super::devices::REMOVED_BY_HOST;
use super::nearby::{LinkMeta, Purpose};
use super::{Input, State};
use crate::log;
use crate::nearby::stream::LinkStream;
use crate::state::ENV_STATE_DIR;

pub const ENV_TEST_HOST_LIST: &str = "SZFRIENDS_TEST_HOST_LIST";
pub const ENV_TEST_HOST_KEYS: &str = "SZFRIENDS_TEST_HOST_KEYS";
pub const ENV_TEST_HOST_CA: &str = "SZFRIENDS_TEST_HOST_CA";
/// Tests: while this file exists in the state directory, no direct candidate is sent or applied.
pub const BLOCK_DIRECT_FILE: &str = "online-block-direct";

/// What the online thread may ask about friends, kept up to date by the service's thread.
#[derive(Debug, Default)]
pub struct Directory {
    friends: HashMap<[u8; 32], OnlineFriend>,
    routes: HashMap<[u8; 32], RouteMethod>,
    own_secret: Option<[u8; 32]>,
    membership: Option<Person>,
    /// The ID from before joining a profile is still to be released (`devices::PRE_JOIN_RELEASE`).
    pub(super) release_owed: bool,
}

#[derive(Debug)]
struct Shared(Arc<Mutex<Directory>>, Arc<Mutex<super::nearby::policy::PolicyView>>);

impl Friends for Shared {
    fn friend(&self, key: &[u8; 32]) -> Option<OnlineFriend> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).friends.get(key).cloned()
    }

    fn nearby_route(&self, key: &[u8; 32]) -> RouteMethod {
        let directory = self.0.lock().unwrap_or_else(|e| e.into_inner());
        directory.routes.get(key).copied().unwrap_or(RouteMethod::None)
    }

    fn own_presence_secret(&self) -> Option<[u8; 32]> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).own_secret
    }

    fn answering(&self, key: &[u8; 32], token: &[u8]) -> Option<OnlineFriend> {
        let admitted = self.1.lock().unwrap_or_else(|e| e.into_inner()).admits(token, key, false, unix_now());
        admitted.then(|| OnlineFriend {
            identity_key: *key,
            static_key: [0; 32],
            presence_secret: None,
            request_token: <[u8; 16]>::try_from(token).ok(),
            root_key: None,
        })
    }
}

#[derive(Debug)]
pub struct OnlineRoutes {
    online: Online,
    pub(super) directory: Arc<Mutex<Directory>>,
    available: bool,
    /// The web origin download links name (the signed list's `links`, else the main host's own).
    link_origin: Option<String>,
    /// Where receive_link opens a link as a guest: the first rendezvous host of the list.
    guest: Option<super::link_open::GuestHost>,
    /// The signed list as the host connection has it now: Add by ID answers' attestations are checked against it.
    pub(crate) list: HostList,
}

impl OnlineRoutes {
    /// Online: the bundled list in a person's own home; in a test home, only a test list of loopback hosts.
    pub fn from_environment(
        identity: &Identity,
        store: &mut Store,
        input: Sender<Input>,
        links: Box<dyn szfriends_online::links::LinkFiles>,
        policy: Arc<Mutex<super::nearby::policy::PolicyView>>,
    ) -> Option<Self> {
        let test_home = std::env::var_os(ENV_STATE_DIR).is_some();
        // A computer another of the person's computers removed never checks in again (the host would refuse it).
        let by_host = szfriends_core::store::sync_log::state(store.connection(), REMOVED_BY_HOST);
        if devices::is_revoked_device(store.connection(), &identity.public_key()).unwrap_or(false)
            || by_host.is_ok_and(|v| v == rusqlite::types::Value::Integer(1))
        {
            return None;
        }
        let (list, pinned, host_roots) = if test_home {
            let list = std::fs::read(std::env::var_os(ENV_TEST_HOST_LIST)?).ok()?;
            let (pinned, _) = pinned_keys(&std::fs::read(std::env::var_os(ENV_TEST_HOST_KEYS)?).ok()?)?;
            let Some(list) = HostList::from_signed(&list, &pinned).filter(HostList::is_loopback_only) else {
                log!("online: the test host list does not verify or names a host that is not loopback");
                return None;
            };
            let roots = std::env::var_os(ENV_TEST_HOST_CA).and_then(|path| std::fs::read(path).ok());
            (list, pinned, roots)
        } else {
            let (list, keys) = bundled();
            let (pinned, _) = pinned_keys(keys)?;
            (HostList::from_signed(list, &pinned)?, pinned, None)
        };
        let directory = Arc::new(Mutex::new(Directory {
            friends: friends(store),
            routes: HashMap::new(),
            own_secret: store.ensure_own_presence_secret().ok(),
            membership: membership(store, &identity.public_key()),
            release_owed: super::devices::release_owed(store.connection()),
        }));
        let owed = directory.clone();
        let person = directory.clone();
        let block = store.state_dir().join(BLOCK_DIRECT_FILE);
        let words = szfriends_identity::friends_id::WordList::bundled();
        let link_origin = list.link_origin();
        let host_list = list.clone();
        let guest =
            list.entries.iter().find(|e| e.rendezvous && !e.urls.is_empty()).map(|entry| super::link_open::GuestHost {
                url: entry.urls[0].clone(),
                stun: entry.turn_uris.iter().filter(|u| u.starts_with("stun:")).cloned().collect(),
                roots: host_roots.clone(),
                loopback: test_home,
            });
        // The ID this profile shows is the one asked for first; a collision draws another.
        let shown: Option<String> = store
            .connection()
            .query_row("SELECT friends_id FROM profile WHERE id = 1", [], |r| r.get(0))
            .ok()
            .flatten();
        let config = OnlineConfig {
            identity: Arc::new(Identity::from_secret_item(&identity.secret_item()).ok()?),
            app_version: crate::stamp::own().version,
            list,
            pinned,
            loopback_only: test_home,
            direct_blocked: test_home
                .then(|| -> szfriends_online::driver::DirectBlocked { Arc::new(move || block.exists()) }),
            friends: Box::new(Shared(directory.clone(), policy)),
            id_provider: Box::new(move |collisions| {
                if let Some(shown) = shown.clone().filter(|_| collisions == 0) {
                    return shown;
                }
                let count = szfriends_identity::friends_id::word_count_for_new_id(2, u64::from(collisions));
                words.map_or_else(String::new, |w| w.random_id(count, szfriends_identity::friends_id::system_uniform))
            }),
            technique_log: Some(store.state_dir().join("online-techniques.json")),
            links: Some(links),
            host_roots,
            membership: Some(Arc::new(move || person.lock().unwrap_or_else(|e| e.into_inner()).membership.clone())),
            release_owed: Some(Arc::new(move || owed.lock().unwrap_or_else(|e| e.into_inner()).release_owed)),
        };
        let (online, events) = Online::start(config);
        std::thread::Builder::new()
            .name("szfriends-online-events".into())
            .spawn(move || {
                for event in events {
                    if input.send(Input::Online(event)).is_err() {
                        return;
                    }
                }
            })
            .ok()?;
        log!("online: checking in with {}", if test_home { "the test host" } else { "the Friends host" });
        Some(Self { online, directory, available: false, link_origin, guest, list: host_list })
    }

    /// The friends and our other devices, the routes outside online, and every one with something waiting.
    pub fn refresh(
        &mut self,
        store: &Store,
        own_devices: Vec<OnlineFriend>,
        routes: HashMap<[u8; 32], RouteMethod>,
        wanted: &[[u8; 32]],
    ) {
        {
            let mut directory = self.directory.lock().unwrap_or_else(|e| e.into_inner());
            directory.friends = friends(store);
            directory.friends.extend(own_devices.into_iter().map(|d| (d.identity_key, d)));
            directory.routes = routes;
            // A computer that joined a profile seals its records under the profile's secret from then on.
            directory.own_secret = store.own_presence_secret().or(directory.own_secret);
        }
        self.online.nearby_routes_changed();
        if self.available {
            for key in wanted {
                self.online.reach(*key);
            }
        }
    }

    pub fn network_changed(&self) {
        self.online.network_changed();
    }

    /// The profile's chain as the store holds it now: a change checks in again for the person.
    fn set_membership(&self, store: &Store, me: &[u8; 32]) {
        let now = membership(store, me);
        let mut directory = self.directory.lock().unwrap_or_else(|e| e.into_inner());
        // Before a new check-in asks: a computer that just joined releases its own ID first.
        directory.release_owed = super::devices::release_owed(store.connection());
        if directory.membership != now {
            directory.membership = now;
            drop(directory);
            self.online.membership_changed();
        }
    }

    pub fn is_available(&self) -> bool {
        self.available
    }

    pub fn link_origin(&self) -> Option<String> {
        self.link_origin.clone()
    }

    pub fn guest_host(&self) -> Option<super::link_open::GuestHost> {
        self.guest.clone()
    }

    /// Every live link (and every tombstone) to the host again.
    pub fn register_links(&self) {
        self.online.links(|links, host| links.register_all(host));
    }

    /// A revoked link: its tombstone, then its binding let go.
    pub fn end_link(&self, link_id: [u8; 16], tombstones: Vec<szfriends_online::links::Tombstone>) {
        self.online.links(move |_, host| {
            host.send_link_tombstones(&tombstones);
            host.unregister_link(&link_id);
        });
    }

    pub fn join_request(&self, friends_id: &str, message: Vec<u8>) {
        self.online.join_request(friends_id, message);
    }

    pub fn join_code(&self, pipe: u64, friends_id: &str) {
        self.online.join_code(pipe, friends_id);
    }

    pub fn join_send(&self, pipe: u64, messages: Vec<Vec<u8>>) {
        self.online.join_send(pipe, messages);
    }

    pub fn join_close(&self, pipe: u64, linger: f64) {
        self.online.join_close(pipe, linger);
    }

    /// Whether this device holds an approval, so answers a new computer's code through the host.
    pub fn set_holds_approval(&self, holds: bool) {
        self.online.holds_approval.store(holds, std::sync::atomic::Ordering::SeqCst);
    }

    pub fn send_tombstones(&self, tombstones: Vec<szfriends_online::links::Tombstone>) {
        self.online.links(move |_, host| host.send_link_tombstones(&tombstones));
    }
}

/// The online responder's admission: IK from exactly the friend (or other device of ours) the signalling named, and
/// nobody else, so a stream set up for one friend never carries another's session.
fn signalled_only(friend: [u8; 32]) -> impl Fn(Option<&[u8; 32]>, Pattern, Option<&[u8]>) -> bool + Send + 'static {
    move |key, pattern, _token| pattern == Pattern::IK && key == Some(&friend)
}

impl State {
    /// Asks the driver for a session with every friend who has something waiting (a message, a file, an answer) or
    /// something on its way to us and no session on a route better than a direct Internet connection, telling it
    /// first which routes outside it carry a session now.
    pub(crate) fn reach_online(&mut self) {
        if self.online.is_none() {
            return;
        }
        let mut routes: HashMap<[u8; 32], RouteMethod> = HashMap::new();
        let carrying = self
            .sessions
            .map
            .values()
            .filter(|s| s.meta.live && !s.meta.superseded && s.channel.is_established() && !s.channel.is_closed());
        for session in carrying {
            let route = session.channel.initiator_route();
            let ours = matches!(route, RouteMethod::Internet | RouteMethod::Relay);
            if let (Some(key), false) = (session.channel.remote_identity(), ours) {
                let best = routes.entry(*key).or_insert(RouteMethod::None);
                if *best == RouteMethod::None || is_better(route, *best) {
                    *best = route;
                }
            }
        }
        let people = self.store.people_by_latest_interaction().unwrap_or_default();
        let mut wanted: Vec<[u8; 32]> = Vec::new();
        let waiting = people
            .iter()
            .filter(|p| p.relation == Relation::Friend)
            .filter(|p| {
                let live = self.sessions.live_for(&p.conversation_id);
                live.is_none_or(|id| is_better(RouteMethod::Internet, self.sessions.map[&id].channel.initiator_route()))
            })
            .filter(|p| {
                self.has_deliverable(p)
                    || !self.store.unfinished_incoming_transfers(&p.conversation_id).unwrap_or_default().is_empty()
            });
        for person in waiting {
            wanted.extend(person.identity_key);
            // Each of their other computers too: whichever one is online answers (nearby/friend_devices.rs).
            wanted.extend(self.friend_other_devices(person).iter().map(|d| d.device_key));
        }
        // Our other devices with no session better than a direct Internet connection (nearby/own.rs).
        wanted.extend(self.own_devices_to_reach_online());
        let own_devices = self.own_devices_online();
        let me = self.identity.public_key();
        if let Some(online) = self.online.as_mut() {
            online.set_membership(&self.store, &me);
            online.refresh(&self.store, own_devices, routes, &wanted);
        }
    }

    /// Add by ID online: our pending request `token` to whoever holds its Friends ID, signed over that NN session.
    pub(crate) fn request_by_id_online(&mut self, token: &[u8; 16]) {
        let Some(online) = self.online.as_ref().filter(|o| o.available) else { return };
        let now = unix_now();
        let Some(request) = self.store.pending_id_requests(now).into_iter().find(|r| &r.request_token == token) else {
            return;
        };
        let day = szfriends_core::nearby::callbacks::callback_day(request.created_at, now);
        let Some(secret) = szfriends_core::nearby::callbacks::callback_secret_for_day(&request.callback_secret, day)
        else {
            return;
        };
        let Ok(identity) = Identity::from_secret_item(&self.identity.secret_item()) else { return };
        let (target, token) = (request.target_friends_id.clone(), *token);
        let invite = self.store.invite_token_for_id_request(&request.conversation_id);
        let frame = Box::new(move |h: &[u8]| {
            let mut frame = szfriends_identity::request_by_id::make_frame(&identity, &target, &token, &secret, h)?;
            // From a friend link: its invite, bound to this session (friend_links.rs).
            if let Some(proof) = invite.and_then(|invite| szfriends_core::crypto::invite::invite_proof(&invite, h)) {
                frame = frame.with(szfriends_core::wire::tag::INVITE_PROOF, proof.to_vec());
            }
            frame.encode().ok()
        });
        let number = u64::from_be_bytes(token[..8].try_into().expect("8 bytes"));
        online.online.request_by_id(number, &request.target_friends_id, frame);
    }

    /// What the online thread reported.
    pub(crate) fn online_event(&mut self, event: OnlineEvent) {
        match event {
            OnlineEvent::Available(available) => {
                if let Some(online) = self.online.as_mut() {
                    online.available = available;
                }
                if available {
                    self.reach_online();
                }
            }
            OnlineEvent::Stream { friend, stream, route, initiator } => {
                self.online_stream(friend, stream, route, initiator)
            }
            OnlineEvent::Reserved(id, attestation) => self.friends_id_reserved(&id, attestation),
            OnlineEvent::PreJoinReleased(released) => self.pre_join_released(released),
            OnlineEvent::HostList(list) => {
                if let Some(online) = self.online.as_mut() {
                    online.list = list;
                }
            }
            OnlineEvent::Link(szfriends_online::links::LinkEvent::Downloaded(id)) => self.link_downloaded(&id),
            OnlineEvent::Join(event) => self.join_event(event),
            OnlineEvent::Removed => {
                // The host knew first: the chain carrying the removal reaches this computer later, or never.
                log!("online: the host says this computer was removed from its profile");
                let conn = self.store.connection();
                let _ = szfriends_core::store::sync_log::set_state(conn, REMOVED_BY_HOST, true.into());
                self.own_devices_changed();
            }
            OnlineEvent::ById(IdEvent::Request { frame, handshake_hash }) => {
                if let Ok(frame) = szfriends_core::wire::Frame::decode(&frame) {
                    self.received_request_by_id(&frame, &handshake_hash);
                }
            }
            OnlineEvent::ById(IdEvent::Sent { received, .. }) => {
                log!("online: an Add by ID request {}", if received { "reached its holder" } else { "found nobody" });
            }
            OnlineEvent::AttemptEnded { .. } | OnlineEvent::ReachChanged(_) | OnlineEvent::Link(_) => {}
        }
    }

    /// A data channel to a friend: a session like a nearby one, which the session race then weighs against the rest.
    fn online_stream(
        &mut self,
        friend: [u8; 32],
        stream: szfriends_online::transport::ChannelStream,
        route: szfriends_online::transport::Route,
        initiator: bool,
    ) {
        let known = self.online.as_ref().map(|o| o.directory.lock().unwrap_or_else(|e| e.into_inner()).friends.clone());
        let known = known.and_then(|f| f.get(&friend).cloned());
        let channel = match (initiator, known) {
            (true, Some(known)) => {
                let mut options = HandshakeOptions::new(Pattern::IK, route.method());
                options.remote_static = Some(known.static_key);
                options.expected_identity = Some(friend);
                // Our acceptance of their Add by ID has not reached them yet: their token says who we are.
                options.request_token = known.request_token.map(|t| t.to_vec());
                let answering = options.request_token.is_some();
                let mut channel = SecureChannel::initiator(ChannelIdentity::new(&self.identity), options);
                if answering {
                    // The host's word that we hold the ID they asked for, beside our certificate.
                    channel.set_local_attestation(self.attestation_for_our_answer());
                }
                channel
            }
            (false, Some(_)) => {
                SecureChannel::responder(ChannelIdentity::new(&self.identity), None, Box::new(signalled_only(friend)))
            }
            (false, None) => {
                // Someone we asked by ID, calling back with our token: that key, and the nearby policy's admission.
                let view = self.nearby.policy.clone();
                let policy = Box::new(move |key: Option<&[u8; 32]>, pattern: Pattern, token: Option<&[u8]>| {
                    let admitted = token.is_some_and(|t| {
                        key.is_some_and(|k| {
                            view.lock().unwrap_or_else(|e| e.into_inner()).admits(t, k, false, unix_now())
                        })
                    });
                    pattern == Pattern::IK && key == Some(&friend) && admitted
                });
                SecureChannel::responder(ChannelIdentity::new(&self.identity), None, policy)
            }
            (true, None) => return stream.writer.close(),
        };
        let own = self.is_own_device(&friend);
        let meta = LinkMeta {
            purpose: match (initiator, own) {
                (true, true) => Purpose::OwnDevice,
                (true, false) => Purpose::Friend,
                (false, _) => Purpose::Incoming,
            },
            dialed_route: route.method(),
            created_at: unix_now(),
            ..LinkMeta::default()
        };
        let conversation = self.store.person_with_identity_key(&friend).ok().flatten().map(|p| p.conversation_id);
        let id = self.reserve_session_id();
        if self.adopt_session_id(id, channel, LinkStream::Online(stream), meta).is_some() && initiator {
            if let Some(session) = self.sessions.map.get_mut(&id) {
                session.conversation = conversation;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_responder_admits_only_the_signalled_friend() {
        let policy = signalled_only([1; 32]);
        assert!(policy(Some(&[1; 32]), Pattern::IK, None));
        assert!(!policy(Some(&[2; 32]), Pattern::IK, None), "another friend, on a stream set up for the first");
        assert!(!policy(Some(&[1; 32]), Pattern::XX, None), "IK only");
        assert!(!policy(None, Pattern::NN, None));
    }
}
