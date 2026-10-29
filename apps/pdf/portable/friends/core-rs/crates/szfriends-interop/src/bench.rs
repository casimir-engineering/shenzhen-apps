//! What the transfer bench and the interop matrix share (ADR 0018 § Verification; `examples/transfer_bench.rs`,
//! `examples/transfer_interop.rs`): emulated routes, peers run as processes of their own, and one measured transfer
//! between two of them through the shaping [`Proxy`], with a cut or a silence when asked. Run on demand only
//! (`make friends-transfer-bench`, `make friends-transfer-interop`); no suite runs them.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::{befriend, keys, listen, write_content, ObjcPeer, Peer, Proxy, Tamper, TempHome};

pub const MIB: u64 = 1 << 20;

/// A route as the proxy emulates it. Rates and delays are plausible, not measured on hardware (the journal of
/// 2026-10-29 has the reasoning); the class is what the dialing side declares, which sets chunk size and window.
#[derive(Clone, Copy, Debug)]
pub struct RouteProfile {
    pub name: &'static str,
    pub class: &'static str,
    pub bytes_per_second: Option<u64>,
    pub one_way_ms: u64,
    pub loss_per_million: u32,
}

pub const LOOPBACK: RouteProfile =
    RouteProfile { name: "loopback", class: "lan", bytes_per_second: None, one_way_ms: 0, loss_per_million: 0 };
pub const LAN: RouteProfile =
    RouteProfile { name: "lan", class: "lan", bytes_per_second: Some(117_500_000), one_way_ms: 1, loss_per_million: 0 };
pub const P2P_WIFI: RouteProfile = RouteProfile {
    name: "p2p_wifi",
    class: "p2p_wifi",
    bytes_per_second: Some(37_500_000),
    one_way_ms: 2,
    loss_per_million: 0,
};
pub const INTERNET: RouteProfile = RouteProfile {
    name: "internet",
    class: "internet",
    bytes_per_second: Some(6_250_000),
    one_way_ms: 20,
    loss_per_million: 0,
};
/// ADR 0018's long lossy path: 150 ms and 1 % loss.
pub const INTERNET_LOSSY: RouteProfile = RouteProfile {
    name: "internet_lossy",
    class: "internet",
    bytes_per_second: Some(6_250_000),
    one_way_ms: 75,
    loss_per_million: 10_000,
};
pub const RELAY: RouteProfile = RouteProfile {
    name: "relay",
    class: "relay",
    bytes_per_second: Some(625_000),
    one_way_ms: 40,
    loss_per_million: 0,
};
pub const BLUETOOTH: RouteProfile = RouteProfile {
    name: "bluetooth",
    class: "bluetooth",
    bytes_per_second: Some(175_000),
    one_way_ms: 15,
    loss_per_million: 0,
};

/// A slow shared network (10 Mbit/s), for ADR 0018's case of Bluetooth helping it.
pub const LAN_SLOW: RouteProfile = RouteProfile {
    name: "lan_slow",
    class: "lan",
    bytes_per_second: Some(1_250_000),
    one_way_ms: 2,
    loss_per_million: 0,
};

pub const ROUTES: [RouteProfile; 7] = [LOOPBACK, LAN, P2P_WIFI, INTERNET, INTERNET_LOSSY, RELAY, BLUETOOTH];

impl RouteProfile {
    pub fn named(name: &str) -> Option<Self> {
        ROUTES.iter().copied().chain([LAN_SLOW]).find(|r| r.name == name)
    }

    pub fn tamper(&self) -> Tamper {
        Tamper {
            bytes_per_second: self.bytes_per_second,
            one_way_delay: (self.one_way_ms > 0).then(|| Duration::from_millis(self.one_way_ms)),
            loss_per_million: self.loss_per_million,
            ..Tamper::default()
        }
    }

