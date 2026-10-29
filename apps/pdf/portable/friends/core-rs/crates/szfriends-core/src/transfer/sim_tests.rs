//! The simulator's own checks: lanes that run at their rate, hold silences, and deliver every block whatever they do.

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
        unit_shift: None,
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
            let base =
                LaneProfile::new(RouteMethod::Lan, mbit(if route == RouteMethod::Bluetooth { 16.0 } else { 300.0 }), 2);
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

#[test]
fn bluetooth_never_makes_a_transfer_slower_than_the_lan_alone() {
    // The owner's rule: whatever Bluetooth does beside a slow LAN, going out of range, cut or flapping at any
    // moment, at any share of the LAN's rate, the transfer ends no later than on the LAN alone. Socket buffers
    // make a silent lane look busy (its last block all written) until its silence is noticed.
    let mut lan = LaneProfile::new(RouteMethod::Lan, mbit(10.0), 4);
    lan.buffer = 128 << 10;
    for unit in [None, Some(18)] {
        let base = Scenario { unit_shift: unit, ..scenario("alone", 16 * MIB, vec![lan.clone()]) };
        let alone = run(&base).done_at.unwrap();
        for rate in [0.1, 0.5, 1.4, 2.0] {
            let mut at = Duration::ZERO;
            while at < alone {
                let s = Duration::from_secs_f64;
                let mut bluetooth = LaneProfile::new(RouteMethod::Bluetooth, mbit(rate), 30);
                bluetooth.buffer = 256 << 10;
                let t = at.as_secs_f64();
                let mut cut = bluetooth.clone();
                cut.cut_at = Some(at.max(s(0.001)));
                for (what, lane) in [
                    ("silent", bluetooth.clone().silent_from(at)),
                    ("cut", cut),
                    ("flapping", bluetooth.clone().flapping(at, s(1.0 + t % 3.0), s(0.5 + t % 2.0), s(60.0))),
                ] {
                    let both = Scenario { lanes: vec![lan.clone(), lane], ..base.clone() };
                    let took = run(&both).done_at.unwrap();
                    assert!(
                        took <= alone,
                        "{unit:?}, Bluetooth {rate} Mbit/s {what} at {t:.2} s: {took:?} against {alone:?}"
                    );
                }
                at += Duration::from_millis(250);
            }
        }
    }
}
