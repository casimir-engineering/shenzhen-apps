//! People and history (`SZFriendsStorePeople.m`, `SZFriendsStoreHistory.m`): what the session and transfer flows
//! need today. Pictures, Friends ID attestations, requests by ID and devices arrive with the waves that use them; the
//! columns exist already and keep their defaults.

use rusqlite::{params, Connection, OptionalExtension, Row};

use super::{is_valid_identifier, new_identifier, unix_now, Result, Store, StoreError};

/// `friends.relation` (`SZFriendsRelation`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Relation {
    IncomingRequest = 0,
    OutgoingRequest = 1,
    Friend = 2,
    Removed = 3,
    Blocked = 4,
}

impl Relation {
    fn from_i64(value: i64) -> Self {
        match value {
            0 => Self::IncomingRequest,
            1 => Self::OutgoingRequest,
            2 => Self::Friend,
            3 => Self::Removed,
            _ => Self::Blocked,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Incoming = 0,
    Outgoing = 1,
}

impl Direction {
    pub(super) fn from_i64(value: i64) -> Self {
        if value == 1 {
            Self::Outgoing
        } else {
            Self::Incoming
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Message = 0,
    /// One file offer and its whole life.
    Transfer = 1,
    Event = 2,
}

impl ItemKind {
    pub(super) fn from_i64(value: i64) -> Self {
        match value {
            1 => Self::Transfer,
            2 => Self::Event,
            _ => Self::Message,
        }
    }
}

/// One person and their one conversation, identified by their Ed25519 identity key alone.
#[derive(Clone, Debug, PartialEq)]
pub struct Person {
    pub conversation_id: String,
    pub identity_key: Option<[u8; 32]>,
    pub static_key: Option<[u8; 32]>,
    pub friends_id: Option<String>,
    pub name: Option<String>,
    pub relation: Relation,
    pub auto_accept: bool,
    pub presence_secret: Option<[u8; 32]>,
    pub comparison_code: Option<String>,
    pub last_interaction_at: f64,
    pub unread_count: i64,
    /// The request card's "asked ..." time; asking again refreshes it.
    pub request_at: Option<f64>,
    /// Nearby (XX on a public entry) rather than by Friends ID.
    pub request_found_nearby: bool,
    /// When the request now waiting began, in either direction; read only. A save starts it at `request_at` (never
    /// later than the save) when the person becomes a request and keeps it while they stay one, so asking again
    /// cannot move it; the IK window and a request's life count from it.
    pub request_since: Option<f64>,
    /// Incoming Add by ID: the requester's token, which our IK callback presents, and their day's callback secret.
    pub callback_token: Option<[u8; 16]>,
    pub callback_secret: Option<[u8; 32]>,
    /// The Friends ID our Add by ID asked for, on an answer no host confirmed, while it waits as an incoming request.
    pub unconfirmed_answer_id: Option<String>,
    pub key_change_pending: bool,
    /// A host attestation covers the Friends ID this row holds now; read only.
    pub friends_id_confirmed: bool,
    /// When the person took someone who is no longer a friend off their list (Unix seconds). Only a Removed or Blocked
    /// person can be off the list: a read voids it for any other relation, and a save with another relation clears
    /// it, so a new request from either side brings them back.
    pub left_list_at: Option<f64>,
}

impl Person {
    /// A new person with a fresh conversation id.
    pub fn new(relation: Relation) -> Self {
        Self {
            conversation_id: new_identifier(),
            identity_key: None,
            static_key: None,
            friends_id: None,
            name: None,
            relation,
            auto_accept: false,
            presence_secret: None,
            comparison_code: None,
            last_interaction_at: unix_now(),
            unread_count: 0,
            request_at: None,
            request_found_nearby: false,
            request_since: None,
            callback_token: None,
            callback_secret: None,
            unconfirmed_answer_id: None,
            key_change_pending: false,
            friends_id_confirmed: false,
            left_list_at: None,
        }
    }
}

const PERSON_COLUMNS: &str = "conversation_id, identity_pk, static_pk, friends_id, name, relation, auto_accept, \
                              presence_secret, comparison_code, last_interaction_at, unread_count, request_at, \
                              request_found_nearby, callback_token, callback_secret, key_change_pending";

/// After the saved columns, what reads work out (`SZFriendsPersonReadColumns`): when the waiting request began, only
/// while one waits; an unconfirmed answer's ID only while the row waits as an incoming request; and whether an
/// attestation covers the Friends ID the row holds now; and when the person took them off the list, only while they are
/// Removed or Blocked, so any other relation, even one an older helper wrote, voids it.
const PERSON_READ_COLUMNS: &str = "CASE WHEN relation IN (0, 1) THEN coalesce(request_since, request_at, \
                                   last_interaction_at) END, CASE WHEN relation = 0 THEN unconfirmed_answer_id END, \
                                   attested_friends_id = friends_id AND id_attestation IS NOT NULL \
                                   AND id_attestation_day IS NOT NULL, CASE WHEN relation IN (3, 4) THEN left_list_at END";

fn key_column(row: &Row, index: usize) -> rusqlite::Result<Option<[u8; 32]>> {
    Ok(row.get::<_, Option<Vec<u8>>>(index)?.and_then(|bytes| bytes.try_into().ok()))
}

fn person_from_row(row: &Row) -> rusqlite::Result<Person> {
    Ok(Person {
        conversation_id: row.get(0)?,
        identity_key: key_column(row, 1)?,
        static_key: key_column(row, 2)?,
        friends_id: row.get(3)?,
        name: row.get(4)?,
        relation: Relation::from_i64(row.get(5)?),
        auto_accept: row.get::<_, i64>(6)? != 0,
        presence_secret: key_column(row, 7)?,
        comparison_code: row.get(8)?,
        last_interaction_at: row.get(9)?,
        unread_count: row.get(10)?,
        request_at: row.get(11)?,
        request_found_nearby: row.get::<_, i64>(12)? != 0,
        callback_token: row.get::<_, Option<Vec<u8>>>(13)?.and_then(|bytes| bytes.try_into().ok()),
        callback_secret: key_column(row, 14)?,
        key_change_pending: row.get::<_, i64>(15)? != 0,
        request_since: row.get(16)?,
        unconfirmed_answer_id: row.get(17)?,
        friends_id_confirmed: row.get::<_, Option<i64>>(18)?.unwrap_or(0) != 0,
        left_list_at: row.get(19)?,
    })
}

pub(super) fn person_where(conn: &Connection, clause: &str, bind: &dyn rusqlite::ToSql) -> Result<Option<Person>> {
    let sql = format!("SELECT {PERSON_COLUMNS}, {PERSON_READ_COLUMNS} FROM friends WHERE {clause}");
    Ok(conn.query_row(&sql, [bind], person_from_row).optional()?)
}

/// One history entry. The id is the sender's 128-bit message id (hex) or a local id.
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub item_id: String,
    pub conversation_id: String,
    pub kind: ItemKind,
    pub direction: Direction,
    pub text: Option<String>,
    pub transfer_id: Option<String>,
    pub sent_at: f64,
    pub received_at: f64,
    pub via_assistant: bool,
}

/// Inserts unless (conversation, item id) exists; `true` when it was inserted. A redelivery after a lost ACK is
/// already durable, so the caller acknowledges again and nothing changes; so is an item erased by a sync deletion.
pub(super) fn insert_item(conn: &Connection, item: &Item) -> Result<bool> {
    if !is_valid_identifier(&item.conversation_id) || !is_valid_identifier(&item.item_id) {
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
    // A sender's fast clock must not pin its messages below everything that arrives later (ADR 0001 § Messages).
    let sent = if item.direction == Direction::Incoming { item.sent_at.min(item.received_at) } else { item.sent_at };
    let mut body = if item.kind == ItemKind::Event { None } else { item.text.clone() };
    if item.kind == ItemKind::Transfer && body.is_none() {
        // A file's history row is found by its name, so the name is indexed with the messages.
        body = conn
            .query_row("SELECT file_name FROM transfers WHERE transfer_id = ?1", [&item.transfer_id], |r| r.get(0))
            .optional()?;
    }
    let folded = body.as_deref().map(super::search::fold);
    let via_assistant = item.via_assistant && item.kind != ItemKind::Event;
    conn.execute(
        "INSERT INTO messages (conversation_id, item_id, kind, direction, body, folded, transfer_id, sent_at, \
         received_at, via_assistant) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            item.conversation_id,
            item.item_id,
            item.kind as i64,
            item.direction as i64,
            body,
            folded,
            item.transfer_id,
            sent,
            item.received_at,
            via_assistant
        ],
    )?;
    let unread = i64::from(item.direction == Direction::Incoming && item.kind != ItemKind::Event);
    conn.execute(
        "UPDATE friends SET last_interaction_at = max(last_interaction_at, ?1), unread_count = unread_count + ?2 \
         WHERE conversation_id = ?3",
        params![item.received_at, unread, item.conversation_id],
    )?;
    Ok(true)
}

/// Only someone who is no longer a friend (Removed) or is blocked can be off the list: saving any other relation, such
/// as a new request from either side, puts them back on it.
pub(crate) fn may_be_off_the_list(relation: i64) -> bool {
    relation == Relation::Removed as i64 || relation == Relation::Blocked as i64
}

/// [`Store::save_person`] inside a transaction the caller holds.
pub(super) fn save_person_in(conn: &Connection, person: &Person) -> Result<()> {
    if !is_valid_identifier(&person.conversation_id) {
        return Err(StoreError::Invalid("bad conversation id"));
    }
    if let Some(stored) = person_where(conn, "conversation_id = ?1", &person.conversation_id)? {
        let kept = |old: Option<[u8; 32]>, new: Option<[u8; 32]>| old.is_none() || old == new;
        if !kept(stored.identity_key, person.identity_key) || !kept(stored.static_key, person.static_key) {
            return Err(StoreError::KeyChangeRefused);
        }
    }
    let auto_accept = person.auto_accept && person.relation != Relation::Blocked && !person.key_change_pending;
    let requesting = matches!(person.relation, Relation::IncomingRequest | Relation::OutgoingRequest);
    // When a request saved now would begin: when it was asked, never later than now.
    let now = unix_now();
    let request_start = requesting.then(|| person.request_at.filter(|at| *at < now).unwrap_or(now));
    let unconfirmed = (person.relation == Relation::IncomingRequest).then_some(person.unconfirmed_answer_id.as_deref());
    let left_list_at = may_be_off_the_list(person.relation as i64).then_some(person.left_list_at).flatten();
    conn.execute(
        &format!(
            "INSERT INTO friends ({PERSON_COLUMNS}, request_since, unconfirmed_answer_id, left_list_at) VALUES (?1, \
                 ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19) \
                 ON CONFLICT(conversation_id) DO UPDATE SET identity_pk = excluded.identity_pk, \
                 static_pk = excluded.static_pk, friends_id = excluded.friends_id, name = excluded.name, \
                 relation = excluded.relation, auto_accept = excluded.auto_accept, \
                 presence_secret = excluded.presence_secret, comparison_code = excluded.comparison_code, \
                 last_interaction_at = max(friends.last_interaction_at, excluded.last_interaction_at), \
                 request_at = excluded.request_at, request_found_nearby = excluded.request_found_nearby, \
                 callback_token = excluded.callback_token, callback_secret = excluded.callback_secret, \
                 key_change_pending = excluded.key_change_pending, \
                 pending_static_pk = CASE WHEN excluded.key_change_pending THEN friends.pending_static_pk END, \
                 unconfirmed_answer_id = excluded.unconfirmed_answer_id, left_list_at = excluded.left_list_at, \
                 request_since = CASE WHEN excluded.relation NOT IN (0, 1) THEN NULL \
                 WHEN friends.relation = excluded.relation AND friends.request_since IS NOT NULL \
                 THEN friends.request_since ELSE excluded.request_since END"
        ),
        params![
            person.conversation_id,
            person.identity_key.map(Vec::from),
            person.static_key.map(Vec::from),
            person.friends_id,
            person.name,
            person.relation as i64,
            auto_accept,
            person.presence_secret.map(Vec::from),
            person.comparison_code,
            person.last_interaction_at,
            person.unread_count.max(0),
            person.request_at,
            person.request_found_nearby,
            person.callback_token.map(Vec::from),
            person.callback_secret.map(Vec::from),
            person.key_change_pending,
            request_start,
            unconfirmed.flatten(),
            left_list_at
        ],
    )?;
    Ok(())
}

impl Store {
    /// Saves a person. Identity keys never change, so a conversation never moves to another key, and a static key
    /// changes only through review (`KeyChangeRefused`); a blocked person never has automatic acceptance.
    pub fn save_person(&mut self, person: &Person) -> Result<()> {
        self.write(|conn| save_person_in(conn, person))
    }

    /// The person whose identity (root) key this is; failing that, the person a friend's chain says this device
    /// speaks for (ADR 0012), so a lookup by a session's key finds a friend's other devices too. Revoked and void
    /// devices never match the second clause, and our own devices never do.
    pub fn person_with_identity_key(&self, key: &[u8; 32]) -> Result<Option<Person>> {
        let clause =
            "identity_pk = coalesce((SELECT identity_pk FROM friends WHERE identity_pk = ?1), (SELECT d.root_pk \
                      FROM chain_devices d JOIN device_chains c ON c.root_pk = d.root_pk WHERE d.device_pk = ?1 AND \
                      d.state = 1 AND c.own = 0))";
        person_where(&self.conn, clause, &key.to_vec())
    }

    pub fn person_with_conversation(&self, conversation_id: &str) -> Result<Option<Person>> {
        person_where(&self.conn, "conversation_id = ?1", &conversation_id)
    }

    /// Everyone, latest interaction first.
    pub fn people_by_latest_interaction(&self) -> Result<Vec<Person>> {
        let sql = format!(
            "SELECT {PERSON_COLUMNS}, {PERSON_READ_COLUMNS} FROM friends ORDER BY last_interaction_at DESC, \
             conversation_id"
        );
        let mut statement = self.conn.prepare(&sql)?;
        let people = statement.query_map([], person_from_row)?.collect::<std::result::Result<_, _>>()?;
        Ok(people)
    }

    /// Records a history item (`true`) or recognises one already kept (`false`): a resent message is acknowledged
    /// again and never inserted twice.
    pub fn insert_item(&mut self, item: &Item) -> Result<bool> {
        self.write(|conn| insert_item(conn, item))
    }

    pub fn search(
        &self,
        query: &str,
        conversation_ids: Option<&[String]>,
        limit: usize,
    ) -> Result<Vec<super::SearchHit>> {
        super::search::search(&self.conn, query, conversation_ids, limit, self.search_uses_index())
    }
}
