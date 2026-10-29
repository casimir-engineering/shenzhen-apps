//! The receiver's side of a fast transfer (ADR 0018 § 2 to 4), sans-IO: the leaves from HASHES, checked against the
//! offered root before a single part is taken; parts gathered into their block in memory; each block checked against
//! its leaf the moment it is complete. A block that fails is dropped and wanted again, alone. What a peer can make it
//! hold is bounded: at most 64 blocks and 64 MiB partly received at once, nothing before the leaves.

use std::collections::BTreeMap;

use szfriends_wire::consts::{BLOCKS_IN_FLIGHT_MAX, BYTES_IN_FLIGHT_MAX};

use super::blockset::BlockSet;
use super::geometry::Geometry;
use super::tree::{self, Leaf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssemblyError {
    /// A part before the leaves were complete and checked.
    NoLeaves,
    /// HASHES out of order, past the block count, or not hashing to the offered root.
    BadHashes,
    /// Leaves sent again that differ from the ones already checked.
    LeavesDiffer,
    /// A part outside the file or across a block boundary.
    OutOfPlace,
    /// More blocks or bytes partly received at once than § 3 allows.
    TooManyInFlight,
}

/// What a part did.
#[derive(Debug, PartialEq, Eq)]
pub enum PartOutcome {
    /// Stored; the block is still missing bytes.
    Pending,
    /// The block is complete and matches its leaf: write it, then [`BlockAssembly::written`].
    Complete { block: u32, data: Vec<u8> },
    /// The block is complete and does not match its leaf: dropped, to be wanted again.
    Corrupt { block: u32 },
    /// A part for a block already complete (sent on two lanes, or before a WANT caught up): ignored.
    Late,
}

#[derive(Debug)]
struct Partial {
    data: Vec<u8>,
    /// Received byte intervals `[start, end)` within the block, sorted and merged.
    covered: Vec<(usize, usize)>,
}

/// A piece's bytes (ADR 0018 § 3).
const PIECE: usize = 1 << szfriends_wire::consts::PIECE_SHIFT;

impl Partial {
    /// Whether `[start, end)` lies inside one received interval.
    fn has(&self, start: usize, end: usize) -> bool {
        self.covered.iter().any(|&(s, e)| s <= start && end <= e)
    }

    fn filled(&self) -> usize {
        self.covered.iter().map(|(start, end)| end - start).sum()
    }

    fn cover(&mut self, start: usize, end: usize) {
        self.covered.push((start, end));
        self.covered.sort_unstable();
        let mut merged: Vec<(usize, usize)> = Vec::with_capacity(self.covered.len());
        for &(s, e) in &self.covered {
            match merged.last_mut() {
                Some(last) if s <= last.1 => last.1 = last.1.max(e),
                _ => merged.push((s, e)),
            }
        }
        self.covered = merged;
    }
}

#[derive(Debug)]
pub struct BlockAssembly {
    geometry: Geometry,
    root: Leaf,
    leaves: Vec<Leaf>,
    leaves_checked: bool,
    /// Checked and handed out for writing (or found durable at a restart).
    complete: BlockSet,
    partial: BTreeMap<u32, Partial>,
    partial_bytes: u64,
    /// Pieces that arrived in blocks not yet complete and that no HAVE reported yet (§ 3).
    arrived: Vec<u32>,
}

impl BlockAssembly {
    pub fn new(geometry: Geometry, root: Leaf) -> Self {
        let complete = BlockSet::new(geometry.blocks);
        Self {
            geometry,
            root,
            leaves: Vec::new(),
            leaves_checked: false,
            complete,
            partial: BTreeMap::new(),
            partial_bytes: 0,
            arrived: Vec::new(),
        }
    }

    /// Resuming from a map whose leaves were checked: `complete` are the blocks re-read and found intact.
    pub fn resumed(geometry: Geometry, root: Leaf, leaves: Vec<Leaf>, complete: BlockSet) -> Option<Self> {
        if tree::root_of(&geometry, &leaves) != Some(root) || complete.len() != geometry.blocks {
            return None;
        }
        let mut assembly = Self::new(geometry, root);
        assembly.leaves = leaves;
        assembly.leaves_checked = true;
        assembly.complete = complete;
        Some(assembly)
    }

    pub fn geometry(&self) -> &Geometry {
        &self.geometry
    }

    pub fn root(&self) -> &Leaf {
        &self.root
    }

    pub fn leaves(&self) -> Option<&[Leaf]> {
        self.leaves_checked.then_some(self.leaves.as_slice())
    }

    pub fn complete(&self) -> &BlockSet {
        &self.complete
    }

    pub fn is_complete(&self) -> bool {
        self.complete.is_full()
    }

    /// What to WANT: every block not complete.
    pub fn missing_ranges(&self) -> Vec<(u32, u32)> {
        let mut wanted = self.complete.clone();
        for &block in self.partial.keys() {
            wanted.insert(block);
        }
        wanted.missing_ranges()
    }

    /// What to WANT besides: in blocks partly received, the pieces still missing (§ 3), as piece ranges.
    pub fn missing_pieces(&self) -> Vec<(u32, u32)> {
        let mut pieces = Vec::new();
        for (&block, partial) in &self.partial {
            let (offset, length) = self.geometry.span(block);
            let first = (offset >> szfriends_wire::consts::PIECE_SHIFT) as u32;
            for (n, start) in (0..length).step_by(PIECE).enumerate() {
                if !partial.has(start, (start + PIECE).min(length)) {
                    pieces.push(first + n as u32);
                }
            }
        }
        to_ranges(&pieces)
    }

    /// Pieces arrived since the last call, in blocks still incomplete, as piece ranges (HAVE's Pieces).
    pub fn take_arrived_pieces(&mut self) -> Vec<(u32, u32)> {
        let shift = self.geometry.shift - szfriends_wire::consts::PIECE_SHIFT;
        let mut pieces = std::mem::take(&mut self.arrived);
        pieces.retain(|p| !self.complete.contains(p >> shift));
        pieces.sort_unstable();
        pieces.dedup();
        to_ranges(&pieces)
    }

    /// Leaves from one HASHES frame. They arrive in order from 0; a new group may start them again from 0. `true`
    /// once all are here and hash to the root (an empty file's one block is then complete, if its leaf matches).
    pub fn accept_hashes(&mut self, index: u32, hashes: &[u8]) -> Result<bool, AssemblyError> {
        if hashes.is_empty() || hashes.len() % 32 != 0 {
            return Err(AssemblyError::BadHashes);
        }
        let given: Vec<Leaf> = hashes.chunks_exact(32).map(|c| c.try_into().expect("32")).collect();
        let end = u64::from(index) + given.len() as u64;
        if end > u64::from(self.geometry.blocks) {
            return Err(AssemblyError::BadHashes);
        }
        if self.leaves_checked {
            return if self.leaves[index as usize..end as usize] == given[..] {
                Ok(false)
            } else {
                Err(AssemblyError::LeavesDiffer)
            };
        }
        if index == 0 {
            self.leaves.clear();
        }
        if index as usize != self.leaves.len() {
            return Err(AssemblyError::BadHashes);
        }
        self.leaves.extend(given);
        if self.leaves.len() < self.geometry.blocks as usize {
            return Ok(false);
        }
        if tree::root_of(&self.geometry, &self.leaves) != Some(self.root) {
            self.leaves.clear();
            return Err(AssemblyError::BadHashes);
        }
        self.leaves_checked = true;
        if self.geometry.size == 0 && self.leaves[0] == tree::leaf(0, &[]) {
            self.complete.insert(0);
        }
        Ok(true)
    }

    /// One PART's data at `offset` in the file.
    pub fn accept_part(&mut self, offset: u64, data: &[u8]) -> Result<PartOutcome, AssemblyError> {
        if !self.leaves_checked {
            return Err(AssemblyError::NoLeaves);
        }
        let end = offset.checked_add(data.len() as u64).ok_or(AssemblyError::OutOfPlace)?;
        if data.is_empty() || end > self.geometry.size {
            return Err(AssemblyError::OutOfPlace);
        }
        let block = self.geometry.block_of(offset);
        if self.geometry.block_of(end - 1) != block {
            return Err(AssemblyError::OutOfPlace);
        }
        if self.complete.contains(block) {
            return Ok(PartOutcome::Late);
        }
        let (block_offset, block_length) = self.geometry.span(block);
        if !self.partial.contains_key(&block) {
            if self.partial.len() >= BLOCKS_IN_FLIGHT_MAX
                || self.partial_bytes + block_length as u64 > BYTES_IN_FLIGHT_MAX
            {
                return Err(AssemblyError::TooManyInFlight);
            }
            self.partial.insert(block, Partial { data: vec![0; block_length], covered: Vec::new() });
            self.partial_bytes += block_length as u64;
        }
        let partial = self.partial.get_mut(&block).expect("inserted");
        let start = (offset - block_offset) as usize;
        let end = start + data.len();
        let fresh: Vec<usize> = (start / PIECE * PIECE..end)
            .step_by(PIECE)
            .filter(|&p| !partial.has(p, (p + PIECE).min(block_length)))
            .collect();
        partial.data[start..end].copy_from_slice(data);
        partial.cover(start, end);
        let first = (block_offset >> szfriends_wire::consts::PIECE_SHIFT) as u32;
        for p in fresh {
            if partial.has(p, (p + PIECE).min(block_length)) {
                self.arrived.push(first + (p / PIECE) as u32);
            }
        }
        if partial.filled() < block_length {
            return Ok(PartOutcome::Pending);
        }
        let partial = self.partial.remove(&block).expect("present");
        self.partial_bytes -= block_length as u64;
        if tree::leaf(block, &partial.data) != self.leaves[block as usize] {
            return Ok(PartOutcome::Corrupt { block });
        }
        self.complete.insert(block);
        Ok(PartOutcome::Complete { block, data: partial.data })
    }

    /// A block taken from elsewhere (an earlier version of the file) whose bytes matched its leaf: complete. `true`
    /// when it was not complete before.
    pub fn mark_complete(&mut self, block: u32) -> bool {
        if let Some(partial) = self.partial.remove(&block) {
            self.partial_bytes -= partial.data.len() as u64;
        }
        self.complete.insert(block)
    }

    /// A complete block could not be written: wanted again.
    pub fn unwritten(&mut self, block: u32) {
        self.complete.remove(block);
    }

    /// Drops every partly received block: a group ended, and the next one sends them whole.
    pub fn drop_partial(&mut self) {
        self.partial.clear();
        self.partial_bytes = 0;
        self.arrived.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(size: usize) -> (Geometry, Vec<u8>, Vec<Leaf>, Leaf) {
        let bytes: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
        let geometry = Geometry::for_size(size as u64).unwrap();
        let leaves: Vec<Leaf> = (0..geometry.blocks)
            .map(|i| {
                let (o, l) = geometry.span(i);
                tree::leaf(i, &bytes[o as usize..o as usize + l])
            })
            .collect();
        let root = tree::root_of(&geometry, &leaves).unwrap();
        (geometry, bytes, leaves, root)
    }

    #[test]
    fn pieces_that_arrived_and_pieces_still_missing() {
        let (geometry, bytes, leaves, root) = file(3 * (1 << 20));
        let mut assembly = BlockAssembly::new(geometry, root);
        assembly.accept_hashes(0, &leaves.concat()).unwrap();
        let piece = 16_384;
        // Block 1: pieces 64 and 65 whole, 66 half; a part across pieces 69 and 70 completes neither.
        let at = 1 << 20;
        assert_eq!(
            assembly.accept_part(at, &bytes[at as usize..at as usize + 2 * piece + 100]),
            Ok(PartOutcome::Pending)
        );
        let odd = at as usize + 5 * piece + 10;
        assert_eq!(assembly.accept_part(odd as u64, &bytes[odd..odd + piece]), Ok(PartOutcome::Pending));
        assert_eq!(assembly.take_arrived_pieces(), vec![(64, 2)]);
        assert!(assembly.take_arrived_pieces().is_empty(), "reported once");
        // The rest of piece 66 arrives.
        let rest = at as usize + 2 * piece + 100;
        assembly.accept_part(rest as u64, &bytes[rest..at as usize + 3 * piece]).unwrap();
        assert_eq!(assembly.take_arrived_pieces(), vec![(66, 1)]);
        // WANT: blocks 0 and 2 whole, and in block 1 everything but pieces 64 to 66.
        assert_eq!(assembly.missing_ranges(), vec![(0, 1), (2, 1)]);
        assert_eq!(assembly.missing_pieces(), vec![(67, 61)]);
        // Completing block 1 out of order: no pieces left to report for it.
        let tail = at as usize + 3 * piece;
        assert!(matches!(assembly.accept_part(tail as u64, &bytes[tail..tail + 60_000]), Ok(PartOutcome::Pending)));
        let mut offset = tail + 60_000;
        while offset < 2 << 20 {
            let end = (offset + 60_000).min(2 << 20);
            let outcome = assembly.accept_part(offset as u64, &bytes[offset..end]).unwrap();
            offset = end;
            if offset == 2 << 20 {
                assert!(matches!(outcome, PartOutcome::Complete { block: 1, .. }));
            }
        }
        assert!(assembly.take_arrived_pieces().is_empty());
        assert!(assembly.missing_pieces().is_empty());
    }

    #[test]
    fn blocks_complete_out_of_order_and_a_corrupt_one_is_dropped() {
        let (geometry, bytes, leaves, root) = file(2 * (1 << 20) + 5);
        let mut assembly = BlockAssembly::new(geometry, root);
        assert_eq!(assembly.accept_part(0, &bytes[..10]), Err(AssemblyError::NoLeaves));
        let flat: Vec<u8> = leaves.concat();
        assert_eq!(assembly.accept_hashes(1, &flat[32..]), Err(AssemblyError::BadHashes), "out of order");
        assert_eq!(assembly.accept_hashes(0, &flat[..32]), Ok(false));
        assert_eq!(assembly.accept_hashes(1, &flat[32..]), Ok(true));
        assert_eq!(assembly.accept_hashes(0, &flat), Ok(false), "sent again, the same");
        // The last block first, then block 0 in two overlapping parts.
        let last = 2 << 20;
        assert!(matches!(
            assembly.accept_part(last, &bytes[last as usize..]),
            Ok(PartOutcome::Complete { block: 2, .. })
        ));
        assert_eq!(assembly.accept_part(last, &bytes[last as usize..]), Ok(PartOutcome::Late));
        assert_eq!(assembly.accept_part(0, &bytes[..600_000]), Ok(PartOutcome::Pending));
        assert!(matches!(
            assembly.accept_part(500_000, &bytes[500_000..1 << 20]),
            Ok(PartOutcome::Complete { block: 0, .. })
        ));
        // Block 1 with one byte changed.
        let mut bad = bytes[1 << 20..2 << 20].to_vec();
        bad[17] ^= 1;
        assert_eq!(assembly.accept_part(1 << 20, &bad), Ok(PartOutcome::Corrupt { block: 1 }));
        assert_eq!(assembly.missing_ranges(), vec![(1, 1)]);
        assert_eq!(
            assembly.accept_part((1 << 20) - 1, &bytes[(1 << 20) - 1..(1 << 20) + 1]),
            Err(AssemblyError::OutOfPlace)
        );
        assert_eq!(assembly.accept_part(last, &bytes[last as usize..]).ok(), Some(PartOutcome::Late));
        assert!(matches!(
            assembly.accept_part(1 << 20, &bytes[1 << 20..2 << 20]),
            Ok(PartOutcome::Complete { block: 1, .. })
        ));
        assert!(assembly.is_complete());
    }

    #[test]
    fn leaves_that_miss_the_root_and_too_many_partial_blocks_are_refused() {
        let (geometry, bytes, leaves, root) = file(70 * (1 << 20));
        let mut wrong = leaves.concat();
        wrong[0] ^= 1;
        let mut assembly = BlockAssembly::new(geometry, root);
        assert_eq!(assembly.accept_hashes(0, &wrong), Err(AssemblyError::BadHashes));
        assert_eq!(assembly.accept_hashes(0, &leaves.concat()), Ok(true));
        for block in 0..64u64 {
            assert_eq!(assembly.accept_part(block << 20, &bytes[..1]), Ok(PartOutcome::Pending));
        }
        assert_eq!(assembly.accept_part(64 << 20, &bytes[..1]), Err(AssemblyError::TooManyInFlight));
        assembly.drop_partial();
        assert_eq!(assembly.accept_part(64 << 20, &bytes[..1]), Ok(PartOutcome::Pending));
    }

    #[test]
    fn an_empty_file_completes_with_its_leaves() {
        let (geometry, _, leaves, root) = file(0);
        let mut assembly = BlockAssembly::new(geometry, root);
        assert_eq!(assembly.accept_hashes(0, &leaves.concat()), Ok(true));
        assert!(assembly.is_complete());
    }
}

/// Sorted indexes to `(first, count)` ranges.
fn to_ranges(sorted: &[u32]) -> Vec<(u32, u32)> {
    let mut out: Vec<(u32, u32)> = Vec::new();
    for &i in sorted {
        match out.last_mut() {
            Some((first, count)) if *first + *count == i => *count += 1,
            _ => out.push((i, 1)),
        }
    }
    out
}
