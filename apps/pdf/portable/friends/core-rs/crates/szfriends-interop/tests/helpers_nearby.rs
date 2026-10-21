//! Nearby between two whole Rust helpers on the loopback test network: the scenarios of `szfriends_interop::nearby`,
//! which the Objective-C pairing (`objc_nearby.rs`) and the VMs (`vm_nearby.rs`) run too.

use std::sync::Mutex;

use szfriends_interop::helpers::{rust_helper, rust_helper_with, Client, Room};
use szfriends_interop::{nearby, nearby_devices, routes, TempHome};

/// Helpers read the environment as they start: one pair at a time.
static START: Mutex<()> = Mutex::new(());

/// The homes come first, so they are dropped last: after the helpers, which Windows needs gone before it removes
/// their files.
fn pair(names: (&str, &str)) -> ([TempHome; 3], Client, Client) {
    let homes = [TempHome::new(names.0), TempHome::new(names.1), TempHome::new("net")];
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var("SZFRIENDS_STATE_DIR", homes[0].path());
    std::env::set_var("SZFRIENDS_TEST_LOOPBACK", homes[2].path());
    std::env::remove_var("SZFRIENDS_TEST_SERVICE_TYPE");
    let mut a = rust_helper(names.0, &homes[0].path().join("state"));
    let mut b = rust_helper(names.1, &homes[1].path().join("state"));
    nearby::start(&mut a, names.0, &mut b, names.1);
    (homes, a, b)
}

#[test]
fn visible_request_then_messages_and_a_file() {
    let (_homes, mut ann, mut ben) = pair(("Ann", "Ben"));
    nearby::visible_request(&mut ann, "Ann", &mut ben, "Ben");
}

#[test]
fn add_by_id_then_messages_and_a_file() {
    let (_homes, mut cat, mut dov) = pair(("Cat", "Dov"));
    nearby::add_by_id(&mut cat, &mut dov);
}

#[test]
fn a_declined_request() {
    let (_homes, mut eli, mut fay) = pair(("Eli", "Fay"));
    nearby::declined(&mut eli, "Eli", &mut fay, "Fay");
}

#[test]
fn a_new_computer_joins_and_syncs() {
    let (_homes, mut gil, mut hal) = pair(("Gil", "Hal"));
    nearby_devices::join_and_sync(&mut gil, "Gil", &mut hal);
}

/// Two Rust helpers in one room (the test air, and a loopback network that starts held), started and named.
fn room(names: (&str, &str)) -> ([TempHome; 3], Client, Client, Room) {
    let homes = [TempHome::new(names.0), TempHome::new(names.1), TempHome::new("room")];
    let room = Room::new(homes[2].path(), true);
    let network = homes[2].path().join("net");
    std::fs::create_dir_all(&network).unwrap();
    let mut env: Vec<(&str, String)> = room.env();
    env.push(("SZFRIENDS_TEST_LOOPBACK", network.to_string_lossy().into_owned()));
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let (mut a, mut b) = {
        let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("SZFRIENDS_STATE_DIR", homes[0].path());
        std::env::remove_var("SZFRIENDS_TEST_SERVICE_TYPE");
        let a = rust_helper_with(names.0, &homes[0].path().join("state"), &env);
        let b = rust_helper_with(names.1, &homes[1].path().join("state"), &env);
        (a, b)
    };
    nearby::start(&mut a, names.0, &mut b, names.1);
    (homes, a, b, room)
}

/// The room scenarios count on Bluetooth reads and dials arriving within the snapshot waits: one at a time.
static ROOM: Mutex<()> = Mutex::new(());

#[test]
fn bluetooth_first_then_the_network_takes_over() {
    let _one = ROOM.lock().unwrap_or_else(|e| e.into_inner());
    let (_homes, mut ida, mut jon, room) = room(("Ida", "Jon"));
    routes::bluetooth_then_network(&mut ida, "Ida", &mut jon, "Jon", &room);
}

#[test]
fn a_join_over_bluetooth_moves_to_the_network() {
    let _one = ROOM.lock().unwrap_or_else(|e| e.into_inner());
    let (_homes, mut kim, mut lev, room) = room(("Kim", "Lev"));
    routes::join_over_bluetooth_then_network(&mut kim, "Kim", &mut lev, &room);
}