    /// What one TCP connection can carry on this route: the rate, or less under loss (Mathis et al.); `None` when
    /// unlimited.
    pub fn expected_bytes_per_second(&self) -> Option<f64> {
        let rate = self.bytes_per_second? as f64;
        if self.loss_per_million == 0 {
            return Some(rate);
        }
        let round_trip = (2 * self.one_way_ms).max(1) as f64 / 1000.0;
        let loss = self.loss_per_million as f64 / 1e6;
        Some(rate.min(1448.0 / round_trip * 1.22 / loss.sqrt()))
    }
}

/// What happens to the route once `fraction` of the payload passed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Loss {
    None,
    /// Both sockets shut: a lost Wi-Fi link.
    Cut(f64),
    /// Nothing moves any more, sockets open: out of range.
    Silence(f64),
}

/// A peer program speaking the session peer protocol (`tools/objc-session-peer`, `examples/session_peer.rs`), run as
/// `<program...> <home> <name>`.
#[derive(Clone, Debug)]
pub struct PeerSpec {
    /// Short name in tables: "rust", "objc", "rust-0.2.4", "objc-26.10.29-1".
    pub label: String,
    pub program: Vec<String>,
    /// Whether its `dial` takes a route class (peers before WP5 always declare LAN).
    pub declares_route: bool,
    /// Whether it is one of today's peers (its minor is this core's) or a released one.
    pub released: bool,
}

impl PeerSpec {
    pub fn local(label: &str, binary: &Path, released: bool) -> Self {
        Self {
            label: label.to_owned(),
            program: vec![binary.to_string_lossy().into_owned()],
            declares_route: !released,
            released,
        }
    }

    pub fn start(&self, home: &Path, name: &str) -> ObjcPeer {
        let mut command = Command::new(&self.program[0]);
        command.args(&self.program[1..]).arg(home).arg(name);
        ObjcPeer::spawn(command)
    }
}

/// Today's Rust peer next to this program (`target/<profile>/examples/session_peer`), or `$SZFRIENDS_RUST_PEER`.
pub fn rust_peer_binary() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("SZFRIENDS_RUST_PEER") {
        return Some(path.into());
    }
    let here = std::env::current_exe().ok()?;
    let path = here.parent()?.join(format!("session_peer{}", std::env::consts::EXE_SUFFIX));
    path.exists().then_some(path)
}

/// One measured transfer.
#[derive(Clone, Debug)]
pub struct Case {
    pub name: String,
    pub route: RouteProfile,
    pub files: Vec<u64>,
    pub loss: Loss,
    /// How long a silent route may go unnoticed before the harness dials again anyway.
    pub silence_wait: Duration,
}

/// The events one peer reported, with when they arrived.
struct Log {
    events: Vec<(Instant, Value)>,
}

impl Log {
    fn new() -> Self {
        Self { events: Vec::new() }
    }

    /// Waits until an event from index `from` on matches, pulling new ones from `peer`.
    fn wait(
        &mut self,
        peer: &mut dyn Peer,
        from: usize,
        timeout: Duration,
        matches: impl Fn(&Value) -> bool,
    ) -> Option<(Instant, Value)> {
        let deadline = Instant::now() + timeout;
        let mut index = from;
        loop {
            while index < self.events.len() {
                if matches(&self.events[index].1) {
                    return Some(self.events[index].clone());
                }
                index += 1;
            }
            let left = deadline.checked_duration_since(Instant::now())?;
            match peer.next_event(left.min(Duration::from_millis(50))) {
                Some(event) => self.events.push((Instant::now(), event)),
                None if Instant::now() >= deadline => return None,
                None => {}
            }
        }
    }

    fn drain(&mut self, peer: &mut dyn Peer) {
        while let Some(event) = peer.next_event(Duration::ZERO) {
            self.events.push((Instant::now(), event));
        }
    }
}

fn cpu_seconds(pid: u32) -> f64 {
    let Ok(out) = Command::new("ps").args(["-o", "cputime=", "-p", &pid.to_string()]).output() else { return 0.0 };
    // [[dd-]hh:]mm:ss.cc
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .split([':', '-'])
        .fold(0.0, |total, part| total * 60.0 + part.trim().parse::<f64>().unwrap_or(0.0))
}

