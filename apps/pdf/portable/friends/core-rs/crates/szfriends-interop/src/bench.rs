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
    keep_logs(&mut result);
    result
}

thread_local! {
    /// The transcripts of the case running on this thread, by role, until it ends.
    static TRANSCRIPTS: std::cell::RefCell<Vec<(&'static str, crate::objc::Transcript)>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

pub(super) fn watch(role: &'static str, peer: &ObjcPeer) {
    TRANSCRIPTS.with(|t| t.borrow_mut().push((role, peer.transcript())));
}

/// A case that failed keeps both peers' transcripts (every command, event and line of standard error) in
/// `$BENCH_LOGS` (default `bench-logs/`), named in its result's "logs"; one that passed keeps nothing.
pub(super) fn keep_logs(result: &mut Value) {
    let transcripts = TRANSCRIPTS.with(|t| std::mem::take(&mut *t.borrow_mut()));
    if result.get("error").is_none() {
        return;
    }
    let dir = PathBuf::from(std::env::var("BENCH_LOGS").unwrap_or_else(|_| "bench-logs".into()));
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis());
    let label = |key: &str| result[key].as_str().unwrap_or("").replace(['/', ' '], "_");
    let mut paths = Vec::new();
    for (role, transcript) in transcripts {
        let name = format!("{}-{}-{}-{stamp}-{role}.log", label("case"), label("sender"), label("receiver"));
        let path = dir.join(name);
        let lines = transcript.lock().map(|l| l.join("\n")).unwrap_or_default();
        if std::fs::write(&path, lines + "\n").is_ok() {
            paths.push(path.to_string_lossy().into_owned());
        }
    }
    result["logs"] = json!(paths);
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
/// A case's file: the usual pseudo-random bytes, or with `BENCH_CORPUS` set (a directory), its files one after another
/// over and over, cut at `size`: real documents for what compression gives (ADR 0018 § 9.4). Pseudo-random bytes do
/// not compress at all, so without a corpus compressed parts change nothing and cost one sample per block.
fn bench_content(path: &Path, label: &str, size: u64) -> [u8; 32] {
    let Some(corpus) = std::env::var_os("BENCH_CORPUS") else { return write_content(path, label, size) };
    use blake2::digest::{Update, VariableOutput};
    use std::io::Write;
    let mut sources: Vec<PathBuf> = std::fs::read_dir(&corpus)
        .expect("BENCH_CORPUS is a directory")
        .filter_map(|entry| Some(entry.ok()?.path()))
        .filter(|path| path.is_file())
        .collect();
    sources.sort();
    assert!(!sources.is_empty(), "BENCH_CORPUS holds no files");
    let mut file = std::io::BufWriter::new(std::fs::File::create(path).expect("content file"));
    let mut digest = blake2::Blake2bVar::new(32).expect("32 bytes");
    let mut written = 0u64;
    for source in sources.iter().cycle() {
        if written >= size {
            break;
        }
        let bytes = std::fs::read(source).expect("a corpus file");
        let take = bytes.len().min((size - written) as usize);
        file.write_all(&bytes[..take]).expect("written");
        digest.update(&bytes[..take]);
        written += take as u64;
    }
    file.flush().expect("flushed");
    let mut out = [0u8; 32];
    digest.finalize_variable(&mut out).expect("32 bytes");
    out
}

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

#[path = "bench_measure.rs"]
mod measure;
use measure::*;

#[path = "bench_multi.rs"]
mod multi;
pub use multi::{run_multi, MultiCase};

#[path = "bench_relay.rs"]
mod relay;
pub use relay::{run_relay, RelayCase, RelayStory, FIRST_PART_MAX, RELAY_BESIDE_DIRECT_MAX};
