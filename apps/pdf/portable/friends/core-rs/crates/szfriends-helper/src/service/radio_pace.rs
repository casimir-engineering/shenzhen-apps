//! A Bluetooth link's own pace: bytes go to the platform's channel only as fast as the radio carries them, so what
//! waits for the radio waits in the session's queues, where a message, an ask or a HAVE overtakes file data.
//!
//! WHY: an Android phone's Bluetooth stack takes 170 to 236 KB/s into an L2CAP channel while its radio carries 43 to
//! 98 (measured 2026-11-28, a POCO F7 and a MacBook Pro): the stack's queue grew by a megabyte in four seconds, and
//! every control frame written after it waited twenty seconds behind it. Nothing on the platform says how much the
//! stack holds, so the pace is learned from the friend's acknowledgements: on Bluetooth the receiver sends a HAVE
//! naming each 16 KiB piece as it arrives (ADR 0018 § 3), and the rate those come back at is the rate the radio
//! carries.
//!
//! A token bucket at `gain × rate`, no deeper than twice what the radio carries in 50 ms (never less than one write),
//! sits in front of the platform. The rate is the highest delivery rate measured over the last few seconds. The gain
//! is 2 until the rate stops growing, then ½ until the stack is empty, then it cycles 1.25, 0.75, 1, so the pace keeps
//! looking for a faster radio and gives back what each look queued. What the stack holds is the bytes handed and not
//! acknowledged, less what that was when the stack was last seen empty (a drain whose delivery fell to its pace): past
//! a quarter of a second of the radio, or every few seconds, the gain is ½ again until the stack is empty, which also
//! keeps framing and messages (never acknowledged) from piling up in that count. Before the first acknowledgement the
//! link is not paced (it may carry nothing that is acknowledged), and while none come back for a few seconds although
//! writes wait, the pace grows by a quarter a second, so a peer that never acknowledges is held back only briefly.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use szfriends_core::transfer::frames;
use szfriends_core::wire::consts::PIECE_SHIFT;
use szfriends_core::wire::{tag, Frame, FrameType};

/// The bucket is no deeper than what the radio carries in twice this long.
const STACK_TIME: Duration = Duration::from_millis(50);
/// Nor shallower than this: a part and its framing pass in one go.
const STACK_FLOOR: f64 = 8.0 * 1024.0;
/// A delivery-rate sample spans at least this long and this many acknowledgements.
const SAMPLE_MIN: Duration = Duration::from_millis(500);
const SAMPLE_ACKS: u32 = 2;
/// The rate is the highest sample this recent.
const RATE_WINDOW: Duration = Duration::from_secs(4);
/// Without an acknowledgement this long while writes wait, the pace grows by a quarter every second.
const STALE: Duration = Duration::from_secs(3);
/// Never slower than this, whatever was measured.
const RATE_FLOOR: f64 = 4_000.0;
/// Nor faster when it grows blind.
const RATE_CEILING: f64 = 50e6;
/// The probing cycle: a quarter faster, a quarter slower, then even, for these long.
const PROBE_UP: Duration = Duration::from_millis(400);
const PROBE_DOWN: Duration = Duration::from_millis(400);
const PROBE_CYCLE: Duration = Duration::from_millis(2400);
/// The stack may hold this much of the radio's time (beside [`STACK_FLOOR`]) before it is drained.
const QUEUE_LIMIT: Duration = Duration::from_millis(250);
/// And it is drained dry at least this often, which finds the count's zero again.
const EMPTY_EVERY: Duration = Duration::from_secs(30);
/// A drain ends when two samples in a row deliver under this share of the rate (the stack ran dry; one could be an
/// acknowledgement late), or after this long.
const EMPTY_SHARE: f64 = 0.7;
const DRAIN_MAX: Duration = Duration::from_secs(4);
/// The longest the writer sleeps before looking again.
const NAP: Duration = Duration::from_millis(20);
/// Before the first acknowledgement this much goes at once; then the writer waits for one, at most `FIRST_WAIT`, and
/// a link that gets none by then is not paced until one comes (what it carries is not acknowledged).
const FIRST_WINDOW: u64 = 32 * 1024;
const FIRST_WAIT: Duration = Duration::from_secs(1);
/// Writes after this long without one start a new burst, which the first acknowledgement times.
const BURST_GAP: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, PartialEq)]
enum Phase {
    /// No acknowledgement yet: [`FIRST_WINDOW`] goes, then the writer waits for one (since when).
    First { waiting: Option<Instant> },
    /// None came in time: not paced until one does.
    Unpaced,
    /// Gain 2 until two samples in a row grow the rate by less than a quarter.
    Startup { flat: u8, best: f64 },
    /// Gain ½ until the stack runs dry (`dry`: until a sample's delivery falls, which marks the count's zero), or
    /// until it holds no more than the bucket.
    Drain { since: Instant, dry: bool, low: u8 },
    /// Gains 1.25, 0.75, 1 in turn.
    Probe { since: Instant },
}

