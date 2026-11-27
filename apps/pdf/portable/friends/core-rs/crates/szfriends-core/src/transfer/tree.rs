//! The hash tree (ADR 0018 § 2), BLAKE3 in its plain hashing mode with fixed 18-byte prefixes that keep leaves, nodes
//! and the root apart:
//!
//! ```text
//! leaf(i) = BLAKE3("SZFriends leaf v1\0" || u64be(i) || block i)
//! node    = BLAKE3("SZFriends node v1\0" || left || right)       a lone last node moves up unchanged
//! root    = BLAKE3("SZFriends root v1\0" || u64be(size) || u8(shift) || top node)
//! ```
//!
//! Leaves are independent, so a whole file is hashed on every core; the read-back before publishing computes the
//! tree and the BLAKE2b-256 content digest (the file's identity everywhere else) in the same pass.

use std::fs::File;
use std::io;

use blake2::digest::{Update, VariableOutput};

use super::geometry::Geometry;

pub type Leaf = [u8; 32];

pub const LEAF_PREFIX: &[u8; 18] = b"SZFriends leaf v1\0";
pub const NODE_PREFIX: &[u8; 18] = b"SZFriends node v1\0";
pub const ROOT_PREFIX: &[u8; 18] = b"SZFriends root v1\0";

/// Blocks read and hashed together when hashing a file: enough to keep every core busy, bounded in memory.
const BATCH_BYTES: usize = 64 << 20;

pub fn leaf(index: u32, block: &[u8]) -> Leaf {
    let mut hasher = blake3::Hasher::new();
    hasher.update(LEAF_PREFIX);
    hasher.update(&u64::from(index).to_be_bytes());
    hasher.update(block);
    *hasher.finalize().as_bytes()
}

pub fn node(left: &Leaf, right: &Leaf) -> Leaf {
    let mut hasher = blake3::Hasher::new();
    hasher.update(NODE_PREFIX);
    hasher.update(left);
    hasher.update(right);
    *hasher.finalize().as_bytes()
}

/// Every level from the leaves up to the single top node; an empty input has no levels.
pub fn levels(leaves: &[Leaf]) -> Vec<Vec<Leaf>> {
    let mut levels = vec![leaves.to_vec()];
    while levels.last().is_some_and(|level| level.len() > 1) {
        let below = levels.last().expect("checked");
        let above = below
            .chunks(2)
            .map(|pair| match pair {
                [left, right] => node(left, right),
                [lone] => *lone,
                _ => unreachable!("chunks of two"),
            })
            .collect();
        levels.push(above);
    }
    levels
}

pub fn top(leaves: &[Leaf]) -> Leaf {
    levels(leaves).last().and_then(|level| level.first().copied()).unwrap_or([0; 32])
}

pub fn root(geometry: &Geometry, top: &Leaf) -> Leaf {
    let mut hasher = blake3::Hasher::new();
    hasher.update(ROOT_PREFIX);
    hasher.update(&geometry.size.to_be_bytes());
    hasher.update(&[geometry.shift]);
    hasher.update(top);
    *hasher.finalize().as_bytes()
}

/// The root of a complete list of leaves; `None` when the count is not the geometry's.
pub fn root_of(geometry: &Geometry, leaves: &[Leaf]) -> Option<Leaf> {
    (leaves.len() == geometry.blocks as usize).then(|| root(geometry, &top(leaves)))
}

/// The leaves of consecutive blocks starting at `first_index`, hashed on every core.
pub fn leaves_parallel(blocks: &[&[u8]], first_index: u32) -> Vec<Leaf> {
    let threads = std::thread::available_parallelism().map_or(1, usize::from).min(blocks.len()).max(1);
    if threads == 1 {
        return blocks.iter().enumerate().map(|(i, b)| leaf(first_index + i as u32, b)).collect();
    }
    let mut out = vec![[0u8; 32]; blocks.len()];
    let per = blocks.len().div_ceil(threads);
    std::thread::scope(|scope| {
        for (slot, (chunk, inputs)) in out.chunks_mut(per).zip(blocks.chunks(per)).enumerate() {
            scope.spawn(move || {
                for (j, (output, block)) in chunk.iter_mut().zip(inputs).enumerate() {
                    *output = leaf(first_index + (slot * per + j) as u32, block);
                }
            });
        }
    });
    out
}

/// What hashing a whole file gives: its leaves, root, and (when asked) its BLAKE2b-256 content digest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileHash {
    pub leaves: Vec<Leaf>,
    pub root: Leaf,
    pub digest: Option<[u8; 32]>,
}

/// Reads `length` bytes at `offset` through the descriptor itself (no shared seek position).
pub fn read_exact_at(file: &File, buffer: &mut [u8], offset: u64) -> io::Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::FileExt::read_exact_at(file, buffer, offset)
    }
    #[cfg(windows)]
    {
        let mut done = 0;
        while done < buffer.len() {
            let got = std::os::windows::fs::FileExt::seek_read(file, &mut buffer[done..], offset + done as u64)?;
            if got == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "shorter than its size"));
            }
            done += got;
        }
        Ok(())
    }
}

/// Writes all of `data` at `offset` through the descriptor itself.
pub fn write_all_at(file: &File, data: &[u8], offset: u64) -> io::Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::FileExt::write_all_at(file, data, offset)
    }
    #[cfg(windows)]
    {
        let mut done = 0;
        while done < data.len() {
            let wrote = std::os::windows::fs::FileExt::seek_write(file, &data[done..], offset + done as u64)?;
            if wrote == 0 {
                return Err(io::Error::new(io::ErrorKind::WriteZero, "nothing written"));
            }
            done += wrote;
        }
        Ok(())
    }
}

