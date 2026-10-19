//! Who may open a session to us (`SZFriendsNearbyService+KeyPolicy.m`; ADR 0004 § Hidden listeners, § Public
//! visibility, Review amendments, 8, 9 and 12), and what a listener lets in before that (`SZFriendsAdmission.m`).
//!
//! The channel asks its key policy in the middle of reading bytes, before any reply, when nothing else may be borrowed;
//! so the policy reads a view of the store the service keeps current ([`PolicyView`], rebuilt whenever people or
//! requests change) and writes nothing but which sessions it admitted as strangers. Everyone admitted by IK who is not
//! a friend could find our device in every presence window by probing, so every such case is bounded in time.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use szfriends_core::nearby::admission::Admission;
use szfriends_core::nearby::limits::{INCOMING_REQUEST_IK_WINDOW_SECONDS, STRANGER_SESSIONS_MAX};
use szfriends_core::session::{ListenerHooks, RemoteKeyPolicy};
use szfriends_core::store::requests::OUTGOING_REQUEST_LIFETIME_SECONDS;
use szfriends_core::store::{unix_now, Relation, Store, ID_REQUEST_MAX_ANSWERS, ID_REQUEST_MAX_UNATTESTED_ANSWERS};
use szfriends_core::wire::Pattern;

/// What the policy knows of one person.
#[derive(Clone, Debug)]
pub struct PersonView {
    pub relation: Relation,
    pub found_nearby: bool,
    pub request_since: Option<f64>,
    pub friends_id: Option<String>,
}

/// One unexpired Add by ID request of ours.
#[derive(Clone, Debug)]
pub struct RequestView {
    pub expires_at: f64,
    pub target: String,
    /// Keys that answered, with whether a host attested them.
    pub answers: Vec<([u8; 32], bool)>,
    /// An Add from a mention or a friend link: the only key that may answer it.
    pub bound: Option<[u8; 32]>,
}

/// The store as the policy reads it, and what it marked.
#[derive(Clone, Debug, Default)]
pub struct PolicyView {
    pub own_key: [u8; 32],
    pub closed: bool,
    pub people: HashMap<[u8; 32], PersonView>,
    pub requests: HashMap<[u8; 16], RequestView>,
    /// Sessions admitted as strangers, counted against the cap; the service keeps it current.
    pub strangers: HashSet<u64>,
    /// The cap was full when a newcomer arrived: the service closes the idlest stranger session.
    pub make_room: bool,
    /// Our other devices, which our chain authorizes: IK only, to sync.
    pub own_devices: HashSet<[u8; 32]>,
    /// Every device a kept chain removed, and those of ours: one of ours finishes IK only to be told so.
    pub revoked: HashSet<[u8; 32]>,
    pub own_removed: HashSet<[u8; 32]>,
}

impl PolicyView {
    /// From the store, now.
    pub fn read(store: &Store, own_key: [u8; 32]) -> Self {
        let now = unix_now();
        let mut view = Self { own_key, ..Self::default() };
        for person in store.people_by_latest_interaction().unwrap_or_default() {
            let Some(key) = person.identity_key else { continue };
            view.people.insert(
                key,
                PersonView {
                    relation: person.relation,
                    found_nearby: person.request_found_nearby,
                    request_since: person.request_since.or(person.request_at),
                    friends_id: person.friends_id.clone(),
                },
            );
        }
        if let Ok(mut statement) = store.connection().prepare("SELECT device_pk FROM chain_devices WHERE state = 2") {
            let keys = statement.query_map([], |r| r.get::<_, Vec<u8>>(0));
            view.revoked = keys.into_iter().flatten().flatten().filter_map(|k| k.try_into().ok()).collect();
        }
        let rows = store.connection().prepare(
            "SELECT r.request_token, r.expires_at, r.target_friends_id, a.identity_pk, a.attested, r.callback_secret, \
             f.identity_pk FROM id_requests r LEFT JOIN id_request_answers a ON a.request_token = r.request_token \
             LEFT JOIN friends f ON f.conversation_id = r.conversation_id WHERE r.expires_at > ?1",
        );
        if let Ok(mut statement) = rows {
            let mapped = statement.query_map([now], |r| {
                Ok((
                    r.get::<_, Vec<u8>>(0)?,
                    r.get::<_, f64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<Vec<u8>>>(3)?,
                    r.get::<_, Option<bool>>(4)?,
                    r.get::<_, Vec<u8>>(5)?,
                    r.get::<_, Option<Vec<u8>>>(6)?,
                ))
            });
            for (token, expires_at, target, key, attested, secret, row_key) in mapped.into_iter().flatten().flatten() {
                let Ok(token) = <[u8; 16]>::try_from(token) else { continue };
                // The token hashes the row's key under the request's secret: bound to that key (a random token, as
                // add_by_id draws, matches with negligible probability).
                let row_key = row_key.and_then(|k| <[u8; 32]>::try_from(k).ok());
                let secret = <[u8; 32]>::try_from(secret).ok();
                let bound = row_key.filter(|k| {
                    secret.is_some_and(|s| crate::service::friend_links::mention_request_token(&s, k) == token)
                });
                let entry = view.requests.entry(token).or_insert(RequestView {
                    expires_at,
                    target,
                    answers: Vec::new(),
                    bound,
                });
                if let Some(key) = key.and_then(|k| <[u8; 32]>::try_from(k).ok()) {
                    entry.answers.push((key, attested.unwrap_or(false)));
                }
            }
        }
        view
    }

    fn blocked(&self, key: &[u8; 32]) -> bool {
        self.people.get(key).is_some_and(|p| p.relation == Relation::Blocked)
    }

