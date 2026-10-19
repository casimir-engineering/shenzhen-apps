//! The merge rules (`SZFriendsSyncApply.m`): what each kind of event changes, so any order of arrival leaves every
//! device with the same store. Items: present unless a deletion covers one of the events that carried them; read
//! markers: the latest (received time, id); people's field groups, the profile and settings: the latest (Lamport
//! clock, author); outbox entries: delivered wins, then the latest; file records: delivered or received wins, then the
//! latest; who holds a file's bytes: the union.

use szfriends_identity::chain::DeviceChain;

use super::bodies::{
    apply_person_group, file_body, file_from_body, file_state_is_final, get_picture, item_from_body, outbox_body,
    outbox_from_body, person_group_body, profile_body, read_body,
};
use super::codec::{decode_vector, vector_covers, Event, Fields};
use super::engine::{SyncEngine, Tombstone};
use super::{
    is_later, person_key, read_key, Kind, GROUP_RELATION, PERSON_GROUPS, SETTING_DEVICES, SETTING_PRESENCE,
    SETTING_RENEWED, STATE_PRESENCE_DRAWN, STATE_PRESENCE_RETELL, STATE_RENEWED, TAG_CONVERSATION,
};
use crate::store::devices::{self, ChainMerge};
use crate::store::sync_log::{self, Register, Vector, YOU};
use crate::store::sync_records::{self, Picture, SyncPerson};
use crate::store::{sync_files, sync_history, Store, StoreError};

const FILE_KIND: i64 = Kind::File as i64;
const OUTBOX_KIND: i64 = Kind::Outbox as i64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Applied {
    /// Applied, or nothing to do: mark it applied.
    Done,
    /// Needs something not here yet; try again later.
    Wait,
    /// A store error; try again later.
    Failed,
}

fn done_if(ok: bool) -> Applied {
    if ok {
        Applied::Done
    } else {
        Applied::Failed
    }
}

impl SyncEngine {
    pub(super) fn apply_event(&mut self, store: &Store, event: &Event) -> Applied {
        let Some(body) = &event.body else { return self.apply_bodiless(store, event) };
        let Some(fields) = Fields::decode(body) else { return Applied::Done };
        match event.kind {
            Kind::Chain => self.apply_chain(store, event, &fields),
            Kind::Profile => self.apply_profile(store, event, &fields),
            Kind::Setting => self.apply_setting(store, event, &fields),
            Kind::Person => self.apply_person(store, event, &fields),
            Kind::Item => self.apply_item(store, event, &fields),
            Kind::Read => self.apply_read(store, event, &fields),
            Kind::Outbox => self.apply_outbox(store, event, &fields),
            Kind::File => self.apply_file(store, event, &fields),
            Kind::FileHeld => self.apply_file_held(store, event),
            Kind::Tombstone => done_if(self.apply_tombstone(store, event)),
            Kind::Revocation => self.apply_revocation(store, event),
        }
    }

    /// A deletion dropped this body on the device we had it from: an item in it is deleted here too.
    fn apply_bodiless(&mut self, store: &Store, event: &Event) -> Applied {
        if event.kind != Kind::Item {
            return Applied::Done;
        }
        let Some(conversation) = self.conversation_for_scope(store, &event.scope, None) else { return Applied::Wait };
        let ok = sync_history::mark_deleted_item(
            &store.conn,
            store.state_dir(),
            &event.subject,
            &conversation,
            FILE_KIND,
            OUTBOX_KIND,
        )
        .is_ok();
        self.note_changed(Some(&conversation));
        done_if(ok)
    }

    pub(super) fn set_register(&self, store: &Store, key: &str, event: &Event, value: Vec<u8>) -> Applied {
        let entry = Register { lamport: event.lamport, author: event.author.to_vec(), value: Some(value) };
        done_if(sync_log::set_register(&store.conn, key, &entry).is_ok())
    }

