//! Device chains on sessions with friends (`SZFriendsNearbyService+Chain.m`; ADR 0012; friends-multi-device.md
//! § Identity). Every live session with a friend carries our chain (CHAIN, session minor 2), so friends hold the
//! newest list of the computers that speak for us; a friend's chain is kept once it verifies from the root we pinned
//! for them.
//! The store then finds a friend from any of their authorized devices (`person_with_identity_key`), so IK from those
//! devices passes the key policy like the first device's, and a removed device finds nobody.
//!
//! Only friends get our chain: it names our computers, which a stranger who reached a public entry has no reason to
//! learn. The one exception is first contact: a request or an answer from a computer other than our first, whose chain
//! goes first so the other side files it under the person, not under that computer.

use szfriends_core::identity::chain::DeviceChain;
use szfriends_core::store::devices::{self, ChainMerge};
use szfriends_core::store::{unix_now, Person, Relation};
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType, Pattern};

use crate::log;
use crate::service::devices::{local_device_name, local_device_system};
use crate::service::State;

impl State {
    fn carries_chains(&self, id: u64) -> bool {
        let Some(session) = self.sessions.map.get(&id) else { return false };
        let channel = &session.channel;
        !channel.is_closed() && channel.pattern() != Pattern::NN && channel.negotiated_minor() >= 2
    }

    /// A device its owner removed, whichever side dialed: one of ours removed while away is told so (removed.rs),
    /// anyone else's session ends. `true` when the session goes no further.
    pub(crate) fn chain_refuses_live(&mut self, id: u64) -> bool {
        let remote = self.sessions.map.get(&id).and_then(|s| s.channel.remote_identity().copied());
        let Some(key) = remote else { return false };
        let conn = self.store.connection();
        if !devices::is_revoked_device(conn, &key).unwrap_or(false) {
            let _ = devices::note_device_seen(conn, &key, unix_now());
            return false;
        }
        if self.is_own_removed_device(&key) {
            self.tell_removed_computer(id);
        } else {
            log!("closed a session with a device its owner removed");
            self.close(id, CloseReason::Normal);
        }
        true
    }

    /// Our chain on a live session with a friend, once per session (a request accepted on it goes on as a friend's);
    /// an existing profile gets its first link here, the first time a friend needs it, never at launch.
    pub(crate) fn send_chain_to_friend(&mut self, id: u64) {
        if !self.carries_chains(id) || self.sessions.map.get(&id).is_none_or(|s| s.meta.chain_sent) {
            return;
        }
        let person = self.conversation_of(id).and_then(|c| self.store.person_with_conversation(&c).ok().flatten());
        if person.is_none_or(|p| p.relation != Relation::Friend) {
            return;
        }
        let (name, system) = (local_device_name(), local_device_system());
        let conn = self.store.connection();
        match devices::own_chain_creating_genesis(conn, &self.devices.identity, &name, &system) {
            Ok(chain) => {
                if self.send_on(id, &Frame::new(FrameType::Chain).with(tag::CHAIN, chain.encoded().to_vec())) {
                    self.sessions.map.get_mut(&id).expect("live").meta.chain_sent = true;
                }
            }
            Err(error) => log!("no device chain to send: {error}"),
        }
    }

    /// Our chain to every friend connected now: a computer added, removed or renamed reaches them at once, so they
    /// accept a new computer before it first reaches them.
    pub(crate) fn send_chain_to_friends(&mut self) {
        let ids: Vec<u64> = self.sessions.map.iter().filter(|(_, s)| s.meta.adopted).map(|(id, _)| *id).collect();
        for id in ids {
            self.sessions.map.get_mut(&id).expect("listed").meta.chain_sent = false;
            self.send_chain_to_friend(id);
        }
    }

