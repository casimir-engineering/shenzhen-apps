//! Friend links and links received in the store (schema v7; `SZFriendsStoreLinks.m`, friends-links.md): the invite
//! tokens behind this person's friend link (one standing token until Reset, one-time tokens for 30 days), the invite
//! one of our own Add by ID requests presents, the people in the list only because they sent a file through a link
//! (link contacts), and a file arriving through a download link this person chose to receive.

use std::collections::BTreeSet;

use rusqlite::{params, Connection, OptionalExtension, Row};

use super::people::{insert_item, person_where};
use super::transfer_files::{create_staging_file, sanitized_file_name};
use super::transfers::{self, apply_event, set_column, TransferEvent, TransferRecord, TransferState};
use super::{is_valid_identifier, unix_now, Direction, Item, ItemKind, Relation, Result, Store, StoreError};

/// Requests the standing friend link accepts at once in any 24 hours; past it they wait for the person, so a link
/// that leaks cannot make friends of strangers faster than this.
pub const INVITE_ACCEPTS_PER_DAY: usize = 20;
pub const ONE_TIME_INVITE_LIFETIME: f64 = 30.0 * 86_400.0;
const ACCEPTS_KEY: &str = "invite_accepts.";

/// One invite token: in the friend link, presented (as a proof bound to the session) by whoever uses the link.
#[derive(Clone, Debug, PartialEq)]
pub struct InviteRecord {
    pub token: [u8; 16],
    pub one_time: bool,
    pub created_at: f64,
    /// None: until Reset (the standing link).
    pub expires_at: Option<f64>,
    pub used_at: Option<f64>,
    pub revoked_at: Option<f64>,
}

fn invite_from_row(row: &Row) -> rusqlite::Result<InviteRecord> {
    let token: Vec<u8> = row.get(0)?;
    Ok(InviteRecord {
        token: token.try_into().unwrap_or([0; 16]),
        one_time: row.get::<_, i64>(1)? != 0,
        created_at: row.get(2)?,
        expires_at: row.get(3)?,
        used_at: row.get(4)?,
        revoked_at: row.get(5)?,
    })
}

fn invites(conn: &Connection, tail: &str, binds: &[&dyn rusqlite::ToSql]) -> Result<Vec<InviteRecord>> {
    let sql = format!("SELECT token, one_time, created_at, expires_at, used_at, revoked_at FROM invites {tail}");
    let mut statement = conn.prepare(&sql)?;
    let rows = statement.query_map(binds, invite_from_row)?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

fn insert_invite(conn: &Connection, one_time: bool, now: f64) -> Result<InviteRecord> {
    let mut token = [0u8; 16];
    crate::crypto::random_bytes(&mut token);
    let expires_at = one_time.then_some(now + ONE_TIME_INVITE_LIFETIME);
    conn.execute(
        "INSERT INTO invites (token, one_time, created_at, expires_at) VALUES (?1, ?2, ?3, ?4)",
        params![token.to_vec(), one_time, now, expires_at],
    )?;
    Ok(InviteRecord { token, one_time, created_at: now, expires_at, used_at: None, revoked_at: None })
}

const LIVE: &str = "revoked_at IS NULL AND used_at IS NULL AND (expires_at IS NULL OR expires_at > ?1)";

/// The standing invite's acceptances over the last 24 hours (settings key "invite_accepts.<token hex>", the times as
/// Unix seconds to the millisecond separated by spaces): one more unless the day's limit already happened.
fn count_accept(conn: &Connection, token: &[u8; 16], now: f64) -> Result<()> {
    let key = format!("{ACCEPTS_KEY}{}", token.iter().map(|b| format!("{b:02x}")).collect::<String>());
    let stored: Option<String> =
        conn.query_row("SELECT value FROM settings WHERE key = ?1", [&key], |r| r.get(0)).optional()?.flatten();
    // `now` is compared as it is kept, so an acceptance stored rounded up stays inside the window it counted in.
    let stamp = (now * 1000.0).round() / 1000.0;
    let mut recent: Vec<String> = stored
        .unwrap_or_default()
        .split(' ')
        .filter(|t| t.parse::<f64>().is_ok_and(|t| t > stamp - 86_400.0 && t <= stamp))
        .map(str::to_owned)
        .collect();
    if recent.len() >= INVITE_ACCEPTS_PER_DAY {
        return Err(StoreError::Constraint);
    }
    recent.push(format!("{stamp:.3}"));
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, recent.join(" ")],
    )?;
    Ok(())
}

