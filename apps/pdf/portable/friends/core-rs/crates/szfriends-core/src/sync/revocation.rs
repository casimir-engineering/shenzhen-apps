//! What a revoked device of ours still counts for (`SZFriendsSyncRevocation.m`, event kind 11): the device that
//! revokes another records how many of its events it held, and our devices accept that device's events up to there
//! and none after, whoever forwards them; a record counts only from the device that signed that revocation. Then one
//! authorized device draws new secrets: the first at once, the next ones in turn after a wait.

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::types::Value;
use szfriends_identity::chain::{DeviceChain, DeviceState, LinkKind};

use super::apply::Applied;
use super::codec::{decode_vector, encode_vector, vector_covers, Event, Fields};
use super::engine::SyncEngine;
use super::{digest, from_hex, hex, Kind, SyncError, SECRET_RENEWAL_WAIT, STATE_DEVICES_SECRET};
use super::{STATE_PRESENCE_DRAWN, STATE_PRESENCE_RETELL, STATE_RENEWED};
use crate::store::sync_log::{self, atomically, Register, Vector};
use crate::store::{devices, sync_files, sync_history, sync_records, Store};

/// Own-devices secrets kept after they were replaced, for finding a computer removed while away.
const PREVIOUS_SECRETS_MAX: usize = 4;
const PREVIOUS_SECRETS_KEY: &str = "own_devices_secrets_previous";

fn revocation_key(device: &[u8; 32]) -> String {
    format!("rv/{}", hex(device))
}

fn chain_revokes(chain: Option<&DeviceChain>, subject: &[u8; 32], signer: &[u8; 32]) -> bool {
    chain.is_some_and(|c| {
        c.links().iter().any(|l| l.kind == LinkKind::Revoke && &l.subject == subject && &l.signer == signer)
    })
}

fn coverage_in_record(event: &Event) -> Option<u64> {
    event.fields().filter(|f| f.has(2)).map(|f| f.u64(2))
}

fn seq_value(seq: u64) -> Vec<u8> {
    seq.to_be_bytes().to_vec()
}

fn held_seq(register: Option<&Register>) -> Option<u64> {
    register.and_then(|r| r.value.as_deref()).and_then(|v| <[u8; 8]>::try_from(v).ok()).map(u64::from_be_bytes)
}

impl SyncEngine {
    /// For each revoked device: the highest sequence number of its events we accept, from the records held and those
    /// in `events`. Absent: none of its events.
    pub(super) fn revocation_coverage(
        &self,
        store: &Store,
        events: &[Event],
        revoked: &BTreeSet<[u8; 32]>,
    ) -> BTreeMap<[u8; 32], u64> {
        let mut coverage = BTreeMap::new();
        for device in revoked {
            let held = sync_log::register(&store.conn, &revocation_key(device)).ok().flatten();
            if let Some(seq) = held_seq(held.as_ref()) {
                coverage.insert(*device, seq);
            }
        }
        let mut chain: Option<Option<DeviceChain>> = None;
        for event in events.iter().filter(|e| e.kind == Kind::Revocation) {
            let subject: Option<[u8; 32]> = from_hex(&event.subject).and_then(|s| s.try_into().ok());
            let (Some(subject), Some(covered)) = (subject, coverage_in_record(event)) else { continue };
            if !revoked.contains(&subject) {
                continue;
            }
            let chain = chain.get_or_insert_with(|| devices::own_chain(&store.conn).ok().flatten());
            if !chain_revokes(chain.as_ref(), &subject, &event.author) {
                continue;
            }
            if covered > coverage.get(&subject).copied().unwrap_or(0) {
                coverage.insert(subject, covered);
            }
        }
        coverage
    }

    pub(super) fn apply_revocation(&mut self, store: &Store, event: &Event) -> Applied {
        let subject: Option<[u8; 32]> = from_hex(&event.subject).and_then(|s| s.try_into().ok());
        let (Some(subject), Some(covered)) = (subject, coverage_in_record(event)) else { return Applied::Done };
        // The revocation itself reaches us by chain, perhaps after this record.
        let chain = devices::own_chain(&store.conn).ok().flatten();
        if !chain_revokes(chain.as_ref(), &subject, &event.author) {
            return Applied::Wait;
        }
        let key = revocation_key(&subject);
        let held = sync_log::register(&store.conn, &key).ok().flatten();
        let mut accepted = held_seq(held.as_ref()).unwrap_or(0);
        if held_seq(held.as_ref()).is_none_or(|h| h < covered) {
            let entry =
                Register { lamport: event.lamport, author: event.author.to_vec(), value: Some(seq_value(covered)) };
            if sync_log::set_register(&store.conn, &key, &entry).is_err() {
                return Applied::Failed;
            }
            accepted = covered;
        }
        let removed =
            self.own_devices(store).iter().any(|d| d.device_key == subject && d.state == DeviceState::Revoked);
        if !removed {
            return Applied::Done;
        }
        if self.drop_events_of_device(store, &subject, accepted) {
            Applied::Done
        } else {
            Applied::Failed
        }
    }

