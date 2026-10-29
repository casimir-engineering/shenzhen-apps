//! The transfer bench (ADR 0018 § Verification): today's peers, Rust (`examples/session_peer.rs`) and the
//! Objective-C helper's own session, store and transfer code (`$SZFRIENDS_OBJC_PEER`), each in a process of its own,
//! send 1 MiB, 100 MiB, 2 GiB and 300 files of 10 KiB through each emulated route, then lose a route mid-transfer.
//! Appends one JSON line per case to `$BENCH_OUT` and prints a table: MB/s, share of the link, CPU seconds per GB on
//! each side, and for a cut or silence when it was noticed and how long until the transfer moved again.
//!
//! `make friends-transfer-bench` builds and runs it; on demand only, no suite runs it. Choose with:
//!   BENCH_PAIRS        rust-rust,rust-objc,objc-rust,objc-objc (default: all; objc ones need SZFRIENDS_OBJC_PEER)
//!   BENCH_ROUTES       loopback,lan,p2p_wifi,internet,internet_lossy,relay,bluetooth (default: all)
//!   BENCH_SIZES        1m,4m,16m,100m,2g,small (default: 1m,100m,2g,small)
//!   BENCH_LOSS         lan-cut,lan-silence,bluetooth-cut,bluetooth-silence (default: all; "none" for none)
//!   BENCH_MULTI        several routes at once between the same two peers, the first carrying the session and the
//!                      others lanes of it (ADR 0018 § 6): lan+p2p, lan+p2p-cut-p2p, lan+p2p-silence-lan,
//!                      slowlan+bt, slowlan+bt-cut-bt, slowlan+bt-silence-bt, lan+p2p+bt, lan+p2p+bt-cut-lan,
//!                      loopback+loopback (default: all; "none" for none); and, for "never slower with Bluetooth",
//!                      slowlan (alone), slowlan+bt-silence-bt-0 (connected and silent), -10, -90, slowlan+bt-flap,
//!                      slowlan+bt1, slowlan+bt5, slowlan+bt20 (Bluetooth at that % of the LAN),
//!                      slowlan+bt5-silence-bt-90, slowlan+bt-flap-mostly-off, not in the default list. Skipped, and said so, until the peers open
//!                      lanes. SZFRIENDS_TEST_AES_LANES=0 and SZFRIENDS_TEST_COMPRESSED_PARTS=0 run the Rust peers
//!                      without AES-GCM lanes or compressed parts (ADR 0018 § 9.2, § 9.4), for before and after;
//!                      SZFRIENDS_TEST_ZSTD=0 plays a phone that compresses with LZ4 only.
//!   BENCH_CORPUS       a directory whose files, one after another, make up each case's files instead of
//!                      pseudo-random bytes (which do not compress): for compressed parts (ADR 0018 § 9.4)
//!   BENCH_MAX_SECONDS  skip a case the route would need longer than this for at its rate (default 120)
//!   BENCH_LOGS         where a failed case keeps both peers' transcripts (default bench-logs/)
//!   BENCH_SILENCE_WAIT seconds a silent route may go unnoticed before the route comes back anyway (default 20)
//! `transfer_bench --table <file.jsonl>` prints the table of earlier results.

use std::path::PathBuf;
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_interop::bench::{
    self, Case, Loss, MultiCase, PeerSpec, RouteProfile, BLUETOOTH, LAN, LAN_SLOW, LOOPBACK, MIB, P2P_WIFI, ROUTES,
};

fn list(name: &str, default: &str) -> Vec<String> {
    let value = std::env::var(name).unwrap_or_default();
    let value = if value.trim().is_empty() { default.to_owned() } else { value };
    value.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty() && s != "none").collect()
}

fn number(name: &str, default: f64) -> f64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn files(size: &str) -> Option<Vec<u64>> {
    Some(match size {
        "1m" => vec![MIB],
        "4m" => vec![4 * MIB],
        "16m" => vec![16 * MIB],
        "100m" => vec![100 * MIB],
        "2g" => vec![2048 * MIB],
        "small" => vec![10 * 1024; 300],
        _ => return None,
    })
}

fn loss_case(name: &str, silence_wait: Duration) -> Option<Case> {
    let (route, files, loss): (RouteProfile, _, _) = match name {
        "lan-cut" => (LAN, vec![100 * MIB], Loss::Cut(0.5)),
        "lan-silence" => (LAN, vec![100 * MIB], Loss::Silence(0.5)),
        "bluetooth-cut" => (BLUETOOTH, vec![4 * MIB], Loss::Cut(0.5)),
        "bluetooth-silence" => (BLUETOOTH, vec![4 * MIB], Loss::Silence(0.5)),
        _ => return None,
    };
    Some(Case { name: name.to_owned(), route, files, loss, silence_wait })
}

