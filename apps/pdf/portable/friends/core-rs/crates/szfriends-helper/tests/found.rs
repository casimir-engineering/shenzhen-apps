//! How a nearby person was found (client capability `nearby.found`), end to end between two Rust helpers' services in
//! test homes: over the test network alone, over the test Bluetooth air alone, and over both at once, Nearby's row
//! names each method that sees the person.

mod clients;
mod support;

use std::sync::Mutex;

use clients::{Client, Temp};
use serde_json::{json, Value};
use szfriends_helper::nearby::test_air::{ENV_TEST_BLUETOOTH, ENV_TEST_BLUETOOTH_POWER};
use szfriends_helper::service::ENV_TEST_LOOPBACK;
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: helpers start one pair at a time.
static START: Mutex<()> = Mutex::new(());

/// Ada visible to Bo over the methods given; the `found` Bo's Nearby row for Ada shows once it names `label`.
fn found_over(network: bool, bluetooth: bool, label: &str) -> Value {
    let (a, b, net, air) = (Temp::new("fa"), Temp::new("fb"), Temp::new("fnet"), Temp::new("fair"));
    let (mut ada, mut bo) = {
        let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var(ENV_STATE_DIR, &a.0);
        std::env::remove_var(ENV_TEST_BLUETOOTH_POWER);
        match network {
            true => std::env::set_var(ENV_TEST_LOOPBACK, &net.0),
            false => std::env::remove_var(ENV_TEST_LOOPBACK),
        }
        match bluetooth {
            true => std::env::set_var(ENV_TEST_BLUETOOTH, &air.0),
            false => std::env::remove_var(ENV_TEST_BLUETOOTH),
        }
        (Client::connect(&a.0), Client::connect_with(&b.0, &["nearby.found"]))
    };
    ada.send("set_name", json!({"name": "Ada"}));
    for client in [&mut ada, &mut bo] {
        client.send("activate", json!({}));
    }
    ada.send("start_visibility", json!({}));
    let nearby = bo.subscribe("nearby", json!({}));
    let ada_row = |d: &Value| d["people"].as_array().and_then(|p| p.iter().find(|p| p["title"] == "Ada")).cloned();
    let seen = bo.snapshot(&nearby, &format!("Ada found over {label}"), |d| {
        ada_row(d).is_some_and(|row| row["found"]["label"] == label)
    });
    let row = ada_row(&seen["data"]).unwrap();
    let spoken = row["accessibility_label"].as_str().unwrap();
    assert!(spoken.ends_with(&format!("Found over {label}")), "{spoken}");
    drop((ada, bo));
    drop((a, b, net, air));
    row["found"].clone()
}

#[test]
fn over_the_local_network() {
    assert_eq!(found_over(true, false, "Local network")["methods"], json!(["lan"]));
}

#[test]
fn over_bluetooth() {
    assert_eq!(found_over(false, true, "Bluetooth")["methods"], json!(["bluetooth"]));
}

#[test]
fn over_both() {
    let found = found_over(true, true, "Local network and Bluetooth");
    assert_eq!(found["methods"], json!(["lan", "bluetooth"]));
}
