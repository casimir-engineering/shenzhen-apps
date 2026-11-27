//! A lane that degrades while it carries a file (ADR 0018 § 7.2), and what the scheduler tries then.
//!
//! Every network lane's acknowledged rate over the last second is compared with its peak over [`SAMPLE_WINDOW`]:
//!
//! - **Degraded:** under half the peak for [`DEGRADED_FOR`] while it had blocks to move (not a slow sender: it held
//!   at least half its cap, and its encrypting thread did not report being the limit). Its blocks move to the others
//!   (its peak is forgotten, so its cap and expected finish follow what it moves now, and what it holds beyond a
//!   second of that goes back), and the scheduler tries one alternative the owner's rules allow, in order: a LAN
//!   lane on another interface than this one ([`LaneRequest::OpenBeside`]: Ethernet beside Wi-Fi), an Internet lane
//!   (a punched connection, where the helper has one), Bluetooth only while the group moves under 4 MB/s
//!   ([`BLUETOOTH_HELPS_BELOW`]); never the relay, which ADR 0020 keeps for when nothing else reaches.
//! - **Lossy:** a LAN lane whose path retransmits [`LOSSY_RETRANSMITS`] of its packets or more (the helper reads it
//!   from the socket, [`Scheduler::retransmits`]) and moves under [`LOSSY_BELOW`] of its peak for [`DEGRADED_FOR`]:
//!   one more TCP connection on the same route. Two connections lose and recover their windows apart, so on a
//!   lossy Wi-Fi together they keep more of the link busy than one does.
//!
//! An alternative is kept only when the group's acknowledged rate, from [`TRIAL_SETTLE`] after the new lane came up
//! to [`TRIAL_JUDGED_AFTER`], beats the rate before it by [`TRIAL_HELPS_BY`]; otherwise the lane is closed. One trial
//! at a time; a route tried is not tried again for [`TRY_AGAIN_AFTER`]. Resuming is already exact (pieces), so a
//! block moved to another lane costs only what was in flight.

use super::*;

/// A lane under this share of its peak is degraded...
pub const DEGRADED_BELOW: f64 = 0.5;
/// ... a lossy LAN lane under this share of it gets a second connection...
pub const LOSSY_BELOW: f64 = 0.7;
/// ... when this share of its packets or more were retransmitted lately...
pub const LOSSY_RETRANSMITS: f64 = 0.02;
/// ... once either held this long.
pub const DEGRADED_FOR: Duration = Duration::from_secs(3);
/// The acknowledged rate a lane moves now is measured over this long.
pub const RECENT: Duration = Duration::from_secs(1);
/// A trial lane's first seconds do not count (slow start, its first blocks)...
pub const TRIAL_SETTLE: Duration = Duration::from_secs(2);
/// ... and it is judged this long after it came up...
pub const TRIAL_JUDGED_AFTER: Duration = Duration::from_secs(7);
/// ... kept only when the group then moves this much more than before it.
pub const TRIAL_HELPS_BY: f64 = 1.1;
/// A lane asked for that never came up is given up after this long.
pub const TRIAL_GIVE_UP: Duration = Duration::from_secs(20);
/// A route tried is not tried again sooner than this.
pub const TRY_AGAIN_AFTER: Duration = Duration::from_secs(60);
/// The group's rate before a trial is measured over this long.
const BEFORE_SPAN: Duration = Duration::from_secs(3);
/// Acknowledgement samples kept per lane and for the group, at most one per [`SAMPLE_EVERY`].
const KEEP: Duration = Duration::from_secs(12);
const SAMPLE_EVERY: Duration = Duration::from_millis(20);
/// The lanes are looked at no more often than this from acknowledgements (every tick looks too).
const WATCH_EVERY: Duration = Duration::from_millis(100);