    /// The own-devices secret becomes `secret`; the one it replaces joins the previous ones.
    pub(super) fn replace_own_devices_secret(&self, store: &Store, secret: &[u8]) -> bool {
        let conn = &store.conn;
        if let Some(current) = self.own_devices_secret(store).filter(|c| c != secret) {
            let mut previous = current;
            for older in self.previous_own_devices_secrets(store) {
                if previous.len() >= PREVIOUS_SECRETS_MAX * 32 {
                    break;
                }
                if older != secret {
                    previous.extend_from_slice(&older);
                }
            }
            if sync_log::set_state(conn, PREVIOUS_SECRETS_KEY, previous.into()).is_err() {
                return false;
            }
        }
        sync_log::set_state(conn, STATE_DEVICES_SECRET, secret.to_vec().into()).is_ok()
    }

    /// This device just stored a chain revoking `device`: records which of its events it held.
    pub fn record_revocation(&mut self, store: &Store, device: &[u8; 32]) -> Result<(), SyncError> {
        self.capture_local_changes(store);
        let covered = sync_log::vector(&store.conn)?.get(device).copied().unwrap_or(0);
        let mut fields = Fields::new();
        fields.set_u64(2, covered);
        self.reset_counters();
        let result = atomically(&store.conn, |conn| {
            let event = self
                .record(conn, Kind::Revocation, "", &hex(device), &fields.encode())
                .map_err(|_| crate::store::StoreError::Invalid("not recorded"))?;
            let entry =
                Register { lamport: event.lamport, author: event.author.to_vec(), value: Some(seq_value(covered)) };
            sync_log::set_register(conn, &revocation_key(device), &entry)
        });
        self.reset_counters();
        result?;
        self.note_new_events();
        Ok(())
    }

    /// The removals so far as every device names them, and this device's place among the authorized ones.
    fn removals_seen(&self, store: &Store) -> (String, Option<usize>) {
        let me = self.device_key();
        let mut revoked = Vec::new();
        let mut place = 0;
        let mut rank = None;
        for device in self.own_devices(store) {
            if device.state == DeviceState::Revoked {
                revoked.push(hex(&device.device_key));
            }
            if device.state != DeviceState::Authorized {
                continue;
            }
            if device.device_key == me {
                rank = Some(place);
            }
            place += 1;
        }
        revoked.sort();
        (revoked.join(","), rank)
    }

    fn secrets_follow_removals(&self, store: &Store, seen: &str) -> bool {
        sync_log::state_bytes(&store.conn, STATE_RENEWED).ok().flatten().as_deref() == Some(&digest(seen.as_bytes()))
    }

    fn state_text(&self, store: &Store, key: &str) -> Option<String> {
        match sync_log::state(&store.conn, key).ok()? {
            Value::Text(text) => Some(text),
            _ => None,
        }
    }

    /// When this device will draw if nobody has by then; `None` when nothing waits.
    pub fn secret_renewal_due(&self, store: &Store) -> Option<f64> {
        let (seen, rank) = self.removals_seen(store);
        let handled = self.state_text(store, "revocations_renewed");
        let rank = rank?;
        if seen.is_empty() || handled.as_deref() == Some(seen.as_str()) || self.secrets_follow_removals(store, &seen) {
            return None;
        }
        if rank == 0 {
            return Some((self.clock)());
        }
        let noticed = self.state_text(store, "revocations_noticed");
        let since = match sync_log::state(&store.conn, "revocations_noticed_at").ok()? {
            Value::Real(at) => at,
            Value::Integer(at) => at as f64,
            _ => return None,
        };
        (noticed.as_deref() == Some(seen.as_str())).then_some(since + rank as f64 * SECRET_RENEWAL_WAIT)
    }