impl Store {
    /// The standing invite, made when there is none and `create` (otherwise None then).
    pub fn standing_invite(&mut self, create: bool) -> Result<Option<InviteRecord>> {
        self.write(|conn| {
            let found = invites(conn, "WHERE one_time = 0 AND revoked_at IS NULL ORDER BY created_at DESC", &[])?;
            match found.into_iter().next() {
                Some(invite) => Ok(Some(invite)),
                None if create => insert_invite(conn, false, unix_now()).map(Some),
                None => Ok(None),
            }
        })
    }

    /// Reset: the standing invite is revoked and a new one made, its daily count starting afresh.
    pub fn reset_standing_invite(&mut self, now: f64) -> Result<InviteRecord> {
        self.write(|conn| {
            conn.execute("UPDATE invites SET revoked_at = ?1 WHERE one_time = 0 AND revoked_at IS NULL", [now])?;
            conn.execute("DELETE FROM settings WHERE key LIKE 'invite_accepts.%'", [])?;
            insert_invite(conn, false, now)
        })
    }

    pub fn create_one_time_invite(&mut self, now: f64) -> Result<InviteRecord> {
        self.write(|conn| insert_invite(conn, true, now))
    }

    /// Invites a request may present now: not revoked, not used, not expired.
    pub fn live_invites(&self, now: f64) -> Vec<InviteRecord> {
        invites(&self.conn, &format!("WHERE {LIVE} ORDER BY created_at"), &[&now]).unwrap_or_default()
    }

    /// A request presented `token` and is accepted through it: a one-time invite is used up (Stale once it is no
    /// longer live); the standing one stays live and counts the acceptance, refusing (Constraint, nothing counted)
    /// past [`INVITE_ACCEPTS_PER_DAY`] in the 24 hours before `now`.
    pub fn use_invite(&mut self, token: &[u8; 16], now: f64) -> Result<()> {
        self.write(|conn| {
            let tail = format!("WHERE token = ?2 AND {LIVE}");
            let invite = invites(conn, &tail, &[&now, &token.to_vec()])?.pop().ok_or(StoreError::Stale)?;
            if !invite.one_time {
                return count_accept(conn, token, now);
            }
            conn.execute("UPDATE invites SET used_at = ?1 WHERE token = ?2", params![now, token.to_vec()])?;
            Ok(())
        })
    }

    /// The invite our own Add by ID request `conversation_id` presents (its id_requests row must exist).
    pub fn set_invite_token_for_id_request(&mut self, conversation_id: &str, token: &[u8; 16]) -> Result<()> {
        self.write(|conn| {
            conn.execute(
                "INSERT INTO link_requests (conversation_id, invite_token) VALUES (?1, ?2) \
                 ON CONFLICT(conversation_id) DO UPDATE SET invite_token = excluded.invite_token",
                params![conversation_id, token.to_vec()],
            )?;
            Ok(())
        })
    }

    pub fn invite_token_for_id_request(&self, conversation_id: &str) -> Option<[u8; 16]> {
        let token: Option<Vec<u8>> = self
            .conn
            .query_row("SELECT invite_token FROM link_requests WHERE conversation_id = ?1", [conversation_id], |r| {
                r.get(0)
            })
            .optional()
            .ok()
            .flatten();
        token.and_then(|t| t.try_into().ok())
    }

    /// Someone in the list only through a link they used to send a file: marked when their row is made for it,
    /// forgotten with the row, and no longer one once they are friends.
    pub fn mark_link_contact(&mut self, conversation_id: &str) -> Result<()> {
        self.write(|conn| {
            conn.execute("INSERT OR IGNORE INTO link_contacts (conversation_id) VALUES (?1)", [conversation_id])?;
            Ok(())
        })
    }

