//! Fast transfers on disk (ADR 0018 § 4 and 5): the receiver's block map beside its staging file, blocks written at
//! their offsets and made durable in batches, the read-back that checks the tree and the BLAKE2b digest in one pass
//! before publishing; the sender's tree beside its snapshot. No schema change: `verified_bytes` keeps meaning the
//! contiguous durable prefix, so an older helper that meets the same partial file resumes from that prefix, and its
//! recovery sweep deletes both sidecars (they are named by no row), which this one then rebuilds.
//!
//! Sidecars are named by the transfer id: `received/.partial/<id>.map` and `outgoing/<id>.tree`.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::receive::partial_path;
use super::transfers::{self, apply_event, load, owned, set_column, TransferEvent, TransferRecord, TransferState};
use super::{Result, Store, StoreError};
use crate::transfer::sidecar::{BlockMap, Header, SenderTree, HEADER_BYTES};
use crate::transfer::tree::{self, read_exact_at, write_all_at};
use crate::transfer::{AssemblyError, BlockAssembly, BlockSet, Geometry, PartOutcome};

/// A durability batch (ADR 0018 § 4): every 8 MiB or every second of received blocks.
const BATCH_BYTES: u64 = 8 << 20;
const BATCH_INTERVAL: Duration = Duration::from_secs(1);

/// Block ranges `(first, count)`.
pub type Ranges = Vec<(u32, u32)>;

/// What one PART did, for the helper to answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockPart {
    Pending,
    /// The block checked and is written; a HAVE reports it.
    Written(u32),
    /// The block failed its leaf and is wanted again.
    Corrupt(u32),
    /// For a block already complete: dropped.
    Late,
}

/// The file's BLAKE2b-256 content digest computed while its blocks arrive (ADR 0018 § 5), on a thread of its own, so
/// the check before saving does not wait for one single-threaded pass over the whole file. Blocks go in in order:
/// each as it completes when it is the next one, and any later blocks that completed earlier read back from the file.
/// It covers the bytes as they arrived and were checked against their leaves; the tree read back before saving
/// covers the disk, so the two together prove the file on disk has the offered digest.
#[derive(Debug)]
struct StreamedDigest {
    sender: Option<std::sync::mpsc::Sender<Vec<u8>>>,
    handle: Option<std::thread::JoinHandle<[u8; 32]>>,
    next: u32,
}

impl StreamedDigest {
    fn new() -> Self {
        let (sender, receiver) = std::sync::mpsc::channel::<Vec<u8>>();
        let handle = std::thread::Builder::new()
            .name("szfriends-digest".into())
            .spawn(move || {
                use blake2::digest::{Update, VariableOutput};
                let mut hasher = blake2::Blake2bVar::new(32).expect("32-byte output");
                for block in receiver {
                    hasher.update(&block);
                }
                let mut out = [0u8; 32];
                hasher.finalize_variable(&mut out).expect("length matches");
                out
            })
            .ok();
        Self { sender: handle.as_ref().map(|_| sender), handle, next: 0 }
    }

    /// Feeds every block from `next` that is complete: `fresh` (just completed, still in memory) when it is the next,
    /// the others read back from `file`.
    fn advance(&mut self, file: &File, geometry: &Geometry, complete: &BlockSet, fresh: Option<(u32, &[u8])>) {
        let Some(sender) = &self.sender else { return };
        while complete.contains(self.next) {
            let data = match fresh {
                Some((block, data)) if block == self.next => data.to_vec(),
                _ => {
                    let (offset, length) = geometry.span(self.next);
                    let mut buffer = vec![0u8; length];
                    if read_exact_at(file, &mut buffer, offset).is_err() {
                        self.sender = None; // the check before saving reads the file whole instead
                        return;
                    }
                    buffer
                }
            };
            if sender.send(data).is_err() {
                self.sender = None;
                return;
            }
            self.next += 1;
        }
    }

    /// The digest once every block went in; `None` when streaming stopped (the caller hashes the file).
    fn finish(mut self, blocks: u32) -> Option<[u8; 32]> {
        let complete = self.next == blocks && self.sender.is_some();
        self.sender = None;
        let digest = self.handle.take()?.join().ok()?;
        complete.then_some(digest)
    }
}