#[derive(Debug)]
struct State {
    phase: Phase,
    /// The radio's rate as measured, bytes a second.
    rate: f64,
    samples: VecDeque<(Instant, f64)>,
    /// Bytes handed to the platform, and the friend's acknowledgements (never more than were handed).
    handed: u64,
    acked: u64,
    /// When the stack was last seen empty: bytes handed and not acknowledged then, bytes handed then, and when.
    empty: (u64, u64, Instant),
    /// The share of what is handed that is never acknowledged (framing, messages, a block's last piece, which only
    /// its Ranges complete), learned between two empty stacks.
    unacknowledged_share: f64,
    /// The current sample: when it started, the bytes acknowledged then, acknowledgements since, and whether a write
    /// waited for the bucket meanwhile (a sample with no write waiting measured the sender, not the radio).
    sample: Option<(Instant, u64, u32, bool)>,
    /// What the bucket holds, as of `level_at`.
    level: f64,
    level_at: Instant,
    /// Since when writes have waited for the bucket with no acknowledgement in between.
    quiet_since: Option<Instant>,
    last_growth: Instant,
    /// The first write of the current burst, which the first acknowledgement times, and the last write.
    burst: Option<(Instant, Instant)>,
}

/// One Bluetooth link's pace, shared by the link's writer (which waits on it) and the service's thread (which hears
/// the acknowledgements).
#[derive(Debug)]
pub struct RadioPace(Mutex<State>);

impl Default for RadioPace {
    fn default() -> Self {
        Self::new()
    }
}

/// The bytes a HAVE acknowledges piece by piece (its Pieces; its Ranges only complete what those named).
pub fn have_bytes(frame: &Frame) -> u64 {
    if frame.frame_type != FrameType::Have {
        return 0;
    }
    let pieces = frames::ranges_of(frame, tag::PIECES).unwrap_or_default();
    pieces.iter().map(|&(_, count)| u64::from(count) << PIECE_SHIFT).sum()
}

impl RadioPace {
    pub fn new() -> Self {
        let now = Instant::now();
        Self(Mutex::new(State {
            phase: Phase::First { waiting: None },
            rate: 0.0,
            samples: VecDeque::new(),
            handed: 0,
            acked: 0,
            empty: (0, 0, now),
            unacknowledged_share: 0.02,
            sample: None,
            level: 0.0,
            level_at: now,
            quiet_since: None,
            last_growth: now,
            burst: None,
        }))
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Before handing `length` bytes to the platform: waits until the bucket has room for them, then counts them.
    pub fn wait_for_room(&self, length: usize) {
        loop {
            let wait = self.state().take(length, Instant::now());
            match wait {
                None => return,
                Some(wait) => std::thread::sleep(wait.min(NAP)),
            }
        }
    }

    /// The friend acknowledged `bytes` (a HAVE's pieces).
    pub fn acknowledged(&self, bytes: u64) {
        if bytes > 0 {
            self.state().acknowledged(bytes, Instant::now());
        }
    }

    /// The pace as a log line shows it: phase, rate and gain, and what the stack is thought to hold.
    pub fn describe(&self) -> String {
        let mut state = self.state();
        let now = Instant::now();
        state.drain_level(now);
        let phase = match state.phase {
            Phase::First { .. } => "first",
            Phase::Unpaced => "unpaced",
            Phase::Startup { .. } => "startup",
            Phase::Drain { .. } => "drain",
            Phase::Probe { .. } => "probe",
        };
        format!("{phase} at {:.1} KB/s × {:.2}, {:.1} KB in the stack", state.rate / 1e3, state.gain(now), {
            state.queued() / 1e3
        })
    }
}

impl State {
    fn gain(&self, now: Instant) -> f64 {
        match self.phase {
            Phase::First { .. } | Phase::Unpaced => f64::INFINITY,
            Phase::Startup { .. } => 1.5,
            Phase::Drain { .. } => 0.5,
            Phase::Probe { since } => {
                let into = now.saturating_duration_since(since).as_secs_f64() % PROBE_CYCLE.as_secs_f64();
                let into = Duration::from_secs_f64(into);
                if into < PROBE_UP {
                    1.25
                } else if into < PROBE_UP + PROBE_DOWN {
                    0.75
                } else {
                    1.0
                }
            }
        }
    }

