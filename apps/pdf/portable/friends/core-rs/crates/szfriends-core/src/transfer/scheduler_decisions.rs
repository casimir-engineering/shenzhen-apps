//! The scheduler's decisions (scheduler.rs's rules): when a lane is silent, a lane's room, where the next block goes,
//! the endgame's second copies, which lanes to ask for, and what a silent lane gives back.

use super::*;

impl Lane {
    pub(super) fn eta(&self, bytes: u64) -> f64 {
        (self.in_flight + bytes) as f64 / self.rate + self.rtt.as_secs_f64()
    }

    pub(super) fn silent_after(&self) -> Duration {
        let floor = if self.route == RouteMethod::Bluetooth { SILENT_AFTER_BLUETOOTH } else { SILENT_AFTER };
        floor.max(self.rtt * 3)
    }

    /// Silent by what it hears: both ends of a fast session ping every second while a file moves (ADR 0018 § 7), so
    /// a lane holding blocks that hears nothing for this long has lost its route, however long its measured round
    /// trip (a deep buffer in the path inflates that, and with it `silent_after`).
    pub(super) fn unheard_after(&self) -> Duration {
        if self.route == RouteMethod::Bluetooth {
            UNHEARD_AFTER_BLUETOOTH
        } else {
            UNHEARD_AFTER
        }
    }

    pub(super) fn working(&self) -> bool {
        !self.silent && !self.closing && !self.unused
    }

    /// The route still reaches the peer: open, and something heard from it lately (both ends ping every second while
    /// a file moves). A lane that is only slow, or held up behind parts it no longer needs, reaches; one out of range
    /// or cut does not. While a direct lane reaches, the relay carries nothing (ADR 0020).
    pub(super) fn reaches(&self, now: Duration) -> bool {
        !self.closing && !self.unused && now.saturating_sub(self.heard_at) < self.unheard_after()
    }

    pub(super) fn sample_rate(&mut self, now: Duration, rate: f64) {
        self.rates.push_back((now, rate.min(1e11)));
        while self.rates.front().is_some_and(|(t, _)| now.saturating_sub(*t) > SAMPLE_WINDOW) {
            self.rates.pop_front();
        }
        self.rate = self.rates.iter().map(|(_, r)| *r).fold(1e3, f64::max);
        self.measured = true;
    }

    pub(super) fn sample_rtt(&mut self, now: Duration, rtt: Duration) {
        self.rtts.push_back((now, rtt));
        while self.rtts.front().is_some_and(|(t, _)| now.saturating_sub(*t) > SAMPLE_WINDOW) {
            self.rtts.pop_front();
        }
        self.rtt = self.rtts.iter().map(|(_, r)| *r).min().unwrap_or(rtt);
    }
}

impl Scheduler {
    // ----- the decisions -----

    pub(super) fn cap(&self, lane: &Lane, block_bytes: u64) -> u64 {
        let mut max = if self.config.phone { LANE_BYTES_MAX_PHONE } else { LANE_BYTES_MAX };
        let fastest = self.lanes.values().filter(|l| l.working()).map(|l| l.rate).fold(0.0, f64::max);
        if lane.rate < fastest {
            max = max.min(((fastest * SLOWER_LANE_SECONDS) as u64).max(block_bytes));
        }
        let bdp2 = (2.0 * lane.rate * lane.rtt.as_secs_f64()) as u64;
        // A lane beside a faster one that needs longer than a second per block (Bluetooth beside a slow LAN: 6 s per
        // MiB) holds one: a second one queued behind it would push its expected finish past what the faster lanes
        // need for the rest, so it would stop taking blocks early, while the round trip a second block saves is a
        // small part of a block's time on it (WP3, measured: Bluetooth's share of its rate 68 % with two, see the
        // journal).
        let faster = self.lanes.values().any(|l| l.working() && l.rate > lane.rate * 2.0);
        let slow = faster && block_bytes as f64 / lane.rate.max(1.0) > SLOW_BLOCK_SECONDS;
        let blocks = if slow { 1 } else { 2 };
        bdp2.max(blocks * block_bytes).min(max)
    }

    pub(super) fn room(&self, lane: &Lane, bytes: u64, block_bytes: u64) -> bool {
        lane.in_flight == 0 || lane.in_flight + bytes <= self.cap(lane, block_bytes)
    }

    pub(super) fn unassigned_bytes(&self) -> u64 {
        self.transfers.iter().map(|t| t.unassigned.iter().map(|&b| t.bytes(b)).sum::<u64>()).sum()
    }