/// The check before saving a file received by blocks (ADR 0018 § 5), detached from the store so it can run on a
/// thread of its own: the file read back through the descriptor that wrote it, its tree on every core, and the digest
/// streamed as it arrived (or read here, after a restart).
#[derive(Debug)]
pub struct BlockCheck {
    record: TransferRecord,
    file: File,
    partial: PathBuf,
    geometry: Geometry,
    root: tree::Leaf,
    complete: BlockSet,
    streamed: StreamedDigest,
}

/// What [`BlockCheck::run`] found.
#[derive(Debug)]
pub struct CheckedFile {
    record: TransferRecord,
    partial: PathBuf,
    matches: bool,
}

impl CheckedFile {
    pub fn transfer_id(&self) -> &str {
        &self.record.transfer_id
    }

    pub fn conversation_id(&self) -> &str {
        &self.record.conversation_id
    }
}

impl BlockCheck {
    pub fn transfer_id(&self) -> &str {
        &self.record.transfer_id
    }

    /// Reads the file back and checks it: the tree against the offered root, the digest against the offered one.
    pub fn run(self) -> CheckedFile {
        let Self { record, file, partial, geometry, root, complete, mut streamed } = self;
        let named = fs::symlink_metadata(&partial).ok();
        let opened = file.metadata().ok();
        let same_file = match (&named, &opened) {
            (Some(named), Some(opened)) => {
                #[cfg(unix)]
                let same = {
                    use std::os::unix::fs::MetadataExt;
                    named.dev() == opened.dev() && named.ino() == opened.ino()
                };
                #[cfg(not(unix))]
                let same = true;
                named.is_file() && same && opened.len() == record.size
            }
            _ => false,
        };
        streamed.advance(&file, &geometry, &complete, None);
        let streamed = streamed.finish(geometry.blocks);
        let hashed = same_file.then(|| tree::hash_file(&file, &geometry, streamed.is_none()).ok()).flatten();
        let digest = streamed.or_else(|| hashed.as_ref().and_then(|h| h.digest));
        let matches = hashed.is_some_and(|h| h.root == root) && digest == Some(record.digest);
        CheckedFile { record, partial, matches }
    }
}

/// One download by blocks: its assembly, staging file and map.
#[derive(Debug)]
pub(crate) struct BlockDownload {
    assembly: BlockAssembly,
    streamed: StreamedDigest,
    digest: [u8; 32],
    file: File,
    partial: PathBuf,
    map: Option<File>,
    durable: BlockSet,
    unsynced: Vec<u32>,
    unsynced_bytes: u64,
    first_unsynced: Option<Instant>,
    unreported_complete: Vec<u32>,
    unreported_durable: Vec<u32>,
}

fn open_rw(path: &Path, create: bool) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(create);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    options.open(path)
}

/// Writes a map without flushing it: nothing in it counts until a durability batch, whose flush covers it too (the
/// map written at OFFER only remembers the offer's tree; lost, the file goes by CHUNK).
fn write_sidecar(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut file = open_rw(path, true)?;
    file.set_len(0)?;
    file.write_all(bytes)
}

/// The sender's tree is a cache, checked against its root and the row's digest whenever it is read: not flushed.
pub(super) fn write_tree_cache(path: &Path, tree: &SenderTree) {
    let _ = open_rw(path, true).and_then(|mut file| {
        file.set_len(0)?;
        file.write_all(&tree.encode())
    });
}

fn ranges(blocks: &mut Vec<u32>) -> Vec<(u32, u32)> {
    blocks.sort_unstable();
    blocks.dedup();
    let mut out: Vec<(u32, u32)> = Vec::new();
    for &block in blocks.iter() {
        match out.last_mut() {
            Some((first, count)) if *first + *count == block => *count += 1,
            _ => out.push((block, 1)),
        }
    }
    blocks.clear();
    out
}

