//! The records sync reads and writes whole (`SZFriendsStorePeople.m`, `SZFriendsStoreRecords.m`): a person with every
//! column a field group carries, history items with their event columns, transfers with their creation time, the
//! profile and settings. Sync compares what it captured with what the store holds now, so it reads every column the
//! helper's records hold, and saves a person exactly as `SZFriendsStoreSavePerson` does.

use rusqlite::types::Value;
use rusqlite::{params, Connection, OptionalExtension, Row};

use super::{is_valid_identifier, new_identifier, unix_now, Result, StoreError};

pub use super::sync_settings::{own_presence_secret, set_own_presence_secret, set_setting, setting};

/// `SZFriendsPicture`: placeholder 0, animal 1, image 2.
#[derive(Clone, Debug, PartialEq)]
pub struct Picture {
    pub kind: i64,
    pub set: i64,
    pub index: i64,
    pub path: Option<String>,
    pub sha256: Option<Vec<u8>>,
}

impl Picture {
    pub const PLACEHOLDER: i64 = 0;
    pub const ANIMAL: i64 = 1;
    pub const IMAGE: i64 = 2;

    pub fn placeholder() -> Self {
        Self { kind: Self::PLACEHOLDER, set: 0, index: -1, path: None, sha256: None }
    }

    /// Out-of-range values name no animal: a placeholder.
    pub fn animal(set: i64, index: i64) -> Self {
        if set < 1 || index < 0 {
            return Self::placeholder();
        }
        Self { kind: Self::ANIMAL, set, index, path: None, sha256: None }
    }

    pub fn image(path: String, sha256: Vec<u8>) -> Self {
        Self { kind: Self::IMAGE, set: 0, index: -1, path: Some(path), sha256: Some(sha256) }
    }

    /// Unknown kinds and incomplete image rows read back as the placeholder.
    fn from_columns(row: &Row, first: usize) -> rusqlite::Result<Self> {
        let kind: i64 = row.get(first)?;
        let path: Option<String> = row.get(first + 3)?;
        let sha: Option<Vec<u8>> = row.get(first + 4)?;
        Ok(match (kind, path, sha) {
            (Self::ANIMAL, _, _) => Self::animal(row.get(first + 1)?, row.get(first + 2)?),
            (Self::IMAGE, Some(path), Some(sha)) => Self::image(path, sha),
            _ => Self::placeholder(),
        })
    }
}

/// A person as sync sees them: every column a field group carries.
#[derive(Clone, Debug, PartialEq)]
pub struct SyncPerson {
    pub conversation_id: String,
    pub identity_key: Option<Vec<u8>>,
    pub static_key: Option<Vec<u8>>,
    pub friends_id: Option<String>,
    pub name: Option<String>,
    pub picture: Picture,
    pub relation: i64,
    pub verified: bool,
    pub verified_at: Option<f64>,
    pub comparison_code: Option<String>,
    pub auto_accept: bool,
    pub key_change_pending: bool,
    pub presence_secret: Option<Vec<u8>>,
    pub callback_token: Option<Vec<u8>>,
    pub callback_secret: Option<Vec<u8>>,
    pub last_interaction_at: f64,
    pub unread_count: i64,
    pub request_at: Option<f64>,
    pub request_found_nearby: bool,
    pub unconfirmed_answer_id: Option<String>,
    /// Off the list since (Removed or Blocked only; see `Person::left_list_at`).
    pub left_list_at: Option<f64>,
}

impl SyncPerson {
    /// Someone sync brings in by their relation: no keys yet but what the scope names.
    pub fn new(conversation_id: String, last_interaction_at: f64) -> Self {
        Self {
            conversation_id,
            identity_key: None,
            static_key: None,
            friends_id: None,
            name: None,
            picture: Picture::placeholder(),
            relation: 0,
            verified: false,
            verified_at: None,
            comparison_code: None,
            auto_accept: false,
            key_change_pending: false,
            presence_secret: None,
            callback_token: None,
            callback_secret: None,
            last_interaction_at,
            unread_count: 0,
            request_at: None,
            request_found_nearby: false,
            unconfirmed_answer_id: None,
            left_list_at: None,
        }
    }
}

