//! Getting a file again from the friend who sent it (ADR 0016, `service/sync/SZFriendsAgain.m`): the AGAIN frame's
//! messages, the per-file state a Get again leaves, the files asked of one friend, and what a finished copy becomes.
//! The requester is `again_request.rs`, the sender's side `again_serve.rs`. Integers are big-endian; `id` is the 16
//! bytes whose lowercase hex is the transfer id.
//!
//! ```text
//! 1 WANT   id (16) | offset u64 | parts u16       send these parts of the file offered under id
//! 2 PART   id (16) | offset u64 | last u8 | bytes at most 48 KiB, in order from offset
//! 3 NONE   id (16) | reason u8                    0: this computer does not have it; 1: not now
//! ```

use std::path::Path;

use rusqlite::types::Value;

use super::engine::SyncEngine;
use super::SyncError;
use crate::presentation::AgainState;
use crate::store::destination::{mark_published, ReceivedSource};
use crate::store::sync_files::{self, SyncFile};
use crate::store::sync_log;
use crate::store::{sanitized_file_name, Store};

/// The bytes one PART carries at most.
pub const AGAIN_PART_MAX: usize = 48 * 1024;
/// NONE's reasons.
pub const NONE_GONE: u8 = 0;
pub const NONE_NOT_NOW: u8 = 1;

const WANT: u8 = 1;
const PART: u8 = 2;
const NONE: u8 = 3;

/// One message of the AGAIN exchange.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgainMessage {
    Want { id: String, offset: u64, parts: u16 },
    Part { id: String, offset: u64, last: bool, bytes: Vec<u8> },
    None { id: String, reason: u8 },
}

fn id_bytes(id: &str) -> Option<[u8; 16]> {
    if id.len() != 32 || id.bytes().any(|b| b.is_ascii_uppercase()) {
        return None;
    }
    hex::decode(id).ok()?.try_into().ok()
}

impl AgainMessage {
    pub fn id(&self) -> &str {
        match self {
            Self::Want { id, .. } | Self::Part { id, .. } | Self::None { id, .. } => id,
        }
    }

    /// The AGAIN field's bytes; `None` for an id that is not 16 bytes of lowercase hex, which nothing sends.
    pub fn encode(&self) -> Option<Vec<u8>> {
        let id = id_bytes(self.id())?;
        let mut out = Vec::new();
        match self {
            Self::Want { offset, parts, .. } => {
                out.push(WANT);
                out.extend_from_slice(&id);
                out.extend_from_slice(&offset.to_be_bytes());
                out.extend_from_slice(&parts.to_be_bytes());
            }
            Self::Part { offset, last, bytes, .. } => {
                if bytes.len() > AGAIN_PART_MAX {
                    return None;
                }
                out.push(PART);
                out.extend_from_slice(&id);
                out.extend_from_slice(&offset.to_be_bytes());
                out.push(u8::from(*last));
                out.extend_from_slice(bytes);
            }
            Self::None { reason, .. } => {
                out.push(NONE);
                out.extend_from_slice(&id);
                out.push(*reason);
            }
        }
        Some(out)
    }

    /// `None` for anything else: an unknown kind, a wrong length, a PART longer than 48 KiB.
    pub fn decode(data: &[u8]) -> Option<Self> {
        let (&kind, rest) = data.split_first()?;
        let id = hex::encode(rest.get(..16)?);
        let rest = &rest[16..];
        let u64_at = |at: usize| rest.get(at..at + 8).map(|b| u64::from_be_bytes(b.try_into().expect("8")));
        match kind {
            WANT if rest.len() == 10 => {
                Some(Self::Want { id, offset: u64_at(0)?, parts: u16::from_be_bytes([rest[8], rest[9]]) })
            }
            PART if rest.len() >= 9 && rest.len() - 9 <= AGAIN_PART_MAX && rest[8] <= 1 => {
                Some(Self::Part { id, offset: u64_at(0)?, last: rest[8] == 1, bytes: rest[9..].to_vec() })
            }
            NONE if rest.len() == 1 => Some(Self::None { id, reason: rest[0] }),
            _ => None,
        }
    }
}

fn again_key(transfer_id: &str) -> String {
    format!("again/{transfer_id}")
}