    fn apply_chain(&mut self, store: &Store, event: &Event, fields: &Fields) -> Applied {
        let root = self.root_key(store);
        let chain = match (root, fields.data(2)) {
            (Some(root), Some(data)) => DeviceChain::decode(data, Some(&root)).ok(),
            _ => None,
        };
        let Some(chain) = chain else { return Applied::Done };
        match devices::merge_own_chain(&store.conn, &chain) {
            Err(_) => return Applied::Done,
            Ok(ChainMerge::Changed) => self.note_changed(None),
            Ok(ChainMerge::Unchanged) => {}
        }
        let fingerprint = self.own_chain_fingerprint(store);
        self.set_register(store, "chain", event, fingerprint.to_vec())
    }

    pub(super) fn picture_from(&self, fields: &Fields, base: u8) -> Picture {
        match get_picture(fields, base) {
            (_, Some(photo)) => {
                self.store_picture.as_ref().and_then(|s| s(&photo)).unwrap_or_else(Picture::placeholder)
            }
            (picture, None) => picture,
        }
    }

    fn apply_profile(&mut self, store: &Store, event: &Event, fields: &Fields) -> Applied {
        let held = sync_log::register(&store.conn, "profile").ok().flatten();
        if !is_later(event.lamport, &event.author, held.as_ref()) {
            return Applied::Done;
        }
        let picture = self.picture_from(fields, 5);
        if sync_records::set_profile(&store.conn, fields.string(2).as_deref(), &picture).is_err() {
            return Applied::Failed;
        }
        self.note_changed(None);
        let (name, picture) = sync_records::profile(&store.conn).unwrap_or((None, Picture::placeholder()));
        self.set_register(store, "profile", event, profile_body(name.as_deref(), &picture, false))
    }

    fn apply_setting(&mut self, store: &Store, event: &Event, fields: &Fields) -> Applied {
        let key = format!("s/{}", event.subject);
        let held = sync_log::register(&store.conn, &key).ok().flatten();
        if !is_later(event.lamport, &event.author, held.as_ref()) {
            return Applied::Done;
        }
        let Some(value) = fields.data(2).filter(|v| v.len() == 32) else { return Applied::Done };
        let conn = &store.conn;
        match event.subject.as_str() {
            SETTING_PRESENCE => {
                // Another device's draw beat the one this device told friends: they hear the winner from here too.
                if sync_log::state_bytes(conn, STATE_PRESENCE_DRAWN).ok().flatten().is_some_and(|d| d != value) {
                    let _ = sync_log::set_state(conn, STATE_PRESENCE_DRAWN, rusqlite::types::Value::Null);
                    let _ = sync_log::set_state(conn, STATE_PRESENCE_RETELL, 1i64.into());
                }
                if sync_records::set_own_presence_secret(conn, Some(value)).is_err() {
                    return Applied::Failed;
                }
            }
            SETTING_DEVICES => {
                if !self.replace_own_devices_secret(store, value) {
                    return Applied::Failed;
                }
            }
            SETTING_RENEWED => {
                if sync_log::set_state(conn, STATE_RENEWED, value.to_vec().into()).is_err() {
                    return Applied::Failed;
                }
            }
            _ => return Applied::Done,
        }
        self.note_changed(None);
        self.set_register(store, &key, event, fields.encode())
    }

