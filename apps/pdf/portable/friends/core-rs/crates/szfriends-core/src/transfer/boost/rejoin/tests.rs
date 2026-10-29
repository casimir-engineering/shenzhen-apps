//! Coming back from a boost: the record, the rejoin and its retries, and what the person is told.

use std::time::Duration;

use super::*;

fn s(seconds: u64) -> Duration {
    Duration::from_secs(seconds)
}

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
