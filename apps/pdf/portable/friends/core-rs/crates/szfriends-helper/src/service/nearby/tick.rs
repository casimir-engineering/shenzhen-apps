//! Nearby's periodic work (mod.rs): discovery windows that end, requests that expire, and when to look next.

use super::*;

impl State {
    /// Periodic nearby work, on every tick of the service's loop.
    pub fn nearby_tick(&mut self) {
        if self.nearby.shut_down {
            return;
        }
        let now = unix_now();
        for adapter in &mut self.nearby.adapters {
            adapter.tick();
        }
        if self.nearby.merger.next_expiry().is_some_and(|at| at <= now) && self.nearby.merger.expire(now) {
            self.candidates_changed();
        }
        let current = window(now);
        if current != self.nearby.window {
            self.window_ended(current);
        }
        if self.nearby.visibility.deadline().is_some() && !self.nearby.visibility.is_visible(Instant::now()) {
            // The deadline stops the public entry on every adapter at once.
            let _ = self.store.set_visibility_deadline(None);
            self.refresh_advertisement();
            self.changed();
        }
        if self.nearby.callback_refresh_at.is_some_and(|at| at <= now) {
            self.refresh_advertisement();
        }
        if now >= self.nearby.expire_at {
            self.nearby.expire_at = now + EXPIRE_REQUESTS_EVERY;
            self.expire_requests(now);
        }
        self.enforce_limits(now);
        self.relay_probe(now);
        self.start_staged_dials(now);
        if self.nearby.reconsider_at.is_some_and(|at| at <= now) {
            self.nearby.reconsider_at = None;
            self.reconsider();
        }
    }

    pub(super) fn window_ended(&mut self, current: i64) {
        self.nearby.window = current;
        self.rebuild_matcher();
        self.refresh_advertisement();
        let now = unix_now();
        self.nearby.attempts.retain(|_, until| *until >= now);
        // What strangers' public entries said is kept only while the merger still knows them.
        let present: HashSet<[u8; 32]> =
            self.nearby.merger.candidates().iter().filter_map(|c| c.identity_key).collect();
        self.nearby.public_profiles.retain(|key, _| present.contains(key));
    }

    pub(super) fn expire_requests(&mut self, now: f64) {
        let incoming = self.store.expire_incoming_requests(now).unwrap_or_default();
        let outgoing = self.store.expire_outgoing_requests(now).unwrap_or_default();
        if !incoming.is_empty() || !outgoing.is_empty() {
            self.people_changed();
        }
    }

    /// The next moment nearby has something to do.
    pub fn nearby_wakeup(&self) -> Option<f64> {
        let staged = self.nearby.staged.iter().map(|(due, _)| *due).min_by(f64::total_cmp);
        [self.nearby.reconsider_at, staged, self.nearby.merger.next_expiry(), self.relay_probe_wakeup()]
            .into_iter()
            .flatten()
            .min_by(f64::total_cmp)
    }
}
