//! Friend requests in the store (`SZFriendsStoreRequests.m`, the settings of `SZFriendsStore.m`): requests nobody
//! answers lapse, history events, and the helper-wide nearby settings (our presence secret, the visibility deadline,
//! whether Nearby's permissions were asked).
//!
//! While a request waits, the requester's key is one the helper knows; that let someone who sent one request during
//! our five visible minutes follow our hidden device for as long as it sat unanswered. The helper bounds what such a
//! key may do to the first hours (`request_since`); this ends the wait itself.

use rusqlite::{params, Connection, OptionalExtension};

use super::people::{person_where, Person, Relation};
use super::{new_identifier, unix_now, Result, Store};

/// A friend request nobody answered lapses after 14 days.
pub const INCOMING_REQUEST_LIFETIME_SECONDS: f64 = 14.0 * 86_400.0;
/// A friend request we sent to someone visible nearby lapses after 7 days unanswered.
pub const OUTGOING_REQUEST_LIFETIME_SECONDS: f64 = 7.0 * 86_400.0;

/// History events the views word from the catalog (`SZFriendsEvent*`).
pub mod event {
    pub const NOW_FRIENDS: &str = "now_friends";
    pub const KEY_CHANGED: &str = "key_changed";
    pub const BLOCKED: &str = "blocked";
    pub const UNBLOCKED: &str = "unblocked";
    pub const REMOVED: &str = "removed";
    pub const VERIFIED: &str = "verified";
    pub const KEY_ACCEPTED: &str = "key_accepted";
}

const SETTING_PERMISSIONS: &str = "nearby_permissions_requested";
const SETTING_PRESENCE_SECRET: &str = "own_presence_secret";
const SETTING_VISIBILITY: &str = "visibility_deadline";

/// Requests we sent that nobody can answer any more: one to someone found nearby after the outgoing lifetime, and an
/// Add by ID row once no unexpired request of ours names it or was answered by its key. ?1 now, ?2 the nearby cutoff.
const OUTGOING_LAPSED: &str = "relation = 1 AND ((request_found_nearby = 1 AND \
     coalesce(request_since, request_at, last_interaction_at) <= ?2) OR (request_found_nearby = 0 AND \
     NOT EXISTS (SELECT 1 FROM id_requests r WHERE r.conversation_id = friends.conversation_id AND \
     r.expires_at > ?1) AND (identity_pk IS NULL OR NOT EXISTS (SELECT 1 FROM id_request_answers a JOIN \
     id_requests r ON r.request_token = a.request_token WHERE a.identity_pk = friends.identity_pk AND \
     r.expires_at > ?1))))";

fn lapsed_ids(conn: &Connection, clause: &str, binds: &[&dyn rusqlite::ToSql]) -> Result<Vec<String>> {
    let mut statement = conn.prepare(&format!("SELECT conversation_id FROM friends WHERE {clause}"))?;
    let ids = statement.query_map(binds, |r| r.get(0))?.collect::<std::result::Result<_, _>>()?;
    Ok(ids)
}

fn held(conn: &Connection, conversation_id: &str, outbox: bool) -> Result<i64> {
    let outbox = if outbox { " + (SELECT count(*) FROM outbox WHERE conversation_id = ?1)" } else { "" };
    let sql = format!(
        "SELECT (SELECT count(*) FROM messages WHERE conversation_id = ?1) + \
         (SELECT count(*) FROM transfers WHERE conversation_id = ?1){outbox}"
    );
    Ok(conn.query_row(&sql, [conversation_id], |r| r.get(0))?)
}

const BACK_TO_REMOVED: &str = "UPDATE friends SET relation = 3, request_since = NULL, callback_token = NULL, \
                               callback_secret = NULL, auto_accept = 0 WHERE conversation_id = ?1";

impl Store {
    /// Records a history event ("now_friends", "blocked"...) in a conversation, now.
    pub fn record_event(&mut self, conversation_id: &str, kind: &str) -> Result<()> {
        let now = unix_now();
        self.write(|conn| {
            conn.execute(
                "INSERT INTO messages (conversation_id, item_id, kind, direction, event_kind, sent_at, received_at) \
                 VALUES (?1, ?2, 2, 1, ?3, ?4, ?4)",
                params![conversation_id, new_identifier(), kind, now],
            )?;
            conn.execute(
                "UPDATE friends SET last_interaction_at = max(last_interaction_at, ?1) WHERE conversation_id = ?2",
                params![now, conversation_id],
            )?;
            Ok(())
        })
    }

    /// Friend requests nobody answered for 14 days, counted from when they began, lapse: a row holding nothing but
    /// the request is deleted; anyone else (a former friend asking again) becomes Removed with their history kept.
    /// Returns the lapsed people as they were.
    pub fn expire_incoming_requests(&mut self, now: f64) -> Result<Vec<Person>> {
        let cutoff = now - INCOMING_REQUEST_LIFETIME_SECONDS;
        self.write(|conn| {
            let clause = "relation = 0 AND coalesce(request_since, request_at, last_interaction_at) <= ?1";
            let mut lapsed = Vec::new();
            for id in lapsed_ids(conn, clause, &[&cutoff])? {
                lapsed.extend(person_where(conn, "conversation_id = ?1", &id)?);
                if held(conn, &id, true)? == 0 {
                    conn.execute("DELETE FROM friends WHERE conversation_id = ?1", [&id])?;
                } else {
                    conn.execute(BACK_TO_REMOVED, [&id])?;
                }
            }
            Ok(lapsed)
        })
    }

