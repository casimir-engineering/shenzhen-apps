//! Files between own devices (`SZFriendsSyncFiles.m`): every device knows every transfer record at once; the bytes
//! copy by themselves up to 25 MB, always in You, and otherwise when the person asks ("On <device> · Get"). The copy
//! runs on a session (`exchange.rs`); here is which files to copy, where their bytes are, and what a finished copy
//! becomes.

use std::path::{Path, PathBuf};

use rusqlite::types::Value;

use super::engine::SyncEngine;
use super::{copies_automatically, SyncError};
use crate::store::destination::{mark_published, ReceivedSource};
use crate::store::sync_files::{self, SyncFile};
use crate::store::sync_log;
use crate::store::sync_records::SyncTransfer;
use crate::store::{modified_ns, sanitized_file_name, Store};

fn want_key(transfer_id: &str) -> String {
    format!("want/{transfer_id}")
}

/// `path` (relative to the state directory, or absolute) when it is a regular file of `size` bytes.
fn whole_file(state_dir: &Path, path: Option<&str>, size: u64) -> Option<PathBuf> {
    let path = PathBuf::from(path.filter(|p| !p.is_empty())?);
    let path = if path.is_absolute() { path } else { state_dir.join(path) };
    let metadata = std::fs::symlink_metadata(&path).ok()?;
    (metadata.is_file() && metadata.len() == size).then_some(path)
}

/// Where this device has a transfer's bytes (ADR 0016): a received file where it was saved, at its size; for one of
/// ours, the snapshot, a copy, or the file it was sent from while unchanged (size and modification time). `None`: none.
pub fn local_path_of_transfer(state_dir: &Path, transfer: &SyncTransfer) -> Option<PathBuf> {
    let size = transfer.size;
    if !transfer.outgoing {
        // Received here (or copied from another of our devices): the published file, where it was saved.
        return whole_file(state_dir, transfer.received_path.as_deref(), size).filter(|_| transfer.state == 6);
    }
    whole_file(state_dir, transfer.staged_path.as_deref(), size)
        .or_else(|| whole_file(state_dir, transfer.received_path.as_deref(), size))
        .or_else(|| {
            let path = whole_file(state_dir, transfer.source_path.as_deref(), size)?;
            let unchanged = transfer.source_mtime_ns != 0 && modified_ns(&path) == transfer.source_mtime_ns;
            unchanged.then_some(path)
        })
}

impl SyncEngine {
    /// Where this device keeps a file's bytes, or `None` ([`local_path_of_transfer`]).
    pub fn local_path_of_file(&self, store: &Store, transfer_id: &str) -> Option<PathBuf> {
        let transfer = sync_files::transfer(&store.conn, transfer_id).ok().flatten()?;
        local_path_of_transfer(store.state_dir(), &transfer)
    }

    /// Records whose bytes are on another device and not here: asked for first, then the ones that copy by
    /// themselves, oldest first.
    pub fn files_wanted(&self, store: &Store) -> Vec<SyncFile> {
        let conn = &store.conn;
        let me = self.device_key();
        let (mut asked, mut automatic) = (Vec::new(), Vec::new());
        for file in sync_files::sync_files(conn).unwrap_or_default() {
            let here = sync_files::transfer(conn, &file.transfer_id).ok().flatten();
            if here.as_ref().is_some_and(|t| local_path_of_transfer(store.state_dir(), t).is_some()) {
                continue; // its bytes are here
            }
            if !file.holders.iter().any(|h| *h != me) {
                continue;
            }
            if sync_log::state(conn, &want_key(&file.transfer_id)).is_ok_and(|v| v != Value::Null) {
                asked.push(file);
            } else if here.is_none() && copies_automatically(file.size, &file.conversation_id) {
                // What the person moved or deleted here comes back only when they ask (Get).
                automatic.push(file);
            }
        }
        let older =
            |a: &SyncFile, b: &SyncFile| a.created_at.total_cmp(&b.created_at).then(a.transfer_id.cmp(&b.transfer_id));
        asked.sort_by(older);
        automatic.sort_by(older);
        asked.extend(automatic);
        asked
    }

    /// "Get": copy this file's bytes here at the next chance, whatever its size.
    pub fn request_file(&mut self, store: &Store, transfer_id: &str) -> Result<(), SyncError> {
        if sync_files::sync_file(&store.conn, transfer_id)?.is_none() {
            return Err(SyncError::Malformed("no such file record"));
        }
        sync_log::set_state(&store.conn, &want_key(transfer_id), Value::Integer(1))?;
        self.note_new_events();
        Ok(())
    }

    pub fn is_file_requested(&self, store: &Store, transfer_id: &str) -> bool {
        sync_log::state(&store.conn, &want_key(transfer_id)).is_ok_and(|v| v != Value::Null)
    }

    /// Cancel after Get: what arrived so far waits in received/.partial/ for another Get.
    pub fn cancel_file_request(&mut self, store: &Store, transfer_id: &str) -> Result<(), SyncError> {
        sync_log::set_state(&store.conn, &want_key(transfer_id), Value::Null)?;
        self.note_new_events();
        Ok(())
    }

    /// A copy arrived whole at `path` (its digest checked by the caller): published where received files go,
    /// recorded, announced.
    pub fn adopt_copied_file(&mut self, store: &Store, transfer_id: &str, path: &Path) -> Result<(), SyncError> {
        let file =
            sync_files::sync_file(&store.conn, transfer_id)?.ok_or(SyncError::Malformed("no such file record"))?;
        let name = sanitized_file_name(&file.file_name);
        let (stored, _) = store.places().publish(path, &name, &mut |_| Ok(()))?;
        let recorded = sync_files::insert_copied_transfer(&store.conn, &file, &stored)
            .and_then(|()| mark_published(&store.conn, transfer_id, Some(ReceivedSource::Device)));
        if let Err(error) = recorded {
            if Path::new(&stored).is_absolute() {
                let _ = std::fs::remove_file(&stored);
            }
            return Err(error.into());
        }
        let _ = sync_log::set_state(&store.conn, &want_key(transfer_id), Value::Null);
        self.note_changed(Some(&file.conversation_id));
        self.flush_changes();
        // Now held here too: the next capture says so, and other devices may copy it from this one.
        self.capture_local_changes(store);
        Ok(())
    }
}
