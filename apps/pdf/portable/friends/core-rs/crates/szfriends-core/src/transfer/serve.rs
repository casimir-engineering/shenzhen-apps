//! The sending side of a fast transfer (ADR 0018 § 3 and 4), sans-IO: the blocks a WANT names queue up in order;
//! each is read whole, checked against this side's own leaf (a snapshot that changed fails at its first changed block,
//! never after sending it) and cut into parts; at most a window of blocks is sent and not yet in a HAVE.

use std::collections::BTreeSet;

use szfriends_wire::consts::{BLOCKS_IN_FLIGHT_MAX, BYTES_IN_FLIGHT_MAX, PART_BYTES_MAX};
use szfriends_wire::Frame;

use super::blockset::BlockSet;
use super::frames;
use super::geometry::Geometry;
use super::tree::{self, Leaf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServeError {
    /// WANT or HAVE naming a block past the file.
    OutOfRange,
    /// A block read from the snapshot does not match its leaf: the file changed under the sender.
    Changed,
}

#[derive(Debug)]
struct Current {
    block: u32,
    data: Vec<u8>,
    sent: usize,
}

#[derive(Debug)]
pub struct BlockServe {
    id: Vec<u8>,
    geometry: Geometry,
    leaves: Vec<Leaf>,
    queue: BTreeSet<u32>,
    in_flight: BTreeSet<u32>,
    acknowledged: BlockSet,
    current: Option<Current>,
    part_bytes: usize,
    window_bytes: u64,
}

impl BlockServe {
    /// `part_bytes` is the route's part size; `window_bytes` what may be sent and not yet in a HAVE (at least two
    /// blocks, within § 3's limits).
    pub fn new(id: &[u8], geometry: Geometry, leaves: Vec<Leaf>, part_bytes: usize, window_bytes: u64) -> Self {
        let window = window_bytes.max(2 * geometry.block_bytes()).min(BYTES_IN_FLIGHT_MAX);
        Self {
            id: id.to_vec(),
            geometry,
            acknowledged: BlockSet::new(geometry.blocks),
            leaves,
            queue: BTreeSet::new(),
            in_flight: BTreeSet::new(),
            current: None,
            part_bytes: part_bytes.clamp(1, PART_BYTES_MAX),
            window_bytes: window,
        }
    }

    pub fn geometry(&self) -> &Geometry {
        &self.geometry
    }

    /// The leaves, for HASHES.
    pub fn hashes_frames(&self) -> Vec<Frame> {
        frames::hashes(&self.id, &self.leaves)
    }

    /// Blocks the receiver is missing: queued, even if sent before (a block that failed its check, or parts lost
    /// with a lane), unless already acknowledged since.
    pub fn want(&mut self, ranges: &[(u32, u32)]) -> Result<(), ServeError> {
        if !self.acknowledged.fits(ranges) {
            return Err(ServeError::OutOfRange);
        }
        for &(first, count) in ranges {
            for block in first..first + count {
                self.in_flight.remove(&block);
                self.acknowledged.remove(block);
                if self.current.as_ref().is_none_or(|c| c.block != block) {
                    self.queue.insert(block);
                }
            }
        }
        Ok(())
    }

    /// Every block wanted: a first acceptance, before any WANT.
    pub fn want_all(&mut self) {
        let _ = self.want(&[(0, self.geometry.blocks)]);
    }

    /// Blocks the receiver has checked and written.
    pub fn have(&mut self, ranges: &[(u32, u32)]) -> Result<(), ServeError> {
        if !self.acknowledged.fits(ranges) {
            return Err(ServeError::OutOfRange);
        }
        for &(first, count) in ranges {
            for block in first..first + count {
                self.in_flight.remove(&block);
                self.queue.remove(&block);
                self.acknowledged.insert(block);
            }
        }
        Ok(())
    }

    /// Blocks waiting to be sent (wanted, not in flight).
    pub fn queued(&self) -> usize {
        self.queue.len()
    }

    /// The part size for the parts cut from now on: each lane cuts its blocks at its own route's size (ADR 0018
    /// § 9.8: 16 KiB on Bluetooth).
    pub fn set_part_bytes(&mut self, part_bytes: usize) {
        self.part_bytes = part_bytes.clamp(1, PART_BYTES_MAX);
    }

    /// Bytes of the file the receiver has not acknowledged yet (ADR 0019 weighs the boost by them).
    pub fn remaining_bytes(&self) -> u64 {
        let acknowledged: u64 = self.acknowledged.iter().map(|block| self.geometry.span(block).1 as u64).sum();
        self.geometry.size.saturating_sub(acknowledged)
    }

    /// Every block acknowledged.
    pub fn all_acknowledged(&self) -> bool {
        self.acknowledged.is_full()
    }

    /// Blocks wanted and not yet acknowledged: queued, being cut into parts, or sent and waiting for a HAVE. A serve
    /// that is not busy gave everything it was asked for (a receiver resuming asks for the blocks it misses only).
    pub fn busy(&self) -> bool {
        !self.idle() || !self.in_flight.is_empty()
    }

    /// Nothing queued or being cut into parts.
    pub fn idle(&self) -> bool {
        self.queue.is_empty() && self.current.is_none()
    }

    fn in_flight_bytes(&self) -> u64 {
        self.in_flight.iter().map(|&b| self.geometry.span(b).1 as u64).sum()
    }

    /// The block to read next, when there is no block being sent and the window has room.
    pub fn next_block(&self) -> Option<u32> {
        if self.current.is_some() || self.in_flight.len() >= BLOCKS_IN_FLIGHT_MAX {
            return None;
        }
        let block = *self.queue.first()?;
        (self.in_flight.is_empty() || self.in_flight_bytes() + self.geometry.span(block).1 as u64 <= self.window_bytes)
            .then_some(block)
    }

    /// Whether `data` is block `block` as the leaves say (the snapshot unchanged), without taking it to send.
    pub fn check_block(&self, block: u32, data: &[u8]) -> Result<(), ServeError> {
        let fits = data.len() == self.geometry.span(block).1
            && self.leaves.get(block as usize).is_some_and(|leaf| tree::leaf(block, data) == *leaf);
        fits.then_some(()).ok_or(ServeError::Changed)
    }

    /// The block `next_block` named, as read from the snapshot.
    pub fn load_block(&mut self, block: u32, data: Vec<u8>) -> Result<(), ServeError> {
        if data.len() != self.geometry.span(block).1 || tree::leaf(block, &data) != self.leaves[block as usize] {
            return Err(ServeError::Changed);
        }
        self.queue.remove(&block);
        self.in_flight.insert(block);
        self.current = Some(Current { block, data, sent: 0 });
        Ok(())
    }

    /// The next PART of the block being sent.
    pub fn next_part(&mut self) -> Option<Frame> {
        let current = self.current.as_mut()?;
        let (block_offset, _) = self.geometry.span(current.block);
        let end = (current.sent + self.part_bytes).min(current.data.len());
        let frame = frames::part(&self.id, block_offset + current.sent as u64, &current.data[current.sent..end]);
        current.sent = end;
        if current.sent == current.data.len() {
            self.current = None;
        }
        Some(frame)
    }

    /// A lane or session ended: what was sent and not acknowledged is wanted again on the next one.
    pub fn requeue_in_flight(&mut self) {
        let blocks: Vec<u32> = self.in_flight.iter().copied().collect();
        self.in_flight.clear();
        self.current = None;
        self.queue.extend(blocks);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use szfriends_wire::tag;

    #[test]
    fn serves_wanted_blocks_within_the_window_and_refuses_a_changed_one() {
        let size = 5 * (1 << 20);
        let bytes: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
        let geometry = Geometry::for_size(size as u64).unwrap();
        let leaves: Vec<Leaf> =
            (0..5).map(|i| tree::leaf(i, &bytes[(i as usize) << 20..((i as usize) + 1) << 20])).collect();
        let mut serve = BlockServe::new(&[1; 16], geometry, leaves, 61_440, 2 << 20);
        assert_eq!(serve.next_block(), None);
        serve.want(&[(1, 3)]).unwrap();
        assert_eq!(serve.want(&[(4, 2)]), Err(ServeError::OutOfRange));
        let block = serve.next_block().unwrap();
        assert_eq!(block, 1);
        let mut changed = bytes[1 << 20..2 << 20].to_vec();
        changed[0] ^= 1;
        assert_eq!(serve.load_block(1, changed), Err(ServeError::Changed));
        serve.load_block(1, bytes[1 << 20..2 << 20].to_vec()).unwrap();
        let mut sent = 0;
        while let Some(frame) = serve.next_part() {
            sent += frame.get(tag::DATA).unwrap().len();
        }
        assert_eq!(sent, 1 << 20);
        serve.load_block(2, bytes[2 << 20..3 << 20].to_vec()).unwrap();
        while serve.next_part().is_some() {}
        assert_eq!(serve.next_block(), None, "two blocks fill a 2 MiB window");
        serve.have(&[(1, 1)]).unwrap();
        assert_eq!(serve.next_block(), Some(3));
        serve.requeue_in_flight();
        assert_eq!(serve.next_block(), Some(2));
        serve.have(&[(0, 5)]).unwrap();
        assert!(serve.all_acknowledged() && serve.idle());
    }
}
