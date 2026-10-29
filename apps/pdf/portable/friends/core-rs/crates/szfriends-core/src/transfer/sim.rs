//! A virtual-time simulator for the scheduler (ADR 0018 § 7, WP2): one file sent over emulated lanes, each with a
//! rate, a round trip, part loss, silences (nothing moves either way, as a route out of range looks to TCP) and a cut
//! (closed, noticed a little later). Lanes come and go through the real [`LaneGroup`], so its limits apply. Events,
//! not threads: deterministic for a given seed, and a 1 GiB transfer runs in milliseconds.
//!
//! The receiver here only counts bytes (parts are written at their offsets, so copies on two lanes add up in 4 KiB
//! granules) and answers each completed block with a HAVE on the lane that completed it, or the quickest live lane
//! if that one is gone; it PINGs each lane every second. [`run_with_bytes`] moves real bytes instead, through WP1's
//! types: the sender checks each block against its leaf as it reads it, the receiver's [`BlockAssembly`] takes the
//! parts, a corrupt block is wanted again alone, and the file that arrives must be the file sent. Scenarios come from code or from
//! `friends/fixtures/scheduler/scenarios.json`, which the Objective-C port (WP4) runs too.

use std::collections::{BTreeMap, VecDeque};
use std::time::Duration;

use serde_json::Value;
use szfriends_wire::RouteMethod;

use super::assembly::{BlockAssembly, PartOutcome};
use super::geometry::Geometry;
use super::scheduler::{Action, Config, Scheduler};
use super::tree::{self, Leaf};
use crate::session::lanes::{LaneGroup, LaneId, LaneRequest};

const GRANULE: u64 = 4096;
const KEY: u64 = 1;

#[derive(Clone, Debug, PartialEq)]
pub struct LaneProfile {
    pub route: RouteMethod,
    /// Bytes per second, each way.
    pub rate: f64,
    pub rtt: Duration,
    /// Probability that a part is lost; a lost part holds its lane for one more round trip.
    pub loss: f64,
    pub part_bytes: u64,
    /// When it comes up; `None`: only when the scheduler asks for its route, `dial` after.
    pub up_at: Option<Duration>,
    pub dial: Duration,
    /// Cut (both ends closed) at this time, noticed `detect` later.
    pub cut_at: Option<Duration>,
    pub detect: Duration,
    /// Nothing moves either way during these.
    pub silences: Vec<(Duration, Duration)>,
}

impl LaneProfile {
    /// A lane up from the start, with the route's part size (16 KiB on Bluetooth, 60 KiB elsewhere).
    pub fn new(route: RouteMethod, rate: f64, rtt_ms: u64) -> Self {
        Self {
            route,
            rate,
            rtt: Duration::from_millis(rtt_ms),
            loss: 0.0,
            part_bytes: if route == RouteMethod::Bluetooth { 16 << 10 } else { 60 << 10 },
            up_at: Some(Duration::ZERO),
            dial: Duration::from_millis(if route == RouteMethod::Bluetooth { 1000 } else { 100 }),
            cut_at: None,
            detect: Duration::from_millis(400),
            silences: Vec::new(),
        }
    }

    /// Silent from `from` for good (well past any transfer).
    pub fn silent_from(mut self, from: Duration) -> Self {
        self.silences.push((from, Duration::from_secs(1 << 20)));
        self
    }

    /// Silent `off` out of every `period`, from `from` on.
    pub fn flapping(mut self, from: Duration, period: Duration, off: Duration, until: Duration) -> Self {
        let mut t = from;
        while t < until {
            self.silences.push((t, t + off));
            t += period;
        }
        self
    }

