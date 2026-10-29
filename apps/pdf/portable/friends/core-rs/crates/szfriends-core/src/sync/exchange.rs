//! Anti-entropy on one session between two of our devices (`SZFriendsSyncExchange.m`). Each message is one SYNC
//! frame's payload:
//!
//! ```text
//! 1 HELLO   version u8 (1) | vector
//! 2 EVENTS  count u16 | (header length u16 | header | has body u8 | [body length u32 | body])*
//! 3 ACK     vector after applying an EVENTS
//! 4 WANT    id length u8 | id | offset u64 | parts u16
//! 5 PART    id length u8 | id | offset u64 | last u8 | bytes
//! 6 NONE    id length u8 | id
//! 7 WANT BLOCKS    id length u8 | id | shift u8 | ranges   (ADR 0018 § 4; fast-transfer sessions only)
//! 8 BLOCKS FOLLOW  id length u8 | id | root (32) | shift u8; HASHES and PARTs follow on the session
//! ```
//!
//! Sans-IO: what to send collects in [`SyncExchange::take_messages`].

use std::collections::BTreeSet;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;

use super::codec::{decode_vector, encode_vector, vector_covers, Event};
use super::engine::SyncEngine;
use super::{label_is_valid, SyncError, BODY_MAX, FILE_PART_MAX, MESSAGE_MAX, WINDOW};
use crate::store::sync_files::{self, SyncFile};
use crate::store::sync_log::Vector;
use crate::store::Store;
use crate::transfer::block_copy::{remove_copy, BlockCopy, CopyPart};
use crate::transfer::copies::{self, CopyMessage};

const COPY_PARTS: u16 = 8;
const COPY_AHEAD: u64 = 16;
const EVENTS_PER_MESSAGE: usize = 200;

const HELLO: u8 = 1;
const EVENTS: u8 = 2;
const ACK: u8 = 3;
const WANT: u8 = 4;
const PART: u8 = 5;
const NONE: u8 = 6;

struct Copy {
    file: SyncFile,
    path: PathBuf,
    handle: std::fs::File,
    received: u64,
    requested: u64,
    /// By blocks, on a session with fast transfers (ADR 0018 § 4), resumed from its map.
    blocks: Option<BlockCopy>,
}

/// A file this device serves by blocks to the other: the leaves and the blocks asked for, cut from `path`.
#[derive(Debug)]
pub struct ServeBlocks {
    pub transfer_id: String,
    pub serve: crate::transfer::BlockServe,
    pub path: PathBuf,
}

pub struct SyncExchange {
    peer_key: [u8; 32],
    sent: Vector,
    peer_vector: Option<Vector>,
    outstanding: usize,
    stopped: bool,
    copy: Option<Copy>,
    unavailable: BTreeSet<String>,
    hello_received: bool,
    outgoing: Vec<Vec<u8>>,
    serving: Option<(String, f64)>,
    /// The session negotiated fast transfers: the other device may ask for files by blocks.
    fast: bool,
    /// This device asks for its copies by blocks (and the other answers them).
    request_blocks: bool,
    /// HAVE frames of a copy by blocks, and files to serve by blocks, for the session to send.
    frames: Vec<szfriends_wire::Frame>,
    serve_blocks: Vec<ServeBlocks>,
}

impl std::fmt::Debug for SyncExchange {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SyncExchange").field("peer_key", &self.peer_key).finish_non_exhaustive()
    }
}

fn put_id(out: &mut Vec<u8>, transfer_id: &str) {
    out.push(transfer_id.len() as u8);
    out.extend_from_slice(transfer_id.as_bytes());
}

fn get_id(data: &[u8], offset: &mut usize) -> Option<String> {
    let length = *data.get(*offset)? as usize;
    if length == 0 || length > 64 || *offset + 1 + length > data.len() {
        return None;
    }
    let id = std::str::from_utf8(&data[*offset + 1..*offset + 1 + length]).ok()?.to_owned();
    *offset += 1 + length;
    (label_is_valid(&id) && !id.contains(':') && !id.contains('/')).then_some(id)
}