/// BLAKE2b-256 of a file, as the transfer digest.
pub fn digest_of(path: &Path) -> Option<[u8; 32]> {
    use blake2::digest::{Update, VariableOutput};
    use std::io::Read;
    let mut file = std::fs::File::open(path).ok()?;
    let mut digest = blake2::Blake2bVar::new(32).ok()?;
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buffer).ok()?;
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
    }
    let mut out = [0u8; 32];
    digest.finalize_variable(&mut out).ok()?;
    Some(out)
}

fn is(kind: &'static str) -> impl Fn(&Value) -> bool {
    move |e: &Value| e["event"] == kind
}

/// Runs `case` from a `sender` to a `receiver` started fresh in temporary homes, and reports it as one JSON object:
/// seconds, MB/s, share of the emulated rate, each side's CPU time, the negotiated minor, whether the received bytes
/// match, and for a cut or silence when it was noticed, where it resumed and how long recovery took. A failure is
/// reported in `error`, never a panic.
pub fn run(case: &Case, sender: &PeerSpec, receiver: &PeerSpec) -> Value {
    let mut result = json!({
        "case": case.name, "sender": sender.label, "receiver": receiver.label, "route": case.route.name,
        "files": case.files.len(), "bytes": case.files.iter().sum::<u64>(),
    });
    if let Err(error) = measure(case, sender, receiver, &mut result) {
        result["error"] = json!(error);
    }
    result
}

