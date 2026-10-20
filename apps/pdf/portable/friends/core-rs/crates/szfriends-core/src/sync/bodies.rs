//! What each event's body says, to and from the store's records (`SZFriendsSyncBodies.m`). Encodings are
//! deterministic, so the register a device keeps for a value compares equal to the value read back from its store.

use super::codec::Fields;
use super::{GROUP_KEYS, GROUP_PROFILE, GROUP_RELATION, GROUP_TRUST, TAG_CONVERSATION};
use crate::store::sync_files::{SyncEntry, SyncFile};
use crate::store::sync_records::{json_arguments, Picture, SyncItem, SyncPerson, SyncTransfer};

/// Largest photo a body carries.
const PHOTO_MAX: usize = 49_152;

fn put_picture(fields: &mut Fields, picture: &Picture, base: u8, full: bool) {
    fields.set_u64(base, picture.kind as u64);
    if picture.kind == Picture::ANIMAL {
        fields.set_u64(base + 1, picture.set as u64);
        fields.set_u64(base + 2, picture.index as u64);
    } else if picture.kind == Picture::IMAGE {
        fields.set_data(base + 3, picture.sha256.as_deref());
        if full {
            if let Some(bytes) = picture.path.as_ref().and_then(|p| std::fs::read(p).ok()) {
                if bytes.len() <= PHOTO_MAX {
                    fields.set_data(base + 4, Some(&bytes));
                }
            }
        }
    }
}

/// The picture a body names; a photo comes back as its bytes, with a placeholder until the caller stores it.
pub fn get_picture(fields: &Fields, base: u8) -> (Picture, Option<Vec<u8>>) {
    let clamp = |v: u64| v.min(i32::MAX as u64) as i64;
    match fields.u64(base) as i64 {
        Picture::ANIMAL => (Picture::animal(clamp(fields.u64(base + 1)), clamp(fields.u64(base + 2))), None),
        Picture::IMAGE => {
            let photo = fields.data(base + 4).filter(|b| !b.is_empty() && b.len() <= PHOTO_MAX).map(<[u8]>::to_vec);
            (Picture::placeholder(), photo)
        }
        _ => (Picture::placeholder(), None),
    }
}

pub fn person_group_body(person: &SyncPerson, group: &str, full: bool) -> Vec<u8> {
    let mut fields = Fields::new();
    fields.set_string(TAG_CONVERSATION, Some(&person.conversation_id));
    match group {
        GROUP_RELATION => {
            fields.set_u64(2, person.relation as u64);
            fields.set_date(3, person.request_at);
            fields.set_u64(4, u64::from(person.request_found_nearby));
            fields.set_u64(5, u64::from(person.auto_accept));
            // Only while off the list, so the body of everyone never taken off it stays as older helpers write it.
            fields.set_date(6, person.left_list_at);
        }
        GROUP_PROFILE => {
            fields.set_string(2, person.name.as_deref());
            fields.set_string(3, person.friends_id.as_deref());
            put_picture(&mut fields, &person.picture, 4, full);
        }
        GROUP_KEYS => {
            fields.set_data(2, person.identity_key.as_deref());
            fields.set_data(3, person.static_key.as_deref());
            fields.set_data(4, person.presence_secret.as_deref());
            fields.set_data(5, person.callback_token.as_deref());
            fields.set_data(6, person.callback_secret.as_deref());
        }
        GROUP_TRUST => {
            fields.set_u64(2, u64::from(person.verified));
            fields.set_date(3, person.verified_at);
            fields.set_string(4, person.comparison_code.as_deref());
        }
        _ => {}
    }
    fields.encode()
}

fn fits(key: Option<&[u8]>, length: usize) -> bool {
    key.is_none_or(|k| k.len() == length)
}

