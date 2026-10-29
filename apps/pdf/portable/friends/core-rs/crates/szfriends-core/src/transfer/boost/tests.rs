use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use super::*;
use szfriends_wire::consts::boost_reason;

const MIB: u64 = 1 << 20;
const T: [u8; 16] = [7; 16];

fn s(seconds: u64) -> Duration {
    Duration::from_secs(seconds)
}

fn home_wifi() -> Connectivity {
    Connectivity { on_wifi: true, wifi_name: Some("HomeWiFi".into()), ..Connectivity::default() }
}

fn gateway() -> IpAddr {
    IpAddr::V4(Ipv4Addr::new(192, 168, 49, 1))
}

// ----- when -----

#[test]
fn small_transfers_never_boost() {
    // 2 MiB at Bluetooth's 150 kB/s is 14 s: nothing to save.
    assert!(worth_it(2 * MIB, 0.0).is_none());
    // 4 MiB is 28 s over Bluetooth against 15.5 s direct: 12 s saved, under 20.
    assert!(worth_it(4 * MIB, 0.0).is_none());
    // 8 MiB: 56 s against 16 s.
    let estimate = worth_it(8 * MIB, 0.0).expect("worth it");
    assert!(estimate.saved_seconds() > 39.0 && estimate.saved_seconds() < 41.0, "{estimate:?}");
}

#[test]
fn the_measured_bluetooth_rate_decides() {
    // 100 MiB over a fast Bluetooth link (2 MB/s): 52 s against 28 s.
    assert!(worth_it(100 * MIB, 2e6).is_some());
    // 40 MiB at 2 MB/s: 21 s against 20 s, not worth it.
    assert!(worth_it(40 * MIB, 2e6).is_none());
}

#[test]
fn only_when_bluetooth_alone_and_the_network_had_its_chances() {
    let base = Situation { bluetooth_only: true, bluetooth_only_for: s(10), ..Situation::default() };
    assert!(not_on_same_network(&base), "never seen on the network in 10 s");
    assert!(!not_on_same_network(&Situation { bluetooth_only_for: s(9), ..base }), "too early to tell");
    assert!(!not_on_same_network(&Situation { bluetooth_only: false, ..base }), "another route carries it");
    let seen = Situation { seen_on_network: true, ..base };
    assert!(!not_on_same_network(&seen), "seen: the network dials first");
    assert!(!not_on_same_network(&Situation { network_failures: 2, ..seen }));
    assert!(not_on_same_network(&Situation { network_failures: 3, ..seen }), "three dials failed");
}

// ----- roles and cost -----

#[test]
fn abilities_round_trip_and_ignore_unknown_bits() {
    for a in [Abilities::android(true), Abilities::android(false), Abilities::joins_only(), Abilities::default()] {
        assert_eq!(Abilities::from_byte(a.byte()), a);
        assert_eq!(Abilities::from_byte(a.byte() | 0xf0), a);
    }
}

#[test]
fn android_hosts_macs_and_iphones_join() {
    let mac = Abilities::joins_only();
    let phone = Abilities::android(true);
    assert_eq!(role(mac, phone, true), Some(Role::Join));
    assert_eq!(role(phone, mac, false), Some(Role::Host));
    // Two Macs, a Mac and an iPhone: nobody hosts (AWDL already carries them).
    assert_eq!(role(mac, mac, true), None);
    assert_eq!(role(Abilities::default(), phone, true), None);
}

#[test]
fn the_pairing_that_keeps_more_devices_online_hosts() {
    let concurrent = Abilities::android(true);
    let not = Abilities::android(false);
    // Keeps its Wi-Fi hosting, not joining: hosting costs one device, the other way round two.
    let hosts_well = Abilities { join_keeps_wifi: false, ..concurrent };
    assert_eq!(role(hosts_well, not, false), Some(Role::Host));
    assert_eq!(role(not, hosts_well, true), Some(Role::Join));
    // Equal: the identity key that sorts first hosts, the same answer on both sides.
    assert_eq!(role(concurrent, concurrent, true), Some(Role::Host));
    assert_eq!(role(concurrent, concurrent, false), Some(Role::Join));
}

