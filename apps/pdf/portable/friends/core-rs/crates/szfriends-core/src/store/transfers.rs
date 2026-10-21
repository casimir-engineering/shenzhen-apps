//! Transfers (`SZFriendsTransfers.h`): the state machine, the rows, outgoing snapshots, offers and the other side's
//! answers. Everything a peer names is checked against the conversation it came from, which must own the transfer.
//! Resume restarts from the recipient's verified byte count, bound to offer id, sender, recipient and digest; the same
//! mechanism moves a transfer between routes. The receiving side's files are `receive.rs`.

use std::collections::HashSet;
use std::path::PathBuf;

use rusqlite::{params, Connection, Row};

use super::people::{insert_item, person_where, Direction, Item, ItemKind, Relation};
use super::transfer_files::{create_staging_file, file_digest, sanitized_file_name, snapshot};
pub use super::transfer_states::{TransferEvent, TransferState};
use super::{is_valid_identifier, new_identifier, unix_now, Result, Store, StoreError};

/// PROTOCOL.md sizes are JSON integers: 2^53 - 1.
pub const MAX_FILE_SIZE: u64 = (1 << 53) - 1;
pub const MAX_NAME_BYTES: usize = 1024;
pub const MAX_PENDING_OFFERS: i64 = 200;
pub const FAILURE_DIGEST_MISMATCH: &str = "digest_mismatch";

#[derive(Clone, Debug, PartialEq)]
pub struct TransferRecord {
    /// The offer id, 128 random bits as hex.
    pub transfer_id: String,
    pub conversation_id: String,
    pub outgoing: bool,
    pub state: TransferState,
    pub file_name: String,
    pub uniform_type: Option<String>,
    pub size: u64,
    /// BLAKE2b-256 of the whole file, carried in OFFER and checked after DONE.
    pub digest: [u8; 32],
    /// Resume point: bytes written, fsynced and committed.
    pub verified_bytes: u64,
    pub staged_path: Option<PathBuf>,
    pub received_path: Option<PathBuf>,
    pub failure_reason: Option<String>,
    /// Outgoing: the file the person chose, and its modification time (nanoseconds since 1970) when it was
    /// snapshotted. While it is unchanged this device still holds the file's bytes after the snapshot is gone
    /// (ADR 0016). Never synced.
    pub source_path: Option<PathBuf>,
    pub source_mtime_ns: i64,
}

const COLUMNS: &str = "transfer_id, conversation_id, outgoing, state, file_name, uniform_type, size, digest, \
                       verified_bytes, staged_path, received_path, failure_reason, source_path, source_mtime_ns";

fn record_from_row(row: &Row) -> rusqlite::Result<TransferRecord> {
    let digest: Vec<u8> = row.get(7)?;
    Ok(TransferRecord {
        transfer_id: row.get(0)?,
        conversation_id: row.get(1)?,
        outgoing: row.get::<_, i64>(2)? != 0,
        state: TransferState::from_i64(row.get(3)?).unwrap_or(TransferState::Failed),
        file_name: row.get(4)?,
        uniform_type: row.get(5)?,
        size: row.get::<_, i64>(6)?.max(0) as u64,
        digest: digest.try_into().unwrap_or([0; 32]),
        verified_bytes: row.get::<_, i64>(8)?.max(0) as u64,
        staged_path: row.get::<_, Option<String>>(9)?.map(PathBuf::from),
        received_path: row.get::<_, Option<String>>(10)?.map(PathBuf::from),
        failure_reason: row.get(11)?,
        source_path: row.get::<_, Option<String>>(12)?.map(PathBuf::from),
        source_mtime_ns: row.get::<_, Option<i64>>(13)?.unwrap_or(0),
    })
}

pub(super) fn rows(conn: &Connection, tail: &str, binds: &[&dyn rusqlite::ToSql]) -> Result<Vec<TransferRecord>> {
    let mut statement = conn.prepare(&format!("SELECT {COLUMNS} FROM transfers {tail}"))?;
    let records = statement.query_map(binds, record_from_row)?;
    Ok(records.collect::<std::result::Result<_, _>>()?)
}

pub(super) fn load(conn: &Connection, transfer_id: &str) -> Result<Option<TransferRecord>> {
    Ok(rows(conn, "WHERE transfer_id = ?1", &[&transfer_id])?.pop())
}