fn measure(case: &Case, sender_spec: &PeerSpec, receiver_spec: &PeerSpec, result: &mut Value) -> Result<(), String> {
    let homes = (TempHome::new("bench-s"), TempHome::new("bench-r"), TempHome::new("bench-content"));
    let mut sender = sender_spec.start(&homes.0.path().join("state"), "Sender");
    let mut receiver = receiver_spec.start(&homes.1.path().join("state"), "Receiver");
    let (pid_s, pid_r) = (sender.pid(), receiver.pid());
    befriend(&mut sender, &mut receiver, ("Sender", "Receiver"));
    let (keys_s, keys_r) = (keys(&mut sender), keys(&mut receiver));
    // The newest minor each side speaks; peers before WP5 do not say (released apps speak 3).
    for (key, peer) in [("sender_session_minor", &mut sender), ("receiver_session_minor", &mut receiver)] {
        result[key] = peer.command(json!({ "cmd": "hello" }))["session_minor"].clone();
    }
    let (mut log_s, mut log_r) = (Log::new(), Log::new());
    let total: u64 = case.files.iter().sum();
    // A peer that declares its route dials, so the session's class is the emulated route's.
    let sender_dials = sender_spec.declares_route || !receiver_spec.declares_route;
    let declared = if sender_dials { sender_spec.declares_route } else { receiver_spec.declares_route };
    result["declared_route"] = json!(if declared { case.route.class } else { "lan" });
    let port = listen(if sender_dials { &mut receiver } else { &mut sender });
    let proxy = Proxy::start(port);
    let mut tamper = case.route.tamper();
    match case.loss {
        Loss::None => {}
        Loss::Cut(fraction) if sender_dials => tamper.cut_to_listener_after = Some((total as f64 * fraction) as u64),
        Loss::Cut(fraction) => tamper.cut_to_dialer_after = Some((total as f64 * fraction) as u64),
        Loss::Silence(fraction) => tamper.silence_after = Some((total as f64 * fraction) as u64),
    }
    proxy.set(tamper);
    let remote = if sender_dials { &keys_r } else { &keys_s };
    let dial = json!({
        "cmd": "dial", "port": proxy.port(), "pattern": "IK", "remote_static": remote.static_key,
        "expected_identity": remote.identity, "route": case.route.class,
    });
    let step = Duration::from_secs(30);
    {
        let dialer: &mut ObjcPeer = if sender_dials { &mut sender } else { &mut receiver };
        dialer.command(dial.clone());
    }
    let (_, live_s) =
        log_s.wait(&mut sender, 0, step, is("established")).ok_or("the sender's session never came up")?;
    let (_, live_r) =
        log_r.wait(&mut receiver, 0, step, is("established")).ok_or("the receiver's session never came up")?;
    result["minor"] = live_s["minor"].clone();
    if live_r["minor"] != live_s["minor"] {
        return Err(format!("the two sides negotiated different minors: {live_s} and {live_r}"));
    }
    for key in ["fast", "capabilities"] {
        if !live_s[key].is_null() {
            result[key] = live_s[key].clone();
        }
    }
    let session = live_s["session"].as_u64().ok_or("no session id")?;
    let mut digests = Vec::new();
    let mut paths = Vec::new();
    for (index, size) in case.files.iter().enumerate() {
        let path = homes.2.path().join(format!("file-{index}.bin"));
        digests.push(write_content(&path, &format!("bench {} {index}", case.name), *size));
        paths.push(path);
    }
    let (cpu_s0, cpu_r0) = (cpu_seconds(pid_s), cpu_seconds(pid_r));
    let started = Instant::now();
    let mut ids = Vec::new();
    for path in &paths {
        let offer = sender.command(json!({ "cmd": "send_file", "session": session, "path": path.to_string_lossy() }));
        let id = offer["transfer"].as_str().ok_or_else(|| format!("send_file failed: {offer}"))?.to_owned();
        ids.push(id);
    }
    result["offer_seconds"] = json!(started.elapsed().as_secs_f64());
    let expected = case.route.expected_bytes_per_second().map_or(60.0, |rate| total as f64 / rate);
    let long = Duration::from_secs_f64(expected * 4.0 + 120.0);
    if case.loss != Loss::None {
        recover(
            case,
            &mut (&mut sender, &mut log_s),
            &mut (&mut receiver, &mut log_r),
            &proxy,
            sender_dials,
            &dial,
            result,
        )?;
    }
    let mut received = Vec::new();
    for id in &ids {
        let (_, event) = log_r
            .wait(&mut receiver, 0, long, |e| e["event"] == "received_file" && e["transfer"] == id.as_str())
            .ok_or_else(|| format!("{id} not received within {long:?}"))?;
        received.push(PathBuf::from(event["path"].as_str().unwrap_or_default()));
    }
    let seconds = started.elapsed().as_secs_f64();
    let (cpu_s, cpu_r) = (cpu_seconds(pid_s) - cpu_s0, cpu_seconds(pid_r) - cpu_r0);
    for id in &ids {
        log_s
            .wait(&mut sender, 0, step, |e| e["event"] == "delivered" && e["transfer"] == id.as_str())
            .ok_or_else(|| format!("{id} received but its sender never heard"))?;
    }
    let failed = log_s.events.iter().chain(&log_r.events).find(|(_, e)| e["event"] == "transfer_failed");
    if let Some((_, event)) = failed {
        return Err(format!("a transfer failed on the way: {event}"));
    }
    let intact = received.iter().zip(&digests).all(|(path, digest)| digest_of(path).as_ref() == Some(digest));
    result["seconds"] = json!(seconds);
    result["mbyte_per_s"] = json!(total as f64 / seconds / 1e6);
    if let Some(rate) = case.route.expected_bytes_per_second() {
        result["link_share"] = json!(total as f64 / seconds / rate);
    }
    result["cpu_sender_s"] = json!(cpu_s);
    result["cpu_receiver_s"] = json!(cpu_r);
    result["cpu_sender_s_per_gb"] = json!(cpu_s / (total as f64 / 1e9));
    result["cpu_receiver_s_per_gb"] = json!(cpu_r / (total as f64 / 1e9));
    result["intact"] = json!(intact);
    if !intact {
        return Err("the received bytes differ from the sent ones".into());
    }
    Ok(())
}

