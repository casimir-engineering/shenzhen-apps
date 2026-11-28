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
//! is 1.5 until the rate stops growing, then ½ until the stack is empty, then it cycles 1.25, 0.75, 1, so the pace
//! keeps looking for a faster radio and gives back what each look queued. What the stack holds is the bytes handed
//! and not acknowledged, less what that was when the stack was last seen empty (a drain whose delivery fell to what
//! it handed): past a quarter of a second of the radio, or every few seconds, the gain is ½ again until the stack is
//! empty, which also keeps framing and messages (never acknowledged) from piling up in that count. A sample whose
//! delivery is low while the stack grows or still drains measured a slower radio, not an empty stack: it is the rate
//! from then on.
//!
//! Only PARTs are acknowledged, so only writes carrying them are held for acknowledgements: before the first one
//! [`FIRST_WINDOW`] of parts goes, and a link that gets none within [`FIRST_WAIT`] is not paced (what it carries is
//! not acknowledged). Once paced, parts stop while more than [`State::stall_cap`] of them went since the last
//! acknowledgement (the radio stalled: the pace holds its rate, the stack does not fill), and while the stack holds
//! more than its limit and a bucket (a slower radio's backlog drains first). A link held [`HOLD_MAX`] without one
//! carries parts that are not acknowledged: it is not paced until one comes, then paced again at its last rate. On a
//! slow radio the probing steps last as long as its samples, and two probing samples in a row well above the rate
//! start the gain at 1.5 again, so a radio that recovers is found in seconds.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use szfriends_core::transfer::frames;
use szfriends_core::wire::consts::PIECE_SHIFT;
use szfriends_core::wire::{tag, Frame, FrameType};

/// What the acknowledgements teach: delivery samples, the rate, and the phases they move.
mod samples;

/// The bucket is no deeper than what the radio carries in twice this long.
const STACK_TIME: Duration = Duration::from_millis(50);
/// Nor shallower than this: a part and its framing pass in one go.
const STACK_FLOOR: f64 = 8.0 * 1024.0;
/// A delivery-rate sample spans at least this long and this many acknowledgements.
const SAMPLE_MIN: Duration = Duration::from_millis(500);
const SAMPLE_ACKS: u32 = 2;
/// The rate is the highest sample this recent (or of about the last two probing cycles, when longer).
const RATE_WINDOW: Duration = Duration::from_secs(4);
/// Never slower than this, whatever was measured.
const RATE_FLOOR: f64 = 4_000.0;
/// The probing cycle: a quarter faster, a quarter slower, then even, for these long; on a slow radio the looks faster
/// and slower last as long as one of its samples (two acknowledgements).
const PROBE_UP: Duration = Duration::from_millis(400);
const PROBE_DOWN: Duration = Duration::from_millis(400);
const PROBE_CYCLE: Duration = Duration::from_millis(2400);
/// A probing sample this much above the rate looked faster (see [`State::faster`]).
const PROBE_FOUND: f64 = 1.2;
/// The stack may hold this much of the radio's time (beside [`STACK_FLOOR`]) before it is drained.
const QUEUE_LIMIT: Duration = Duration::from_millis(250);
/// And it is drained dry at least this often, which finds the count's zero again.
const EMPTY_EVERY: Duration = Duration::from_secs(30);
/// A drain ends when two samples in a row deliver under this share of the rate (the stack ran dry; one could be an
/// acknowledgement late), or after this long ([`State::drain_max`]: longer on a slow radio).
const EMPTY_SHARE: f64 = 0.7;
const DRAIN_MAX: Duration = Duration::from_secs(4);
/// A sample's delivery this far from what was handed meanwhile (and a piece) says the stack grew or drained: it was not
/// dry, so the delivery was the radio's.
const RADIO_LIMITED: f64 = 0.15;
/// The longest the writer sleeps before looking again.
const NAP: Duration = Duration::from_millis(20);
/// Before the first acknowledgement this many bytes of parts go at once; then the writer waits for one, at most
/// `FIRST_WAIT`, and a link that gets none by then is not paced until one comes (what it carries is not
/// acknowledged). Writes without parts never wait for one.
const FIRST_WINDOW: u64 = 32 * 1024;
const FIRST_WAIT: Duration = Duration::from_secs(1);
/// Parts after this long without one start a new burst, which the first acknowledgement times.
const BURST_GAP: Duration = Duration::from_secs(1);
/// One piece: what a HAVE's Pieces name.
const PIECE: f64 = (1u64 << PIECE_SHIFT) as f64;
/// Parts held this long with no acknowledgement are not acknowledged (Bluetooth's silence closes a session at 12 s).
const HOLD_MAX: Duration = Duration::from_secs(10);
/// While the backlog holds parts, acknowledgements that stop for this many of their recent spacings (and at least
/// [`ACK_TIMEOUT_MIN`], longer than a piece takes at 8 KB/s, so a radio that just slowed is not taken for a dry
/// stack) say the stack is dry after all: what the count still holds was never going to be acknowledged.
const ACK_TIMEOUT_SPACINGS: f64 = 3.0;
const ACK_TIMEOUT_MIN: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, PartialEq)]
enum Phase {
    /// No acknowledgement yet: [`FIRST_WINDOW`] goes, then the writer waits for one (since when).
    First { waiting: Option<Instant> },
    /// None came in time, or parts were held [`HOLD_MAX`]: not paced until one comes.
    Unpaced,
    /// Gain 1.5 until two samples in a row grow the rate by less than a quarter.
    Startup { flat: u8, best: f64 },
    /// Gain ½ until the stack runs dry (`dry`: until a sample's delivery falls, which marks the count's zero), or
    /// until it holds no more than the bucket.
    Drain { since: Instant, dry: bool, low: u8 },
    /// Gains 1.25, 0.75, 1 in turn.
    Probe { since: Instant },
}