/// Blocks of `claimed` whose bytes in `file` match their leaves; read and hashed on every core.
fn recheck(file: &File, geometry: &Geometry, leaves: &[tree::Leaf], claimed: &BlockSet) -> BlockSet {
    let mut intact = BlockSet::new(geometry.blocks);
    let wanted: Vec<u32> = claimed.iter().collect();
    for batch in wanted.chunks(64) {
        let mut buffers = Vec::with_capacity(batch.len());
        for &block in batch {
            let (offset, length) = geometry.span(block);
            let mut buffer = vec![0u8; length];
            buffers.push(read_exact_at(file, &mut buffer, offset).is_ok().then_some(buffer));
        }
        let readable: Vec<(u32, &[u8])> =
            batch.iter().zip(&buffers).filter_map(|(b, data)| Some((*b, data.as_deref()?))).collect();
        let hashed: Vec<tree::Leaf> = std::thread::scope(|scope| {
            let handles: Vec<_> =
                readable.iter().map(|(block, data)| scope.spawn(move || tree::leaf(*block, data))).collect();
            handles.into_iter().map(|h| h.join().expect("leaf thread")).collect()
        });
        for ((block, _), leaf) in readable.iter().zip(hashed) {
            if leaf == leaves[*block as usize] {
                intact.insert(*block);
            }
        }
    }
    intact
}

/// The contiguous durable prefix in bytes: what `verified_bytes` records.
fn durable_prefix(geometry: &Geometry, durable: &BlockSet) -> u64 {
    let blocks = durable.prefix();
    if blocks == geometry.blocks {
        geometry.size
    } else {
        u64::from(blocks) << geometry.shift
    }
}

fn receiving(conn: &rusqlite::Connection, transfer_id: &str, conversation_id: &str) -> Result<TransferRecord> {
    match load(conn, transfer_id)? {
        Some(r) if !r.outgoing && r.state == TransferState::Receiving && r.conversation_id == conversation_id => Ok(r),
        Some(r) if !r.outgoing && r.conversation_id == conversation_id => Err(StoreError::Stale),
        _ => Err(StoreError::Invalid("not this friend's transfer")),
    }
}

/// The settings key that switches fast transfers (ADR 0018 § 1): on unless it holds 0. No view shows it; it is the way
/// back for a release without a protocol change.
pub const SETTING_FAST_TRANSFERS: &str = "transfers.fast";

impl Store {
    /// Whether this helper offers fast transfers to peers that have them too ([`SETTING_FAST_TRANSFERS`]).
    pub fn fast_transfers_enabled(&self) -> bool {
        !matches!(
            super::sync_settings::setting(&self.conn, SETTING_FAST_TRANSFERS),
            Ok(rusqlite::types::Value::Integer(0))
        )
    }

    pub fn set_fast_transfers_enabled(&mut self, enabled: bool) -> Result<()> {
        let value = if enabled { rusqlite::types::Value::Null } else { rusqlite::types::Value::Integer(0) };
        self.write(|conn| super::sync_settings::set_setting(conn, SETTING_FAST_TRANSFERS, value))
    }

    fn partial_directory(&self) -> PathBuf {
        self.state_dir().join("received").join(".partial")
    }

    /// `received/.partial/<id>.map`.
    pub fn block_map_path(&self, transfer_id: &str) -> PathBuf {
        self.partial_directory().join(format!("{transfer_id}.map"))
    }

    /// `outgoing/<id>.tree`.
    pub fn sender_tree_path(&self, transfer_id: &str) -> PathBuf {
        self.state_dir().join("outgoing").join(format!("{transfer_id}.tree"))
    }

    /// The tree a friend's OFFER announced, kept for when the person accepts (perhaps after a restart). Only for an
    /// offer recorded from that friend and not yet answered; the offered size and digest are the row's.
    pub fn record_offered_tree(
        &mut self,
        transfer_id: &str,
        conversation_id: &str,
        geometry: Geometry,
        root: tree::Leaf,
    ) -> Result<()> {
        let record = load(&self.conn, transfer_id)?.ok_or(StoreError::NotFound)?;
        if record.outgoing || record.conversation_id != conversation_id || record.size != geometry.size {
            return Err(StoreError::Invalid("not this friend's offer"));
        }
        if record.state != TransferState::WaitingForYou || self.offered_tree(transfer_id).is_some() {
            return Ok(());
        }
        super::transfer_files::ensure_private_directory(&self.partial_directory())?;
        let map = BlockMap::new(Header { geometry, root, digest: record.digest });
        write_sidecar(&self.block_map_path(transfer_id), &map.encode())?;
        Ok(())
    }

    fn read_map(&self, transfer_id: &str) -> Option<BlockMap> {
        let bytes = fs::read(self.block_map_path(transfer_id)).ok()?;
        BlockMap::decode(&bytes)
    }

