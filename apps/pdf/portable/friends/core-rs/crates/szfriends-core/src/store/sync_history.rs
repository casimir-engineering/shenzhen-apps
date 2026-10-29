//! History between own devices (`SZFriendsStoreSyncHistory.m`): the You conversation, which events put each item here
//! (origins), items copied from other devices, deletions that take exactly what the deleting device had seen, removed
//! devices' late events purged, and unread counts worked out from a read marker every device agrees on.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};

use super::sync_log::{atomically, Vector, CAPTURE_ROW_KEY, YOU};
use super::sync_records::{item_from_row, sync_insert_item, SyncItem, ITEM_COLUMNS};
use super::{is_valid_identifier, unix_now, Result, StoreError};

fn clamp(value: u64) -> i64 {
    value.min(i64::MAX as u64) as i64
}

pub fn ensure_you_conversation(conn: &Connection) -> Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO friends (conversation_id, relation, last_interaction_at) VALUES (?1, 2, ?2)",
        params![YOU, unix_now()],
    )?;
    Ok(())
}

/// Items with no origin yet, oldest row first, after row `after`, and the last row read.
pub fn items_without_origin(conn: &Connection, after: i64, limit: usize) -> Result<(Vec<SyncItem>, i64)> {
    let sql = format!(
        "SELECT {ITEM_COLUMNS}, m.seq FROM messages m WHERE m.seq > ?1 AND NOT EXISTS (SELECT 1 FROM sync_origins o \
         WHERE o.conversation_id = m.conversation_id AND o.item_id = m.item_id) ORDER BY m.seq LIMIT ?2"
    );
    let mut statement = conn.prepare(&sql)?;
    let mut last = after;
    let mut items = Vec::new();
    let mut rows = statement.query(params![after, limit as i64])?;
    while let Some(row) = rows.next()? {
        items.push(item_from_row(row)?);
        last = row.get(12)?;
    }
    Ok((items, last))
}

pub type Origin = ([u8; 32], u64);

pub fn origins_of_item(conn: &Connection, item_id: &str, conversation_id: &str) -> Result<Vec<Origin>> {
    let mut statement =
        conn.prepare("SELECT author, seq FROM sync_origins WHERE conversation_id = ?1 AND item_id = ?2")?;
    let rows =
        statement.query_map([conversation_id, item_id], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?)))?;
    let mut out = Vec::new();
    for row in rows {
        let (author, seq) = row?;
        if let Ok(author) = author.try_into() {
            out.push((author, seq as u64));
        }
    }
    Ok(out)
}

pub fn origins_in_conversation(conn: &Connection, conversation_id: &str) -> Result<BTreeMap<String, Vec<Origin>>> {
    let mut statement = conn.prepare("SELECT item_id, author, seq FROM sync_origins WHERE conversation_id = ?1")?;
    let rows = statement
        .query_map([conversation_id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?, r.get::<_, i64>(2)?)))?;
    let mut out: BTreeMap<String, Vec<Origin>> = BTreeMap::new();
    for row in rows {
        let (item, author, seq) = row?;
        if let Ok(author) = author.try_into() {
            out.entry(item).or_default().push((author, seq as u64));
        }
    }
    Ok(out)
}

pub fn add_origin(conn: &Connection, item_id: &str, conversation_id: &str, author: &[u8; 32], seq: u64) -> Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO sync_origins (conversation_id, item_id, author, seq) VALUES (?1, ?2, ?3, ?4)",
        params![conversation_id, item_id, author.to_vec(), clamp(seq)],
    )?;
    Ok(())
}

/// An item copied from another device: inserted when absent, otherwise its times lowered to the earliest any device
/// saw, with its origin recorded. An item a deletion took stays deleted.
pub fn merge_synced_item(conn: &Connection, item: &SyncItem, author: &[u8; 32], seq: u64) -> Result<()> {
    if !is_valid_identifier(&item.conversation_id) || !is_valid_identifier(&item.item_id) {
        return Err(StoreError::Invalid("bad synced item"));
    }
    atomically(conn, |conn| {
        if is_deleted(conn, &item.item_id, &item.conversation_id)? {
            return Ok(());
        }
        let sent = if item.direction == 0 { item.sent_at.min(item.received_at) } else { item.sent_at };
        if !sync_insert_item(conn, item)? {
            conn.execute(
                "UPDATE messages SET received_at = min(received_at, ?1), sent_at = min(sent_at, ?2) \
                 WHERE conversation_id = ?3 AND item_id = ?4",
                params![item.received_at, sent, item.conversation_id, item.item_id],
            )?;
        }
        add_origin(conn, &item.item_id, &item.conversation_id, author, seq)
    })
}

