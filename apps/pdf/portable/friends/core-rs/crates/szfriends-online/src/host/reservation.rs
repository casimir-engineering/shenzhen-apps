//! Who a check-in speaks for, and what the host's answer about the Friends ID does (`SZFriendsCheckInClient.m`,
//! `+Reservation.m`; HOST-PROTOCOL.md § Devices). A person is their root key, the identity key of their first
//! computer; every other computer checks in with its own key for that root and brings the person's device chain, and
//! the first computer brings it too once the person has others, so every host learns of the computers removed. The
//! Friends ID is the person's: only the first computer draws a new one after a collision. A computer the person
//! removed is turned away for good.

use std::sync::Arc;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::attestation::{Attestation, Verdict};
use super::client::{HostClient, HostOutcome, RESERVES_PER_CONNECTION};
use super::codec::DEVICES_PROTOCOL;

/// The person this computer checks in for: their root key, and the chain to bring (none on a first computer that is
/// alone). `None` before the profile has a chain: the computer is its own root.
pub type Membership = Arc<dyn Fn() -> Option<([u8; 32], Option<Vec<u8>>)> + Send + Sync>;

/// The close code a host ends a removed computer's connection with (HOST-PROTOCOL.md § Devices).
pub const CLOSE_DEVICE_REVOKED: u16 = 4002;

/// What a check-in was made for: the root, and the chain's digest.
pub(super) type CheckedInFor = ([u8; 32], Option<[u8; 32]>);

fn digest(chain: Option<&[u8]>) -> Option<[u8; 32]> {
    chain.map(|c| Sha256::digest(c).into())
}

impl HostClient {
    /// The root and chain a check-in under `protocol` names: a host from before protocol 3 reads only protocol 2's
    /// check-in, so the computer checks in as itself there until the host is updated.
    pub(super) fn person_for(&self, protocol: i64) -> ([u8; 32], Option<Vec<u8>>) {
        let own = self.identity.public_key();
        let named = self.membership.as_ref().and_then(|m| m());
        match named {
            Some((root, chain)) if protocol >= DEVICES_PROTOCOL => (root, chain),
            _ => (own, None),
        }
    }

    /// The check-in's root and chain as sent, remembered so a change of either checks in again (from protocol 3).
    pub(super) fn checking_in_for(&mut self, protocol: i64, root: [u8; 32], chain: Option<&[u8]>) {
        self.person_key = root;
        self.checked_in_for = (protocol >= DEVICES_PROTOCOL).then(|| (root, digest(chain)));
    }

    /// Whether this computer draws a new Friends ID after a collision: only the person's first, whose key the ID is
    /// reserved for.
    pub fn draws_ids(&self) -> bool {
        self.person_key == self.identity.public_key()
    }

    /// The profile's chain changed (a computer joined, was renamed or removed, or this one joined a profile): a
    /// connection made for another root or another chain checks in again, so the host files this computer's records
    /// under its person and turns away the computers removed.
    pub fn membership_changed(&mut self) {
        let Some(sent) = self.checked_in_for else { return };
        let named = self.membership.as_ref().and_then(|m| m());
        let now = named.map_or((self.identity.public_key(), None), |(root, chain)| (root, digest(chain.as_deref())));
        if now != sent && self.is_running() {
            // Joined a profile: the ID from before is released first, once more if a release is still owed.
            self.release_tried = false;
            self.restart();
        }
    }

    /// Another of the person's computers removed this one (the error, or close 4002): no host will take it again, so
    /// nothing more is tried.
    pub(super) fn device_revoked(&mut self) {
        if self.is_running() {
            self.stop();
            self.outcomes.push(HostOutcome::Removed);
        }
    }

    /// The attestation a reservation carried, kept only when it checks out here for the person's key and `id`: one
    /// that would not check out here would not check out for anyone nearby either. An older host sends none.
    fn attestation_for(&self, id: &str, proof: Option<&Value>) -> Option<Attestation> {
        let attestation = proof.and_then(Attestation::from_value)?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64();
        (attestation.check(&self.list, id, &self.person_key, now) == Verdict::Valid).then_some(attestation)
    }

    /// The answer to a reservation, in a welcome (which may name another ID this key already holds) or after a
    /// collision (which must name exactly the ID just drawn), with the host's attestation of the ID reserved.
    pub(super) fn handle_reservation(
        &mut self,
        result: &str,
        value: Option<&Value>,
        adoptable: bool,
        proof: Option<&Value>,
    ) {
        let id = value.and_then(Value::as_str).filter(|id| result == "reserved" && id.len() <= 64);
        let id = id.filter(|id| adoptable || *id == self.pending_id).map(str::to_owned);
        match (result, id) {
            ("reserved", Some(id)) => {
                self.attempt = 0;
                self.reserved = true;
                self.pending_id = id.clone();
                self.collisions = 0;
                let attestation = self.attestation_for(&id, proof);
                self.outcomes.push(HostOutcome::Reserved(id, attestation));
            }
            // A computer that joined a profile never draws an ID: the person's is reserved from their first computer.
            ("taken" | "invalid", _) if !self.draws_ids() => self.reserved = false,
            ("taken" | "invalid", _) => {
                self.reserved = false;
                self.collisions += 1;
                self.reserves += 1;
                if self.reserves > RESERVES_PER_CONNECTION {
                    return;
                }
                self.pending_id = (self.id_provider)(self.collisions);
                if let Value::Object(fields) = json!({ "friends_id": self.pending_id }) {
                    self.send("reserve", fields);
                }
            }
            _ => {}
        }
    }
}
