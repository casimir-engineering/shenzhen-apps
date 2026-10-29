//! The transfer bench between this computer and another device over a real route (ADR 0018 § Verification, hardware
//! runs). `tools/transfer-devices.sh` sets it up; by hand:
//!   BENCH_REMOTE       the remote peer's command, run with `<home> <name>` appended and speaking on its standard input
//!                      and output: `ssh -T mac2.local szf-bench/SZFSessionPeer`, `adb shell /data/local/tmp/szf/session_peer`
//!   BENCH_REMOTE_HOME  a directory on the remote device the peer may write (a fresh one below it per run)
//!   BENCH_REMOTE_HOST  the address this computer dials it at (its Wi-Fi or Ethernet address; fe80::…%awdl0 for AWDL)
//!   BENCH_LOCAL        rust or objc (default objc where SZFRIENDS_OBJC_PEER is set): today's peer on this computer
//!   BENCH_ROUTE_NAME   a name for the table (wifi, ethernet, awdl); BENCH_ROUTE_CLASS the class declared (lan, p2p_wifi)
//!   BENCH_SIZES        1m,100m,2g,small (default 1m,100m,small)
//!   BENCH_LINK_BYTES_PER_SECOND  what one TCP connection gets between the two (iperf3), for the share of the link
//!   BENCH_REMOTE_LOOPBACK=1  the "remote" listens on loopback only: a dry run with both peers on this computer
//! Each payload goes there, then the received copy comes back and is checked against the original here, so nothing
//! has to be prepared on the device. CPU is this computer's side only. The remote listens on every interface for the
//! length of the run.

use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::json;
use szfriends_interop::bench::{self, PeerSpec, MIB};
use szfriends_interop::{befriend, keys, wait_for, write_content, ObjcPeer, Peer, TempHome};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

fn cpu_seconds(pid: u32) -> f64 {
    let Ok(out) = Command::new("ps").args(["-o", "cputime=", "-p", &pid.to_string()]).output() else { return 0.0 };
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .split([':', '-'])
        .fold(0.0, |total, part| total * 60.0 + part.trim().parse::<f64>().unwrap_or(0.0))
}

/// Sends `paths` from `from` on `session` and waits for `to` to publish them all; returns the seconds and the paths
/// the receiver reports.
fn send(from: &mut ObjcPeer, session: u64, to: &mut ObjcPeer, paths: &[String], total: u64) -> (f64, Vec<String>) {
    let started = Instant::now();
    let ids: Vec<String> = paths
        .iter()
        .map(|path| {
            let offer = from.command(json!({ "cmd": "send_file", "session": session, "path": path }));
            offer["transfer"].as_str().unwrap_or_else(|| panic!("send_file failed: {offer}")).to_owned()
        })
        .collect();
    let long = Duration::from_secs(600 + total / 100_000);
    let mut seen = Vec::new();
    let received = ids
        .iter()
        .map(|id| {
            let event = wait_for(to, &mut seen, long, "received_file", |e| {
                e["event"] == "received_file" && e["transfer"] == id.as_str()
            });
            event["path"].as_str().unwrap_or_default().to_owned()
        })
        .collect();
    let seconds = started.elapsed().as_secs_f64();
    let mut seen = Vec::new();
    for id in &ids {
        wait_for(from, &mut seen, Duration::from_secs(60), "delivered", |e| {
            e["event"] == "delivered" && e["transfer"] == id.as_str()
        });
    }
    (seconds, received)
}

