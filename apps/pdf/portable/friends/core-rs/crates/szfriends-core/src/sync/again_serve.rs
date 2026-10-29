//! Get again, the sender's side (ADR 0016): this computer gives a friend again a file it sent them, from its own bytes
//! only, without asking anyone, because it already chose to send that file to that person. Anything that is not such
//! a file is NONE 0, so the friend learns nothing about other files; "not now" (NONE 1) when another of the person's
//! computers holds it, or a limit is reached: one file at a time per friend, 20 whole-file digest checks an hour.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;

use super::again::{AgainMessage, AGAIN_PART_MAX, NONE_GONE, NONE_NOT_NOW};
use super::exchange::matches_digest;
use super::files::local_path_of_transfer;
use crate::store::sync_files;
use crate::store::{modified_ns, Relation, Store};

/// A WANT for another file within this long of the last WANT for an unfinished one is "not now".
pub const ONE_FILE_SECONDS: f64 = 60.0;
/// Whole-file digest checks per friend per rolling hour.
pub const CHECKS_PER_HOUR: usize = 20;
/// Parts sent for one WANT at most.
pub const PARTS_PER_WANT_MAX: u16 = 16;

#[derive(Debug, Default)]
struct Friend {
    /// The file served last, when its last WANT came, and whether its last part went.
    current: Option<(String, f64, bool)>,
    checks: VecDeque<f64>,
}

/// A file given again by blocks: the BLOCKS FOLLOW to send, then the leaves and the blocks `serve` cuts from `path`.
#[derive(Debug)]
pub struct ServeBlocks {
    pub follow: AgainMessage,
    pub serve: crate::transfer::BlockServe,
    pub path: PathBuf,
}

/// What this helper run keeps of the files it gives again.
#[derive(Debug, Default)]
pub struct AgainServer {
    /// Digest checks by transfer, path, size and modification time: a file checked once is not checked again while
    /// it stays unchanged.
    verified: HashMap<(String, PathBuf, u64, i64), bool>,
    /// Trees served by blocks, by transfer, path, size, modification time and shift.
    trees: HashMap<(String, PathBuf, u64, i64, u8), crate::transfer::FileHash>,
    friends: HashMap<String, Friend>,
}

impl AgainServer {
    pub fn new() -> Self {
        Self::default()
    }

    /// The answer to a friend's WANT on a session with `conversation_id`. `other_own_device` says whether a key is
    /// another authorized computer of this profile.
    pub fn answer(
        &mut self,
        store: &Store,
        conversation_id: &str,
        want: &AgainMessage,
        now: f64,
        other_own_device: &dyn Fn(&[u8; 32]) -> bool,
    ) -> Vec<AgainMessage> {
        let AgainMessage::Want { id, offset, parts } = want else { return Vec::new() };
        let none = |reason| vec![AgainMessage::None { id: id.clone(), reason }];
        let (row, path) = match self.check(store, conversation_id, id, now, other_own_device) {
            Ok(found) => found,
            Err(answer) => return answer,
        };
        if *offset > row.size {
            return none(NONE_GONE);
        }
        let limits = self.friends.entry(conversation_id.to_owned()).or_default();
        let Ok(mut handle) = std::fs::File::open(&path) else { return none(NONE_GONE) };
        if handle.seek(SeekFrom::Start(*offset)).is_err() {
            return none(NONE_GONE);
        }
        let mut answer = Vec::new();
        let mut at = *offset;
        for _ in 0..(*parts).clamp(1, PARTS_PER_WANT_MAX) {
            let length = (AGAIN_PART_MAX as u64).min(row.size - at) as usize;
            let mut bytes = vec![0u8; length];
            if handle.read_exact(&mut bytes).is_err() {
                return none(NONE_GONE);
            }
            let last = at + length as u64 == row.size;
            answer.push(AgainMessage::Part { id: id.clone(), offset: at, last, bytes });
            at += length as u64;
            if last {
                break;
            }
        }
        limits.current = Some((id.clone(), now, at == row.size));
        answer
    }

