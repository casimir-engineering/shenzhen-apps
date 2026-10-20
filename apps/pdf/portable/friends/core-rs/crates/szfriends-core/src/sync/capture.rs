//! Capture (`SZFriendsSyncCapture.m`): what changed in the store since the last look becomes events of ours. Each
//! value is compared with the register sync keeps for it, so a value another device's event wrote is not sent back,
//! and a change made while sync was off (or before a crash) is found the next time. History items are found by having
//! no origin yet, oldest first, in batches.

use std::collections::BTreeMap;

use rusqlite::types::Value;

use super::bodies::{file_body, file_from_transfer, file_state_is_final, item_body, outbox_body, person_group_body};
use super::bodies::{profile_body, read_body};
use super::codec::Fields;
use super::engine::SyncEngine;
use super::files::holds_transfer;
use super::{person_key, read_key, ref_for_person, Kind, BODY_MAX, PERSON_GROUPS, SETTING_DEVICES, SETTING_PRESENCE};
use super::{SETTING_RENEWED, STATE_RENEWED, TAG_CONVERSATION, TAG_RELEASED};
use crate::store::devices;
use crate::store::sync_files::{self, SyncFile};
use crate::store::sync_log::{self, atomically, Register, CAPTURE_ROW_KEY, YOU};
use crate::store::sync_records::{self, Picture, SyncPerson};
use crate::store::{sync_history, Store};

/// History items turned into events per transaction.
const CAPTURE_BATCH: usize = 400;

/// One event to record, the register it updates, the item it is an origin of and the file record saved with it.
struct Pending {
    kind: Kind,
    scope: String,
    subject: String,
    body: Vec<u8>,
    register: Option<(String, Vec<u8>)>,
    origin: Option<String>,
    file: Option<SyncFile>,
}

fn pending(kind: Kind, scope: &str, subject: &str, body: Vec<u8>) -> Pending {
    Pending {
        kind,
        scope: scope.to_owned(),
        subject: subject.to_owned(),
        body,
        register: None,
        origin: None,
        file: None,
    }
}

fn same_value(current: Option<&Register>, value: &[u8]) -> bool {
    current.and_then(|r| r.value.as_deref()) == Some(value)
}

impl SyncEngine {
    pub(super) fn capture_changes(&mut self, store: &Store) -> usize {
        let profile_wide = self.pending_profile_wide(store);
        let mut count = self.commit(store, profile_wide);
        let conn = &store.conn;
        let registers = sync_log::registers_with_prefix(conn, "p/").unwrap_or_default();
        let mut people: BTreeMap<String, SyncPerson> = BTreeMap::new();
        let mut list = Vec::new();
        for person in sync_records::sync_people(conn, "", None).unwrap_or_default() {
            if person.conversation_id != YOU {
                add_person_changes(&person, &registers, &mut list);
            }
            people.insert(person.conversation_id.clone(), person);
        }
        count += self.commit(store, list);
        count += self.capture_items(store, &people);
        let mut list = Vec::new();
        self.add_file_changes(store, &people, &mut list);
        add_outbox_changes(store, &people, &mut list);
        add_read_changes(store, &people, &mut list);
        count + self.commit(store, list)
    }

    fn commit(&mut self, store: &Store, list: Vec<Pending>) -> usize {
        // A value too large for one event stays on this device rather than holding back everything recorded with it.
        let list: Vec<Pending> = list.into_iter().filter(|p| p.body.len() <= BODY_MAX).collect();
        if list.is_empty() {
            return 0;
        }
        let result = atomically(&store.conn, |conn| {
            for item in &list {
                let event = self
                    .record(conn, item.kind, &item.scope, &item.subject, &item.body)
                    .map_err(|_| crate::store::StoreError::Invalid("not recorded"))?;
                if let Some((key, value)) = &item.register {
                    let register =
                        Register { lamport: event.lamport, author: event.author.to_vec(), value: Some(value.clone()) };
                    sync_log::set_register(conn, key, &register)?;
                }
                if let Some(conversation) = &item.origin {
                    sync_history::add_origin(conn, &item.subject, conversation, &event.author, event.seq)?;
                }
                if let Some(file) = &item.file {
                    sync_files::save_sync_file(conn, file)?;
                }
            }
            Ok(())
        });
        if result.is_err() {
            self.reset_counters(); // a rolled-back batch leaves the counters ahead of the log
            return 0;
        }
        list.len()
    }

