//! Reusing blocks this computer already holds (ADR 0018 § 9.5, WP6): when a friend sends a file whose leaves match
//! blocks of a file they sent before, or of one this person sent them, those blocks are read here instead of sent
//! again. A new version of a CAD model or a document that was edited in place usually keeps most of its blocks.
//!
//! The index is a directory of small files, `blocks-index/<scope>-<transfer>.leaves`, one per file received or sent
//! by blocks: where the file is and its leaves. It never leaves this computer and nothing in it is sent: a friend
//! learns only which of the blocks they offered were not wanted, and only from files that friend sent or was sent, so
//! at most that the person still has what they exchanged. Bounded to the newest 1,024 files and 64 MiB of leaves; an
//! entry whose file moved or changed costs one failed check and is dropped.
//!
//! A leaf binds its block's index (ADR 0018 § 2), so blocks are found at the same position only: edits that do not
//! move the rest of the file. Every block found is read and checked against the new file's leaf, through the same
//! path as a block that arrived, before it counts.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use super::Store;
use crate::transfer::{Geometry, Leaf};

const MAGIC: &[u8; 8] = b"SZFRIDX1";
const MAX_FILES: usize = 1_024;
const MAX_BYTES: u64 = 64 << 20;
/// Leaves of one file at most (ADR 0018 § 2), so a damaged entry cannot make a lookup read more.
const MAX_LEAVES: usize = 65_536;

/// One indexed file.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct IndexEntry {
    pub path: PathBuf,
    pub shift: u8,
    pub size: u64,
    pub leaves: Vec<Leaf>,
}

impl IndexEntry {
    fn encode(&self) -> Option<Vec<u8>> {
        let path = self.path.to_str()?.as_bytes();
        let length = u16::try_from(path.len()).ok()?;
        let mut out = Vec::with_capacity(8 + 1 + 8 + 2 + path.len() + 4 + 32 * self.leaves.len());
        out.extend_from_slice(MAGIC);
        out.push(self.shift);
        out.extend_from_slice(&self.size.to_be_bytes());
        out.extend_from_slice(&length.to_be_bytes());
        out.extend_from_slice(path);
        out.extend_from_slice(&(self.leaves.len() as u32).to_be_bytes());
        for leaf in &self.leaves {
            out.extend_from_slice(leaf);
        }
        Some(out)
    }

    fn decode(bytes: &[u8]) -> Option<Self> {
        let rest = bytes.strip_prefix(MAGIC)?;
        let (&shift, rest) = rest.split_first()?;
        let size = u64::from_be_bytes(rest.get(..8)?.try_into().ok()?);
        let length = usize::from(u16::from_be_bytes(rest.get(8..10)?.try_into().ok()?));
        let path = std::str::from_utf8(rest.get(10..10 + length)?).ok()?;
        let rest = &rest[10 + length..];
        let count = u32::from_be_bytes(rest.get(..4)?.try_into().ok()?) as usize;
        let leaves = rest.get(4..)?;
        if count > MAX_LEAVES || leaves.len() != 32 * count {
            return None;
        }
        let leaves = leaves.chunks_exact(32).map(|c| c.try_into().expect("32")).collect();
        Some(Self { path: PathBuf::from(path), shift, size, leaves })
    }
}

/// A new file only this user can read (0600, never through a symbolic link).
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    options.open(path)?.write_all(bytes)
}

/// The file-name prefix for one friend's entries: 16 hex digits of BLAKE2b over the conversation id, so a lookup
/// reads only that friend's entries and a listing of the directory names nobody.
fn scope_prefix(conversation_id: &str) -> String {
    let digest = crate::crypto::blake2b::<8>(None, &[b"SZFriends block index v1", conversation_id.as_bytes()]);
    hex::encode(digest)
}

impl Store {
    fn block_index_dir(&self) -> PathBuf {
        self.state_dir().join("blocks-index")
    }

