//! The receiving side of a transfer (`SZFriendsTransferReceiver.m`; ADR 0003 § Durable progress, § Crash recovery):
//! chunks into a private staging file, durable progress, the whole-file digest as streamed and as read back from
//! disk, publishing into `received/` without overwriting anything, and recovery after a crash.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use blake2::digest::{Update, VariableOutput};
use rusqlite::Connection;

use super::transfer_files::{
    create_staging_file, digest_prefix, ensure_private_directory, move_no_replace, unique_destination,
};
use super::transfers::{self, apply_event, set_column, TransferEvent, TransferRecord, TransferState};
use super::{Result, Store, StoreError};

/// Progress becomes durable every 4 MiB or every second, whichever comes first, and at the last byte.
pub const DURABLE_BATCH_BYTES: u64 = 4 << 20;
const DURABLE_BATCH_INTERVAL: Duration = Duration::from_secs(1);

/// One download in progress: its open staging file, running digest, and how much is written versus durable.
struct Download {
    file: File,
    hasher: blake2::Blake2bVar,
    written: u64,
    durable: u64,
    partial: PathBuf,
    last_commit: Instant,
}

/// The store's in-memory state for transfers: open downloads, and snapshots already verified this run.
#[derive(Default)]
pub(crate) struct Receiving {
    open: HashMap<String, Download>,
    pub(super) verified_snapshots: HashSet<String>,
}

impl Receiving {
    pub(super) fn forget(&mut self, transfer_id: &str) {
        self.open.remove(transfer_id);
    }
}

fn open_rw(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::custom_flags(&mut options, rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    options.open(path)
}

fn partial_path(conn: &Connection, transfer_id: &str) -> Result<Option<PathBuf>> {
    let path: Option<String> =
        conn.query_row("SELECT partial_path FROM transfers WHERE transfer_id = ?1", [transfer_id], |r| r.get(0))?;
    Ok(path.map(PathBuf::from))
}

/// Reopens a download after a restart or a route change: bytes past the durable count were never confirmed, so they
/// are cut off, and the digest is rebuilt from the durable prefix once.
fn reopen(conn: &Connection, record: &TransferRecord) -> Result<Download> {
    let partial = partial_path(conn, &record.transfer_id)?.ok_or(StoreError::Invalid("no staging file"))?;
    let mut file = open_rw(&partial).map_err(|_| StoreError::FileMissing)?;
    let length = file.metadata()?.len();
    let durable = record.verified_bytes.min(length);
    file.set_len(durable)?;
    if durable != record.verified_bytes {
        set_column(conn, &record.transfer_id, "verified_bytes", &(durable as i64))?;
    }
    file.seek(SeekFrom::Start(0))?;
    let mut hasher = blake2::Blake2bVar::new(32).expect("32-byte output");
    let mut reader = std::io::Read::take(&mut file, durable);
    std::io::copy(&mut reader, &mut HashWriter(&mut hasher))?;
    Ok(Download { file, hasher, written: durable, durable, partial, last_commit: Instant::now() })
}

struct HashWriter<'a>(&'a mut blake2::Blake2bVar);

