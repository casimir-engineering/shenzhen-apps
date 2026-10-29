//! The multi-route scheduler (ADR 0018 § 7), sans-IO: which lane of a group carries which block of which transfer.
//!
//! It hears lanes come and go ([`LaneEvent`] from the group, `session/lanes.rs`), what the receiver wants and has
//! (WANT and HAVE), and what the lanes do (a write completed, a block's last part written, a byte heard, the encrypting
//! thread busy). It answers with [`Action`]s: send this block on that lane, drop what is left of a block another lane
//! completed, and [`LaneRequest`]s to open or close lanes. Time is whatever monotonic clock the driver passes in.
//!
//! The rules:
//! - Each lane keeps a delivery rate (the largest over HAVEs in the last 10 s, BBR's sample: bytes this lane delivered
//!   since the block was assigned, over the time since the lane's previous delivery) and a round-trip time (the
//!   smallest from a block's last part written to its HAVE, in the last 10 s); a route's typical figures until then.
//! - The next block goes to the lane expected to finish it first: (in flight + block) / rate + round trip. A lane that
//!   is not the best overall (the best has no room) gets it only if it would finish it before the other lanes could
//!   finish everything still unassigned without it: so slower lanes add their share while there is plenty left, and
//!   the last blocks never wait behind a slow one.
//! - In flight per lane: 2 × rate × round trip, at least two blocks, at most 32 MiB (8 MiB on phones); per transfer
//!   § 3's 64 blocks and 64 MiB that are assigned and not complete.
//! - A lane that closes gives its blocks back at once; a lane with blocks that for max(3 round trips, 1 s) (2 s on
//!   Bluetooth) neither completed one nor finished a write is silent: its blocks go to the others at once, it gets
//!   nothing new until it moves again, and it is closed after 10 s without a byte from the peer.
//! - Endgame: when nothing is unassigned, a lane with room takes a second copy of the in-flight block whose lane would
//!   finish it last, when it would finish it sooner; the first copy to complete wins and the other is cancelled. The
//!   fastest lane takes such copies whatever it expects to gain, so it never waits on another lane: a transfer is
//!   never slower with more lanes than on its fastest lane alone (the owner's rule).
//! - Bluetooth carries blocks only while the other lanes together measure below 4 MB/s, or alone; the relay only while
//!   no other lane works. Direct Wi-Fi is asked for (and kept) only where it leaves the device on its Wi-Fi network.
//!   A lane under 3 % of the fastest's rate carries nothing, and one slower than the fastest holds at most what the
//!   fastest sends in a second.
//!
//! The driver turns [`Action::Send`] into PARTs with the lane's part size, reading the block through
//! [`BlockServe`](super::BlockServe)'s leaf check, and reports back with [`Scheduler::written`], [`Scheduler::sent`],
//! [`Scheduler::have`] and [`Scheduler::heard`]. `sim.rs` drives it with emulated lanes.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::time::Duration;

use szfriends_wire::consts::{BLOCKS_IN_FLIGHT_MAX, BYTES_IN_FLIGHT_MAX};
use szfriends_wire::RouteMethod;

use super::geometry::Geometry;
use crate::session::lanes::{one_lane_only, LaneEvent, LaneId, LaneRequest, LANES_PER_ROUTE};

/// The driver's name for one transfer within the group (a row id, a counter).
pub type TransferKey = u64;