#[test]
fn only_a_device_losing_its_only_internet_is_asked() {
    let mac = Abilities::joins_only();
    assert_eq!(Cost::of(Role::Join, mac, &home_wifi()), Cost::LeavesInternet { network: Some("HomeWiFi".into()) });
    assert!(Cost::of(Role::Join, mac, &home_wifi()).asks());
    let wired = Connectivity { wired: true, ..home_wifi() };
    assert_eq!(
        Cost::of(Role::Join, mac, &wired),
        Cost::LeavesWifi { network: Some("HomeWiFi".into()), over_mobile: false }
    );
    let phone = Connectivity { mobile: true, ..home_wifi() };
    let cost = Cost::of(Role::Join, mac, &phone);
    assert_eq!(cost, Cost::LeavesWifi { network: Some("HomeWiFi".into()), over_mobile: true });
    assert!(!cost.asks() && cost.leaves_wifi());
    // Not on Wi-Fi at all, or a role that keeps it: nothing.
    assert_eq!(Cost::of(Role::Join, mac, &Connectivity { mobile: true, ..Connectivity::default() }), Cost::Nothing);
    assert_eq!(Cost::of(Role::Host, Abilities::android(true), &home_wifi()), Cost::Nothing);
    assert!(Cost::of(Role::Host, Abilities::android(false), &home_wifi()).asks());
    // An unnamed network still asks; the question then says "your Wi-Fi".
    let unnamed = Connectivity { wifi_name: None, ..home_wifi() };
    assert_eq!(Cost::of(Role::Join, mac, &unnamed), Cost::LeavesInternet { network: None });
}

// ----- link and frames -----

#[test]
fn links_are_random_android_names_and_strong_passphrases() {
    let a = Link::new();
    let b = Link::new();
    assert_ne!(a, b);
    for link in [&a, &b] {
        assert!(link.valid(), "{link:?}");
        assert!(link.network.starts_with("DIRECT-") && link.network.len() == 17, "{}", link.network);
        assert_eq!(link.passphrase.len(), 20);
        assert!(!link.network.to_lowercase().contains("friends"));
    }
    // The same bytes make the same link (the vectors' link).
    let fixed = Link::from_random(&[0; 64]);
    assert_eq!(fixed.network, "DIRECT-AAAAAAAAAA");
    assert!(!format!("{fixed:?}").contains(&fixed.passphrase), "the passphrase never reaches a log");
}

#[test]
fn frames_round_trip_through_the_codec() {
    let link = Link::from_random(&[3; 64]);
    for message in [
        Message::Propose { abilities: Abilities::joins_only() },
        Message::Ready { abilities: Abilities::android(true) },
        Message::Host { link: link.clone(), address: gateway(), port: 49_152 },
        Message::Host { link, address: "fe80::1".parse().unwrap(), port: 1 },
        Message::End { reason: boost_reason::SLOWER },
        Message::Decline { reason: boost_reason::NOT_NOW },
    ] {
        let frame = encode(&T, &message);
        let bytes = frame.encode().expect("the codec accepts it");
        let back = szfriends_wire::Frame::decode(&bytes).expect("decodes");
        assert_eq!(decode(&back), Ok((T, message)));
    }
}

#[test]
fn a_host_message_naming_anything_else_is_refused() {
    let link = Link::from_random(&[3; 64]);
    let public = Message::Host { link: link.clone(), address: "8.8.8.8".parse().unwrap(), port: 80 };
    assert_eq!(decode(&encode(&T, &public)), Err(MessageError::BadLink));
    let not_direct = Link { network: "HomeWiFi".into(), ..link.clone() };
    let renamed = Message::Host { link: not_direct, address: gateway(), port: 80 };
    assert_eq!(decode(&encode(&T, &renamed)), Err(MessageError::BadLink));
    let port_zero = Message::Host { link, address: gateway(), port: 0 };
    assert_eq!(decode(&encode(&T, &port_zero)), Err(MessageError::BadLink));
    let unknown = szfriends_wire::Frame::new(szfriends_wire::FrameType::Boost)
        .with(szfriends_wire::tag::ID, T.to_vec())
        .with(szfriends_wire::tag::STEP, [9]);
    assert_eq!(decode(&unknown), Err(MessageError::UnknownStep(9)));
}

