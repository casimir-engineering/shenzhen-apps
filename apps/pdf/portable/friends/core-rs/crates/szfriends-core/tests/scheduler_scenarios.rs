//! The scheduler's scenario table (`friends/fixtures/scheduler/scenarios.json`, ADR 0018 § 7, WP2), run through the
//! simulator; the Objective-C scheduler (WP4) must meet the same expectations. `--nocapture` prints the results as the
//! journal records them.

use std::path::PathBuf;

use serde_json::Value;
use szfriends_core::session::lanes::LaneRequest;
use szfriends_core::transfer::sim::{self, route_name, Scenario};

fn table() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../fixtures/scheduler/scenarios.json");
    serde_json::from_slice(&std::fs::read(&path).expect("the scenario table")).expect("JSON")
}

#[test]
fn every_scenario_meets_its_expectations() {
    let table = table();
    let mut failures = Vec::new();
    println!("| Scenario | Lanes (Mbit/s) | Time | MB/s | Of the lanes' sum | Per route (MiB sent) | Sent twice | Fastest lane idle at the end |");
    println!("|---|---|---|---|---|---|---|---|");
    for entry in table["scenarios"].as_array().expect("scenarios") {
        let scenario = Scenario::from_json(entry).unwrap_or_else(|| panic!("a scenario: {entry}"));
        let started = std::time::Instant::now();
        let out = sim::run(&scenario);
        let wall = started.elapsed();
        let name = &scenario.name;
        let Some(done) = out.done_at else {
            failures.push(format!("{name}: did not finish"));
            continue;
        };
        let secs = done.as_secs_f64();
        let mbit = scenario.size as f64 * 8.0 / secs / 1e6;
        let sum: f64 = scenario.lanes.iter().map(|l| l.rate * 8.0 / 1e6).sum();
        let tail = out.tail(&scenario.lanes);
        let per_route: Vec<String> = out
            .lanes
            .iter()
            .map(|l| format!("{} {:.1}", route_name(l.route), l.sent_bytes as f64 / (1 << 20) as f64))
            .collect();
        let lanes: Vec<String> =
            scenario.lanes.iter().map(|l| format!("{} {}", route_name(l.route), l.rate * 8.0 / 1e6)).collect();
        println!(
            "| {name} | {} | {secs:.2} s | {:.1} | {:.0} % | {} | {:.1} MiB | {} ms |",
            lanes.join(", "),
            mbit / 8.0,
            100.0 * mbit / sum,
            per_route.join(", "),
            out.wasted_bytes as f64 / (1 << 20) as f64,
            tail.as_millis(),
        );
        assert!(wall.as_secs() < 5, "{name}: the simulator took {wall:?}");
        assert!(out.max_open_blocks <= 64 && out.max_open_bytes <= 64 << 20 && !out.lane_cap_exceeded, "{name}");
        let expect = &entry["expect"];
        if let Some(min) = expect["mbit"].as_f64() {
            if mbit < min {
                failures.push(format!("{name}: {mbit:.1} Mbit/s, expected at least {min}"));
            }
        }
        if let Some(max) = expect["max_s"].as_f64() {
            if secs > max {
                failures.push(format!("{name}: {secs:.2} s, expected at most {max}"));
            }
        }
        if let Some(max) = expect["max_tail_ms"].as_u64() {
            if tail.as_millis() as u64 > max {
                failures.push(format!("{name}: fastest lane idle {} ms at the end, at most {max}", tail.as_millis()));
            }
        }
        if let Some(max) = expect["max_wasted_mib"].as_f64() {
            if out.wasted_bytes as f64 > max * (1 << 20) as f64 {
                failures.push(format!("{name}: {} bytes sent twice, at most {max} MiB", out.wasted_bytes));
            }
        }
        for route in expect["idle"].as_array().into_iter().flatten() {
            let route = route.as_str().unwrap();
            if out.lanes.iter().any(|l| route_name(l.route) == route && l.sent_bytes > 0) {
                failures.push(format!("{name}: {route} carried bytes"));
            }
        }
        for request in expect["requests"].as_array().into_iter().flatten() {
            let request = request.as_str().unwrap();
            let made = out.requests.iter().any(|(_, r)| match r {
                LaneRequest::Open { route } => request == format!("open {}", route_name(*route)),
                LaneRequest::Close { .. } => request == "close",
            });
            if !made {
                failures.push(format!("{name}: no {request} request"));
            }
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}
