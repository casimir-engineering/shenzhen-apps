//! The Add by ID requests this person sent (table `id_requests`, ADR 0004 steps 1 to 4) and who answered each one
//! (`id_request_answers`), as `SZFriendsStoreAddByID.m` keeps them.
//!
//! A request stays until it expires, even once answered, so a second holder of an unreserved ID can still call back.
//! Its token is broadcast to every nearby device, so it proves nothing about who answers: each distinct key gets its
//! own conversation, a token admits at most three of them, and keys without a host attestation at most two, so three
//! throwaway keys from one stranger cannot lock the real holder out.

use rusqlite::{params, Connection, OptionalExtension, Row};

use super::people::{person_where, Person, Relation};
use super::{is_valid_identifier, unix_now, Result, Store, StoreError};

pub const ID_REQUEST_MAX_PENDING: usize = 4;
pub const ID_REQUEST_LIFETIME_SECONDS: f64 = 7.0 * 86_400.0;
pub const ID_REQUEST_MAX_ANSWERS: usize = 3;
pub const ID_REQUEST_MAX_UNATTESTED_ANSWERS: usize = 2;

/// One Add by ID request (`SZFriendsIDRequestRecord`).
#[derive(Clone, Debug, PartialEq)]
pub struct IdRequest {
    /// The "Request sent" row in the list.
    pub conversation_id: String,
    pub target_friends_id: String,
    pub request_token: [u8; 16],
    /// The master secret the callback days derive from; never leaves this computer.
    pub callback_secret: [u8; 32],
    pub created_at: f64,
    pub expires_at: f64,
    /// Read only: the first answering key's callback, and how many distinct keys the token admitted.
    pub answered_at: Option<f64>,
    pub answering_keys: usize,
}

impl IdRequest {
    /// A new request for `friends_id`, with a fresh token and secret.
    pub fn new(friends_id: &str, now: f64) -> Self {
        let mut request_token = [0u8; 16];
        szfriends_crypto::random_bytes(&mut request_token);
        Self {
            conversation_id: String::new(),
            target_friends_id: friends_id.to_owned(),
            request_token,
            callback_secret: crate::nearby::callbacks::new_secret(),
            created_at: now,
            expires_at: now + ID_REQUEST_LIFETIME_SECONDS,
            answered_at: None,
            answering_keys: 0,
        }
    }
}

const COLUMNS: &str = "conversation_id, target_friends_id, request_token, callback_secret, created_at, expires_at, \
                       answered_at, (SELECT count(*) FROM id_request_answers a WHERE a.request_token = \
                       id_requests.request_token)";

fn from_row(row: &Row) -> rusqlite::Result<IdRequest> {
    let token: Vec<u8> = row.get(2)?;
    let secret: Vec<u8> = row.get(3)?;
    let created_at: f64 = row.get(4)?;
    Ok(IdRequest {
        conversation_id: row.get(0)?,
        target_friends_id: row.get(1)?,
        request_token: token.try_into().unwrap_or([0; 16]),
        callback_secret: secret.try_into().unwrap_or([0; 32]),
        created_at,
        expires_at: row.get::<_, Option<f64>>(5)?.unwrap_or(created_at),
        answered_at: row.get(6)?,
        answering_keys: row.get::<_, i64>(7)?.max(0) as usize,
    })
}

fn requests(conn: &Connection, clause: &str, binds: &[&dyn rusqlite::ToSql]) -> Result<Vec<IdRequest>> {
    let sql = format!("SELECT {COLUMNS} FROM id_requests {clause} ORDER BY created_at, conversation_id");
    let mut statement = conn.prepare(&sql)?;
    let rows = statement.query_map(binds, from_row)?.collect::<std::result::Result<_, _>>()?;
    Ok(rows)
}