    /// Requests we sent that can no longer be answered lapse the same way (the queued request goes with them).
    pub fn expire_outgoing_requests(&mut self, now: f64) -> Result<Vec<Person>> {
        let cutoff = now - OUTGOING_REQUEST_LIFETIME_SECONDS;
        self.write(|conn| {
            let mut lapsed = Vec::new();
            for id in lapsed_ids(conn, OUTGOING_LAPSED, &[&now, &cutoff])? {
                lapsed.extend(person_where(conn, "conversation_id = ?1", &id)?);
                if held(conn, &id, false)? == 0 {
                    conn.execute("DELETE FROM friends WHERE conversation_id = ?1", [&id])?;
                    continue;
                }
                conn.execute("DELETE FROM id_requests WHERE conversation_id = ?1", [&id])?;
                conn.execute("DELETE FROM outbox WHERE conversation_id = ?1 AND item_id IS NULL", [&id])?;
                conn.execute(BACK_TO_REMOVED, [&id])?;
            }
            Ok(lapsed)
        })
    }

    /// For the key policy, a pure read: an unexpired Add by ID request of ours admitted this key.
    pub fn identity_key_answers_unexpired_id_request(&self, identity_key: &[u8; 32], now: f64) -> bool {
        self.conn
            .query_row(
                "SELECT EXISTS (SELECT 1 FROM id_request_answers a JOIN id_requests r ON r.request_token = \
                 a.request_token WHERE a.identity_pk = ?1 AND r.expires_at > ?2)",
                params![identity_key.to_vec(), now],
                |r| r.get::<_, bool>(0),
            )
            .unwrap_or(false)
    }

    fn setting<T: rusqlite::types::FromSql>(&self, key: &str) -> Option<T> {
        self.conn.query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0)).optional().ok()?
    }

    fn set_setting(&mut self, key: &str, value: Option<&dyn rusqlite::ToSql>) -> Result<()> {
        self.write(|conn| {
            match value {
                Some(value) => conn.execute(
                    "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET \
                     value = excluded.value",
                    params![key, value],
                )?,
                None => conn.execute("DELETE FROM settings WHERE key = ?1", [key])?,
            };
            Ok(())
        })
    }

    /// Nearby starts at launch only once the person was asked (ADR 0004 § Permissions at launch).
    pub fn nearby_permissions_requested(&self) -> bool {
        self.setting::<i64>(SETTING_PERMISSIONS).unwrap_or(0) != 0
    }

    pub fn set_nearby_permissions_requested(&mut self) -> Result<()> {
        self.set_setting(SETTING_PERMISSIONS, Some(&1))
    }

    /// Our presence secret, sent to each friend on acceptance; replaced on every remove or block.
    pub fn own_presence_secret(&self) -> Option<[u8; 32]> {
        self.setting::<Vec<u8>>(SETTING_PRESENCE_SECRET).and_then(|bytes| bytes.try_into().ok())
    }

    pub fn set_own_presence_secret(&mut self, secret: &[u8; 32]) -> Result<()> {
        self.set_setting(SETTING_PRESENCE_SECRET, Some(&secret.to_vec()))
    }

    /// Ours, drawn on first use.
    pub fn ensure_own_presence_secret(&mut self) -> Result<[u8; 32]> {
        if let Some(secret) = self.own_presence_secret() {
            return Ok(secret);
        }
        let secret = crate::nearby::callbacks::new_secret();
        self.set_own_presence_secret(&secret)?;
        Ok(secret)
    }

    /// The absolute end of the person's 5 minutes, Unix seconds.
    pub fn visibility_deadline(&self) -> Option<f64> {
        self.setting::<f64>(SETTING_VISIBILITY)
    }

    /// While a stored deadline is still ahead a later one is ignored (repeating start does not extend it); `None` or
    /// an earlier deadline always applies.
    pub fn set_visibility_deadline(&mut self, deadline: Option<f64>) -> Result<()> {
        let Some(deadline) = deadline else { return self.set_setting(SETTING_VISIBILITY, None) };
        let now = unix_now();
        self.write(|conn| {
            conn.execute(
                "INSERT INTO settings (key, value) VALUES ('visibility_deadline', ?1) ON CONFLICT(key) DO UPDATE \
                 SET value = CASE WHEN settings.value > ?2 AND settings.value < excluded.value THEN settings.value \
                 ELSE excluded.value END",
                params![deadline, now],
            )?;
            Ok(())
        })
    }

    /// Everyone whose relation is `relation`.
    pub fn people_with_relation(&self, relation: Relation) -> Vec<Person> {
        self.people_by_latest_interaction().unwrap_or_default().into_iter().filter(|p| p.relation == relation).collect()
    }
}