    /// `id_request_admits` over the view: the token names an unexpired request, the key is not blocked, and it
    /// answered already or a slot is free for it (the last one only for an attested answer).
    pub fn admits(&self, token: &[u8], key: &[u8; 32], attested: bool, now: f64) -> bool {
        let Some(request) = <[u8; 16]>::try_from(token).ok().and_then(|t| self.requests.get(&t)) else {
            return false;
        };
        if request.expires_at <= now || self.blocked(key) || request.bound.is_some_and(|bound| bound != *key) {
            return false;
        }
        if request.answers.iter().any(|(k, _)| k == key) {
            return true;
        }
        let unattested = request.answers.iter().filter(|(_, a)| !a).count();
        request.answers.len() < ID_REQUEST_MAX_ANSWERS && (attested || unattested < ID_REQUEST_MAX_UNATTESTED_ANSWERS)
    }

    fn answers_unexpired_request(&self, key: &[u8; 32], now: f64) -> bool {
        self.requests.values().any(|r| r.expires_at > now && r.answers.iter().any(|(k, _)| k == key))
    }

    /// Whether a known person who is not a friend may open IK to our hidden listener now.
    fn person_may_open_ik(&self, key: &[u8; 32], person: &PersonView, token: Option<&[u8]>, now: f64) -> bool {
        let since = person.request_since;
        match person.relation {
            Relation::Friend => true,
            Relation::OutgoingRequest => {
                if token.is_some_and(|t| t.len() == 16 && self.admits(t, key, false, now)) {
                    return true;
                }
                if !person.found_nearby {
                    return self.answers_unexpired_request(key, now);
                }
                since.is_some_and(|s| now - s < OUTGOING_REQUEST_LIFETIME_SECONDS)
            }
            Relation::IncomingRequest => {
                person.found_nearby && since.is_some_and(|s| now - s < INCOMING_REQUEST_IK_WINDOW_SECONDS)
            }
            Relation::Removed => {
                // Only answering an Add by ID of ours for the ID they last told us (no host attests here).
                let Some(token) = token.filter(|t| t.len() == 16) else { return false };
                let asked = <[u8; 16]>::try_from(token).ok().and_then(|t| self.requests.get(&t)).map(|r| &r.target);
                asked.is_some_and(|asked| person.friends_id.as_ref() == Some(asked))
                    && self.admits(token, key, false, now)
            }
            Relation::Blocked => false,
        }
    }

    /// The key policy (`allowRemoteKey:...`): reads only; marks `session` a stranger when it admits someone who is
    /// not a friend.
    pub fn allow(
        &mut self,
        session: u64,
        key: Option<&[u8; 32]>,
        pattern: Pattern,
        token: Option<&[u8]>,
        public: bool,
    ) -> bool {
        if self.closed || key == Some(&self.own_key) {
            return false;
        }
        // A device its owner removed, whatever relation its person has (ADR 0012); one of ours, only to be told.
        if key.is_some_and(|k| self.revoked.contains(k)) {
            return pattern == Pattern::IK && key.is_some_and(|k| self.own_removed.contains(k));
        }
        if key.is_some_and(|k| self.own_devices.contains(k)) {
            return pattern == Pattern::IK;
        }
        let now = unix_now();
        let person = key.and_then(|k| self.people.get(k)).cloned();
        match pattern {
            Pattern::NN => {} // Add by ID: anyone may ask, within the listener's rates
            Pattern::XX => {
                // Only a public entry reaches this; completing XX there is a friend request.
                if !public || person.as_ref().is_some_and(|p| p.relation == Relation::Blocked) {
                    return false;
                }
            }
            Pattern::IK => {
                let Some(key) = key else { return false };
                match &person {
                    Some(person) => {
                        if !self.person_may_open_ik(key, person, token, now) {
                            return false;
                        }
                    }
                    // An unknown key only with a token we issued for an unexpired Add by ID, while its slots last.
                    None => {
                        if !token.is_some_and(|t| t.len() == 16 && self.admits(t, key, false, now)) {
                            return false;
                        }
                    }
                }
            }
        }
        if person.as_ref().is_some_and(|p| p.relation == Relation::Friend) && pattern != Pattern::NN {
            return true;
        }
        // Everyone else counts against the strangers' cap; a full cap gives the newcomer the idlest one's place.
        if self.strangers.len() >= STRANGER_SESSIONS_MAX {
            self.make_room = true;
        }
        self.strangers.insert(session);
        true
    }
}

/// The key policy a responder channel asks, for session `session`.
pub fn key_policy(view: Arc<Mutex<PolicyView>>, session: u64, public: bool) -> RemoteKeyPolicy {
    Box::new(move |key: Option<&[u8; 32]>, pattern: Pattern, token: Option<&[u8]>| {
        view.lock().unwrap_or_else(|e| e.into_inner()).allow(session, key, pattern, token, public)
    })
}

/// A listener's admission hooks for one accepted connection.
#[derive(Debug)]
pub struct Hooks {
    pub admission: Arc<Mutex<Admission>>,
    pub connection: u64,
}

impl ListenerHooks for Hooks {
    fn admit_pattern(&mut self, pattern: Pattern) -> bool {
        self.admission.lock().unwrap_or_else(|e| e.into_inner()).admit_pattern(self.connection, pattern, unix_now())
    }

    fn first_message_received(&mut self) {
        self.admission.lock().unwrap_or_else(|e| e.into_inner()).first_message(self.connection);
    }

    fn authenticated(&mut self) {
        self.admission.lock().unwrap_or_else(|e| e.into_inner()).release(self.connection);
    }
}