type Side<'a, 'b> = (&'a mut ObjcPeer, &'b mut Log);

/// After a cut or a silence: who noticed and when, then the route comes back (the harness dials again through the
/// proxy, now without loss, as the route racer would), and where and how soon the sender resumed.
fn recover(
    case: &Case,
    sender: &mut Side,
    receiver: &mut Side,
    proxy: &Proxy,
    sender_dials: bool,
    dial: &Value,
    result: &mut Value,
) -> Result<(), String> {
    let expected =
        case.route.expected_bytes_per_second().map_or(60.0, |rate| case.files.iter().sum::<u64>() as f64 / rate);
    let deadline = Instant::now() + Duration::from_secs_f64(expected * 2.0 + 60.0);
    let lost_at = loop {
        if let Some(at) = proxy.lost_at() {
            break at;
        }
        if Instant::now() > deadline {
            return Err("the route was never lost: the transfer ended first".into());
        }
        sender.1.drain(sender.0);
        receiver.1.drain(receiver.0);
        std::thread::sleep(Duration::from_millis(5));
    };
    let (to_listener, to_dialer) = proxy.counts();
    result["lost_after_bytes"] = json!(if sender_dials { to_listener } else { to_dialer });
    let (from_s, from_r) = (sender.1.events.len(), receiver.1.events.len());
    let window = match case.loss {
        Loss::Silence(_) => case.silence_wait,
        _ => Duration::from_secs(30),
    };
    // Whoever notices first: watch both sides in turn until the window ends.
    let until = lost_at + window;
    let mut noticed = None;
    let short = Duration::from_millis(20);
    while noticed.is_none() && Instant::now() < until {
        noticed = sender
            .1
            .wait(sender.0, from_s, short, is("closed"))
            .or_else(|| receiver.1.wait(receiver.0, from_r, short, is("closed")))
            .map(|(at, _)| at.duration_since(lost_at).as_secs_f64());
    }
    result["noticed_s"] = json!(noticed);
    let from_s = sender.1.events.len();
    proxy.set(case.route.tamper());
    let dialer: &mut ObjcPeer = if sender_dials { sender.0 } else { receiver.0 };
    let reply = dialer.command(dial.clone());
    if reply["session"].is_null() {
        return Err(format!("the second dial failed: {reply}"));
    }
    let (at, resumed) = sender
        .1
        .wait(sender.0, from_s, Duration::from_secs(60), is("sending"))
        .ok_or("the sender never resumed on the new route")?;
    result["resume_offset"] = resumed["offset"].clone();
    result["resent_bytes"] =
        json!(result["lost_after_bytes"].as_u64().unwrap_or(0).saturating_sub(resumed["offset"].as_u64().unwrap_or(0)));
    result["recovery_s"] = json!(at.duration_since(lost_at).as_secs_f64());
    Ok(())
}

/// Runs `case` with panics caught, so one broken pair never stops a matrix.
pub fn run_caught(case: &Case, sender: &PeerSpec, receiver: &PeerSpec) -> Value {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(case, sender, receiver))).unwrap_or_else(|panic| {
        let why = panic
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| panic.downcast_ref::<&str>().map(|s| (*s).to_owned()))
            .unwrap_or_default();
        json!({ "case": case.name, "sender": sender.label, "receiver": receiver.label, "route": case.route.name,
                "error": format!("panicked: {why}") })
    })
}

/// Appends one JSON line to `path`.
pub fn append(path: &Path, value: &Value) {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).expect("the results file");
    writeln!(file, "{value}").expect("written");
}

/// "1 MiB", "300 × 10 KiB": a case's payload for tables.
pub fn payload(files: &[u64]) -> String {
    let size = |b: u64| match b {
        b if b >= 1 << 30 && b % (1 << 30) == 0 => format!("{} GiB", b >> 30),
        b if b >= MIB && b % MIB == 0 => format!("{} MiB", b >> 20),
        b if b % 1024 == 0 => format!("{} KiB", b >> 10),
        b => format!("{b} B"),
    };
    match files {
        [one] => size(*one),
        [first, ..] if files.iter().all(|f| f == first) => format!("{} × {}", files.len(), size(*first)),
        _ => format!("{} files, {}", files.len(), size(files.iter().sum())),
    }
}