/// A delivery-rate sample in progress.
#[derive(Clone, Copy, Debug)]
struct Sample {
    started: Instant,
    /// Bytes acknowledged, and handed, when it started.
    acked: u64,
    handed: u64,
    /// Acknowledgements since.
    acks: u32,
    /// A write waited for the bucket or the holds meanwhile (a sample with none measured the sender, not the radio).
    waited: bool,
    /// Parts were held for a stall meanwhile: what it measured is the stall, not the radio.
    stalled: bool,
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
    /// Bytes of parts handed, and how many that was at the last acknowledgement.
    parts: u64,
    parts_at_ack: u64,
    /// When the stack was last seen empty: bytes handed and not acknowledged then, bytes handed then, and when.
    empty: (u64, u64, Instant),
    /// The share of what is handed that is never acknowledged (framing, messages, a block's last piece, which only
    /// its Ranges complete), learned between two empty stacks.
    unacknowledged_share: f64,
    sample: Option<Sample>,
    /// What the bucket holds, as of `level_at`.
    level: f64,
    level_at: Instant,
    /// The first part of the current burst, which the first acknowledgement times, and the last.
    burst: Option<(Instant, Instant)>,
    /// The last acknowledgement, and the longest time between two lately (seconds, decaying).
    last_ack: Option<Instant>,
    ack_spacing: f64,
    /// Since when parts have been held for a stall.
    held: Option<Instant>,
    /// The last probing sample delivered well above the rate.
    faster: bool,
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
            parts: 0,
            parts_at_ack: 0,
            empty: (0, 0, now),
            unacknowledged_share: 0.02,
            sample: None,
            level: 0.0,
            level_at: now,
            burst: None,
            last_ack: None,
            ack_spacing: 0.0,
            held: None,
            faster: false,
        }))
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Before handing `length` bytes to the platform, `parts` of them PARTs ([`szfriends_core::session::LinkWrite::
    /// part_bytes`]): waits until the bucket has room for them, then counts them.
    pub fn wait_for_room(&self, length: usize, parts: usize) {
        loop {
            let wait = self.state().take(length, parts, Instant::now());
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
        let held = if state.held.is_some() { ", parts held for a stall" } else { "" };
        format!("{phase} at {:.1} KB/s × {:.2}, {:.1} KB in the stack{held}", state.rate / 1e3, state.gain(now), {
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
                let (up, down) = self.probe_steps();
                let cycle = up + down + (PROBE_CYCLE - PROBE_UP - PROBE_DOWN).as_secs_f64();
                let into = now.saturating_duration_since(since).as_secs_f64() % cycle;
                if into < up {
                    1.25
                } else if into < up + down {
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

    /// Counts `length` bytes (`parts` of them PARTs) as handed when the bucket has room and parts are not held, else
    /// says how long until it may.
    fn take(&mut self, length: usize, parts: usize, now: Instant) -> Option<Duration> {
        if parts > 0 {
            self.burst = match self.burst {
                Some((first, last)) if now.saturating_duration_since(last) < BURST_GAP => Some((first, now)),
                _ => Some((now, now)),
            };
        }
        if let Phase::First { waiting } = self.phase {
            if parts > 0 && self.parts > 0 && self.parts + parts as u64 > FIRST_WINDOW {
                let since = waiting.unwrap_or(now);
                if now.saturating_duration_since(since) < FIRST_WAIT {
                    self.phase = Phase::First { waiting: Some(since) };
                    return Some(NAP);
                }
                // FRIENDS-PROTOCOL-1: remove after 2027-06-30. A Friends protocol 1 Rust helper sends no piece HAVEs
                // for copies and pulls: the link goes unpaced.
                self.phase = Phase::Unpaced;
            }
        }
        self.drain_level(now);
        let room = (self.depth() - length as f64).max(0.0);
        if self.paced() && self.level > room {
            self.waited(false);
            return Some(Duration::from_secs_f64((self.level - room) / self.pace(now)));
        }
        if parts > 0 && self.paced() {
            if let Some(stalled) = self.holds(now) {
                self.waited(stalled);
                return Some(NAP);
            }
            self.held = None;
        }
        self.level += length as f64;
        self.handed += length as u64;
        self.parts += parts as u64;
        None
    }

    /// A write waited (for a stall, `stalled`): the sample in progress measures the radio, or nothing.
    fn waited(&mut self, stalled: bool) {
        if let Some(sample) = self.sample.as_mut() {
            sample.waited = true;
            sample.stalled |= stalled;
        }
    }

    /// Parts handed since the last acknowledgement beyond which the radio is taken to have stalled: two pieces (a
    /// block's last is acknowledged only by its Ranges) and what the stack may hold.
    fn stall_cap(&self) -> f64 {
        2.0 * PIECE + self.limit()
    }

    /// Whether parts wait now, and if so whether for a stall (`Some(true)`) or for the backlog (`Some(false)`).
    fn holds(&mut self, now: Instant) -> Option<bool> {
        // The radio stalled: parts went and nothing came back. The rate stays what it was; the stack does not fill.
        let unanswered = self.parts.saturating_sub(self.parts_at_ack) as f64;
        if unanswered > self.stall_cap() {
            let since = *self.held.get_or_insert(now);
            if now.saturating_duration_since(since) < HOLD_MAX {
                return Some(true);
            }
            // So long without one: what this link carries now is not acknowledged.
            self.phase = Phase::Unpaced;
            self.sample = None;
            self.held = None;
            return None;
        }
        // A slower radio's backlog drains before more parts join it, unless acknowledgements stopped with nothing
        // unanswered: then the stack is dry and the count held what is never acknowledged.
        if self.queued() > self.backlog() {
            let timeout = (ACK_TIMEOUT_SPACINGS * self.ack_spacing).max(ACK_TIMEOUT_MIN.as_secs_f64());
            let quiet = self.last_ack.map_or(0.0, |at| now.saturating_duration_since(at).as_secs_f64());
            if quiet < timeout {
                return Some(false);
            }
            if unanswered > 2.0 * PIECE {
                // Nothing came back for parts that went: a stall, as above.
                return Some(true);
            }
            self.mark_empty(now);
        }
        None
    }

    /// Beyond what the stack may hold and a bucket more, parts wait for it to drain ([`State::holds`]).
    fn backlog(&self) -> f64 {
        self.limit() + self.depth()
    }

    /// What the stack may hold before it is drained.
    fn limit(&self) -> f64 {
        self.rate * QUEUE_LIMIT.as_secs_f64() + STACK_FLOOR
    }
}
