//! Block geometry (ADR 0018 § 2): blocks of 2^shift bytes, the last one shorter; shift 20 (1 MiB) up to 64 GiB, then
//! the smallest shift up to 24 (16 MiB) that keeps 65,536 blocks or fewer. An empty file is one empty block, so every
//! file has a tree. A file over 1 TiB has no geometry and goes by CHUNK.

use szfriends_wire::consts::{BLOCKS_MAX, BLOCK_SHIFT_MAX, BLOCK_SHIFT_MIN};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Geometry {
    pub size: u64,
    pub shift: u8,
    pub blocks: u32,
}

fn block_count(size: u64, shift: u8) -> u64 {
    size.div_ceil(1u64 << shift).max(1)
}

impl Geometry {
    /// The geometry this build offers a file of `size` bytes.
    pub fn for_size(size: u64) -> Option<Self> {
        (BLOCK_SHIFT_MIN..=BLOCK_SHIFT_MAX).find_map(|shift| Self::new(size, shift))
    }

    /// An offered geometry: any shift from 20 to 24 that keeps the block count within limits.
    pub fn new(size: u64, shift: u8) -> Option<Self> {
        if !(BLOCK_SHIFT_MIN..=BLOCK_SHIFT_MAX).contains(&shift) {
            return None;
        }
        let blocks = block_count(size, shift);
        (blocks <= u64::from(BLOCKS_MAX)).then_some(Self { size, shift, blocks: blocks as u32 })
    }

    pub fn block_bytes(&self) -> u64 {
        1u64 << self.shift
    }

    /// Block `index`'s offset and length; the last block is shorter, an empty file's only block is empty.
    pub fn span(&self, index: u32) -> (u64, usize) {
        let offset = u64::from(index) << self.shift;
        let length = self.size.saturating_sub(offset).min(self.block_bytes());
        (offset, length as usize)
    }

    /// The block holding byte `offset`.
    pub fn block_of(&self, offset: u64) -> u32 {
        (offset >> self.shift) as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shifts_follow_the_size() {
        assert_eq!(Geometry::for_size(0), Some(Geometry { size: 0, shift: 20, blocks: 1 }));
        assert_eq!(Geometry::for_size(1 << 20).map(|g| g.blocks), Some(1));
        assert_eq!(Geometry::for_size((1 << 20) + 1).map(|g| g.blocks), Some(2));
        assert_eq!(Geometry::for_size(64 << 30).map(|g| (g.shift, g.blocks)), Some((20, 65_536)));
        assert_eq!(Geometry::for_size((64 << 30) + 1).map(|g| (g.shift, g.blocks)), Some((21, 32_769)));
        assert_eq!(Geometry::for_size(1 << 40).map(|g| (g.shift, g.blocks)), Some((24, 65_536)));
        assert_eq!(Geometry::for_size((1 << 40) + 1), None);
        assert_eq!(Geometry::new(10, 19), None);
        assert_eq!(Geometry::new(10, 25), None);
        let g = Geometry::for_size(3 * (1 << 20) + 7).unwrap();
        assert_eq!((g.blocks, g.span(3), g.block_of((3 << 20) + 6)), (4, (3 << 20, 7), 3));
    }
}