/// How far back rate and round-trip samples count.
pub const SAMPLE_WINDOW: Duration = Duration::from_secs(10);
/// Bluetooth adds to the other lanes only while they measure less than this together.
pub const BLUETOOTH_HELPS_BELOW: f64 = 4e6;
/// A direct Wi-Fi lane is asked for beside the LAN only while the LAN lanes measure less than this together.
pub const DIRECT_WIFI_HELPS_BELOW: f64 = 25e6;
/// A silent lane: no block completed and no write finished for this long, or 3 round trips if longer.
pub const SILENT_AFTER: Duration = Duration::from_secs(1);
pub const SILENT_AFTER_BLUETOOTH: Duration = Duration::from_secs(2);
/// A lane holding blocks that hears nothing from the peer this long is silent (the peer pings every second).
pub const UNHEARD_AFTER: Duration = Duration::from_millis(2_500);
pub const UNHEARD_AFTER_BLUETOOTH: Duration = Duration::from_millis(3_500);
/// A silent lane is closed after this long without a byte from the peer.
pub const CLOSE_SILENT_AFTER: Duration = Duration::from_secs(10);
/// A lane slower than this many seconds per block holds one block at a time.
const SLOW_BLOCK_SECONDS: f64 = 1.0;
/// In flight per lane at most.
pub const LANE_BYTES_MAX: u64 = 32 << 20;
pub const LANE_BYTES_MAX_PHONE: u64 = 8 << 20;
/// The same lane request is not repeated sooner than this.
pub const REQUEST_AGAIN_AFTER: Duration = Duration::from_secs(10);
/// A lane is worth asking for only when the work left would take the current lanes longer than this.
const WORTH_A_LANE: f64 = 4.0;
/// A lane slower than the fastest takes blocks only while it measures at least this share of the fastest: below it,
/// what it adds is less than what it costs (its encryption and HAVEs, a block the fastest may end up sending again).
pub const HELPS_FROM_SHARE: f64 = 0.03;
/// A lane slower than the fastest holds at most what the fastest sends in this long (one block at least), so what a
/// lost lane leaves the fastest to send again is little.
const SLOWER_LANE_SECONDS: f64 = 1.0;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Config {
    /// Phones keep at most 8 MiB in flight per lane.
    pub phone: bool,
    /// Direct Wi-Fi leaves this device on its Wi-Fi network (AWDL on Macs and iPhones). Without it, direct Wi-Fi is
    /// never asked for and a direct Wi-Fi lane that comes up anyway is closed unused: a transfer never costs a device
    /// its Internet connection without its person's word ([`Scheduler::allow_direct_wifi`], ADR 0019's boost).
    pub direct_wifi_keeps_internet: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// Read `block` of `transfer`, check it against its leaf and send it as PARTs on `lane`.
    Send { lane: LaneId, transfer: TransferKey, block: u32 },
    /// Another copy of `block` completed: drop its parts not yet written on `lane`.
    Cancel { lane: LaneId, transfer: TransferKey, block: u32 },
    /// Open or close a lane (the group keeps its limits; an impossible request is dropped quietly).
    Lane(LaneRequest),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SchedulerError {
    UnknownTransfer,
    /// WANT or HAVE naming a block past the file.
    OutOfRange,
}

/// What the scheduler knows of one lane, for logs and tests.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LaneStats {
    pub route: RouteMethod,
    pub index: u8,
    /// Bytes per second.
    pub rate: f64,
    pub rtt: Duration,
    pub in_flight: u64,
    pub silent: bool,
    pub measured: bool,
}

/// What a route typically does, until a lane on it has measured itself.
fn typical(route: RouteMethod) -> (f64, Duration) {
    let ms = Duration::from_millis;
    match route {
        RouteMethod::Lan => (40e6, ms(5)),
        RouteMethod::PeerToPeerWifi => (20e6, ms(5)),
        RouteMethod::Internet => (4e6, ms(50)),
        RouteMethod::Relay => (0.5e6, ms(100)),
        RouteMethod::Bluetooth => (0.15e6, ms(40)),
        RouteMethod::None => (1e6, ms(100)),
    }
}

#[derive(Clone, Copy, Debug)]
struct Placement {
    lane: LaneId,
    seq: u64,
    bytes: u64,
    sent_at: Option<Duration>,
    /// The lane's delivered bytes and the time of its last delivery when this was assigned (BBR's rate sample).
    delivered: u64,
    delivered_at: Duration,
}

#[derive(Debug)]
struct Transfer {
    key: TransferKey,
    geometry: Geometry,
    /// Wanted and not in a HAVE.
    wanted: Vec<bool>,
    wanted_count: u32,
    /// Wanted, with no live placement.
    unassigned: BTreeSet<u32>,
    /// Open blocks (assigned since they were last wanted, not complete) and their placements; a block whose lane went
    /// away stays open with none, as the receiver may hold parts of it (§ 3 counts it).
    open: BTreeMap<u32, Vec<Placement>>,
    open_bytes: u64,
}