fn cell(value: &Value, digits: usize) -> String {
    value.as_f64().map_or_else(|| "–".to_owned(), |v| format!("{v:.digits$}"))
}

/// The bench's table, one row per result: what an agent or the owner reads at the end of a run.
pub fn table(results: &[Value]) -> String {
    let mut rows = vec![[
        "case",
        "sender → receiver",
        "payload",
        "s",
        "MB/s",
        "% link",
        "CPU s/GB send",
        "CPU s/GB recv",
        "noticed s",
        "recovery s",
    ]
    .map(str::to_owned)];
    for r in results {
        let pair = format!("{} → {}", r["sender"].as_str().unwrap_or("?"), r["receiver"].as_str().unwrap_or("?"));
        let case = r["case"].as_str().unwrap_or("?").to_owned();
        let payload = r["payload"].as_str().unwrap_or("").to_owned();
        if let Some(why) = r["skipped"].as_str().or(r["error"].as_str()) {
            let label = if r["skipped"].is_null() { "FAILED: " } else { "skipped: " };
            rows.push([
                case,
                pair,
                payload,
                format!("{label}{why}"),
                String::new(),
                String::new(),
                String::new(),
                String::new(),
                String::new(),
                String::new(),
            ]);
            continue;
        }
        let share = r["link_share"].as_f64().map_or_else(|| "–".to_owned(), |s| format!("{:.0} %", s * 100.0));
        let noticed = match (&r["noticed_s"], r["recovery_s"].is_null()) {
            (Value::Null, false) => format!("not in {}", r["silence_wait_s"].as_f64().unwrap_or(0.0)),
            (v, _) => cell(v, 3),
        };
        // ps counts CPU in hundredths of a second: per GB it means something from about 50 MB on.
        let per_gb =
            |key: &str| if r["bytes"].as_u64().unwrap_or(0) < 50_000_000 { "–".into() } else { cell(&r[key], 2) };
        rows.push([
            case,
            pair,
            payload,
            cell(&r["seconds"], 2),
            cell(&r["mbyte_per_s"], 1),
            share,
            per_gb("cpu_sender_s_per_gb"),
            per_gb("cpu_receiver_s_per_gb"),
            noticed,
            cell(&r["recovery_s"], 3),
        ]);
    }
    let widths: Vec<usize> = (0..10).map(|i| rows.iter().map(|r| r[i].chars().count()).max().unwrap_or(0)).collect();
    let mut out = String::new();
    for (index, row) in rows.iter().enumerate() {
        let cells: Vec<String> = row.iter().zip(&widths).map(|(c, w)| format!("{c:<w$}")).collect();
        out.push_str(&format!("| {} |\n", cells.join(" | ")));
        if index == 0 {
            let rule: Vec<String> = widths.iter().map(|w| "-".repeat(*w)).collect();
            out.push_str(&format!("|-{}-|\n", rule.join("-|-")));
        }
    }
    out
}

/// One transfer over several emulated routes between the same two peers at once (ADR 0018 § 6, 7): the first route
/// carries the session, each other one a lane of it; `lost` cuts or silences one route once the whole transfer is
/// at that fraction. Needs peers whose `hello` says `"lanes": true` and whose `dial` takes `"lane_of"` (the session
/// the lane joins); until then the case is reported as skipped.
#[derive(Clone, Debug)]
pub struct MultiCase {
    pub name: String,
    pub routes: Vec<RouteProfile>,
    pub files: Vec<u64>,
    /// Which route (index into `routes`) and what happens to it.
    pub lost: Option<(usize, Loss)>,
}