    /// Lanes that may take blocks now: working ones; the relay only when no direct lane reaches the peer (ADR 0020);
    /// Bluetooth only alone or while the others measure below 4 MB/s together; none under 3 % of the fastest.
    pub(super) fn eligible(&self, now: Duration) -> Vec<LaneId> {
        let working: Vec<(&LaneId, &Lane)> = self.lanes.iter().filter(|(_, l)| l.working()).collect();
        let lanes = if self.direct_reaches(now) {
            working.into_iter().filter(|(_, l)| l.route != RouteMethod::Relay).collect()
        } else {
            working
        };
        let others: f64 = lanes.iter().filter(|(_, l)| l.route != RouteMethod::Bluetooth).map(|(_, l)| l.rate).sum();
        let only_bluetooth = lanes.iter().all(|(_, l)| l.route == RouteMethod::Bluetooth);
        let fastest = lanes.iter().map(|(_, l)| l.rate).fold(0.0, f64::max);
        lanes
            .into_iter()
            .filter(|(_, l)| l.route != RouteMethod::Bluetooth || only_bluetooth || others < BLUETOOTH_HELPS_BELOW)
            .filter(|(_, l)| l.rate >= fastest * HELPS_FROM_SHARE)
            .map(|(id, _)| *id)
            .collect()
    }

    /// When `lanes` would finish `bytes` more between them, beyond what each holds (seconds from now).
    pub(super) fn finish_time(&self, lanes: &[LaneId], bytes: u64) -> f64 {
        let mut starts: Vec<(f64, f64)> = lanes
            .iter()
            .map(|id| {
                let l = &self.lanes[id];
                (l.in_flight as f64 / l.rate + l.rtt.as_secs_f64(), l.rate)
            })
            .collect();
        if starts.is_empty() {
            return f64::INFINITY;
        }
        szfriends_wire::order::sort_by(&mut starts, |a, b| a.0.total_cmp(&b.0));
        let (mut left, mut slope, mut time) = (bytes as f64, 0.0, starts[0].0);
        for (i, &(start, rate)) in starts.iter().enumerate() {
            if slope > 0.0 && left <= slope * (start - time) {
                return time + left / slope;
            }
            left -= slope * (start - time);
            time = start;
            slope += rate;
            if i == starts.len() - 1 {
                return time + left / slope;
            }
        }
        unreachable!()
    }

    /// The lane for a block of `bytes` (of a transfer of `block_bytes` blocks), if one should take it now.
    pub(super) fn pick(&self, eligible: &[LaneId], bytes: u64, block_bytes: u64, unassigned: u64) -> Option<LaneId> {
        let eta = |id: &LaneId| self.lanes[id].eta(bytes);
        let best = eligible.iter().min_by(|a, b| eta(a).total_cmp(&eta(b)))?;
        let candidate = eligible
            .iter()
            .filter(|id| self.room(&self.lanes[id], bytes, block_bytes))
            .min_by(|a, b| eta(a).total_cmp(&eta(b)))?;
        if candidate == best {
            return Some(*candidate);
        }
        let others: Vec<LaneId> = eligible.iter().copied().filter(|id| id != candidate).collect();
        (eta(candidate) <= self.finish_time(&others, unassigned)).then_some(*candidate)
    }

    /// The next block to place: open blocks that lost their lane first, then the lowest unassigned one of the first
    /// transfer within § 3's limits.
    pub(super) fn next_block(&self) -> Option<(usize, u32)> {
        for (at, t) in self.transfers.iter().enumerate() {
            if let Some(&block) = t.unassigned.iter().find(|b| t.open.contains_key(b)) {
                return Some((at, block));
            }
        }
        for (at, t) in self.transfers.iter().enumerate() {
            let Some(&block) = t.unassigned.first() else { continue };
            if t.open.len() < BLOCKS_IN_FLIGHT_MAX && t.open_bytes + t.bytes(block) <= BYTES_IN_FLIGHT_MAX {
                return Some((at, block));
            }
        }
        None
    }

    pub(super) fn fill(&mut self, now: Duration) {
        self.relay_steps_aside(now);
        let eligible = self.eligible(now);
        let mut unassigned = self.unassigned_bytes();
        while let Some((at, block)) = self.next_block() {
            let (bytes, block_bytes) = (self.transfers[at].bytes(block), self.transfers[at].geometry.block_bytes());
            let Some(lane) = self.pick(&eligible, bytes, block_bytes, unassigned) else { break };
            self.assign(at, block, lane, now);
            unassigned -= bytes;
        }
        if self.transfers.iter().all(|t| t.unassigned.is_empty()) {
            self.endgame(&eligible, now);
        }
        self.ask_for_lanes(&eligible, now);
    }

