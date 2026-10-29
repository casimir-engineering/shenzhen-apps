//! A set of block indexes below a fixed count, as a bitmap: what is complete, durable, wanted or acknowledged. Its
//! byte form (bit `i % 8` of byte `i / 8`, most significant first) is the block map sidecar's bitmap.

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BlockSet {
    bits: Vec<u64>,
    len: u32,
    count: u32,
}

impl BlockSet {
    pub fn new(len: u32) -> Self {
        Self { bits: vec![0; (len as usize).div_ceil(64)], len, count: 0 }
    }

    /// The same members in a set of `len` blocks (members past it are dropped).
    pub fn widened(&self, len: u32) -> Self {
        let mut set = Self::new(len);
        self.iter().for_each(|i| {
            set.insert(i);
        });
        set
    }

    pub fn full(len: u32) -> Self {
        let mut set = Self::new(len);
        set.insert_range(0, len);
        set
    }

    pub fn len(&self) -> u32 {
        self.len
    }

    pub fn count(&self) -> u32 {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    pub fn is_full(&self) -> bool {
        self.count == self.len
    }

    pub fn contains(&self, index: u32) -> bool {
        index < self.len && self.bits[(index / 64) as usize] & (1 << (index % 64)) != 0
    }

    /// `true` when it was not in the set.
    pub fn insert(&mut self, index: u32) -> bool {
        if index >= self.len || self.contains(index) {
            return false;
        }
        self.bits[(index / 64) as usize] |= 1 << (index % 64);
        self.count += 1;
        true
    }

    /// `true` when it was in the set.
    pub fn remove(&mut self, index: u32) -> bool {
        if !self.contains(index) {
            return false;
        }
        self.bits[(index / 64) as usize] &= !(1 << (index % 64));
        self.count -= 1;
        true
    }

    pub fn insert_range(&mut self, first: u32, count: u32) {
        for index in first..first.saturating_add(count).min(self.len) {
            self.insert(index);
        }
    }

    /// Ranges that all lie below the count; `false`, changing nothing, when one does not.
    pub fn fits(&self, ranges: &[(u32, u32)]) -> bool {
        ranges.iter().all(|&(first, count)| u64::from(first) + u64::from(count) <= u64::from(self.len))
    }

    pub fn iter(&self) -> impl Iterator<Item = u32> + '_ {
        (0..self.len).filter(|&i| self.contains(i))
    }

    /// The set as ascending `(first, count)` runs.
    pub fn ranges(&self) -> Vec<(u32, u32)> {
        runs((0..self.len).map(|i| self.contains(i)))
    }

    /// What is not in the set, as runs.
    pub fn missing_ranges(&self) -> Vec<(u32, u32)> {
        runs((0..self.len).map(|i| !self.contains(i)))
    }

    /// The first `n` indexes from 0 that are all in the set.
    pub fn prefix(&self) -> u32 {
        (0..self.len).find(|&i| !self.contains(i)).unwrap_or(self.len)
    }

    pub fn to_bitmap(&self) -> Vec<u8> {
        let mut out = vec![0u8; (self.len as usize).div_ceil(8)];
        for index in self.iter() {
            out[(index / 8) as usize] |= 0x80 >> (index % 8);
        }
        out
    }

    /// From a bitmap of exactly the right length whose padding bits are clear.
    pub fn from_bitmap(len: u32, bitmap: &[u8]) -> Option<Self> {
        if bitmap.len() != (len as usize).div_ceil(8) {
            return None;
        }
        let mut set = Self::new(len);
        for (byte_index, byte) in bitmap.iter().enumerate() {
            for bit in 0..8u32 {
                if byte & (0x80 >> bit) != 0 {
                    let index = byte_index as u32 * 8 + bit;
                    if index >= len {
                        return None;
                    }
                    set.insert(index);
                }
            }
        }
        Some(set)
    }
}

fn runs(flags: impl Iterator<Item = bool>) -> Vec<(u32, u32)> {
    let mut out: Vec<(u32, u32)> = Vec::new();
    for (index, flag) in flags.enumerate() {
        if !flag {
            continue;
        }
        match out.last_mut() {
            Some((first, count)) if *first + *count == index as u32 => *count += 1,
            _ => out.push((index as u32, 1)),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_prefix_and_bitmap() {
        let mut set = BlockSet::new(70);
        set.insert_range(0, 3);
        set.insert(5);
        set.insert(69);
        assert_eq!(set.ranges(), vec![(0, 3), (5, 1), (69, 1)]);
        assert_eq!(set.missing_ranges(), vec![(3, 2), (6, 63)]);
        assert_eq!((set.prefix(), set.count()), (3, 5));
        let bitmap = set.to_bitmap();
        assert_eq!(bitmap[0], 0b1110_0100);
        assert_eq!(BlockSet::from_bitmap(70, &bitmap), Some(set.clone()));
        assert_eq!(BlockSet::from_bitmap(69, &bitmap), None, "a bit past the count");
        assert!(set.fits(&[(60, 10)]) && !set.fits(&[(60, 11)]));
        assert!(BlockSet::full(9).is_full());
    }
}