const PERSON_COLUMNS: &str = "conversation_id, identity_pk, static_pk, friends_id, name, picture_kind, picture_set, \
     picture_index, picture_path, picture_sha256, relation, verified, verified_at, comparison_code, auto_accept, \
     key_change_pending, presence_secret, callback_token, callback_secret, last_interaction_at, unread_count, \
     request_at, request_found_nearby";

fn person_from_row(row: &Row) -> rusqlite::Result<SyncPerson> {
    Ok(SyncPerson {
        conversation_id: row.get(0)?,
        identity_key: row.get(1)?,
        static_key: row.get(2)?,
        friends_id: row.get(3)?,
        name: row.get(4)?,
        picture: Picture::from_columns(row, 5)?,
        relation: row.get(10)?,
        verified: row.get::<_, i64>(11)? != 0,
        verified_at: row.get(12)?,
        comparison_code: row.get(13)?,
        auto_accept: row.get::<_, i64>(14)? != 0,
        key_change_pending: row.get::<_, i64>(15)? != 0,
        presence_secret: row.get(16)?,
        callback_token: row.get(17)?,
        callback_secret: row.get(18)?,
        last_interaction_at: row.get(19)?,
        unread_count: row.get(20)?,
        request_at: row.get(21)?,
        request_found_nearby: row.get::<_, i64>(22)? != 0,
        unconfirmed_answer_id: row.get(23)?,
        left_list_at: row.get(24)?,
    })
}

/// People matching `clause` (with one bind), latest interaction first.
pub fn sync_people(conn: &Connection, clause: &str, bind: Option<&dyn rusqlite::ToSql>) -> Result<Vec<SyncPerson>> {
    let sql = format!(
        "SELECT {PERSON_COLUMNS}, CASE WHEN relation = 0 THEN unconfirmed_answer_id END, \
         CASE WHEN relation IN (3, 4) THEN left_list_at END FROM friends {clause} \
         ORDER BY last_interaction_at DESC, conversation_id"
    );
    let mut statement = conn.prepare(&sql)?;
    let rows = match bind {
        Some(bind) => statement.query_map([bind], person_from_row)?.collect::<rusqlite::Result<Vec<_>>>()?,
        None => statement.query_map([], person_from_row)?.collect::<rusqlite::Result<Vec<_>>>()?,
    };
    Ok(rows)
}

pub fn sync_person_with_conversation(conn: &Connection, conversation_id: &str) -> Result<Option<SyncPerson>> {
    Ok(sync_people(conn, "WHERE conversation_id = ?1", Some(&conversation_id))?.into_iter().next())
}

pub fn sync_person_with_identity_key(conn: &Connection, key: &[u8]) -> Result<Option<SyncPerson>> {
    Ok(sync_people(conn, "WHERE identity_pk = ?1", Some(&key))?.into_iter().next())
}

fn has_length(value: &Option<Vec<u8>>, length: usize) -> bool {
    value.as_ref().is_none_or(|v| v.len() == length)
}

