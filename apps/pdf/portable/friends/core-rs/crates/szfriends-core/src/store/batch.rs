//! Store batches (ADR 0018 § 9.3): what one burst of work writes — files staged together, offers recorded and
//! answered back to back, small files received and published — shares one transaction and one full flush, instead of
//! one of each per write. The helper opens a batch before it handles what arrived and closes it before it sends
//! anything, so nothing it acknowledges is less durable than before.
//!
//! Inside a batch every [`Store::write`] is a savepoint; files are ordered on disk (`order_writes`) and the batch's
//! commit flushes the drive once for all of them. Publishing keeps ADR 0003's rule that the name a file takes is
//! durable before the file takes it: publishes wait for the batch's end, where every file's name is claimed in the
//! batch's commit, the files are moved, and one more commit records them received.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use super::destination::{rename_no_replace, sync_directory};
use super::transfers::{set_column, TransferRecord};
use super::{unique_destination, Result, Store};

/// A batch's state.
#[derive(Debug, Default)]
pub(crate) struct Batch {
    /// Batches opened inside this one: only the outermost end commits.
    depth: usize,
    /// Verified files waiting to be published at the batch's end.
    pending: Vec<(TransferRecord, PathBuf)>,
}

/// A file published at a batch's end: its transfer and where it went, or why it could not.
#[derive(Debug)]
pub struct Published {
    pub transfer_id: String,
    pub conversation_id: String,
    pub result: Result<PathBuf>,
}

impl Store {
    /// Opens a batch; inside one already open, the same batch, which then ends with the outermost end.
    pub fn begin_batch(&mut self) -> Result<()> {
        match self.batch.as_mut() {
            Some(batch) => batch.depth += 1,
            None => {
                self.conn.execute_batch("BEGIN IMMEDIATE")?;
                self.batch = Some(Batch::default());
            }
        }
        Ok(())
    }

    /// Whether writes now join a batch (files are then made durable by its commit).
    pub fn in_batch(&self) -> bool {
        self.batch.is_some()
    }

    /// Commits the batch, then publishes what it verified (names claimed durably first) and returns those files, so
    /// the caller acknowledges each only now.
    pub fn end_batch(&mut self) -> Result<Vec<Published>> {
        if let Some(batch) = self.batch.as_mut().filter(|b| b.depth > 0) {
            batch.depth -= 1;
            return Ok(Vec::new());
        }
        let Some(batch) = self.batch.take() else { return Ok(Vec::new()) };
        if batch.pending.is_empty() {
            self.conn.execute_batch("COMMIT")?;
            self.vacuum_if_pending();
            return Ok(Vec::new());
        }
        // Each file's name, claimed in the same commit as everything else, in the one folder they all go to.
        let folder = self.places().batch_folder();
        let mut claimed: Vec<(TransferRecord, PathBuf, Option<PathBuf>)> = Vec::new();
        let mut taken: HashSet<PathBuf> = HashSet::new();
        for (record, partial) in batch.pending {
            // Two files of one name in one batch: the second publishes alone, after the first took the name.
            let destination = folder
                .as_ref()
                .map(|folder| unique_destination(folder, &record.file_name))
                .filter(|candidate| taken.insert(candidate.clone()));
            if let Some(destination) = &destination {
                let text = destination.to_string_lossy().into_owned();
                set_column(&self.conn, &record.transfer_id, "final_path", &text)?;
                set_column(&self.conn, &record.transfer_id, "publishing", &1)?;
            }
            claimed.push((record, partial, destination));
        }
        self.conn.execute_batch("COMMIT")?;
        self.vacuum_if_pending();
        // The moves, then one commit that records them received. A name taken meanwhile, or a folder that refuses,
        // publishes that file alone, as outside a batch.
        let mut moved = Vec::new();
        let mut alone = Vec::new();
        for (record, partial, destination) in claimed {
            match destination {
                Some(destination) if rename_no_replace(&partial, &destination).is_ok() => {
                    moved.push((record, destination))
                }
                _ => alone.push((record, partial)),
            }
        }
        if let Some(folder) = &folder {
            if !moved.is_empty() {
                sync_directory(folder);
                super::saved::record_fallback(self.state_dir(), None);
            }
        }
        let mut published = Vec::new();
        if !moved.is_empty() {
            let recorded = self.write(|conn| {
                for (record, destination) in &moved {
                    super::receive::mark_received(conn, record, &destination.to_string_lossy())?;
                }
                Ok(())
            });
            for (record, destination) in moved {
                let result = match &recorded {
                    Ok(()) => Ok(destination),
                    Err(error) => Err(error.clone()),
                };
                published.push(Published {
                    transfer_id: record.transfer_id,
                    conversation_id: record.conversation_id,
                    result,
                });
            }
        }
        for (record, partial) in alone {
            let result = self.publish_now(&record, &partial);
            published.push(Published {
                transfer_id: record.transfer_id,
                conversation_id: record.conversation_id,
                result,
            });
        }
        Ok(published)
    }

    /// A history deletion made inside the batch scrubs the file now that it committed (`sync_history::vacuum`).
    fn vacuum_if_pending(&mut self) {
        let pending: Option<String> = rusqlite::OptionalExtension::optional(self.conn.query_row(
            "SELECT value FROM meta WHERE key = 'vacuum_pending'",
            [],
            |r| r.get(0),
        ))
        .ok()
        .flatten();
        if pending.is_some() {
            let _ = super::sync_history::vacuum(&self.conn);
        }
    }

    /// Publishes now, or at the batch's end when one is open (then `Ok` of an empty path: the caller waits for
    /// [`Store::end_batch`] to acknowledge it).
    pub(super) fn publish_or_defer(&mut self, record: &TransferRecord, partial: &Path) -> Result<PathBuf> {
        match self.batch.as_mut() {
            Some(batch) => {
                batch.pending.push((record.clone(), partial.to_path_buf()));
                Ok(PathBuf::new())
            }
            None => self.publish_now(record, partial),
        }
    }
}
