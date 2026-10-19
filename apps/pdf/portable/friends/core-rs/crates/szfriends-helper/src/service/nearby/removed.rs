//! Telling a computer it was removed (`SZFriendsNearbyService+Removed.m`; PROTOCOL.md § Devices, This computer was
//! removed; ADR 0012). A computer removed while it was away hears nothing by itself: its sessions with our computers
//! are gone, and the secrets it finds them by were drawn again. So our computers look for it too, by the tags it still
//! advertises (under the own-devices secret it holds, the current one or one replaced since), and dial it; and when it
//! dials one of them, the key policy lets its IK through. Either way the session carries one frame, our chain, which
//! says it was removed and which it can verify itself, and then closes. Nothing else reaches it: no sync, no friend's
//! message.

use szfriends_core::identity::chain::DeviceState;
use szfriends_core::nearby::merger::Candidate;
use szfriends_core::session::HandshakeOptions;
use szfriends_core::store::devices;
use szfriends_core::store::unix_now;
use szfriends_core::sync::device_tag_secret;
use szfriends_core::wire::{tag, CloseReason, Frame, FrameType, Pattern};

use super::Purpose;
use crate::log;
use crate::service::{hex, unhex, State};

/// What the matcher names a removed computer's sightings by: "rmv-" and its device key in hex.
const REMOVED_PREFIX: &str = "rmv-";
/// A removed computer seen nearby is dialed again where it was seen at most this often, however the last try ended.
const REMOVED_REDIAL: f64 = 60.0;

impl State {
    /// One of our computers that our chain removed, while this one still belongs to the profile.
    pub(crate) fn is_own_removed_device(&self, key: &[u8; 32]) -> bool {
        let Some(root) = self.own_root() else { return false }; // this computer was removed too
        let records = devices::devices_of_root(self.store.connection(), &root).unwrap_or_default();
        records.iter().any(|d| d.device_key == *key && d.state == DeviceState::Revoked)
    }

    /// Our removed computers' keys: the key policy lets their IK through, to tell them.
    pub(crate) fn own_removed_devices(&self) -> Vec<[u8; 32]> {
        let Some(root) = self.own_root() else { return Vec::new() };
        let records = devices::devices_of_root(self.store.connection(), &root).unwrap_or_default();
        records.into_iter().filter(|d| d.state == DeviceState::Revoked).map(|d| d.device_key).collect()
    }

    /// The matcher's entries for our removed computers: the tags each would advertise under every own-devices secret
    /// we held.
    pub(crate) fn removed_device_tag_secrets(&self) -> Vec<(String, Vec<u8>)> {
        let engine = &self.devices.engine;
        let Some(current) = engine.own_devices_secret(&self.store).filter(|_| engine.is_active(&self.store)) else {
            return Vec::new();
        };
        let mut held = vec![current];
        held.extend(engine.previous_own_devices_secrets(&self.store));
        let mut secrets = Vec::new();
        for device in self.own_removed_devices() {
            let name = format!("{REMOVED_PREFIX}{}", hex(&device));
            for secret in &held {
                if let Some(tag_secret) = device_tag_secret(secret, &device) {
                    secrets.push((name.clone(), tag_secret.to_vec()));
                }
            }
        }
        secrets
    }

    /// A candidate the matcher named after a removed computer of ours: dialed with IK to say so; `false` for anyone
    /// else.
    pub(crate) fn reach_removed_device_candidate(&mut self, candidate: &Candidate) -> bool {
        let Some(hex_key) = candidate.conversation_id.as_deref().and_then(|c| c.strip_prefix(REMOVED_PREFIX)) else {
            return false;
        };
        let device: Option<[u8; 32]> = unhex(hex_key).and_then(|k| k.try_into().ok());
        let Some(device) = device.filter(|d| self.is_own_removed_device(d)) else { return true };
        let chain = devices::own_chain(self.store.connection()).ok().flatten();
        let Some(static_key) = chain.as_ref().and_then(|c| c.device(&device)).map(|d| d.static_key) else {
            return true;
        };
        let now = unix_now();
        for sighting in candidate.sightings.iter().filter(|s| !s.public) {
            // Per place it was seen: a sighting from before it went away must not hold back the one where it is now.
            let throttle = format!("removed|{hex_key}|{}", sighting.endpoint);
            if self.nearby.attempts.get(&throttle).is_some_and(|until| *until > now) {
                continue;
            }
            let mut options = HandshakeOptions::new(Pattern::IK, sighting.route);
            options.remote_static = Some(static_key);
            options.expected_identity = Some(device);
            let plan = self.plan(sighting, Purpose::OwnDevice, options);
            if self.dial(plan, 0.0) {
                self.nearby.attempts.insert(throttle, now + REMOVED_REDIAL);
                break;
            }
        }
        true
    }

    /// Our chain, which says it was removed, then the end of the session.
    pub(crate) fn tell_removed_computer(&mut self, id: u64) {
        let Some(session) = self.sessions.map.get(&id) else { return };
        let ik = session.channel.pattern() == Pattern::IK && session.channel.negotiated_minor() >= 2;
        let chain = devices::own_chain(self.store.connection()).ok().flatten();
        if let (true, Some(chain)) = (ik && !session.channel.is_closed(), chain) {
            log!("told a computer removed from the profile that it was removed");
            self.send_on(id, &Frame::new(FrameType::Chain).with(tag::CHAIN, chain.encoded().to_vec()));
        }
        self.close(id, CloseReason::Normal);
    }
}
