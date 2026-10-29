//! Fetching one file's blocks from several sources at once (ADR 0018 § 9.6, WP6), sans-IO: the same file (the same
//! tree root) held by several devices, the friend's or this person's own, asked for in parts so that each block
//! crosses one route about once and every holder serves at its own speed. It applies where the receiver asks for
//! blocks itself: Get again (AGAIN 4 and 5), copies between one person's devices (SYNC 7 and 8), and the person's other
//! devices filling from the one that accepted a friend's file and from the friend.
//!
//! The receiver drives WP2's scheduler with each source as a lane: a block the scheduler gives a lane is asked of that
//! source (WANT BLOCKS, then the source's HASHES and PARTs as for an offer); a block that completes is credited to
//! the source whose part completed it, which measures each source's rate; a copy the scheduler cancels (the block
//! arrived from elsewhere) is reported to that source as a HAVE, so it stops. A source that closes or falls silent
//! gives its blocks back to the others, and the endgame asks a second source for a block only when it would finish
//! it sooner. Nothing here is on the wire: WANT BLOCKS, HAVE and PART are the ADR's.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use szfriends_wire::RouteMethod;

use super::geometry::Geometry;
use super::scheduler::{Action, Config, Scheduler};
use crate::session::lanes::LaneEvent;

/// A source: a session with a device that holds the file, as the driver names it.
pub type SourceId = u64;

const KEY: u64 = 0;

/// What to tell a source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PullAction {
    /// Ask for these blocks (WANT BLOCKS, or WANT on a session that already serves the file).
    Want { source: SourceId, ranges: Vec<(u32, u32)> },
    /// These blocks arrived from elsewhere: a HAVE, so the source drops what it has not sent of them.
    Have { source: SourceId, ranges: Vec<(u32, u32)> },
}

#[derive(Debug)]
pub struct Pull {
    scheduler: Scheduler,
    geometry: Geometry,
    /// What each source was asked for and has not delivered or been told about.
    asked: BTreeMap<SourceId, BTreeSet<u32>>,
    next_index: u8,
}

fn ranges(blocks: &BTreeSet<u32>) -> Vec<(u32, u32)> {
    let mut out: Vec<(u32, u32)> = Vec::new();
    for &block in blocks {
        match out.last_mut() {
            Some((first, count)) if *first + *count == block => *count += 1,
            _ => out.push((block, 1)),
        }
    }
    out
}

impl Pull {
    /// A pull of the blocks `missing` names (all of them for a new copy; what the map lacks when resuming).
    pub fn new(geometry: Geometry, missing: &[(u32, u32)], config: Config, now: Duration) -> Self {
        let mut scheduler = Scheduler::new(config);
        scheduler.add_transfer(KEY, geometry);
        let _ = scheduler.want(KEY, missing, now);
        Self { scheduler, geometry, asked: BTreeMap::new(), next_index: 0 }
    }

    pub fn geometry(&self) -> &Geometry {
        &self.geometry
    }

    /// A source is ready to serve (its BLOCKS FOLLOW arrived, and its leaves checked against the root).
    pub fn source_up(&mut self, source: SourceId, route: RouteMethod, now: Duration) {
        if self.asked.contains_key(&source) {
            return;
        }
        self.asked.insert(source, BTreeSet::new());
        let index = self.next_index;
        self.next_index = self.next_index.saturating_add(1);
        self.scheduler.lane_event(LaneEvent::Up { lane: source, index, route }, now);
    }

    /// A source's session ended: what it was asked for and did not deliver goes to the others.
    pub fn source_down(&mut self, source: SourceId, now: Duration) {
        if self.asked.remove(&source).is_some() {
            self.scheduler.lane_event(LaneEvent::Down { lane: source }, now);
        }
    }

    /// Something arrived from a source (any part, any frame): it is alive.
    pub fn heard(&mut self, source: SourceId, now: Duration) {
        self.scheduler.heard(source, now);
    }

    /// A block completed, checked and written; the part that completed it came from `source`.
    pub fn arrived(&mut self, source: SourceId, block: u32, now: Duration) {
        if block >= self.geometry.blocks || self.scheduler.is_done(KEY) {
            return;
        }
        if let Some(asked) = self.asked.get_mut(&source) {
            asked.remove(&block);
        }
        // Credited to that source as a copy sent whole: its rate and round trip are measured this way.
        self.scheduler.sent(source, KEY, block, now);
        let _ = self.scheduler.have(KEY, &[(block, 1)], now);
    }