/// Where Get again stands for a file (sync state `again/<id>`: 1 asked, 2 gone).
pub fn again_state(store: &Store, transfer_id: &str) -> AgainState {
    match sync_log::state(&store.conn, &again_key(transfer_id)) {
        Ok(Value::Integer(1)) => AgainState::Asked,
        Ok(Value::Integer(2)) => AgainState::Gone,
        _ => AgainState::None,
    }
}

pub fn set_again_state(store: &Store, transfer_id: &str, state: AgainState) -> crate::store::Result<()> {
    let value = match state {
        AgainState::None => Value::Null,
        AgainState::Asked => Value::Integer(1),
        AgainState::Gone => Value::Integer(2),
    };
    sync_log::set_state(&store.conn, &again_key(transfer_id), value)
}

/// A file a friend sent, as Get again copies it: from its row here, or from the record of another computer's.
#[derive(Clone, Debug, PartialEq)]
pub struct AgainFile {
    pub transfer_id: String,
    pub conversation_id: String,
    pub file_name: String,
    pub uniform_type: Option<String>,
    pub size: u64,
    pub digest: Vec<u8>,
    pub created_at: f64,
}

impl AgainFile {
    /// An incoming file's row here, else its sync record.
    pub fn of(store: &Store, transfer_id: &str) -> Option<Self> {
        if let Some(row) = sync_files::transfer(&store.conn, transfer_id).ok().flatten() {
            let file = Self {
                transfer_id: row.transfer_id,
                conversation_id: row.conversation_id,
                file_name: row.file_name,
                uniform_type: row.uniform_type,
                size: row.size,
                digest: row.digest,
                created_at: row.created_at,
            };
            return (!row.outgoing).then_some(file);
        }
        let record = sync_files::sync_file(&store.conn, transfer_id).ok().flatten().filter(|r| !r.outgoing)?;
        Some(Self {
            transfer_id: record.transfer_id,
            conversation_id: record.conversation_id,
            file_name: record.file_name,
            uniform_type: record.uniform_type,
            size: record.size,
            digest: record.digest,
            created_at: record.created_at,
        })
    }

    /// The files asked again of this conversation's friend, oldest first.
    pub fn asked(store: &Store, conversation_id: &str) -> Vec<Self> {
        let states = sync_log::states_with_prefix(&store.conn, "again/").unwrap_or_default();
        let mut files: Vec<Self> = states
            .into_iter()
            .filter(|(_, value)| *value == Value::Integer(1))
            .filter_map(|(key, _)| Self::of(store, key.strip_prefix("again/")?))
            .filter(|file| file.conversation_id == conversation_id)
            .collect();
        files.sort_by(|a, b| a.created_at.total_cmp(&b.created_at).then(a.transfer_id.cmp(&b.transfer_id)));
        files
    }
}

impl SyncEngine {
    /// A file copied again from its friend arrived whole at `path`, its digest checked by the caller: published where
    /// received files go, its row (made from the record when there was none) pointing there, and held here again.
    pub fn adopt_again_file(&mut self, store: &Store, file: &AgainFile, path: &Path) -> Result<(), SyncError> {
        let name = sanitized_file_name(&file.file_name);
        let (stored, _) = store.places().publish(path, &name, &mut |_| Ok(()))?;
        let record = SyncFile {
            transfer_id: file.transfer_id.clone(),
            conversation_id: file.conversation_id.clone(),
            item_id: None,
            outgoing: false,
            state: 6,
            file_name: file.file_name.clone(),
            uniform_type: file.uniform_type.clone(),
            size: file.size,
            digest: file.digest.clone(),
            created_at: file.created_at,
            holders: Vec::new(),
        };
        let recorded = sync_files::insert_copied_transfer(&store.conn, &record, &stored)
            .and_then(|()| mark_published(&store.conn, &file.transfer_id, Some(ReceivedSource::Friend)));
        if let Err(error) = recorded {
            if Path::new(&stored).is_absolute() {
                let _ = std::fs::remove_file(&stored);
            }
            return Err(error.into());
        }
        let _ = set_again_state(store, &file.transfer_id, AgainState::None);
        self.note_changed(Some(&file.conversation_id));
        self.flush_changes();
        // Held here again: the next capture says so to the person's other computers.
        self.capture_local_changes(store);
        Ok(())
    }

    /// Where a copy from the friend waits until it is whole; a later session resumes it.
    pub fn again_partial_path(&self, transfer_id: &str) -> std::path::PathBuf {
        self.received_dir.join(".partial").join(format!("again-{transfer_id}"))
    }
}
