//! Nearby between two whole Rust helpers on the loopback test network: the scenarios of `szfriends_interop::nearby`,
//! which the Objective-C pairing (`objc_nearby.rs`) and the VMs (`vm_nearby.rs`) run too.

use std::sync::Mutex;

use szfriends_interop::helpers::{rust_helper, Client};
use szfriends_interop::{nearby, nearby_devices, TempHome};

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