fn save(conn: &Connection, request: &IdRequest, now: f64) -> Result<()> {
    if !is_valid_identifier(&request.conversation_id) || request.target_friends_id.is_empty() {
        return Err(StoreError::Invalid("bad ID request"));
    }
    // Requests expire after 7 days; a longer expiry would keep callback tags on the air past what the person was told.
    let expires = request.expires_at.min(request.created_at + ID_REQUEST_LIFETIME_SECONDS);
    let known: i64 =
        conn.query_row("SELECT count(*) FROM friends WHERE conversation_id = ?1", [&request.conversation_id], |r| {
            r.get(0)
        })?;
    if known == 0 {
        return Err(StoreError::NotFound);
    }
    conn.execute("DELETE FROM id_requests WHERE expires_at <= ?1", [now])?;
    let others: i64 = conn.query_row(
        "SELECT count(*) FROM id_requests WHERE conversation_id <> ?1 AND answered_at IS NULL",
        [&request.conversation_id],
        |r| r.get(0),
    )?;
    if others as usize >= ID_REQUEST_MAX_PENDING {
        return Err(StoreError::Constraint); // four already pending: the helper answers rate_limited
    }
    // A new token is a new request: the old one, and who answered it, go.
    conn.execute(
        "DELETE FROM id_requests WHERE conversation_id = ?1 AND request_token <> ?2",
        params![request.conversation_id, request.request_token.to_vec()],
    )?;
    conn.execute(
        "INSERT INTO id_requests (conversation_id, target_friends_id, request_token, callback_secret, created_at, \
         expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(conversation_id) DO UPDATE SET \
         target_friends_id = excluded.target_friends_id, callback_secret = excluded.callback_secret, \
         created_at = excluded.created_at, expires_at = excluded.expires_at",
        params![
            request.conversation_id,
            request.target_friends_id,
            request.request_token.to_vec(),
            request.callback_secret.to_vec(),
            request.created_at,
            expires
        ],
    )?;
    Ok(())
}

/// The same key answering takes its own row back: a keyless "Request sent" row and what was queued on it move there.
fn fold_request_row(conn: &Connection, request: &IdRequest, row_id: &str, known_id: &str) -> Result<()> {
    let token = request.request_token.to_vec();
    conn.execute(
        "DELETE FROM id_requests WHERE conversation_id = ?1 AND request_token <> ?2",
        params![known_id, token],
    )?;
    conn.execute("UPDATE id_requests SET conversation_id = ?1 WHERE request_token = ?2", params![known_id, token])?;
    for table in ["outbox", "messages", "transfers", "id_request_answers"] {
        conn.execute(
            &format!("UPDATE {table} SET conversation_id = ?1 WHERE conversation_id = ?2"),
            params![known_id, row_id],
        )?;
    }
    conn.execute("DELETE FROM friends WHERE conversation_id = ?1", [row_id])?;
    Ok(())
}

/// Saves a person inside an open transaction (the store's own save takes the transaction itself).
fn save_in(conn: &Connection, person: &Person) -> Result<()> {
    super::people::save_person_in(conn, person)
}