impl MultiCase {
    /// What the routes carry together, and what the fastest alone carries.
    pub fn rates(&self) -> (f64, f64) {
        let rates: Vec<f64> = self.routes.iter().filter_map(RouteProfile::expected_bytes_per_second).collect();
        (rates.iter().sum(), rates.iter().copied().fold(0.0, f64::max))
    }
}

/// Runs a [`MultiCase`]; reported like [`run`], plus `route_bytes` (what each route carried), `best_route_share`
/// (against the fastest route alone) and, after a loss, when a side noticed the lane was gone.
pub fn run_multi(case: &MultiCase, sender: &PeerSpec, receiver: &PeerSpec) -> Value {
    let total: u64 = case.files.iter().sum();
    let mut result = json!({
        "case": case.name, "sender": sender.label, "receiver": receiver.label,
        "route": case.routes.iter().map(|r| r.name).collect::<Vec<_>>().join("+"),
        "files": case.files.len(), "bytes": total,
    });
    let outcome =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| measure_multi(case, sender, receiver, &mut result)));
    match outcome {
        Ok(Ok(())) => {}
        Ok(Err(why)) if why.starts_with("skip: ") => result["skipped"] = json!(why.trim_start_matches("skip: ")),
        Ok(Err(why)) => result["error"] = json!(why),
        Err(_) => result["error"] = json!("panicked"),
    }
    result
}

