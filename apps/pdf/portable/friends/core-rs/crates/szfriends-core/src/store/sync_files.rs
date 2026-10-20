//! The outbox and files between own devices (`SZFriendsStoreSyncFiles.m`): entries other devices may deliver too, the
//! profile's file records with who holds their bytes, and copies of files whose bytes came from another device.

use rusqlite::{params, Connection, OptionalExtension};

use super::sync_records::{sync_transfers, SyncTransfer};
use super::transfers::MAX_FILE_SIZE;
use super::{is_valid_identifier, unix_now, Result, StoreError};

/// An outbox entry as sync carries it (`SZFriendsOutboxEntry`).
#[derive(Clone, Debug, PartialEq)]
pub struct SyncEntry {
    pub entry_id: String,
    pub conversation_id: String,
    pub kind: i64,
    pub state: i64,
    pub created_at: f64,
    pub queued_at: Option<f64>,
    pub item_id: Option<String>,
    pub failure_reason: Option<String>,
    pub payload: Option<Vec<u8>>,
}

const KIND_REQUEST: i64 = 0;
const KIND_MESSAGE: i64 = 1;
const KIND_PRESENCE_SECRET: i64 = 4;
const QUEUED: i64 = 0;
const CONNECTING: i64 = 1;
const SENDING: i64 = 2;
const FAILED: i64 = 4;

