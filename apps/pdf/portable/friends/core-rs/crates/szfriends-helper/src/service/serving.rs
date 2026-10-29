//! Files this computer serves by blocks (ADR 0018 § 4), by session: Get again for a friend, or a copy for another of
//! the person's computers. For the latter the You row says how far the copy is ("Copying to your other computers ·
//! 40%") until the other computer has every block, the serve ends, or the copy stops (the other computer cancelled,
//! went quiet or took the rest from elsewhere), as `SZFriendsSyncExchange`'s `servingTransferID` says on the Mac.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use szfriends_core::transfer::BlockServe;

use super::State;

/// A serve that sent everything asked and heard nothing for this long has given what it was asked for (a computer
/// resuming a copy asks only for the blocks it misses, so its last HAVE may not cover the file).
const DONE_AFTER: Duration = Duration::from_secs(2);
/// A serve waiting on a HAVE this long: the other computer stopped the copy (or took the rest from elsewhere).
const QUIET_AFTER: Duration = Duration::from_secs(30);

/// A file this computer serves by blocks on one session: Get again for a friend, or a copy for our own device.
#[derive(Debug)]
pub struct Serving {
    pub serve: BlockServe,
    pub path: PathBuf,
    pub sync: bool,
    /// The tree's root, for BLOCKS FOLLOW sent again.
    pub root: [u8; 32],
    /// When the other side last asked for blocks or acknowledged some.
    heard_at: Instant,
    /// Whether the You row showed it at the last look (`serving_tick`).
    shown: bool,
}

impl Serving {
    pub fn new(serve: BlockServe, path: PathBuf, sync: bool, root: [u8; 32]) -> Self {
        Self { serve, path, sync, root, heard_at: Instant::now(), shown: sync }
    }

    /// The other side asked for blocks or acknowledged some.
    pub fn heard(&mut self) {
        self.heard_at = Instant::now();
    }

    /// How much of the file the other computer has from this serve, while the copy runs.
    fn copying(&self, now: Instant) -> Option<f64> {
        let quiet = now.saturating_duration_since(self.heard_at);
        let running =
            !self.serve.all_acknowledged() && quiet < if self.serve.busy() { QUIET_AFTER } else { DONE_AFTER };
        let size = self.serve.geometry().size;
        let have = size - self.serve.remaining_bytes();
        (self.sync && running).then(|| if size > 0 { have as f64 / size as f64 } else { 0.0 })
    }
}

impl State {
    /// You files being copied from here to another of the person's computers now, by transfer: how much of each
    /// that computer has. Streamed by the sync exchange, or served by blocks on its session.
    pub(crate) fn you_copying(&self) -> BTreeMap<String, f64> {
        let now = Instant::now();
        let streamed = self.devices.exchanges.values().filter_map(|e| e.serving()).map(|(t, f)| (t.to_owned(), f));
        let served = self.again.serving.iter().filter_map(|((_, t), s)| Some((t.clone(), s.copying(now)?)));
        streamed.chain(served).collect()
    }

    /// A copy that ended by going quiet leaves the You row (`copying` changes with time alone).
    pub(crate) fn serving_tick(&mut self) {
        let now = Instant::now();
        let mut flipped = false;
        for serving in self.again.serving.values_mut().filter(|s| s.sync) {
            let shown = serving.copying(now).is_some();
            flipped |= shown != serving.shown;
            serving.shown = shown;
        }
        if flipped {
            self.changed();
        }
    }
}
