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

    /// Blocks still missing, for WANT.
    pub fn block_missing(&self, transfer_id: &str) -> Vec<(u32, u32)> {
        self.receiving.blocks.get(transfer_id).map(|d| d.assembly.missing_ranges()).unwrap_or_default()
    }

    /// For a peer without Pieces: every block not complete, partly received ones included (they go again whole).
    pub fn block_missing_whole(&self, transfer_id: &str) -> Vec<(u32, u32)> {
        self.receiving.blocks.get(transfer_id).map(|d| d.assembly.complete().missing_ranges()).unwrap_or_default()
    }

    /// The pieces still missing from blocks partly received (WANT's Pieces, ADR 0018 § 3).
    pub fn block_missing_pieces(&self, transfer_id: &str) -> Vec<(u32, u32)> {
        self.receiving.blocks.get(transfer_id).map(|d| d.assembly.missing_pieces()).unwrap_or_default()
    }

    /// Pieces arrived since the last call in blocks not yet complete (HAVE's Pieces).
    pub fn take_piece_have(&mut self, transfer_id: &str) -> Vec<(u32, u32)> {
        self.receiving.blocks.get_mut(transfer_id).map(|d| d.assembly.take_arrived_pieces()).unwrap_or_default()
    }

    /// Leaves from a HASHES frame; once all are here and check, the map gains them. `Ok(true)` when they completed.
    pub fn block_hashes(
        &mut self,
        transfer_id: &str,
        conversation_id: &str,
        index: u32,
        hashes: &[u8],
    ) -> Result<bool> {
        self.open_blocks(transfer_id, conversation_id)?;
        let map_path = self.block_map_path(transfer_id);
        let verified = load(&self.conn, transfer_id)?.map_or(0, |r| r.verified_bytes);
        let download = self.receiving.blocks.get_mut(transfer_id).expect("opened");
        let done = download.assembly.accept_hashes(index, hashes).map_err(|_| StoreError::Invalid("bad leaves"))?;
        if done && download.map.is_none() {
            let geometry = *download.assembly.geometry();
            let header = Header { geometry, root: *download.assembly.root(), digest: download.digest };
            // A download begun by CHUNK: the whole blocks of its durable prefix count once they check (§ 1).
            let whole = if verified >= geometry.size { geometry.blocks } else { (verified >> geometry.shift) as u32 };
            if whole > 0 && download.durable.is_empty() {
                let leaves = download.assembly.leaves().expect("checked").to_vec();
                let intact =
                    recheck(&download.file, &geometry, &leaves, &BlockSet::full(whole).widened(geometry.blocks));
                download.assembly = BlockAssembly::resumed(geometry, header.root, leaves, intact.clone())
                    .ok_or(StoreError::Invalid("map does not check"))?;
                // Reported at once, so the sender drops them from what it was asked for before the leaves arrived.
                download.unreported_complete.extend(intact.iter());
                download.unreported_durable.extend(intact.iter());
                download.durable = intact;
            }
            let mut map = BlockMap::new(header);
            map.leaves = download.assembly.leaves().map(<[_]>::to_vec);
            map.durable = download.durable.clone();
            write_sidecar(&map_path, &map.encode())?;
            download.map = Some(open_rw(&map_path, false)?);
            let reused = self.reuse_previous_version(transfer_id);
            if !reused.is_empty() {
                self.flush_blocks(transfer_id)?;
            }
            let download = self.receiving.blocks.get_mut(transfer_id).expect("opened");
            if geometry.size == 0 && download.assembly.is_complete() {
                // An empty file: its one block is complete and nothing needs writing.
                download.durable.insert(0);
                download.unreported_complete.push(0);
                download.unreported_durable.push(0);
            }
        }
        if done {
            // Blocks this computer already holds from the same friend are not wanted from them (§ 9.5).
            self.reuse_blocks(transfer_id, conversation_id)?;
        }
        Ok(done)
    }

    /// One PART: gathered, and when its block completes, checked and written at its offset.
    pub fn block_part(
        &mut self,
        transfer_id: &str,
        conversation_id: &str,
        offset: u64,
        data: &[u8],
    ) -> Result<BlockPart> {
        self.open_blocks(transfer_id, conversation_id)?;
        let download = self.receiving.blocks.get_mut(transfer_id).expect("opened");
        let outcome = match download.assembly.accept_part(offset, data) {
            Ok(outcome) => outcome,
            Err(AssemblyError::TooManyInFlight) => return Err(StoreError::Invalid("too many blocks in flight")),
            Err(_) => return Err(StoreError::Invalid("part out of place")),
        };
        match outcome {
            PartOutcome::Pending => Ok(BlockPart::Pending),
            PartOutcome::Late => Ok(BlockPart::Late),
            PartOutcome::Corrupt { block } => Ok(BlockPart::Corrupt(block)),
            PartOutcome::Complete { block, data } => {
                let (block_offset, _) = download.assembly.geometry().span(block);
                if let Err(error) = write_all_at(&download.file, &data, block_offset) {
                    download.assembly.unwritten(block);
                    return Err(error.into());
                }
                let geometry = *download.assembly.geometry();
                download.streamed.advance(
                    &download.file,
                    &geometry,
                    download.assembly.complete(),
                    Some((block, &data)),
                );
                download.unsynced.push(block);
                download.unsynced_bytes += data.len() as u64;
                download.first_unsynced.get_or_insert_with(Instant::now);
                download.unreported_complete.push(block);
                let due = download.unsynced_bytes >= BATCH_BYTES || download.assembly.is_complete();
                if due {
                    self.flush_blocks(transfer_id)?;
                }
                Ok(BlockPart::Written(block))
            }
        }
    }

    /// When the oldest written block not yet durable became so overdue that a batch should run now.
    pub fn block_flush_due(&self) -> Option<Instant> {
        self.receiving.blocks.values().filter_map(|d| d.first_unsynced).min().map(|at| at + BATCH_INTERVAL)
    }

    /// A durability batch: the blocks, then the map's bitmap, then both durable at once; then the prefix committed.
    pub fn flush_blocks(&mut self, transfer_id: &str) -> Result<()> {
        let Some(download) = self.receiving.blocks.get_mut(transfer_id) else { return Ok(()) };
        if download.unsynced.is_empty() {
            return Ok(());
        }
        let Some(map) = download.map.as_ref() else { return Ok(()) };
        // Blocks ordered before the bitmap that claims them, without the drive cache flush (`disk::order_writes`);
        // the map's full flush below then makes both durable at once: one F_FULLFSYNC per batch on Apple systems.
        super::disk::order_writes(&download.file)?;
        for &block in &download.unsynced {
            download.durable.insert(block);
        }
        let geometry = *download.assembly.geometry();
        let bitmap_offset = (HEADER_BYTES + 32 * geometry.blocks as usize) as u64;
        write_all_at(map, &download.durable.to_bitmap(), bitmap_offset)?;
        if self.batch.is_some() {
            super::disk::order_writes(map)?; // the batch's commit flushes the drive
        } else {
            super::disk::make_durable(map)?;
        }
        download.unreported_durable.append(&mut download.unsynced);
        download.unsynced_bytes = 0;
        download.first_unsynced = None;
        let prefix = durable_prefix(&geometry, &download.durable);
        self.write(|conn| set_column(conn, transfer_id, "verified_bytes", &(prefix as i64)))
    }

    /// Every download by blocks whose batch is due (or all of them, at a session's end or exit).
    pub fn flush_due_blocks(&mut self, all: bool) -> Result<Vec<String>> {
        let now = Instant::now();
        let due: Vec<String> = self
            .receiving
            .blocks
            .iter()
            .filter(|(_, d)| d.first_unsynced.is_some_and(|at| all || now >= at + BATCH_INTERVAL))
            .map(|(id, _)| id.clone())
            .collect();
        for id in &due {
            self.flush_blocks(id)?;
        }
        Ok(due)
    }

    /// What changed since the last HAVE: blocks written, blocks made durable.
    pub fn take_block_have(&mut self, transfer_id: &str) -> (Ranges, Ranges) {
        let Some(download) = self.receiving.blocks.get_mut(transfer_id) else { return (Vec::new(), Vec::new()) };
        (ranges(&mut download.unreported_complete), ranges(&mut download.unreported_durable))
    }

    /// Every block durable: ready for the publish check.
    pub fn blocks_all_durable(&self, transfer_id: &str) -> bool {
        self.receiving.blocks.get(transfer_id).is_some_and(|d| d.durable.is_full())
    }

    /// The blocks complete so far, as a fraction of the file's bytes (the item's progress).
    pub fn block_progress(&self, transfer_id: &str) -> Option<u64> {
        let download = self.receiving.blocks.get(transfer_id)?;
        let geometry = download.assembly.geometry();
        Some(download.assembly.complete().iter().map(|b| geometry.span(b).1 as u64).sum())
    }

    /// A group ended with these downloads open.
    ///
    /// Since pieces (ADR 0018 § 3), partly received blocks are kept: the next session's WANT names only their missing
    /// pieces. Only a restart loses them (they live in memory).
    pub fn blocks_session_ended(&mut self, _transfers: &[String]) {}

    /// ADR 0018 § 5, in one call: [`Store::begin_block_check`], [`BlockCheck::run`], [`Store::complete_block_check`].
    pub fn finish_block_transfer(&mut self, transfer_id: &str, conversation_id: &str) -> Result<PathBuf> {
        let check = self.begin_block_check(transfer_id, conversation_id)?;
        self.complete_block_check(check.run())
    }

    /// Every block durable: the check before saving, handed out so it can run off the helper's thread (large files
    /// show "Finishing…" meanwhile). The download leaves the open set; its map stays until the check completes, so a
    /// helper that stops meanwhile runs the check again at its next start.
    pub fn begin_block_check(&mut self, transfer_id: &str, conversation_id: &str) -> Result<BlockCheck> {
        let record = receiving(&self.conn, transfer_id, conversation_id)?;
        self.flush_blocks(transfer_id)?;
        if !self.blocks_all_durable(transfer_id) {
            return Err(StoreError::Invalid("file is incomplete"));
        }
        let download = self.receiving.blocks.remove(transfer_id).expect("checked");
        Ok(BlockCheck {
            geometry: *download.assembly.geometry(),
            root: *download.assembly.root(),
            complete: download.assembly.complete().clone(),
            record,
            file: download.file,
            partial: download.partial,
            streamed: download.streamed,
        })
    }

    /// A file this computer holds that has the offered bytes: received from the same friend (or copied here from
    /// another of the person's computers), still where it was saved at its size, and still hashing to the digest.
    /// Never another friend's file: a friend learns at most that the person kept what that friend sent (§ 8).
    fn held_copy(&self, record: &TransferRecord) -> Option<PathBuf> {
        let candidates = transfers::rows(
            &self.conn,
            "WHERE conversation_id = ?1 AND outgoing = 0 AND state = ?2 AND size = ?3 AND digest = ?4 \
             AND transfer_id != ?5 ORDER BY updated_at DESC LIMIT 4",
            &[
                &record.conversation_id,
                &(TransferState::Received as i64),
                &(record.size as i64),
                &record.digest.to_vec(),
                &record.transfer_id,
            ],
        )
        .ok()?;
        candidates.into_iter().filter_map(|r| r.received_path).find(|path| {
            fs::metadata(path).is_ok_and(|m| m.is_file() && m.len() == record.size)
                && super::file_digest(path, u64::MAX).ok() == Some(record.digest)
        })
    }

    /// After acceptance: when this computer holds the offered file, its bytes go into the staging file and become
    /// the durable count, so the transfer completes without them crossing the route. `true` when it did.
    pub fn fill_from_held_copy(&mut self, transfer_id: &str) -> Result<bool> {
        let record = load(&self.conn, transfer_id)?.ok_or(StoreError::NotFound)?;
        if record.outgoing || record.state != TransferState::Receiving || record.size == 0 {
            return Ok(false);
        }
        let Some(source) = self.held_copy(&record) else { return Ok(false) };
        let partial = partial_path(&self.conn, transfer_id)?.ok_or(StoreError::Invalid("no staging file"))?;
        let mut out = open_rw(&partial, false)?;
        out.set_len(0)?;
        std::io::copy(&mut File::open(&source)?, &mut out)?;
        if self.batch.is_some() {
            super::disk::order_writes(&out)?;
        } else {
            super::disk::make_durable(&out)?;
        }
        if out.metadata()?.len() != record.size {
            out.set_len(0)?;
            return Ok(false);
        }
        self.receiving.forget(transfer_id);
        self.write(|conn| set_column(conn, transfer_id, "verified_bytes", &(record.size as i64)))?;
        Ok(true)
    }

    /// Whether a download's bytes are all here already (filled locally): it finishes by CHUNK's DONE, not by blocks.
    pub fn whole_file_held(&self, transfer_id: &str) -> bool {
        load(&self.conn, transfer_id).ok().flatten().is_some_and(|r| !r.outgoing && r.verified_bytes == r.size)
    }

    /// The blocks a new version can take from the version the same friend sent before (§ 9.5): the newest file of
    /// the same name received from them, still here, hashed at this geometry; a block whose leaf matches at the same
    /// position is copied into the staging file and counts as arrived. Returns the blocks taken.
    fn reuse_previous_version(&mut self, transfer_id: &str) -> Vec<u32> {
        let Ok(Some(record)) = load(&self.conn, transfer_id) else { return Vec::new() };
        let previous = transfers::rows(
            &self.conn,
            "WHERE conversation_id = ?1 AND outgoing = 0 AND state = ?2 AND file_name = ?3 AND transfer_id != ?4 \
             ORDER BY updated_at DESC LIMIT 1",
            &[&record.conversation_id, &(TransferState::Received as i64), &record.file_name, &record.transfer_id],
        )
        .ok()
        .and_then(|mut rows| rows.pop())
        .and_then(|r| r.received_path);
        let Some(download) = self.receiving.blocks.get_mut(transfer_id) else { return Vec::new() };
        let Some(old) = previous.and_then(|p| File::open(p).ok()) else { return Vec::new() };
        let Some(leaves) = download.assembly.leaves().map(<[_]>::to_vec) else { return Vec::new() };
        let geometry = *download.assembly.geometry();
        let old_size = old.metadata().map_or(0, |m| m.len());
        let mut taken = Vec::new();
        for block in 0..geometry.blocks {
            let (offset, length) = geometry.span(block);
            if download.assembly.complete().contains(block) || offset + length as u64 > old_size || length == 0 {
                continue;
            }
            let mut buffer = vec![0u8; length];
            if read_exact_at(&old, &mut buffer, offset).is_err() || tree::leaf(block, &buffer) != leaves[block as usize]
            {
                continue;
            }
            if write_all_at(&download.file, &buffer, offset).is_ok() && download.assembly.mark_complete(block) {
                download.unsynced.push(block);
                download.unsynced_bytes += length as u64;
                download.first_unsynced.get_or_insert_with(Instant::now);
                download.unreported_complete.push(block);
                download.streamed.advance(
                    &download.file,
                    &geometry,
                    download.assembly.complete(),
                    Some((block, &buffer)),
                );
                taken.push(block);
            }
        }
        taken
    }

    /// Whether a download's check is quick enough to run on the caller's thread (at most 16 MiB).
    pub fn block_check_is_quick(&self, transfer_id: &str) -> bool {
        self.receiving.blocks.get(transfer_id).is_some_and(|d| d.assembly.geometry().size <= 16 << 20)
    }

    /// Saves a file whose check passed, or deletes it and fails the transfer (DigestMismatch). A transfer cancelled
    /// while it was checked keeps nothing.
    pub fn complete_block_check(&mut self, checked: CheckedFile) -> Result<PathBuf> {
        let CheckedFile { record, partial, matches } = checked;
        let map = self.read_map(&record.transfer_id);
        let _ = fs::remove_file(self.block_map_path(&record.transfer_id));
        let still = receiving(&self.conn, &record.transfer_id, &record.conversation_id).is_ok();
        if matches && still {
            let published = self.publish_received(&record, &partial)?;
            // Its leaves, for blocks of a later version from the same friend (§ 9.5).
            if let Some(leaves) =
                map.as_ref().and_then(|m| m.leaves.as_deref()).filter(|_| !published.as_os_str().is_empty())
            {
                let geometry = map.as_ref().expect("read").header.geometry;
                self.index_blocks(&record.conversation_id, &record.transfer_id, &published, &geometry, leaves);
            }
            return Ok(published);
        }
        let _ = fs::remove_file(&partial);
        if !still {
            return Err(StoreError::Stale);
        }
        self.fail_received_transfer(&record.transfer_id)?;
        Err(StoreError::DigestMismatch)
    }

    /// The sender's tree for one of our offers: from `outgoing/<id>.tree` when it matches the row, else computed from
    /// the snapshot (whose digest must still be the offered one) and kept there.
    pub fn sender_tree(&self, record: &TransferRecord) -> Result<SenderTree> {
        let path = self.sender_tree_path(&record.transfer_id);
        if let Some(tree) = fs::read(&path).ok().and_then(|b| SenderTree::decode(&b)) {
            if tree.header.digest == record.digest && tree.header.geometry.size == record.size {
                self.index_sent_blocks(record, &tree);
                return Ok(tree);
            }
        }
        let geometry = Geometry::for_size(record.size).ok_or(StoreError::Invalid("too large for blocks"))?;
        let snapshot = record.staged_path.as_ref().ok_or(StoreError::FileMissing)?;
        let file = File::open(snapshot).map_err(|_| StoreError::FileMissing)?;
        if file.metadata()?.len() != record.size {
            return Err(StoreError::FileMissing);
        }
        let hashed = tree::hash_file(&file, &geometry, true)?;
        if hashed.digest != Some(record.digest) {
            return Err(StoreError::FileMissing);
        }
        let tree =
            SenderTree { header: Header { geometry, root: hashed.root, digest: record.digest }, leaves: hashed.leaves };
        // A cache: a write that fails only costs hashing again.
        write_tree_cache(&path, &tree);
        self.index_sent_blocks(record, &tree);
        Ok(tree)
    }

    /// A file this person sends a friend: its leaves and the file they chose, for blocks of a version that friend may
    /// send back (§ 9.5). Every block found there is checked against the new file's leaf before it counts, so a file
    /// edited since costs only a failed check.
    fn index_sent_blocks(&self, record: &TransferRecord, tree: &SenderTree) {
        if let Some(source) = &record.source_path {
            self.index_blocks(
                &record.conversation_id,
                &record.transfer_id,
                source,
                &tree.header.geometry,
                &tree.leaves,
            );
        }
    }

    /// Blocks of a download whose leaves an indexed file of the same friend holds at the same position: read there,
    /// and taken exactly as if they had arrived (checked against their leaves, written, reported in the next HAVE), so
    /// the sender skips them. Returns how many.
    fn reuse_blocks(&mut self, transfer_id: &str, conversation_id: &str) -> Result<u32> {
        let Some(download) = self.receiving.blocks.get(transfer_id) else { return Ok(0) };
        let Some(leaves) = download.assembly.leaves().map(<[_]>::to_vec) else { return Ok(0) };
        let geometry = *download.assembly.geometry();
        let complete = download.assembly.complete().clone();
        let found = self.reusable_blocks(conversation_id, &geometry, &leaves, |b| !complete.contains(b));
        let mut reused = 0;
        let mut open: Option<(PathBuf, File)> = None;
        for (block, path) in found {
            if open.as_ref().is_none_or(|(p, _)| *p != path) {
                open = File::open(&path).ok().map(|f| (path.clone(), f));
            }
            let Some((_, file)) = &open else { continue };
            let (offset, length) = geometry.span(block);
            let mut data = vec![0u8; length];
            if read_exact_at(file, &mut data, offset).is_err() {
                continue;
            }
            if let BlockPart::Written(_) = self.block_part(transfer_id, conversation_id, offset, &data)? {
                reused += 1;
            }
        }
        Ok(reused)
    }

    /// They took our offer by blocks (OFFER_REPLY with Blocks, or a WANT on a later session): Sending, without hashing
    /// the whole snapshot first, since every block is checked against its leaf as it is read (§ 4). Returns the record
    /// and whether this was the first acceptance (then every block is wanted, before any WANT).
    pub fn peer_took_blocks(&mut self, transfer_id: &str, conversation_id: &str) -> Result<(TransferRecord, bool)> {
        self.write(|conn| {
            let record = owned(conn, transfer_id, conversation_id, true)?;
            let first = match record.state {
                TransferState::Sending => false,
                state if TransferEvent::Accepted.next_state(true, state) == TransferState::Sending => true,
                _ => return Err(StoreError::Stale),
            };
            if record.staged_path.as_ref().is_none_or(|p| fs::metadata(p).map(|m| m.len()).ok() != Some(record.size)) {
                apply_event(conn, transfer_id, TransferEvent::Failed, Some(super::outbox::FAILURE_SOURCE_MISSING))?;
                return Err(StoreError::FileMissing);
            }
            if first {
                apply_event(conn, transfer_id, TransferEvent::Accepted, None)?;
            }
            Ok((load(conn, transfer_id)?.ok_or(StoreError::NotFound)?, first))
        })
    }

    /// Our snapshot no longer matches its tree: the transfer fails as a missing source does.
    pub fn snapshot_changed(&mut self, transfer_id: &str) -> Result<()> {
        self.write(|conn| {
            apply_event(conn, transfer_id, TransferEvent::Failed, Some(super::outbox::FAILURE_SOURCE_MISSING))
                .map(|_| ())
        })
    }

    /// Reads block `index` of an outgoing transfer's snapshot whole, for the sender to check against its leaf.
    pub fn read_outgoing_block(&self, record: &TransferRecord, geometry: &Geometry, index: u32) -> Result<Vec<u8>> {
        let path = record.staged_path.as_ref().ok_or(StoreError::FileMissing)?;
        let file = File::open(path).map_err(|_| StoreError::FileMissing)?;
        let (offset, length) = geometry.span(index);
        let mut buffer = vec![0u8; length];
        read_exact_at(&file, &mut buffer, offset).map_err(|_| StoreError::FileMissing)?;
        Ok(buffer)
    }

    /// Sidecars whose transfer still needs them; the recovery sweep keeps these and deletes the rest.
    pub(super) fn live_sidecars(&self) -> Result<Vec<PathBuf>> {
        let open = transfers::rows(
            &self.conn,
            "WHERE state IN (?1, ?2, ?3, ?4, ?5)",
            &[
                &(TransferState::Queued as i64),
                &(TransferState::Offered as i64),
                &(TransferState::WaitingForYou as i64),
                &(TransferState::Sending as i64),
                &(TransferState::Receiving as i64),
            ],
        )?;
        Ok(open
            .iter()
            .map(
                |r| {
                    if r.outgoing {
                        self.sender_tree_path(&r.transfer_id)
                    } else {
                        self.block_map_path(&r.transfer_id)
                    }
                },
            )
            .collect())
    }
}