/// The conversation a newly admitted key belongs to (`SZFriendsAnswerConversation`).
fn answer_conversation(
    conn: &Connection,
    request: &IdRequest,
    known: Option<Person>,
    identity_key: [u8; 32],
    static_key: [u8; 32],
    attested: bool,
    now: f64,
) -> Result<String> {
    let row = person_where(conn, "conversation_id = ?1", &request.conversation_id)?;
    if let Some(mut known) = known {
        // Their row coming back only if they hold the ID asked for, by the host's word or as they last told us.
        if !attested && known.friends_id.as_deref() != Some(request.target_friends_id.as_str()) {
            return Ok(known.conversation_id);
        }
        if let Some(row) =
            row.as_ref().filter(|r| r.identity_key.is_none() && r.conversation_id != known.conversation_id)
        {
            fold_request_row(conn, request, &row.conversation_id, &known.conversation_id)?;
        }
        if known.relation != Relation::Removed {
            return Ok(known.conversation_id);
        }
        known.relation = Relation::OutgoingRequest;
        known.request_at = Some(row.as_ref().and_then(|r| r.request_at).unwrap_or(request.created_at));
        known.request_found_nearby = false;
        known.comparison_code = None;
        known.auto_accept = false;
        known.last_interaction_at = now;
        save_in(conn, &known)?;
        return Ok(known.conversation_id);
    }
    if let Some(mut row) = row.clone().filter(|r| r.identity_key.is_none()) {
        row.identity_key = Some(identity_key);
        row.static_key = row.static_key.or(Some(static_key));
        save_in(conn, &row)?;
        return Ok(row.conversation_id);
    }
    // The row already holds another key: a different identity key is always a different person, never merged.
    let mut other = Person::new(Relation::OutgoingRequest);
    other.identity_key = Some(identity_key);
    other.static_key = Some(static_key);
    other.friends_id = Some(request.target_friends_id.clone());
    other.request_at = Some(row.and_then(|r| r.request_at).unwrap_or(request.created_at));
    other.last_interaction_at = now;
    save_in(conn, &other)?;
    Ok(other.conversation_id)
}

impl Store {
    /// Unexpired, unanswered: what the helper offers to new devices and whose callback tags it advertises.
    pub fn pending_id_requests(&self, now: f64) -> Vec<IdRequest> {
        requests(&self.conn, "WHERE expires_at > ?1 AND answered_at IS NULL", &[&now]).unwrap_or_default()
    }

    /// Any unexpired request with this token, answered or not.
    pub fn id_request_with_token(&self, token: &[u8], now: f64) -> Option<IdRequest> {
        let rows = requests(&self.conn, "WHERE request_token = ?1 AND expires_at > ?2", &[&token.to_vec(), &now]);
        rows.ok()?.into_iter().next()
    }

    /// add_by_id: the "Request sent" row and its request in one transaction, so a refused fifth request leaves no row.
    /// The newest keyless row with this ID that waits or was withdrawn is reused; a row holding a key never is.
    pub fn start_id_request(&mut self, request: &mut IdRequest) -> Result<String> {
        let now = unix_now();
        let target = request.target_friends_id.clone();
        if target.is_empty() {
            return Err(StoreError::Invalid("no Friends ID"));
        }
        let conversation = self.write(|conn| {
            let row = person_where(
                conn,
                "friends_id = ?1 AND identity_pk IS NULL AND relation IN (1, 3) ORDER BY last_interaction_at DESC, \
                 conversation_id LIMIT 1",
                &target,
            )?;
            let mut row = row.unwrap_or_else(|| {
                let mut fresh = Person::new(Relation::OutgoingRequest);
                fresh.friends_id = Some(target.clone());
                fresh
            });
            row.relation = Relation::OutgoingRequest;
            row.request_at = Some(request.created_at);
            row.request_found_nearby = false;
            row.last_interaction_at = request.created_at;
            save_in(conn, &row)?;
            let mut saved = request.clone();
            saved.conversation_id = row.conversation_id.clone();
            save(conn, &saved, now)?;
            Ok(row.conversation_id)
        })?;
        request.conversation_id = conversation.clone();
        Ok(conversation)
    }

    /// add_from_mention and add_from_link: the "Request sent" row holding the mentioned key from the start (so their
    /// answer comes back to it) and its request, in one transaction, so a refused fifth request leaves no row.
    pub fn start_keyed_id_request(&mut self, person: &Person, request: &mut IdRequest) -> Result<String> {
        let now = unix_now();
        let conversation = self.write(|conn| {
            save_in(conn, person)?;
            let mut saved = request.clone();
            saved.conversation_id = person.conversation_id.clone();
            save(conn, &saved, now)?;
            Ok(person.conversation_id.clone())
        })?;
        request.conversation_id = conversation.clone();
        Ok(conversation)
    }

