//! "Make myself visible for 5 minutes" (`SZFriendsVisibility.m`; PROTOCOL.md start_visibility). The deadline is
//! absolute: expiry, sleep, wake, disabling and restarting never extend it, and repeating start does not either.
//! Two clocks guard it: wall time, which the store keeps across restarts, and a continuous clock that counts sleep and
//! cannot be set back, so setting the computer's clock back cannot buy time.

use std::time::Duration;

pub const VISIBILITY_SECONDS: f64 = 300.0;

/// Two readings of one moment.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Instant {
    /// Unix seconds.
    pub wall: f64,
    /// A clock that keeps counting during sleep ([`crate::session::monotonic_now`]).
    pub continuous: Duration,
}

impl Instant {
    pub fn now() -> Self {
        Self { wall: crate::store::unix_now(), continuous: crate::session::monotonic_now() }
    }
}

/// See the module documentation.
#[derive(Clone, Debug, Default)]
pub struct Visibility {
    /// Unix seconds; `None` when hidden.
    deadline: Option<f64>,
    /// `None` for a deadline restored from the store, which only the wall clock can check.
    continuous_deadline: Option<Duration>,
}

impl Visibility {
    /// From the store's deadline: one already past, or further away than 5 minutes (the clock was set back since it
    /// was stored), is dropped at once. Visibility fails closed.
    pub fn restored(stored: Option<f64>, now: Instant) -> Self {
        let deadline = stored.filter(|d| {
            let remaining = d - now.wall;
            remaining > 0.0 && remaining <= VISIBILITY_SECONDS
        });
        Self { deadline, continuous_deadline: None }
    }

    /// Visible for 5 minutes from now, or the running deadline unchanged; the deadline to store and report.
    pub fn start(&mut self, now: Instant) -> f64 {
        if !self.is_visible(now) {
            self.deadline = Some(now.wall + VISIBILITY_SECONDS);
            self.continuous_deadline = Some(now.continuous + Duration::from_secs_f64(VISIBILITY_SECONDS));
        }
        self.deadline.expect("set above or still running")
    }

    pub fn stop(&mut self) {
        self.deadline = None;
        self.continuous_deadline = None;
    }

    /// Checks both clocks; once either says the 5 minutes are over, the deadline is cleared.
    pub fn is_visible(&mut self, now: Instant) -> bool {
        let Some(deadline) = self.deadline else { return false };
        let wall_over = now.wall >= deadline;
        let continuous_over = self.continuous_deadline.is_some_and(|d| now.continuous >= d);
        // A wall clock moved back below the start leaves more than 5 minutes "remaining": over too.
        let implausible = deadline - now.wall > VISIBILITY_SECONDS;
        if wall_over || continuous_over || implausible {
            self.stop();
            return false;
        }
        true
    }

    /// Seconds left; 0 when hidden.
    pub fn remaining(&mut self, now: Instant) -> f64 {
        if !self.is_visible(now) {
            return 0.0;
        }
        let mut remaining = self.deadline.expect("visible") - now.wall;
        if let Some(continuous) = self.continuous_deadline {
            remaining = remaining.min(continuous.saturating_sub(now.continuous).as_secs_f64());
        }
        remaining.max(0.0)
    }

    /// The deadline to store; reflects the last check.
    pub fn deadline(&self) -> Option<f64> {
        self.deadline
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(wall: f64, continuous: u64) -> Instant {
        Instant { wall, continuous: Duration::from_secs(continuous) }
    }

    #[test]
    fn five_minutes_never_extended() {
        let mut v = Visibility::default();
        assert_eq!(v.start(at(1000.0, 50)), 1300.0);
        assert_eq!(v.start(at(1100.0, 150)), 1300.0, "repeating does not extend");
        assert!(v.is_visible(at(1299.0, 349)));
        assert!(!v.is_visible(at(1300.0, 350)));
        assert_eq!(v.deadline(), None);
    }

    #[test]
    fn setting_the_clock_back_buys_nothing() {
        let mut v = Visibility::default();
        v.start(at(1000.0, 50));
        assert!(!v.is_visible(at(990.0, 360)), "the continuous clock ran out");
        let mut w = Visibility::default();
        w.start(at(1000.0, 50));
        assert!(!w.is_visible(at(900.0, 60)), "a wall clock before the start is implausible");
    }

    #[test]
    fn restored_deadlines_fail_closed() {
        assert_eq!(Visibility::restored(Some(1200.0), at(1000.0, 0)).deadline(), Some(1200.0));
        assert_eq!(Visibility::restored(Some(900.0), at(1000.0, 0)).deadline(), None);
        assert_eq!(Visibility::restored(Some(1400.0), at(1000.0, 0)).deadline(), None);
        let mut v = Visibility::restored(Some(1200.0), at(1000.0, 0));
        assert!((v.remaining(at(1100.0, 0)) - 100.0).abs() < 1e-9);
    }
}
