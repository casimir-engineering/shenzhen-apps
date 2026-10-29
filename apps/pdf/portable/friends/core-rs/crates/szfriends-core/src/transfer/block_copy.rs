//! A copy by blocks that is not an offer (ADR 0018 § 4): Get again from a friend (AGAIN 4 and 5) and a file copied
//! from another of the person's computers (SYNC 7 and 8). The serving side announces its tree (BLOCKS FOLLOW), sends
//! the leaves (HASHES) and the blocks asked for (PART); this side checks each block against its leaf, writes it into
//! its staging file, keeps a map beside it so the next session asks only for what is missing (WANT BLOCKS), and before
//! the file counts checks the whole of it against the BLAKE2b digest it is known by: the leaves are only the serving
//! side's word, the digest is the file's identity.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use super::assembly::{BlockAssembly, PartOutcome};
use super::blockset::BlockSet;
use super::geometry::Geometry;
use super::sidecar::{BlockMap, Header};
use super::tree::{self, read_exact_at, write_all_at, Leaf};

/// A copy's staging file and the map beside it go together: the source said the file is gone, or it did not check.
pub fn remove_copy(partial: &Path) {
    let _ = std::fs::remove_file(partial);
    let _ = std::fs::remove_file(map_of(partial));
}

/// `<partial>.map`, where a copy keeps what arrived.
pub fn map_of(partial: &Path) -> PathBuf {
    let mut name = partial.as_os_str().to_owned();
    name.push(".map");
    PathBuf::from(name)
}

/// Copies kept across restarts are given up after this long without a byte arriving.
pub const COPY_KEEP_SECONDS: u64 = 30 * 24 * 3600;

/// Whether a file in `received/.partial/` belongs to a copy that is not an offer (`again-<id>`, `sync-<id>`, and
/// their maps): the recovery sweep keeps these until [`COPY_KEEP_SECONDS`] passed without a change.
pub fn is_copy_file(name: &str) -> bool {
    let stem = name.strip_suffix(".map").unwrap_or(name);
    let id = stem.strip_prefix("again-").or_else(|| stem.strip_prefix("sync-"));
    id.is_some_and(|id| !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
}

/// Blocks made durable together.
const BATCH_BYTES: u64 = 8 << 20;

/// What one PART did to a copy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopyPart {
    Pending,
    /// A block checked and written: reported in the next HAVE.
    Written(u32),
    /// A block that did not match its leaf: wanted again, alone.
    Corrupt(u32),
    /// Every block is here and durable: [`BlockCopy::finish`].
    Complete,
    Late,
    /// Out of place, or before BLOCKS FOLLOW and the leaves: the serving side is not doing what was asked.
    Refused,
}

#[derive(Debug)]
pub struct BlockCopy {
    size: u64,
    digest: [u8; 32],
    partial: PathBuf,
    map_path: PathBuf,
    file: File,
    header: Option<Header>,
    assembly: Option<BlockAssembly>,
    map: Option<File>,
    durable: BlockSet,
    unsynced: Vec<u32>,
    unsynced_bytes: u64,
    unreported: Vec<u32>,
}

fn open_rw(path: &Path, create: bool) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(create);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// Blocks of `claimed` whose bytes in `file` match their leaves.
fn recheck(file: &File, geometry: &Geometry, leaves: &[Leaf], claimed: impl Iterator<Item = u32>) -> BlockSet {
    let mut intact = BlockSet::new(geometry.blocks);
    for block in claimed {
        let (offset, length) = geometry.span(block);
        let mut buffer = vec![0u8; length];
        if read_exact_at(file, &mut buffer, offset).is_ok() && tree::leaf(block, &buffer) == leaves[block as usize] {
            intact.insert(block);
        }
    }
    intact
}

impl BlockCopy {
    /// Opens the staging file (made when missing) and the map beside it, if one from an earlier session is there.
    pub fn open(size: u64, digest: [u8; 32], partial: PathBuf, map_path: PathBuf) -> io::Result<Self> {
        let file = open_rw(&partial, true)?;
        let mut copy = Self {
            size,
            digest,
            partial,
            map_path,
            file,
            header: None,
            assembly: None,
            map: None,
            durable: BlockSet::new(0),
            unsynced: Vec::new(),
            unsynced_bytes: 0,
            unreported: Vec::new(),
        };
        let map = std::fs::read(&copy.map_path).ok().and_then(|b| BlockMap::decode(&b));
        match map.filter(|m| m.header.geometry.size == size && m.header.digest == digest) {
            Some(map) => copy.adopt_map(map)?,
            None => {
                let _ = std::fs::remove_file(&copy.map_path);
            }
        }
        Ok(copy)
    }

