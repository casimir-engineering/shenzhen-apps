//! The sender's side of pieces (ADR 0018 § 3, § 7): the scheduler works in 256 KiB **slices**, a block's quarter, so
//! a slow lane takes 1.5 s of Bluetooth at a time; pieces (16 KiB) the receiver acknowledged in HAVE are never sent
//! again, so a lost lane or route costs what was in flight. Blocks stay what is read and checked against its leaf;
//! a few checked blocks are kept while their slices go out on several lanes.

use std::collections::{BTreeSet, HashMap, VecDeque};

use szfriends_wire::consts::{PART_BYTES_MAX, PIECE_SHIFT};
use szfriends_wire::Frame;

use super::frames;
use super::geometry::Geometry;

/// 2^18 = 256 KiB.
pub const SLICE_SHIFT: u8 = 18;
/// Checked blocks kept for their slices still to send.
const CACHED_BLOCKS: usize = 16;

/// The scheduler's geometry for a file: its units of 2^`unit` bytes (slices, or whole blocks for a peer without
/// pieces, which acknowledges whole blocks only).
pub fn unit_geometry(blocks: &Geometry, unit: u8) -> Geometry {
    let size = blocks.size;
    Geometry { size, shift: unit, blocks: size.div_ceil(1 << unit).max(1) as u32 }
}

/// Unit ranges at `from_shift` as ranges of the units at `to_shift` that hold them (`to_shift` the larger: pieces or
/// slices to the slices or blocks holding them) or that they hold (`to_shift` the smaller), within `units` of those.
fn convert(ranges: &[(u32, u32)], from_shift: u8, to_shift: u8, units: u32) -> Vec<(u32, u32)> {
    let mut out: Vec<(u32, u32)> = Vec::new();
    for &(first, count) in ranges {
        let (start, end) = if to_shift >= from_shift {
            let d = to_shift - from_shift;
            (first >> d, (first + count).div_ceil(1 << d))
        } else {
            let d = from_shift - to_shift;
            (first << d, ((first + count) << d).min(units))
        };
        let end = end.min(units);
        if start >= end {
            continue;
        }
        match out.last_mut() {
            Some((f, c)) if *f + *c >= start => *c = (*c).max(end - *f),
            _ => out.push((start, end - start)),
        }
    }
    out
}

/// What one file's sender knows of pieces, and the checked blocks its slices are cut from.
#[derive(Debug)]
pub struct SliceSend {
    /// The scheduler's unit: [`SLICE_SHIFT`] with a peer that has pieces, the block's shift otherwise.
    unit: u8,
    acked: BTreeSet<u32>,
    cache: HashMap<u32, Vec<u8>>,
    order: VecDeque<u32>,
}

impl SliceSend {
    /// Slices when the peer has pieces (it acknowledges them), whole blocks otherwise.
    pub fn new(blocks: &Geometry, pieces: bool) -> Self {
        let unit = if pieces { SLICE_SHIFT.min(blocks.shift) } else { blocks.shift };
        Self { unit, acked: BTreeSet::new(), cache: HashMap::new(), order: VecDeque::new() }
    }

    /// The scheduler's geometry for this file.
    pub fn units(&self, blocks: &Geometry) -> Geometry {
        unit_geometry(blocks, self.unit)
    }

    /// The units of these blocks (a WANT's or a HAVE's Ranges), for the scheduler.
    pub fn units_of_blocks(&self, blocks: &Geometry, ranges: &[(u32, u32)]) -> Vec<(u32, u32)> {
        convert(ranges, blocks.shift, self.unit, self.units(blocks).blocks)
    }

    /// The units holding these pieces.
    pub fn units_of_pieces(&self, blocks: &Geometry, pieces: &[(u32, u32)]) -> Vec<(u32, u32)> {
        convert(pieces, PIECE_SHIFT, self.unit, self.units(blocks).blocks)
    }

    /// The block holding a unit.
    pub fn block_of_unit(&self, blocks: &Geometry, unit: u32) -> u32 {
        unit >> (blocks.shift - self.unit)
    }

    fn pieces_of_slice(&self, blocks: &Geometry, slice: u32) -> std::ops::Range<u32> {
        let per = 1u32 << (self.unit - PIECE_SHIFT);
        let all = blocks.size.div_ceil(1 << PIECE_SHIFT).max(1) as u32;
        (slice * per).min(all)..((slice + 1) * per).min(all)
    }

    /// HAVE's Pieces: acknowledged; returns the slices now wholly acknowledged, for the scheduler.
    pub fn have_pieces(&mut self, blocks: &Geometry, pieces: &[(u32, u32)]) -> Vec<(u32, u32)> {
        for &(first, count) in pieces {
            self.acked.extend(first..first + count);
        }
        let mut done = Vec::new();
        for (first, count) in self.units_of_pieces(blocks, pieces) {
            for slice in first..first + count {
                if self.pieces_of_slice(blocks, slice).all(|p| self.acked.contains(&p)) {
                    done.push(slice);
                }
            }
        }
        to_ranges(&done)
    }

    /// HAVE's Ranges: these blocks are complete; their pieces and cached data are no longer needed.
    pub fn have_blocks(&mut self, blocks: &Geometry, ranges: &[(u32, u32)]) {
        for (first, count) in convert(ranges, blocks.shift, PIECE_SHIFT, u32::MAX) {
            let gone: Vec<u32> = self.acked.range(first..first + count).copied().collect();
            for p in gone {
                self.acked.remove(&p);
            }
        }
        for &(first, count) in ranges {
            for block in first..first + count {
                self.cache.remove(&block);
            }
        }
    }