    fn pace(&self, now: Instant) -> f64 {
        (self.rate * self.gain(now)).max(RATE_FLOOR)
    }

    fn depth(&self) -> f64 {
        (2.0 * self.rate * STACK_TIME.as_secs_f64()).max(STACK_FLOOR)
    }

    /// Bytes thought to wait in the stack (and on the air): handed and not acknowledged, beyond what that was when it
    /// was last empty.
    fn queued(&self) -> f64 {
        let since = self.handed.saturating_sub(self.empty.1) as f64 * self.unacknowledged_share;
        (self.handed.saturating_sub(self.acked).saturating_sub(self.empty.0) as f64 - since).max(0.0)
    }

    /// The stack is empty now: what is not acknowledged is what never will be, which teaches its share.
    fn mark_empty(&mut self, now: Instant) {
        let unacknowledged = self.handed.saturating_sub(self.acked);
        let handed = self.handed.saturating_sub(self.empty.1);
        if handed > 256 * 1024 {
            let share = unacknowledged.saturating_sub(self.empty.0) as f64 / handed as f64;
            self.unacknowledged_share = (self.unacknowledged_share + share.clamp(0.0, 0.1)) / 2.0;
        }
        self.empty = (unacknowledged, self.handed, now);
    }

    fn paced(&self) -> bool {
        !matches!(self.phase, Phase::First { .. } | Phase::Unpaced)
    }

    fn drain_level(&mut self, now: Instant) {
        if !self.paced() {
            self.level = 0.0;
        } else {
            let seconds = now.saturating_duration_since(self.level_at).as_secs_f64();
            self.level = (self.level - seconds * self.pace(now)).max(0.0);
        }
        self.level_at = now;
    }

    /// Counts `length` bytes as handed when the bucket has room, else says how long until it may.
    fn take(&mut self, length: usize, now: Instant) -> Option<Duration> {
        self.burst = match self.burst {
            Some((first, last)) if now.saturating_duration_since(last) < BURST_GAP => Some((first, now)),
            _ => Some((now, now)),
        };
        if let Phase::First { waiting } = self.phase {
            if self.handed > 0 && self.handed + length as u64 > FIRST_WINDOW {
                let since = waiting.unwrap_or(now);
                if now.saturating_duration_since(since) < FIRST_WAIT {
                    self.phase = Phase::First { waiting: Some(since) };
                    return Some(NAP);
                }
                self.phase = Phase::Unpaced;
            }
        }
        self.drain_level(now);
        let length = length as f64;
        let room = (self.depth() - length).max(0.0);
        if self.paced() && self.level > room {
            if let Some(sample) = self.sample.as_mut() {
                sample.3 = true;
            }
            self.quiet_since.get_or_insert(now);
            self.grow_blind(now);
            return Some(Duration::from_secs_f64((self.level - room) / self.pace(now)));
        }
        if self.level == 0.0 {
            // The bucket was empty: the sender, not the pace, held this link back.
            self.quiet_since = None;
        }
        self.level += length;
        self.handed += length as u64;
        None
    }

    /// Writes have waited a while with no acknowledgement: what is sent now is not acknowledged (or the route is
    /// silent), so the pace grows by a quarter a second instead of holding the link to an old rate.
    fn grow_blind(&mut self, now: Instant) {
        let Some(quiet) = self.quiet_since else { return };
        if now.saturating_duration_since(quiet) < STALE || now.saturating_duration_since(self.last_growth).as_secs() < 1
        {
            return;
        }
        self.last_growth = now;
        self.rate = (self.rate * 1.25).min(RATE_CEILING);
        self.samples.clear();
        self.phase = Phase::Probe { since: now };
        self.empty = (self.handed.saturating_sub(self.acked), self.handed, now);
    }

