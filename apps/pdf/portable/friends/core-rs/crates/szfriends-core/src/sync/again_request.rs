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
use crate::transfer::block_copy::{BlockCopy, CopyPart};

const PARTS_PER_WANT: u16 = 8;
/// HAVE after this many bytes of blocks at most, so the serving side's window keeps moving.
const HAVE_EVERY_BLOCKS: usize = 1;
const PARTS_AHEAD: u64 = 16;

#[derive(Debug)]
struct Copy {
    file: AgainFile,
    path: PathBuf,
    handle: std::fs::File,
    received: u64,
    requested: u64,
    /// On a session with fast transfers (ADR 0018 § 4): by blocks, resumed from its map; `handle` is then unused.
    blocks: Option<crate::transfer::block_copy::BlockCopy>,
}

/// What one session with a friend copies again from them.
#[derive(Debug)]
pub struct AgainRequester {
    conversation_id: String,
    copy: Option<Copy>,
    /// Answered "not now" on this session: tried again on the next one.
    not_now: BTreeSet<String>,
    outgoing: Vec<AgainMessage>,
    /// Copies by blocks: on a session that negotiated fast transfers.
    fast: bool,
    /// HAVE frames for a copy by blocks, to send in order after the AGAIN messages.
    frames: Vec<szfriends_wire::Frame>,
}

impl AgainRequester {
    pub fn new(conversation_id: &str) -> Self {
        Self::with_blocks(conversation_id, false)
    }

    /// `fast`: the session negotiated fast transfers, so copies go by blocks (ADR 0018 § 4).
    pub fn with_blocks(conversation_id: &str, fast: bool) -> Self {
        Self {
            conversation_id: conversation_id.to_owned(),
            copy: None,
            not_now: BTreeSet::new(),
            outgoing: Vec::new(),
            fast,
            frames: Vec::new(),
        }
    }

    /// Session frames (HAVE) for copies by blocks, to send after [`AgainRequester::take_messages`].
    pub fn take_frames(&mut self) -> Vec<szfriends_wire::Frame> {
        std::mem::take(&mut self.frames)
    }

    /// The transfer copying by blocks now, whose HASHES and PARTs this requester takes.
    pub fn copying_by_blocks(&self) -> Option<&str> {
        self.copy.as_ref().filter(|c| c.blocks.is_some()).map(|c| c.file.transfer_id.as_str())
    }