    /// WANT: these blocks (Ranges) are wanted whole, these pieces (Pieces) again.
    pub fn want(&mut self, blocks: &Geometry, ranges: &[(u32, u32)], pieces: &[(u32, u32)]) {
        let whole = convert(ranges, blocks.shift, PIECE_SHIFT, u32::MAX);
        for &(first, count) in whole.iter().chain(pieces) {
            let wanted: Vec<u32> = self.acked.range(first..first + count).copied().collect();
            for p in wanted {
                self.acked.remove(&p);
            }
        }
    }

    pub fn cached(&self, block: u32) -> Option<&[u8]> {
        self.cache.get(&block).map(Vec::as_slice)
    }

    /// A block read and checked against its leaf, kept for its other slices.
    pub fn keep(&mut self, block: u32, data: Vec<u8>) {
        if self.cache.insert(block, data).is_none() {
            self.order.push_back(block);
        }
        while self.order.len() > CACHED_BLOCKS {
            if let Some(old) = self.order.pop_front() {
                self.cache.remove(&old);
            }
        }
        self.order.retain(|b| self.cache.contains_key(b));
    }

    /// The PARTs of unit `slice` not yet acknowledged, cut at `part_bytes`, from its block's checked data (the block
    /// that [`SliceSend::block_of_unit`] names, as [`SliceSend::cached`] holds it).
    pub fn parts(&self, id: &[u8], blocks: &Geometry, slice: u32, part_bytes: usize) -> Vec<Frame> {
        let block = self.block_of_unit(blocks, slice);
        let Some(data) = self.cache.get(&block) else { return Vec::new() };
        let (block_offset, _) = blocks.span(block);
        let piece = 1u64 << PIECE_SHIFT;
        let mut runs: Vec<(u64, u64)> = Vec::new();
        for p in self.pieces_of_slice(blocks, slice).filter(|p| !self.acked.contains(p)) {
            let (start, end) = (u64::from(p) * piece, ((u64::from(p) + 1) * piece).min(blocks.size));
            match runs.last_mut() {
                Some(run) if run.1 == start => run.1 = end,
                _ => runs.push((start, end)),
            }
        }
        let mut out = Vec::new();
        for (start, end) in runs {
            let mut at = start;
            while at < end {
                let next = (at + part_bytes.clamp(1, PART_BYTES_MAX) as u64).min(end);
                let (from, to) = ((at - block_offset) as usize, (next - block_offset) as usize);
                out.push(frames::part(id, at, &data[from..to]));
                at = next;
            }
        }
        out
    }
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use szfriends_wire::tag;

    fn offsets(frames: &[Frame]) -> Vec<(u64, usize)> {
        frames
            .iter()
            .map(|f| (f.integer(tag::OFFSET).expect("offset"), f.get(tag::DATA).expect("data").len()))
            .collect()
    }

    #[test]
    fn slices_and_pieces_map_onto_blocks() {
        let blocks = Geometry::for_size((3 << 20) + 7).unwrap();
        let send = SliceSend::new(&blocks, true);
        assert_eq!(send.units(&blocks).blocks, 13);
        assert_eq!(send.units_of_blocks(&blocks, &[(1, 2)]), vec![(4, 8)]);
        assert_eq!(send.units_of_blocks(&blocks, &[(3, 1)]), vec![(12, 1)]);
        assert_eq!(send.units_of_pieces(&blocks, &[(15, 2), (64, 1)]), vec![(0, 2), (4, 1)]);
        assert_eq!(send.block_of_unit(&blocks, 7), 1);
        // A peer without pieces: whole blocks.
        let whole = SliceSend::new(&blocks, false);
        assert_eq!(whole.units(&blocks).blocks, 4);
        assert_eq!(whole.units_of_blocks(&blocks, &[(1, 2)]), vec![(1, 2)]);
    }

    #[test]
    fn acknowledged_pieces_are_not_sent_again() {
        let blocks = Geometry::for_size(2 << 20).unwrap();
        let mut send = SliceSend::new(&blocks, true);
        send.keep(0, vec![9; 1 << 20]);
        assert_eq!(offsets(&send.parts(&[1; 16], &blocks, 1, 61_440)).len(), 5, "256 KiB in 60 KiB parts");
        // Pieces 16 to 19 (the slice's first 64 KiB) and 31 arrived: slice 1 is not whole yet.
        assert!(send.have_pieces(&blocks, &[(16, 4), (31, 1)]).is_empty());
        let left = offsets(&send.parts(&[1; 16], &blocks, 1, 16_384));
        assert_eq!(left.first(), Some(&(20 * 16_384, 16_384)));
        assert_eq!(left.len(), 11);
        assert_eq!(send.have_pieces(&blocks, &[(20, 11)]), vec![(1, 1)]);
        assert!(send.parts(&[1; 16], &blocks, 1, 16_384).is_empty());
        // Wanted again: the pieces go again.
        send.want(&blocks, &[], &[(30, 2)]);
        assert_eq!(offsets(&send.parts(&[1; 16], &blocks, 1, 61_440)), vec![(30 * 16_384, 32_768)]);
        send.want(&blocks, &[(0, 1)], &[]);
        let whole = offsets(&send.parts(&[1; 16], &blocks, 1, 1 << 20));
        assert_eq!((whole[0].0, whole.iter().map(|w| w.1).sum::<usize>()), (1 << 18, 1 << 18), "parts at most 60 KiB");
    }
}
