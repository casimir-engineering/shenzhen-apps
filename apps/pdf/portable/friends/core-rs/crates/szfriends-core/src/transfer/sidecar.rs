//! The two sidecar files of ADR 0018 § 4, named by the transfer id beside the files they describe. Integers are
//! big-endian; both start with the same 88-byte header:
//!
//! ```text
//! 0   8   magic: "SZFRMAP\x01" (receiver, received/.partial/<id>.map) or "SZFRTRE\x01" (sender, outgoing/<id>.tree)
//! 8   8   size
//! 16  1   shift
//! 17  1   flags: bit 0, the leaves follow (a map written at OFFER has only the header; the tree always has them)
//! 18  2   zero
//! 20  4   block count
//! 24  32  TreeRoot
//! 56  32  the offered BLAKE2b-256 digest, the file's identity
//! 88  32 × blocks   the leaves, checked against TreeRoot (with flag bit 0)
//! ..  ⌈blocks / 8⌉  map only: the durable blocks, bit i % 8 of byte i / 8, most significant first
//! ```
//!
//! A decoded sidecar is trusted only as far as it checks: the leaves must hash to the root, and a receiver re-reads
//! every block its map claims before believing it (`store/blocks.rs`).

use super::blockset::BlockSet;
use super::geometry::Geometry;
use super::tree::{self, Leaf};

pub const MAP_MAGIC: &[u8; 8] = b"SZFRMAP\x01";
pub const TREE_MAGIC: &[u8; 8] = b"SZFRTRE\x01";
pub const HEADER_BYTES: usize = 88;
const FLAG_LEAVES: u8 = 1;

/// What both sidecars start with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub geometry: Geometry,
    pub root: Leaf,
    pub digest: [u8; 32],
}

/// A receiver's map: the offered tree, and once HASHES checked, the leaves and the durable blocks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockMap {
    pub header: Header,
    pub leaves: Option<Vec<Leaf>>,
    pub durable: BlockSet,
}

fn encode_header(magic: &[u8; 8], header: &Header, with_leaves: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_BYTES);
    out.extend_from_slice(magic);
    out.extend_from_slice(&header.geometry.size.to_be_bytes());
    out.push(header.geometry.shift);
    out.push(if with_leaves { FLAG_LEAVES } else { 0 });
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&header.geometry.blocks.to_be_bytes());
    out.extend_from_slice(&header.root);
    out.extend_from_slice(&header.digest);
    out
}

fn decode_header(magic: &[u8; 8], bytes: &[u8]) -> Option<(Header, bool)> {
    if bytes.len() < HEADER_BYTES || &bytes[..8] != magic || bytes[17] & !FLAG_LEAVES != 0 || bytes[18..20] != [0, 0] {
        return None;
    }
    let size = u64::from_be_bytes(bytes[8..16].try_into().ok()?);
    let geometry = Geometry::new(size, bytes[16])?;
    if u32::from_be_bytes(bytes[20..24].try_into().ok()?) != geometry.blocks {
        return None;
    }
    let header = Header { geometry, root: bytes[24..56].try_into().ok()?, digest: bytes[56..88].try_into().ok()? };
    Some((header, bytes[17] & FLAG_LEAVES != 0))
}

fn decode_leaves(header: &Header, bytes: &[u8]) -> Option<Vec<Leaf>> {
    let leaves: Vec<Leaf> = bytes.chunks_exact(32).map(|c| c.try_into().expect("32")).collect();
    (leaves.len() == header.geometry.blocks as usize && tree::root_of(&header.geometry, &leaves) == Some(header.root))
        .then_some(leaves)
}

impl BlockMap {
    pub fn new(header: Header) -> Self {
        Self { header, leaves: None, durable: BlockSet::new(header.geometry.blocks) }
    }

    /// Where the durable bitmap starts, once the leaves are written.
    pub fn bitmap_offset(&self) -> usize {
        HEADER_BYTES + 32 * self.header.geometry.blocks as usize
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = encode_header(MAP_MAGIC, &self.header, self.leaves.is_some());
        if let Some(leaves) = &self.leaves {
            leaves.iter().for_each(|leaf| out.extend_from_slice(leaf));
            out.extend_from_slice(&self.durable.to_bitmap());
        }
        out
    }

    /// `None` for anything malformed, or leaves that do not hash to the root.
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let (header, with_leaves) = decode_header(MAP_MAGIC, bytes)?;
        let mut map = Self::new(header);
        if !with_leaves {
            return (bytes.len() == HEADER_BYTES).then_some(map);
        }
        let bitmap_offset = map.bitmap_offset();
        let bitmap_bytes = (header.geometry.blocks as usize).div_ceil(8);
        if bytes.len() != bitmap_offset + bitmap_bytes {
            return None;
        }
        map.leaves = Some(decode_leaves(&header, &bytes[HEADER_BYTES..bitmap_offset])?);
        map.durable = BlockSet::from_bitmap(header.geometry.blocks, &bytes[bitmap_offset..])?;
        Some(map)
    }
}

/// A sender's tree: the header and every leaf of its snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SenderTree {
    pub header: Header,
    pub leaves: Vec<Leaf>,
}

impl SenderTree {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = encode_header(TREE_MAGIC, &self.header, true);
        self.leaves.iter().for_each(|leaf| out.extend_from_slice(leaf));
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let (header, with_leaves) = decode_header(TREE_MAGIC, bytes)?;
        if !with_leaves || bytes.len() != HEADER_BYTES + 32 * header.geometry.blocks as usize {
            return None;
        }
        Some(Self { header, leaves: decode_leaves(&header, &bytes[HEADER_BYTES..])? })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecars_round_trip_and_refuse_leaves_that_do_not_hash_to_the_root() {
        let geometry = Geometry::for_size(3 << 20).unwrap();
        let leaves: Vec<Leaf> = (0..3).map(|i| tree::leaf(i, &[i as u8])).collect();
        let root = tree::root_of(&geometry, &leaves).unwrap();
        let header = Header { geometry, root, digest: [7; 32] };
        let mut map = BlockMap::new(header);
        assert_eq!(BlockMap::decode(&map.encode()), Some(map.clone()));
        map.leaves = Some(leaves.clone());
        map.durable.insert(2);
        let bytes = map.encode();
        assert_eq!(bytes.len(), map.bitmap_offset() + 1);
        assert_eq!(BlockMap::decode(&bytes), Some(map.clone()));
        let mut tampered = bytes.clone();
        tampered[HEADER_BYTES] ^= 1;
        assert_eq!(BlockMap::decode(&tampered), None);
        let tree = SenderTree { header, leaves };
        assert_eq!(SenderTree::decode(&tree.encode()), Some(tree.clone()));
        assert_eq!(SenderTree::decode(&bytes), None, "a map is not a tree");
    }
}
