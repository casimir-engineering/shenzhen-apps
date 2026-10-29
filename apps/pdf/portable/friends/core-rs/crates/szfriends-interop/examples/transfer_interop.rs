//! The interop matrix (ADR 0018 § Verification): released peers against today's, and today's against each other, on
//! every emulated route, a transfer and then a transfer that resumes after a cut halfway. Peers, each a process:
//!   rust, objc                   today's (`examples/session_peer.rs`, `$SZFRIENDS_OBJC_PEER`)
//!   $SZFRIENDS_RELEASED_RUST_PEER  the Rust core at a release tag (default label rust-0.2.4)
//!   $SZFRIENDS_RELEASED_OBJC_PEER  the Mac helper's code at a release tag (default label objc-26.10.29-1)
//! `tools/released-peers.sh` builds the released ones in worktrees of their tags; `make friends-transfer-interop` does
//! all of it. Every ordered pair with at least one of today's peers runs; released with released is how they shipped.
//!
//! A run passes when the file arrives intact, both sides agree on the minor, a pair with a released peer negotiates at
//! most the minor that release knows (3) and a pair of today's peers this core's `SESSION_MINOR`, and after the cut
//! the sender resumes past the start. INTEROP_EXPECT_FAST=1 also requires today's pairs to report fast transfers.
//! INTEROP_SILENCE=1 adds the route going silent halfway (out of range, sockets open), which passes only when a side
//! notices within ADR 0018's 8 s (12 s on Bluetooth): today's code does not, so it fails until WP3 and WP4 land.
//! Choose with INTEROP_ROUTES (lan,p2p_wifi,internet,relay,bluetooth) and INTEROP_PAIRS (e.g. rust-objc-26.10.29-1).
//! One JSON line per run goes to $INTEROP_OUT; the table goes to standard output; any failure exits 1.

use std::path::PathBuf;
use std::time::Duration;

use serde_json::{json, Value};
use szfriends_interop::bench::{self, Case, Loss, PeerSpec, RouteProfile, MIB};

/// The newest session minor the released apps of 26.10.29-1 and 0.2.4 speak.
const RELEASED_MINOR: u64 = 3;

fn payload(route: &str) -> u64 {
    match route {
        "lan" | "loopback" => 64 * MIB,
        "p2p_wifi" => 32 * MIB,
        "internet" => 8 * MIB,
        "relay" => MIB,
        _ => MIB / 2,
    }
}

fn check(result: &Value, sender: &PeerSpec, receiver: &PeerSpec, loss: Loss) -> Result<String, String> {
    if let Some(error) = result["error"].as_str() {
        return Err(error.to_owned());
    }
    let minor = result["minor"].as_u64().ok_or("no minor reported")?;
    let released = sender.released || receiver.released;
    let today = u64::from(szfriends_core::wire::consts::SESSION_MINOR);
    if released && minor > RELEASED_MINOR {
        return Err(format!("minor {minor} with a released peer"));
    }
    if !released && minor != today {
        return Err(format!("minor {minor}, not {today}"));
    }
    if !released && std::env::var("INTEROP_EXPECT_FAST").as_deref() == Ok("1") && result["fast"] != true {
        return Err("no fast transfers between today's peers".into());
    }
    if loss != Loss::None && result["resume_offset"].as_u64().unwrap_or(0) == 0 {
        return Err("started again from zero after the route came back".into());
    }
    if let Loss::Silence(_) = loss {
        let limit = if result["route"] == "bluetooth" { 12.0 } else { 8.0 };
        match result["noticed_s"].as_f64() {
            Some(seconds) if seconds <= limit => {}
            Some(seconds) => return Err(format!("silence noticed after {seconds:.1} s, not within {limit} s")),
            None => return Err(format!("silence not noticed in {} s", result["silence_wait_s"])),
        }
    }
    let fast = if result["fast"] == true { ", fast" } else { "" };
    Ok(if loss != Loss::None {
        format!(
            "ok, resumed at {:.0} %",
            result["resume_offset"].as_f64().unwrap_or(0.0) * 100.0 / result["bytes"].as_f64().unwrap_or(1.0)
        )
    } else {
        format!("ok, minor {minor}{fast}, {:.1} MB/s", result["mbyte_per_s"].as_f64().unwrap_or(0.0))
    })
}

