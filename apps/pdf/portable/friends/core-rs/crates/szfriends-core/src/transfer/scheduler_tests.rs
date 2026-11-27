//! The scheduler's rules, each against a few lanes driven by hand (sim.rs runs whole transfers).

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
    s.add_transfer(7, Geometry::for_size(64 * MIB).unwrap());
    s.want(7, &[(0, 64)], Duration::ZERO).unwrap();
    let first = sends(&s.take_actions());
    assert_eq!(first.len(), 16, "eight blocks per network lane at first: {first:?}");
    let on_two: Vec<u32> = first.iter().filter(|(l, _)| *l == 2).map(|(_, b)| *b).collect();
    s.lane_event(LaneEvent::Down { lane: 2 }, ms(5));
    let again = sends(&s.take_actions());
    assert!(again.is_empty(), "lane 1 is full: {again:?}");
    s.have(7, &[(0, 1)], ms(30)).unwrap();
    let next = sends(&s.take_actions());
    assert_eq!(next[0], (1, on_two[0]), "the lost lane's blocks first: {next:?}");
    assert_eq!(s.open(7).0, 15, "lost blocks stay open (the receiver may hold parts)");
}

#[test]
fn a_silent_lane_loses_its_blocks_and_is_closed_after_ten_seconds() {
    let mut s = Scheduler::new(Config { direct_wifi: true, ..Config::default() });
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
fn direct_wifi_the_rule_does_not_allow_is_closed_unused() {
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
    let mut awdl = Scheduler::new(Config { direct_wifi: true, ..Config::default() });
    up(&mut awdl, 1, 0, RouteMethod::Relay);
    awdl.add_transfer(1, Geometry::for_size(512 * MIB).unwrap());
    awdl.want(1, &[(0, 512)], Duration::ZERO).unwrap();
    assert!(awdl.take_actions().contains(&Action::Lane(LaneRequest::Open { route: RouteMethod::PeerToPeerWifi })));
    // Beside a LAN, never asked for (ADR 0022: no direct Wi-Fi for speed, whatever the LAN measures).
    let mut lan = Scheduler::new(Config { direct_wifi: true, ..Config::default() });
    up(&mut lan, 1, 0, RouteMethod::Lan);
    lan.add_transfer(1, Geometry::for_size(512 * MIB).unwrap());
    lan.want(1, &[(0, 512)], Duration::ZERO).unwrap();
    assert!(!lan.take_actions().contains(&Action::Lane(LaneRequest::Open { route: RouteMethod::PeerToPeerWifi })));
    // A device joined a Wi-Fi network: the rule says no now, and the lane closes.
    up(&mut awdl, 2, 1, RouteMethod::PeerToPeerWifi);
    awdl.take_actions();
    awdl.set_direct_wifi(false);
    assert!(awdl.take_actions().contains(&Action::Lane(LaneRequest::Close { lane: 2 })));
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
    // Already allowed by the owner's rule: ending a boost closes nothing.
    let mut awdl = Scheduler::new(Config { direct_wifi: true, ..Config::default() });
    up(&mut awdl, 2, 1, RouteMethod::PeerToPeerWifi);
    awdl.allow_direct_wifi(false);
    assert!(awdl.take_actions().is_empty());
}

#[test]
fn a_block_that_failed_is_wanted_again_alone_and_goes_first() {
    let mut s = Scheduler::new(Config::default());
    up(&mut s, 1, 0, RouteMethod::Lan);
    s.add_transfer(1, Geometry::for_size(16 * MIB).unwrap());
    s.want(1, &[(0, 16)], Duration::ZERO).unwrap();
    assert_eq!(sends(&s.take_actions()), (0..8).map(|b| (1, b)).collect::<Vec<_>>(), "eight on a network lane");
    s.want(1, &[(0, 1)], ms(10)).unwrap();
    let actions = s.take_actions();
    assert_eq!(actions[0], Action::Cancel { lane: 1, transfer: 1, block: 0 });
    assert_eq!(sends(&actions), vec![(1, 0)]);
    assert_eq!(s.want(1, &[(15, 2)], ms(10)), Err(SchedulerError::OutOfRange));
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

/// ADR 0018 § 7.2: a LAN lane that falls under half its peak while it has blocks to move gets a lane beside it on
/// another interface; that lane is kept only if the group then moves 10 % more.
#[test]
fn a_degraded_lane_gets_a_lane_beside_it_kept_only_if_it_helps() {
    use std::collections::VecDeque;
    let mut s = Scheduler::new(Config::default());
    up(&mut s, 1, 0, RouteMethod::Lan);
    s.add_transfer(1, Geometry::for_size(2048 * MIB).unwrap());
    s.want(1, &[(0, 2048)], Duration::ZERO).unwrap();
    let mut queue: VecDeque<u32> = VecDeque::new();
    let mut requests: Vec<(Duration, LaneRequest)> = Vec::new();
    let mut lane_two_up = false;
    let mut t = 0u64;
    loop {
        let now = ms(t);
        for a in s.take_actions() {
            match a {
                Action::Send { lane, block, .. } => {
                    s.sent(lane, 1, block, now);
                    queue.push_back(block);
                }
                Action::Lane(request) => requests.push((now, request)),
                Action::Cancel { block, .. } => queue.retain(|b| *b != block),
            }
        }
        let asked = requests.iter().any(|(_, r)| matches!(r, LaneRequest::OpenBeside { .. }));
        if asked && !lane_two_up {
            lane_two_up = true;
            s.lane_event(LaneEvent::Up { lane: 2, index: 1, route: RouteMethod::Lan }, now);
            continue;
        }
        if t >= 20_000 {
            break;
        }
        // 40 MB/s for 4 s (one MiB every 25 ms), then 10 MB/s whatever the lanes: one slow path.
        t += if t < 4_000 { 25 } else { 100 };
        let Some(block) = queue.pop_front() else { break };
        s.have(1, &[(block, 1)], ms(t)).unwrap();
    }
    let (asked_at, _) = requests
        .iter()
        .find(|(_, r)| *r == LaneRequest::OpenBeside { route: RouteMethod::Lan, beside: 1 })
        .unwrap_or_else(|| panic!("a LAN lane beside the degraded one: {requests:?}"));
    assert!(*asked_at >= ms(6_000) && *asked_at <= ms(9_000), "3 s under half its peak: {asked_at:?}");
    let verdicts = s.take_verdicts();
    assert!(verdicts.iter().any(|v| v.lane == 2 && !v.kept), "judged useless: {verdicts:?}");
    assert!(requests.iter().any(|(_, r)| *r == LaneRequest::Close { lane: 2 }), "and closed: {requests:?}");
}