    fn advance(&self, mut t: Duration, mut d: Duration) -> Duration {
        for &(from, to) in &self.silences {
            if to <= t {
                continue;
            }
            if t >= from {
                t = to;
                continue;
            }
            if t + d <= from {
                return t + d;
            }
            d -= from - t;
            t = to;
        }
        t + d
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Scenario {
    pub name: String,
    pub size: u64,
    pub config: Config,
    /// The first is the group's first session and must be up at 0.
    pub lanes: Vec<LaneProfile>,
    pub seed: u64,
    pub limit: Duration,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct LaneOutcome {
    pub route: RouteMethod,
    pub sent_bytes: u64,
    /// Blocks whose last missing part came on this lane.
    pub completed: u32,
    /// When its last part was written.
    pub last_write: Duration,
    pub up: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outcome {
    pub done_at: Option<Duration>,
    pub sent_bytes: u64,
    /// Bytes that arrived for what the receiver already had (second copies, parts of lost lanes resent).
    pub wasted_bytes: u64,
    pub lanes: Vec<LaneOutcome>,
    /// § 3 as the sender counted it.
    pub max_open_blocks: usize,
    pub max_open_bytes: u64,
    /// A lane held more than its cap (or more than one block over an empty lane).
    pub lane_cap_exceeded: bool,
    pub requests: Vec<(Duration, LaneRequest)>,
    /// The route of the lane that completed the last block.
    pub last_route: RouteMethod,
    pub events: u64,
    /// [`run_with_bytes`]: every block arrived through the assembly and the bytes are the file's.
    pub verified: bool,
    /// [`run_with_bytes`]: blocks that failed their leaf and were wanted again.
    pub corrupt_blocks: u32,
}

impl Outcome {
    /// Megabytes (10^6) per second over the whole transfer.
    pub fn rate(&self, size: u64) -> f64 {
        self.done_at.map_or(0.0, |t| size as f64 / t.as_secs_f64() / 1e6)
    }

    /// How long the fastest lane still up at the end sat idle before completion.
    pub fn tail(&self, profiles: &[LaneProfile]) -> Duration {
        let Some(done) = self.done_at else { return Duration::MAX };
        let fastest = profiles
            .iter()
            .zip(&self.lanes)
            .filter(|(_, o)| o.up && o.sent_bytes > 0)
            .max_by(|a, b| a.0.rate.total_cmp(&b.0.rate));
        fastest.map_or(Duration::ZERO, |(_, o)| done.saturating_sub(o.last_write))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Ev {
    Up(usize),
    Cut(usize),
    Notice(usize),
    TxDone(usize, u32),
    Arrive {
        lane: usize,
        epoch: u32,
        block: u32,
        from: u64,
        to: u64,
        flip: bool,
    },
    /// HAVE, or WANT for a block that failed its leaf, from the receiver.
    Back {
        lane: usize,
        epoch: u32,
        block: u32,
        want: bool,
    },
    Ping(usize),
    Heard(usize, u32),
    Timer,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Idle,
    Dialing,
    Up,
    Gone,
}

#[derive(Clone, Copy, Debug)]
struct Part {
    block: u32,
    from: u64,
    to: u64,
    last: bool,
    /// A byte of it is flipped on the way ([`run_with_bytes`]).
    flip: bool,
}

/// What [`run_with_bytes`] carries: the file, its leaves, the receiver's assembly and what arrived.
#[derive(Debug)]
struct Bytes {
    file: Vec<u8>,
    leaves: Vec<Leaf>,
    assembly: BlockAssembly,
    received: Vec<u8>,
    /// Blocks whose first copy is damaged on the way.
    damage: std::collections::BTreeSet<u32>,
}

#[derive(Debug)]
struct SimLane {
    profile: LaneProfile,
    id: LaneId,
    state: State,
    epoch: u32,
    queue: VecDeque<Part>,
    current: Option<Part>,
}

struct Random(u64);

impl Random {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        (z ^ (z >> 31)) as f64 / u64::MAX as f64
    }
}

struct Sim {
    geometry: Geometry,
    now: Duration,
    seq: u64,
    queue: BTreeMap<(Duration, u64), Ev>,
    timer_at: Option<Duration>,
    lanes: Vec<SimLane>,
    group: LaneGroup,
    scheduler: Scheduler,
    covered: Vec<Vec<u64>>,
    complete: Vec<bool>,
    answered: std::collections::BTreeSet<(usize, u32)>,
    bytes: Option<Bytes>,
    random: Random,
    out: Outcome,
}

/// Runs `scenario` to completion or its time limit, counting bytes.
pub fn run(scenario: &Scenario) -> Outcome {
    simulate(scenario, None)
}

/// Runs `scenario` with real bytes through WP1's tree and assembly; the first copy of each block in `damage` is
/// corrupted on the way.
pub fn run_with_bytes(scenario: &Scenario, damage: &[u32]) -> Outcome {
    let geometry = Geometry::for_size(scenario.size).expect("a size with a geometry");
    let file: Vec<u8> = (0..scenario.size).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    let leaves: Vec<Leaf> = (0..geometry.blocks)
        .map(|b| {
            let (offset, len) = geometry.span(b);
            tree::leaf(b, &file[offset as usize..offset as usize + len])
        })
        .collect();
    let root = tree::root_of(&geometry, &leaves).expect("leaves");
    let mut assembly = BlockAssembly::new(geometry, root);
    let flat: Vec<u8> = leaves.concat();
    for (i, chunk) in flat.chunks(2000 * 32).enumerate() {
        assembly.accept_hashes((i * 2000) as u32, chunk).expect("leaves of this root");
    }
    let bytes =
        Bytes { received: vec![0; file.len()], file, leaves, assembly, damage: damage.iter().copied().collect() };
    simulate(scenario, Some(bytes))
}

fn simulate(scenario: &Scenario, bytes: Option<Bytes>) -> Outcome {
    let geometry = Geometry::for_size(scenario.size).expect("a size with a geometry");
    let first = &scenario.lanes[0];
    assert_eq!(first.up_at, Some(Duration::ZERO), "the first lane is up at 0");
    let lanes: Vec<SimLane> = scenario
        .lanes
        .iter()
        .enumerate()
        .map(|(i, p)| SimLane {
            profile: p.clone(),
            id: 100 + i as LaneId,
            state: State::Idle,
            epoch: 0,
            queue: VecDeque::new(),
            current: None,
        })
        .collect();
    let granules = geometry.block_bytes().div_ceil(GRANULE).div_ceil(64) as usize;
    let mut sim = Sim {
        geometry,
        now: Duration::ZERO,
        seq: 0,
        queue: BTreeMap::new(),
        timer_at: None,
        group: LaneGroup::new(lanes[0].id, [0; 32], first.route, |i| [i; 16]),
        lanes,
        scheduler: Scheduler::new(scenario.config),
        covered: vec![vec![0; granules]; geometry.blocks as usize],
        complete: vec![false; geometry.blocks as usize],
        answered: std::collections::BTreeSet::new(),
        bytes,
        random: Random(scenario.seed),
        out: Outcome {
            lanes: scenario.lanes.iter().map(|p| LaneOutcome { route: p.route, ..LaneOutcome::default() }).collect(),
            ..Outcome::default()
        },
    };
    sim.start();
    while let Some(((at, _), ev)) = sim.queue.pop_first() {
        if at > scenario.limit {
            break;
        }
        sim.now = at;
        sim.out.events += 1;
        sim.handle(ev);
        if sim.out.done_at.is_some() {
            break;
        }
        sim.check_limits();
        sim.arm_timer();
    }
    for (o, lane) in sim.out.lanes.iter_mut().zip(&sim.lanes) {
        o.up = lane.state == State::Up;
    }
    if let Some(bytes) = &sim.bytes {
        sim.out.verified = sim.out.done_at.is_some()
            && bytes.assembly.is_complete()
            && bytes.received == bytes.file
            && tree::root_of(&sim.geometry, &bytes.leaves).is_some();
    }
    sim.out
}

impl Sim {
    fn at(&mut self, t: Duration, ev: Ev) {
        self.seq += 1;
        self.queue.insert((t, self.seq), ev);
    }

    fn start(&mut self) {
        self.lanes[0].state = State::Up;
        self.at(Duration::from_secs(1), Ev::Ping(0));
        for i in 1..self.lanes.len() {
            if let Some(t) = self.lanes[i].profile.up_at {
                self.at(t, Ev::Up(i));
            }
        }
        for i in 0..self.lanes.len() {
            if let Some(t) = self.lanes[i].profile.cut_at {
                self.at(t, Ev::Cut(i));
            }
        }
        self.feed_group();
        self.scheduler.add_transfer(KEY, self.geometry);
        self.scheduler.want(KEY, &[(0, self.geometry.blocks)], self.now).expect("in range");
        self.act();
    }

    fn feed_group(&mut self) {
        for event in self.group.take_events() {
            self.scheduler.lane_event(event, self.now);
        }
    }

    fn arm_timer(&mut self) {
        if let Some(t) = self.scheduler.next_timer() {
            let t = t.max(self.now);
            if self.timer_at.is_none_or(|armed| t < armed) {
                self.timer_at = Some(t);
                self.at(t, Ev::Timer);
            }
        }
    }

    fn check_limits(&mut self) {
        let (blocks, bytes) = self.scheduler.open(KEY);
        self.out.max_open_blocks = self.out.max_open_blocks.max(blocks);
        self.out.max_open_bytes = self.out.max_open_bytes.max(bytes);
    }

    fn lane_of(&self, id: LaneId) -> Option<usize> {
        self.lanes.iter().position(|l| l.id == id)
    }

    fn act(&mut self) {
        for action in self.scheduler.take_actions() {
            match action {
                Action::Send { lane, block, .. } => {
                    let Some(i) = self.lane_of(lane) else { continue };
                    let stats = self.scheduler.lane_stats(lane).expect("a lane it chose");
                    let (_, length) = self.geometry.span(block);
                    let cap = self.scheduler.lane_cap(lane, self.geometry.block_bytes());
                    if stats.in_flight > cap.max(length as u64) {
                        self.out.lane_cap_exceeded = true;
                    }
                    if self.lanes[i].state != State::Up {
                        continue;
                    }
                    let (start, len) = self.geometry.span(block);
                    let mut flip = false;
                    if let Some(bytes) = &mut self.bytes {
                        // As the sender's driver does (BlockServe::load_block): the block read is checked first.
                        let data = &bytes.file[start as usize..start as usize + len];
                        assert_eq!(tree::leaf(block, data), bytes.leaves[block as usize], "the snapshot's block");
                        flip = bytes.damage.remove(&block);
                    }
                    let step = self.lanes[i].profile.part_bytes;
                    let mut from = start;
                    loop {
                        let to = (from + step).min(start + len as u64);
                        let last = to == start + len as u64;
                        self.lanes[i].queue.push_back(Part { block, from, to, last, flip: flip && from == start });
                        if to == start + len as u64 {
                            break;
                        }
                        from = to;
                    }
                    if self.lanes[i].current.is_none() {
                        self.transmit(i);
                    }
                }
                Action::Cancel { lane, block, .. } => {
                    if let Some(i) = self.lane_of(lane) {
                        self.lanes[i].queue.retain(|p| p.block != block);
                    }
                }
                Action::Lane(request) => {
                    self.out.requests.push((self.now, request));
                    match request {
                        LaneRequest::Open { route } => {
                            let found = self.lanes.iter().position(|l| {
                                l.profile.route == route && l.profile.up_at.is_none() && l.state == State::Idle
                            });
                            if let Some(i) = found {
                                if self.group.reserve(self.lanes[i].id, route).is_some() {
                                    self.lanes[i].state = State::Dialing;
                                    let t = self.now + self.lanes[i].profile.dial;
                                    self.at(t, Ev::Up(i));
                                }
                            }
                        }
                        LaneRequest::Close { lane } => {
                            if let Some(i) = self.lane_of(lane) {
                                self.cut(i);
                                self.notice(i);
                            }
                        }
                    }
                }
            }
        }
    }

    fn transmit(&mut self, i: usize) {
        let Some(part) = self.lanes[i].queue.pop_front() else {
            self.lanes[i].current = None;
            return;
        };
        let profile = &self.lanes[i].profile;
        let mut seconds = (part.to - part.from) as f64 / profile.rate;
        if profile.loss > 0.0 && self.random.next() < profile.loss {
            seconds += profile.rtt.as_secs_f64();
        }
        let done = profile.advance(self.now, Duration::from_secs_f64(seconds));
        self.lanes[i].current = Some(part);
        let epoch = self.lanes[i].epoch;
        self.at(done, Ev::TxDone(i, epoch));
    }

    fn cut(&mut self, i: usize) {
        let lane = &mut self.lanes[i];
        if lane.state != State::Up {
            return;
        }
        lane.state = State::Gone;
        lane.epoch += 1;
        lane.queue.clear();
        lane.current = None;
    }

    fn notice(&mut self, i: usize) {
        self.group.lane_down(self.lanes[i].id);
        self.feed_group();
        self.act();
    }

    fn send_back(&mut self, mut i: usize, block: u32, want: bool) {
        if self.lanes[i].state != State::Up {
            let quickest = (0..self.lanes.len())
                .filter(|&j| self.lanes[j].state == State::Up)
                .min_by_key(|&j| self.lanes[j].profile.rtt);
            let Some(j) = quickest else { return };
            i = j;
        }
        let lane = &self.lanes[i];
        let t = lane.profile.advance(self.now + Duration::from_micros(300), lane.profile.rtt / 2);
        let epoch = lane.epoch;
        self.at(t, Ev::Back { lane: i, epoch, block, want });
    }

    /// The receiver with real bytes: WP1's assembly decides, and a block that fails its leaf is wanted again.
    fn arrive_bytes(&mut self, lane: usize, block: u32, from: u64, to: u64, flip: bool) {
        let bytes = self.bytes.as_mut().expect("real bytes");
        let mut data = bytes.file[from as usize..to as usize].to_vec();
        if flip {
            data[0] ^= 0x80;
        }
        match bytes.assembly.accept_part(from, &data).expect("parts only for wanted blocks, within § 3") {
            PartOutcome::Pending => {}
            PartOutcome::Complete { block, data } => {
                let (offset, _) = self.geometry.span(block);
                bytes.received[offset as usize..offset as usize + data.len()].copy_from_slice(&data);
                self.complete[block as usize] = true;
                self.out.lanes[lane].completed += 1;
                self.out.last_route = self.lanes[lane].profile.route;
                self.send_back(lane, block, false);
            }
            PartOutcome::Corrupt { block } => {
                self.out.corrupt_blocks += 1;
                self.send_back(lane, block, true);
            }
            PartOutcome::Late => {
                self.out.wasted_bytes += to - from;
                if self.answered.insert((lane, block)) {
                    self.send_back(lane, block, false);
                }
            }
        }
    }

    fn handle(&mut self, ev: Ev) {
        match ev {
            Ev::Up(i) => {
                let id = self.lanes[i].id;
                if self.lanes[i].state == State::Idle && self.group.reserve(id, self.lanes[i].profile.route).is_none() {
                    return;
                }
                self.lanes[i].state = State::Up;
                self.group.lane_up(id);
                self.at(self.now + Duration::from_secs(1), Ev::Ping(i));
                self.feed_group();
                self.act();
            }
            Ev::Cut(i) => {
                if self.lanes[i].state == State::Up {
                    self.cut(i);
                    self.at(self.now + self.lanes[i].profile.detect, Ev::Notice(i));
                }
            }
            Ev::Notice(i) => self.notice(i),
            Ev::TxDone(i, epoch) => {
                if self.lanes[i].epoch != epoch {
                    return;
                }
                let Some(part) = self.lanes[i].current.take() else { return };
                let id = self.lanes[i].id;
                let o = &mut self.out.lanes[i];
                o.sent_bytes += part.to - part.from;
                o.last_write = self.now;
                self.out.sent_bytes += part.to - part.from;
                let arrive = self.lanes[i].profile.advance(self.now, self.lanes[i].profile.rtt / 2);
                let (block, from, to, flip) = (part.block, part.from, part.to, part.flip);
                self.at(arrive, Ev::Arrive { lane: i, epoch, block, from, to, flip });
                self.scheduler.written(id, self.now);
                if part.last {
                    self.scheduler.sent(id, KEY, part.block, self.now);
                }
                self.transmit(i);
                self.act();
            }
            Ev::Arrive { lane, epoch, block, from, to, flip } => {
                if self.lanes[lane].epoch != epoch {
                    return;
                }
                if self.bytes.is_some() {
                    return self.arrive_bytes(lane, block, from, to, flip);
                }
                if self.complete[block as usize] {
                    // A late copy: dropped, and answered with a HAVE for that block once per lane, as the HAVE that
                    // said so may have gone with a lane that fell silent.
                    self.out.wasted_bytes += to - from;
                    if self.answered.insert((lane, block)) {
                        self.send_back(lane, block, false);
                    }
                    return;
                }
                let (start, len) = self.geometry.span(block);
                let bits = &mut self.covered[block as usize];
                let mut fresh = false;
                for g in (from - start) / GRANULE..(to - start).div_ceil(GRANULE) {
                    let (word, bit) = ((g / 64) as usize, g % 64);
                    fresh |= bits[word] & (1 << bit) == 0;
                    bits[word] |= 1 << bit;
                }
                if !fresh {
                    self.out.wasted_bytes += to - from;
                }
                let needed = (len as u64).div_ceil(GRANULE).max(1);
                let have: u64 = bits.iter().map(|w| u64::from(w.count_ones())).sum();
                if have >= needed {
                    self.complete[block as usize] = true;
                    self.out.lanes[lane].completed += 1;
                    self.out.last_route = self.lanes[lane].profile.route;
                    self.send_back(lane, block, false);
                }
            }
            Ev::Back { lane, epoch, block, want } => {
                if self.lanes[lane].epoch != epoch {
                    self.send_back(lane, block, want);
                    return;
                }
                let id = self.lanes[lane].id;
                self.scheduler.heard(id, self.now);
                if want {
                    self.scheduler.want(KEY, &[(block, 1)], self.now).expect("in range");
                    self.act();
                    return;
                }
                self.scheduler.have(KEY, &[(block, 1)], self.now).expect("in range");
                if self.scheduler.is_done(KEY) {
                    self.out.done_at = Some(self.now);
                    return;
                }
                self.act();
            }
            Ev::Ping(i) => {
                if self.lanes[i].state != State::Up {
                    return;
                }
                let t = self.lanes[i].profile.advance(self.now, self.lanes[i].profile.rtt / 2);
                let epoch = self.lanes[i].epoch;
                self.at(t, Ev::Heard(i, epoch));
                self.at(self.now + Duration::from_secs(1), Ev::Ping(i));
            }
            Ev::Heard(i, epoch) => {
                if self.lanes[i].epoch == epoch && self.lanes[i].state == State::Up {
                    self.scheduler.heard(self.lanes[i].id, self.now);
                }
            }
            Ev::Timer => {
                if self.timer_at == Some(self.now) {
                    self.timer_at = None;
                    self.scheduler.tick(self.now);
                    self.act();
                }
            }
        }
    }
}

// ----- scenarios from JSON (friends/fixtures/scheduler/scenarios.json) -----

fn route_named(name: &str) -> Option<RouteMethod> {
    Some(match name {
        "lan" => RouteMethod::Lan,
        "direct-wifi" => RouteMethod::PeerToPeerWifi,
        "internet" => RouteMethod::Internet,
        "relay" => RouteMethod::Relay,
        "bluetooth" => RouteMethod::Bluetooth,
        _ => return None,
    })
}

pub fn route_name(route: RouteMethod) -> &'static str {
    match route {
        RouteMethod::Lan => "lan",
        RouteMethod::PeerToPeerWifi => "direct-wifi",
        RouteMethod::Internet => "internet",
        RouteMethod::Relay => "relay",
        RouteMethod::Bluetooth => "bluetooth",
        RouteMethod::None => "none",
    }
}

fn ms(value: &Value) -> Option<Duration> {
    value.as_f64().map(|v| Duration::from_secs_f64(v / 1000.0))
}

impl LaneProfile {
    /// `{"route": "lan", "mbit": 940, "rtt_ms": 2, "loss": 0, "part_bytes": 61440, "up_ms": 0 | null, "dial_ms",
    /// "cut_ms", "detect_ms", "silences_ms": [[from, to]], "flapping_ms": {"from", "period", "off", "until"}}`.
    /// Missing fields take [`LaneProfile::new`]'s values; `"up_ms": null` means only when asked for.
    pub fn from_json(value: &Value) -> Option<Self> {
        let route = route_named(value.get("route")?.as_str()?)?;
        let mut lane = Self::new(route, value.get("mbit")?.as_f64()? * 1e6 / 8.0, value.get("rtt_ms")?.as_u64()?);
        if let Some(loss) = value.get("loss").and_then(Value::as_f64) {
            lane.loss = loss;
        }
        if let Some(bytes) = value.get("part_bytes").and_then(Value::as_u64) {
            lane.part_bytes = bytes;
        }
        if let Some(up) = value.get("up_ms") {
            lane.up_at = ms(up);
        }
        if let Some(dial) = value.get("dial_ms").and_then(ms) {
            lane.dial = dial;
        }
        lane.cut_at = value.get("cut_ms").and_then(ms);
        if let Some(detect) = value.get("detect_ms").and_then(ms) {
            lane.detect = detect;
        }
        for window in value.get("silences_ms").and_then(Value::as_array).into_iter().flatten() {
            let pair = window.as_array()?;
            lane.silences.push((ms(pair.first()?)?, ms(pair.get(1)?)?));
        }
        if let Some(f) = value.get("flapping_ms") {
            let get = |k: &str| f.get(k).and_then(ms);
            lane = lane.flapping(get("from")?, get("period")?, get("off")?, get("until")?);
        }
        lane.silences.sort_by_key(|w| w.0);
        Some(lane)
    }
}

impl Scenario {
    /// `{"name", "mib": size in MiB, "seed", "limit_s", "phone", "direct_wifi_keeps_internet", "lanes": [...]}`.
    pub fn from_json(value: &Value) -> Option<Self> {
        let flag = |k: &str| value.get(k).and_then(Value::as_bool).unwrap_or(false);
        Some(Self {
            name: value.get("name")?.as_str()?.to_owned(),
            size: (value.get("mib")?.as_f64()? * (1u64 << 20) as f64) as u64,
            config: Config { phone: flag("phone"), direct_wifi_keeps_internet: flag("direct_wifi_keeps_internet") },
            lanes: value.get("lanes")?.as_array()?.iter().map(LaneProfile::from_json).collect::<Option<_>>()?,
            seed: value.get("seed").and_then(Value::as_u64).unwrap_or(1),
            limit: Duration::from_secs(value.get("limit_s").and_then(Value::as_u64).unwrap_or(3600)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIB: u64 = 1 << 20;

    fn mbit(m: f64) -> f64 {
        m * 1e6 / 8.0
    }

    fn scenario(name: &str, size: u64, lanes: Vec<LaneProfile>) -> Scenario {
        Scenario {
            name: name.into(),
            size,
            config: Config::default(),
            lanes,
            seed: 7,
            limit: Duration::from_secs(3600),
        }
    }

    #[test]
    fn silences_hold_time() {
        let lane = LaneProfile::new(RouteMethod::Lan, 1e6, 2).flapping(
            Duration::from_secs(1),
            Duration::from_secs(2),
            Duration::from_secs(1),
            Duration::from_secs(4),
        );
        let s = Duration::from_secs_f64;
        assert_eq!(lane.advance(s(0.5), s(0.25)), s(0.75));
        assert_eq!(lane.advance(s(0.5), s(1.0)), s(2.5));
        assert_eq!(lane.advance(s(1.5), s(0.25)), s(2.25));
        assert_eq!(lane.advance(s(0.5), s(2.0)), s(4.5));
    }

    #[test]
    fn one_lane_runs_at_its_rate() {
        let sc = scenario("lan", 256 * MIB, vec![LaneProfile::new(RouteMethod::Lan, mbit(940.0), 2)]);
        let out = run(&sc);
        let ideal = sc.size as f64 / mbit(940.0);
        let took = out.done_at.unwrap().as_secs_f64();
        assert!(took < ideal * 1.03, "{took} s against {ideal} s");
        assert_eq!(out.wasted_bytes, 0);
    }

    #[test]
    fn real_bytes_arrive_through_the_assembly_with_corrupt_blocks_wanted_again() {
        // WP1's types on both ends: a slow LAN, Bluetooth beside it going silent, direct Wi-Fi cut, three blocks
        // damaged on the way. Every block checks and the file is the file.
        let mut cut = LaneProfile::new(RouteMethod::PeerToPeerWifi, mbit(40.0), 4);
        cut.cut_at = Some(Duration::from_secs(2));
        let lanes = vec![
            LaneProfile::new(RouteMethod::Lan, mbit(24.0), 3),
            LaneProfile::new(RouteMethod::Bluetooth, mbit(1.4), 30).silent_from(Duration::from_secs(4)),
            cut,
        ];
        let mut sc = scenario("bytes", 24 * MIB + 12_345, lanes);
        sc.config.direct_wifi_keeps_internet = true;
        let out = run_with_bytes(&sc, &[0, 5, 24]);
        assert!(out.verified, "{out:?}");
        // A damaged copy can also be lost with its lane, or overtaken by a clean second copy.
        assert!((2..=3).contains(&out.corrupt_blocks), "{}", out.corrupt_blocks);
        assert!(out.max_open_blocks <= 64 && !out.lane_cap_exceeded);
    }

    #[test]
    fn every_block_arrives_whatever_the_lanes_do() {
        // Property: random lanes, random cuts and silences; one lane always survives. No block is lost, § 3 and the
        // per-lane caps hold, nothing hangs.
        let routes = [RouteMethod::Lan, RouteMethod::PeerToPeerWifi, RouteMethod::Internet, RouteMethod::Bluetooth];
        let mut random = Random(42);
        for case in 0..150 {
            let count = 1 + (random.next() * 4.0) as usize;
            let mut lanes = Vec::new();
            for i in 0..count {
                let route = routes[(random.next() * routes.len() as f64) as usize];
                let rate = match route {
                    RouteMethod::Bluetooth => mbit(0.5 + random.next() * 1.5),
                    _ => mbit(5.0 + random.next() * 900.0),
                };
                let mut lane = LaneProfile::new(route, rate, 1 + (random.next() * 80.0) as u64);
                lane.loss = if random.next() < 0.3 { random.next() * 0.05 } else { 0.0 };
                if i > 0 {
                    lane.up_at = Some(Duration::from_secs_f64(random.next() * 2.0));
                    let at = Duration::from_secs_f64(random.next() * 3.0);
                    match (random.next() * 4.0) as u32 {
                        0 => lane.cut_at = Some(at),
                        1 => lane = lane.silent_from(at),
                        2 => lane = lane.flapping(at, Duration::from_secs(2), Duration::from_secs(1), at * 20),
                        _ => {}
                    }
                }
                lanes.push(lane);
            }
            let size = (1 + (random.next() * 96.0) as u64) * MIB - (random.next() * 4096.0) as u64;
            let mut sc = scenario(&format!("random {case}"), size, lanes);
            sc.seed = case;
            let out = run(&sc);
            assert!(out.done_at.is_some(), "{case}: did not finish: {sc:?} {out:?}");
            assert!(out.max_open_blocks <= 64 && out.max_open_bytes <= 64 * MIB, "{case}");
            assert!(!out.lane_cap_exceeded, "{case}");
            let useful = out.sent_bytes - out.wasted_bytes;
            assert!(useful >= sc.size, "{case}: {useful} useful of {}", sc.size);
        }
    }

    #[test]
    fn a_silent_lane_delays_completion_by_its_detection_time_at_most() {
        // The same lanes, one going silent or being cut (noticed at once) at the same moment: silence may cost the
        // time it takes to notice it, no more.
        for (route, rate, rtt, detect) in [
            (RouteMethod::PeerToPeerWifi, mbit(300.0), 4, 1.0),
            (RouteMethod::Bluetooth, mbit(1.4), 30, 2.0),
            (RouteMethod::Lan, mbit(100.0), 2, 1.0),
        ] {
            for at in [0.5, 2.0, 4.0] {
                let base = LaneProfile::new(
                    RouteMethod::Lan,
                    mbit(if route == RouteMethod::Bluetooth { 16.0 } else { 300.0 }),
                    2,
                );
                let silent = LaneProfile::new(route, rate, rtt).silent_from(Duration::from_secs_f64(at));
                let mut cut = LaneProfile::new(route, rate, rtt);
                cut.cut_at = Some(Duration::from_secs_f64(at));
                cut.detect = Duration::ZERO;
                let size = 160 * MIB;
                let quiet = run(&scenario("silent", size, vec![base.clone(), silent])).done_at.unwrap();
                let gone = run(&scenario("cut", size, vec![base, cut])).done_at.unwrap();
                let slack = quiet.as_secs_f64() - gone.as_secs_f64();
                assert!(slack <= detect + 0.1, "{route:?} silent at {at} s: {quiet:?} against {gone:?}");
            }
        }
    }
}