fn measure_multi(
    case: &MultiCase,
    sender_spec: &PeerSpec,
    receiver_spec: &PeerSpec,
    result: &mut Value,
) -> Result<(), String> {
    let total: u64 = case.files.iter().sum();
    let homes = (TempHome::new("multi-s"), TempHome::new("multi-r"), TempHome::new("multi-content"));
    let mut sender = sender_spec.start(&homes.0.path().join("state"), "Sender");
    let mut receiver = receiver_spec.start(&homes.1.path().join("state"), "Receiver");
    let lanes = |peer: &mut ObjcPeer| peer.command(json!({ "cmd": "hello" }))["lanes"] == true;
    if !lanes(&mut sender) || !lanes(&mut receiver) {
        return Err("skip: these peers open no lanes yet (ADR 0018 WP3)".into());
    }
    let (pid_s, pid_r) = (sender.pid(), receiver.pid());
    befriend(&mut sender, &mut receiver, ("Sender", "Receiver"));
    let remote = keys(&mut receiver);
    let (mut log_s, mut log_r) = (Log::new(), Log::new());
    let port = listen(&mut receiver);
    let proxies: Vec<Proxy> = case
        .routes
        .iter()
        .map(|route| {
            let proxy = Proxy::start(port);
            proxy.set(route.tamper());
            proxy
        })
        .collect();
    let step = Duration::from_secs(30);
    let dial = |proxy: &Proxy, route: &RouteProfile| {
        json!({ "cmd": "dial", "port": proxy.port(), "pattern": "IK", "remote_static": remote.static_key,
                "expected_identity": remote.identity, "route": route.class })
    };
    let first =
        sender.command(dial(&proxies[0], &case.routes[0]))["session"].as_u64().ok_or("the first dial failed")?;
    let (_, live) = log_s.wait(&mut sender, 0, step, is("established")).ok_or("the session never came up")?;
    log_r.wait(&mut receiver, 0, step, is("established")).ok_or("the receiver's session never came up")?;
    result["minor"] = live["minor"].clone();
    result["fast"] = live["fast"].clone();
    for (index, (proxy, route)) in proxies.iter().zip(&case.routes).enumerate().skip(1) {
        let mut lane = dial(proxy, route);
        lane["lane_of"] = json!(first);
        let reply = sender.command(lane);
        if reply["session"].is_null() {
            return Err(format!("lane {index} ({}) refused: {reply}", route.name));
        }
        let from = log_s.events.len();
        log_s.wait(&mut sender, from, step, is("established")).ok_or_else(|| format!("lane {index} never came up"))?;
    }
    let mut digests = Vec::new();
    let mut paths = Vec::new();
    for (index, size) in case.files.iter().enumerate() {
        let path = homes.2.path().join(format!("file-{index}.bin"));
        digests.push(write_content(&path, &format!("multi {} {index}", case.name), *size));
        paths.push(path);
    }
    let (cpu_s0, cpu_r0) = (cpu_seconds(pid_s), cpu_seconds(pid_r));
    let started = Instant::now();
    let mut ids = Vec::new();
    for path in &paths {
        let offer = sender.command(json!({ "cmd": "send_file", "session": first, "path": path.to_string_lossy() }));
        ids.push(offer["transfer"].as_str().ok_or_else(|| format!("send_file failed: {offer}"))?.to_owned());
    }
    let (together, best) = case.rates();
    let long = Duration::from_secs_f64(total as f64 / best.max(1.0) * 4.0 + 120.0);
    if let Some((which, loss)) = case.lost {
        let carried = || proxies.iter().map(|p| p.counts().0).sum::<u64>();
        let at = match loss {
            Loss::Cut(f) | Loss::Silence(f) => (total as f64 * f) as u64,
            Loss::None => u64::MAX,
        };
        while carried() < at && started.elapsed() < long {
            log_s.drain(&mut sender);
            log_r.drain(&mut receiver);
            std::thread::sleep(Duration::from_millis(2));
        }
        let lost_at = Instant::now();
        if matches!(loss, Loss::Cut(_)) {
            proxies[which].cut_now();
        } else {
            proxies[which].silence_now();
        }
        result["lost_route"] = json!(case.routes[which].name);
        result["lost_after_s"] = json!(lost_at.duration_since(started).as_secs_f64());
        let (from_s, from_r) = (log_s.events.len(), log_r.events.len());
        let short = Duration::from_millis(20);
        let mut noticed = None;
        while noticed.is_none() && lost_at.elapsed() < Duration::from_secs(20) {
            noticed = log_s
                .wait(&mut sender, from_s, short, is("closed"))
                .or_else(|| log_r.wait(&mut receiver, from_r, short, is("closed")))
                .map(|(at, _)| at.duration_since(lost_at).as_secs_f64());
            if log_r.events[from_r..].iter().any(|(_, e)| e["event"] == "received_file") {
                break;
            }
        }
        result["noticed_s"] = json!(noticed);
    }
    for id in &ids {
        log_r
            .wait(&mut receiver, 0, long, |e| e["event"] == "received_file" && e["transfer"] == id.as_str())
            .ok_or_else(|| format!("{id} not received within {long:?}"))?;
    }
    let seconds = started.elapsed().as_secs_f64();
    let (cpu_s, cpu_r) = (cpu_seconds(pid_s) - cpu_s0, cpu_seconds(pid_r) - cpu_r0);
    let received: Vec<PathBuf> = ids
        .iter()
        .filter_map(|id| {
            log_r.events.iter().find(|(_, e)| e["event"] == "received_file" && e["transfer"] == id.as_str())
        })
        .map(|(_, e)| PathBuf::from(e["path"].as_str().unwrap_or_default()))
        .collect();
    let intact = received.len() == digests.len()
        && received.iter().zip(&digests).all(|(path, digest)| digest_of(path).as_ref() == Some(digest));
    result["seconds"] = json!(seconds);
    result["mbyte_per_s"] = json!(total as f64 / seconds / 1e6);
    result["link_share"] = json!(total as f64 / seconds / together);
    result["best_route_share"] = json!(total as f64 / seconds / best);
    result["route_bytes"] = json!(proxies.iter().map(|p| p.counts().0).collect::<Vec<_>>());
    result["cpu_sender_s_per_gb"] = json!(cpu_s / (total as f64 / 1e9));
    result["cpu_receiver_s_per_gb"] = json!(cpu_r / (total as f64 / 1e9));
    result["intact"] = json!(intact);
    if !intact {
        return Err("the received bytes differ from the sent ones".into());
    }
    Ok(())
}
