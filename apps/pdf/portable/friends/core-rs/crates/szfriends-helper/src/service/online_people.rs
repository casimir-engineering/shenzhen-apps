//! Whom online reaches and for whom this computer checks in, as the store says now (`online.rs`): friends and each of
//! their other computers, and the person and chain of a profile on several computers.

use std::collections::HashMap;

use szfriends_core::identity::chain::DeviceState;
use szfriends_core::store::{devices, Relation, Store};
use szfriends_online::driver::OnlineFriend;

/// The root a computer checks in for, and the chain it brings (`szfriends_online::host::reservation`).
pub(super) type Person = ([u8; 32], Option<Vec<u8>>);

/// Who this computer checks in for (HOST-PROTOCOL.md § Devices): the root of a profile on several computers, with its
/// chain; a first computer alone checks in as itself, and a computer that was never part of one has no root.
pub(super) fn membership(store: &Store, me: &[u8; 32]) -> Option<Person> {
    let conn = store.connection();
    let root = devices::root_for_device(conn, me).ok().flatten()?;
    let several = devices::devices_of_root(conn, &root).map(|d| d.len() >= 2).unwrap_or(false);
    let chain = devices::own_chain(conn).ok().flatten().filter(|_| several).map(|c| c.encoded().to_vec());
    Some((root, chain))
}

/// Friends the online driver may reach: friends with a static key and no key change waiting for review, and each of
/// their other computers their chain authorizes, filed under the friend (nearby/friend_devices.rs).
pub(super) fn friends(store: &Store) -> HashMap<[u8; 32], OnlineFriend> {
    let people = store.people_by_latest_interaction().unwrap_or_default();
    let mut friends = HashMap::new();
    for p in people.into_iter().filter(|p| p.relation == Relation::Friend && !p.key_change_pending) {
        let (Some(root), Some(static_key)) = (p.identity_key, p.static_key) else { continue };
        let (presence_secret, request_token) = (p.presence_secret, p.callback_token);
        let friend = |identity_key, static_key, root_key| OnlineFriend {
            identity_key,
            static_key,
            presence_secret,
            request_token,
            root_key,
        };
        friends.insert(root, friend(root, static_key, None));
        for device in devices::devices_of_root(store.connection(), &root).unwrap_or_default() {
            if !device.is_root && device.state == DeviceState::Authorized {
                friends.insert(device.device_key, friend(device.device_key, device.static_key, Some(root)));
            }
        }
    }
    friends
}