fn main() {
    let remote_program: Vec<String> =
        env("BENCH_REMOTE").expect("BENCH_REMOTE").split_whitespace().map(str::to_owned).collect();
    let remote_home = env("BENCH_REMOTE_HOME").expect("BENCH_REMOTE_HOME");
    let host = env("BENCH_REMOTE_HOST").expect("BENCH_REMOTE_HOST");
    let route_name = env("BENCH_ROUTE_NAME").unwrap_or_else(|| "wifi".into());
    let route_class = env("BENCH_ROUTE_CLASS").unwrap_or_else(|| "lan".into());
    let link: Option<f64> = env("BENCH_LINK_BYTES_PER_SECOND").and_then(|v| v.parse().ok());
    let out = PathBuf::from(env("BENCH_OUT").unwrap_or_else(|| "transfer-devices.jsonl".into()));
    let local = match (env("BENCH_LOCAL").as_deref(), ObjcPeer::binary()) {
        (Some("rust"), _) | (None, None) => {
            PeerSpec::local("rust", &bench::rust_peer_binary().expect("examples/session_peer is built"), false)
        }
        (_, Some(binary)) => PeerSpec::local("objc", &binary, false),
        (_, None) => panic!("BENCH_LOCAL=objc needs SZFRIENDS_OBJC_PEER"),
    };
    let remote = PeerSpec {
        label: format!("remote {}", remote_program.last().map_or("peer", |p| p.rsplit('/').next().unwrap_or(p))),
        program: remote_program,
        declares_route: true,
        released: false,
    };
    let home = TempHome::new("devices");
    let mut nonce = [0u8; 4];
    szfriends_core::crypto::random_bytes(&mut nonce);
    let mut here = local.start(&home.path().join("state"), "Here");
    let mut there = remote.start(&PathBuf::from(format!("{remote_home}/run-{}", hex::encode(nonce))), "There");
    befriend(&mut here, &mut there, ("Here", "There"));
    let keys_there = keys(&mut there);
    // On every interface, except for a dry run with everything on this computer (BENCH_REMOTE_LOOPBACK=1).
    let any = env("BENCH_REMOTE_LOOPBACK").as_deref() != Some("1");
    let port = there.command(json!({ "cmd": "listen", "any": any }))["port"].as_u64().expect("the remote listens");
    here.command(json!({
        "cmd": "dial", "host": host, "port": port, "pattern": "IK", "remote_static": keys_there.static_key,
        "expected_identity": keys_there.identity, "route": route_class,
    }));
    let (mut seen_here, mut seen_there) = (Vec::new(), Vec::new());
    let step = Duration::from_secs(30);
    let live_here = wait_for(&mut here, &mut seen_here, step, "a session here", |e| e["event"] == "established");
    let live_there = wait_for(&mut there, &mut seen_there, step, "a session there", |e| e["event"] == "established");
    let (session_here, session_there) =
        (live_here["session"].as_u64().unwrap(), live_there["session"].as_u64().unwrap());
    let sizes = env("BENCH_SIZES").unwrap_or_else(|| "1m,100m,small".into());
    let mut results = Vec::new();
    for size in sizes.split(',').map(str::trim) {
        let files: Vec<u64> = match size {
            "1m" => vec![MIB],
            "100m" => vec![100 * MIB],
            "2g" => vec![2048 * MIB],
            "small" => vec![10 * 1024; 300],
            _ => continue,
        };
        let total: u64 = files.iter().sum();
        let mut paths = Vec::new();
        let mut digests = Vec::new();
        for (index, bytes) in files.iter().enumerate() {
            let path = home.path().join(format!("{size}-{index}.bin"));
            digests.push(write_content(&path, &format!("devices {size} {index}"), *bytes));
            paths.push(path.to_string_lossy().into_owned());
        }
        for outward in [true, false] {
            let pid = here.pid();
            let cpu0 = cpu_seconds(pid);
            let (seconds, received) = if outward {
                send(&mut here, session_here, &mut there, &paths, total)
            } else {
                send(&mut there, session_there, &mut here, &paths, total)
            };
            let cpu = cpu_seconds(pid) - cpu0;
            let mut result = json!({
                "case": format!("{route_name}-{size}"), "route": route_name, "payload": bench::payload(&files),
                "sender": if outward { local.label.clone() } else { remote.label.clone() },
                "receiver": if outward { remote.label.clone() } else { local.label.clone() },
                "files": files.len(), "bytes": total, "seconds": seconds, "mbyte_per_s": total as f64 / seconds / 1e6,
                "minor": live_here["minor"],
            });
            result[if outward { "cpu_sender_s_per_gb" } else { "cpu_receiver_s_per_gb" }] =
                json!(cpu / (total as f64 / 1e9));
            if let Some(rate) = link {
                result["link_share"] = json!(total as f64 / seconds / rate);
            }
            if outward {
                // The device's copies go back next.
                paths = received;
            } else {
                let intact = received
                    .iter()
                    .zip(&digests)
                    .all(|(path, digest)| bench::digest_of(std::path::Path::new(path)).as_ref() == Some(digest));
                result["intact"] = json!(intact);
                if !intact {
                    result["error"] = json!("the copy that came back differs from the original");
                }
            }
            eprintln!("devices: {result}");
            bench::append(&out, &result);
            results.push(result);
        }
    }
    print!("{}", bench::table(&results));
    println!("results appended to {}", out.display());
}