pub(super) fn matches_digest(path: &std::path::Path, size: u64, digest: &[u8]) -> bool {
    use blake2::digest::{Update, VariableOutput};
    let Ok(mut file) = std::fs::File::open(path) else { return false };
    let mut hasher = blake2::Blake2bVar::new(32).expect("32");
    let mut buffer = vec![0u8; 1 << 20];
    let mut total = 0u64;
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => {
                total += n as u64;
                hasher.update(&buffer[..n]);
            }
            Err(_) => return false,
        }
    }
    let mut out = [0u8; 32];
    hasher.finalize_variable(&mut out).expect("32");
    total == size && digest.len() == 32 && out.as_slice() == digest
}

impl SyncExchange {
    pub fn new(peer_key: [u8; 32]) -> Self {
        Self {
            peer_key,
            sent: Vector::new(),
            peer_vector: None,
            outstanding: 0,
            stopped: false,
            copy: None,
            unavailable: BTreeSet::new(),
            hello_received: false,
            outgoing: Vec::new(),
            serving: None,
            fast: false,
            request_blocks: false,
            frames: Vec::new(),
            serve_blocks: Vec::new(),
        }
    }

    /// The session negotiated fast transfers (ADR 0018 § 4): the other device may ask for files by blocks, and with
    /// `request_blocks` this one asks for its copies so.
    pub fn set_fast(&mut self, fast: bool, request_blocks: bool) {
        self.fast = fast;
        self.request_blocks = fast && request_blocks;
    }

    /// HAVE frames for the copy by blocks, to send after the messages.
    pub fn take_frames(&mut self) -> Vec<szfriends_wire::Frame> {
        std::mem::take(&mut self.frames)
    }

    /// Files to serve by blocks, which the session takes over (it sends their leaves, then the blocks).
    pub fn take_serve_blocks(&mut self) -> Vec<ServeBlocks> {
        std::mem::take(&mut self.serve_blocks)
    }

    /// The transfer copying by blocks now, whose HASHES and PARTs this exchange takes.
    pub fn copying_by_blocks(&self) -> Option<&str> {
        self.copy.as_ref().filter(|c| c.blocks.is_some()).map(|c| c.file.transfer_id.as_str())
    }

    pub fn peer_key(&self) -> &[u8; 32] {
        &self.peer_key
    }