pub fn is_deleted(conn: &Connection, item_id: &str, conversation_id: &str) -> Result<bool> {
    let count: i64 = conn.query_row(
        "SELECT count(*) FROM sync_deleted WHERE conversation_id = ?1 AND item_id = ?2",
        [conversation_id, item_id],
        |r| r.get(0),
    )?;
    Ok(count > 0)
}

/// Removes items with their transfers, previews and outbox entries (private files into `files`), marks them deleted
/// for good unless `keepable`, and drops the bodies of the events that carried them.
fn delete_items(
    conn: &Connection,
    items: &[(String, String)],
    file_kind: i64,
    outbox_kind: i64,
    files: &mut Vec<String>,
    keepable: bool,
) -> Result<()> {
    for (conversation, item) in items {
        let mut transfer: Option<String> = conn
            .query_row(
                "SELECT transfer_id FROM messages WHERE conversation_id = ?1 AND item_id = ?2",
                [conversation, item],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        if transfer.is_none() {
            transfer = conn
                .query_row(
                    "SELECT transfer_id FROM sync_files WHERE conversation_id = ?1 AND item_id = ?2",
                    [conversation, item],
                    |r| r.get(0),
                )
                .optional()?
                .flatten();
        }
        if let Some(transfer) = transfer {
            let paths: Option<(Option<String>, Option<String>)> = conn
                .query_row("SELECT staged_path, partial_path FROM transfers WHERE transfer_id = ?1", [&transfer], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .optional()?;
            if let Some((staged, partial)) = paths {
                files.extend(staged.into_iter().chain(partial).filter(|p| !p.is_empty()));
            }
            let mut thumbnails = conn.prepare("SELECT png_name FROM transfer_thumbnails WHERE transfer_id = ?1")?;
            let names = thumbnails.query_map([&transfer], |r| r.get::<_, String>(0))?;
            for name in names {
                files.push(format!("thumbnails/{}", name?));
            }
            conn.execute("DELETE FROM transfers WHERE transfer_id = ?1", [&transfer])?;
            conn.execute("DELETE FROM sync_files WHERE transfer_id = ?1", [&transfer])?;
            conn.execute(
                "UPDATE sync_events SET body = NULL WHERE subject = ?1 AND kind = ?2",
                params![transfer, file_kind],
            )?;
        }
        conn.execute(
            "UPDATE sync_events SET body = NULL WHERE kind = ?1 AND subject IN \
             (SELECT entry_id FROM outbox WHERE conversation_id = ?2 AND item_id = ?3)",
            params![outbox_kind, conversation, item],
        )?;
        conn.execute(
            "UPDATE sync_events SET body = NULL WHERE (author, seq) IN \
             (SELECT author, seq FROM sync_origins WHERE conversation_id = ?1 AND item_id = ?2)",
            [conversation, item],
        )?;
        conn.execute("DELETE FROM outbox WHERE conversation_id = ?1 AND item_id = ?2", [conversation, item])?;
        conn.execute("DELETE FROM messages WHERE conversation_id = ?1 AND item_id = ?2", [conversation, item])?;
        conn.execute("DELETE FROM sync_origins WHERE conversation_id = ?1 AND item_id = ?2", [conversation, item])?;
        if !keepable {
            conn.execute(
                "INSERT OR IGNORE INTO sync_deleted (conversation_id, item_id) VALUES (?1, ?2)",
                [conversation, item],
            )?;
        }
    }
    conn.execute("DELETE FROM sync_state WHERE key = ?1", [CAPTURE_ROW_KEY])?;
    Ok(())
}

/// The store's delete path (`-deleteRows:`): rows in one transaction with the search index rebuilt, then the private
/// files, then a compaction so deleted text does not survive in free pages.
fn delete_rows(
    conn: &Connection,
    state_dir: &Path,
    rows: impl FnOnce(&Connection, &mut Vec<String>) -> Result<()>,
) -> Result<()> {
    let mut files = Vec::new();
    atomically(conn, |conn| {
        rows(conn, &mut files)?;
        let has_search: i64 =
            conn.query_row("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'search'", [], |r| {
                r.get(0)
            })?;
        if has_search > 0 {
            conn.execute_batch("INSERT INTO search(search) VALUES ('rebuild')")?;
        }
        conn.execute("DELETE FROM meta WHERE key = 'search_stale'", [])?;
        Ok(())
    })?;
    for file in files {
        // Only the store's own private files: a path outside the state directory is never touched.
        let path = state_dir.join(&file);
        if path.starts_with(state_dir) && !file.split('/').any(|part| part == "..") {
            let _ = std::fs::remove_file(path);
        }
    }
    // Freed pages are scrubbed now, or, inside a store batch (which VACUUM cannot run in), right after it commits.
    if conn.is_autocommit() {
        vacuum(conn)?;
    } else {
        conn.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('vacuum_pending', '1')", [])?;
    }
    Ok(())
}

/// Rewrites the file without the deleted rows' pages, and empties the WAL that still held them.
pub(crate) fn vacuum(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM meta WHERE key = 'vacuum_pending'", [])?;
    conn.execute_batch("VACUUM")?;
    conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
    Ok(())
}

/// A deletion: every item in `conversation` (`None`: all) one of whose origins `vector` covers goes, and stays gone.
/// Returns the conversations that lost items.
pub fn delete_synced_items(
    conn: &Connection,
    state_dir: &Path,
    conversation: Option<&str>,
    vector: &Vector,
    file_kind: i64,
    outbox_kind: i64,
) -> Result<Vec<String>> {
    let mut touched = BTreeSet::new();
    delete_rows(conn, state_dir, |conn, files| {
        let mut items: Vec<(String, String)> = Vec::new();
        for (author, seq) in vector {
            let up_to = clamp(*seq);
            if up_to == 0 {
                continue;
            }
            let mut statement = conn.prepare(
                "SELECT DISTINCT conversation_id, item_id FROM sync_origins WHERE author = ?1 AND seq <= ?2 \
                 AND (?3 IS NULL OR conversation_id = ?3)",
            )?;
            let rows =
                statement.query_map(params![author.to_vec(), up_to, conversation], |r| Ok((r.get(0)?, r.get(1)?)))?;
            for row in rows {
                let pair: (String, String) = row?;
                if !items.contains(&pair) {
                    items.push(pair);
                }
            }
        }
        touched.extend(items.iter().map(|(c, _)| c.clone()));
        delete_items(conn, &items, file_kind, outbox_kind, files, false)
    })?;
    Ok(touched.into_iter().collect())
}

/// Delete history with no other device to tell (`-deleteHistoryInConversation:`): every message and file of
/// `conversation` (`None`: every chat) goes with its previews and private files, and what the outbox still had to
/// send of them; requests, answers and secrets carry no item and stay queued. Received files stay.
pub fn delete_history(conn: &Connection, state_dir: &Path, conversation: Option<&str>) -> Result<()> {
    if conversation.is_some_and(|c| !is_valid_identifier(c)) {
        return Err(StoreError::Invalid("bad conversation"));
    }
    let filter = "(?1 IS NULL OR conversation_id = ?1)";
    delete_rows(conn, state_dir, |conn, files| {
        let mut statement = conn.prepare(&format!("SELECT staged_path, partial_path FROM transfers WHERE {filter}"))?;
        let paths = statement.query_map([conversation], |r| Ok((r.get::<_, Option<String>>(0)?, r.get(1)?)))?;
        for row in paths {
            let (staged, partial): (Option<String>, Option<String>) = row?;
            files.extend(staged.into_iter().chain(partial).filter(|p| !p.is_empty()));
        }
        let mut statement = conn.prepare(&format!(
            "SELECT png_name FROM transfer_thumbnails WHERE transfer_id IN (SELECT transfer_id FROM transfers \
             WHERE {filter})"
        ))?;
        for name in statement.query_map([conversation], |r| r.get::<_, String>(0))? {
            files.push(format!("thumbnails/{}", name?));
        }
        conn.execute(&format!("DELETE FROM outbox WHERE item_id IS NOT NULL AND {filter}"), [conversation])?;
        conn.execute(&format!("DELETE FROM transfers WHERE {filter}"), [conversation])?;
        conn.execute(&format!("DELETE FROM messages WHERE {filter}"), [conversation])?;
        conn.execute(&format!("UPDATE friends SET unread_count = 0 WHERE {filter}"), [conversation])?;
        Ok(())
    })
}

/// One item a deletion covers that arrived after it (or without its body): gone, and marked so it stays gone.
pub fn mark_deleted_item(
    conn: &Connection,
    state_dir: &Path,
    item_id: &str,
    conversation_id: &str,
    file_kind: i64,
    outbox_kind: i64,
) -> Result<()> {
    if !is_valid_identifier(conversation_id) || !is_valid_identifier(item_id) {
        return Err(StoreError::Invalid("bad item"));
    }
    let pair = [(conversation_id.to_owned(), item_id.to_owned())];
    let present: i64 = conn.query_row(
        "SELECT count(*) FROM messages WHERE conversation_id = ?1 AND item_id = ?2",
        [conversation_id, item_id],
        |r| r.get(0),
    )?;
    if present == 0 {
        return atomically(conn, |conn| delete_items(conn, &pair, file_kind, outbox_kind, &mut Vec::new(), false));
    }
    delete_rows(conn, state_dir, |conn, files| delete_items(conn, &pair, file_kind, outbox_kind, files, false))
}

/// A removed device's events past `seq`: gone from the log; the items only they put here go (not marked deleted).
pub fn purge_events_of_author(
    conn: &Connection,
    state_dir: &Path,
    author: &[u8; 32],
    seq: u64,
    file_kind: i64,
    outbox_kind: i64,
) -> Result<Vec<String>> {
    if super::sync_log::events_of_author_after(conn, author, seq)?.is_empty() {
        return Ok(Vec::new());
    }
    let mut touched = BTreeSet::new();
    delete_rows(conn, state_dir, |conn, files| {
        let mut statement = conn.prepare(
            "SELECT DISTINCT conversation_id, item_id FROM sync_origins o WHERE author = ?1 AND seq > ?2 \
             AND NOT EXISTS (SELECT 1 FROM sync_origins p WHERE p.conversation_id = o.conversation_id \
             AND p.item_id = o.item_id AND NOT (p.author = ?1 AND p.seq > ?2))",
        )?;
        let items: Vec<(String, String)> = statement
            .query_map(params![author.to_vec(), clamp(seq)], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        delete_items(conn, &items, file_kind, outbox_kind, files, true)?;
        touched.extend(items.into_iter().map(|(c, _)| c));
        conn.execute("DELETE FROM sync_origins WHERE author = ?1 AND seq > ?2", params![author.to_vec(), clamp(seq)])?;
        conn.execute("DELETE FROM sync_events WHERE author = ?1 AND seq > ?2", params![author.to_vec(), clamp(seq)])?;
        Ok(())
    })?;
    Ok(touched.into_iter().collect())
}

/// Unread = incoming messages and files received after (received_at, item_id); all of them without a marker.
pub fn recount_unread(conn: &Connection, conversation: &str, through: Option<(f64, &str)>) -> Result<()> {
    let count = "SELECT count(*) FROM messages WHERE conversation_id = ?1 AND direction = 0 AND kind IN (0, 1)";
    match through {
        Some((at, item)) => conn.execute(
            &format!(
                "UPDATE friends SET unread_count = ({count} AND (received_at > ?2 OR (received_at = ?2 AND \
                 item_id > ?3))) WHERE conversation_id = ?1"
            ),
            params![conversation, at, item],
        )?,
        None => conn.execute(
            &format!("UPDATE friends SET unread_count = ({count}) WHERE conversation_id = ?1"),
            [conversation],
        )?,
    };
    Ok(())
}

/// The incoming message or file with exactly `newer` incoming ones after it.
pub fn incoming_item(conn: &Connection, conversation: &str, newer: u64) -> Result<Option<SyncItem>> {
    let sql = format!(
        "SELECT {ITEM_COLUMNS} FROM messages m WHERE m.conversation_id = ?1 AND m.direction = 0 AND m.kind IN (0, 1) \
         ORDER BY m.received_at DESC, m.item_id DESC LIMIT 1 OFFSET ?2"
    );
    Ok(conn.query_row(&sql, params![conversation, newer as i64], item_from_row).optional()?)
}

pub fn item(conn: &Connection, conversation: &str, item_id: &str) -> Result<Option<SyncItem>> {
    let sql = format!("SELECT {ITEM_COLUMNS} FROM messages m WHERE m.conversation_id = ?1 AND m.item_id = ?2");
    Ok(conn.query_row(&sql, [conversation, item_id], item_from_row).optional()?)
}