    /// A block failed its leaf: asked for again, alone.
    pub fn failed(&mut self, block: u32, now: Duration) {
        for asked in self.asked.values_mut() {
            asked.remove(&block);
        }
        let _ = self.scheduler.want(KEY, &[(block, 1)], now);
    }

    pub fn tick(&mut self, now: Duration) {
        self.scheduler.tick(now);
    }

    pub fn next_timer(&self) -> Option<Duration> {
        self.scheduler.next_timer()
    }

    /// Every block arrived.
    pub fn is_done(&self) -> bool {
        self.scheduler.is_done(KEY)
    }

    /// What to send to whom, one WANT and one HAVE per source at most.
    pub fn take_actions(&mut self) -> Vec<PullAction> {
        let mut wants: BTreeMap<SourceId, BTreeSet<u32>> = BTreeMap::new();
        let mut haves: BTreeMap<SourceId, BTreeSet<u32>> = BTreeMap::new();
        for action in self.scheduler.take_actions() {
            match action {
                Action::Send { lane, block, .. } => {
                    if let Some(asked) = self.asked.get_mut(&lane) {
                        asked.insert(block);
                        wants.entry(lane).or_default().insert(block);
                        haves.entry(lane).or_default().remove(&block);
                    }
                }
                Action::Cancel { lane, block, .. } => {
                    if self.asked.get_mut(&lane).is_some_and(|asked| asked.remove(&block)) {
                        haves.entry(lane).or_default().insert(block);
                    }
                    if let Some(wanted) = wants.get_mut(&lane) {
                        wanted.remove(&block);
                    }
                }
                // Sources are the sessions that hold the file; the scheduler's lane requests do not apply.
                Action::Lane(_) => {}
            }
        }
        let mut out = Vec::new();
        for (source, blocks) in wants.into_iter().filter(|(_, b)| !b.is_empty()) {
            out.push(PullAction::Want { source, ranges: ranges(&blocks) });
        }
        for (source, blocks) in haves.into_iter().filter(|(_, b)| !b.is_empty()) {
            out.push(PullAction::Have { source, ranges: ranges(&blocks) });
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, VecDeque};

    const MIB: u64 = 1 << 20;

    /// A source serving what it was asked in order at `rate` bytes per second, after `delay` each way; `lost_at`
    /// ends its session.
    struct Source {
        route: RouteMethod,
        rate: f64,
        delay: Duration,
        queue: VecDeque<u32>,
        busy_until: Duration,
        serving: Option<u32>,
        lost_at: Option<Duration>,
        served: u64,
    }

    /// Runs a pull in virtual time; returns (seconds, blocks each source delivered, blocks delivered twice).
    fn simulate(size: u64, mut sources: Vec<Source>) -> (f64, Vec<u64>, u64) {
        let geometry = Geometry::for_size(size).unwrap();
        let mut now = Duration::ZERO;
        let mut pull = Pull::new(geometry, &[(0, geometry.blocks)], Config::default(), now);
        for (id, source) in sources.iter().enumerate() {
            pull.source_up(id as u64, source.route, now);
        }
        let mut have = vec![false; geometry.blocks as usize];
        let mut twice = 0;
        // Requests in flight toward each source: (arrives at, Want or Have).
        let mut requests: Vec<(Duration, PullAction)> = Vec::new();
        let step = Duration::from_millis(1);
        let mut live: HashMap<u64, bool> = (0..sources.len() as u64).map(|id| (id, true)).collect();
        while !pull.is_done() {
            assert!(now < Duration::from_secs(600), "the pull never finished");
            for action in pull.take_actions() {
                let source = match &action {
                    PullAction::Want { source, .. } | PullAction::Have { source, .. } => *source,
                };
                requests.push((now + sources[source as usize].delay, action));
            }
            requests.retain(|(at, action)| {
                if *at > now {
                    return true;
                }
                match action {
                    PullAction::Want { source, ranges } => {
                        let queue = &mut sources[*source as usize].queue;
                        queue.extend(ranges.iter().flat_map(|&(f, c)| f..f + c));
                    }
                    PullAction::Have { source, ranges } => {
                        let queue = &mut sources[*source as usize].queue;
                        queue.retain(|b| !ranges.iter().any(|&(f, c)| (f..f + c).contains(b)));
                    }
                }
                false
            });
            for (id, source) in sources.iter_mut().enumerate() {
                let id = id as u64;
                if !live[&id] {
                    continue;
                }
                if source.lost_at.is_some_and(|at| now >= at) {
                    live.insert(id, false);
                    pull.source_down(id, now);
                    continue;
                }
                if let Some(block) = source.serving {
                    if now >= source.busy_until + source.delay {
                        source.serving = None;
                        source.served += 1;
                        pull.heard(id, now);
                        if have[block as usize] {
                            twice += 1;
                        } else {
                            have[block as usize] = true;
                            pull.arrived(id, block, now);
                        }
                    }
                }
                if source.serving.is_none() {
                    if let Some(block) = source.queue.pop_front() {
                        let bytes = geometry.span(block).1 as f64;
                        source.busy_until = now + Duration::from_secs_f64(bytes / source.rate);
                        source.serving = Some(block);
                    }
                } else if now.as_millis() % 500 == 0 {
                    pull.heard(id, now); // its pings
                }
            }
            pull.tick(now);
            now += step;
        }
        (now.as_secs_f64(), sources.iter().map(|s| s.served).collect(), twice)
    }

    fn source(route: RouteMethod, megabytes_per_second: f64, delay_ms: u64) -> Source {
        Source {
            route,
            rate: megabytes_per_second * 1e6,
            delay: Duration::from_millis(delay_ms),
            queue: VecDeque::new(),
            busy_until: Duration::ZERO,
            serving: None,
            lost_at: None,
            served: 0,
        }
    }

    #[test]
    fn three_holders_fill_one_copy_at_about_their_sum() {
        // The friend's Mac on the LAN, the person's own Mac that already took it, the friend's phone on the LAN.
        let sources = vec![
            source(RouteMethod::Lan, 40.0, 2),
            source(RouteMethod::Lan, 20.0, 2),
            source(RouteMethod::Lan, 10.0, 3),
        ];
        let (seconds, served, twice) = simulate(256 * MIB, sources);
        let alone = 256.0 * MIB as f64 / 40e6;
        let together = 256.0 * MIB as f64 / 70e6;
        eprintln!("three holders: {seconds:.2} s (sum {together:.2} s, fastest alone {alone:.2} s), {served:?}, {twice} twice");
        assert!(seconds < together * 1.15, "{seconds:.2} s against {together:.2} s at the sum ({alone:.2} s alone)");
        assert!(served.iter().all(|&n| n > 0), "every holder served: {served:?}");
        assert!(twice <= 4, "at most the endgame's duplicates: {twice}");
    }

    #[test]
    fn a_holder_that_leaves_half_way_costs_only_its_share() {
        let mut sources = vec![source(RouteMethod::Lan, 40.0, 2), source(RouteMethod::Lan, 40.0, 2)];
        sources[1].lost_at = Some(Duration::from_secs(1));
        let (seconds, served, _) = simulate(256 * MIB, sources);
        let alone = 256.0 * MIB as f64 / 40e6;
        eprintln!("one of two leaves at 1 s: {seconds:.2} s (one alone {alone:.2} s), {served:?}");
        assert!(seconds < alone, "{seconds:.2} s, alone {alone:.2} s");
        assert!(served.iter().sum::<u64>() >= 256);
    }

    #[test]
    fn a_slow_holder_never_holds_up_the_end() {
        // A friend's phone over Bluetooth beside a Mac on a slow network: it helps while much is left, and the last
        // blocks come from the Mac.
        let sources = vec![source(RouteMethod::Lan, 2.0, 2), source(RouteMethod::Bluetooth, 0.17, 30)];
        let (seconds, served, _) = simulate(32 * MIB, sources);
        let alone = 32.0 * MIB as f64 / 2e6;
        eprintln!("slow network and Bluetooth: {seconds:.2} s (the Mac alone {alone:.2} s), {served:?}");
        assert!(seconds <= alone + 1.0, "{seconds:.2} s, the Mac alone {alone:.2} s, served {served:?}");
    }
}