    pub(super) fn assign(&mut self, at: usize, block: u32, lane_id: LaneId, now: Duration) {
        let transfer = &mut self.transfers[at];
        let bytes = transfer.bytes(block);
        let key = transfer.key;
        self.seq += 1;
        let lane = self.lanes.get_mut(&lane_id).expect("eligible");
        if lane.in_flight == 0 {
            // From idle, measure from now, not from the last delivery.
            lane.delivered_at = now;
            lane.progress_at = now;
        }
        let placement = Placement {
            lane: lane_id,
            seq: self.seq,
            bytes,
            sent_at: None,
            delivered: lane.delivered,
            delivered_at: lane.delivered_at,
        };
        lane.in_flight += bytes;
        lane.holds.insert(self.seq, (key, block));
        if !transfer.open.contains_key(&block) {
            transfer.open_bytes += bytes;
        }
        transfer.open.entry(block).or_default().push(placement);
        transfer.unassigned.remove(&block);
        self.actions.push(Action::Send { lane: lane_id, transfer: key, block });
    }

    /// When the copy `p` should complete, as its lane stands now.
    pub(super) fn expected(&self, p: &Placement, now: Duration) -> f64 {
        let lane = &self.lanes[&p.lane];
        let rtt = lane.rtt.as_secs_f64();
        if let Some(sent) = p.sent_at {
            return (sent.as_secs_f64() + rtt).max(now.as_secs_f64());
        }
        let ahead: u64 = lane
            .holds
            .range(..=p.seq)
            .filter_map(|(seq, (key, block))| {
                let t = self.transfers.iter().find(|t| t.key == *key)?;
                let q = t.open.get(block)?.iter().find(|q| q.seq == *seq)?;
                q.sent_at.is_none().then_some(q.bytes)
            })
            .sum();
        now.as_secs_f64() + ahead as f64 / lane.rate + rtt
    }

    /// Nothing unassigned: lanes with room take second copies of the blocks that would otherwise finish last. The
    /// fastest lane takes them whatever it expects to gain: it has nothing else to do, and a lane that went quiet with
    /// a block all written (in its socket's buffer, as far as this side can tell) looks on time until its silence is
    /// noticed, seconds later. So the transfer ends no later than on the fastest lane alone.
    pub(super) fn endgame(&mut self, eligible: &[LaneId], now: Duration) {
        let fastest =
            eligible.iter().copied().reduce(|a, b| if self.lanes[&b].rate > self.lanes[&a].rate { b } else { a });
        let only_bluetooth = eligible.iter().all(|id| self.lanes[id].route == RouteMethod::Bluetooth);
        let helpers: Vec<LaneId> = eligible
            .iter()
            .copied()
            .filter(|id| only_bluetooth || self.lanes[id].route != RouteMethod::Bluetooth)
            .collect();
        loop {
            let mut best: Option<(f64, usize, u32, LaneId)> = None;
            for (at, t) in self.transfers.iter().enumerate() {
                for (&block, placements) in &t.open {
                    let live: Vec<&Placement> =
                        placements.iter().filter(|p| self.lanes.get(&p.lane).is_some_and(|l| l.working())).collect();
                    if live.len() != 1 {
                        continue;
                    }
                    let finish = self.expected(live[0], now);
                    for &id in &helpers {
                        let lane = &self.lanes[&id];
                        if id == live[0].lane || !self.room(lane, t.bytes(block), t.geometry.block_bytes()) {
                            continue;
                        }
                        let gain = finish - (now.as_secs_f64() + lane.eta(t.bytes(block)));
                        let worth = gain > lane.rtt.as_secs_f64().max(0.005) || Some(id) == fastest;
                        if worth && best.is_none_or(|b| gain > b.0) {
                            best = Some((gain, at, block, id));
                        }
                    }
                }
            }
            let Some((_, at, block, lane)) = best else { return };
            self.assign(at, block, lane, now);
        }
    }

    /// A lane other than the relay reaches the peer (ADR 0020).
    pub(super) fn direct_reaches(&self, now: Duration) -> bool {
        self.lanes.values().any(|l| l.route != RouteMethod::Relay && l.reaches(now))
    }

    /// The relay carries the transfer: it works and no direct lane reaches the peer (ADR 0020).
    pub(super) fn relayed(&self, now: Duration) -> bool {
        self.lanes.values().any(|l| l.route == RouteMethod::Relay && l.working()) && !self.direct_reaches(now)
    }

