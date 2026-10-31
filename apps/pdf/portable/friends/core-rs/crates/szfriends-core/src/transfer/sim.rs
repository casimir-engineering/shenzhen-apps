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
    /// The sender's socket buffer: a write completes once its part is in it, before the part crosses (0: a write
    /// completes as its part crosses). A path with a deep buffer looks busy, and a block all written, while its
    /// route is silent.
    pub buffer: u64,
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
            buffer: 0,
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

    /// Whether the route is silent at `t`.
    pub fn silent_at(&self, t: Duration) -> bool {
        self.silences.iter().any(|&(from, to)| from <= t && t < to)
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
    /// The scheduler's unit: `None` for the file's blocks (WP2's rows), `Some(18)` for 256 KiB slices, as the helpers
    /// schedule with a peer that has pieces.
    pub unit_shift: Option<u8>,
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
    /// When it came up, and when its first part was written (ADR 0020: a new route carries at once).
    pub up_at: Option<Duration>,
    pub first_write: Option<Duration>,
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
    /// Bytes the relay wrote while a direct lane worked (up, not silent, not cut): ADR 0020 allows one part in
    /// crossing at most.
    pub relay_beside_direct_bytes: u64,
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
    /// With a socket buffer: parts written, not yet across (the one crossing included), and their bytes.
    buffered: VecDeque<Part>,
    buffered_bytes: u64,
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
    let blocks = Geometry::for_size(scenario.size).expect("a size with a geometry");
    let geometry = match scenario.unit_shift {
        Some(unit) if bytes.is_none() => super::slices::unit_geometry(&blocks, unit.min(blocks.shift)),
        _ => blocks,
    };
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
            buffered: VecDeque::new(),
            buffered_bytes: 0,
        })
        .collect();
    let granules = geometry.block_bytes().div_ceil(GRANULE).div_ceil(64) as usize;
    let mut sim = Sim {
        geometry,
        now: Duration::ZERO,
        seq: 0,
        queue: BTreeMap::new(),
        timer_at: None,
        group: LaneGroup::new(lanes[0].id, [0; 32], true, first.route, |i| [i; 16]),
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

#[path = "sim_events.rs"]
mod events;

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
    /// "cut_ms", "detect_ms", "silences_ms": [[from, to]], "flapping_ms": {"from", "period", "off", "until"},
    /// "buffer_kib"}`.
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
        if let Some(kib) = value.get("buffer_kib").and_then(Value::as_u64) {
            lane.buffer = kib << 10;
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
    /// `{"name", "mib": size in MiB, "seed", "limit_s", "phone", "direct_wifi_keeps_internet", "unit_kib": 256 for
    /// slices, "lanes": [...]}`.
    pub fn from_json(value: &Value) -> Option<Self> {
        let flag = |k: &str| value.get(k).and_then(Value::as_bool).unwrap_or(false);
        Some(Self {
            name: value.get("name")?.as_str()?.to_owned(),
            size: (value.get("mib")?.as_f64()? * (1u64 << 20) as f64) as u64,
            config: Config { phone: flag("phone"), direct_wifi_keeps_internet: flag("direct_wifi_keeps_internet") },
            lanes: value.get("lanes")?.as_array()?.iter().map(LaneProfile::from_json).collect::<Option<_>>()?,
            seed: value.get("seed").and_then(Value::as_u64).unwrap_or(1),
            limit: Duration::from_secs(value.get("limit_s").and_then(Value::as_u64).unwrap_or(3600)),
            unit_shift: value.get("unit_kib").and_then(Value::as_u64).map(|kib| (kib * 1024).trailing_zeros() as u8),
        })
    }
}

#[cfg(test)]
#[path = "sim_tests.rs"]
mod tests;