    fn apply_person(&mut self, store: &Store, event: &Event, fields: &Fields) -> Applied {
        let group = event.subject.as_str();
        if !PERSON_GROUPS.contains(&group) {
            return Applied::Done;
        }
        let conn = &store.conn;
        let named = fields.string(TAG_CONVERSATION);
        let conversation = self.conversation_for_scope(store, &event.scope, named.as_deref());
        let found = conversation.and_then(|c| sync_records::sync_person_with_conversation(conn, &c).ok().flatten());
        let created = found.is_none();
        let mut person = match found {
            Some(person) => {
                let held = sync_log::register(conn, &person_key(&person.conversation_id, group)).ok().flatten();
                if !is_later(event.lamport, &event.author, held.as_ref()) {
                    return Applied::Done;
                }
                person
            }
            None => {
                // Someone this device has not met yet: their relation brings them in; anything else waits for it.
                if group != GROUP_RELATION {
                    return Applied::Wait;
                }
                let free = named.as_deref().is_some_and(|n| {
                    !n.is_empty()
                        && n != YOU
                        && sync_records::sync_person_with_conversation(conn, n).ok().flatten().is_none()
                });
                let id = if free { named.clone().unwrap_or_default() } else { String::new() };
                let mut person = SyncPerson::new(id, event.date());
                person.identity_key = event.scope.strip_prefix("k:").and_then(super::from_hex);
                person
            }
        };
        let mut photo = None;
        if !apply_person_group(fields, group, &mut person, &mut photo) {
            return Applied::Done;
        }
        if let Some(photo) = photo {
            person.picture = self.store_picture.as_ref().and_then(|s| s(&photo)).unwrap_or_else(Picture::placeholder);
        }
        if let Err(error) = sync_records::sync_save_person(conn, &mut person) {
            // Refused for good (a key held by someone else, a malformed value): nothing this event can change.
            return if matches!(error, StoreError::Database(_) | StoreError::DiskFull) {
                Applied::Failed
            } else {
                Applied::Done
            };
        }
        let stored =
            sync_records::sync_person_with_conversation(conn, &person.conversation_id).ok().flatten().unwrap_or(person);
        self.note_changed(Some(&stored.conversation_id));
        if created {
            // The groups no event has filled yet hold what a new person has, at clock 0.
            for other in PERSON_GROUPS.iter().filter(|g| **g != group) {
                let empty =
                    Register { lamport: 0, author: Vec::new(), value: Some(person_group_body(&stored, other, false)) };
                let _ = sync_log::set_register(conn, &person_key(&stored.conversation_id, other), &empty);
            }
        }
        self.set_register(
            store,
            &person_key(&stored.conversation_id, group),
            event,
            person_group_body(&stored, group, false),
        )
    }

    fn apply_item(&mut self, store: &Store, event: &Event, fields: &Fields) -> Applied {
        let named = fields.string(TAG_CONVERSATION);
        let Some(conversation) = self.conversation_for_scope(store, &event.scope, named.as_deref()) else {
            return Applied::Wait;
        };
        let conn = &store.conn;
        self.note_changed(Some(&conversation));
        if self.tombstone_covers(store, event, &conversation) {
            let ok = sync_history::mark_deleted_item(
                conn,
                store.state_dir(),
                &event.subject,
                &conversation,
                FILE_KIND,
                OUTBOX_KIND,
            )
            .is_ok()
                && sync_log::drop_body(conn, &event.author, event.seq).is_ok();
            return done_if(ok);
        }
        if sync_history::is_deleted(conn, &event.subject, &conversation).unwrap_or(false) {
            return done_if(sync_log::drop_body(conn, &event.author, event.seq).is_ok());
        }
        let Some(mut item) = item_from_body(fields, &event.subject) else { return Applied::Done };
        item.conversation_id = conversation;
        done_if(sync_history::merge_synced_item(conn, &item, &event.author, event.seq).is_ok())
    }

    fn apply_read(&mut self, store: &Store, event: &Event, fields: &Fields) -> Applied {
        let named = fields.string(TAG_CONVERSATION);
        let Some(conversation) = self.conversation_for_scope(store, &event.scope, named.as_deref()) else {
            return Applied::Wait;
        };
        let (Some(received_at), Some(item_id)) = (fields.date(2), fields.string(3).filter(|s| !s.is_empty())) else {
            return Applied::Done;
        };
        let key = read_key(&conversation);
        let held = sync_log::register(&store.conn, &key).ok().flatten();
        let held = held.and_then(|r| r.value).and_then(|v| Fields::decode(&v));
        if let Some(held_at) = held.as_ref().and_then(|h| h.date(2)) {
            let held_id = held.as_ref().and_then(|h| h.string(3)).unwrap_or_default();
            // The maximum: a marker never moves back.
            if received_at < held_at || (received_at == held_at && item_id.as_str() <= held_id.as_str()) {
                return Applied::Done;
            }
        }
        self.note_changed(Some(&conversation));
        self.set_register(store, &key, event, read_body(&conversation, received_at, &item_id))
    }