    fn pending_profile_wide(&mut self, store: &Store) -> Vec<Pending> {
        let conn = &store.conn;
        let mut list = Vec::new();
        let fingerprint = self.own_chain_fingerprint(store);
        if !same_value(sync_log::register(conn, "chain").ok().flatten().as_ref(), &fingerprint) {
            let encoded = devices::own_chain(conn).ok().flatten().map(|c| c.encoded().to_vec());
            if let Some(encoded) = encoded.filter(|e| e.len() + 3 <= BODY_MAX) {
                let mut fields = Fields::new();
                fields.set_data(2, Some(&encoded));
                let mut event = pending(Kind::Chain, "", "", fields.encode());
                event.register = Some(("chain".into(), fingerprint.to_vec()));
                list.push(event);
            }
        }
        let (name, picture) = sync_records::profile(conn).unwrap_or((None, Picture::placeholder()));
        let profile = profile_body(name.as_deref(), &picture, false);
        let held = sync_log::register(conn, "profile").ok().flatten();
        // A device that just joined has an empty profile until the profile's own reaches it: not a change.
        let empty = name.is_none() && picture.kind == Picture::PLACEHOLDER;
        let never = held.as_ref().is_none_or(|h| h.value.is_none());
        if !(same_value(held.as_ref(), &profile) || (never && empty)) {
            let mut event = pending(Kind::Profile, "", "", profile_body(name.as_deref(), &picture, true));
            event.register = Some(("profile".into(), profile));
            list.push(event);
        }
        self.ensure_own_devices_secret(store);
        let presence = sync_records::own_presence_secret(conn).ok().flatten().unwrap_or_default();
        let devices_secret = self.own_devices_secret(store).unwrap_or_default();
        let renewed = sync_log::state_bytes(conn, STATE_RENEWED).ok().flatten().unwrap_or_default();
        // Sorted by name, as the helper walks them.
        for (name, value) in
            [(SETTING_DEVICES, devices_secret), (SETTING_PRESENCE, presence), (SETTING_RENEWED, renewed)]
        {
            if value.len() != 32 {
                continue;
            }
            let mut fields = Fields::new();
            fields.set_data(2, Some(&value));
            let key = format!("s/{name}");
            if same_value(sync_log::register(conn, &key).ok().flatten().as_ref(), &fields.encode()) {
                continue;
            }
            let mut event = pending(Kind::Setting, "", name, fields.encode());
            event.register = Some((key, fields.encode()));
            list.push(event);
        }
        list
    }

    fn capture_items(&mut self, store: &Store, people: &BTreeMap<String, SyncPerson>) -> usize {
        let conn = &store.conn;
        let mut count = 0;
        let mut row = match sync_log::state(conn, CAPTURE_ROW_KEY) {
            Ok(Value::Integer(row)) => row,
            Ok(Value::Real(row)) => row as i64,
            _ => 0,
        };
        while let Ok((items, last)) = sync_history::items_without_origin(conn, row, CAPTURE_BATCH) {
            if items.is_empty() {
                break;
            }
            let mut list = Vec::new();
            for item in items {
                let Some(person) = people.get(&item.conversation_id) else { continue };
                let mut event = pending(Kind::Item, &ref_for_person(person), &item.item_id, item_body(&item));
                event.origin = Some(item.conversation_id.clone());
                list.push(event);
            }
            let attempted = list.len();
            let recorded = self.commit(store, list);
            if recorded == 0 && attempted > 0 {
                break; // the store refused; the next capture tries again
            }
            count += recorded;
            row = last;
            let _ = sync_log::set_state(conn, CAPTURE_ROW_KEY, Value::Integer(row));
        }
        count
    }