    fn adopt_map(&mut self, map: BlockMap) -> io::Result<()> {
        let geometry = map.header.geometry;
        self.header = Some(map.header);
        self.durable = BlockSet::new(geometry.blocks);
        let Some(leaves) = map.leaves else {
            self.assembly = Some(BlockAssembly::new(geometry, map.header.root));
            return Ok(());
        };
        if self.file.metadata()?.len() < self.size {
            self.file.set_len(self.size)?;
        }
        // The map may run ahead of the disk after an unclean exit: what it claims counts once it checks.
        let intact = recheck(&self.file, &geometry, &leaves, map.durable.iter());
        self.assembly = BlockAssembly::resumed(geometry, map.header.root, leaves, intact.clone());
        self.durable = intact;
        self.map = Some(open_rw(&self.map_path, false)?);
        Ok(())
    }

    /// The shift to ask with: the announced tree's, else this build's for the size.
    pub fn shift(&self) -> u8 {
        self.header.map_or_else(|| Geometry::for_size(self.size).map_or(20, |g| g.shift), |h| h.geometry.shift)
    }

    /// What to ask for: every block not yet here (all of them before a tree was announced).
    pub fn missing(&self) -> Vec<(u32, u32)> {
        match &self.assembly {
            Some(assembly) if assembly.leaves().is_some() => assembly.missing_ranges(),
            _ => {
                let blocks = Geometry::new(self.size, self.shift()).map_or(1, |g| g.blocks);
                vec![(0, blocks)]
            }
        }
    }

    /// BLOCKS FOLLOW: the serving side's tree. The same tree as before keeps what arrived; another starts over.
    pub fn follow(&mut self, root: Leaf, shift: u8) -> bool {
        let Some(geometry) = Geometry::new(self.size, shift) else { return false };
        if self.header.is_some_and(|h| h.root == root && h.geometry == geometry) {
            return true;
        }
        let header = Header { geometry, root, digest: self.digest };
        let prefix = self.file.metadata().map_or(0, |m| m.len()).min(self.size);
        self.header = Some(header);
        self.assembly = Some(BlockAssembly::new(geometry, root));
        self.durable = BlockSet::new(geometry.blocks);
        self.map = None;
        let _ = std::fs::remove_file(&self.map_path);
        // A prefix an earlier copy by offset left: its whole blocks count once the leaves arrive and they check.
        self.unsynced_bytes = prefix;
        true
    }

    /// Leaves from HASHES: `Some(true)` once all are here, `None` for leaves that do not hash to the announced root.
    pub fn hashes(&mut self, index: u32, hashes: &[u8]) -> Option<bool> {
        let assembly = self.assembly.as_mut()?;
        let done = assembly.accept_hashes(index, hashes).ok()?;
        if !done || self.map.is_some() {
            return Some(done);
        }
        let header = self.header.expect("followed");
        let geometry = header.geometry;
        let leaves = assembly.leaves().expect("checked").to_vec();
        let prefix = std::mem::take(&mut self.unsynced_bytes);
        let whole = if prefix >= geometry.size { geometry.blocks } else { (prefix >> geometry.shift) as u32 };
        let intact = recheck(&self.file, &geometry, &leaves, 0..whole);
        self.assembly = BlockAssembly::resumed(geometry, header.root, leaves.clone(), intact.clone());
        let _ = self.file.set_len(self.size);
        self.durable = intact.clone();
        self.unreported.extend(intact.iter());
        let mut map = BlockMap::new(header);
        map.leaves = Some(leaves);
        map.durable = intact;
        let mut file = open_rw(&self.map_path, true).ok()?;
        file.set_len(0).and_then(|()| file.write_all(&map.encode())).ok()?;
        self.map = Some(file);
        Some(true)
    }

    /// One PART at `offset`.
    pub fn part(&mut self, offset: u64, data: &[u8]) -> CopyPart {
        let Some(assembly) = self.assembly.as_mut() else { return CopyPart::Refused };
        match assembly.accept_part(offset, data) {
            Err(_) => CopyPart::Refused,
            Ok(PartOutcome::Pending) => CopyPart::Pending,
            Ok(PartOutcome::Late) => CopyPart::Late,
            Ok(PartOutcome::Corrupt { block }) => CopyPart::Corrupt(block),
            Ok(PartOutcome::Complete { block, data }) => {
                let (at, _) = assembly.geometry().span(block);
                if write_all_at(&self.file, &data, at).is_err() {
                    assembly.unwritten(block);
                    return CopyPart::Refused;
                }
                self.unsynced.push(block);
                self.unsynced_bytes += data.len() as u64;
                self.unreported.push(block);
                let complete = assembly.is_complete();
                if (complete || self.unsynced_bytes >= BATCH_BYTES) && self.flush().is_err() {
                    return CopyPart::Refused;
                }
                if complete {
                    CopyPart::Complete
                } else {
                    CopyPart::Written(block)
                }
            }
        }
    }