impl Transfer {
    fn bytes(&self, block: u32) -> u64 {
        self.geometry.span(block).1 as u64
    }
}

#[derive(Debug)]
struct Lane {
    index: u8,
    route: RouteMethod,
    rates: VecDeque<(Duration, f64)>,
    rtts: VecDeque<(Duration, Duration)>,
    rate: f64,
    rtt: Duration,
    measured: bool,
    in_flight: u64,
    delivered: u64,
    delivered_at: Duration,
    progress_at: Duration,
    heard_at: Duration,
    silent: bool,
    closing: bool,
    /// Never given blocks (direct Wi-Fi that would cost this device its network).
    unused: bool,
    /// Placements in the order they were assigned: seq → (transfer, block).
    holds: BTreeMap<u64, (TransferKey, u32)>,
}

impl Lane {
    fn eta(&self, bytes: u64) -> f64 {
        (self.in_flight + bytes) as f64 / self.rate + self.rtt.as_secs_f64()
    }

    fn silent_after(&self) -> Duration {
        let floor = if self.route == RouteMethod::Bluetooth { SILENT_AFTER_BLUETOOTH } else { SILENT_AFTER };
        floor.max(self.rtt * 3)
    }

    /// Silent by what it hears: both ends of a fast session ping every second while a file moves (ADR 0018 § 7), so
    /// a lane holding blocks that hears nothing for this long has lost its route, however long its measured round
    /// trip (a deep buffer in the path inflates that, and with it `silent_after`).
    fn unheard_after(&self) -> Duration {
        if self.route == RouteMethod::Bluetooth {
            UNHEARD_AFTER_BLUETOOTH
        } else {
            UNHEARD_AFTER
        }
    }

    fn working(&self) -> bool {
        !self.silent && !self.closing && !self.unused
    }

    fn sample_rate(&mut self, now: Duration, rate: f64) {
        self.rates.push_back((now, rate.min(1e11)));
        while self.rates.front().is_some_and(|(t, _)| now.saturating_sub(*t) > SAMPLE_WINDOW) {
            self.rates.pop_front();
        }
        self.rate = self.rates.iter().map(|(_, r)| *r).fold(1e3, f64::max);
        self.measured = true;
    }

    fn sample_rtt(&mut self, now: Duration, rtt: Duration) {
        self.rtts.push_back((now, rtt));
        while self.rtts.front().is_some_and(|(t, _)| now.saturating_sub(*t) > SAMPLE_WINDOW) {
            self.rtts.pop_front();
        }
        self.rtt = self.rtts.iter().map(|(_, r)| *r).min().unwrap_or(rtt);
    }
}

/// The scheduler of one group: every transfer this side sends to that device, over every lane of the group.
#[derive(Debug)]
pub struct Scheduler {
    config: Config,
    lanes: BTreeMap<LaneId, Lane>,
    /// In the order they were added: earlier transfers' blocks go first.
    transfers: Vec<Transfer>,
    actions: Vec<Action>,
    requested: BTreeMap<u8, Duration>,
    seq: u64,
    /// ADR 0019: a direct Wi-Fi lane this device's person agreed to (the boost) is kept even where direct Wi-Fi costs
    /// the Internet connection.
    direct_wifi_allowed: bool,
}

