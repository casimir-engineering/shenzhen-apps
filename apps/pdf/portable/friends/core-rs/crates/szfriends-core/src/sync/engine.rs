//! The sync engine (`SZFriendsSyncEngine.m`): signing our events, taking in our other devices' events, applying them
//! in batches, and the deletion that erases chat history on every device. Capture is `capture.rs`, the merge rules
//! `apply.rs`, file copies `files.rs`. The engine keeps no store: every call takes the one it works on, so it can live
//! beside the store in whatever owns both.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;

use rusqlite::Connection;
use szfriends_identity::chain::DeviceState;
use szfriends_identity::Identity;

use super::codec::{encode_vector, Event, Fields};
use super::{label_is_valid, ref_for_person, Kind, SyncError, BODY_MAX, LAMPORT_MARGIN, STATE_DEVICES_SECRET};
use crate::store::devices::{self, DeviceRecord};
use crate::store::sync_log::{self, atomically, Vector, YOU};
use crate::store::sync_records::{self, Picture};
use crate::store::{Store, StoreError};

/// Events applied per transaction.
const APPLY_BATCH: usize = 200;

pub(super) struct Tombstone {
    pub scope: String,
    pub conversation: String,
    pub vector: Vector,
    pub lamport: u64,
}

/// Keeps a synced photo's bytes and returns its picture.
pub type StorePicture = Box<dyn Fn(&[u8]) -> Option<Picture> + Send>;

/// One engine per device, beside its store.
pub struct SyncEngine {
    pub(super) identity: Arc<Identity>,
    pub(super) received_dir: PathBuf,
    next_seq: u64,
    lamport: u64,
    pub(super) tombstones: Option<Vec<Tombstone>>,
    pub(super) changed: BTreeSet<String>,
    pub(super) profile_changed: bool,
    changes: Vec<BTreeSet<String>>,
    new_events: bool,
    /// The clock events are stamped with (Unix seconds); tests set it.
    pub clock: Box<dyn Fn() -> f64 + Send>,
    /// Keeps a synced photo and returns its picture; `None`: placeholder.
    pub store_picture: Option<StorePicture>,
}

impl std::fmt::Debug for SyncEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SyncEngine").field("received_dir", &self.received_dir).finish_non_exhaustive()
    }
}

impl SyncEngine {
    pub fn new(identity: Arc<Identity>, received_dir: PathBuf) -> Self {
        Self {
            identity,
            received_dir,
            next_seq: 0,
            lamport: 0,
            tombstones: None,
            changed: BTreeSet::new(),
            profile_changed: false,
            changes: Vec::new(),
            new_events: false,
            clock: Box::new(crate::store::unix_now),
            store_picture: None,
        }
    }

    pub fn device_key(&self) -> [u8; 32] {
        self.identity.public_key()
    }

    /// The store changed by sync since the last call: conversations touched, empty for profile-wide changes.
    pub fn take_changes(&mut self) -> Vec<BTreeSet<String>> {
        std::mem::take(&mut self.changes)
    }

    /// Events were recorded or received since the last call: sessions with our other devices send them on.
    pub fn take_new_events(&mut self) -> bool {
        std::mem::take(&mut self.new_events)
    }

    pub(super) fn note_new_events(&mut self) {
        self.new_events = true;
    }

    /// Our own chain's root key while the chain authorizes this device.
    pub fn root_key(&self, store: &Store) -> Option<[u8; 32]> {
        devices::root_for_device(&store.conn, &self.device_key()).ok().flatten()
    }

    pub(super) fn own_devices(&self, store: &Store) -> Vec<DeviceRecord> {
        self.root_key(store).and_then(|root| devices::devices_of_root(&store.conn, &root).ok()).unwrap_or_default()
    }

    /// Sync runs once our own chain has held another device.
    pub fn is_active(&self, store: &Store) -> bool {
        self.own_devices(store).len() >= 2
    }