/// What a lane's health watch keeps.
#[derive(Debug, Default)]
pub(super) struct Health {
    /// (time, bytes delivered so far) at each acknowledgement.
    acked: VecDeque<(Duration, u64)>,
    low_since: Option<Duration>,
    lossy_since: Option<Duration>,
    /// Share of packets retransmitted, as the helper last said.
    retransmits: f64,
    cpu_bound_at: Option<Duration>,
    /// This low spell was acted on.
    handled: bool,
}

/// One alternative being tried.
#[derive(Clone, Copy, Debug)]
pub(super) struct Trial {
    route: RouteMethod,
    asked_at: Duration,
    /// The group's rate before it, bytes per second.
    before: f64,
    lane: Option<(LaneId, Duration)>,
}

/// The group's side: its acknowledgements, the trial running, and when each route was last tried.
#[derive(Debug, Default)]
pub(super) struct GroupHealth {
    acked: VecDeque<(Duration, u64)>,
    delivered: u64,
    trial: Option<Trial>,
    tried: BTreeMap<u8, Duration>,
    watched_at: Option<Duration>,
}

fn rate_over(samples: &VecDeque<(Duration, u64)>, from: Duration, to: Duration) -> Option<f64> {
    let first = samples.iter().find(|(t, _)| *t >= from)?;
    let last = samples.iter().rev().find(|(t, _)| *t <= to)?;
    let span = last.0.saturating_sub(first.0).as_secs_f64();
    (span >= 0.5).then(|| last.1.saturating_sub(first.1) as f64 / span)
}

fn keep(samples: &mut VecDeque<(Duration, u64)>, now: Duration, delivered: u64) {
    // Dense acknowledgements (hundreds a second on a fast lane) keep one exact sample per SAMPLE_EVERY.
    if samples.back().is_some_and(|(t, _)| now.saturating_sub(*t) < SAMPLE_EVERY) {
        return;
    }
    samples.push_back((now, delivered));
    while samples.front().is_some_and(|(t, _)| now.saturating_sub(*t) > KEEP) {
        samples.pop_front();
    }
}

impl Scheduler {
    /// The unit blocks are placed in (the first transfer's block, or slice).
    fn unit_bytes(&self) -> u64 {
        self.transfers.first().map_or(1 << 20, |t| t.geometry.block_bytes())
    }

    /// The helper's reading of `lane`'s socket: the share of its packets retransmitted since the last reading.
    pub fn retransmits(&mut self, lane: LaneId, share: f64, now: Duration) {
        if let Some(l) = self.lanes.get_mut(&lane) {
            l.health.retransmits = share.clamp(0.0, 1.0);
        }
        self.watch_health(now);
    }

    /// The group's acknowledged rate over the last `span`, bytes per second (0 before two samples).
    pub fn group_rate(&self, span: Duration, now: Duration) -> f64 {
        rate_over(&self.group.acked, now.saturating_sub(span), now).unwrap_or(0.0)
    }

    pub(super) fn note_cpu_bound(&mut self, lane: LaneId, now: Duration) {
        if let Some(l) = self.lanes.get_mut(&lane) {
            l.health.cpu_bound_at = Some(now);
        }
    }

    /// `bytes` of `lane` acknowledged now.
    pub(super) fn note_acked(&mut self, lane: LaneId, bytes: u64, now: Duration) {
        self.group.delivered += bytes;
        let delivered = self.group.delivered;
        keep(&mut self.group.acked, now, delivered);
        if let Some(l) = self.lanes.get_mut(&lane) {
            let mine = l.delivered;
            keep(&mut l.health.acked, now, mine);
        }
    }

    /// A lane came up: a trial waiting for one on its route has it now.
    pub(super) fn health_lane_up(&mut self, lane: LaneId, route: RouteMethod, now: Duration) {
        if let Some(trial) = self.group.trial.as_mut() {
            if trial.lane.is_none() && trial.route == route {
                trial.lane = Some((lane, now));
            }
        }
    }