    pub fn link_contact_conversations(&self) -> BTreeSet<String> {
        let sql = "SELECT c.conversation_id FROM link_contacts c JOIN friends f USING (conversation_id) \
                   WHERE f.relation <> ?1";
        let Ok(mut statement) = self.conn.prepare(sql) else { return BTreeSet::new() };
        let ids = statement.query_map([Relation::Friend as i64], |r| r.get::<_, String>(0));
        ids.map(|rows| rows.flatten().collect()).unwrap_or_default()
    }

    /// A file arriving through a download link this person chose to receive: an incoming transfer accepted from the
    /// start (Receiving, with its staging file) and its history item, in the conversation of whoever sent it,
    /// whatever their relation except Blocked. Its chunks and its end then go through `append_chunk` and
    /// `finish_transfer`, which check `digest` (the BLAKE2b the sender signed) as for any transfer.
    pub fn record_link_transfer(
        &mut self,
        transfer_id: &str,
        conversation_id: &str,
        name: &str,
        uniform_type: Option<&str>,
        size: u64,
        digest: &[u8; 32],
    ) -> Result<TransferRecord> {
        if !is_valid_identifier(transfer_id)
            || name.is_empty()
            || name.len() > transfers::MAX_NAME_BYTES
            || size > transfers::MAX_FILE_SIZE
            || uniform_type.is_some_and(|t| t.len() > 255)
        {
            return Err(StoreError::Invalid("bad transfer"));
        }
        let partial_directory = self.state_dir().join("received").join(".partial");
        let staging = create_staging_file(&partial_directory)?;
        let recorded = self.write(|conn| {
            let person = person_where(conn, "conversation_id = ?1", &conversation_id)?;
            if person.is_none_or(|p| p.relation == Relation::Blocked) {
                return Err(StoreError::Invalid("no such sender"));
            }
            if !transfers::rows(conn, "WHERE transfer_id = ?1 COLLATE NOCASE", &[&transfer_id])?.is_empty() {
                return Err(StoreError::Invalid("transfer id taken"));
            }
            let now = unix_now();
            let record = TransferRecord {
                transfer_id: transfer_id.to_owned(),
                conversation_id: conversation_id.to_owned(),
                outgoing: false,
                state: TransferState::WaitingForYou,
                file_name: sanitized_file_name(name),
                uniform_type: uniform_type.map(str::to_owned),
                size,
                digest: *digest,
                verified_bytes: 0,
                staged_path: None,
                received_path: None,
                failure_reason: None,
                source_path: None,
                source_mtime_ns: 0,
            };
            transfers::insert(conn, &record, None)?;
            let item = Item {
                item_id: transfer_id.to_owned(),
                conversation_id: conversation_id.to_owned(),
                kind: ItemKind::Transfer,
                direction: Direction::Incoming,
                text: None,
                transfer_id: Some(transfer_id.to_owned()),
                sent_at: now,
                received_at: now,
                via_assistant: false,
            };
            insert_item(conn, &item)?;
            set_column(conn, transfer_id, "partial_path", &staging.to_string_lossy().into_owned())?;
            apply_event(conn, transfer_id, TransferEvent::Accepted, None)?;
            conn.execute("UPDATE transfers SET received_via = 1 WHERE transfer_id = ?1", [transfer_id])?;
            transfers::load(conn, transfer_id)?.ok_or(StoreError::NotFound)
        });
        if recorded.is_err() {
            let _ = std::fs::remove_file(&staging); // the row that named it rolled back
        }
        recorded
    }

    /// An event in `conversation_id`'s history with its arguments ("Sent you {file} through a link").
    pub fn record_event_with(
        &mut self,
        conversation_id: &str,
        kind: &str,
        arguments: &serde_json::Value,
    ) -> Result<()> {
        let now = unix_now();
        self.write(|conn| {
            conn.execute(
                "INSERT INTO messages (conversation_id, item_id, kind, direction, event_kind, event_args, sent_at, \
                 received_at) VALUES (?1, ?2, 2, 0, ?3, ?4, ?5, ?5)",
                params![conversation_id, super::new_identifier(), kind, arguments.to_string(), now],
            )?;
            conn.execute(
                "UPDATE friends SET last_interaction_at = max(last_interaction_at, ?1) WHERE conversation_id = ?2",
                params![now, conversation_id],
            )?;
            Ok(())
        })
    }
}