    /// Our devices other than this one that the chain authorizes now.
    pub fn other_device_keys(&self, store: &Store) -> Vec<[u8; 32]> {
        let me = self.device_key();
        self.own_devices(store)
            .into_iter()
            .filter(|d| d.state == DeviceState::Authorized && d.device_key != me)
            .map(|d| d.device_key)
            .collect()
    }

    pub(super) fn own_chain_fingerprint(&self, store: &Store) -> [u8; 32] {
        let mut index = Vec::new();
        for device in self.own_devices(store) {
            index.extend_from_slice(&device.device_key);
            index.extend_from_slice(format!("{}|{}|{}|", device.state as i64, device.name, device.system).as_bytes());
        }
        super::digest(&index)
    }

    pub fn own_devices_secret(&self, store: &Store) -> Option<Vec<u8>> {
        sync_log::state_bytes(&store.conn, STATE_DEVICES_SECRET).ok().flatten().filter(|s| s.len() == 32)
    }

    /// The own-devices secret, drawn now when this is the first device (or the first was revoked) and none exists.
    pub fn ensure_own_devices_secret(&self, store: &Store) -> Option<Vec<u8>> {
        let held = self.own_devices_secret(store);
        if held.is_some() || !self.is_active(store) {
            return held;
        }
        let me = self.device_key();
        let draws = self
            .own_devices(store)
            .iter()
            .rfind(|d| d.is_root)
            .is_some_and(|root| root.device_key == me || root.state != DeviceState::Authorized);
        if !draws {
            return None;
        }
        let mut secret = vec![0u8; 32];
        szfriends_crypto::random_bytes(&mut secret);
        sync_log::set_state(&store.conn, STATE_DEVICES_SECRET, secret.clone().into()).ok()?;
        Some(secret)
    }

    pub(super) fn reset_counters(&mut self) {
        self.next_seq = 0;
    }

    /// Signs and appends one event of ours (inside the caller's transaction).
    pub(super) fn record(
        &mut self,
        conn: &Connection,
        kind: Kind,
        scope: &str,
        subject: &str,
        body: &[u8],
    ) -> Result<Event, SyncError> {
        let root = devices::root_for_device(conn, &self.device_key())?.ok_or(SyncError::Inactive)?;
        if body.len() > BODY_MAX || !label_is_valid(scope) || !label_is_valid(subject) {
            return Err(SyncError::Malformed("an event outside its limits"));
        }
        if self.next_seq == 0 {
            self.next_seq = sync_log::vector(conn)?.get(&self.device_key()).copied().unwrap_or(0) + 1;
            self.lamport = sync_log::lamport(conn)?;
        }
        let event = Event::signed(
            &self.identity,
            &root,
            kind,
            self.next_seq,
            self.lamport + 1,
            (self.clock)(),
            scope,
            subject,
            body,
        );
        // Our own change is already in the store.
        if !sync_log::append_event(conn, &event.log_event(true))? {
            self.next_seq = 0;
            return Err(SyncError::OutOfOrder);
        }
        self.next_seq += 1;
        self.lamport += 1;
        Ok(event)
    }

    /// Records events for everything that changed in the store since the last capture. Returns how many.
    pub fn capture_local_changes(&mut self, store: &Store) -> usize {
        if !self.is_active(store) {
            return 0;
        }
        self.next_seq = 0;
        let recorded = self.capture_changes(store);
        self.next_seq = 0;
        if recorded > 0 {
            self.note_new_events();
        }
        recorded
    }

