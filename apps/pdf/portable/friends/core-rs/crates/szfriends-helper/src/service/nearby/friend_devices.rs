//! Friends reach whichever of a person's computers they find (`SZFriendsNearbyService+FriendDevices.m`;
//! friends-multi-device.md § Sync, Friends; ADR 0012).
//!
//! A person's first computer keeps advertising the person's presence tags, which every friend recognises; each of
//! their other computers advertises tags of its own, from the person's presence secret and its device key
//! (`own_friend_presence_tag`), so a friend who holds the person's chain knows which computer it sees and dials it with
//! IK to the static key the chain gives that computer. Online, the driver is asked for each of the person's computers
//! (each publishes its record under the person's key). The session then belongs to the person's conversation like any
//! other: whatever is queued for them goes, and what they send arrives, on whichever computer it is; that computer's
//! sync passes it to the others.

use szfriends_core::identity::chain::DeviceState;
use szfriends_core::nearby::merger::Candidate;
use szfriends_core::nearby::racer::should_start;
use szfriends_core::session::HandshakeOptions;
use szfriends_core::store::devices::{self, DeviceRecord};
use szfriends_core::store::{unix_now, Person, Relation};
use szfriends_core::sync::friend_device_tag_secret;
use szfriends_core::wire::RouteMethod;

use super::Purpose;
use crate::service::{hex, unhex, State};

/// What the matcher names a friend's other computer: "fdev-", its key in hex, "-", the conversation.
const FRIEND_DEVICE_PREFIX: &str = "fdev-";

/// The conversation and device key a matcher name stands for.
pub(super) fn friend_device_of(name: &str) -> Option<(String, [u8; 32])> {
    let rest = name.strip_prefix(FRIEND_DEVICE_PREFIX)?;
    let (key, conversation) = (rest.get(..64)?, rest.get(64..)?.strip_prefix('-')?);
    Some((conversation.to_owned(), unhex(key)?.try_into().ok()?))
}

impl State {
    /// A friend's computers other than their first that their chain authorizes now.
    pub(crate) fn friend_other_devices(&self, person: &Person) -> Vec<DeviceRecord> {
        let Some(root) = person.identity_key.filter(|_| person.relation == Relation::Friend) else { return Vec::new() };
        let records = devices::devices_of_root(self.store.connection(), &root).unwrap_or_default();
        records.into_iter().filter(|d| !d.is_root && d.state == DeviceState::Authorized).collect()
    }

    /// The matcher's entries for friends' other computers.
    pub(crate) fn friend_device_tag_secrets(&self) -> Vec<(String, Vec<u8>)> {
        let people = self.store.people_by_latest_interaction().unwrap_or_default();
        let mut secrets = Vec::new();
        for person in people.iter().filter(|p| p.relation == Relation::Friend) {
            let Some(presence) = person.presence_secret else { continue };
            for device in self.friend_other_devices(person) {
                let Some(secret) = friend_device_tag_secret(&presence, &device.device_key) else { continue };
                let name = format!("{FRIEND_DEVICE_PREFIX}{}-{}", hex(&device.device_key), person.conversation_id);
                secrets.push((name, secret.to_vec()));
            }
        }
        secrets
    }

    /// IK to a friend's other computer: the static key their chain gives it, that computer's key expected.
    pub(crate) fn friend_device_options(
        &self,
        person: &Person,
        device: &[u8; 32],
        route: RouteMethod,
    ) -> Option<HandshakeOptions> {
        if person.relation != Relation::Friend || person.key_change_pending {
            return None;
        }
        let root = person.identity_key?;
        let static_key = devices::static_key_for_device(self.store.connection(), device, &root).ok().flatten()?;
        let mut options = self.ik_options(person, route);
        options.remote_static = Some(static_key);
        options.expected_identity = Some(*device);
        Some(options)
    }

    /// A candidate the matcher named after a friend's other computer; `false` for anyone else. One session per
    /// conversation: a friend's other computer is dialed while none of theirs carries one.
    pub(crate) fn reach_friend_device_candidate(&mut self, candidate: &Candidate) -> bool {
        let Some((conversation, device)) = candidate.conversation_id.as_deref().and_then(friend_device_of) else {
            return false;
        };
        let person = self.store.person_with_conversation(&conversation).ok().flatten();
        let Some(person) = person.filter(|_| self.sessions.live_for(&conversation).is_none()) else { return true };
        if !self.may_dial(&conversation) {
            return true;
        }
        let attempts = self.nearby.racer.attempts(candidate, self.nearby.merger.matcher(), unix_now());
        for attempt in attempts {
            if !should_start(&attempt, RouteMethod::None) {
                continue;
            }
            let Some(options) = self.friend_device_options(&person, &device, attempt.sighting.route) else {
                return true;
            };
            let mut plan = self.plan(&attempt.sighting, Purpose::Friend, options);
            plan.conversation = Some(conversation.clone());
            self.dial(plan, attempt.delay);
        }
        true
    }

    /// The keys a friend's other computers present: the key policy reads them as that friend.
    pub(crate) fn friend_device_keys(&self) -> Vec<([u8; 32], [u8; 32])> {
        let people = self.store.people_by_latest_interaction().unwrap_or_default();
        let mut keys = Vec::new();
        for person in people.iter().filter(|p| p.relation == Relation::Friend) {
            let Some(root) = person.identity_key else { continue };
            keys.extend(self.friend_other_devices(person).into_iter().map(|d| (d.device_key, root)));
        }
        keys
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_matcher_name_says_whose_computer_it_is() {
        let key = [0xab; 32];
        let name = format!("{FRIEND_DEVICE_PREFIX}{}-c0ffee", hex(&key));
        assert_eq!(friend_device_of(&name), Some(("c0ffee".to_owned(), key)));
        assert_eq!(friend_device_of("fdev-12-c0ffee"), None);
        assert_eq!(friend_device_of("dev-ab"), None);
    }
}