    /// New presence and own-devices secrets after a removal, drawn by one device; the new presence secret, if drawn.
    pub fn renew_secrets_after_revocation(&mut self, store: &Store) -> Option<Vec<u8>> {
        let conn = &store.conn;
        let (seen, rank) = self.removals_seen(store);
        if self.state_text(store, "revocations_renewed").unwrap_or_default() == seen {
            return None;
        }
        let Some(rank) = rank.filter(|_| !seen.is_empty() && !self.secrets_follow_removals(store, &seen)) else {
            let _ = sync_log::set_state(conn, "revocations_renewed", Value::Text(seen));
            return None;
        };
        if rank > 0 {
            if self.state_text(store, "revocations_noticed").as_deref() != Some(seen.as_str()) {
                let _ = sync_log::set_state(conn, "revocations_noticed", Value::Text(seen.clone()));
                let _ = sync_log::set_state(conn, "revocations_noticed_at", Value::Real((self.clock)()));
            }
            let due = self.secret_renewal_due(store)?;
            if due > (self.clock)() {
                return None;
            }
        }
        let mut fresh = [0u8; 64];
        szfriends_crypto::random_bytes(&mut fresh);
        let (presence, devices_secret) = fresh.split_at(32);
        if !self.replace_own_devices_secret(store, devices_secret)
            || sync_log::set_state(conn, STATE_RENEWED, digest(seen.as_bytes()).to_vec().into()).is_err()
        {
            return None;
        }
        let _ = sync_records::set_own_presence_secret(conn, Some(presence));
        let _ = sync_log::set_state(conn, STATE_PRESENCE_DRAWN, presence.to_vec().into());
        let _ = sync_log::set_state(conn, "revocations_renewed", Value::Text(seen));
        self.note_changed(None);
        self.flush_changes();
        Some(presence.to_vec())
    }

    /// Once, after sync replaced a presence secret this device drew and told friends.
    pub fn take_presence_secret_retell(&self, store: &Store) -> bool {
        let retell = !matches!(sync_log::state(&store.conn, STATE_PRESENCE_RETELL), Ok(Value::Null) | Err(_));
        if retell {
            let _ = sync_log::set_state(&store.conn, STATE_PRESENCE_RETELL, Value::Null);
        }
        retell
    }

    /// What another of our devices last said it holds (its HELLO or ACK).
    pub fn vector_held_by(&self, store: &Store, device: &[u8; 32]) -> Option<Vector> {
        let held = sync_log::state_bytes(&store.conn, &format!("held/{}", hex(device))).ok().flatten()?;
        decode_vector(&held).map(|(v, _)| v)
    }

    pub fn note_device_holds(&self, store: &Store, device: &[u8; 32], vector: &Vector) {
        let _ = sync_log::set_state(&store.conn, &format!("held/{}", hex(device)), encode_vector(vector).into());
    }

    /// Every other authorized device of ours holds an event that carried this item.
    pub fn item_reached_every_device(&self, store: &Store, item_id: &str, conversation: &str) -> bool {
        let origins = sync_history::origins_of_item(&store.conn, item_id, conversation).unwrap_or_default();
        if origins.is_empty() {
            return false;
        }
        self.other_device_keys(store).iter().all(|device| {
            let held = self.vector_held_by(store, device);
            origins.iter().any(|(author, seq)| held.as_ref().is_some_and(|v| vector_covers(v, author, *seq)))
        })
    }

    pub fn file_reached_every_device(&self, store: &Store, transfer_id: &str) -> bool {
        let Some(file) = sync_files::sync_file(&store.conn, transfer_id).ok().flatten() else { return false };
        self.other_device_keys(store).iter().all(|d| file.holders.contains(d))
    }

    /// The own-devices secrets this device held before the current one, newest first.
    pub fn previous_own_devices_secrets(&self, store: &Store) -> Vec<Vec<u8>> {
        let held = sync_log::state_bytes(&store.conn, PREVIOUS_SECRETS_KEY).ok().flatten().unwrap_or_default();
        held.chunks_exact(32).map(<[u8]>::to_vec).collect()
    }
}

/// Without an engine: the own-devices secret a store holds, drawn when absent and `create`.
pub fn own_devices_secret_in_store(store: &Store, create: bool) -> Option<Vec<u8>> {
    if let Some(held) =
        sync_log::state_bytes(&store.conn, STATE_DEVICES_SECRET).ok().flatten().filter(|s| s.len() == 32)
    {
        return Some(held);
    }
    if !create {
        return None;
    }
    let mut secret = vec![0u8; 32];
    szfriends_crypto::random_bytes(&mut secret);
    sync_log::set_state(&store.conn, STATE_DEVICES_SECRET, secret.clone().into()).ok()?;
    Some(secret)
}

/// The one a joined device receives.
pub fn adopt_own_devices_secret(store: &Store, secret: &[u8]) -> bool {
    secret.len() == 32 && sync_log::set_state(&store.conn, STATE_DEVICES_SECRET, secret.to_vec().into()).is_ok()
}