    pub fn delete_id_request(&mut self, conversation_id: &str) -> Result<()> {
        self.write(|conn| {
            conn.execute("DELETE FROM id_requests WHERE conversation_id = ?1", [conversation_id])?;
            Ok(())
        })
    }

    /// A pure read for the key policy: the token names an unexpired request, the key is not blocked, and it already
    /// answered or a slot is free for it (`attested` keys may take the last one).
    pub fn id_request_admits(&self, token: &[u8], identity_key: &[u8; 32], attested: bool, now: f64) -> bool {
        if token.len() != 16 {
            return false;
        }
        self.conn
            .query_row(
                "SELECT EXISTS (SELECT 1 FROM id_request_answers WHERE request_token = ?1 AND identity_pk = ?2) OR \
                 ((SELECT count(*) FROM id_request_answers WHERE request_token = ?1) < ?3 AND (?5 OR (SELECT \
                 count(*) FROM id_request_answers WHERE request_token = ?1 AND attested = 0) < ?6)) FROM id_requests \
                 WHERE request_token = ?1 AND expires_at > ?4 AND NOT EXISTS (SELECT 1 FROM friends WHERE \
                 identity_pk = ?2 AND relation = 4)",
                params![
                    token.to_vec(),
                    identity_key.to_vec(),
                    ID_REQUEST_MAX_ANSWERS as i64,
                    now,
                    attested,
                    ID_REQUEST_MAX_UNATTESTED_ANSWERS as i64
                ],
                |r| r.get::<_, bool>(0),
            )
            .optional()
            .ok()
            .flatten()
            .unwrap_or(false)
    }

    /// An IK callback presenting a token went live: which conversation it belongs to, decided and recorded in one
    /// transaction (the rules are `SZFriendsStore.h`'s). `NotFound` for an unknown or expired token, `Invalid` for a
    /// blocked key, `Constraint` when the request has all the answers it admits.
    pub fn conversation_for_id_answer(
        &mut self,
        token: &[u8],
        identity_key: [u8; 32],
        static_key: [u8; 32],
        attested: bool,
        now: f64,
    ) -> Result<String> {
        self.write(|conn| {
            let token = token.to_vec();
            let request = requests(conn, "WHERE request_token = ?1 AND expires_at > ?2", &[&token, &now])?
                .into_iter()
                .next()
                .ok_or(StoreError::NotFound)?;
            let known = person_where(conn, "identity_pk = ?1", &identity_key.to_vec())?;
            if known.as_ref().is_some_and(|p| p.relation == Relation::Blocked) {
                return Err(StoreError::Invalid("blocked"));
            }
            let earlier: Option<String> = conn
                .query_row(
                    "SELECT conversation_id FROM id_request_answers WHERE request_token = ?1 AND identity_pk = ?2",
                    params![token, identity_key.to_vec()],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(earlier) = earlier {
                return Ok(earlier); // the same key calling back after a dropped session
            }
            let unattested: i64 = if attested {
                0
            } else {
                conn.query_row(
                    "SELECT count(*) FROM id_request_answers WHERE request_token = ?1 AND attested = 0",
                    [&token],
                    |r| r.get(0),
                )?
            };
            if request.answering_keys >= ID_REQUEST_MAX_ANSWERS
                || unattested as usize >= ID_REQUEST_MAX_UNATTESTED_ANSWERS
            {
                return Err(StoreError::Constraint);
            }
            let conversation = answer_conversation(conn, &request, known, identity_key, static_key, attested, now)?;
            conn.execute(
                "INSERT INTO id_request_answers (request_token, identity_pk, conversation_id, answered_at, attested) \
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![token, identity_key.to_vec(), conversation, now, attested],
            )?;
            conn.execute(
                "UPDATE id_requests SET answered_at = coalesce(answered_at, ?1) WHERE request_token = ?2",
                params![now, token],
            )?;
            Ok(conversation)
        })
    }
}