    /// After acknowledgements (at most every [`WATCH_EVERY`]) and each tick: degraded and lossy lanes, and the
    /// trial's verdict.
    pub(super) fn watch_health_soon(&mut self, now: Duration) {
        if self.group.watched_at.is_none_or(|t| now.saturating_sub(t) >= WATCH_EVERY) {
            self.watch_health(now);
        }
    }

    pub(super) fn watch_health(&mut self, now: Duration) {
        self.group.watched_at = Some(now);
        self.judge_trial(now);
        let waiting = self.unassigned_bytes() > 0;
        let ids: Vec<LaneId> = self.lanes.keys().copied().collect();
        for id in ids {
            let block = self.unit_bytes();
            let cap = self.cap(&self.lanes[&id], block);
            let lane = self.lanes.get_mut(&id).expect("listed");
            if matches!(lane.route, RouteMethod::Bluetooth | RouteMethod::Relay) || !lane.working() || !lane.measured {
                continue;
            }
            let recent = rate_over(&lane.health.acked, now.saturating_sub(RECENT), now);
            let cpu = lane.health.cpu_bound_at.is_some_and(|t| now.saturating_sub(t) < DEGRADED_FOR);
            // It had blocks to move: not starved by the sender, and the file is not ending.
            let offered = waiting && lane.in_flight * 2 >= cap && !cpu;
            let ratio = match recent {
                Some(r) if offered => r / lane.rate.max(1.0),
                _ => {
                    lane.health.low_since = None;
                    lane.health.lossy_since = None;
                    lane.health.handled = false;
                    continue;
                }
            };
            if ratio >= LOSSY_BELOW {
                lane.health.low_since = None;
                lane.health.lossy_since = None;
                lane.health.handled = false;
                continue;
            }
            let lossy = lane.route == RouteMethod::Lan && lane.health.retransmits >= LOSSY_RETRANSMITS;
            if lossy {
                lane.health.lossy_since.get_or_insert(now);
            } else {
                lane.health.lossy_since = None;
            }
            if ratio < DEGRADED_BELOW {
                lane.health.low_since.get_or_insert(now);
            } else {
                lane.health.low_since = None;
            }
            if lane.health.handled {
                continue;
            }
            let long = |since: Option<Duration>| since.is_some_and(|t| now.saturating_sub(t) >= DEGRADED_FOR);
            let (degraded, lossy_long) = (long(lane.health.low_since), long(lane.health.lossy_since));
            if !degraded && !lossy_long {
                continue;
            }
            lane.health.handled = true;
            let route = lane.route;
            if degraded {
                self.degrade(id, recent.unwrap_or(0.0), now);
            }
            let choice = if lossy_long { Some((RouteMethod::Lan, None)) } else { self.alternative(id, route, now) };
            if let Some((route, beside)) = choice {
                self.try_route(route, beside, now);
            }
        }
    }

    /// The degraded lane's blocks move to the others: its peak is forgotten (its cap and expected finish follow what
    /// it moves now) and what it holds beyond a second of that, not yet sent, goes back.
    fn degrade(&mut self, id: LaneId, recent: f64, now: Duration) {
        let lane = self.lanes.get_mut(&id).expect("listed");
        lane.rates.clear();
        lane.rates.push_back((now, recent.max(1e3)));
        lane.rate = recent.max(1e3);
        let mut keep_bytes = (lane.rate * 1.0) as u64;
        let mut giving: Vec<(u64, TransferKey, u32)> = Vec::new();
        for (seq, (key, block)) in &lane.holds {
            let Some(transfer) = self.transfers.iter().find(|t| t.key == *key) else { continue };
            let placement = transfer.open.get(block).and_then(|ps| ps.iter().find(|p| p.seq == *seq));
            let Some(p) = placement else { continue };
            if p.sent_at.is_some() || keep_bytes >= p.bytes {
                keep_bytes = keep_bytes.saturating_sub(p.bytes);
                continue;
            }
            giving.push((*seq, *key, *block));
        }
        for (seq, key, block) in giving {
            let lane = self.lanes.get_mut(&id).expect("listed");
            lane.holds.remove(&seq);
            if let Some(transfer) = self.transfers.iter_mut().find(|t| t.key == key) {
                if let Some(placements) = transfer.open.get_mut(&block) {
                    if let Some(at) = placements.iter().position(|p| p.seq == seq) {
                        let p = placements.remove(at);
                        lane.in_flight = lane.in_flight.saturating_sub(p.bytes);
                    }
                }
            }
            self.actions.push(Action::Cancel { lane: id, transfer: key, block });
            self.release_if_unplaced(key, block);
        }
        self.fill(now);
    }