    /// The offered tree's header, when the map exists and matches the row.
    pub fn offered_tree(&self, transfer_id: &str) -> Option<Header> {
        let record = load(&self.conn, transfer_id).ok().flatten()?;
        let map = self.read_map(transfer_id)?;
        (map.header.geometry.size == record.size && map.header.digest == record.digest).then_some(map.header)
    }

    /// Whether this download is by blocks with its leaves known: a restart resumes it by WANT, not by prefix.
    pub fn has_block_map(&self, transfer_id: &str) -> bool {
        self.read_map(transfer_id).is_some_and(|m| m.leaves.is_some())
    }

    /// Opens a download by blocks: the staging file at its full size, the map, and every block the map claims
    /// re-read and checked before it counts (after an unclean exit the map may run ahead of the disk).
    fn open_blocks(&mut self, transfer_id: &str, conversation_id: &str) -> Result<()> {
        if self.receiving.blocks.contains_key(transfer_id) {
            return Ok(());
        }
        let record = receiving(&self.conn, transfer_id, conversation_id)?;
        let map = self.read_map(transfer_id).ok_or(StoreError::Invalid("no offered tree"))?;
        if map.header.geometry.size != record.size || map.header.digest != record.digest {
            return Err(StoreError::Invalid("tree does not match the offer"));
        }
        let partial = partial_path(&self.conn, transfer_id)?.ok_or(StoreError::Invalid("no staging file"))?;
        let file = open_rw(&partial, false).map_err(|_| StoreError::FileMissing)?;
        // The CHUNK flow left nothing past its prefix; anything there now came from this map's blocks.
        if file.metadata()?.len() < record.size {
            file.set_len(record.size)?;
        }
        let geometry = map.header.geometry;
        let bitmap_offset = map.bitmap_offset() as u64;
        let (assembly, durable, handle) = match map.leaves {
            Some(leaves) => {
                let intact = recheck(&file, &geometry, &leaves, &map.durable);
                let assembly = BlockAssembly::resumed(geometry, map.header.root, leaves, intact.clone())
                    .ok_or(StoreError::Invalid("map does not check"))?;
                let handle = open_rw(&self.block_map_path(transfer_id), false)?;
                if intact != map.durable {
                    write_all_at(&handle, &intact.to_bitmap(), bitmap_offset)?;
                    handle.sync_all()?;
                }
                (assembly, intact, Some(handle))
            }
            None => (BlockAssembly::new(geometry, map.header.root), BlockSet::new(geometry.blocks), None),
        };
        // Until the leaves are here, a prefix the CHUNK flow made durable stands (block_hashes re-checks it).
        let prefix = durable_prefix(&geometry, &durable);
        if handle.is_some() && prefix != record.verified_bytes {
            self.write(|conn| set_column(conn, transfer_id, "verified_bytes", &(prefix as i64)))?;
        }
        self.receiving.forget(transfer_id); // the CHUNK flow's open file, if it had one
        self.receiving.blocks.insert(
            transfer_id.to_owned(),
            BlockDownload {
                assembly,
                streamed: StreamedDigest::new(),
                digest: record.digest,
                file,
                partial,
                map: handle,
                durable,
                unsynced: Vec::new(),
                unsynced_bytes: 0,
                first_unsynced: None,
                unreported_complete: Vec::new(),
                unreported_durable: Vec::new(),
            },
        );
        Ok(())
    }

    /// Starts or resumes a download by blocks; `Ok(false)` when there is no offered tree for it (it goes by CHUNK).
    pub fn begin_blocks(&mut self, transfer_id: &str, conversation_id: &str) -> Result<bool> {
        if self.read_map(transfer_id).is_none() {
            return Ok(false);
        }
        self.open_blocks(transfer_id, conversation_id).map(|()| true)
    }

    /// Stops treating a download as blocks (a session without fast transfers resumes it by CHUNK from the prefix): the
    /// map goes, and the CHUNK flow truncates to the prefix as it reopens.
    pub fn drop_blocks(&mut self, transfer_id: &str) {
        self.receiving.blocks.remove(transfer_id);
        let _ = fs::remove_file(self.block_map_path(transfer_id));
    }
}

#[path = "blocks_receive.rs"]
mod receive_blocks;

#[path = "blocks_check.rs"]
mod check;