/// Bluetooth at `share` of the slow LAN's rate.
fn bluetooth_at(share: f64) -> RouteProfile {
    RouteProfile { bytes_per_second: LAN_SLOW.bytes_per_second.map(|r| (r as f64 * share) as u64), ..BLUETOOTH }
}

fn multi_case(name: &str) -> Option<MultiCase> {
    // Never slower with Bluetooth than without (the owner's rule): the slow LAN alone, then Bluetooth beside it out of
    // range at 10, 50 and 90 % of the bytes, connected and silent from the start, flapping, and at 1, 5 and 20 % of the
    // LAN's rate. Compare each with "slowlan".
    let flap = |up: f64, down: f64| Some((1, Duration::from_secs_f64(up), Duration::from_secs_f64(down)));
    let (routes, files, lost, flap) = match name {
        "slowlan" => (vec![LAN_SLOW], vec![16 * MIB], None, None),
        "slowlan+bt-silence-bt-0" => (vec![LAN_SLOW, BLUETOOTH], vec![16 * MIB], Some((1, Loss::Silence(0.0))), None),
        "slowlan+bt-silence-bt-10" => (vec![LAN_SLOW, BLUETOOTH], vec![16 * MIB], Some((1, Loss::Silence(0.1))), None),
        "slowlan+bt-silence-bt-90" => (vec![LAN_SLOW, BLUETOOTH], vec![16 * MIB], Some((1, Loss::Silence(0.9))), None),
        "slowlan+bt-flap" => (vec![LAN_SLOW, BLUETOOTH], vec![16 * MIB], None, flap(0.6, 1.8)),
        "slowlan+bt1" => (vec![LAN_SLOW, bluetooth_at(0.01)], vec![16 * MIB], None, None),
        "slowlan+bt5" => (vec![LAN_SLOW, bluetooth_at(0.05)], vec![16 * MIB], None, None),
        "slowlan+bt20" => (vec![LAN_SLOW, bluetooth_at(0.2)], vec![16 * MIB], None, None),
        // Where the scheduler before "never slower" lost most in the simulator: the extra lane's last slice all
        // written into socket buffers when it goes out of range, and a lane mostly out of range.
        "slowlan+bt5-silence-bt-90" => {
            (vec![LAN_SLOW, bluetooth_at(0.05)], vec![16 * MIB], Some((1, Loss::Silence(0.9))), None)
        }
        "slowlan+bt-flap-mostly-off" => (vec![LAN_SLOW, BLUETOOTH], vec![16 * MIB], None, flap(0.5, 1.9)),
        _ => {
            let (routes, files, lost) = older_multi_case(name)?;
            (routes, files, lost, None)
        }
    };
    Some(MultiCase { name: name.to_owned(), routes, files, lost, flap })
}

type MultiRoutes = (Vec<RouteProfile>, Vec<u64>, Option<(usize, Loss)>);