    /// A WANT BLOCKS (ADR 0018 § 4, fast-transfer sessions only): the same checks, then BLOCKS FOLLOW with this
    /// file's tree at the asked shift, and what serves the blocks asked for (the session sends the leaves first).
    pub fn answer_blocks(
        &mut self,
        store: &Store,
        conversation_id: &str,
        want: &AgainMessage,
        now: f64,
        other_own_device: &dyn Fn(&[u8; 32]) -> bool,
    ) -> Result<ServeBlocks, Vec<AgainMessage>> {
        let AgainMessage::WantBlocks { id, shift, ranges } = want else { return Err(Vec::new()) };
        let none = |reason| vec![AgainMessage::None { id: id.clone(), reason }];
        let (row, path) = self.check(store, conversation_id, id, now, other_own_device)?;
        let geometry = crate::transfer::Geometry::new(row.size, *shift).ok_or_else(|| none(NONE_GONE))?;
        let key = (id.clone(), path.clone(), row.size, modified_ns(&path), *shift);
        let hashed = match self.trees.get(&key) {
            Some(hashed) => hashed.clone(),
            None => {
                let file = std::fs::File::open(&path).map_err(|_| none(NONE_GONE))?;
                let hashed = crate::transfer::tree::hash_file(&file, &geometry, false).map_err(|_| none(NONE_GONE))?;
                self.trees.insert(key, hashed.clone());
                hashed
            }
        };
        let wire = hex::decode(id).map_err(|_| none(NONE_GONE))?;
        let mut serve = crate::transfer::BlockServe::new(&wire, geometry, hashed.leaves, AGAIN_PART_MAX, 8 << 20);
        serve.want(ranges).map_err(|_| none(NONE_GONE))?;
        let limits = self.friends.entry(conversation_id.to_owned()).or_default();
        limits.current = Some((id.clone(), now, false));
        Ok(ServeBlocks {
            follow: AgainMessage::BlocksFollow { id: id.clone(), root: hashed.root, shift: *shift },
            serve,
            path,
        })
    }

    /// The checks every answer makes: a file this computer sent this friend, its bytes here and unchanged, within the
    /// limits. Its row and path, or the NONE to answer.
    fn check(
        &mut self,
        store: &Store,
        conversation_id: &str,
        id: &String,
        now: f64,
        other_own_device: &dyn Fn(&[u8; 32]) -> bool,
    ) -> Result<(crate::store::sync_records::SyncTransfer, PathBuf), Vec<AgainMessage>> {
        let none = |reason| vec![AgainMessage::None { id: id.clone(), reason }];
        let friend = store.person_with_conversation(conversation_id).ok().flatten();
        if !friend.is_some_and(|p| p.relation == Relation::Friend) {
            return Err(none(NONE_GONE));
        }
        let row = sync_files::transfer(&store.conn, id).ok().flatten();
        let Some(row) = row.filter(|t| t.outgoing && t.conversation_id == conversation_id && t.state == 5) else {
            return Err(none(NONE_GONE));
        };
        let Some(path) = local_path_of_transfer(store, &row) else {
            // Another of our computers has it: the friend waits for that one rather than hear it is gone.
            let record = sync_files::sync_file(&store.conn, id).ok().flatten();
            let elsewhere = record.is_some_and(|r| r.holders.iter().any(other_own_device));
            return Err(none(if elsewhere { NONE_NOT_NOW } else { NONE_GONE }));
        };
        let limits = self.friends.entry(conversation_id.to_owned()).or_default();
        if let Some((current, last, finished)) = &limits.current {
            if current != id && !finished && now - last < ONE_FILE_SECONDS {
                return Err(none(NONE_NOT_NOW));
            }
        }
        let key = (id.clone(), path.clone(), row.size, modified_ns(&path));
        let matches = match self.verified.get(&key) {
            Some(matches) => *matches,
            None => {
                limits.checks.retain(|at| now - at < 3600.0);
                if limits.checks.len() >= CHECKS_PER_HOUR {
                    return Err(none(NONE_NOT_NOW));
                }
                limits.checks.push_back(now);
                let matches = matches_digest(&path, row.size, &row.digest);
                self.verified.insert(key, matches);
                matches
            }
        };
        if !matches {
            return Err(none(NONE_GONE));
        }
        Ok((row, path))
    }
}