/// Messages, requests and presence secrets: what other devices may deliver too.
pub fn syncable_outbox_entries(conn: &Connection) -> Result<Vec<SyncEntry>> {
    let mut statement = conn.prepare(
        "SELECT entry_id, conversation_id, kind, state, created_at, queued_at, item_id, failure_reason, payload \
         FROM outbox WHERE kind IN (?1, ?2, ?3) ORDER BY entry_id",
    )?;
    let rows = statement.query_map(params![KIND_MESSAGE, KIND_REQUEST, KIND_PRESENCE_SECRET], |r| {
        Ok(SyncEntry {
            entry_id: r.get(0)?,
            conversation_id: r.get(1)?,
            kind: r.get(2)?,
            state: r.get(3)?,
            created_at: r.get::<_, Option<f64>>(4)?.unwrap_or(0.0),
            queued_at: r.get(5)?,
            item_id: r.get(6)?,
            failure_reason: r.get(7)?,
            payload: r.get(8)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

/// An entry from another device: inserted when absent, else its state, failure and payload replaced. In-flight
/// states arrive as Queued, and a session of ours writing it now keeps it.
pub fn merge_synced_outbox_entry(conn: &Connection, entry: &SyncEntry) -> Result<()> {
    let item_ok = entry.item_id.as_deref().is_none_or(is_valid_identifier);
    let kind_ok = matches!(entry.kind, KIND_MESSAGE | KIND_REQUEST | KIND_PRESENCE_SECRET);
    if !is_valid_identifier(&entry.entry_id)
        || !is_valid_identifier(&entry.conversation_id)
        || !item_ok
        || !kind_ok
        || !(QUEUED..=FAILED).contains(&entry.state)
    {
        return Err(StoreError::Invalid("bad synced outbox entry"));
    }
    let state = if matches!(entry.state, CONNECTING | SENDING) { QUEUED } else { entry.state };
    let now = unix_now();
    let held: Option<i64> =
        conn.query_row("SELECT state FROM outbox WHERE entry_id = ?1", [&entry.entry_id], |r| r.get(0)).optional()?;
    if let Some(current) = held {
        if matches!(current, CONNECTING | SENDING) && state == QUEUED {
            return Ok(());
        }
        conn.execute(
            "UPDATE outbox SET state = ?1, failure_reason = ?2, payload = ?3, updated_at = ?4 WHERE entry_id = ?5",
            params![state, entry.failure_reason, entry.payload, now, entry.entry_id],
        )?;
        return Ok(());
    }
    let known: i64 =
        conn.query_row("SELECT count(*) FROM friends WHERE conversation_id = ?1", [&entry.conversation_id], |r| {
            r.get(0)
        })?;
    if known == 0 {
        return Err(StoreError::NotFound);
    }
    let created = entry.created_at;
    conn.execute(
        "INSERT INTO outbox (entry_id, conversation_id, kind, state, created_at, queued_at, attempts, item_id, \
         client_token, failure_reason, payload, updated_at) VALUES (?1,?2,?3,?4,?5,?6,0,?7,NULL,?8,?9,?10)",
        params![
            entry.entry_id,
            entry.conversation_id,
            entry.kind,
            state,
            created,
            entry.queued_at.unwrap_or(created),
            entry.item_id,
            entry.failure_reason,
            entry.payload,
            now
        ],
    )?;
    Ok(())
}

/// A transfer record as the whole profile knows it, with the devices holding its bytes (sorted).
#[derive(Clone, Debug, PartialEq)]
pub struct SyncFile {
    pub transfer_id: String,
    pub conversation_id: String,
    pub item_id: Option<String>,
    pub outgoing: bool,
    pub state: i64,
    pub file_name: String,
    pub uniform_type: Option<String>,
    pub size: u64,
    pub digest: Vec<u8>,
    pub created_at: f64,
    pub holders: Vec<[u8; 32]>,
}

fn holders(packed: &[u8]) -> Vec<[u8; 32]> {
    packed.chunks_exact(32).map(|c| c.try_into().expect("32")).collect()
}

fn pack_holders(holders: &[[u8; 32]]) -> Vec<u8> {
    let mut sorted = holders.to_vec();
    sorted.sort();
    sorted.dedup();
    sorted.concat()
}

fn sync_files_where(conn: &Connection, tail: &str, binds: &[&dyn rusqlite::ToSql]) -> Result<Vec<SyncFile>> {
    let mut statement = conn.prepare(&format!(
        "SELECT transfer_id, conversation_id, item_id, outgoing, state, file_name, uniform_type, size, digest, \
         created_at, holders FROM sync_files {tail}"
    ))?;
    let rows = statement.query_map(binds, |r| {
        Ok(SyncFile {
            transfer_id: r.get(0)?,
            conversation_id: r.get(1)?,
            item_id: r.get(2)?,
            outgoing: r.get::<_, i64>(3)? != 0,
            state: r.get(4)?,
            file_name: r.get(5)?,
            uniform_type: r.get(6)?,
            size: r.get::<_, i64>(7)?.max(0) as u64,
            digest: r.get(8)?,
            created_at: r.get::<_, Option<f64>>(9)?.unwrap_or(0.0),
            holders: holders(&r.get::<_, Vec<u8>>(10)?),
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn sync_file(conn: &Connection, transfer_id: &str) -> Result<Option<SyncFile>> {
    Ok(sync_files_where(conn, "WHERE transfer_id = ?1", &[&transfer_id])?.into_iter().next())
}

pub fn sync_files(conn: &Connection) -> Result<Vec<SyncFile>> {
    sync_files_where(conn, "ORDER BY transfer_id", &[])
}

pub fn save_sync_file(conn: &Connection, file: &SyncFile) -> Result<()> {
    if !is_valid_identifier(&file.transfer_id)
        || !is_valid_identifier(&file.conversation_id)
        || !file.item_id.as_deref().is_none_or(is_valid_identifier)
        || file.digest.len() != 32
        || file.file_name.is_empty()
        || file.size > MAX_FILE_SIZE
    {
        return Err(StoreError::Invalid("bad file record"));
    }
    conn.execute(
        "INSERT OR REPLACE INTO sync_files (transfer_id, conversation_id, item_id, outgoing, state, file_name, \
         uniform_type, size, digest, created_at, holders) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
        params![
            file.transfer_id,
            file.conversation_id,
            file.item_id,
            file.outgoing,
            file.state,
            file.file_name,
            file.uniform_type,
            file.size as i64,
            file.digest,
            file.created_at,
            pack_holders(&file.holders)
        ],
    )?;
    Ok(())
}

pub fn all_transfers(conn: &Connection) -> Result<Vec<SyncTransfer>> {
    sync_transfers(conn, "ORDER BY transfer_id", &[])
}

pub fn transfer(conn: &Connection, transfer_id: &str) -> Result<Option<SyncTransfer>> {
    Ok(sync_transfers(conn, "WHERE transfer_id = ?1", &[&transfer_id])?.into_iter().next())
}

pub fn item_id_for_transfer(conn: &Connection, transfer_id: &str, conversation_id: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT item_id FROM messages WHERE conversation_id = ?1 AND transfer_id = ?2",
            [conversation_id, transfer_id],
            |r| r.get(0),
        )
        .optional()?)
}

/// Only a copy: an outgoing row holding a received file and no snapshot of its own is one another device sent.
pub fn set_state_of_copied_transfer(conn: &Connection, transfer_id: &str, state: i64) -> Result<()> {
    conn.execute(
        "UPDATE transfers SET state = ?1, updated_at = ?2 WHERE transfer_id = ?3 AND outgoing = 1 AND \
         received_path IS NOT NULL AND staged_path IS NULL",
        params![state, unix_now(), transfer_id],
    )?;
    Ok(())
}

/// A transfers row for a file whose bytes were copied here (from another of our devices, or again from the friend
/// who sent it), pointing at `path` (in received/). A row already here lost its bytes (the caller copies only what is
/// not here): the copy replaces the path that is gone; the caller marks it published.
pub fn insert_copied_transfer(conn: &Connection, file: &SyncFile, path: &str) -> Result<()> {
    let held: i64 =
        conn.query_row("SELECT count(*) FROM transfers WHERE transfer_id = ?1", [&file.transfer_id], |r| r.get(0))?;
    let now = unix_now();
    if held > 0 {
        conn.execute(
            "UPDATE transfers SET received_path = ?1, updated_at = ?2 WHERE transfer_id = ?3",
            params![path, now, file.transfer_id],
        )?;
        return Ok(());
    }
    conn.execute(
        "INSERT INTO transfers (transfer_id, conversation_id, outgoing, state, file_name, uniform_type, size, digest, \
         verified_bytes, received_path, created_at, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?7,?9,?10,?11)",
        params![
            file.transfer_id,
            file.conversation_id,
            file.outgoing,
            file.state,
            file.file_name,
            file.uniform_type,
            file.size as i64,
            file.digest,
            path,
            file.created_at,
            now
        ],
    )?;
    Ok(())
}
