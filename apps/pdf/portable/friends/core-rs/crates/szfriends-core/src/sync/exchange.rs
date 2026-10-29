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
    pub root: [u8; 32],
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
    /// The helper copies by blocks from every holder at once (`pulled`): this exchange starts no copy of its own.
    pulled: bool,
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
            pulled: false,
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

    /// The helper pulls this device's copies from every holder at once (ADR 0018 § 9.6): no copy starts here.
    pub fn set_pulled(&mut self, pulled: bool) {
        self.pulled = pulled;
    }

    /// A copy elsewhere finished this file: one in progress here stops (what arrived waits, as after Cancel).
    pub fn stop_copy(&mut self, transfer_id: &str) {
        if self.copy.as_ref().is_some_and(|c| c.file.transfer_id == transfer_id) {
            if let Some(blocks) = self.copy.take().and_then(|c| c.blocks) {
                blocks.pause();
            }
        }
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
}

#[path = "exchange_copies.rs"]
mod own_copies;
