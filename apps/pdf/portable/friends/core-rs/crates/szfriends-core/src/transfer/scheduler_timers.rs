//! The scheduler's clock and what it answers (scheduler.rs): its timers (silent lanes, closing them, lane requests),
//! when it next needs the time, and its transfers' and lanes' state.

use super::*;

impl Scheduler {
    /// Timers: silent lanes, closing them, lane requests.
    pub fn tick(&mut self, now: Duration) {
        let ids: Vec<LaneId> = self.lanes.keys().copied().collect();
        for id in ids {
            let lane = &self.lanes[&id];
            let unheard = now.saturating_sub(lane.heard_at) >= lane.unheard_after();
            if !lane.silent
                && lane.in_flight > 0
                && (now.saturating_sub(lane.progress_at) >= lane.silent_after() || unheard)
            {
                self.go_silent(id);
            }
            let lane = self.lanes.get_mut(&id).expect("listed");
            if lane.silent
                && !lane.closing
                && lane.index != 0
                && now.saturating_sub(lane.heard_at) >= CLOSE_SILENT_AFTER
            {
                lane.closing = true;
                self.actions.push(Action::Lane(LaneRequest::Close { lane: id }));
            }
        }
        self.fill(now);
    }

    /// When [`Scheduler::tick`] has something to do next.
    pub fn next_timer(&self) -> Option<Duration> {
        self.lanes
            .values()
            .filter_map(|l| {
                if !l.silent && l.in_flight > 0 {
                    Some((l.progress_at + l.silent_after()).min(l.heard_at + l.unheard_after()))
                } else if l.silent && !l.closing && l.index != 0 {
                    Some(l.heard_at + CLOSE_SILENT_AFTER)
                } else {
                    None
                }
            })
            .min()
    }

    // ----- queries -----

    /// Every wanted block of `key` is in a HAVE.
    pub fn is_done(&self, key: TransferKey) -> bool {
        self.transfers.iter().find(|t| t.key == key).is_some_and(|t| t.wanted_count == 0)
    }

    /// § 3: blocks of `key` assigned and not complete, and their bytes.
    pub fn open(&self, key: TransferKey) -> (usize, u64) {
        self.transfers.iter().find(|t| t.key == key).map_or((0, 0), |t| (t.open.len(), t.open_bytes))
    }

    pub fn lane_stats(&self, lane: LaneId) -> Option<LaneStats> {
        self.lanes.get(&lane).map(|l| LaneStats {
            route: l.route,
            index: l.index,
            rate: l.rate,
            rtt: l.rtt,
            in_flight: l.in_flight,
            silent: l.silent,
            measured: l.measured,
        })
    }

    /// The most a lane may hold for blocks of `block_bytes`.
    pub fn lane_cap(&self, lane: LaneId, block_bytes: u64) -> u64 {
        self.lanes.get(&lane).map_or(0, |l| self.cap(l, block_bytes))
    }
}