    fn add_file_changes(&self, store: &Store, people: &BTreeMap<String, SyncPerson>, list: &mut Vec<Pending>) {
        let conn = &store.conn;
        let me = self.device_key();
        let registers = sync_log::registers_with_prefix(conn, "f/").unwrap_or_default();
        let records: BTreeMap<String, SyncFile> =
            sync_files::sync_files(conn).unwrap_or_default().into_iter().map(|f| (f.transfer_id.clone(), f)).collect();
        for transfer in sync_files::all_transfers(conn).unwrap_or_default() {
            let Some(person) = people.get(&transfer.conversation_id) else { continue };
            let scope = ref_for_person(person);
            let known = records.get(&transfer.transfer_id);
            let item_id = known.and_then(|k| k.item_id.clone()).or_else(|| {
                sync_files::item_id_for_transfer(conn, &transfer.transfer_id, &transfer.conversation_id).ok().flatten()
            });
            let mut file = file_from_transfer(&transfer, item_id);
            file.holders = known.map(|k| k.holders.clone()).unwrap_or_default();
            let key = format!("f/{}", transfer.transfer_id);
            let value = file_body(&file);
            let current = registers.get(&key);
            let held = current.and_then(|r| r.value.as_deref()).and_then(Fields::decode);
            let held_final = held.is_some_and(|h| file_state_is_final(h.u64(4) as i64));
            let regresses = held_final && !file_state_is_final(file.state);
            let changed = !same_value(current, &value) && !regresses;
            // Whether this device has the bytes now (ADR 0016): it says so when that changes, either way.
            let here = holds_transfer(store, &transfer);
            let listed = file.holders.contains(&me);
            let holds = here && !listed;
            let released = !here && listed && known.is_some();
            if holds {
                file.holders.push(me);
            }
            if released {
                file.holders.retain(|h| *h != me);
            }
            if changed {
                let mut event = pending(Kind::File, &scope, &transfer.transfer_id, value.clone());
                event.register = Some((key, value));
                event.file = Some(file.clone());
                list.push(event);
            }
            if holds || released {
                let mut fields = Fields::new();
                fields.set_string(TAG_CONVERSATION, Some(&transfer.conversation_id));
                if released {
                    fields.set_u64(TAG_RELEASED, 1);
                }
                let mut event = pending(Kind::FileHeld, &scope, &transfer.transfer_id, fields.encode());
                event.file = Some(file);
                list.push(event);
            }
        }
    }
}

fn add_person_changes(person: &SyncPerson, registers: &BTreeMap<String, Register>, list: &mut Vec<Pending>) {
    let scope = ref_for_person(person);
    for group in PERSON_GROUPS {
        let key = person_key(&person.conversation_id, group);
        let value = person_group_body(person, group, false);
        if same_value(registers.get(&key), &value) {
            continue;
        }
        let mut event = pending(Kind::Person, &scope, group, person_group_body(person, group, true));
        event.register = Some((key, value));
        list.push(event);
    }
}

fn add_read_changes(store: &Store, people: &BTreeMap<String, SyncPerson>, list: &mut Vec<Pending>) {
    let conn = &store.conn;
    let registers = sync_log::registers_with_prefix(conn, "r/").unwrap_or_default();
    // NSDictionary order is not part of the format: the events' order follows conversation ids here.
    for person in people.values() {
        if person.unread_count < 0 {
            continue;
        }
        let newest = sync_history::incoming_item(conn, &person.conversation_id, person.unread_count as u64);
        let Some(newest) = newest.ok().flatten() else { continue };
        let key = read_key(&person.conversation_id);
        let held = registers.get(&key).and_then(|r| r.value.as_deref()).and_then(Fields::decode);
        if let Some(held_at) = held.as_ref().and_then(|h| h.date(2)) {
            let held_id = held.as_ref().and_then(|h| h.string(3)).unwrap_or_default();
            if newest.received_at < held_at
                || (newest.received_at == held_at && newest.item_id.as_str() <= held_id.as_str())
            {
                continue;
            }
        }
        let body = read_body(&person.conversation_id, newest.received_at, &newest.item_id);
        let mut event = pending(Kind::Read, &ref_for_person(person), "", body.clone());
        event.register = Some((key, body));
        list.push(event);
    }
}

fn add_outbox_changes(store: &Store, people: &BTreeMap<String, SyncPerson>, list: &mut Vec<Pending>) {
    let conn = &store.conn;
    let registers = sync_log::registers_with_prefix(conn, "o/").unwrap_or_default();
    for entry in sync_files::syncable_outbox_entries(conn).unwrap_or_default() {
        let Some(person) = people.get(&entry.conversation_id) else { continue };
        if entry.conversation_id == YOU {
            continue;
        }
        let key = format!("o/{}", entry.entry_id);
        let value = outbox_body(&entry);
        let current = registers.get(&key);
        if same_value(current, &value) {
            continue;
        }
        let held = current.and_then(|r| r.value.as_deref()).and_then(Fields::decode);
        // Delivered elsewhere is final: a local Queued copy must not say otherwise.
        if held.is_some_and(|h| h.u64(3) == 3) && entry.state != 3 {
            continue;
        }
        let mut event = pending(Kind::Outbox, &ref_for_person(person), &entry.entry_id, value.clone());
        event.register = Some((key, value));
        list.push(event);
    }
}