    fn acknowledged(&mut self, bytes: u64, now: Instant) {
        self.drain_level(now);
        self.acked += bytes.min(self.handed.saturating_sub(self.acked));
        self.quiet_since = None;
        let Some((started, from, acks, waited)) = self.sample else {
            self.first_acknowledgement(now);
            self.sample = Some((now, self.acked, 0, false));
            return;
        };
        let acks = acks + 1;
        let span = now.saturating_duration_since(started);
        if span < SAMPLE_MIN || acks < SAMPLE_ACKS {
            self.sample = Some((started, from, acks, waited));
            return;
        }
        self.sample = Some((now, self.acked, 0, false));
        // In bytes handed: what is never acknowledged crossed the radio too.
        let rate = (self.acked - from) as f64 / span.as_secs_f64() / (1.0 - self.unacknowledged_share);
        self.sampled(rate, !waited, now);
    }

    /// The first acknowledgement: the link is paced from now on, at what crossed since the first write (a round trip
    /// too long, so a little slow). What went unpaced meanwhile may fill the stack: it drains first.
    fn first_acknowledgement(&mut self, now: Instant) {
        let first = self.burst.map_or(now, |(first, _)| first);
        let since = now.saturating_duration_since(first).as_secs_f64().max(0.01);
        self.rate = (self.acked as f64 / since).max(RATE_FLOOR);
        self.empty = (0, 0, now);
        self.phase = if self.queued() > self.limit() {
            Phase::Drain { since: now, dry: true, low: 0 }
        } else {
            Phase::Startup { flat: 0, best: self.rate }
        };
        self.level = 0.0;
        self.level_at = now;
    }

    /// What the stack may hold before it is drained.
    fn limit(&self) -> f64 {
        self.rate * QUEUE_LIMIT.as_secs_f64() + STACK_FLOOR
    }

    fn sampled(&mut self, rate: f64, limited_by_sender: bool, now: Instant) {
        if !limited_by_sender || rate > self.rate {
            self.samples.push_back((now, rate));
        }
        while self.samples.front().is_some_and(|(at, _)| now.saturating_duration_since(*at) > RATE_WINDOW) {
            self.samples.pop_front();
        }
        let measured = self.samples.iter().map(|(_, r)| *r).reduce(f64::max);
        // The stack ran dry: a drain's delivery fell towards its pace, or the sender left it near empty.
        let dry = rate < EMPTY_SHARE * self.rate || (limited_by_sender && self.queued() <= self.depth());
        match self.phase {
            Phase::First { .. } | Phase::Unpaced => {}
            Phase::Startup { flat, best } => {
                self.rate = measured.unwrap_or(self.rate).max(RATE_FLOOR);
                self.phase = if self.rate >= best * 1.25 {
                    Phase::Startup { flat: 0, best: self.rate }
                } else if flat >= 1 {
                    Phase::Drain { since: now, dry: true, low: 0 }
                } else {
                    Phase::Startup { flat: flat + 1, best }
                };
            }
            Phase::Drain { since, dry: until_dry, low } => {
                // While draining the delivery falls only once the stack is dry, so the rate stays what it was.
                let low = if dry { low + 1 } else { 0 };
                self.phase = Phase::Drain { since, dry: until_dry, low };
                if low >= 2 || (dry && limited_by_sender) {
                    self.mark_empty(now);
                    self.phase = Phase::Probe { since: now };
                } else if (!until_dry && self.queued() <= self.depth())
                    || now.saturating_duration_since(since) > DRAIN_MAX
                {
                    self.phase = Phase::Probe { since: now };
                }
            }
            Phase::Probe { .. } => {
                self.rate = measured.unwrap_or(self.rate).max(RATE_FLOOR);
                if limited_by_sender && self.queued() <= self.depth() {
                    self.mark_empty(now);
                } else if now.saturating_duration_since(self.empty.2) > EMPTY_EVERY {
                    self.phase = Phase::Drain { since: now, dry: true, low: 0 };
                } else if self.queued() > self.limit() {
                    self.phase = Phase::Drain { since: now, dry: false, low: 0 };
                }
            }
        }
    }
}