/// `SZFriendsStoreSavePerson`: a fresh id when none, keys set where none were and never replaced, automatic
/// acceptance off for a blocked person, unread count and latest interaction never moved back.
pub fn sync_save_person(conn: &Connection, person: &mut SyncPerson) -> Result<()> {
    if person.conversation_id.is_empty() {
        person.conversation_id = new_identifier();
    }
    if !is_valid_identifier(&person.conversation_id) {
        return Err(StoreError::Invalid("bad conversation id"));
    }
    let lengths_ok = has_length(&person.identity_key, 32)
        && has_length(&person.static_key, 32)
        && has_length(&person.presence_secret, 32)
        && has_length(&person.callback_token, 16)
        && has_length(&person.callback_secret, 32);
    if !lengths_ok || !(0..=4).contains(&person.relation) {
        return Err(StoreError::Invalid("bad person fields"));
    }
    if let Some(stored) = sync_person_with_conversation(conn, &person.conversation_id)? {
        let kept = |old: &Option<Vec<u8>>, new: &Option<Vec<u8>>| old.is_none() || old == new;
        if !kept(&stored.identity_key, &person.identity_key) || !kept(&stored.static_key, &person.static_key) {
            return Err(StoreError::KeyChangeRefused);
        }
    }
    let auto_accept = person.auto_accept && person.relation != 4 && !person.key_change_pending;
    let request_since = matches!(person.relation, 0 | 1).then(|| {
        let now = unix_now();
        person.request_at.filter(|at| *at < now).unwrap_or(now)
    });
    let unconfirmed = if person.relation == 0 { person.unconfirmed_answer_id.clone() } else { None };
    let left_list_at = super::people::may_be_off_the_list(person.relation).then_some(person.left_list_at).flatten();
    let p = &*person;
    conn.execute(
        &format!(
            "INSERT INTO friends ({PERSON_COLUMNS}, request_since, unconfirmed_answer_id, left_list_at) VALUES \
             (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26) \
             ON CONFLICT(conversation_id) DO UPDATE SET identity_pk = excluded.identity_pk, \
             static_pk = excluded.static_pk, friends_id = excluded.friends_id, name = excluded.name, \
             picture_kind = excluded.picture_kind, picture_set = excluded.picture_set, \
             picture_index = excluded.picture_index, picture_path = excluded.picture_path, \
             picture_sha256 = excluded.picture_sha256, relation = excluded.relation, verified = excluded.verified, \
             verified_at = excluded.verified_at, comparison_code = excluded.comparison_code, \
             auto_accept = excluded.auto_accept, key_change_pending = excluded.key_change_pending, \
             pending_static_pk = CASE WHEN excluded.key_change_pending THEN friends.pending_static_pk END, \
             presence_secret = excluded.presence_secret, callback_token = excluded.callback_token, \
             callback_secret = excluded.callback_secret, \
             last_interaction_at = max(friends.last_interaction_at, excluded.last_interaction_at), \
             request_at = excluded.request_at, request_found_nearby = excluded.request_found_nearby, \
             unconfirmed_answer_id = excluded.unconfirmed_answer_id, left_list_at = excluded.left_list_at, \
             request_since = CASE WHEN excluded.relation NOT IN (0, 1) THEN NULL \
             WHEN friends.relation = excluded.relation AND friends.request_since IS NOT NULL \
             THEN friends.request_since ELSE excluded.request_since END"
        ),
        params![
            p.conversation_id,
            p.identity_key,
            p.static_key,
            p.friends_id,
            p.name,
            p.picture.kind,
            p.picture.set,
            p.picture.index,
            p.picture.path,
            p.picture.sha256,
            p.relation,
            p.verified,
            p.verified_at,
            p.comparison_code,
            auto_accept,
            p.key_change_pending,
            p.presence_secret,
            p.callback_token,
            p.callback_secret,
            p.last_interaction_at,
            p.unread_count.max(0),
            p.request_at,
            p.request_found_nearby,
            request_since,
            unconfirmed,
            left_list_at
        ],
    )?;
    Ok(())
}

/// A history item with the columns sync carries (`SZFriendsItemRecord`).
#[derive(Clone, Debug, PartialEq)]
pub struct SyncItem {
    pub item_id: String,
    pub conversation_id: String,
    pub kind: i64,
    pub direction: i64,
    pub sent_at: f64,
    pub received_at: f64,
    pub text: Option<String>,
    pub transfer_id: Option<String>,
    pub event_kind: Option<String>,
    /// Sorted, as a dictionary of strings.
    pub event_arguments: Vec<(String, String)>,
    pub via_assistant: bool,
    pub cancelled: bool,
}

pub(crate) const ITEM_COLUMNS: &str = "m.item_id, m.conversation_id, m.kind, m.direction, m.sent_at, m.received_at, \
     m.body, m.transfer_id, m.event_kind, m.event_args, m.via_assistant, m.cancelled";