    /// The file copying now and how much of it is here.
    pub fn copying(&self) -> Option<(&str, f64)> {
        self.copy.as_ref().map(|c| {
            let received = c.blocks.as_ref().map_or(c.received, |b| b.received_bytes());
            let fraction = if c.file.size > 0 { received as f64 / c.file.size as f64 } else { 0.0 };
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
            if let Some(blocks) = self.copy.take().and_then(|c| c.blocks) {
                blocks.pause();
            }
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
            if self.fast {
                let digest: Option<[u8; 32]> = file.digest.clone().try_into().ok();
                let map = path.with_file_name(format!("again-{}.map", file.transfer_id));
                let opened = digest.and_then(|d| BlockCopy::open(file.size, d, path.clone(), map).ok());
                let Some(blocks) = opened else { continue };
                let Ok(handle) = std::fs::File::open(&path) else { continue };
                let (id, shift, ranges) = (file.transfer_id.clone(), blocks.shift(), blocks.missing());
                self.outgoing.push(AgainMessage::WantBlocks { id, shift, ranges });
                self.copy = Some(Copy { file, path, handle, received: 0, requested: 0, blocks: Some(blocks) });
                return;
            }
            let options = std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(&path);
            let Ok(mut handle) = options else { continue };
            let mut held = handle.seek(SeekFrom::End(0)).unwrap_or(0);
            if held > file.size {
                let _ = handle.set_len(0);
                let _ = handle.seek(SeekFrom::Start(0));
                held = 0;
            }
            self.copy = Some(Copy { file, path, handle, received: held, requested: held, blocks: None });
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
            AgainMessage::BlocksFollow { id, root, shift } => {
                let Some(copy) = self.copy.as_mut().filter(|c| c.file.transfer_id == *id) else { return false };
                if copy.blocks.as_mut().is_some_and(|b| b.follow(*root, *shift)) {
                    return false;
                }
                // A tree that cannot be this file's: tried again on the next session.
                self.stop_copy(id);
                self.not_now.insert(id.clone());
                self.start_next(engine, store);
                true
            }
            AgainMessage::Want { .. } | AgainMessage::WantBlocks { .. } => false,
        }
    }

    /// HASHES for the copy by blocks; `false` when this requester is not copying `id` by blocks.
    pub fn hashes(&mut self, id: &str, index: u32, hashes: &[u8]) -> bool {
        let Some(copy) = self.copy.as_mut().filter(|c| c.file.transfer_id == id) else { return false };
        let Some(blocks) = copy.blocks.as_mut() else { return false };
        if blocks.hashes(index, hashes).is_none() {
            self.stop_copy(id);
            self.not_now.insert(id.to_owned());
            return true;
        }
        self.queue_have(id);
        true
    }

    fn queue_have(&mut self, id: &str) {
        let Some(blocks) = self.copy.as_mut().and_then(|c| c.blocks.as_mut()) else { return };
        let have = blocks.take_have();
        if let Ok(wire) = hex::decode(id) {
            self.frames.extend(crate::transfer::frames::have(&wire, &have, &[]));
        }
    }

    /// A PART for the copy by blocks; `false` when this requester is not copying `id` by blocks. `true` in the
    /// second value when what the views show changed (a copy finished or stopped).
    pub fn part(&mut self, engine: &mut SyncEngine, store: &Store, id: &str, offset: u64, data: &[u8]) -> (bool, bool) {
        let Some(copy) = self.copy.as_mut().filter(|c| c.file.transfer_id == id) else { return (false, false) };
        let Some(blocks) = copy.blocks.as_mut() else { return (false, false) };
        match blocks.part(offset, data) {
            CopyPart::Pending | CopyPart::Late => (true, false),
            CopyPart::Written(_) => {
                if blocks.unreported_count() >= HAVE_EVERY_BLOCKS {
                    self.queue_have(id);
                }
                (true, false)
            }
            CopyPart::Corrupt(block) => {
                let shift = blocks.shift();
                self.outgoing.push(AgainMessage::WantBlocks { id: id.to_owned(), shift, ranges: vec![(block, 1)] });
                (true, false)
            }
            CopyPart::Refused => {
                self.stop_copy(id);
                self.not_now.insert(id.to_owned());
                self.start_next(engine, store);
                (true, true)
            }
            CopyPart::Complete => {
                self.queue_have(id);
                let copy = self.copy.take().expect("present");
                let blocks = copy.blocks.expect("by blocks");
                drop(copy.handle);
                match blocks.finish() {
                    Some(path) => {
                        if engine.adopt_again_file(store, &copy.file, &path).is_err() {
                            self.not_now.insert(copy.file.transfer_id.clone());
                        }
                    }
                    // Not the file it was offered as: gone, as a copy by offset that did not match.
                    None => {
                        let _ = set_again_state(store, id, AgainState::Gone);
                    }
                }
                self.start_next(engine, store);
                (true, true)
            }
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
        let bad = end > copy.file.size || (last && end != copy.file.size);
        if bad || copy.handle.write_all(bytes).is_err() {
            let copy = self.copy.take().expect("present");
            drop(copy.handle);
            let _ = std::fs::remove_file(&copy.path);
            if bad {
                // Not the file it was offered as: start over on the next session.
                self.not_now.insert(copy.file.transfer_id);
            } else {
                // No room left here: Get again ends; the item offers it, which then says so.
                let _ = set_again_state(store, id, AgainState::None);
            }
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
