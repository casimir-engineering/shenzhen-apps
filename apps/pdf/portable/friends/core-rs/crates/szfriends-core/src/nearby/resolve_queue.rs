//! Resolving one service at a time (ADR 0015 § 9, Android): before Android 14, `NsdManager` resolves one service at a
//! time and a second `resolveService` fails with `FAILURE_ALREADY_ACTIVE`, so the plugin's Kotlin side asks this queue
//! what to resolve next. Newest sighting first (the device that just appeared is the one the person is waiting for),
//! each resolve with a timeout, and a service lost while waiting is dropped. On Android 14 and later the plugin uses
//! `registerServiceInfoCallback`, which has no such limit, and does not use the queue. Pure: times are arguments.

use std::collections::VecDeque;

/// A resolve that has not answered in this long is given up and the next one starts.
pub const RESOLVE_TIMEOUT_SECONDS: f64 = 5.0;
/// Services remembered while waiting; beyond it the oldest sightings go (newer ones resolve first anyway).
pub const QUEUE_MAX: usize = 64;

/// What the platform side should do next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Next {
    /// Start resolving this service now.
    Resolve(String),
    /// Cancel the running resolve (it timed out), then ask again.
    Cancel(String),
    Idle,
}

/// See the module documentation.
#[derive(Debug, Default)]
pub struct ResolveQueue {
    /// Newest at the front.
    waiting: VecDeque<String>,
    active: Option<(String, f64)>,
}

impl ResolveQueue {
    /// A service was found (or found again): it goes to the front.
    pub fn found(&mut self, name: &str) {
        if self.active.as_ref().is_some_and(|(active, _)| active == name) {
            return;
        }
        self.waiting.retain(|n| n != name);
        self.waiting.push_front(name.to_owned());
        self.waiting.truncate(QUEUE_MAX);
    }

    /// A service went away: it is not resolved any more.
    pub fn lost(&mut self, name: &str) {
        self.waiting.retain(|n| n != name);
    }

    /// The running resolve answered, successfully or not.
    pub fn finished(&mut self, name: &str) {
        if self.active.as_ref().is_some_and(|(active, _)| active == name) {
            self.active = None;
        }
    }

    /// What to do now.
    pub fn next(&mut self, now: f64) -> Next {
        if let Some((name, started)) = &self.active {
            if now - started < RESOLVE_TIMEOUT_SECONDS {
                return Next::Idle;
            }
            let name = name.clone();
            self.active = None;
            return Next::Cancel(name);
        }
        match self.waiting.pop_front() {
            Some(name) => {
                self.active = Some((name.clone(), now));
                Next::Resolve(name)
            }
            None => Next::Idle,
        }
    }

    /// When to ask again while a resolve runs.
    pub fn deadline(&self) -> Option<f64> {
        self.active.as_ref().map(|(_, started)| started + RESOLVE_TIMEOUT_SECONDS)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_at_a_time_newest_first() {
        let mut q = ResolveQueue::default();
        q.found("a");
        q.found("b");
        assert_eq!(q.next(0.0), Next::Resolve("b".into()));
        q.found("c");
        assert_eq!(q.next(1.0), Next::Idle, "one resolve at a time");
        q.finished("b");
        assert_eq!(q.next(1.0), Next::Resolve("c".into()));
        q.lost("a");
        q.finished("c");
        assert_eq!(q.next(2.0), Next::Idle);
    }

    #[test]
    fn a_silent_resolve_times_out() {
        let mut q = ResolveQueue::default();
        q.found("a");
        q.found("b");
        assert_eq!(q.next(0.0), Next::Resolve("b".into()));
        assert_eq!(q.deadline(), Some(RESOLVE_TIMEOUT_SECONDS));
        assert_eq!(q.next(RESOLVE_TIMEOUT_SECONDS), Next::Cancel("b".into()));
        assert_eq!(q.next(RESOLVE_TIMEOUT_SECONDS), Next::Resolve("a".into()));
        q.found("a");
        assert_eq!(q.next(6.0), Next::Idle, "found again while resolving: not queued twice");
    }

    #[test]
    fn bounded() {
        let mut q = ResolveQueue::default();
        for i in 0..100 {
            q.found(&i.to_string());
        }
        assert_eq!(q.waiting.len(), QUEUE_MAX);
        assert_eq!(q.next(0.0), Next::Resolve("99".into()));
    }
}