fn main() {
    let out = PathBuf::from(std::env::var("INTEROP_OUT").unwrap_or_else(|_| "transfer-interop.jsonl".into()));
    let mut peers =
        vec![PeerSpec::local("rust", &bench::rust_peer_binary().expect("examples/session_peer is built"), false)];
    if let Some(binary) = szfriends_interop::ObjcPeer::binary() {
        peers.push(PeerSpec::local("objc", &binary, false));
    }
    for (variable, label, default) in [
        ("SZFRIENDS_RELEASED_RUST_PEER", "SZFRIENDS_RELEASED_RUST_LABEL", "rust-0.2.4"),
        ("SZFRIENDS_RELEASED_OBJC_PEER", "SZFRIENDS_RELEASED_OBJC_LABEL", "objc-26.10.29-1"),
    ] {
        match std::env::var_os(variable).map(PathBuf::from).filter(|p| p.exists()) {
            Some(binary) => {
                let label = std::env::var(label).unwrap_or_else(|_| default.to_owned());
                peers.push(PeerSpec::local(&label, &binary, true));
            }
            None => eprintln!("interop: {variable} not set, so no {default}"),
        }
    }
    let wanted_pairs: Vec<String> = std::env::var("INTEROP_PAIRS")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect();
    let routes: Vec<RouteProfile> = std::env::var("INTEROP_ROUTES")
        .unwrap_or_else(|_| "lan,p2p_wifi,internet,relay,bluetooth".into())
        .split(',')
        .filter_map(|name| RouteProfile::named(name.trim()))
        .collect();
    let mut losses = vec![("", Loss::None), ("-cut", Loss::Cut(0.5))];
    if std::env::var("INTEROP_SILENCE").as_deref() == Ok("1") {
        losses.push(("-silence", Loss::Silence(0.5)));
    }
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut failed = 0;
    for sender in &peers {
        for receiver in &peers {
            if sender.released && receiver.released {
                continue;
            }
            let pair = format!("{}-{}", sender.label, receiver.label);
            if !wanted_pairs.is_empty() && !wanted_pairs.contains(&pair) {
                continue;
            }
            for route in &routes {
                let mut cells = vec![format!("{} → {}", sender.label, receiver.label), route.name.to_owned()];
                for (suffix, loss) in &losses {
                    let case = Case {
                        name: format!("{}{suffix}", route.name),
                        route: *route,
                        files: vec![payload(route.name)],
                        loss: *loss,
                        silence_wait: Duration::from_secs(20),
                    };
                    eprintln!("interop: {} {} → {}", case.name, sender.label, receiver.label);
                    let mut result = bench::run_caught(&case, sender, receiver);
                    result["silence_wait_s"] = json!(20);
                    let verdict = check(&result, sender, receiver, *loss);
                    result["pass"] = json!(verdict.is_ok());
                    eprintln!("interop: {result}");
                    bench::append(&out, &result);
                    cells.push(verdict.unwrap_or_else(|why| {
                        failed += 1;
                        format!("FAILED: {why}")
                    }));
                }
                rows.push(cells);
            }
        }
    }
    let mut header = vec!["sender → receiver", "route", "transfer", "cut at 50 %, route back"];
    if losses.len() > 2 {
        header.push("silent at 50 %");
    }
    rows.insert(0, header.into_iter().map(str::to_owned).collect());
    let widths: Vec<usize> =
        (0..rows[0].len()).map(|i| rows.iter().map(|r| r[i].chars().count()).max().unwrap_or(0)).collect();
    for (index, row) in rows.iter().enumerate() {
        let cells: Vec<String> = row.iter().zip(&widths).map(|(c, w)| format!("{c:<w$}")).collect();
        println!("| {} |", cells.join(" | "));
        if index == 0 {
            println!("|-{}-|", widths.iter().map(|w| "-".repeat(*w)).collect::<Vec<_>>().join("-|-"));
        }
    }
    println!("{} runs failed; results appended to {}", failed, out.display());
    if failed > 0 {
        std::process::exit(1);
    }
}