    /// Events from another of our devices, each author's in order: verified (by the caller), appended, applied.
    /// Stops at the first that fails; the ones before it are kept.
    pub fn receive_events(&mut self, store: &Store, events: &[Event]) -> Result<(), SyncError> {
        let devices = self.own_devices(store);
        if devices.len() < 2 {
            return Err(SyncError::Inactive);
        }
        let state_of = |key: &[u8; 32]| devices.iter().find(|d| &d.device_key == key).map(|d| d.state);
        let revoked: BTreeSet<[u8; 32]> =
            devices.iter().filter(|d| d.state == DeviceState::Revoked).map(|d| d.device_key).collect();
        self.capture_local_changes(store);
        let mut coverage = None;
        let mut beyond: BTreeSet<[u8; 32]> = BTreeSet::new();
        let mut clock = sync_log::lamport(&store.conn)?;
        let mut result = Ok(());
        let mut appended_any = false;
        for event in events {
            match state_of(&event.author) {
                Some(DeviceState::Void) => continue,
                Some(DeviceState::Authorized) => {}
                Some(DeviceState::Revoked) => {
                    let coverage = coverage.get_or_insert_with(|| self.revocation_coverage(store, events, &revoked));
                    let covered = coverage.get(&event.author).copied();
                    if beyond.contains(&event.author) || covered.is_none_or(|c| event.seq > c) {
                        beyond.insert(event.author);
                        continue;
                    }
                }
                None => {
                    result = Err(SyncError::Unauthorized);
                    break;
                }
            }
            if event.lamport > clock && event.lamport - clock > LAMPORT_MARGIN {
                result = Err(SyncError::Forged("an event whose clock is far ahead of ours"));
                break;
            }
            match sync_log::append_event(&store.conn, &event.log_event(false)) {
                Ok(appended) => {
                    appended_any |= appended;
                    if appended && event.lamport > clock {
                        clock = event.lamport;
                    }
                }
                Err(_) => {
                    result = Err(SyncError::OutOfOrder);
                    break;
                }
            }
        }
        self.next_seq = 0;
        if appended_any {
            self.apply_pending_events(store);
            self.note_new_events();
        }
        result
    }

    /// Applies events waiting on something not here yet. Returns how many applied.
    pub fn apply_pending_events(&mut self, store: &Store) -> usize {
        let mut total = 0;
        self.tombstones = None;
        loop {
            let pending = sync_log::unapplied_events(&store.conn).unwrap_or_default();
            let mut applied = 0;
            let mut batch: Vec<Event> = Vec::new();
            for log in &pending {
                let Some(event) = Event::from_log(log) else { continue };
                if self.applies_alone(store, &event) {
                    applied += self.apply_batch(store, &batch);
                    batch.clear();
                    let done = self.apply_event(store, &event) == super::apply::Applied::Done
                        && sync_log::mark_applied(&store.conn, &event.author, event.seq).is_ok();
                    if done {
                        applied += 1;
                        // A removal record may have taken events further down this list from the log.
                        if event.kind == Kind::Revocation {
                            break;
                        }
                    }
                    continue;
                }
                batch.push(event);
                if batch.len() == APPLY_BATCH {
                    applied += self.apply_batch(store, &batch);
                    batch.clear();
                }
            }
            applied += self.apply_batch(store, &batch);
            total += applied;
            if applied == 0 {
                break;
            }
        }
        for conversation in self.changed.clone() {
            self.recount_unread(store, &conversation);
        }
        self.flush_changes();
        total
    }

    /// Deletions compact the database, which no transaction may surround; the profile and settings are rare.
    fn applies_alone(&mut self, store: &Store, event: &Event) -> bool {
        match event.kind {
            Kind::Tombstone | Kind::Profile | Kind::Setting | Kind::Revocation | Kind::Chain => true,
            Kind::Item => {
                if event.body.is_none() {
                    return true;
                }
                let named = event.fields().and_then(|f| f.string(super::TAG_CONVERSATION));
                self.conversation_for_scope(store, &event.scope, named.as_deref())
                    .is_some_and(|c| self.tombstone_covers(store, event, &c))
            }
            _ => false,
        }
    }

    fn apply_batch(&mut self, store: &Store, batch: &[Event]) -> usize {
        if batch.is_empty() {
            return 0;
        }
        let mut applied = 0;
        let committed = atomically(&store.conn, |conn| {
            for event in batch {
                if self.apply_event(store, event) != super::apply::Applied::Done {
                    continue;
                }
                sync_log::mark_applied(conn, &event.author, event.seq)?;
                applied += 1;
            }
            Ok(())
        });
        if committed.is_ok() {
            applied
        } else {
            0
        }
    }