// ----- negotiation -----

/// Two sides wired to each other: messages go across, platform effects are answered as a working platform would.
struct Pair {
    a: Boost,
    b: Boost,
    a_effects: Vec<Effect>,
    b_effects: Vec<Effect>,
}

impl Pair {
    fn pump(&mut self, now: Duration) {
        for _ in 0..10 {
            let from_a = self.a.take_effects();
            let from_b = self.b.take_effects();
            if from_a.is_empty() && from_b.is_empty() {
                return;
            }
            for (effects, other, log) in
                [(from_a, &mut self.b, &mut self.a_effects), (from_b, &mut self.a, &mut self.b_effects)]
            {
                for effect in effects {
                    if let Effect::Send(message) = &effect {
                        other.message(message.clone(), now);
                    }
                    log.push(effect);
                }
            }
        }
        panic!("effects never settled");
    }
}

/// The Mac (A, joins only, on its only Wi-Fi) proposes to an Android phone (B, concurrent).
fn mac_and_phone() -> Pair {
    let a = Boost::propose(T, Abilities::joins_only(), home_wifi(), true);
    let mut pair = Pair {
        a,
        b: Boost::propose(T, Abilities::default(), Connectivity::default(), false),
        a_effects: vec![],
        b_effects: vec![],
    };
    // B starts from A's PROPOSE.
    let propose = pair.a.take_effects();
    assert_eq!(propose, vec![Effect::Send(Message::Propose { abilities: Abilities::joins_only() })]);
    pair.b = Boost::proposed(T, Abilities::android(true), Abilities::joins_only(), home_wifi(), false, s(0));
    pair
}

#[test]
fn mac_joins_a_phone_after_its_person_says_go_faster() {
    let mut pair = mac_and_phone();
    pair.pump(s(0));
    // The phone keeps its Wi-Fi as host: no question there, READY at once. The Mac asks.
    assert!(pair.b_effects.contains(&Effect::Send(Message::Ready { abilities: Abilities::android(true) })));
    assert_eq!(pair.a.phase(), Phase::Asking);
    assert!(pair.a_effects.contains(&Effect::Ask(Cost::LeavesInternet { network: Some("HomeWiFi".into()) })));
    assert!(!pair.b_effects.iter().any(|e| matches!(e, Effect::Host(_))), "nothing hosted before the Mac agrees");

    pair.a.answer(true, s(5));
    pair.pump(s(5));
    assert_eq!(pair.b.phase(), Phase::Hosting);
    let Some(Effect::Host(link)) = pair.b_effects.iter().find(|e| matches!(e, Effect::Host(_))).cloned() else {
        panic!("the phone hosts");
    };
    pair.b.hosted(gateway(), 50_000, s(7));
    pair.pump(s(7));
    assert_eq!(pair.a.phase(), Phase::Joining);
    assert!(pair.a_effects.contains(&Effect::Join(link.clone())), "the Mac joins the link the phone made");
    pair.a.joined(s(12));
    pair.pump(s(12));
    assert!(pair.a_effects.contains(&Effect::Dial { address: gateway(), port: 50_000 }));
    pair.a.lane_up(s(13));
    pair.b.lane_up(s(13));
    assert!(pair.a.direct() && pair.b.direct());

    // Faster than Bluetooth: kept. The transfer ends: the phone stops hosting, the Mac goes back.
    pair.a.rates(20e6, 0.2e6, s(30));
    assert!(pair.a.direct());
    pair.a.transfer_ended(s(60));
    pair.pump(s(60));
    assert!(pair.a_effects.contains(&Effect::LeaveJoined));
    assert!(pair.a_effects.contains(&Effect::AllowDirectLane(false)));
    assert!(pair.b_effects.contains(&Effect::StopHosting));
    assert_eq!(pair.b.end_reason(), Some(boost_reason::TRANSFER_ENDED));
}

