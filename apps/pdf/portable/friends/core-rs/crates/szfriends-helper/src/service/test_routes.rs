//! A test home's emulated routes: their rates and the file that silences one, so lanes over several routes can be
//! measured on one computer.

use std::collections::HashMap;

/// A test home's emulated route rates, `lan=1250000,bluetooth=175000` (bytes per second each side writes at), so
/// lanes over several routes can be measured on one computer (WP5's bench emulates one route at a time).
pub const ENV_TEST_ROUTE_RATES: &str = "SZFRIENDS_TEST_ROUTE_RATES";
/// A test home's file: while it names a route (`lan`, `bluetooth`, …), links on it write nothing (out of range).
pub const ENV_TEST_ROUTE_SILENCE: &str = "SZFRIENDS_TEST_ROUTE_SILENCE";
/// A test home's emulated stacks, `bluetooth=1048576`: bytes a platform's stream takes ahead of the route's rate
/// before a write waits, as an Android phone's Bluetooth stack takes a megabyte (with a rate only).
pub const ENV_TEST_ROUTE_BUFFERS: &str = "SZFRIENDS_TEST_ROUTE_BUFFERS";
/// A test home's emulated one-way delays in milliseconds, `bluetooth=25`, over a platform's stream (with a rate only).
pub const ENV_TEST_ROUTE_DELAYS: &str = "SZFRIENDS_TEST_ROUTE_DELAYS";

/// The names `SZFRIENDS_TEST_ROUTE_RATES` and `SZFRIENDS_TEST_ROUTE_SILENCE` use.
pub(crate) fn route_name(route: szfriends_core::wire::RouteMethod) -> &'static str {
    use szfriends_core::wire::RouteMethod;
    match route {
        RouteMethod::Lan => "lan",
        RouteMethod::PeerToPeerWifi => "p2p_wifi",
        RouteMethod::Bluetooth => "bluetooth",
        RouteMethod::Internet => "internet",
        RouteMethod::Relay => "relay",
        RouteMethod::None => "none",
    }
}

pub(crate) fn route_rates(text: &str) -> HashMap<szfriends_core::wire::RouteMethod, f64> {
    use szfriends_core::wire::RouteMethod;
    text.split(',')
        .filter_map(|pair| {
            let (name, rate) = pair.split_once('=')?;
            let route = match name.trim() {
                "lan" => RouteMethod::Lan,
                "p2p_wifi" => RouteMethod::PeerToPeerWifi,
                "bluetooth" => RouteMethod::Bluetooth,
                "internet" => RouteMethod::Internet,
                "relay" => RouteMethod::Relay,
                _ => return None,
            };
            Some((route, rate.trim().parse::<f64>().ok().filter(|r| *r > 0.0)?))
        })
        .collect()
}