    pub(super) fn request(&mut self, route: RouteMethod, now: Duration) {
        let last = self.requested.get(&(route as u8));
        let again = if self.relayed(now) { REQUEST_WHILE_RELAYED } else { REQUEST_AGAIN_AFTER };
        if last.is_none_or(|t| now.saturating_sub(*t) >= again) {
            self.requested.insert(route as u8, now);
            self.actions.push(Action::Lane(LaneRequest::Open { route }));
        }
    }

    /// Bluetooth beside slow lanes; direct Wi-Fi beside a LAN below 25 MB/s, where it keeps the device online.
    pub(super) fn ask_for_lanes(&mut self, eligible: &[LaneId], now: Duration) {
        let left = self.unassigned_bytes();
        if left == 0 {
            return;
        }
        let rate_of = |pred: &dyn Fn(RouteMethod) -> bool| -> f64 {
            eligible.iter().map(|id| &self.lanes[id]).filter(|l| pred(l.route)).map(|l| l.rate).sum()
        };
        let has = |route: RouteMethod| self.lanes.values().any(|l| l.route == route);
        let direct = rate_of(&|r| !matches!(r, RouteMethod::Bluetooth | RouteMethod::Relay));
        let lan = rate_of(&|r| r == RouteMethod::Lan);
        let worth = left as f64 > WORTH_A_LANE * direct;
        let bluetooth = !has(RouteMethod::Bluetooth) && direct < BLUETOOTH_HELPS_BELOW && worth;
        let direct_wifi = self.config.direct_wifi_keeps_internet
            && !has(RouteMethod::PeerToPeerWifi)
            && lan < DIRECT_WIFI_HELPS_BELOW
            && worth;
        if bluetooth {
            self.request(RouteMethod::Bluetooth, now);
        }
        if direct_wifi {
            self.request(RouteMethod::PeerToPeerWifi, now);
        }
    }

    /// The owner's relay rule (ADR 0020): while a direct lane works, the relay carries nothing. What it holds goes
    /// back at once to be sent on the direct lanes (its parts not yet written are dropped); it keeps its session, for
    /// when every direct lane is gone again.
    pub(super) fn relay_steps_aside(&mut self, now: Duration) {
        if !self.direct_reaches(now) {
            return;
        }
        let relays: Vec<LaneId> = self
            .lanes
            .iter()
            .filter(|(_, l)| l.route == RouteMethod::Relay && !l.holds.is_empty())
            .map(|(id, _)| *id)
            .collect();
        for id in relays {
            let lane = self.lanes.get_mut(&id).expect("listed");
            let holds = std::mem::take(&mut lane.holds);
            lane.in_flight = 0;
            for (seq, (key, block)) in holds {
                if let Some(transfer) = self.transfers.iter_mut().find(|t| t.key == key) {
                    if let Some(placements) = transfer.open.get_mut(&block) {
                        placements.retain(|p| p.seq != seq);
                    }
                }
                self.actions.push(Action::Cancel { lane: id, transfer: key, block });
                self.release_if_unplaced(key, block);
            }
        }
    }

    // ----- lane state -----

    /// `block` has no live placement any more: it goes back to the unassigned (it stays open).
    pub(super) fn release_if_unplaced(&mut self, key: TransferKey, block: u32) {
        let lanes = &self.lanes;
        let Some(transfer) = self.transfers.iter_mut().find(|t| t.key == key) else { return };
        if !transfer.wanted[block as usize] {
            return;
        }
        let live = transfer
            .open
            .get(&block)
            .is_some_and(|ps| ps.iter().any(|p| lanes.get(&p.lane).is_some_and(|l| l.working())));
        if !live {
            transfer.unassigned.insert(block);
        }
    }

    pub(super) fn go_silent(&mut self, id: LaneId) {
        let lane = self.lanes.get_mut(&id).expect("listed");
        lane.silent = true;
        let holds: Vec<(TransferKey, u32)> = lane.holds.values().copied().collect();
        for (key, block) in holds {
            self.release_if_unplaced(key, block);
        }
    }

    pub(super) fn recover(&mut self, id: LaneId) {
        let lane = self.lanes.get_mut(&id).expect("listed");
        lane.silent = false;
        let holds: Vec<(TransferKey, u32)> = lane.holds.values().copied().collect();
        for (key, block) in holds {
            if let Some(t) = self.transfers.iter_mut().find(|t| t.key == key) {
                t.unassigned.remove(&block);
            }
        }
    }
}