/// String keys and values of a JSON object; anything else is left out.
pub fn json_arguments(text: &str) -> Vec<(String, String)> {
    let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(text) else { return Vec::new() };
    let mut pairs: Vec<(String, String)> =
        map.into_iter().filter_map(|(k, v)| v.as_str().map(|v| (k, v.to_owned()))).collect();
    pairs.sort();
    pairs
}

/// `NSJSONSerialization` with sorted keys: `/` escaped, controls as `\uXXXX` except the short escapes.
pub fn foundation_json(pairs: &[(String, String)]) -> String {
    fn quoted(out: &mut String, text: &str) {
        out.push('"');
        for c in text.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '/' => out.push_str("\\/"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                '\u{8}' => out.push_str("\\b"),
                '\u{c}' => out.push_str("\\f"),
                c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out.push('"');
    }
    let mut sorted = pairs.to_vec();
    sorted.sort();
    let mut out = String::from("{");
    for (i, (key, value)) in sorted.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        quoted(&mut out, key);
        out.push(':');
        quoted(&mut out, value);
    }
    out.push('}');
    out
}

pub(crate) fn item_from_row(row: &Row) -> rusqlite::Result<SyncItem> {
    let kind: i64 = row.get(2)?;
    let sent_at: Option<f64> = row.get(4)?;
    let sent_at = sent_at.unwrap_or(0.0);
    let body: Option<String> = row.get(6)?;
    let arguments: Option<String> = row.get(9)?;
    Ok(SyncItem {
        item_id: row.get(0)?,
        conversation_id: row.get(1)?,
        kind,
        direction: row.get(3)?,
        sent_at,
        received_at: row.get::<_, Option<f64>>(5)?.unwrap_or(sent_at),
        text: if kind == 2 { None } else { body },
        transfer_id: row.get(7)?,
        event_kind: row.get(8)?,
        event_arguments: arguments.as_deref().map(json_arguments).unwrap_or_default(),
        via_assistant: row.get::<_, i64>(10)? != 0,
        cancelled: row.get::<_, i64>(11)? != 0,
    })
}

/// `SZFriendsStoreInsertItem` with the event columns: `true` when inserted. A duplicate, or an item a sync deletion
/// took, changes nothing.
pub fn sync_insert_item(conn: &Connection, item: &SyncItem) -> Result<bool> {
    if !is_valid_identifier(&item.conversation_id)
        || !is_valid_identifier(&item.item_id)
        || !(0..=2).contains(&item.kind)
        || !(0..=1).contains(&item.direction)
    {
        return Err(StoreError::Invalid("bad history item"));
    }
    let known: i64 =
        conn.query_row("SELECT count(*) FROM friends WHERE conversation_id = ?1", [&item.conversation_id], |r| {
            r.get(0)
        })?;
    if known == 0 {
        return Err(StoreError::NotFound);
    }
    let exists: i64 = conn.query_row(
        "SELECT (SELECT count(*) FROM messages WHERE conversation_id = ?1 AND item_id = ?2) + \
         (SELECT count(*) FROM sync_deleted WHERE conversation_id = ?1 AND item_id = ?2)",
        [&item.conversation_id, &item.item_id],
        |r| r.get(0),
    )?;
    if exists > 0 {
        return Ok(false);
    }
    let sent = if item.direction == 0 { item.sent_at.min(item.received_at) } else { item.sent_at };
    let mut body = if item.kind == 2 { None } else { item.text.clone() };
    if item.kind == 1 && body.is_none() && item.transfer_id.is_some() {
        body = conn
            .query_row("SELECT file_name FROM transfers WHERE transfer_id = ?1", [&item.transfer_id], |r| r.get(0))
            .optional()?;
    }
    let arguments = (!item.event_arguments.is_empty()).then(|| foundation_json(&item.event_arguments));
    let folded = body.as_deref().map(super::search::fold);
    conn.execute(
        "INSERT INTO messages (conversation_id, item_id, kind, direction, body, folded, transfer_id, event_kind, \
         event_args, sent_at, received_at, via_assistant) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
        params![
            item.conversation_id,
            item.item_id,
            item.kind,
            item.direction,
            body,
            folded,
            item.transfer_id,
            item.event_kind,
            arguments,
            sent,
            item.received_at,
            item.via_assistant && item.kind != 2
        ],
    )?;
    let unread = i64::from(item.direction == 0 && item.kind != 2);
    conn.execute(
        "UPDATE friends SET last_interaction_at = max(last_interaction_at, ?1), unread_count = unread_count + ?2 \
         WHERE conversation_id = ?3",
        params![item.received_at, unread, item.conversation_id],
    )?;
    Ok(true)
}