impl Scheduler {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            lanes: BTreeMap::new(),
            transfers: Vec::new(),
            actions: Vec::new(),
            requested: BTreeMap::new(),
            seq: 0,
            direct_wifi_allowed: false,
        }
    }

    /// ADR 0019's boost: while `allowed`, a direct Wi-Fi lane is kept where [`Config::direct_wifi_keeps_internet`]
    /// would close it; when the boost ends, such lanes close at once (their blocks go back to the others).
    pub fn allow_direct_wifi(&mut self, allowed: bool) {
        self.direct_wifi_allowed = allowed;
        if allowed || self.config.direct_wifi_keeps_internet {
            return;
        }
        let closing: Vec<LaneId> = self
            .lanes
            .iter()
            .filter(|(_, l)| l.route == RouteMethod::PeerToPeerWifi && l.index != 0 && !l.closing)
            .map(|(id, _)| *id)
            .collect();
        for lane in closing {
            if let Some(l) = self.lanes.get_mut(&lane) {
                l.closing = true;
            }
            self.actions.push(Action::Lane(LaneRequest::Close { lane }));
        }
    }

    /// What the lanes on `route` measure together, in bytes per second (0 before any measured): how the boost knows
    /// whether its lane beats Bluetooth.
    pub fn route_rate(&self, route: RouteMethod) -> f64 {
        self.lanes.values().filter(|l| l.route == route && l.measured && l.working()).map(|l| l.rate).sum()
    }

    /// What to do since the last call.
    pub fn take_actions(&mut self) -> Vec<Action> {
        std::mem::take(&mut self.actions)
    }

    // ----- inputs -----

    /// A lane went live or closed (`LaneGroup::take_events`).
    pub fn lane_event(&mut self, event: LaneEvent, now: Duration) {
        match event {
            LaneEvent::Up { lane, index, route } => {
                let (rate, rtt) = typical(route);
                // The first session is wherever the route racer put it; only a lane can be refused.
                let unused = route == RouteMethod::PeerToPeerWifi
                    && !self.config.direct_wifi_keeps_internet
                    && !self.direct_wifi_allowed
                    && index != 0;
                if unused {
                    self.actions.push(Action::Lane(LaneRequest::Close { lane }));
                }
                self.lanes.insert(
                    lane,
                    Lane {
                        index,
                        route,
                        rates: VecDeque::new(),
                        rtts: VecDeque::new(),
                        rate,
                        rtt,
                        measured: false,
                        in_flight: 0,
                        delivered: 0,
                        delivered_at: now,
                        progress_at: now,
                        heard_at: now,
                        silent: false,
                        closing: unused,
                        unused,
                        holds: BTreeMap::new(),
                    },
                );
            }
            LaneEvent::Down { lane } => {
                if let Some(gone) = self.lanes.remove(&lane) {
                    for (key, block) in gone.holds.into_values() {
                        let Some(transfer) = self.transfers.iter_mut().find(|t| t.key == key) else { continue };
                        if let Some(placements) = transfer.open.get_mut(&block) {
                            placements.retain(|p| p.lane != lane);
                        }
                        self.release_if_unplaced(key, block);
                    }
                }
            }
        }
        self.fill(now);
    }

    /// A transfer this side sends, accepted by blocks; nothing is wanted until [`Scheduler::want`].
    pub fn add_transfer(&mut self, key: TransferKey, geometry: Geometry) {
        if self.transfers.iter().any(|t| t.key == key) {
            return;
        }
        self.transfers.push(Transfer {
            key,
            geometry,
            wanted: vec![false; geometry.blocks as usize],
            wanted_count: 0,
            unassigned: BTreeSet::new(),
            open: BTreeMap::new(),
            open_bytes: 0,
        });
    }

    /// The transfer ended (done, cancelled, failed): its blocks are dropped from every lane.
    pub fn remove_transfer(&mut self, key: TransferKey) {
        let Some(at) = self.transfers.iter().position(|t| t.key == key) else { return };
        let transfer = self.transfers.remove(at);
        for (block, placements) in transfer.open {
            for p in placements {
                if let Some(lane) = self.lanes.get_mut(&p.lane) {
                    lane.holds.remove(&p.seq);
                    lane.in_flight -= p.bytes;
                    self.actions.push(Action::Cancel { lane: p.lane, transfer: key, block });
                }
            }
        }
    }

    /// The receiver's WANT: these blocks are missing. A block already open is wanted again because it failed its
    /// check: its copies are cancelled (the receiver dropped what it had) and it goes first.
    pub fn want(&mut self, key: TransferKey, ranges: &[(u32, u32)], now: Duration) -> Result<(), SchedulerError> {
        let at = self.transfers.iter().position(|t| t.key == key).ok_or(SchedulerError::UnknownTransfer)?;
        let blocks = self.transfers[at].geometry.blocks;
        if ranges.iter().any(|&(first, count)| u64::from(first) + u64::from(count) > u64::from(blocks)) {
            return Err(SchedulerError::OutOfRange);
        }
        for &(first, count) in ranges {
            for block in first..first + count {
                let transfer = &mut self.transfers[at];
                if !transfer.wanted[block as usize] {
                    transfer.wanted[block as usize] = true;
                    transfer.wanted_count += 1;
                }
                let placements = transfer.open.get_mut(&block).map(std::mem::take).unwrap_or_default();
                transfer.unassigned.insert(block);
                for p in placements {
                    if let Some(lane) = self.lanes.get_mut(&p.lane) {
                        lane.holds.remove(&p.seq);
                        lane.in_flight -= p.bytes;
                        self.actions.push(Action::Cancel { lane: p.lane, transfer: key, block });
                    }
                }
            }
        }
        self.fill(now);
        Ok(())
    }

    /// The receiver's HAVE (from any lane): these blocks are complete, checked and written.
    pub fn have(&mut self, key: TransferKey, ranges: &[(u32, u32)], now: Duration) -> Result<(), SchedulerError> {
        let at = self.transfers.iter().position(|t| t.key == key).ok_or(SchedulerError::UnknownTransfer)?;
        let blocks = self.transfers[at].geometry.blocks;
        if ranges.iter().any(|&(first, count)| u64::from(first) + u64::from(count) > u64::from(blocks)) {
            return Err(SchedulerError::OutOfRange);
        }
        for &(first, count) in ranges {
            for block in first..first + count {
                let transfer = &mut self.transfers[at];
                if !transfer.wanted[block as usize] {
                    continue;
                }
                transfer.wanted[block as usize] = false;
                transfer.wanted_count -= 1;
                transfer.unassigned.remove(&block);
                let Some(placements) = transfer.open.remove(&block) else { continue };
                transfer.open_bytes -= transfer.bytes(block);
                // The copy that finished: the one whose last part was written first, else the first assigned. When
                // no copy was sent whole, the receiver had the block from elsewhere (its own earlier version, another
                // source, or parts of two copies, WP6): what is left of every copy is dropped, the winner's too.
                let winner = placements.iter().min_by_key(|p| (p.sent_at.is_none(), p.sent_at, p.seq)).map(|p| p.seq);
                let elsewhere = placements.iter().all(|p| p.sent_at.is_none());
                for p in placements {
                    let Some(lane) = self.lanes.get_mut(&p.lane) else { continue };
                    lane.holds.remove(&p.seq);
                    lane.in_flight -= p.bytes;
                    if elsewhere && Some(p.seq) == winner {
                        self.actions.push(Action::Cancel { lane: p.lane, transfer: key, block });
                    }
                    if Some(p.seq) != winner {
                        self.actions.push(Action::Cancel { lane: p.lane, transfer: key, block });
                        continue;
                    }
                    lane.delivered += p.bytes;
                    let elapsed = now.saturating_sub(p.delivered_at).max(Duration::from_micros(100));
                    lane.sample_rate(now, (lane.delivered - p.delivered) as f64 / elapsed.as_secs_f64());
                    if let Some(sent) = p.sent_at {
                        lane.sample_rtt(now, now.saturating_sub(sent));
                    }
                    lane.delivered_at = now;
                    lane.progress_at = now;
                    if lane.silent {
                        self.recover(p.lane);
                    }
                }
            }
        }
        self.fill(now);
        Ok(())
    }

    /// A write on `lane` completed (bytes left this side): the lane is moving.
    pub fn written(&mut self, lane: LaneId, now: Duration) {
        let Some(entry) = self.lanes.get_mut(&lane) else { return };
        if entry.in_flight > 0 {
            entry.progress_at = now;
            if entry.silent {
                self.recover(lane);
                self.fill(now);
            }
        }
    }

    /// The last part of `block` was written on `lane`: its round trip starts.
    pub fn sent(&mut self, lane: LaneId, key: TransferKey, block: u32, now: Duration) {
        let Some(transfer) = self.transfers.iter_mut().find(|t| t.key == key) else { return };
        if let Some(p) = transfer.open.get_mut(&block).and_then(|ps| ps.iter_mut().find(|p| p.lane == lane)) {
            p.sent_at.get_or_insert(now);
        }
        self.written(lane, now);
    }

    /// A byte from the peer on `lane` (any frame, PING included).
    pub fn heard(&mut self, lane: LaneId, now: Duration) {
        if let Some(entry) = self.lanes.get_mut(&lane) {
            entry.heard_at = now;
        }
    }

    /// `lane`'s encrypting thread is busy all the time while its socket has room: this computer, not the path, limits
    /// it. One more lane on its route is asked for (never on the relay or Bluetooth).
    pub fn cpu_bound(&mut self, lane: LaneId, now: Duration) {
        let Some(route) = self.lanes.get(&lane).map(|l| l.route) else { return };
        let on_route = self.lanes.values().filter(|l| l.route == route).count();
        if one_lane_only(route) || on_route >= LANES_PER_ROUTE || self.unassigned_bytes() < 8 << 20 {
            return;
        }
        self.request(route, now);
    }

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

    // ----- the decisions -----

    fn cap(&self, lane: &Lane, block_bytes: u64) -> u64 {
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

    fn room(&self, lane: &Lane, bytes: u64, block_bytes: u64) -> bool {
        lane.in_flight == 0 || lane.in_flight + bytes <= self.cap(lane, block_bytes)
    }

    fn unassigned_bytes(&self) -> u64 {
        self.transfers.iter().map(|t| t.unassigned.iter().map(|&b| t.bytes(b)).sum::<u64>()).sum()
    }

    /// Lanes that may take blocks now: working ones; the relay only when nothing else works; Bluetooth only alone or
    /// while the others measure below 4 MB/s together; none under 3 % of the fastest.
    fn eligible(&self) -> Vec<LaneId> {
        let working: Vec<(&LaneId, &Lane)> = self.lanes.iter().filter(|(_, l)| l.working()).collect();
        let direct: Vec<_> = working.iter().filter(|(_, l)| l.route != RouteMethod::Relay).copied().collect();
        let lanes = if direct.is_empty() { working } else { direct };
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
    fn finish_time(&self, lanes: &[LaneId], bytes: u64) -> f64 {
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
    fn pick(&self, eligible: &[LaneId], bytes: u64, block_bytes: u64, unassigned: u64) -> Option<LaneId> {
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
    fn next_block(&self) -> Option<(usize, u32)> {
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

    fn fill(&mut self, now: Duration) {
        let eligible = self.eligible();
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

    fn assign(&mut self, at: usize, block: u32, lane_id: LaneId, now: Duration) {
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
    fn expected(&self, p: &Placement, now: Duration) -> f64 {
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
    fn endgame(&mut self, eligible: &[LaneId], now: Duration) {
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

    fn request(&mut self, route: RouteMethod, now: Duration) {
        let last = self.requested.get(&(route as u8));
        if last.is_none_or(|t| now.saturating_sub(*t) >= REQUEST_AGAIN_AFTER) {
            self.requested.insert(route as u8, now);
            self.actions.push(Action::Lane(LaneRequest::Open { route }));
        }
    }

    /// Bluetooth beside slow lanes; direct Wi-Fi beside a LAN below 25 MB/s, where it keeps the device online.
    fn ask_for_lanes(&mut self, eligible: &[LaneId], now: Duration) {
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

    // ----- lane state -----

    /// `block` has no live placement any more: it goes back to the unassigned (it stays open).
    fn release_if_unplaced(&mut self, key: TransferKey, block: u32) {
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

    fn go_silent(&mut self, id: LaneId) {
        let lane = self.lanes.get_mut(&id).expect("listed");
        lane.silent = true;
        let holds: Vec<(TransferKey, u32)> = lane.holds.values().copied().collect();
        for (key, block) in holds {
            self.release_if_unplaced(key, block);
        }
    }

    fn recover(&mut self, id: LaneId) {
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

#[cfg(test)]
mod tests {
    use super::*;

    const MIB: u64 = 1 << 20;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    fn sends(actions: &[Action]) -> Vec<(LaneId, u32)> {
        actions
            .iter()
            .filter_map(|a| match a {
                Action::Send { lane, block, .. } => Some((*lane, *block)),
                _ => None,
            })
            .collect()
    }

    fn up(s: &mut Scheduler, lane: LaneId, index: u8, route: RouteMethod) {
        s.lane_event(LaneEvent::Up { lane, index, route }, Duration::ZERO);
    }

    #[test]
    fn a_closed_lane_gives_its_blocks_back_at_once() {
        let mut s = Scheduler::new(Config::default());
        up(&mut s, 1, 0, RouteMethod::Lan);
        up(&mut s, 2, 1, RouteMethod::Lan);
        s.add_transfer(7, Geometry::for_size(8 * MIB).unwrap());
        s.want(7, &[(0, 8)], Duration::ZERO).unwrap();
        let first = sends(&s.take_actions());
        assert_eq!(first.len(), 4, "two blocks per lane at first: {first:?}");
        let on_two: Vec<u32> = first.iter().filter(|(l, _)| *l == 2).map(|(_, b)| *b).collect();
        s.lane_event(LaneEvent::Down { lane: 2 }, ms(5));
        let again = sends(&s.take_actions());
        assert!(again.is_empty(), "lane 1 is full: {again:?}");
        s.have(7, &[(0, 1)], ms(30)).unwrap();
        let next = sends(&s.take_actions());
        assert_eq!(next[0], (1, on_two[0]), "the lost lane's blocks first: {next:?}");
        assert_eq!(s.open(7).0, 3, "lost blocks stay open (the receiver may hold parts)");
    }

    #[test]
    fn a_silent_lane_loses_its_blocks_and_is_closed_after_ten_seconds() {
        let mut s = Scheduler::new(Config { direct_wifi_keeps_internet: true, ..Config::default() });
        up(&mut s, 1, 0, RouteMethod::Lan);
        up(&mut s, 2, 1, RouteMethod::PeerToPeerWifi);
        s.add_transfer(1, Geometry::for_size(64 * MIB).unwrap());
        s.want(1, &[(0, 64)], Duration::ZERO).unwrap();
        let on_two: Vec<u32> = sends(&s.take_actions()).into_iter().filter(|(l, _)| *l == 2).map(|(_, b)| b).collect();
        assert!(!on_two.is_empty());
        // Lane 1 keeps moving; lane 2 says nothing.
        for t in (100..=900).step_by(100) {
            s.written(1, ms(t));
        }
        assert_eq!(s.next_timer(), Some(ms(1000)));
        s.tick(ms(1000));
        assert!(s.lane_stats(2).unwrap().silent);
        s.take_actions();
        s.have(1, &[(0, 1)], ms(1001)).unwrap();
        assert_eq!(sends(&s.take_actions())[0], (1, on_two[0]), "its blocks go to the other lane first");
        s.written(1, ms(9_990));
        s.take_actions();
        s.tick(ms(9_999));
        assert!(s.take_actions().is_empty());
        s.tick(ms(10_000));
        assert_eq!(s.take_actions(), vec![Action::Lane(LaneRequest::Close { lane: 2 })]);
    }

    #[test]
    fn the_relay_only_when_nothing_else_works_and_bluetooth_only_beside_slow_lanes() {
        let mut s = Scheduler::new(Config::default());
        up(&mut s, 1, 0, RouteMethod::Relay);
        up(&mut s, 2, 1, RouteMethod::Bluetooth);
        s.add_transfer(1, Geometry::for_size(32 * MIB).unwrap());
        s.want(1, &[(0, 32)], Duration::ZERO).unwrap();
        let first = sends(&s.take_actions());
        assert!(first.iter().all(|(l, _)| *l == 2), "Bluetooth works, so not the relay: {first:?}");
        up(&mut s, 3, 2, RouteMethod::Lan);
        let next = sends(&s.take_actions());
        assert!(!next.is_empty() && next.iter().all(|(l, _)| *l == 3), "a 40 MB/s LAN: no more Bluetooth: {next:?}");
    }

    #[test]
    fn direct_wifi_that_would_cut_the_network_is_closed_unused() {
        let mut s = Scheduler::new(Config::default());
        up(&mut s, 1, 0, RouteMethod::Relay);
        up(&mut s, 2, 1, RouteMethod::PeerToPeerWifi);
        assert_eq!(s.take_actions(), vec![Action::Lane(LaneRequest::Close { lane: 2 })]);
        s.add_transfer(1, Geometry::for_size(512 * MIB).unwrap());
        s.want(1, &[(0, 512)], Duration::ZERO).unwrap();
        let actions = s.take_actions();
        assert!(sends(&actions).iter().all(|(l, _)| *l == 1));
        assert!(actions.contains(&Action::Lane(LaneRequest::Open { route: RouteMethod::Bluetooth })));
        assert!(!actions.contains(&Action::Lane(LaneRequest::Open { route: RouteMethod::PeerToPeerWifi })));
        let mut awdl = Scheduler::new(Config { direct_wifi_keeps_internet: true, ..Config::default() });
        up(&mut awdl, 1, 0, RouteMethod::Relay);
        awdl.add_transfer(1, Geometry::for_size(512 * MIB).unwrap());
        awdl.want(1, &[(0, 512)], Duration::ZERO).unwrap();
        assert!(awdl.take_actions().contains(&Action::Lane(LaneRequest::Open { route: RouteMethod::PeerToPeerWifi })));
    }

    #[test]
    fn a_boost_the_person_agreed_to_keeps_its_direct_lane_until_it_ends() {
        let mut s = Scheduler::new(Config::default());
        up(&mut s, 1, 0, RouteMethod::Bluetooth);
        s.allow_direct_wifi(true);
        up(&mut s, 2, 1, RouteMethod::PeerToPeerWifi);
        assert!(s.take_actions().is_empty(), "kept: the person said Go faster");
        s.add_transfer(1, Geometry::for_size(64 * MIB).unwrap());
        s.want(1, &[(0, 64)], Duration::ZERO).unwrap();
        let first = sends(&s.take_actions());
        assert!(first.iter().any(|(l, _)| *l == 2), "the direct lane carries blocks: {first:?}");
        s.allow_direct_wifi(false);
        assert!(s.take_actions().contains(&Action::Lane(LaneRequest::Close { lane: 2 })), "the boost ended");
        // Already allowed by the platform (AWDL): ending a boost closes nothing.
        let mut awdl = Scheduler::new(Config { direct_wifi_keeps_internet: true, ..Config::default() });
        up(&mut awdl, 2, 1, RouteMethod::PeerToPeerWifi);
        awdl.allow_direct_wifi(false);
        assert!(awdl.take_actions().is_empty());
    }

    #[test]
    fn a_block_that_failed_is_wanted_again_alone_and_goes_first() {
        let mut s = Scheduler::new(Config::default());
        up(&mut s, 1, 0, RouteMethod::Lan);
        s.add_transfer(1, Geometry::for_size(4 * MIB).unwrap());
        s.want(1, &[(0, 4)], Duration::ZERO).unwrap();
        assert_eq!(sends(&s.take_actions()), vec![(1, 0), (1, 1)]);
        s.want(1, &[(0, 1)], ms(10)).unwrap();
        let actions = s.take_actions();
        assert_eq!(actions[0], Action::Cancel { lane: 1, transfer: 1, block: 0 });
        assert_eq!(sends(&actions), vec![(1, 0)]);
        assert_eq!(s.want(1, &[(3, 2)], ms(10)), Err(SchedulerError::OutOfRange));
        assert_eq!(s.have(9, &[(0, 1)], ms(10)), Err(SchedulerError::UnknownTransfer));
    }

    #[test]
    fn finish_time_fills_the_lanes_like_water() {
        let mut s = Scheduler::new(Config::default());
        up(&mut s, 1, 0, RouteMethod::Lan);
        up(&mut s, 2, 1, RouteMethod::PeerToPeerWifi);
        // 40 MB/s at 5 ms and 20 MB/s at 5 ms, nothing in flight: 60 MB take 1 s after the 5 ms.
        let t = s.finish_time(&[1, 2], 60_000_000);
        assert!((t - 1.005).abs() < 1e-9, "{t}");
        assert!(s.finish_time(&[], 1).is_infinite());
    }
}
