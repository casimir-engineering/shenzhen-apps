//! What sync keeps (`SZFriendsStoreSync.m`, schema v9): the event log by (author, sequence number), contiguous per
//! author; last-writer-wins registers; sync state. Nothing here verifies a signature: an event reaches
//! [`append_event`] only after the sync area checked it. Every function takes the connection so that, inside
//! [`atomically`], reads see the transaction's own writes.

use std::collections::BTreeMap;

use rusqlite::types::Value;
use rusqlite::{params, Connection, OptionalExtension, Row};

use super::{Result, StoreError};

/// The conversation with yourself.
pub const YOU: &str = "you";
/// The sync state key holding the last history row a scan for new items read; a deletion clears it.
pub const CAPTURE_ROW_KEY: &str = "capture_row";

/// author -> highest sequence number held.
pub type Vector = BTreeMap<[u8; 32], u64>;

/// One event as the log keeps it; `body` is `None` once a deletion dropped it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogEvent {
    pub author: [u8; 32],
    pub seq: u64,
    pub lamport: u64,
    pub kind: i64,
    pub scope: String,
    pub subject: String,
    pub header: Vec<u8>,
    pub body: Option<Vec<u8>>,
    pub applied: bool,
}

/// A last-writer-wins value: the clock and author of the event that wrote it, and its bytes.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Register {
    pub lamport: u64,
    /// Empty for a register no event wrote.
    pub author: Vec<u8>,
    pub value: Option<Vec<u8>>,
}

/// Runs `body` as one transaction (a savepoint, so it nests): nothing commits unless it returns `Ok`.
pub fn atomically<T>(conn: &Connection, body: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
    conn.execute_batch("SAVEPOINT szf_sync")?;
    match body(conn) {
        Ok(value) => {
            conn.execute_batch("RELEASE szf_sync")?;
            Ok(value)
        }
        Err(error) => {
            let _ = conn.execute_batch("ROLLBACK TO szf_sync; RELEASE szf_sync");
            Err(error)
        }
    }
}

const EVENT_COLUMNS: &str = "author, seq, lamport, kind, scope, subject, header, body, applied";

fn event_from_row(row: &Row) -> rusqlite::Result<LogEvent> {
    let author: Vec<u8> = row.get(0)?;
    Ok(LogEvent {
        author: author.try_into().unwrap_or([0; 32]),
        seq: row.get::<_, i64>(1)? as u64,
        lamport: row.get::<_, i64>(2)? as u64,
        kind: row.get(3)?,
        scope: row.get(4)?,
        subject: row.get(5)?,
        header: row.get(6)?,
        body: row.get(7)?,
        applied: row.get::<_, i64>(8)? != 0,
    })
}

fn clamp(value: u64) -> i64 {
    value.min(i64::MAX as u64) as i64
}

fn events(conn: &Connection, tail: &str, binds: &[&dyn rusqlite::ToSql]) -> Result<Vec<LogEvent>> {
    let mut statement = conn.prepare(&format!("SELECT {EVENT_COLUMNS} FROM sync_events {tail}"))?;
    let rows = statement.query_map(binds, event_from_row)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn vector(conn: &Connection) -> Result<Vector> {
    let mut statement = conn.prepare("SELECT author, max(seq) FROM sync_events GROUP BY author")?;
    let rows = statement.query_map([], |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?)))?;
    let mut vector = Vector::new();
    for row in rows {
        let (author, seq) = row?;
        if let Ok(author) = author.try_into() {
            vector.insert(author, seq as u64);
        }
    }
    Ok(vector)
}

/// The sync state holding the clock a device that joined starts from: the approving device's when it welcomed it.
pub const STATE_JOIN_CLOCK: &str = "join_clock";

/// The highest Lamport clock in the log, or the one this device started from when it joined when that is higher; 0
/// when both are absent.
pub fn lamport(conn: &Connection) -> Result<u64> {
    let logged = conn.query_row("SELECT coalesce(max(lamport), 0) FROM sync_events", [], |r| r.get::<_, i64>(0))?;
    let joined = match state(conn, STATE_JOIN_CLOCK)? {
        Value::Integer(clock) => clock,
        _ => 0,
    };
    Ok(logged.max(joined).max(0) as u64)
}

pub fn event_count(conn: &Connection) -> Result<u64> {
    Ok(conn.query_row("SELECT count(*) FROM sync_events", [], |r| r.get::<_, i64>(0))? as u64)
}