    pub(super) fn recount_unread(&self, store: &Store, conversation: &str) {
        let marker = sync_log::register(&store.conn, &read_key(conversation)).ok().flatten();
        let fields = marker.and_then(|m| m.value).and_then(|v| Fields::decode(&v));
        let at = fields.as_ref().and_then(|f| f.date(2));
        let item = fields.as_ref().and_then(|f| f.string(3)).unwrap_or_default();
        let _ = sync_history::recount_unread(&store.conn, conversation, at.map(|at| (at, item.as_str())));
    }

    fn apply_outbox(&mut self, store: &Store, event: &Event, fields: &Fields) -> Applied {
        let named = fields.string(TAG_CONVERSATION);
        let Some(conversation) = self.conversation_for_scope(store, &event.scope, named.as_deref()) else {
            return Applied::Wait;
        };
        let Some(mut entry) = outbox_from_body(fields, &event.subject) else { return Applied::Done };
        entry.conversation_id = conversation.clone();
        let conn = &store.conn;
        if let Some(item_id) = &entry.item_id {
            if sync_history::is_deleted(conn, item_id, &conversation).unwrap_or(false) {
                return Applied::Done;
            }
            // The message it delivers comes first: a sibling builds the frame from it.
            if sync_history::item(conn, &conversation, item_id).ok().flatten().is_none() {
                return Applied::Wait;
            }
        }
        let key = format!("o/{}", event.subject);
        let current = sync_log::register(conn, &key).ok().flatten();
        let held = current.as_ref().and_then(|r| r.value.as_deref()).and_then(Fields::decode);
        let held_delivered = held.is_some_and(|h| h.u64(3) == 3);
        let later = is_later(event.lamport, &event.author, current.as_ref());
        let wins = if entry.state == 3 { !held_delivered } else { !held_delivered && later };
        if !wins {
            return Applied::Done;
        }
        if sync_files::merge_synced_outbox_entry(conn, &entry).is_err() {
            return Applied::Wait;
        }
        self.note_changed(Some(&conversation));
        self.set_register(store, &key, event, outbox_body(&entry))
    }

    fn apply_file(&mut self, store: &Store, event: &Event, fields: &Fields) -> Applied {
        let named = fields.string(TAG_CONVERSATION);
        let Some(conversation) = self.conversation_for_scope(store, &event.scope, named.as_deref()) else {
            return Applied::Wait;
        };
        let Some(mut file) = file_from_body(fields, &event.subject) else { return Applied::Done };
        file.conversation_id = conversation.clone();
        let conn = &store.conn;
        if file.item_id.as_deref().is_some_and(|i| sync_history::is_deleted(conn, i, &conversation).unwrap_or(false)) {
            return done_if(sync_log::drop_body(conn, &event.author, event.seq).is_ok());
        }
        let key = format!("f/{}", event.subject);
        let current = sync_log::register(conn, &key).ok().flatten();
        let held = current.as_ref().and_then(|r| r.value.as_deref()).and_then(Fields::decode);
        let held_final = held.as_ref().is_some_and(|h| file_state_is_final(h.u64(4) as i64));
        let is_final = file_state_is_final(file.state);
        let wins =
            if is_final != held_final { is_final } else { is_later(event.lamport, &event.author, current.as_ref()) };
        if held.is_some() && !wins {
            return Applied::Done;
        }
        file.holders =
            sync_files::sync_file(conn, &file.transfer_id).ok().flatten().map(|f| f.holders).unwrap_or_default();
        if sync_files::save_sync_file(conn, &file).is_err() {
            return Applied::Failed;
        }
        // A copy of a file another of our devices is sending follows that device's record.
        let _ = sync_files::set_state_of_copied_transfer(conn, &file.transfer_id, file.state);
        self.note_changed(Some(&conversation));
        self.set_register(store, &key, event, file_body(&file))
    }