/// The leaves of the `count` blocks from `index` in `data`, on every core when there are several.
fn batch_leaves(data: &[u8], block_bytes: usize, index: u32, count: usize) -> Vec<Leaf> {
    if count == 1 {
        // One block (every small file): no thread is worth starting.
        return vec![leaf(index, data)];
    }
    let length = data.len();
    let blocks: Vec<&[u8]> =
        (0..count).map(|i| &data[(i * block_bytes).min(length)..((i + 1) * block_bytes).min(length)]).collect();
    leaves_parallel(&blocks, index)
}

/// Hashes the first `geometry.size` bytes of `file`: every leaf on every core and, with `digest`, the BLAKE2b-256 of
/// the same bytes on one more thread, in a single read pass. Two buffers of half [`BATCH_BYTES`]: the digest, the
/// slowest part (one thread), takes one batch while the next is read and its leaves hashed, so it never waits for
/// the disk or for the leaves.
pub fn hash_file(file: &File, geometry: &Geometry, digest: bool) -> io::Result<FileHash> {
    let block_bytes = geometry.block_bytes() as usize;
    let per_batch = (BATCH_BYTES / 2 / block_bytes).max(1);
    let capacity = (per_batch * block_bytes).min(geometry.size as usize);
    let mut leaves = Vec::with_capacity(geometry.blocks as usize);
    let digest = std::thread::scope(|scope| -> io::Result<Option<[u8; 32]>> {
        let (to_digest, batches) = std::sync::mpsc::channel::<(Vec<u8>, usize)>();
        let (give_back, returned) = std::sync::mpsc::channel::<Vec<u8>>();
        let several = geometry.blocks as usize > per_batch;
        let worker = digest.then(|| {
            let work = move || {
                let mut hasher = blake2::Blake2bVar::new(32).expect("32-byte output");
                for (buffer, length) in batches {
                    hasher.update(&buffer[..length]);
                    let _ = give_back.send(buffer);
                }
                let mut out = [0u8; 32];
                hasher.finalize_variable(&mut out).expect("length matches");
                out
            };
            scope.spawn(work)
        });
        let mut spare = vec![vec![0u8; capacity]];
        if worker.is_some() && several {
            spare.push(vec![0u8; capacity]);
        }
        let mut index = 0u32;
        let mut read = Ok(());
        while index < geometry.blocks {
            let count = per_batch.min((geometry.blocks - index) as usize);
            let (offset, _) = geometry.span(index);
            let (last_offset, last_length) = geometry.span(index + count as u32 - 1);
            let length = (last_offset + last_length as u64 - offset) as usize;
            let mut buffer = match spare.pop() {
                Some(buffer) => buffer,
                None => returned.recv().expect("the digest thread gives each buffer back"),
            };
            if buffer.len() < length {
                buffer.resize(length, 0);
            }
            if let Err(error) = read_exact_at(file, &mut buffer[..length], offset) {
                read = Err(error);
                break;
            }
            leaves.extend(batch_leaves(&buffer[..length], block_bytes, index, count));
            if worker.is_some() {
                let _ = to_digest.send((buffer, length));
            } else {
                spare.push(buffer);
            }
            index += count as u32;
        }
        drop(to_digest);
        let out = worker.map(|w| w.join().expect("digest thread"));
        read.map(|()| out)
    })?;
    let root = root_of(geometry, &leaves).expect("one leaf per block");
    Ok(FileHash { leaves, root, digest })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_lone_node_moves_up_and_the_root_binds_size_and_shift() {
        let leaves: Vec<Leaf> = (0..3u32).map(|i| leaf(i, &[i as u8])).collect();
        let expected_top = node(&node(&leaves[0], &leaves[1]), &leaves[2]);
        assert_eq!(top(&leaves), expected_top);
        let g = Geometry::new(3, 20).unwrap();
        assert_eq!(root_of(&g, &leaves), None, "three leaves for one block");
        let one = Geometry::new(1, 20).unwrap();
        assert_ne!(root_of(&one, &leaves[..1]), root_of(&Geometry::new(1, 21).unwrap(), &leaves[..1]));
        assert_ne!(leaf(0, b"ab"), leaf(1, b"ab"));
    }

    #[test]
    fn a_file_hashes_the_same_in_parallel_with_its_digest() {
        let size = 5 * (1 << 20) + 11;
        let bytes: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
        let path = std::env::temp_dir().join(format!("szf-tree-{}", std::process::id()));
        std::fs::write(&path, &bytes).unwrap();
        let file = File::open(&path).unwrap();
        let g = Geometry::for_size(size as u64).unwrap();
        let hashed = hash_file(&file, &g, true).unwrap();
        let _ = std::fs::remove_file(&path);
        let serial: Vec<Leaf> = (0..g.blocks)
            .map(|i| {
                let (offset, length) = g.span(i);
                leaf(i, &bytes[offset as usize..offset as usize + length])
            })
            .collect();
        assert_eq!(hashed.leaves, serial);
        assert_eq!(Some(hashed.root), root_of(&g, &serial));
        let mut digest = [0u8; 32];
        let mut h = blake2::Blake2bVar::new(32).unwrap();
        h.update(&bytes);
        h.finalize_variable(&mut digest).unwrap();
        assert_eq!(hashed.digest, Some(digest));
    }
}
