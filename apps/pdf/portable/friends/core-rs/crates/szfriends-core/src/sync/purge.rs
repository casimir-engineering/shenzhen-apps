//! A removed device's late events (`SZFriendsSyncPurge.m`): a device that heard the removed one before it heard the
//! removal record drops what the record does not cover. Their items go as erased history goes, and every value one of
//! them was the last to write is worked out again from the events that remain, so every device ends alike.

use std::collections::{BTreeMap, BTreeSet};

use super::codec::Event;
use super::engine::SyncEngine;
use super::{person_key, read_key, Kind};
use crate::store::sync_log::{self, Register};
use crate::store::sync_records::{self, Picture};
use crate::store::{sync_files, sync_history, Store};

impl SyncEngine {
    /// The register an event of these kinds writes, by this device's names.
    fn register_key_of(&self, store: &Store, event: &Event) -> Option<String> {
        match event.kind {
            Kind::Profile => Some("profile".into()),
            Kind::Setting => Some(format!("s/{}", event.subject)),
            Kind::Outbox => Some(format!("o/{}", event.subject)),
            Kind::File => Some(format!("f/{}", event.subject)),
            Kind::Person | Kind::Read => {
                let named = event.fields().and_then(|f| f.string(super::TAG_CONVERSATION));
                let conversation = self.conversation_for_scope(store, &event.scope, named.as_deref())?;
                Some(if event.kind == Kind::Read {
                    read_key(&conversation)
                } else {
                    person_key(&conversation, &event.subject)
                })
            }
            _ => None,
        }
    }

    pub(super) fn drop_events_of_device(&mut self, store: &Store, device: &[u8; 32], covered: u64) -> bool {
        let conn = &store.conn;
        let late = sync_log::events_of_author_after(conn, device, covered).unwrap_or_default();
        if late.is_empty() {
            return true;
        }
        // A change made here and not yet recorded becomes an event of ours first, so it stays the last writer.
        self.capture_local_changes(store);
        let mut written: BTreeMap<String, Kind> = BTreeMap::new();
        let mut held = BTreeSet::new();
        for log in &late {
            let Some(event) = Event::from_log(log) else { continue };
            if event.kind == Kind::FileHeld {
                held.insert(event.subject.clone());
            }
            let Some(key) = self.register_key_of(store, &event) else { continue };
            let current = sync_log::register(conn, &key).ok().flatten();
            if current.is_some_and(|c| c.author == device.as_slice() && c.lamport == event.lamport) {
                written.insert(key, event.kind);
            }
        }
        let touched = sync_history::purge_events_of_author(
            conn,
            store.state_dir(),
            device,
            covered,
            Kind::File as i64,
            Kind::Outbox as i64,
        );
        let Ok(touched) = touched else { return false };
        self.tombstones = None;
        for id in &touched {
            self.note_changed(Some(id));
        }
        // It no longer holds what it claimed to after its removal.
        for transfer in held {
            let Some(mut file) = sync_files::sync_file(conn, &transfer).ok().flatten() else { continue };
            if !file.holders.contains(device) {
                continue;
            }
            file.holders.retain(|h| h != device);
            let _ = sync_files::save_sync_file(conn, &file);
            self.note_changed(Some(&file.conversation_id.clone()));
        }
        for (key, kind) in written {
            self.rederive_register(store, &key, kind);
        }
        for conversation in self.changed.clone() {
            self.recount_unread(store, &conversation);
        }
        self.flush_changes();
        true
    }

    /// The value of `key` as the events left would have made it, or never written when none is left.
    fn rederive_register(&mut self, store: &Store, key: &str, kind: Kind) {
        let mut candidates: Vec<Event> = sync_log::events_of_kind(&store.conn, kind as i64)
            .unwrap_or_default()
            .iter()
            .filter(|log| log.body.is_some() && log.applied)
            .filter_map(Event::from_log)
            .filter(|event| self.register_key_of(store, event).as_deref() == Some(key))
            .collect();
        let never = Register::default();
        if sync_log::set_register(&store.conn, key, &never).is_err() {
            return;
        }
        if candidates.is_empty() {
            if kind == Kind::Profile {
                let _ = sync_records::set_profile(&store.conn, None, &Picture::placeholder());
                self.note_changed(None);
            } else if kind == Kind::Read {
                let conversation = key.strip_prefix("r/").unwrap_or_default().to_owned();
                self.note_changed(Some(&conversation));
            }
            return;
        }
        candidates.sort_by(|a, b| a.lamport.cmp(&b.lamport).then(a.author.cmp(&b.author)));
        for event in &candidates {
            self.apply_event(store, event);
        }
    }
}