/// A transfer row with what sync carries of it.
#[derive(Clone, Debug, PartialEq)]
pub struct SyncTransfer {
    pub transfer_id: String,
    pub conversation_id: String,
    pub outgoing: bool,
    pub state: i64,
    pub file_name: String,
    pub uniform_type: Option<String>,
    pub size: u64,
    pub digest: Vec<u8>,
    pub staged_path: Option<String>,
    pub received_path: Option<String>,
    pub created_at: f64,
    /// Outgoing: the file it was sent from and its modification time then (schema v12; never synced).
    pub source_path: Option<String>,
    pub source_mtime_ns: i64,
}

pub fn sync_transfers(conn: &Connection, tail: &str, binds: &[&dyn rusqlite::ToSql]) -> Result<Vec<SyncTransfer>> {
    let sql = format!(
        "SELECT transfer_id, conversation_id, outgoing, state, file_name, uniform_type, size, digest, staged_path, \
         received_path, created_at, source_path, source_mtime_ns FROM transfers {tail}"
    );
    let mut statement = conn.prepare(&sql)?;
    let rows = statement.query_map(binds, |row| {
        Ok(SyncTransfer {
            transfer_id: row.get(0)?,
            conversation_id: row.get(1)?,
            outgoing: row.get::<_, i64>(2)? != 0,
            state: row.get(3)?,
            file_name: row.get(4)?,
            uniform_type: row.get(5)?,
            size: row.get::<_, i64>(6)?.max(0) as u64,
            digest: row.get(7)?,
            staged_path: row.get(8)?,
            received_path: row.get(9)?,
            created_at: row.get(10)?,
            source_path: row.get(11)?,
            source_mtime_ns: row.get::<_, Option<i64>>(12)?.unwrap_or(0),
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// The profile's name and picture.
pub fn profile(conn: &Connection) -> Result<(Option<String>, Picture)> {
    let row = conn
        .query_row(
            "SELECT name, picture_kind, picture_set, picture_index, picture_path, picture_sha256 FROM profile \
             WHERE id = 1",
            [],
            |row| Ok((row.get::<_, Option<String>>(0)?, Picture::from_columns(row, 1)?)),
        )
        .optional()?;
    Ok(row.unwrap_or((None, Picture::placeholder())))
}

pub fn set_profile(conn: &Connection, name: Option<&str>, picture: &Picture) -> Result<()> {
    conn.execute("INSERT INTO profile(id) VALUES (1) ON CONFLICT(id) DO NOTHING", [])?;
    conn.execute(
        "UPDATE profile SET name = ?1, picture_kind = ?2, picture_set = ?3, picture_index = ?4, picture_path = ?5, \
         picture_sha256 = ?6 WHERE id = 1",
        params![name, picture.kind, picture.set, picture.index, picture.path, picture.sha256],
    )?;
    Ok(())
}

/// A profile column (`friends_id`, `friends_id_state`) written alone.
pub fn set_profile_value(conn: &Connection, column: &'static str, value: Value) -> Result<()> {
    conn.execute("INSERT INTO profile(id) VALUES (1) ON CONFLICT(id) DO NOTHING", [])?;
    conn.execute(&format!("UPDATE profile SET {column} = ?1 WHERE id = 1"), [value])?;
    Ok(())
}

pub fn profile_value(conn: &Connection, column: &'static str) -> Result<Value> {
    let value = conn.query_row(&format!("SELECT {column} FROM profile WHERE id = 1"), [], |r| r.get(0)).optional()?;
    Ok(value.unwrap_or(Value::Null))
}