/// Applies a group's fields to `person` (not saved); `false` when malformed. A photo's bytes go to `photo`.
pub fn apply_person_group(fields: &Fields, group: &str, person: &mut SyncPerson, photo: &mut Option<Vec<u8>>) -> bool {
    match group {
        GROUP_RELATION => {
            let relation = fields.u64(2);
            if relation > 4 {
                return false;
            }
            person.relation = relation as i64;
            person.request_at = fields.date(3);
            person.request_found_nearby = fields.u64(4) != 0;
            person.auto_accept = fields.u64(5) != 0;
            person.left_list_at = fields.date(6);
        }
        GROUP_PROFILE => {
            person.name = fields.string(2);
            person.friends_id = fields.string(3);
            let (picture, bytes) = get_picture(fields, 4);
            person.picture = picture;
            *photo = bytes;
        }
        GROUP_KEYS => {
            let (identity, static_key) = (fields.data(2), fields.data(3));
            let (presence, token, callback) = (fields.data(4), fields.data(5), fields.data(6));
            if !fits(identity, 32)
                || !fits(static_key, 32)
                || !fits(presence, 32)
                || !fits(token, 16)
                || !fits(callback, 32)
            {
                return false;
            }
            // Keys only ever arrive: a stored key changes through review alone.
            if person.identity_key.is_none() {
                person.identity_key = identity.map(<[u8]>::to_vec);
            }
            if person.static_key.is_none() {
                person.static_key = static_key.map(<[u8]>::to_vec);
            }
            person.presence_secret = presence.map(<[u8]>::to_vec);
            person.callback_token = token.map(<[u8]>::to_vec);
            person.callback_secret = callback.map(<[u8]>::to_vec);
        }
        GROUP_TRUST => {
            person.verified = fields.u64(2) != 0;
            person.verified_at = fields.date(3);
            person.comparison_code = fields.string(4);
        }
        _ => return false,
    }
    true
}

/// The name and picture; the Friends ID never travels (it is the person's on the host).
pub fn profile_body(name: Option<&str>, picture: &Picture, full: bool) -> Vec<u8> {
    let mut fields = Fields::new();
    fields.set_string(2, name);
    put_picture(&mut fields, picture, 5, full);
    fields.encode()
}

pub fn item_body(item: &SyncItem) -> Vec<u8> {
    let mut fields = Fields::new();
    fields.set_string(TAG_CONVERSATION, Some(&item.conversation_id));
    fields.set_u64(2, item.kind as u64);
    fields.set_u64(3, item.direction as u64);
    fields.set_date(4, Some(item.sent_at));
    fields.set_date(5, Some(item.received_at));
    fields.set_string(6, item.text.as_deref());
    fields.set_string(7, item.transfer_id.as_deref());
    fields.set_string(8, item.event_kind.as_deref());
    if !item.event_arguments.is_empty() {
        let json = crate::store::sync_records::foundation_json(&item.event_arguments);
        fields.set_data(9, Some(json.as_bytes()));
    }
    fields.set_u64(10, u64::from(item.via_assistant));
    fields.set_u64(11, u64::from(item.cancelled));
    fields.encode()
}

pub fn item_from_body(fields: &Fields, item_id: &str) -> Option<SyncItem> {
    let (kind, direction) = (fields.u64(2), fields.u64(3));
    let (sent, received) = (fields.date(4)?, fields.date(5)?);
    if kind > 2 || direction > 1 {
        return None;
    }
    Some(SyncItem {
        item_id: item_id.to_owned(),
        conversation_id: String::new(),
        kind: kind as i64,
        direction: direction as i64,
        sent_at: sent,
        received_at: received,
        text: fields.string(6),
        transfer_id: fields.string(7),
        event_kind: fields.string(8),
        event_arguments: fields
            .data(9)
            .and_then(|d| std::str::from_utf8(d).ok())
            .map(json_arguments)
            .unwrap_or_default(),
        via_assistant: fields.u64(10) != 0,
        cancelled: fields.u64(11) != 0,
    })
}