    /// Messages to send, oldest first.
    pub fn take_messages(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.outgoing)
    }

    /// Sends HELLO.
    pub fn start(&mut self, engine: &SyncEngine, store: &Store) {
        let mut hello = vec![HELLO, 1];
        hello.extend_from_slice(&encode_vector(&engine.vector(store)));
        self.outgoing.push(hello);
    }

    /// The peer said HELLO and has acknowledged everything we offer.
    pub fn peer_caught_up(&self, engine: &SyncEngine, store: &Store) -> bool {
        let Some(peer) = &self.peer_vector else { return false };
        engine.offered_vector(store).iter().all(|(author, seq)| vector_covers(peer, author, *seq))
    }

    pub fn hello_received(&self) -> bool {
        self.hello_received
    }

    pub fn copying(&self) -> Option<(&str, f64)> {
        self.copy.as_ref().map(|c| {
            let received = c.blocks.as_ref().map_or(c.received, BlockCopy::received_bytes);
            let fraction = if c.file.size > 0 { received as f64 / c.file.size as f64 } else { 0.0 };
            (c.file.transfer_id.as_str(), fraction)
        })
    }

    pub fn serving(&self) -> Option<(&str, f64)> {
        self.serving.as_ref().map(|(id, fraction)| (id.as_str(), *fraction))
    }

    /// The session ended: partial copies stay for the next one.
    pub fn stop(&mut self) {
        self.stopped = true;
        if let Some(blocks) = self.copy.take().and_then(|c| c.blocks) {
            blocks.pause();
        }
    }

    /// A message from the peer; an error means it broke the protocol: end the session.
    pub fn receive(&mut self, engine: &mut SyncEngine, store: &Store, message: &[u8]) -> Result<(), SyncError> {
        if self.stopped {
            return Ok(());
        }
        if message.is_empty() || message.len() > MESSAGE_MAX {
            return Err(SyncError::Malformed("a sync message of the wrong size"));
        }
        match message[0] {
            HELLO => self.receive_hello(engine, store, message),
            EVENTS => self.receive_events(engine, store, message),
            ACK => self.receive_ack(engine, store, message),
            WANT => self.receive_want(engine, store, message),
            PART => self.receive_part(engine, store, message),
            NONE => self.receive_none(engine, store, message),
            copies::SYNC_WANT_BLOCKS | copies::SYNC_BLOCKS_FOLLOW if self.fast => {
                self.receive_blocks_message(engine, store, message)
            }
            _ => Err(SyncError::Malformed("an unknown sync message")),
        }
    }

    fn vector_in(message: &[u8], offset: usize) -> Option<Vector> {
        let rest = &message[offset.min(message.len())..];
        decode_vector(rest).filter(|(_, used)| *used == rest.len()).map(|(v, _)| v)
    }

    fn learn_peer_holds(&mut self, vector: &Vector) {
        for (author, seq) in vector {
            if *seq > self.sent.get(author).copied().unwrap_or(0) {
                self.sent.insert(*author, *seq);
            }
        }
    }

    fn receive_hello(&mut self, engine: &mut SyncEngine, store: &Store, message: &[u8]) -> Result<(), SyncError> {
        let vector = (message.len() >= 2 && message[1] == 1).then(|| Self::vector_in(message, 2)).flatten();
        let vector = vector.ok_or(SyncError::Malformed("a HELLO that does not decode"))?;
        self.hello_received = true;
        engine.note_device_holds(store, &self.peer_key, &vector);
        self.sent.clear();
        self.learn_peer_holds(&vector);
        self.peer_vector = Some(vector);
        self.outstanding = 0;
        self.pump(engine, store);
        Ok(())
    }

    fn receive_events(&mut self, engine: &mut SyncEngine, store: &Store, message: &[u8]) -> Result<(), SyncError> {
        let malformed = SyncError::Malformed("EVENTS");
        // Removed from the profile meanwhile: nothing to sync with.
        let root = engine.root_key(store).ok_or(SyncError::Inactive)?;
        if message.len() < 3 {
            return Err(malformed);
        }
        let count = u16::from_be_bytes([message[1], message[2]]) as usize;
        let mut offset = 3;
        let mut events = Vec::with_capacity(count);
        for _ in 0..count {
            if offset + 2 > message.len() {
                return Err(malformed);
            }
            let header_length = u16::from_be_bytes([message[offset], message[offset + 1]]) as usize;
            if offset + 2 + header_length + 1 > message.len() {
                return Err(malformed);
            }
            let header = &message[offset + 2..offset + 2 + header_length];
            offset += 2 + header_length;
            let has_body = message[offset];
            offset += 1;
            let body = match has_body {
                0 => None,
                1 => {
                    if offset + 4 > message.len() {
                        return Err(malformed);
                    }
                    let length = u32::from_be_bytes(message[offset..offset + 4].try_into().expect("4")) as usize;
                    if length > BODY_MAX || offset + 4 + length > message.len() {
                        return Err(malformed);
                    }
                    offset += 4 + length;
                    Some(&message[offset - length..offset])
                }
                _ => return Err(malformed),
            };
            events.push(Event::verified(header, body, &root)?);
        }
        if offset != message.len() {
            return Err(malformed);
        }
        for event in &events {
            if event.seq > self.sent.get(&event.author).copied().unwrap_or(0) {
                self.sent.insert(event.author, event.seq);
            }
        }
        engine.receive_events(store, &events)?;
        let mut ack = vec![ACK];
        ack.extend_from_slice(&encode_vector(&engine.vector(store)));
        self.outgoing.push(ack);
        self.pump(engine, store);
        Ok(())
    }

    fn receive_ack(&mut self, engine: &mut SyncEngine, store: &Store, message: &[u8]) -> Result<(), SyncError> {
        let vector = Self::vector_in(message, 1).ok_or(SyncError::Malformed("an ACK that does not decode"))?;
        self.learn_peer_holds(&vector);
        engine.note_device_holds(store, &self.peer_key, &vector);
        self.peer_vector = Some(vector);
        self.outstanding = self.outstanding.saturating_sub(1);
        self.pump(engine, store);
        Ok(())
    }

    /// Something new to send: what the peer lacks, within the window; and the next file to copy.
    pub fn pump(&mut self, engine: &mut SyncEngine, store: &Store) {
        if self.stopped || !self.hello_received {
            return;
        }
        while self.outstanding < WINDOW {
            let events = engine.events_missing_from(store, &self.sent, EVENTS_PER_MESSAGE);
            if events.is_empty() {
                break;
            }
            let mut message = vec![EVENTS, 0, 0];
            let mut count: u16 = 0;
            for event in &events {
                let size = 2 + event.header.len() + 1 + event.body.as_ref().map_or(0, |b| 4 + b.len());
                if count > 0 && message.len() + size > MESSAGE_MAX {
                    break;
                }
                message.extend_from_slice(&(event.header.len() as u16).to_be_bytes());
                message.extend_from_slice(&event.header);
                message.push(u8::from(event.body.is_some()));
                if let Some(body) = &event.body {
                    message.extend_from_slice(&(body.len() as u32).to_be_bytes());
                    message.extend_from_slice(body);
                }
                self.sent.insert(event.author, event.seq);
                count += 1;
            }
            message[1..3].copy_from_slice(&count.to_be_bytes());
            self.outstanding += 1;
            self.outgoing.push(message);
        }
        // A copy nobody wants any more (Cancel after Get) stops; what arrived waits for another Get.
        if let Some(copy) = &self.copy {
            if !engine.files_wanted(store).iter().any(|f| f.transfer_id == copy.file.transfer_id) {
                self.copy = None;
            }
        }
        self.start_next_copy(engine, store);
    }

    fn start_next_copy(&mut self, engine: &SyncEngine, store: &Store) {
        if self.copy.is_some() || self.stopped {
            return;
        }
        for file in engine.files_wanted(store) {
            if !file.holders.contains(&self.peer_key) || self.unavailable.contains(&file.transfer_id) {
                continue;
            }
            let partial = engine.received_dir.join(".partial");
            if std::fs::create_dir_all(&partial).is_err() {
                continue;
            }
            let path = partial.join(format!("sync-{}", file.transfer_id));
            if self.request_blocks {
                let map = partial.join(format!("sync-{}.map", file.transfer_id));
                let digest: Option<[u8; 32]> = file.digest.clone().try_into().ok();
                let Some(blocks) = digest.and_then(|d| BlockCopy::open(file.size, d, path.clone(), map).ok()) else {
                    continue;
                };
                let Ok(handle) = std::fs::File::open(&path) else { continue };
                let want = CopyMessage::WantBlocks {
                    id: file.transfer_id.clone(),
                    shift: blocks.shift(),
                    ranges: blocks.missing(),
                };
                if let Some(message) = want.encode_sync() {
                    self.outgoing.push(message);
                }
                self.copy = Some(Copy { file, path, handle, received: 0, requested: 0, blocks: Some(blocks) });
                return;
            }
            let Ok(mut handle) =
                std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(&path)
            else {
                continue;
            };
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
        while (copy.requested < size || (size == 0 && first))
            && copy.requested - copy.received < COPY_AHEAD * FILE_PART_MAX as u64
        {
            let mut want = vec![WANT];
            put_id(&mut want, &copy.file.transfer_id);
            want.extend_from_slice(&copy.requested.to_be_bytes());
            want.extend_from_slice(&COPY_PARTS.to_be_bytes());
            self.outgoing.push(want);
            copy.requested = size.min(copy.requested + u64::from(COPY_PARTS) * FILE_PART_MAX as u64);
            if size == 0 {
                break;
            }
            first = false;
        }
    }

    fn receive_want(&mut self, engine: &mut SyncEngine, store: &Store, message: &[u8]) -> Result<(), SyncError> {
        let mut offset = 1;
        let id = get_id(message, &mut offset).filter(|_| offset + 10 == message.len());
        let id = id.ok_or(SyncError::Malformed("a WANT that does not decode"))?;
        let start = u64::from_be_bytes(message[offset..offset + 8].try_into().expect("8"));
        let parts = u64::from(u16::from_be_bytes([message[offset + 8], message[offset + 9]])).min(COPY_AHEAD);
        let path = engine.local_path_of_file(store, &id);
        let size = path.as_ref().and_then(|_| sync_files::transfer(&store.conn, &id).ok().flatten()).map(|t| t.size);
        let handle = path.and_then(|p| std::fs::File::open(p).ok());
        let (Some(mut handle), Some(size)) = (handle, size.filter(|s| start <= *s)) else {
            let mut none = vec![NONE];
            put_id(&mut none, &id);
            self.outgoing.push(none);
            if size.is_none() {
                // Listed as holding it and it is gone (moved or deleted here): every device hears so now.
                if engine.capture_local_changes(store) > 0 {
                    self.pump(engine, store);
                }
            }
            return Ok(());
        };
        let _ = handle.seek(SeekFrom::Start(start));
        let mut at = start;
        for _ in 0..parts {
            let length = (FILE_PART_MAX as u64).min(size - at) as usize;
            let mut bytes = vec![0u8; length];
            let read = handle.read(&mut bytes).unwrap_or(0);
            bytes.truncate(read);
            let last = at + bytes.len() as u64 >= size;
            let mut part = vec![PART];
            put_id(&mut part, &id);
            part.extend_from_slice(&at.to_be_bytes());
            part.push(u8::from(last));
            part.extend_from_slice(&bytes);
            self.outgoing.push(part);
            at += bytes.len() as u64;
            if last || bytes.is_empty() {
                break;
            }
        }
        let fraction = if size > 0 { at as f64 / size as f64 } else { 1.0 };
        self.serving = (at < size).then_some((id, fraction));
        Ok(())
    }

    fn receive_part(&mut self, engine: &mut SyncEngine, store: &Store, message: &[u8]) -> Result<(), SyncError> {
        let mut offset = 1;
        let id = get_id(message, &mut offset).filter(|_| offset + 9 <= message.len());
        let id = id.ok_or(SyncError::Malformed("a PART that does not decode"))?;
        let at = u64::from_be_bytes(message[offset..offset + 8].try_into().expect("8"));
        let last = message[offset + 8] != 0;
        let bytes = &message[offset + 9..];
        let Some(copy) = self.copy.as_mut() else { return Ok(()) };
        if copy.file.transfer_id != id || at != copy.received {
            return Ok(());
        }
        let end = copy.received + bytes.len() as u64;
        if end > copy.file.size || (last && end != copy.file.size) {
            self.abandon_copy(true);
            return Ok(());
        }
        if copy.handle.write_all(bytes).is_err() {
            // No room left here: what arrived goes, and so does the Get; the item offers Get, which then says so.
            self.abandon_copy(true);
            let _ = engine.cancel_file_request(store, &id);
            return Ok(());
        }
        copy.received = end;
        if copy.received < copy.file.size {
            self.request_more();
            return Ok(());
        }
        let copy = self.copy.take().expect("present");
        let _ = copy.handle.sync_all();
        drop(copy.handle);
        if matches_digest(&copy.path, copy.file.size, &copy.file.digest) {
            let _ = engine.adopt_copied_file(store, &id, &copy.path);
        } else {
            remove_copy(&copy.path);
            self.unavailable.insert(id);
        }
        self.start_next_copy(engine, store);
        Ok(())
    }

    fn receive_none(&mut self, engine: &mut SyncEngine, store: &Store, message: &[u8]) -> Result<(), SyncError> {
        let mut offset = 1;
        let id = get_id(message, &mut offset).filter(|_| offset == message.len());
        let id = id.ok_or(SyncError::Malformed("a NONE that does not decode"))?;
        self.unavailable.insert(id.clone());
        if self.copy.as_ref().is_some_and(|c| c.file.transfer_id == id) {
            self.abandon_copy(false);
        }
        self.start_next_copy(engine, store);
        Ok(())
    }

    /// WANT BLOCKS from the other device (serve the file by blocks), or BLOCKS FOLLOW for our copy.
    fn receive_blocks_message(
        &mut self,
        engine: &mut SyncEngine,
        store: &Store,
        message: &[u8],
    ) -> Result<(), SyncError> {
        match CopyMessage::decode_sync(message).ok_or(SyncError::Malformed("a block message that does not decode"))? {
            CopyMessage::WantBlocks { id, shift, ranges } => {
                let path = engine.local_path_of_file(store, &id);
                let size =
                    path.as_ref().and_then(|_| sync_files::transfer(&store.conn, &id).ok().flatten()).map(|t| t.size);
                let served = (|| {
                    let (path, size) = (path?, size?);
                    let geometry = crate::transfer::Geometry::new(size, shift)?;
                    let file = std::fs::File::open(&path).ok()?;
                    let hashed = crate::transfer::tree::hash_file(&file, &geometry, false).ok()?;
                    let wire = hex::decode(&id).ok()?;
                    let mut serve =
                        crate::transfer::BlockServe::new(&wire, geometry, hashed.leaves, FILE_PART_MAX, 8 << 20);
                    serve.want(&ranges).ok()?;
                    Some((hashed.root, serve, path))
                })();
                match served {
                    Some((root, serve, path)) => {
                        if let Some(follow) = (CopyMessage::BlocksFollow { id: id.clone(), root, shift }).encode_sync()
                        {
                            self.outgoing.push(follow);
                        }
                        self.serving = Some((id.clone(), 0.0));
                        self.serve_blocks.push(ServeBlocks { transfer_id: id, serve, path });
                    }
                    None => {
                        let mut none = vec![NONE];
                        put_id(&mut none, &id);
                        self.outgoing.push(none);
                        if size.is_none() && engine.capture_local_changes(store) > 0 {
                            self.pump(engine, store);
                        }
                    }
                }
            }
            CopyMessage::BlocksFollow { id, root, shift } => {
                let followed = self
                    .copy
                    .as_mut()
                    .filter(|c| c.file.transfer_id == id)
                    .and_then(|c| c.blocks.as_mut())
                    .map(|b| b.follow(root, shift));
                if followed == Some(false) {
                    self.abandon_copy(false);
                    self.start_next_copy(engine, store);
                }
            }
        }
        Ok(())
    }

    /// HASHES for the copy by blocks; `false` when this exchange is not copying `id` by blocks.
    pub fn hashes(&mut self, id: &str, index: u32, hashes: &[u8]) -> bool {
        let Some(copy) = self.copy.as_mut().filter(|c| c.file.transfer_id == id) else { return false };
        let Some(blocks) = copy.blocks.as_mut() else { return false };
        if blocks.hashes(index, hashes).is_none() {
            self.abandon_copy(false);
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

    /// A PART for the copy by blocks; `false` when this exchange is not copying `id` by blocks.
    pub fn part(&mut self, engine: &mut SyncEngine, store: &Store, id: &str, offset: u64, data: &[u8]) -> bool {
        let Some(copy) = self.copy.as_mut().filter(|c| c.file.transfer_id == id) else { return false };
        let Some(blocks) = copy.blocks.as_mut() else { return false };
        match blocks.part(offset, data) {
            CopyPart::Pending | CopyPart::Late => {}
            CopyPart::Written(_) => self.queue_have(id),
            CopyPart::Corrupt(block) => {
                let want =
                    CopyMessage::WantBlocks { id: id.to_owned(), shift: blocks.shift(), ranges: vec![(block, 1)] };
                if let Some(message) = want.encode_sync() {
                    self.outgoing.push(message);
                }
            }
            CopyPart::Refused => {
                self.abandon_copy(false);
                self.start_next_copy(engine, store);
            }
            CopyPart::Complete => {
                self.queue_have(id);
                let copy = self.copy.take().expect("present");
                drop(copy.handle);
                match copy.blocks.expect("by blocks").finish() {
                    Some(path) => {
                        let _ = engine.adopt_copied_file(store, id, &path);
                    }
                    None => {
                        self.unavailable.insert(id.to_owned());
                    }
                }
                self.start_next_copy(engine, store);
            }
        }
        true
    }

    fn abandon_copy(&mut self, discard: bool) {
        if let Some(copy) = self.copy.take() {
            if discard {
                remove_copy(&copy.path);
            }
            self.unavailable.insert(copy.file.transfer_id);
        }
    }
}
