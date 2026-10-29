//! The forward-only migration runner (ADR 0003 § Migrations; `SZFriendsStoreMigrate`). `PRAGMA user_version` is the
//! schema version; each migration runs in one `BEGIN IMMEDIATE` transaction with its version bump; before migrating a
//! store that already holds a schema, `VACUUM INTO 'friends.sqlite.before-v<N>'` keeps the latest backup only.

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, TransactionBehavior};

use super::schema::Migration;
use super::{new_identifier, unix_now, Result, StoreError};

/// `user_version` and `meta.min_reader_version` as found, before anything is written.
pub(super) fn read_versions(conn: &Connection) -> Result<(i64, i64)> {
    let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    let has_meta: i64 =
        conn.query_row("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'", [], |row| {
            row.get(0)
        })?;
    if has_meta == 0 {
        return Ok((version, 0));
    }
    let minimum: Option<String> =
        conn.query_row("SELECT value FROM meta WHERE key = 'min_reader_version'", [], |row| row.get(0)).optional()?;
    Ok((version, minimum.and_then(|text| text.parse().ok()).unwrap_or(0)))
}

/// VACUUM INTO writes a consistent copy without blocking the WAL. Only the latest backup is kept: older ones hold
/// history the person may since have deleted, and the newest is the one a failed upgrade needs.
fn back_up(conn: &Connection, database: &Path, target: i64) -> Result<()> {
    let directory = database.parent().ok_or(StoreError::MigrationFailed("no directory".into()))?;
    let prefix = format!("{}.before-v", database.file_name().and_then(|n| n.to_str()).unwrap_or("friends.sqlite"));
    let name = format!("{prefix}{target}");
    let backup = directory.join(&name);
    let _ = std::fs::remove_file(&backup); // VACUUM INTO refuses an existing file, even an empty one
    let path = backup.to_str().ok_or(StoreError::MigrationFailed("path is not UTF-8".into()))?;
    conn.execute("VACUUM INTO ?1", [path])?;
    // The copy holds the whole history, so it gets the database's own 0600.
    super::transfer_files::make_private(&backup);
    if let Ok(entries) = std::fs::read_dir(directory) {
        for entry in entries.flatten() {
            let other = entry.file_name().to_string_lossy().into_owned();
            if other.starts_with(&prefix) && other != name {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    Ok(())
}

/// Runs every pending migration; returns the resulting `user_version`. A failed migration leaves the database at its
/// last committed version and the backup intact.
pub(super) fn migrate(conn: &Connection, database: &Path, migrations: &[Migration]) -> Result<i64> {
    let (mut current, _) = read_versions(conn)?;
    let mut pending: Vec<&Migration> = migrations.iter().filter(|m| m.version > current).collect();
    szfriends_wire::order::sort_by_key(&mut pending, |m| m.version);
    let Some(last) = pending.last() else { return Ok(current) };
    // A version-0 file is new and empty: nothing to protect yet.
    if current > 0 {
        back_up(conn, database, last.version)
            .map_err(|_| StoreError::MigrationFailed("could not write the pre-migration backup".into()))?;
    }
    for migration in pending {
        let applied = (|| -> Result<()> {
            let transaction = rusqlite::Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
            transaction.execute_batch(migration.sql)?;
            if migration.version == 1 {
                let seed = "INSERT INTO meta(key, value) VALUES ('store_id', ?1), ('created_at', ?2)";
                transaction.execute(seed, [new_identifier(), format!("{:.3}", unix_now())])?;
            }
            // user_version lives in the header page, so it commits or rolls back with the migration itself.
            transaction.execute_batch(&format!("PRAGMA user_version = {}", migration.version))?;
            if migration.min_reader_version > 0 {
                transaction.execute(
                    "INSERT INTO meta(key, value) VALUES ('min_reader_version', ?1) \
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [migration.min_reader_version.to_string()],
                )?;
            }
            transaction.commit()?;
            Ok(())
        })();
        if let Err(error) = applied {
            return Err(StoreError::MigrationFailed(format!("migration to v{} failed: {error}", migration.version)));
        }
        current = migration.version;
    }
    Ok(current)
}
