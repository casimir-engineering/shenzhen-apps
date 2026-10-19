//! The responders' memory of message 1 ephemeral keys (`SZFriendsReplayCache`). IK and NN message 1 can be
//! replayed (Noise § 7.7): a responder records the initiator's ephemeral key once message 1 has decrypted, before its
//! payload or the key policy, and refuses one it already holds, so a captured message 1 reaches the policy once.
//! Entries last the replay window; past the capacity the oldest goes first.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use szfriends_wire::consts::REPLAY_WINDOW_SECONDS;

/// About 110 handshakes a second for 10 minutes.
pub const DEFAULT_CAPACITY: usize = 65_536;

type Clock = Box<dyn Fn() -> Duration + Send + Sync>;

struct Entries {
    seen_at: HashMap<[u8; 32], Duration>,
    order: VecDeque<[u8; 32]>,
}

/// Thread-safe; one per process ([`ReplayCache::shared`]) so every listener shares it.
pub struct ReplayCache {
    capacity: usize,
    clock: Clock,
    entries: Mutex<Entries>,
}

impl std::fmt::Debug for ReplayCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReplayCache").field("capacity", &self.capacity).field("count", &self.count()).finish()
    }
}

impl ReplayCache {
    /// `clock` counts time that keeps running during sleep; tests inject one.
    pub fn new(capacity: usize, clock: Option<Clock>) -> Self {
        Self {
            capacity: capacity.max(1),
            clock: clock.unwrap_or_else(|| Box::new(super::monotonic_now)),
            entries: Mutex::new(Entries { seen_at: HashMap::new(), order: VecDeque::new() }),
        }
    }

    /// The cache every responder uses unless given another.
    pub fn shared() -> Arc<ReplayCache> {
        static SHARED: OnceLock<Arc<ReplayCache>> = OnceLock::new();
        SHARED.get_or_init(|| Arc::new(ReplayCache::new(DEFAULT_CAPACITY, None))).clone()
    }

    /// `true`, recording it, when `ephemeral_key` has not been seen within the window; `false` for a repeat.
    pub fn record(&self, ephemeral_key: &[u8; 32]) -> bool {
        let now = (self.clock)();
        let window = Duration::from_secs(REPLAY_WINDOW_SECONDS);
        let mut entries = self.entries.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let Entries { seen_at, order } = &mut *entries;
        while let Some(oldest) = order.front() {
            if now.saturating_sub(seen_at[oldest]) < window {
                break;
            }
            seen_at.remove(oldest);
            order.pop_front();
        }
        if seen_at.contains_key(ephemeral_key) {
            return false;
        }
        while seen_at.len() >= self.capacity {
            if let Some(oldest) = order.pop_front() {
                seen_at.remove(&oldest);
            }
        }
        seen_at.insert(*ephemeral_key, now);
        order.push_back(*ephemeral_key);
        true
    }

    pub fn count(&self) -> usize {
        self.entries.lock().map(|entries| entries.seen_at.len()).unwrap_or(0)
    }
}
