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
use crate::store::{sanitized_file_name, Store};

fn want_key(transfer_id: &str) -> String {
    format!("want/{transfer_id}")
}

impl SyncEngine {
    /// Where this device keeps a file's bytes, or `None`.
    pub fn local_path_of_file(&self, store: &Store, transfer_id: &str) -> Option<PathBuf> {
        let transfer = sync_files::transfer(&store.conn, transfer_id).ok().flatten()?;
        let path = if transfer.outgoing && transfer.staged_path.is_some() {
            transfer.staged_path.clone()
        } else {
            transfer.received_path.clone()
        };
        let usable = if transfer.outgoing { path.is_some() } else { transfer.state == 6 && path.is_some() };
        let path = PathBuf::from(path.filter(|_| usable)?);
        let path = if path.is_absolute() { path } else { store.state_dir().join(path) };
        let metadata = std::fs::metadata(&path).ok()?;
        (metadata.is_file() && metadata.len() == transfer.size).then_some(path)
    }

    /// Records whose bytes are on another device and not here: asked for first, then the ones that copy by
    /// themselves, oldest first.
    pub fn files_wanted(&self, store: &Store) -> Vec<SyncFile> {
        let conn = &store.conn;
        let me = self.device_key();
        let (mut asked, mut automatic) = (Vec::new(), Vec::new());
        for file in sync_files::sync_files(conn).unwrap_or_default() {
            if sync_files::transfer(conn, &file.transfer_id).ok().flatten().is_some() {
                continue;
            }
            if !file.holders.iter().any(|h| *h != me) {
                continue;
            }
            if sync_log::state(conn, &want_key(&file.transfer_id)).is_ok_and(|v| v != Value::Null) {
                asked.push(file);
            } else if copies_automatically(file.size, &file.conversation_id) {
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