pub(super) fn insert(conn: &Connection, record: &TransferRecord, partial: Option<&str>) -> Result<()> {
    if !is_valid_identifier(&record.transfer_id)
        || !is_valid_identifier(&record.conversation_id)
        || record.size > MAX_FILE_SIZE
    {
        return Err(StoreError::Invalid("bad transfer record"));
    }
    let now = unix_now();
    conn.execute(
        &format!(
            "INSERT INTO transfers ({COLUMNS}, partial_path, created_at, updated_at) \
                  VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?16)"
        ),
        params![
            record.transfer_id,
            record.conversation_id,
            record.outgoing,
            record.state as i64,
            record.file_name,
            record.uniform_type,
            record.size as i64,
            record.digest.to_vec(),
            record.verified_bytes as i64,
            record.staged_path.as_ref().map(|p| p.to_string_lossy().into_owned()),
            record.received_path.as_ref().map(|p| p.to_string_lossy().into_owned()),
            record.failure_reason,
            record.source_path.as_ref().map(|p| p.to_string_lossy().into_owned()),
            record.source_path.as_ref().map(|_| record.source_mtime_ns),
            partial,
            now
        ],
    )?;
    Ok(())
}

/// One state-machine event; Stale when it does not apply, so a late or replayed answer changes nothing.
pub(super) fn apply_event(
    conn: &Connection,
    transfer_id: &str,
    event: TransferEvent,
    reason: Option<&str>,
) -> Result<TransferState> {
    let record = load(conn, transfer_id)?.ok_or(StoreError::NotFound)?;
    let next = event.next_state(record.outgoing, record.state);
    if next == record.state {
        return Err(StoreError::Stale);
    }
    let reason = if next == TransferState::Failed { reason } else { None };
    conn.execute(
        "UPDATE transfers SET state = ?1, failure_reason = ?2, updated_at = ?3 WHERE transfer_id = ?4",
        params![next as i64, reason, unix_now(), transfer_id],
    )?;
    // Every state change passes here: an offer that ended without its file loses its preview with it.
    if matches!(next, TransferState::Declined | TransferState::Cancelled | TransferState::Failed)
        && matches!(record.state, TransferState::Queued | TransferState::Offered | TransferState::WaitingForYou)
    {
        conn.execute("DELETE FROM transfer_thumbnails WHERE transfer_id = ?1", [transfer_id])?;
    }
    Ok(next)
}

pub(super) fn set_column(
    conn: &Connection,
    transfer_id: &str,
    column: &str,
    value: &dyn rusqlite::ToSql,
) -> Result<()> {
    const ALLOWED: [&str; 9] = [
        "received_at",
        "received_via",
        "verified_bytes",
        "staged_path",
        "partial_path",
        "final_path",
        "publishing",
        "received_path",
        "failure_reason",
    ];
    if !ALLOWED.contains(&column) {
        return Err(StoreError::Invalid("unknown column"));
    }
    let sql = format!("UPDATE transfers SET {column} = ?1, updated_at = ?2 WHERE transfer_id = ?3");
    conn.execute(&sql, params![value, unix_now(), transfer_id])?;
    Ok(())
}

/// The transfer only when `conversation_id` owns it: the lookup for an id a peer named.
fn owned(conn: &Connection, transfer_id: &str, conversation_id: &str, outgoing: bool) -> Result<TransferRecord> {
    match load(conn, transfer_id)? {
        Some(record)
            if !conversation_id.is_empty()
                && record.conversation_id == conversation_id
                && record.outgoing == outgoing =>
        {
            Ok(record)
        }
        _ => Err(StoreError::Invalid("not this friend's transfer")),
    }
}

impl Store {
    pub fn transfer(&self, transfer_id: &str) -> Result<Option<TransferRecord>> {
        load(&self.conn, transfer_id)
    }

    /// Inbound transfers still Receiving: on every new session the recipient sends PROGRESS for each.
    pub fn unfinished_incoming_transfers(&self, conversation_id: &str) -> Result<Vec<TransferRecord>> {
        rows(
            &self.conn,
            "WHERE conversation_id = ?1 AND outgoing = 0 AND state = ?2 ORDER BY created_at",
            &[&conversation_id, &(TransferState::Receiving as i64)],
        )
    }

