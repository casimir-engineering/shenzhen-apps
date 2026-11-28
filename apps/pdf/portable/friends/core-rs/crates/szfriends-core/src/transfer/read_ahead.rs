//! The sender's blocks read and checked ahead of the lanes (ADR 0018 § 7), on a thread of the file's own: the
//! session's thread asks for the blocks the scheduler will place next and, when it places one, takes it already read
//! and checked against its leaf instead of reading and hashing it while every lane waits. A block taken before it was
//! asked for, or once the reader is gone, is read where it is taken, exactly as before. A file of one block has
//! nothing to read ahead and no thread.

use std::collections::{BTreeSet, HashMap};
use std::fs::File;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};

use super::geometry::Geometry;
use super::serve::ServeError;
use super::tree::{self, read_exact_at, Leaf};

/// Read ahead: at least two blocks, and up to this many bytes of smaller ones.
const AHEAD_BYTES: u64 = 8 << 20;

type Checked = Result<Vec<u8>, ServeError>;

struct Ask {
    block: u32,
    leaf: Leaf,
}

/// One file's blocks read ahead (see the module documentation).
pub struct ReadAhead {
    path: Option<PathBuf>,
    geometry: Geometry,
    worker: Option<(Sender<Ask>, Receiver<(u32, Checked)>)>,
    asked: BTreeSet<u32>,
    ready: HashMap<u32, Checked>,
}

impl std::fmt::Debug for ReadAhead {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReadAhead").field("asked", &self.asked).field("ready", &self.ready.len()).finish()
    }
}

/// Block `block` of the file at `path`, read and checked against `leaf`; any failure means the snapshot changed.
fn read_checked(path: Option<&PathBuf>, geometry: &Geometry, block: u32, leaf: &Leaf) -> Checked {
    let file = File::open(path.ok_or(ServeError::Changed)?).map_err(|_| ServeError::Changed)?;
    let (offset, length) = geometry.span(block);
    let mut data = vec![0u8; length];
    read_exact_at(&file, &mut data, offset).map_err(|_| ServeError::Changed)?;
    (tree::leaf(block, &data) == *leaf).then_some(data).ok_or(ServeError::Changed)
}

impl ReadAhead {
    /// The snapshot at `path` (none: every read fails, as a missing source does), cut by `geometry`.
    pub fn new(path: Option<PathBuf>, geometry: Geometry) -> Self {
        Self { path, geometry, worker: None, asked: BTreeSet::new(), ready: HashMap::new() }
    }

    /// How many blocks it holds or reads ahead at most.
    pub fn depth(&self) -> usize {
        ((AHEAD_BYTES >> self.geometry.shift) as usize).max(2)
    }

    fn start_worker(&mut self) -> bool {
        if self.worker.is_some() {
            return true;
        }
        let (asks, inbox) = channel::<Ask>();
        let (results, outbox) = channel();
        let (path, geometry) = (self.path.clone(), self.geometry);
        let started = std::thread::Builder::new().name("szfriends-read-ahead".into()).spawn(move || {
            for ask in inbox {
                let checked = read_checked(path.as_ref(), &geometry, ask.block, &ask.leaf);
                if results.send((ask.block, checked)).is_err() {
                    return;
                }
            }
        });
        if started.is_ok() {
            self.worker = Some((asks, outbox));
        }
        started.is_ok()
    }

    /// The blocks the lanes will want next, lowest first, each with its leaf: read on the worker as far as
    /// [`ReadAhead::depth`] allows. Blocks read earlier and no longer among them are let go.
    pub fn ahead(&mut self, blocks: &[(u32, Leaf)]) {
        if self.geometry.blocks < 2 {
            return;
        }
        self.collect();
        self.ready.retain(|block, _| blocks.iter().any(|(b, _)| b == block));
        for &(block, leaf) in blocks {
            if self.asked.len() + self.ready.len() >= self.depth() {
                break;
            }
            if self.asked.contains(&block) || self.ready.contains_key(&block) || !self.start_worker() {
                continue;
            }
            let sent = self.worker.as_ref().is_some_and(|(asks, _)| asks.send(Ask { block, leaf }).is_ok());
            if !sent {
                self.worker = None;
                self.asked.clear();
                return;
            }
            self.asked.insert(block);
        }
    }

    /// What the worker finished, without waiting.
    fn collect(&mut self) {
        let Some((_, results)) = &self.worker else { return };
        while let Ok((block, checked)) = results.try_recv() {
            self.asked.remove(&block);
            self.ready.insert(block, checked);
        }
    }

    /// Block `block`, read and checked against `leaf`: from the worker when it was asked for (waiting for it if it is
    /// still being read), read here otherwise.
    pub fn take(&mut self, block: u32, leaf: &Leaf) -> Checked {
        self.collect();
        if let Some(checked) = self.ready.remove(&block) {
            return checked;
        }
        while self.asked.contains(&block) {
            let Some((_, results)) = &self.worker else { break };
            match results.recv() {
                Ok((got, checked)) => {
                    self.asked.remove(&got);
                    if got == block {
                        return checked;
                    }
                    self.ready.insert(got, checked);
                }
                Err(_) => {
                    self.worker = None;
                    self.asked.clear();
                }
            }
        }
        read_checked(self.path.as_ref(), &self.geometry, block, leaf)
    }
}