    fn apply_file_held(&mut self, store: &Store, event: &Event) -> Applied {
        let conn = &store.conn;
        let Some(mut file) = sync_files::sync_file(conn, &event.subject).ok().flatten() else {
            // Deleted with its item, or its record has not arrived yet.
            let deleted = sync_log::has_bodiless_event(conn, FILE_KIND, &event.subject).unwrap_or(false);
            return if deleted { Applied::Done } else { Applied::Wait };
        };
        if file.holders.contains(&event.author) {
            return Applied::Done;
        }
        file.holders.push(event.author);
        if sync_files::save_sync_file(conn, &file).is_err() {
            return Applied::Failed;
        }
        self.note_changed(Some(&file.conversation_id));
        Applied::Done
    }

    fn loaded_tombstones(&mut self, store: &Store) -> &Vec<Tombstone> {
        if self.tombstones.is_none() {
            let mut tombstones = Vec::new();
            for log in sync_log::events_of_kind(&store.conn, Kind::Tombstone as i64).unwrap_or_default() {
                let Some(fields) = log.body.as_deref().and_then(Fields::decode) else { continue };
                let Some((vector, _)) = fields.data(2).and_then(decode_vector) else { continue };
                let conversation = fields.string(TAG_CONVERSATION).unwrap_or_default();
                tombstones.push(Tombstone { scope: log.scope.clone(), conversation, vector, lamport: log.lamport });
            }
            self.tombstones = Some(tombstones);
        }
        self.tombstones.as_ref().expect("loaded")
    }

    /// Whether an applied tombstone covers this event in this conversation (events older than it by clock only).
    pub(super) fn tombstone_covers(&mut self, store: &Store, event: &Event, conversation: &str) -> bool {
        let candidates: Vec<(String, String)> = self
            .loaded_tombstones(store)
            .iter()
            .filter(|t| vector_covers(&t.vector, &event.author, event.seq) && event.lamport < t.lamport)
            .map(|t| (t.scope.clone(), t.conversation.clone()))
            .collect();
        candidates.into_iter().any(|(scope, named)| {
            scope.is_empty() || {
                let named = (!named.is_empty()).then_some(named.as_str());
                self.conversation_for_scope(store, &scope, named).as_deref() == Some(conversation)
            }
        })
    }

    /// What a tombstone may take of the events held here: per author, the prefix older than it by clock.
    fn vector_seen_by(&self, store: &Store, tombstone: &Event, claimed: &Vector) -> Vector {
        let held = self.vector(store);
        let mut seen = Vector::new();
        for (author, claimed_seq) in claimed {
            let (mut low, mut high) = (0u64, (*claimed_seq).min(held.get(author).copied().unwrap_or(0)));
            while low < high {
                let middle = low + (high - low).div_ceil(2);
                let log = sync_log::event_with(&store.conn, author, middle).ok().flatten();
                if log.is_some_and(|l| l.lamport < tombstone.lamport) {
                    low = middle;
                } else {
                    high = middle - 1;
                }
            }
            if low > 0 {
                seen.insert(*author, low);
            }
        }
        seen
    }

    pub(super) fn apply_tombstone(&mut self, store: &Store, event: &Event) -> bool {
        self.tombstones = None;
        let fields = event.fields();
        let Some((claimed, _)) = fields.as_ref().and_then(|f| f.data(2)).and_then(decode_vector) else { return true };
        let vector = self.vector_seen_by(store, event, &claimed);
        let mut conversation = None;
        if !event.scope.is_empty() {
            let named = fields.as_ref().and_then(|f| f.string(TAG_CONVERSATION));
            conversation = self.conversation_for_scope(store, &event.scope, named.as_deref());
            if conversation.is_none() {
                return true;
            }
        }
        let touched = sync_history::delete_synced_items(
            &store.conn,
            store.state_dir(),
            conversation.as_deref(),
            &vector,
            FILE_KIND,
            OUTBOX_KIND,
        );
        let Ok(touched) = touched else { return false };
        for id in &touched {
            self.note_changed(Some(id));
            self.recount_unread(store, id);
        }
        if let Some(id) = conversation {
            self.note_changed(Some(&id));
        }
        true
    }
}
