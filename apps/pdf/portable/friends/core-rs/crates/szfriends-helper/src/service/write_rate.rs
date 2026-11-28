//! How fast a LAN or direct Wi-Fi link's writes leave, so its in-flight budget holds about a tenth of a second of them
//! (`sessions.rs`): enough that the link never idles while the service's thread is late for a pass, little enough
//! that a message queued now waits behind no more than that. A fixed 1 MiB, right for 24 MB/s, kept a message a
//! second behind file data on a 1 MB/s Wi-Fi link.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The budget holds this long of the link's writes, never less than `BUDGET_MIN` nor more than `BUDGET_MAX`.
const BUDGET_TIME: f64 = 0.1;
const BUDGET_MIN: usize = 256 * 1024;
const BUDGET_MAX: usize = 1024 * 1024;
/// A sample spans at least this long; the rate is the highest sample this recent.
const SAMPLE: Duration = Duration::from_millis(200);
const WINDOW: Duration = Duration::from_secs(2);
/// A writer that waited this long for its next write was idle: what follows starts a new sample.
pub const IDLE: Duration = Duration::from_millis(50);

#[derive(Debug, Default)]
pub struct WriteRate(Mutex<State>);

#[derive(Debug, Default)]
struct State {
    /// The current sample: when it started, and the bytes written since.
    sample: Option<(Instant, u64)>,
    samples: VecDeque<(Instant, f64)>,
}

impl WriteRate {
    /// `bytes` were written now, in a write taken from the queue at `started`; `idle`: the writer had waited for it.
    pub fn wrote(&self, bytes: usize, started: Instant, idle: bool) {
        let now = Instant::now();
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let (since, written) = match state.sample {
            Some(sample) if !idle => sample,
            _ => (started, 0),
        };
        let written = written + bytes as u64;
        let span = now.saturating_duration_since(since);
        if span < SAMPLE {
            state.sample = Some((since, written));
            return;
        }
        state.sample = Some((now, 0));
        state.samples.push_back((now, written as f64 / span.as_secs_f64()));
        while state.samples.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > WINDOW) {
            state.samples.pop_front();
        }
    }

    /// One write's size, a quarter of the budget: the largest before anything is measured.
    pub fn write_size(&self) -> usize {
        let state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let budget = match state.samples.iter().map(|(_, r)| *r).reduce(f64::max) {
            Some(rate) => ((rate * BUDGET_TIME) as usize).clamp(BUDGET_MIN, BUDGET_MAX),
            None => BUDGET_MAX,
        };
        budget / 4
    }
}
