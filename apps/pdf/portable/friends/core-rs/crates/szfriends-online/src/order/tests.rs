//! The order with a scripted clock.

use super::*;

const R: f64 = 0.5;

#[test]
fn the_relay_opens_only_after_the_direct_budget() {
    let mut order = Order::new(Role::Offerer, Purpose::Friend);
    order.descriptions_applied(NatClass::EndpointIndependent, NatClass::PerDestination, 0.0);
    assert_eq!(order.phase(), Phase::PlainChecks);
    assert_eq!(order.fire_due_timers(4.9, R), 0);
    let actions = order.fire_due_timers(5.0, R);
    assert_eq!(actions, action::START_PREDICTION | action::START_PROBING);
    assert_eq!(order.phase(), Phase::HardNat);
    assert_eq!(order.fire_due_timers(17.0, R), action::STOP_PROBING | action::OPEN_RELAY);
    let relay = Route { technique: Technique::Relay, ipv6: false };
    assert_eq!(order.stream_opened(Kind::Relay, relay, 18.0, R), 0);
    assert_eq!(order.phase(), Phase::Relayed);
    assert!((order.next_deadline() - 19.0).abs() < 1e-9);
    assert_eq!(order.fire_due_timers(19.0, R), action::CLOSE_DIRECT | action::OPEN_DIRECT);
    let direct = Route { technique: Technique::ServerReflexive, ipv6: false };
    assert_eq!(order.stream_opened(Kind::Direct, direct, 49.0, R), action::CLOSE_RELAY);
    assert!(order.log_entry().left_relay);
}

#[test]
fn a_better_route_supersedes_and_another_route_keeps_the_relay_closed() {
    let mut order = Order::new(Role::Offerer, Purpose::Friend);
    order.descriptions_applied(NatClass::Unknown, NatClass::Unknown, 0.0);
    assert_eq!(order.other_route_changed(RouteMethod::Bluetooth, 1.0, R), 0);
    assert_eq!(order.fire_due_timers(5.0, R), 0);
    assert_eq!(order.phase(), Phase::Standby);
    assert_eq!(order.other_route_changed(RouteMethod::Lan, 6.0, R), action::END);
    assert_eq!(order.end_reason(), EndReason::Superseded);
}

/// ADR 0020: while the relay carries the stream, direct is tried again a short gap after each try ends, forever, never
/// backing off; a direct path that becomes possible is found within one try and the relay closes at once.
#[test]
fn while_relayed_direct_is_retried_every_second() {
    let mut order = Order::new(Role::Offerer, Purpose::Friend);
    order.descriptions_applied(NatClass::PerDestination, NatClass::PerDestination, 0.0);
    assert_eq!(order.fire_due_timers(5.0, R), action::OPEN_RELAY);
    let relay = Route { technique: Technique::Relay, ipv6: false };
    order.stream_opened(Kind::Relay, relay, 5.5, R);
    assert_eq!(order.phase(), Phase::Relayed);
    let mut now = 5.5;
    for jitter in [0.0, 1.0, 0.5, 0.0, 1.0].iter().cycle().take(200) {
        let due = order.next_deadline();
        assert!(due - now <= RELAYED_RETRY_GAP * (1.0 + RETRY_JITTER) + 1e-9, "the next try {} s away", due - now);
        assert_ne!(order.fire_due_timers(due, *jitter) & action::OPEN_DIRECT, 0);
        // The try finds nothing: its descriptions, then its plain checks, then it ends.
        order.descriptions_applied(NatClass::PerDestination, NatClass::PerDestination, due + 0.2);
        now = due + 0.2 + PLAIN_CHECKS_BUDGET;
        assert_eq!(order.fire_due_timers(now, *jitter), action::CLOSE_DIRECT);
        assert_eq!(order.phase(), Phase::Relayed);
    }
    // The next one connects: the relay closes with it.
    let due = order.next_deadline();
    order.fire_due_timers(due, R);
    let direct = Route { technique: Technique::ServerReflexive, ipv6: false };
    assert_eq!(order.stream_opened(Kind::Direct, direct, due + 0.3, R), action::CLOSE_RELAY);
    assert_eq!(order.phase(), Phase::Direct);
}

/// ADR 0020: Bluetooth carried the session (Standby); when it goes, direct is tried once more before the relay opens.
#[test]
fn when_the_other_route_goes_direct_is_tried_before_the_relay() {
    let mut order = Order::new(Role::Offerer, Purpose::Friend);
    order.descriptions_applied(NatClass::Unknown, NatClass::Unknown, 0.0);
    order.other_route_changed(RouteMethod::Bluetooth, 1.0, R);
    assert_eq!(order.fire_due_timers(5.0, R), 0);
    assert_eq!(order.phase(), Phase::Standby);
    let actions = order.other_route_changed(RouteMethod::None, 100.0, R);
    assert_eq!(actions & action::OPEN_RELAY, 0, "the relay before a new direct try");
    assert_ne!(actions & action::OPEN_DIRECT, 0);
    order.descriptions_applied(NatClass::Unknown, NatClass::Unknown, 100.3);
    assert_eq!(order.fire_due_timers(105.3, R), action::CLOSE_DIRECT | action::OPEN_RELAY);
    assert_eq!(order.phase(), Phase::Relay);
    // A direct try that connects instead never opens the relay.
    let mut order = Order::new(Role::Offerer, Purpose::Friend);
    order.descriptions_applied(NatClass::Unknown, NatClass::Unknown, 0.0);
    order.other_route_changed(RouteMethod::Bluetooth, 1.0, R);
    order.fire_due_timers(5.0, R);
    order.other_route_changed(RouteMethod::None, 100.0, R);
    let direct = Route { technique: Technique::ServerReflexive, ipv6: false };
    assert_eq!(order.stream_opened(Kind::Direct, direct, 100.5, R), 0);
    assert_eq!(order.phase(), Phase::Direct);
}