impl Write for HashWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.update(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// The file about to be published, read back: still the file the staging path names, a regular file of the offered
/// size, hashing to the offered digest. The streamed digest covers bytes as they arrived; this covers what is on disk.
fn staged_file_matches(file: &mut File, path: &Path, record: &TransferRecord) -> bool {
    let (Ok(opened), Ok(named)) = (file.metadata(), fs::symlink_metadata(path)) else { return false };
    if !named.is_file() || opened.len() != record.size {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if opened.dev() != named.dev() || opened.ino() != named.ino() {
            return false;
        }
    }
    file.seek(SeekFrom::Start(0)).is_ok() && digest_prefix(file, record.size).ok() == Some(record.digest)
}

/// The row must say Receiving, for this sender, on every chunk: anything else is unsolicited.
fn receiving_record(conn: &Connection, transfer_id: &str, conversation_id: &str) -> Result<(TransferRecord, bool)> {
    let record = transfers::load(conn, transfer_id)?;
    let live = record.as_ref().is_some_and(|r| !r.outgoing && r.state == TransferState::Receiving);
    match record {
        Some(record) if live && !conversation_id.is_empty() && record.conversation_id == conversation_id => {
            Ok((record, true))
        }
        _ => Err(if live { StoreError::Invalid("unsolicited chunk") } else { StoreError::Stale }),
    }
}

impl Store {
    fn download(&mut self, record: &TransferRecord) -> Result<()> {
        if !self.receiving.open.contains_key(&record.transfer_id) {
            let download = self.write(|conn| reopen(conn, record))?;
            self.receiving.open.insert(record.transfer_id.clone(), download);
        }
        Ok(())
    }

    /// Full fsync first, commit second: the database never claims a byte the disk could still lose.
    fn commit(&mut self, transfer_id: &str) -> Result<()> {
        let Some(download) = self.receiving.open.get_mut(transfer_id) else { return Ok(()) };
        if download.durable == download.written {
            return Ok(());
        }
        download.file.sync_all()?;
        let written = download.written;
        self.write(|conn| set_column(conn, transfer_id, "verified_bytes", &(written as i64)))?;
        if let Some(download) = self.receiving.open.get_mut(transfer_id) {
            download.durable = written;
            download.last_commit = Instant::now();
        }
        Ok(())
    }

    /// Appends a chunk at exactly the verified count from the conversation that owns the transfer, and returns the
    /// durable byte count, which is what PROGRESS may report.
    pub fn append_chunk(&mut self, transfer_id: &str, offset: u64, bytes: &[u8], conversation_id: &str) -> Result<u64> {
        let (record, _) = match receiving_record(&self.conn, transfer_id, conversation_id) {
            Ok(found) => found,
            Err(error) => {
                if error == StoreError::Stale {
                    self.receiving.forget(transfer_id); // only a dead transfer loses its open file
                }
                return Err(StoreError::Invalid("unsolicited chunk"));
            }
        };
        self.download(&record)?;
        let download = self.receiving.open.get_mut(transfer_id).expect("opened above");
        if offset != download.written || bytes.len() as u64 > record.size - download.written {
            return Err(StoreError::Invalid("chunk out of place"));
        }
        download.file.seek(SeekFrom::Start(offset))?;
        if let Err(error) = download.file.write_all(bytes) {
            let _ = download.file.set_len(download.written);
            return Err(error.into());
        }
        download.hasher.update(bytes);
        download.written += bytes.len() as u64;
        let due = download.written - download.durable >= DURABLE_BATCH_BYTES
            || download.last_commit.elapsed() >= DURABLE_BATCH_INTERVAL
            || download.written == record.size;
        if due {
            self.commit(transfer_id)?;
        }
        Ok(self.receiving.open.get(transfer_id).map_or(0, |d| d.durable))
    }

    /// Makes every received byte durable now (session lost, handover, exit), so the next resume starts from it.
    pub fn flush_progress(&mut self) -> Result<()> {
        let open: Vec<String> = self.receiving.open.keys().cloned().collect();
        for transfer_id in open {
            self.commit(&transfer_id)?;
        }
        Ok(())
    }

    /// DONE: publishes into `received/` only when the sender's final digest, the streamed digest and the staged file
    /// read back from disk all match the offer; otherwise deletes the file and fails the transfer (DigestMismatch).
    pub fn finish_transfer(
        &mut self,
        transfer_id: &str,
        final_digest: &[u8],
        conversation_id: &str,
    ) -> Result<PathBuf> {
        let (record, _) = receiving_record(&self.conn, transfer_id, conversation_id)
            .map_err(|_| StoreError::Invalid("unsolicited DONE"))?;
        self.download(&record)?;
        if self.receiving.open.get(transfer_id).is_some_and(|d| d.written != record.size) {
            return Err(StoreError::Invalid("file is incomplete"));
        }
        self.commit(transfer_id)?;
        let mut download = self.receiving.open.remove(transfer_id).expect("opened above");
        let mut computed = [0u8; 32];
        download.hasher.clone().finalize_variable(&mut computed).expect("length matches");
        let matches = final_digest == record.digest
            && computed == record.digest
            && staged_file_matches(&mut download.file, &download.partial, &record);
        drop(download.file);
        if matches {
            return self.publish(&record, &download.partial);
        }
        let _ = fs::remove_file(&download.partial);
        self.write(|conn| fail_mismatched(conn, transfer_id))?;
        Err(StoreError::DigestMismatch)
    }

    /// A download that stopped for good (a link that dropped too often, a file that did not check): nothing partial
    /// is kept, and the transfer says it failed.
    pub fn fail_received_transfer(&mut self, transfer_id: &str) -> Result<()> {
        self.receiving.forget(transfer_id);
        if let Some(partial) = partial_path(&self.conn, transfer_id)? {
            let _ = fs::remove_file(partial);
        }
        self.write(|conn| fail_mismatched(conn, transfer_id))
    }

    /// Records the destination before the move, so a crash between move and commit is finished at the next start;
    /// the move refuses an existing destination (`move_no_replace`), so nothing is ever overwritten.
    fn publish(&mut self, record: &TransferRecord, partial: &Path) -> Result<PathBuf> {
        let directory = self.state_dir().join("received");
        ensure_private_directory(&directory)?;
        for _ in 0..8 {
            let destination = unique_destination(&directory, &record.file_name);
            let text = destination.to_string_lossy().into_owned();
            self.write(|conn| {
                set_column(conn, &record.transfer_id, "final_path", &text)?;
                set_column(conn, &record.transfer_id, "publishing", &1)
            })?;
            match move_no_replace(partial, &destination) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e.into()),
            }
            sync_directory(&directory);
            self.write(|conn| mark_received(conn, record, &text))?;
            return Ok(destination);
        }
        Err(StoreError::Database("no free destination name".into()))
    }

    /// ADR 0003 § Crash recovery for files: finish publishing, truncate staging files to their durable count, and
    /// delete private files no row references.
    pub(super) fn recover_transfers(&mut self) -> Result<()> {
        let partial_directory = self.state_dir().join("received").join(".partial");
        let publishing = transfers::rows(&self.conn, "WHERE publishing = 1", &[])?;
        for record in publishing {
            let partial = partial_path(&self.conn, &record.transfer_id)?;
            let final_path: Option<String> = self.conn.query_row(
                "SELECT final_path FROM transfers WHERE transfer_id = ?1",
                [&record.transfer_id],
                |r| r.get(0),
            )?;
            let staged = partial.as_ref().filter(|p| fs::symlink_metadata(p).is_ok());
            if let Some(partial) = staged {
                let ok = File::open(partial).is_ok_and(|mut f| staged_file_matches(&mut f, partial, &record));
                if ok {
                    // An empty file at the recorded destination while the staged file is still here is the name the
                    // interrupted move claimed (or a link to an empty file): ours to remove before publishing again.
                    let claimed = final_path
                        .as_ref()
                        .map(Path::new)
                        .filter(|p| fs::symlink_metadata(p).is_ok_and(|m| m.is_file() && m.len() == 0));
                    if let Some(claimed) = claimed {
                        let _ = fs::remove_file(claimed);
                    }
                    self.publish(&record, &partial.clone())?;
                } else {
                    let _ = fs::remove_file(partial);
                    self.write(|conn| fail_mismatched(conn, &record.transfer_id))?;
                }
            } else if let Some(published) = final_path.filter(|p| fs::symlink_metadata(p).is_ok()) {
                // Moved before the crash, committed after it: the digest was verified before the move.
                self.write(|conn| mark_received(conn, &record, &published))?;
            } else {
                let fresh = create_staging_file(&partial_directory)?.to_string_lossy().into_owned();
                self.write(|conn| {
                    set_column(conn, &record.transfer_id, "publishing", &0)?;
                    set_column(conn, &record.transfer_id, "final_path", &rusqlite::types::Null)?;
                    set_column(conn, &record.transfer_id, "partial_path", &fresh)?;
                    set_column(conn, &record.transfer_id, "verified_bytes", &0)
                })?;
            }
        }
        let receiving =
            transfers::rows(&self.conn, "WHERE outgoing = 0 AND state = ?1", &[&(TransferState::Receiving as i64)])?;
        for record in receiving {
            self.receiving.forget(&record.transfer_id);
            let present =
                partial_path(&self.conn, &record.transfer_id)?.is_some_and(|p| fs::symlink_metadata(p).is_ok());
            if present {
                // Truncates past the durable count and corrects a count the disk no longer backs.
                self.download(&record)?;
            } else {
                let fresh = create_staging_file(&partial_directory)?.to_string_lossy().into_owned();
                self.write(|conn| {
                    set_column(conn, &record.transfer_id, "partial_path", &fresh)?;
                    set_column(conn, &record.transfer_id, "verified_bytes", &0)
                })?;
            }
        }
        self.remove_orphans(&partial_directory)
    }

    fn remove_orphans(&mut self, partial_directory: &Path) -> Result<()> {
        self.conn.execute(
            "DELETE FROM transfers WHERE outgoing = 1 AND state = 0 AND transfer_id NOT IN \
             (SELECT transfer_id FROM messages WHERE transfer_id IS NOT NULL) AND transfer_id NOT IN \
             (SELECT item_id FROM outbox WHERE item_id IS NOT NULL)",
            [],
        )?;
        let mut referenced = HashSet::new();
        let mut statement = self.conn.prepare("SELECT staged_path, partial_path FROM transfers")?;
        let paths =
            statement.query_map([], |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<String>>(1)?)))?;
        for (staged, partial) in paths.flatten() {
            referenced.extend(staged.into_iter().chain(partial).map(PathBuf::from));
        }
        for directory in [partial_directory.to_path_buf(), self.state_dir().join("outgoing")] {
            for entry in fs::read_dir(&directory).into_iter().flatten().flatten() {
                if !referenced.contains(&entry.path()) {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
        Ok(())
    }
}

fn mark_received(conn: &Connection, record: &TransferRecord, destination: &str) -> Result<()> {
    set_column(conn, &record.transfer_id, "received_path", &destination)?;
    set_column(conn, &record.transfer_id, "publishing", &0)?;
    set_column(conn, &record.transfer_id, "final_path", &rusqlite::types::Null)?;
    set_column(conn, &record.transfer_id, "partial_path", &rusqlite::types::Null)?;
    set_column(conn, &record.transfer_id, "verified_bytes", &(record.size as i64))?;
    apply_event(conn, &record.transfer_id, TransferEvent::Verified, None).map(|_| ())
}

/// A mismatch deletes the file and fails the transfer; Try again starts over from zero.
fn fail_mismatched(conn: &Connection, transfer_id: &str) -> Result<()> {
    set_column(conn, transfer_id, "verified_bytes", &0)?;
    set_column(conn, transfer_id, "partial_path", &rusqlite::types::Null)?;
    set_column(conn, transfer_id, "publishing", &0)?;
    set_column(conn, transfer_id, "final_path", &rusqlite::types::Null)?;
    apply_event(conn, transfer_id, TransferEvent::Failed, Some(transfers::FAILURE_DIGEST_MISMATCH)).map(|_| ())
}

fn sync_directory(directory: &Path) {
    #[cfg(unix)]
    if let Ok(handle) = File::open(directory) {
        let _ = handle.sync_all();
    }
    #[cfg(not(unix))]
    let _ = directory;
}