/// Appends an event that follows its author's last one: `Ok(true)` appended, `Ok(false)` held already; a gap is
/// `Invalid` and stores nothing.
pub fn append_event(conn: &Connection, event: &LogEvent) -> Result<bool> {
    if event.seq < 1 || event.seq > i64::MAX as u64 || event.lamport < 1 || event.lamport > i64::MAX as u64 {
        return Err(StoreError::Invalid("bad sync event"));
    }
    if event.header.is_empty() {
        return Err(StoreError::Invalid("bad sync event"));
    }
    let last: i64 = conn.query_row(
        "SELECT coalesce(max(seq), 0) FROM sync_events WHERE author = ?1",
        [event.author.to_vec()],
        |r| r.get(0),
    )?;
    if event.seq <= last as u64 {
        return Ok(false);
    }
    if event.seq != last as u64 + 1 {
        return Err(StoreError::Invalid("a gap in the log"));
    }
    conn.execute(
        &format!("INSERT INTO sync_events ({EVENT_COLUMNS}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
        params![
            event.author.to_vec(),
            clamp(event.seq),
            clamp(event.lamport),
            event.kind,
            event.scope,
            event.subject,
            event.header,
            event.body,
            event.applied
        ],
    )?;
    Ok(true)
}

/// Events `vector` lacks, by author then sequence, at most `limit`.
pub fn events_missing_from(conn: &Connection, vector: &Vector, limit: usize) -> Result<Vec<LogEvent>> {
    let mut out = Vec::new();
    for author in super::sync_log::vector(conn)?.keys() {
        if out.len() >= limit {
            break;
        }
        let held = clamp(vector.get(author).copied().unwrap_or(0));
        let left = (limit - out.len()) as i64;
        out.extend(events(
            conn,
            "WHERE author = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3",
            &[&author.to_vec(), &held, &left],
        )?);
    }
    Ok(out)
}

pub fn event_with(conn: &Connection, author: &[u8; 32], seq: u64) -> Result<Option<LogEvent>> {
    Ok(events(conn, "WHERE author = ?1 AND seq = ?2", &[&author.to_vec(), &clamp(seq)])?.into_iter().next())
}

pub fn events_of_author_after(conn: &Connection, author: &[u8; 32], seq: u64) -> Result<Vec<LogEvent>> {
    events(conn, "WHERE author = ?1 AND seq > ?2 ORDER BY seq", &[&author.to_vec(), &clamp(seq)])
}

/// Not applied yet, by Lamport clock, author and sequence.
pub fn unapplied_events(conn: &Connection) -> Result<Vec<LogEvent>> {
    events(conn, "WHERE applied = 0 ORDER BY lamport, author, seq", &[])
}

pub fn events_of_kind(conn: &Connection, kind: i64) -> Result<Vec<LogEvent>> {
    events(conn, "WHERE kind = ?1 ORDER BY author, seq", &[&kind])
}

pub fn has_bodiless_event(conn: &Connection, kind: i64, subject: &str) -> Result<bool> {
    let count: i64 = conn.query_row(
        "SELECT count(*) FROM sync_events WHERE kind = ?1 AND subject = ?2 AND body IS NULL",
        params![kind, subject],
        |r| r.get(0),
    )?;
    Ok(count > 0)
}

pub fn mark_applied(conn: &Connection, author: &[u8; 32], seq: u64) -> Result<()> {
    conn.execute(
        "UPDATE sync_events SET applied = 1 WHERE author = ?1 AND seq = ?2",
        params![author.to_vec(), clamp(seq)],
    )?;
    Ok(())
}

pub fn drop_body(conn: &Connection, author: &[u8; 32], seq: u64) -> Result<()> {
    conn.execute(
        "UPDATE sync_events SET body = NULL WHERE author = ?1 AND seq = ?2",
        params![author.to_vec(), clamp(seq)],
    )?;
    Ok(())
}

fn registers_where(
    conn: &Connection,
    clause: &str,
    binds: &[&dyn rusqlite::ToSql],
) -> Result<BTreeMap<String, Register>> {
    let mut statement = conn.prepare(&format!("SELECT key, lamport, author, value FROM sync_registers {clause}"))?;
    let rows = statement.query_map(binds, |row| {
        Ok((
            row.get::<_, String>(0)?,
            Register { lamport: row.get::<_, i64>(1)? as u64, author: row.get(2)?, value: row.get(3)? },
        ))
    })?;
    Ok(rows.collect::<rusqlite::Result<BTreeMap<_, _>>>()?)
}

pub fn register(conn: &Connection, key: &str) -> Result<Option<Register>> {
    Ok(registers_where(conn, "WHERE key = ?1", &[&key])?.remove(key))
}

/// substr rather than LIKE: keys hold ids with '_', which LIKE reads as a wildcard.
pub fn registers_with_prefix(conn: &Connection, prefix: &str) -> Result<BTreeMap<String, Register>> {
    registers_where(conn, "WHERE substr(key, 1, ?1) = ?2", &[&(prefix.chars().count() as i64), &prefix])
}

pub fn set_register(conn: &Connection, key: &str, value: &Register) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO sync_registers (key, lamport, author, value) VALUES (?1, ?2, ?3, ?4)",
        params![key, clamp(value.lamport), value.author, value.value],
    )?;
    Ok(())
}

pub fn state(conn: &Connection, key: &str) -> Result<Value> {
    let value = conn.query_row("SELECT value FROM sync_state WHERE key = ?1", [key], |r| r.get(0)).optional()?;
    Ok(value.unwrap_or(Value::Null))
}

/// A state value as bytes, when it is a blob.
pub fn state_bytes(conn: &Connection, key: &str) -> Result<Option<Vec<u8>>> {
    Ok(match state(conn, key)? {
        Value::Blob(bytes) => Some(bytes),
        _ => None,
    })
}

/// Every state value whose key starts with `prefix`, by key.
pub fn states_with_prefix(conn: &Connection, prefix: &str) -> Result<Vec<(String, Value)>> {
    let mut statement = conn.prepare("SELECT key, value FROM sync_state WHERE substr(key, 1, ?2) = ?1 ORDER BY key")?;
    let rows = statement.query_map(params![prefix, prefix.len() as i64], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn set_state(conn: &Connection, key: &str, value: Value) -> Result<()> {
    if value == Value::Null {
        conn.execute("DELETE FROM sync_state WHERE key = ?1", [key])?;
    } else {
        conn.execute("INSERT OR REPLACE INTO sync_state (key, value) VALUES (?1, ?2)", params![key, value])?;
    }
    Ok(())
}
