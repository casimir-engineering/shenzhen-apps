//! Get again, the asking side (ADR 0016): on one session with a friend, one file at a time, the oldest asked of that
//! friend; its bytes go to `received/.partial/again-<id>` (a later session resumes from its length), at most 16 parts
//! requested and not yet arrived, 8 per WANT. Whole, its digest must be the one it was offered with: then it is
//! published, else it is gone. NONE 0 ends the request; NONE 1 tries another file and leaves this one for the next
//! session. Sans-IO: what to send collects in [`AgainRequester::take_messages`].

use std::collections::BTreeSet;
use std::io::{Seek, SeekFrom, Write};
use std::path::PathBuf;

use super::again::{set_again_state, AgainFile, AgainMessage, AGAIN_PART_MAX, NONE_NOT_NOW};
use super::engine::SyncEngine;
use super::exchange::matches_digest;
use crate::presentation::AgainState;
use crate::store::Store;

const PARTS_PER_WANT: u16 = 8;
const PARTS_AHEAD: u64 = 16;

#[derive(Debug)]
struct Copy {
    file: AgainFile,
    path: PathBuf,
    handle: std::fs::File,
    received: u64,
    requested: u64,
}

/// What one session with a friend copies again from them.
#[derive(Debug)]
pub struct AgainRequester {
    conversation_id: String,
    copy: Option<Copy>,
    /// Answered "not now" on this session: tried again on the next one.
    not_now: BTreeSet<String>,
    outgoing: Vec<AgainMessage>,
}

impl AgainRequester {
    pub fn new(conversation_id: &str) -> Self {
        Self { conversation_id: conversation_id.to_owned(), copy: None, not_now: BTreeSet::new(), outgoing: Vec::new() }
    }

    /// The file copying now and how much of it is here.
    pub fn copying(&self) -> Option<(&str, f64)> {
        self.copy.as_ref().map(|c| {
            let fraction = if c.file.size > 0 { c.received as f64 / c.file.size as f64 } else { 0.0 };
            (c.file.transfer_id.as_str(), fraction)
        })
    }

    /// The AGAIN fields to send, in order.
    pub fn take_messages(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.outgoing).iter().filter_map(AgainMessage::encode).collect()
    }

    /// Cancel: the copy stops; what arrived waits for another Get again.
    pub fn stop_copy(&mut self, transfer_id: &str) {
        if self.copy.as_ref().is_some_and(|c| c.file.transfer_id == transfer_id) {
            self.copy = None;
        }
    }

    /// Starts the oldest asked file this session has not been told "not now" about, unless one is copying.
    pub fn start_next(&mut self, engine: &SyncEngine, store: &Store) {
        if self.copy.is_some() {
            return;
        }
        for file in AgainFile::asked(store, &self.conversation_id) {
            if self.not_now.contains(&file.transfer_id) {
                continue;
            }
            let path = engine.again_partial_path(&file.transfer_id);
            if path.parent().is_none_or(|p| std::fs::create_dir_all(p).is_err()) {
                continue;
            }
            let options = std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(&path);
            let Ok(mut handle) = options else { continue };
            let mut held = handle.seek(SeekFrom::End(0)).unwrap_or(0);
            if held > file.size {
                let _ = handle.set_len(0);
                let _ = handle.seek(SeekFrom::Start(0));
                held = 0;
            }
            self.copy = Some(Copy { file, path, handle, received: held, requested: held });
            self.request_more();
            return;
        }
    }

    fn request_more(&mut self) {
        let Some(copy) = self.copy.as_mut() else { return };
        let size = copy.file.size;
        let mut first = copy.requested == copy.received;
        while (copy.requested < size || (copy.requested == size && first))
            && copy.requested - copy.received < PARTS_AHEAD * AGAIN_PART_MAX as u64
        {
            let id = copy.file.transfer_id.clone();
            self.outgoing.push(AgainMessage::Want { id, offset: copy.requested, parts: PARTS_PER_WANT });
            copy.requested = size.min(copy.requested + u64::from(PARTS_PER_WANT) * AGAIN_PART_MAX as u64);
            if copy.requested == size {
                break;
            }
            first = false;
        }
    }

    /// A PART or NONE from the friend (a WANT is the sender's business). `true` when what the views show changed.
    pub fn receive(&mut self, engine: &mut SyncEngine, store: &Store, message: &AgainMessage) -> bool {
        match message {
            AgainMessage::Part { id, offset, last, bytes } => {
                self.receive_part(engine, store, id, *offset, *last, bytes)
            }
            AgainMessage::None { id, reason } => {
                let Some(copy) = self.copy.take_if(|c| c.file.transfer_id == *id) else { return false };
                if *reason == NONE_NOT_NOW {
                    self.not_now.insert(copy.file.transfer_id);
                } else {
                    drop(copy.handle);
                    let _ = std::fs::remove_file(&copy.path);
                    let _ = set_again_state(store, id, AgainState::Gone);
                }
                self.start_next(engine, store);
                true
            }
            AgainMessage::Want { .. } => false,
        }
    }

    fn receive_part(
        &mut self,
        engine: &mut SyncEngine,
        store: &Store,
        id: &str,
        offset: u64,
        last: bool,
        bytes: &[u8],
    ) -> bool {
        let Some(copy) = self.copy.as_mut() else { return false };
        if copy.file.transfer_id != id || offset != copy.received {
            return false;
        }
        let end = copy.received + bytes.len() as u64;
        if end > copy.file.size || (last && end != copy.file.size) || copy.handle.write_all(bytes).is_err() {
            // Not the file it was offered as: start over on the next session.
            let copy = self.copy.take().expect("present");
            drop(copy.handle);
            let _ = std::fs::remove_file(&copy.path);
            self.not_now.insert(copy.file.transfer_id);
            self.start_next(engine, store);
            return true;
        }
        copy.received = end;
        if copy.received < copy.file.size {
            self.request_more();
            return true;
        }
        let copy = self.copy.take().expect("present");
        let _ = copy.handle.sync_all();
        drop(copy.handle);
        if matches_digest(&copy.path, copy.file.size, &copy.file.digest) {
            if engine.adopt_again_file(store, &copy.file, &copy.path).is_err() {
                self.not_now.insert(copy.file.transfer_id.clone());
            }
        } else {
            let _ = std::fs::remove_file(&copy.path);
            let _ = set_again_state(store, id, AgainState::Gone);
        }
        self.start_next(engine, store);
        true
    }
}