#[test]
fn not_now_declines_and_is_never_asked_again() {
    let mut pair = mac_and_phone();
    pair.pump(s(0));
    pair.a.answer(false, s(3));
    pair.pump(s(3));
    assert!(pair.a.declined_by_person() && pair.b.declined_by_person());
    assert_eq!(pair.a.phase(), Phase::Ended);
    assert_eq!(pair.b.phase(), Phase::Ended);
    assert!(pair.a_effects.contains(&Effect::Unask));
    assert!(pair.a_effects.contains(&Effect::Send(Message::Decline { reason: boost_reason::NOT_NOW })));
    assert!(!pair.b_effects.iter().any(|e| matches!(e, Effect::Host(_) | Effect::StopHosting)));
    // A second answer changes nothing.
    pair.a.answer(true, s(4));
    assert!(pair.a.take_effects().is_empty());
}

#[test]
fn a_slower_direct_lane_ends_the_boost() {
    let mut pair = mac_and_phone();
    pair.pump(s(0));
    pair.a.answer(true, s(1));
    pair.pump(s(1));
    pair.b.hosted(gateway(), 50_000, s(2));
    pair.pump(s(2));
    pair.a.joined(s(3));
    pair.a.lane_up(s(4));
    pair.b.lane_up(s(4));
    pair.pump(s(4));
    // Too early to judge.
    pair.a.rates(0.1e6, 0.2e6, s(8));
    assert!(pair.a.direct());
    pair.a.rates(0.1e6, 0.2e6, s(10));
    pair.pump(s(10));
    assert_eq!(pair.a.end_reason(), Some(boost_reason::SLOWER));
    assert!(pair.a_effects.contains(&Effect::LeaveJoined));
    assert!(pair.b_effects.contains(&Effect::StopHosting));
}

#[test]
fn a_link_that_never_comes_up_ends_and_comes_back() {
    let mut pair = mac_and_phone();
    pair.pump(s(0));
    pair.a.answer(true, s(1));
    pair.pump(s(1));
    pair.b.hosted(gateway(), 50_000, s(2));
    pair.pump(s(2));
    // The Mac never manages to join.
    pair.a.tick(s(30));
    assert_eq!(pair.a.phase(), Phase::Joining, "still within the time a link takes");
    pair.a.tick(s(46));
    pair.pump(s(46));
    assert_eq!(pair.a.end_reason(), Some(boost_reason::FAILED));
    assert!(pair.a_effects.contains(&Effect::LeaveJoined), "it may have half-joined: it goes back anyway");
    assert!(pair.b_effects.contains(&Effect::StopHosting));
}

#[test]
fn failures_and_lost_sessions_come_back_too() {
    let mut pair = mac_and_phone();
    pair.pump(s(0));
    pair.a.answer(true, s(1));
    pair.pump(s(1));
    pair.b.failed(s(2)); // the phone could not host
    pair.pump(s(2));
    assert_eq!(pair.a.phase(), Phase::Ended);
    assert!(pair.b_effects.contains(&Effect::StopHosting));
    assert!(!pair.a_effects.contains(&Effect::LeaveJoined), "it never left");

    let mut pair = mac_and_phone();
    pair.pump(s(0));
    pair.a.answer(true, s(1));
    pair.pump(s(1));
    pair.b.hosted(gateway(), 50_000, s(2));
    pair.pump(s(2));
    let sent = pair.a_effects.len();
    pair.a.session_lost(s(3));
    let effects = pair.a.take_effects();
    assert!(effects.contains(&Effect::LeaveJoined));
    assert!(!effects.iter().any(|e| matches!(e, Effect::Send(_))), "nothing to send it on");
    assert_eq!(pair.a_effects.len(), sent);
}