    /// CHAIN from someone who is not one of our devices: a friend's chain, or before a stranger's request the chain
    /// of the computer asking.
    pub(crate) fn friend_chain_frame(&mut self, id: u64, frame: &Frame) {
        let data = frame.get(tag::CHAIN).unwrap_or_default().to_vec();
        let person = self.conversation_of(id).and_then(|c| self.store.person_with_conversation(&c).ok().flatten());
        let Some(person) = person else {
            match self.verified_first_contact_chain(id, &data) {
                Some(chain) => {
                    if let Some(s) = self.sessions.map.get_mut(&id) {
                        s.meta.pending_chain = Some(chain);
                    }
                }
                None => log!("a chain before a request did not name the device that sent it; ignored"),
            }
            return;
        };
        if person.relation == Relation::Blocked {
            return;
        }
        let device = self.sessions.map.get(&id).and_then(|s| s.channel.remote_identity().copied());
        let (Some(root), Some(device)) = (person.identity_key, device) else { return };
        let conn = self.store.connection();
        // Our Add by ID answered by a device other than their first: the row the answer made names that device until
        // its chain says whose it is. Only a request may move, never a friend, whose key the person may have checked.
        if root == device
            && person.relation != Relation::Friend
            && !self.is_verified(&person.conversation_id)
            && devices::chain_for_root(conn, &root).ok().flatten().is_none()
        {
            if let Some(theirs) = self.verified_first_contact_chain(id, &data) {
                if devices::rekey_conversation(conn, &person.conversation_id, &device, &theirs).is_ok() {
                    return self.people_changed();
                }
            }
        }
        let merged = match devices::merge_friend_chain(conn, &data, &root) {
            Ok(merged) => merged,
            Err(error) => {
                // A chain that does not verify from the root we pinned, or forks it, is never believed; the device
                // that sent it gets no more of this session.
                log!("refused a friend's device chain: {error}");
                return self.close(id, CloseReason::ProtocolError);
            }
        };
        // The chain the sender just gave may remove the sender itself.
        let still_speaks = if device == root {
            !devices::is_revoked_device(conn, &device).unwrap_or(true)
        } else {
            devices::root_for_device(conn, &device).ok().flatten() == Some(root)
        };
        if !still_speaks {
            return self.close(id, CloseReason::Normal);
        }
        if merged == ChainMerge::Changed {
            // Their other computers: tags to match, keys to admit, devices online may reach.
            self.people_changed();
        }
    }

    /// Before a request or an answer that may be the first they hear of us: our chain, when this computer is not the
    /// profile's first (which is the person itself, with nothing to explain).
    pub(crate) fn send_first_contact_chain(&mut self, id: u64) {
        let Some(session) = self.sessions.map.get(&id) else { return };
        if session.meta.first_contact_chain_sent || self.is_own_device_session(id) || !self.carries_chains(id) {
            return;
        }
        if let Some(s) = self.sessions.map.get_mut(&id) {
            s.meta.first_contact_chain_sent = true;
        }
        let me = self.identity.public_key();
        if self.own_root().is_none_or(|root| root == me) {
            return;
        }
        if let Some(chain) = devices::own_chain(self.store.connection()).ok().flatten() {
            self.send_on(id, &Frame::new(FrameType::Chain).with(tag::CHAIN, chain.encoded().to_vec()));
        }
    }

    fn is_verified(&self, conversation: &str) -> bool {
        let sql = "SELECT verified FROM friends WHERE conversation_id = ?1";
        self.store.connection().query_row(sql, [conversation], |r| r.get::<_, i64>(0)).is_ok_and(|v| v != 0)
    }

    fn is_own_device_session(&self, id: u64) -> bool {
        self.devices.exchanges.contains_key(&id)
    }

    /// A chain from a device we have no person for yet: from its own genesis, naming the session's device with the
    /// static key its handshake used, and not its root (the first device needs no chain to be itself).
    fn verified_first_contact_chain(&self, id: u64, data: &[u8]) -> Option<DeviceChain> {
        let channel = &self.sessions.map.get(&id)?.channel;
        let (device, presented) = (channel.remote_identity()?, channel.remote_static()?);
        let chain = DeviceChain::decode(data, None).ok()?;
        let named = chain.device(device)?;
        let fits = chain.authorizes(device) && chain.root_key() != device && named.static_key == *presented;
        fits.then_some(chain)
    }

    /// A stranger's request after their chain: the person is its root, dialed at their first computer (its key and
    /// static key).
    pub(crate) fn first_contact_root(&self, id: u64) -> Option<(DeviceChain, [u8; 32], [u8; 32])> {
        let chain = self.sessions.map.get(&id)?.meta.pending_chain.clone()?;
        let root = *chain.root_key();
        let root_static = chain.device(&root)?.static_key;
        Some((chain, root, root_static))
    }

    /// Another device of `person`'s, which has its own static key in their chain: `Some(true)` when the session
    /// presented that key, `Some(false)` when another (refused, not reviewed), `None` for their first device.
    pub(crate) fn other_device_static_matches(&self, person: &Person, id: u64) -> Option<bool> {
        let channel = &self.sessions.map.get(&id)?.channel;
        let (device, root) = (channel.remote_identity()?, person.identity_key?);
        if *device == root {
            return None;
        }
        let expected = devices::static_key_for_device(self.store.connection(), device, &root).ok().flatten();
        Some(expected.is_some() && expected.as_ref() == channel.remote_static())
    }
}
