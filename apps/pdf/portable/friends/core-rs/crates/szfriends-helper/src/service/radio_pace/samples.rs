//! What a Bluetooth link's acknowledgements teach its pace (`radio_pace.rs`): delivery-rate samples, the rate they
//! measure, and the phases they move it through.

use std::time::Instant;

use super::{
    Phase, Sample, State, DRAIN_MAX, EMPTY_EVERY, EMPTY_SHARE, PIECE, PROBE_CYCLE, PROBE_DOWN, PROBE_FOUND, PROBE_UP,
    RADIO_LIMITED, RATE_FLOOR, RATE_WINDOW, SAMPLE_ACKS, SAMPLE_MIN,
};

impl State {
    pub(super) fn acknowledged(&mut self, bytes: u64, now: Instant) {
        self.drain_level(now);
        self.acked += bytes.min(self.handed.saturating_sub(self.acked));
        self.parts_at_ack = self.parts;
        self.held = None;
        if let Some(last) = self.last_ack {
            let spacing = now.saturating_duration_since(last).as_secs_f64();
            self.ack_spacing = (0.8 * self.ack_spacing).max(spacing);
        }
        self.last_ack = Some(now);
        let fresh =
            Sample { started: now, acked: self.acked, handed: self.handed, acks: 0, waited: false, stalled: false };
        let Some(sample) = self.sample else {
            if self.phase == Phase::Unpaced && self.rate > 0.0 {
                // Paced before, until parts went unacknowledged too long: paced again at the last rate, the stack
                // drained first.
                self.phase = Phase::Drain { since: now, dry: true, low: 0 };
                self.level = 0.0;
                self.level_at = now;
            } else {
                self.first_acknowledgement(now);
            }
            self.sample = Some(fresh);
            return;
        };
        let acks = sample.acks + 1;
        let span = now.saturating_duration_since(sample.started);
        if span < SAMPLE_MIN || acks < SAMPLE_ACKS {
            self.sample = Some(Sample { acks, ..sample });
            return;
        }
        self.sample = Some(fresh);
        if sample.stalled {
            // It spans a stall: it measured the stall, not the radio.
            return;
        }
        // In bytes handed: what is never acknowledged crossed the radio too.
        let seconds = span.as_secs_f64();
        let rate = (self.acked - sample.acked) as f64 / seconds / (1.0 - self.unacknowledged_share);
        let handed = self.handed.saturating_sub(sample.handed) as f64 / seconds;
        self.sampled(rate, handed, seconds, !sample.waited, now);
    }

    /// The first acknowledgement: the link is paced from now on, at what crossed since the first part (a round trip
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

    /// The longest a drain lasts: [`DRAIN_MAX`], or two samples' worth of acknowledgements on a slow radio.
    fn drain_max(&self) -> f64 {
        DRAIN_MAX.as_secs_f64().max(2.5 * SAMPLE_ACKS as f64 * self.ack_spacing)
    }

    /// How long the probing cycle's looks faster and slower last (seconds): on a slow radio, as long as its sample.
    pub(super) fn probe_steps(&self) -> (f64, f64) {
        let sample = SAMPLE_ACKS as f64 * PIECE / self.rate.max(RATE_FLOOR);
        (PROBE_UP.as_secs_f64().max(sample), PROBE_DOWN.as_secs_f64().max(sample))
    }

    /// The radio is slower: `rate` from now on, without the faster samples before it.
    fn slower(&mut self, rate: f64, now: Instant) {
        self.rate = rate.max(RATE_FLOOR);
        self.samples.clear();
        self.samples.push_back((now, rate));
    }

    /// A sample of `seconds`: `rate` delivered, `handed` handed meanwhile (bytes a second).
    fn sampled(&mut self, rate: f64, handed: f64, seconds: f64, limited_by_sender: bool, now: Instant) {
        if !limited_by_sender || rate > self.rate {
            self.samples.push_back((now, rate));
        }
        let (up, down) = self.probe_steps();
        let window = RATE_WINDOW.as_secs_f64().max(2.0 * (up + down) + PROBE_CYCLE.as_secs_f64());
        while self.samples.front().is_some_and(|(at, _)| now.saturating_duration_since(*at).as_secs_f64() > window) {
            self.samples.pop_front();
        }
        let measured = self.samples.iter().map(|(_, r)| *r).reduce(f64::max);
        let low = rate < EMPTY_SHARE * self.rate;
        // Delivery under what was handed (the stack grew), or over it with the stack still holding a backlog (it
        // drained, and is not dry yet): the delivery was the radio's. A sample with no write waiting measured the
        // sender.
        // By more than a piece, the grain of acknowledgements.
        let apart = (RADIO_LIMITED * handed).max(PIECE / seconds);
        let grew = rate < handed - apart;
        let drained = rate > handed + apart && self.queued() > self.limit();
        let radio_limited = !limited_by_sender && (grew || drained);
        // The stack ran dry: a drain's delivery fell to what it handed with little left in the count, or the sender
        // left it near empty. (A low delivery with a backlog counted is a slower radio, which the holds bring out.)
        let dry = (low && !radio_limited && self.queued() <= self.backlog())
            || (limited_by_sender && self.queued() <= self.depth());
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
            Phase::Drain { since, dry: until_dry, low: lows } => {
                if low && radio_limited {
                    // Not an empty stack: a slower radio. The drain goes on at its pace.
                    self.slower(rate, now);
                    self.phase = Phase::Drain { since: now, dry: until_dry, low: 0 };
                    return;
                }
                // While draining the delivery falls only once the stack is dry, so the rate stays what it was.
                let lows = if dry { lows + 1 } else { 0 };
                self.phase = Phase::Drain { since, dry: until_dry, low: lows };
                if lows >= 2 || (dry && limited_by_sender) {
                    self.mark_empty(now);
                    self.phase = Phase::Probe { since: now };
                } else if (!until_dry && self.queued() <= self.depth())
                    || now.saturating_duration_since(since).as_secs_f64() > self.drain_max()
                {
                    self.phase = Phase::Probe { since: now };
                }
            }
            Phase::Probe { .. } => {
                if low && radio_limited && grew {
                    // The stack grows at this pace: the radio slowed. Its backlog drains first.
                    self.slower(rate, now);
                    self.phase = Phase::Drain { since: now, dry: false, low: 0 };
                    return;
                }
                // Two samples in a row well above the rate, the stack not growing: a faster radio, found again at
                // gain 1.5 rather than a quarter per probing cycle.
                let faster = !limited_by_sender && !grew && rate >= PROBE_FOUND * self.rate;
                let found = faster && self.faster;
                self.faster = faster;
                self.rate = measured.unwrap_or(self.rate).max(RATE_FLOOR);
                if found && self.queued() <= self.limit() {
                    self.faster = false;
                    self.phase = Phase::Startup { flat: 0, best: self.rate };
                } else if limited_by_sender && self.queued() <= self.depth() {
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