pub fn read_body(conversation: &str, received_at: f64, item_id: &str) -> Vec<u8> {
    let mut fields = Fields::new();
    fields.set_string(TAG_CONVERSATION, Some(conversation));
    fields.set_date(2, Some(received_at));
    fields.set_string(3, Some(item_id));
    fields.encode()
}

/// In-flight states fold into Queued: they are one device's session, not the message's fate.
pub fn outbox_folded_state(state: i64) -> i64 {
    if matches!(state, 1 | 2) {
        0
    } else {
        state
    }
}

pub fn outbox_body(entry: &SyncEntry) -> Vec<u8> {
    let mut fields = Fields::new();
    fields.set_string(TAG_CONVERSATION, Some(&entry.conversation_id));
    fields.set_u64(2, entry.kind as u64);
    fields.set_u64(3, outbox_folded_state(entry.state) as u64);
    fields.set_date(4, Some(entry.created_at));
    fields.set_string(5, entry.item_id.as_deref());
    fields.set_string(6, entry.failure_reason.as_deref());
    fields.set_data(7, entry.payload.as_deref());
    fields.encode()
}

pub fn outbox_from_body(fields: &Fields, entry_id: &str) -> Option<SyncEntry> {
    let (kind, state) = (fields.u64(2), fields.u64(3));
    if kind > 4 || state > 4 {
        return None;
    }
    Some(SyncEntry {
        entry_id: entry_id.to_owned(),
        conversation_id: String::new(),
        kind: kind as i64,
        state: state as i64,
        created_at: fields.date(4).unwrap_or(0.0),
        queued_at: None,
        item_id: fields.string(5),
        failure_reason: fields.string(6),
        payload: fields.data(7).map(<[u8]>::to_vec),
    })
}

/// Delivered and received files stay so, whatever a later clock says.
pub fn file_state_is_final(state: i64) -> bool {
    matches!(state, 5 | 6)
}

pub fn file_body(file: &SyncFile) -> Vec<u8> {
    let mut fields = Fields::new();
    fields.set_string(TAG_CONVERSATION, Some(&file.conversation_id));
    fields.set_string(2, file.item_id.as_deref());
    fields.set_u64(3, u64::from(file.outgoing));
    fields.set_u64(4, file.state as u64);
    fields.set_string(5, Some(&file.file_name));
    fields.set_string(6, file.uniform_type.as_deref());
    fields.set_u64(7, file.size);
    fields.set_data(8, Some(&file.digest));
    fields.set_date(9, Some(file.created_at));
    fields.encode()
}

pub fn file_from_body(fields: &Fields, transfer_id: &str) -> Option<SyncFile> {
    let state = fields.u64(4);
    let name = fields.string(5).filter(|n| !n.is_empty())?;
    let digest = fields.data(8).filter(|d| d.len() == 32)?;
    if state > 9 {
        return None;
    }
    Some(SyncFile {
        transfer_id: transfer_id.to_owned(),
        conversation_id: String::new(),
        item_id: fields.string(2),
        outgoing: fields.u64(3) != 0,
        state: state as i64,
        file_name: name,
        uniform_type: fields.string(6),
        size: fields.u64(7),
        digest: digest.to_vec(),
        created_at: fields.date(9).unwrap_or(0.0),
        holders: Vec::new(),
    })
}

pub fn file_from_transfer(transfer: &SyncTransfer, item_id: Option<String>) -> SyncFile {
    SyncFile {
        transfer_id: transfer.transfer_id.clone(),
        conversation_id: transfer.conversation_id.clone(),
        item_id,
        outgoing: transfer.outgoing,
        state: transfer.state,
        file_name: transfer.file_name.clone(),
        uniform_type: transfer.uniform_type.clone(),
        size: transfer.size,
        digest: transfer.digest.clone(),
        created_at: transfer.created_at,
        holders: Vec::new(),
    }
}