    /// Binds a file to an immutable snapshot in `outgoing/` before offering it, and records the transfer as Queued.
    pub fn stage_outgoing_file(
        &mut self,
        source: &std::path::Path,
        display_name: Option<&str>,
        conversation_id: &str,
    ) -> Result<TransferRecord> {
        let directory = self.state_dir().join("outgoing");
        super::transfer_files::ensure_private_directory(&directory)?;
        let transfer_id = new_identifier();
        let staged = directory.join(&transfer_id);
        // Before the copy, so a change during it shows later.
        let source_mtime_ns = super::transfer_files::modified_ns(source);
        let (size, digest) = snapshot(source, &staged).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => StoreError::FileMissing,
            _ => StoreError::from(e),
        })?;
        let name =
            display_name.map(str::to_owned).or_else(|| source.file_name().map(|n| n.to_string_lossy().into_owned()));
        let record = TransferRecord {
            transfer_id,
            conversation_id: conversation_id.to_owned(),
            outgoing: true,
            state: TransferState::Queued,
            file_name: sanitized_file_name(name.as_deref().unwrap_or_default()),
            uniform_type: None,
            size,
            digest,
            verified_bytes: 0,
            staged_path: Some(staged.clone()),
            received_path: None,
            failure_reason: None,
            source_path: std::path::absolute(source).ok(),
            source_mtime_ns,
        };
        let result = self.write(|conn| {
            insert(conn, &record, None)?;
            let now = unix_now();
            let item = Item {
                item_id: record.transfer_id.clone(),
                conversation_id: record.conversation_id.clone(),
                kind: ItemKind::Transfer,
                direction: Direction::Outgoing,
                text: None,
                transfer_id: Some(record.transfer_id.clone()),
                sent_at: now,
                received_at: now,
                via_assistant: false,
            };
            insert_item(conn, &item).map(|_| ())
        });
        if result.is_err() {
            let _ = std::fs::remove_file(&staged);
        }
        result.map(|()| record)
    }

    /// An OFFER from a friend, with its history item, in one transaction; refused for anyone who is not an unblocked
    /// friend or an offer out of limits. Idempotent by offer id within the conversation; an id that matches, ignoring
    /// case, another transfer is refused.
    #[allow(clippy::too_many_arguments)]
    pub fn record_incoming_offer(
        &mut self,
        transfer_id: &str,
        conversation_id: &str,
        name: &str,
        uniform_type: Option<&str>,
        size: u64,
        digest: &[u8; 32],
        sent_at: f64,
    ) -> Result<TransferRecord> {
        if name.is_empty() || name.len() > MAX_NAME_BYTES || size > MAX_FILE_SIZE {
            return Err(StoreError::Invalid("offer out of limits"));
        }
        self.write(|conn| {
            let person = person_where(conn, "conversation_id = ?1", &conversation_id)?;
            if person.is_none_or(|p| p.relation != Relation::Friend) {
                return Err(StoreError::Invalid("offers come only from friends"));
            }
            let same = rows(conn, "WHERE transfer_id = ?1 COLLATE NOCASE", &[&transfer_id])?;
            if let Some(existing) = same.first() {
                if existing.transfer_id == transfer_id
                    && existing.conversation_id == conversation_id
                    && !existing.outgoing
                {
                    return Ok(existing.clone());
                }
                return Err(StoreError::Invalid("offer id taken"));
            }
            let pending: i64 = conn.query_row(
                "SELECT count(*) FROM transfers WHERE conversation_id = ?1 AND outgoing = 0 AND state = ?2",
                params![conversation_id, TransferState::WaitingForYou as i64],
                |r| r.get(0),
            )?;
            if pending >= MAX_PENDING_OFFERS {
                return Err(StoreError::Invalid("too many unanswered offers"));
            }
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
            insert(conn, &record, None)?;
            let item = Item {
                item_id: transfer_id.to_owned(),
                conversation_id: conversation_id.to_owned(),
                kind: ItemKind::Transfer,
                direction: Direction::Incoming,
                text: None,
                transfer_id: Some(transfer_id.to_owned()),
                sent_at,
                received_at: unix_now(),
                via_assistant: false,
            };
            insert_item(conn, &item)?;
            Ok(record)
        })
    }

    /// This person accepts an offer: Receiving, with a fresh private staging file.
    pub fn accept_transfer(&mut self, transfer_id: &str) -> Result<()> {
        let partial_directory = self.state_dir().join("received").join(".partial");
        self.write(|conn| {
            let record = load(conn, transfer_id)?.ok_or(StoreError::NotFound)?;
            if record.outgoing || record.state != TransferState::WaitingForYou {
                return Err(StoreError::Stale);
            }
            let staging = create_staging_file(&partial_directory)?;
            set_column(conn, transfer_id, "partial_path", &staging.to_string_lossy().into_owned())?;
            apply_event(conn, transfer_id, TransferEvent::Accepted, None).map(|_| ())
        })
    }

    /// Their device acknowledged our OFFER.
    pub fn mark_offer_delivered(&mut self, transfer_id: &str, conversation_id: &str) -> Result<()> {
        self.write(|conn| {
            owned(conn, transfer_id, conversation_id, true)?;
            apply_event(conn, transfer_id, TransferEvent::OfferDelivered, None).map(|_| ())
        })
    }

    /// They answered our offer. Accepting continues from `offset` only for our own offer to this friend, with the
    /// offset within the file and the snapshot still hashing to the offered digest; a resend of the same acceptance
    /// (a new session resuming) is allowed while Sending.
    pub fn peer_answered_transfer(
        &mut self,
        transfer_id: &str,
        accepted: bool,
        offset: u64,
        conversation_id: &str,
    ) -> Result<TransferRecord> {
        let mut verified = std::mem::take(&mut self.receiving.verified_snapshots);
        let result = self.write(|conn| {
            let record = owned(conn, transfer_id, conversation_id, true)?;
            if !accepted {
                apply_event(conn, transfer_id, TransferEvent::Declined, None)?;
                return load(conn, transfer_id)?.ok_or(StoreError::NotFound);
            }
            let resuming = record.state == TransferState::Sending;
            if offset > record.size
                || (!resuming && TransferEvent::Accepted.next_state(true, record.state) == record.state)
            {
                return Err(StoreError::Stale);
            }
            if !snapshot_matches(&record, &mut verified) {
                apply_event(conn, transfer_id, TransferEvent::Failed, Some(super::outbox::FAILURE_SOURCE_MISSING))?;
                return Err(StoreError::FileMissing);
            }
            if !resuming {
                apply_event(conn, transfer_id, TransferEvent::Accepted, None)?;
            }
            load(conn, transfer_id)?.ok_or(StoreError::NotFound)
        });
        self.receiving.verified_snapshots = verified;
        result
    }

    /// Their device verified our file: Delivered, and the outgoing snapshot goes.
    pub fn peer_verified_transfer(&mut self, transfer_id: &str, conversation_id: &str) -> Result<()> {
        let staged = self.write(|conn| {
            let record = owned(conn, transfer_id, conversation_id, true)?;
            apply_event(conn, transfer_id, TransferEvent::Verified, None)?;
            Ok(record.staged_path)
        })?;
        if let Some(path) = staged {
            let _ = std::fs::remove_file(path);
        }
        Ok(())
    }

    pub fn peer_cancelled_transfer(&mut self, transfer_id: &str, conversation_id: &str) -> Result<()> {
        self.write(|conn| {
            let record = load(conn, transfer_id)?.ok_or(StoreError::NotFound)?;
            if conversation_id.is_empty() || record.conversation_id != conversation_id {
                return Err(StoreError::Invalid("not this friend's transfer"));
            }
            apply_event(conn, transfer_id, TransferEvent::Cancelled, None).map(|_| ())
        })?;
        self.receiving.forget(transfer_id);
        Ok(())
    }

    /// Reads `length` bytes at `offset` from an outgoing transfer's snapshot, for its next CHUNK.
    pub fn read_outgoing(&self, record: &TransferRecord, offset: u64, length: usize) -> Result<Vec<u8>> {
        use std::io::{Read, Seek, SeekFrom};
        let path = record.staged_path.as_ref().ok_or(StoreError::FileMissing)?;
        let mut file = std::fs::File::open(path).map_err(|_| StoreError::FileMissing)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut buffer = vec![0u8; length];
        file.read_exact(&mut buffer)?;
        Ok(buffer)
    }
}

/// The snapshot still hashes to the offered digest; checked once per run for each transfer.
fn snapshot_matches(record: &TransferRecord, verified: &mut HashSet<String>) -> bool {
    if verified.contains(&record.transfer_id) {
        return true;
    }
    let matches = record.staged_path.as_ref().and_then(|path| file_digest(path, u64::MAX).ok()) == Some(record.digest);
    if matches {
        verified.insert(record.transfer_id.clone());
    }
    matches
}
