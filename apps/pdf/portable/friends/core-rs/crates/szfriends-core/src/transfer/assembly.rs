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

impl Partial {
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
        self.complete.missing_ranges()
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
        partial.data[start..start + data.len()].copy_from_slice(data);
        partial.cover(start, start + data.len());
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

    /// A complete block could not be written: wanted again.
    pub fn unwritten(&mut self, block: u32) {
        self.complete.remove(block);
    }

    /// Drops every partly received block: a group ended, and the next one sends them whole.
    pub fn drop_partial(&mut self) {
        self.partial.clear();
        self.partial_bytes = 0;
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