    /// Remembers where a file exchanged with this friend is and its leaves, for later versions of it. Best effort: an
    /// index that cannot be written only costs blocks sent again.
    pub(crate) fn index_blocks(
        &self,
        conversation_id: &str,
        transfer_id: &str,
        path: &Path,
        geometry: &Geometry,
        leaves: &[Leaf],
    ) {
        if leaves.len() != geometry.blocks as usize || leaves.len() > MAX_LEAVES {
            return;
        }
        let directory = self.block_index_dir();
        let name = format!("{}-{transfer_id}.leaves", scope_prefix(conversation_id));
        let target = directory.join(&name);
        if target.exists() {
            return;
        }
        let entry =
            IndexEntry { path: path.to_owned(), shift: geometry.shift, size: geometry.size, leaves: leaves.to_vec() };
        let Some(bytes) = entry.encode() else { return };
        if fs::create_dir_all(&directory).is_err() {
            return;
        }
        let temporary = directory.join(format!(".{name}"));
        let written = write_private(&temporary, &bytes).and_then(|()| fs::rename(&temporary, &target));
        if written.is_err() {
            let _ = fs::remove_file(&temporary);
            return;
        }
        self.trim_block_index();
    }

    /// Keeps the newest [`MAX_FILES`] entries within [`MAX_BYTES`].
    fn trim_block_index(&self) {
        let Ok(listing) = fs::read_dir(self.block_index_dir()) else { return };
        let mut entries: Vec<(std::time::SystemTime, u64, PathBuf)> = listing
            .filter_map(|e| {
                let e = e.ok()?;
                let meta = e.metadata().ok()?;
                meta.is_file().then(|| (meta.modified().unwrap_or(std::time::UNIX_EPOCH), meta.len(), e.path()))
            })
            .collect();
        entries.sort_by_key(|entry| std::cmp::Reverse(entry.0));
        let mut total = 0u64;
        for (index, (_, length, path)) in entries.iter().enumerate() {
            total += length;
            if index >= MAX_FILES || total > MAX_BYTES {
                let _ = fs::remove_file(path);
            }
        }
    }

    /// Blocks of a file this friend is sending that an indexed file of theirs (or one sent to them) holds at the same
    /// position, by leaf: `(block, file to read it from)`, for the blocks `missing` names. Entries whose file is gone
    /// are dropped.
    pub(crate) fn reusable_blocks(
        &self,
        conversation_id: &str,
        geometry: &Geometry,
        leaves: &[Leaf],
        missing: impl Fn(u32) -> bool,
    ) -> Vec<(u32, PathBuf)> {
        let Ok(listing) = fs::read_dir(self.block_index_dir()) else { return Vec::new() };
        let prefix = format!("{}-", scope_prefix(conversation_id));
        let mut found: HashMap<u32, PathBuf> = HashMap::new();
        for item in listing.filter_map(|e| e.ok()) {
            let path = item.path();
            if !item.file_name().to_str().is_some_and(|n| n.starts_with(&prefix) && n.ends_with(".leaves")) {
                continue;
            }
            let Some(entry) = fs::read(&path).ok().and_then(|b| IndexEntry::decode(&b)) else {
                let _ = fs::remove_file(&path);
                continue;
            };
            if !entry.path.is_file() {
                let _ = fs::remove_file(&path);
                continue;
            }
            if entry.shift != geometry.shift {
                continue;
            }
            for (block, leaf) in entry.leaves.iter().enumerate().take(leaves.len()) {
                let block = block as u32;
                if *leaf == leaves[block as usize] && missing(block) {
                    found.entry(block).or_insert_with(|| entry.path.clone());
                }
            }
        }
        let mut found: Vec<(u32, PathBuf)> = found.into_iter().collect();
        found.sort();
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_entry_round_trips_and_damage_is_refused() {
        let entry =
            IndexEntry { path: PathBuf::from("/tmp/a b.step"), shift: 20, size: 3 << 20, leaves: vec![[7; 32]; 3] };
        let bytes = entry.encode().unwrap();
        assert_eq!(IndexEntry::decode(&bytes), Some(entry));
        assert_eq!(IndexEntry::decode(&bytes[..bytes.len() - 1]), None);
        let mut wrong = bytes.clone();
        wrong[0] ^= 1;
        assert_eq!(IndexEntry::decode(&wrong), None);
    }

    #[test]
    fn scopes_never_name_the_friend() {
        let prefix = scope_prefix("conversation-1");
        assert_eq!(prefix.len(), 16);
        assert!(!prefix.contains("conversation"));
        assert_ne!(prefix, scope_prefix("conversation-2"));
    }
}