    /// "Erase chat history" (`None`: every chat): a tombstone for what this device has, applied here at once.
    pub fn delete_history(&mut self, store: &Store, conversation: Option<&str>) -> Result<(), SyncError> {
        if !self.is_active(store) {
            return Err(SyncError::Inactive);
        }
        self.capture_local_changes(store);
        let scope = match conversation {
            Some(id) => {
                let person =
                    sync_records::sync_person_with_conversation(&store.conn, id)?.ok_or(StoreError::NotFound)?;
                ref_for_person(&person)
            }
            None => String::new(),
        };
        let mut fields = Fields::new();
        fields.set_string(super::TAG_CONVERSATION, conversation);
        fields.set_data(2, Some(&encode_vector(&sync_log::vector(&store.conn)?)));
        self.next_seq = 0;
        let tombstone =
            atomically(&store.conn, |conn| Ok(self.record(conn, Kind::Tombstone, &scope, "", &fields.encode())));
        self.next_seq = 0;
        let tombstone = tombstone??;
        self.tombstones = None;
        if !self.apply_tombstone(store, &tombstone) {
            return Err(SyncError::Malformed("the deletion did not apply"));
        }
        self.flush_changes();
        self.note_new_events();
        Ok(())
    }

    pub fn vector(&self, store: &Store) -> Vector {
        sync_log::vector(&store.conn).unwrap_or_default()
    }

    /// Authors whose events we pass on: devices our chain authorizes or removed.
    fn authors_offered(&self, store: &Store) -> BTreeSet<[u8; 32]> {
        self.own_devices(store)
            .into_iter()
            .filter(|d| matches!(d.state, DeviceState::Authorized | DeviceState::Revoked))
            .map(|d| d.device_key)
            .collect()
    }

    /// What we hold of the devices whose events we pass on.
    pub fn offered_vector(&self, store: &Store) -> Vector {
        let authors = self.authors_offered(store);
        self.vector(store).into_iter().filter(|(a, _)| authors.contains(a)).collect()
    }

    /// Events `vector` lacks, each author's in order; a void device's are never offered.
    pub fn events_missing_from(&self, store: &Store, vector: &Vector, limit: usize) -> Vec<Event> {
        let authors = self.authors_offered(store);
        let mut asked = vector.clone();
        for author in self.vector(store).keys() {
            if !authors.contains(author) {
                asked.insert(*author, u64::MAX);
            }
        }
        sync_log::events_missing_from(&store.conn, &asked, limit)
            .unwrap_or_default()
            .iter()
            .filter_map(Event::from_log)
            .collect()
    }

    /// This device's conversation for an event's scope and the id its author used; `None` when not here yet.
    pub(super) fn conversation_for_scope(&self, store: &Store, scope: &str, named: Option<&str>) -> Option<String> {
        let conn = &store.conn;
        if scope == YOU {
            return crate::store::sync_history::ensure_you_conversation(conn).ok().map(|_| YOU.to_owned());
        }
        if let Some(hex) = scope.strip_prefix("k:") {
            let key = super::from_hex(hex).filter(|k| k.len() == 32)?;
            if let Some(person) = sync_records::sync_person_with_identity_key(conn, &key).ok().flatten() {
                return Some(person.conversation_id);
            }
            let named = named.and_then(|n| sync_records::sync_person_with_conversation(conn, n).ok().flatten())?;
            return named.identity_key.is_none().then_some(named.conversation_id);
        }
        if let Some(id) = scope.strip_prefix("c:") {
            if sync_records::sync_person_with_conversation(conn, id).ok().flatten().is_some() {
                return Some(id.to_owned());
            }
            let named = named?;
            return sync_records::sync_person_with_conversation(conn, named).ok().flatten().map(|_| named.to_owned());
        }
        None
    }

    pub(super) fn note_changed(&mut self, conversation: Option<&str>) {
        match conversation {
            Some(id) => {
                self.changed.insert(id.to_owned());
            }
            None => self.profile_changed = true,
        }
    }

    pub(super) fn flush_changes(&mut self) {
        if self.changed.is_empty() && !self.profile_changed {
            return;
        }
        self.changes.push(std::mem::take(&mut self.changed));
        self.profile_changed = false;
    }
}