#[test]
fn a_question_left_open_goes_when_the_transfer_ends() {
    let mut pair = mac_and_phone();
    pair.pump(s(0));
    pair.a.transfer_ended(s(30));
    let effects = pair.a.take_effects();
    assert!(effects.contains(&Effect::Unask));
    assert!(effects.contains(&Effect::Send(Message::Decline { reason: boost_reason::TRANSFER_ENDED })));
    assert!(!pair.a.declined_by_person(), "not the person's answer");
}

#[test]
fn proposals_that_cross_still_meet() {
    // Two Android phones on the same kind of hardware propose at once; the key order decides who hosts.
    let mut pair = Pair {
        a: Boost::propose(T, Abilities::android(true), home_wifi(), true),
        b: Boost::propose(T, Abilities::android(true), home_wifi(), false),
        a_effects: vec![],
        b_effects: vec![],
    };
    pair.pump(s(0));
    assert_eq!(pair.a.role(), Some(Role::Host));
    assert_eq!(pair.b.role(), Some(Role::Join));
    assert_eq!(pair.a.phase(), Phase::Hosting, "nobody asked: both keep their Wi-Fi");
    assert!(!pair.a_effects.iter().chain(&pair.b_effects).any(|e| matches!(e, Effect::Ask(_))));
}

#[test]
fn two_devices_that_cannot_pair_decline() {
    let a = Boost::propose(T, Abilities::joins_only(), home_wifi(), true);
    let mut pair = Pair {
        a,
        b: Boost::proposed(T, Abilities::joins_only(), Abilities::joins_only(), home_wifi(), false, s(0)),
        a_effects: vec![],
        b_effects: vec![],
    };
    pair.a.take_effects();
    pair.pump(s(0));
    assert_eq!(pair.a.end_reason(), Some(boost_reason::UNSUPPORTED));
    assert!(!pair.a.declined_by_person());
}

#[test]
fn host_from_a_side_that_did_not_agree_is_ignored() {
    let mut pair = mac_and_phone();
    pair.pump(s(0));
    // Still asking: a HOST arriving now (a confused or hostile peer) changes nothing.
    pair.a.message(Message::Host { link: Link::new(), address: gateway(), port: 1 }, s(1));
    assert_eq!(pair.a.phase(), Phase::Asking);
    assert!(!pair.a.take_effects().iter().any(|e| matches!(e, Effect::Join(_))));
}

// ----- coming back -----

fn saved() -> Saved {
    Saved {
        network: Some("HomeWiFi".into()),
        network_name: Some("HomeWiFi".into()),
        joined: "DIRECT-ab12345678".into(),
        left_at: 1_800_000_000.0,
    }
}

#[test]
fn the_record_round_trips_and_refuses_what_it_does_not_know() {
    let record = saved();
    assert_eq!(Saved::from_json(&record.to_json()), Some(record.clone()));
    let mut later = record.to_json();
    later["version"] = json!(2);
    assert_eq!(Saved::from_json(&later), None);
    assert_eq!(Saved::from_json(&json!({"version": 1})), None);
    let nowhere = Saved { network: None, network_name: None, ..record };
    assert_eq!(Saved::from_json(&nowhere.to_json()), Some(nowhere));
}

#[test]
fn comes_back_and_checks_it_is_online() {
    let mut rejoin = Rejoin::default();
    rejoin.leaving(saved());
    assert_eq!(rejoin.take_effects(), vec![RejoinEffect::Write(saved())]);
    assert!(rejoin.away());
    rejoin.come_back(s(100));
    assert_eq!(
        rejoin.take_effects(),
        vec![RejoinEffect::Rejoin { network: Some("HomeWiFi".into()), joined: "DIRECT-ab12345678".into() }]
    );
    rejoin.rejoined(true, s(103));
    assert_eq!(rejoin.take_effects(), vec![RejoinEffect::CheckOnline]);
    rejoin.online(false, s(104));
    rejoin.tick(s(106));
    assert_eq!(rejoin.take_effects(), vec![RejoinEffect::CheckOnline]);
    rejoin.online(true, s(106));
    assert_eq!(rejoin.take_effects(), vec![RejoinEffect::Forget]);
    assert!(!rejoin.away());
}