fn older_multi_case(name: &str) -> Option<MultiRoutes> {
    let (routes, files, lost) = match name {
        "lan+p2p" => (vec![LAN, P2P_WIFI], vec![1024 * MIB], None),
        // Two connections over loopback, the second a lane: what lanes and their cipher (AES-256-GCM where both sides
        // have hardware AES, ADR 0018 § 9.2) give when the computer, not the route, is the limit.
        "loopback+loopback" => (vec![LOOPBACK, LOOPBACK], vec![2048 * MIB], None),
        "lan+p2p-cut-p2p" => (vec![LAN, P2P_WIFI], vec![1024 * MIB], Some((1, Loss::Cut(0.5)))),
        "lan+p2p-silence-lan" => (vec![LAN, P2P_WIFI], vec![1024 * MIB], Some((0, Loss::Silence(0.5)))),
        "slowlan+bt" => (vec![LAN_SLOW, BLUETOOTH], vec![16 * MIB], None),
        "slowlan+bt-cut-bt" => (vec![LAN_SLOW, BLUETOOTH], vec![16 * MIB], Some((1, Loss::Cut(0.5)))),
        "slowlan+bt-silence-bt" => (vec![LAN_SLOW, BLUETOOTH], vec![16 * MIB], Some((1, Loss::Silence(0.5)))),
        "lan+p2p+bt" => (vec![LAN, P2P_WIFI, BLUETOOTH], vec![1024 * MIB], None),
        "lan+p2p+bt-cut-lan" => (vec![LAN, P2P_WIFI, BLUETOOTH], vec![1024 * MIB], Some((0, Loss::Cut(0.5)))),
        _ => return None,
    };
    Some((routes, files, lost))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--table") {
        let text = std::fs::read_to_string(args.get(2).expect("a results file")).expect("readable");
        let results: Vec<Value> = text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
        print!("{}", bench::table(&results));
        return;
    }
    let out = PathBuf::from(std::env::var("BENCH_OUT").unwrap_or_else(|_| "transfer-bench.jsonl".into()));
    let rust = PeerSpec::local("rust", &bench::rust_peer_binary().expect("examples/session_peer is built"), false);
    let objc = szfriends_interop::ObjcPeer::binary().map(|b| PeerSpec::local("objc", &b, false));
    let max_seconds = number("BENCH_MAX_SECONDS", 120.0);
    let silence_wait = Duration::from_secs_f64(number("BENCH_SILENCE_WAIT", 20.0));
    let mut pairs = Vec::new();
    for pair in list("BENCH_PAIRS", "rust-rust,rust-objc,objc-rust,objc-objc") {
        let pick = |name: &str| match name {
            "rust" => Some(rust.clone()),
            "objc" => objc.clone(),
            _ => None,
        };
        match pair.split_once('-').map(|(s, r)| (pick(s), pick(r))) {
            Some((Some(s), Some(r))) => pairs.push((s, r)),
            _ => eprintln!("bench: skipping {pair} (unknown, or SZFRIENDS_OBJC_PEER not set)"),
        }
    }
    let mut cases = Vec::new();
    for route in list("BENCH_ROUTES", &ROUTES.map(|r| r.name).join(",")) {
        let Some(profile) = RouteProfile::named(&route) else {
            eprintln!("bench: no route {route}");
            continue;
        };
        for size in list("BENCH_SIZES", "1m,100m,2g,small") {
            let Some(files) = files(&size) else { continue };
            cases.push(Case { name: format!("{route}-{size}"), route: profile, files, loss: Loss::None, silence_wait });
        }
    }
    cases.extend(
        list("BENCH_LOSS", "lan-cut,lan-silence,bluetooth-cut,bluetooth-silence")
            .iter()
            .filter_map(|name| loss_case(name, silence_wait)),
    );
    let mut results = Vec::new();
    for case in &cases {
        for (sender, receiver) in &pairs {
            let total: u64 = case.files.iter().sum();
            let payload = bench::payload(&case.files);
            let expected = case.route.expected_bytes_per_second().map_or(0.0, |rate| total as f64 / rate);
            let mut result = if expected > max_seconds {
                json!({ "case": case.name, "sender": sender.label, "receiver": receiver.label,
                        "route": case.route.name, "files": case.files.len(), "bytes": total,
                        "skipped": format!("about {:.0} s at this rate (BENCH_MAX_SECONDS={max_seconds})", expected) })
            } else {
                eprintln!("bench: {} {} → {}", case.name, sender.label, receiver.label);
                bench::run_caught(case, sender, receiver)
            };
            result["payload"] = json!(payload);
            if case.loss != Loss::None {
                result["silence_wait_s"] = json!(silence_wait.as_secs_f64());
            }
            eprintln!("bench: {result}");
            bench::append(&out, &result);
            results.push(result);
        }
    }
    let multi = list(
        "BENCH_MULTI",
        "lan+p2p,lan+p2p-cut-p2p,lan+p2p-silence-lan,slowlan+bt,slowlan+bt-cut-bt,slowlan+bt-silence-bt,lan+p2p+bt,\
         lan+p2p+bt-cut-lan,loopback+loopback",
    );
    for case in multi.iter().filter_map(|name| multi_case(name)) {
        for (sender, receiver) in &pairs {
            eprintln!("bench: {} {} → {}", case.name, sender.label, receiver.label);
            let mut result = bench::run_multi(&case, sender, receiver);
            result["payload"] = json!(bench::payload(&case.files));
            eprintln!("bench: {result}");
            bench::append(&out, &result);
            results.push(result);
        }
    }
    print!("{}", bench::table(&results));
    println!("results appended to {}", out.display());
    if results.iter().any(|r| !r["error"].is_null()) {
        std::process::exit(1);
    }
}
