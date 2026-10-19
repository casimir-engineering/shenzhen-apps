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
    assert!((order.next_deadline() - 48.0).abs() < 1e-9);
    assert_eq!(order.fire_due_timers(48.0, R), action::CLOSE_DIRECT | action::OPEN_DIRECT);
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