    /// Blocks written and not yet in a HAVE.
    pub fn unreported_count(&self) -> usize {
        self.unreported.len()
    }

    /// Bytes of the blocks here, for the item's progress.
    pub fn received_bytes(&self) -> u64 {
        let Some(assembly) = &self.assembly else { return 0 };
        let geometry = assembly.geometry();
        assembly.complete().iter().map(|b| geometry.span(b).1 as u64).sum()
    }

    /// Blocks written since the last HAVE.
    pub fn take_have(&mut self) -> Vec<(u32, u32)> {
        let mut blocks = std::mem::take(&mut self.unreported);
        blocks.sort_unstable();
        blocks.dedup();
        let mut set = BlockSet::new(self.assembly.as_ref().map_or(0, |a| a.geometry().blocks));
        blocks.into_iter().for_each(|b| {
            set.insert(b);
        });
        set.ranges()
    }

    /// Whether every block arrived (an empty file is complete once its leaf checks).
    pub fn is_complete(&self) -> bool {
        self.assembly.as_ref().is_some_and(BlockAssembly::is_complete)
    }

    /// A durability batch: the blocks, then the map's bitmap, both flushed.
    pub fn flush(&mut self) -> io::Result<()> {
        let Some(map) = self.map.as_ref() else { return Ok(()) };
        if self.unsynced.is_empty() {
            return Ok(());
        }
        self.file.sync_data()?;
        for block in self.unsynced.drain(..) {
            self.durable.insert(block);
        }
        self.unsynced_bytes = 0;
        let blocks = self.durable.len() as usize;
        write_all_at(map, &self.durable.to_bitmap(), (super::sidecar::HEADER_BYTES + 32 * blocks) as u64)?;
        map.sync_all()
    }

    /// The whole file read back: `Some(path)` when its tree is the announced one and its digest the known one (the
    /// map goes; the caller takes the file from there), `None` when it is not (the copy is deleted).
    pub fn finish(mut self) -> Option<PathBuf> {
        let _ = self.flush();
        let header = self.header?;
        let hashed = tree::hash_file(&self.file, &header.geometry, true).ok();
        let _ = std::fs::remove_file(&self.map_path);
        let good = hashed.is_some_and(|h| h.root == header.root && h.digest == Some(self.digest))
            && self.file.metadata().is_ok_and(|m| m.len() == self.size);
        drop(self.file);
        if good {
            Some(self.partial)
        } else {
            let _ = std::fs::remove_file(&self.partial);
            None
        }
    }

    /// Stops without deleting: what arrived waits for the next copy.
    pub fn pause(mut self) {
        let _ = self.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_copy_by_blocks_resumes_from_its_map_and_checks_the_digest() {
        let dir = std::env::temp_dir().join(format!("szf-copy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let data: Vec<u8> = (0..3 * (1 << 20) + 9).map(|i: usize| (i % 249) as u8).collect();
        let digest = {
            use blake2::digest::{Update, VariableOutput};
            let mut h = blake2::Blake2bVar::new(32).unwrap();
            h.update(&data);
            let mut out = [0u8; 32];
            h.finalize_variable(&mut out).unwrap();
            out
        };
        let geometry = Geometry::for_size(data.len() as u64).unwrap();
        let leaves: Vec<Leaf> = (0..geometry.blocks)
            .map(|i| {
                let (o, l) = geometry.span(i);
                tree::leaf(i, &data[o as usize..o as usize + l])
            })
            .collect();
        let root = tree::root_of(&geometry, &leaves).unwrap();
        let (partial, map) = (dir.join("again-x"), dir.join("again-x.map"));
        let mut copy = BlockCopy::open(data.len() as u64, digest, partial.clone(), map.clone()).unwrap();
        assert_eq!(copy.missing(), vec![(0, 4)]);
        assert_eq!(copy.part(0, &data[..10]), CopyPart::Refused, "nothing before the tree");
        assert!(copy.follow(root, geometry.shift));
        assert_eq!(copy.hashes(0, &leaves.concat()), Some(true));
        assert_eq!(copy.part(1 << 20, &data[1 << 20..2 << 20]), CopyPart::Written(1));
        copy.pause();
        // A later session: block 1 is here, the rest is asked for.
        let mut copy = BlockCopy::open(data.len() as u64, digest, partial.clone(), map.clone()).unwrap();
        assert_eq!(copy.missing(), vec![(0, 1), (2, 2)]);
        assert!(copy.follow(root, geometry.shift), "the same tree keeps what arrived");
        for block in [0, 2, 3] {
            let (o, l) = geometry.span(block);
            let _ = copy.part(o, &data[o as usize..o as usize + l]);
        }
        assert!(copy.is_complete());
        let path = copy.finish().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), data);
        assert!(!map.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