#[test]
fn rejoining_is_retried_then_the_person_is_told() {
    let mut rejoin = Rejoin::default();
    rejoin.leaving(saved());
    rejoin.take_effects();
    rejoin.come_back(s(0));
    rejoin.take_effects();
    rejoin.rejoined(false, s(1));
    rejoin.tick(s(4));
    assert!(matches!(rejoin.take_effects()[..], [RejoinEffect::Rejoin { .. }]));
    rejoin.rejoined(false, s(5));
    rejoin.tick(s(8));
    assert!(matches!(rejoin.take_effects()[..], [RejoinEffect::Rejoin { .. }]));
    rejoin.rejoined(false, s(9));
    assert_eq!(
        rejoin.take_effects(),
        vec![RejoinEffect::Forget, RejoinEffect::Tell { network_name: Some("HomeWiFi".into()) }]
    );
    // Nothing more happens after giving up.
    rejoin.tick(s(100));
    assert!(rejoin.take_effects().is_empty());
}

#[test]
fn back_on_wifi_without_internet_is_told_too() {
    let mut rejoin = Rejoin::default();
    rejoin.leaving(saved());
    rejoin.come_back(s(0));
    rejoin.rejoined(true, s(1));
    rejoin.take_effects();
    for second in (2..=24).step_by(2) {
        rejoin.online(false, s(second));
        rejoin.tick(s(second + 2));
    }
    let effects = rejoin.take_effects();
    assert!(effects.contains(&RejoinEffect::Tell { network_name: Some("HomeWiFi".into()) }), "{effects:?}");
}

#[test]
fn an_unanswered_rejoin_counts_as_failed() {
    let mut rejoin = Rejoin::default();
    rejoin.leaving(saved());
    rejoin.come_back(s(0));
    rejoin.take_effects();
    rejoin.tick(s(3));
    rejoin.tick(s(6));
    rejoin.tick(s(9));
    let effects = rejoin.take_effects();
    assert_eq!(effects.iter().filter(|e| matches!(e, RejoinEffect::Rejoin { .. })).count(), 2);
    assert!(effects.contains(&RejoinEffect::Tell { network_name: Some("HomeWiFi".into()) }));
}

#[test]
fn a_crash_while_away_comes_back_at_the_next_launch() {
    let mut rejoin = Rejoin::launched(Some(saved()), s(0));
    assert_eq!(
        rejoin.take_effects(),
        vec![RejoinEffect::Rejoin { network: Some("HomeWiFi".into()), joined: "DIRECT-ab12345678".into() }]
    );
    rejoin.rejoined(true, s(2));
    rejoin.online(true, s(3));
    assert_eq!(rejoin.take_effects(), vec![RejoinEffect::CheckOnline, RejoinEffect::Forget]);
    // No record: nothing at all.
    let mut quiet = Rejoin::launched(None, s(0));
    assert!(quiet.take_effects().is_empty() && !quiet.away());
}

#[test]
fn a_device_that_was_on_no_wifi_only_leaves_the_link() {
    let mut rejoin = Rejoin::default();
    rejoin.leaving(Saved { network: None, network_name: None, ..saved() });
    rejoin.take_effects();
    rejoin.come_back(s(0));
    assert_eq!(rejoin.take_effects(), vec![RejoinEffect::Rejoin { network: None, joined: "DIRECT-ab12345678".into() }]);
    rejoin.rejoined(true, s(1));
    assert_eq!(rejoin.take_effects(), vec![RejoinEffect::Forget], "no Internet check: it relied on mobile data");
}