    /// The first alternative the rules allow for a degraded lane on `route`.
    fn alternative(&self, id: LaneId, route: RouteMethod, now: Duration) -> Option<(RouteMethod, Option<LaneId>)> {
        let fresh =
            |r: RouteMethod| self.group.tried.get(&(r as u8)).is_none_or(|t| now.saturating_sub(*t) >= TRY_AGAIN_AFTER);
        let count = |r: RouteMethod| self.lanes.values().filter(|l| l.route == r && !l.closing).count();
        let has = |r: RouteMethod| count(r) > 0;
        let group = self.group_rate(BEFORE_SPAN, now);
        if route == RouteMethod::Lan && fresh(RouteMethod::Lan) && count(RouteMethod::Lan) < LANES_PER_ROUTE {
            return Some((RouteMethod::Lan, Some(id)));
        }
        if !has(RouteMethod::Internet) && fresh(RouteMethod::Internet) {
            return Some((RouteMethod::Internet, None));
        }
        if !has(RouteMethod::Bluetooth) && fresh(RouteMethod::Bluetooth) && group < BLUETOOTH_HELPS_BELOW {
            return Some((RouteMethod::Bluetooth, None));
        }
        None
    }

    fn try_route(&mut self, route: RouteMethod, beside: Option<LaneId>, now: Duration) {
        if self.group.trial.is_some() {
            return;
        }
        let before = self.group_rate(BEFORE_SPAN, now);
        self.group.tried.insert(route as u8, now);
        self.group.trial = Some(Trial { route, asked_at: now, before, lane: None });
        self.actions.push(Action::Lane(match beside {
            Some(beside) => LaneRequest::OpenBeside { route, beside },
            None => LaneRequest::Open { route },
        }));
    }

    fn judge_trial(&mut self, now: Duration) {
        let Some(trial) = self.group.trial else { return };
        let Some((lane, up)) = trial.lane else {
            if now.saturating_sub(trial.asked_at) >= TRIAL_GIVE_UP {
                self.group.trial = None;
            }
            return;
        };
        if !self.lanes.contains_key(&lane) {
            self.group.trial = None;
            return;
        }
        if now.saturating_sub(up) < TRIAL_JUDGED_AFTER {
            return;
        }
        self.group.trial = None;
        let with = rate_over(&self.group.acked, up + TRIAL_SETTLE, now).unwrap_or(0.0);
        let helps = with >= trial.before * TRIAL_HELPS_BY;
        self.verdicts.push(Verdict { lane, route: trial.route, before: trial.before, with, kept: helps });
        if !helps {
            if let Some(l) = self.lanes.get_mut(&lane) {
                l.closing = true;
            }
            self.actions.push(Action::Lane(LaneRequest::Close { lane }));
        }
    }

    /// The trials judged since the last call, for the helper's log.
    pub fn take_verdicts(&mut self) -> Vec<Verdict> {
        std::mem::take(&mut self.verdicts)
    }
}

/// How a trial lane did (for helper.log).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Verdict {
    pub lane: LaneId,
    pub route: RouteMethod,
    /// The group's acknowledged bytes per second before the lane, and with it.
    pub before: f64,
    pub with: f64,
    pub kept: bool,
}
