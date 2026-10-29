//! ADR 0019's Wi-Fi Direct boost between two Rust helpers' services in test homes: friends on the test Bluetooth air
//! only (no network at all), Bluetooth shaped to 150 kB/s, and each side's pretend radio (`TestDirectWifi`), which
//! "hosts" on loopback and only writes down what it was asked. Ada is a device that can only join and is on her one
//! Wi-Fi network, "HomeWiFi"; Bo hosts and keeps his Wi-Fi. No real network is touched.
//!
//! - Go faster: Ada's row asks (Bo's never does), Bo hosts, Ada joins, the link's lane carries the rest, and Ada goes
//!   back to "HomeWiFi" at the end, record deleted.
//! - Not now: the question goes, nothing is hosted, and it is not asked again for that file.
//! - A record left by a crash: the next launch goes back to the network it names, then deletes it.

mod clients;
mod support;

use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use clients::{texts, Client, Temp};
use serde_json::{json, Value};
use szfriends_helper::nearby::direct_wifi::{ENV_TEST_DIRECT_WIFI, ENV_TEST_WIFI, TEST_LOG};
use szfriends_helper::nearby::test_air::ENV_TEST_BLUETOOTH;
use szfriends_helper::service::{seed, ENV_TEST_ROUTE_RATES};
use szfriends_helper::state::ENV_STATE_DIR;

/// The environment is the process's: each service reads it as it starts, one at a time.
static START: Mutex<()> = Mutex::new(());

const CAPABILITIES: &[&str] = &["drop.files", "transfers.boost"];

struct Pair {
    ada: Client,
    bo: Client,
    bo_in_a: String,
    ada_in_b: String,
    homes: (Temp, Temp, Temp),
}

fn start(label: &str) -> Pair {
    let homes =
        (Temp::new(&format!("{label}-a")), Temp::new(&format!("{label}-b")), Temp::new(&format!("{label}-air")));
    let (bo_in_a, ada_in_b) = seed::befriend(&homes.0 .0, &homes.1 .0, ("Ada", "Bo")).expect("befriended");
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var(ENV_STATE_DIR, &homes.0 .0);
    std::env::set_var(ENV_TEST_BLUETOOTH, &homes.2 .0);
    std::env::set_var(ENV_TEST_ROUTE_RATES, "bluetooth=150000");
    // Ada: joins only, on her one Wi-Fi network.
    std::env::set_var(ENV_TEST_DIRECT_WIFI, "join");
    std::env::set_var(ENV_TEST_WIFI, "HomeWiFi");
    let mut ada = Client::connect_with(&homes.0 .0, CAPABILITIES);
    // Bo: hosts, and keeps his Wi-Fi while he does.
    std::env::set_var(ENV_TEST_DIRECT_WIFI, "host,join,keeps");
    std::env::set_var(ENV_TEST_WIFI, "Bo's network");
    let mut bo = Client::connect_with(&homes.1 .0, CAPABILITIES);
    for variable in [ENV_TEST_DIRECT_WIFI, ENV_TEST_WIFI, ENV_TEST_ROUTE_RATES] {
        std::env::remove_var(variable);
    }
    ada.send("activate", json!({}));
    bo.send("activate", json!({}));
    Pair { ada, bo, bo_in_a, ada_in_b, homes }
}

fn token() -> String {
    let mut token = [0u8; 16];
    szfriends_crypto::random_bytes(&mut token);
    token.iter().map(|b| format!("{b:02x}")).collect()
}

fn item<'a>(data: &'a Value, transfer: &str) -> Option<&'a Value> {
    data["items"].as_array()?.iter().find(|i| i["transfer_id"] == transfer)
}

fn sees(client: &mut Client, chat: &str, transfer: &str, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
    let subscription = client.send("open_conversation", json!({"conversation_id": chat}))["subscription"].clone();
    let shown = client.snapshot_within(subscription.as_str().unwrap(), what, Duration::from_secs(60), |d| {
        item(d, transfer).is_some_and(&matches)
    });
    item(&shown["data"], transfer).unwrap().clone()
}

fn log_of(home: &Path) -> String {
    std::fs::read_to_string(home.join(TEST_LOG)).unwrap_or_default()
}

fn wait_for(what: &str, within: Duration, done: impl Fn() -> bool) {
    let deadline = Instant::now() + within;
    while !done() {
        assert!(Instant::now() < deadline, "{what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Ada offers Bo a file of `size` bytes and Bo accepts it: the transfer's id and the bytes.
fn offer(pair: &mut Pair, size: usize) -> (String, Vec<u8>) {
    let source = pair.homes.0 .0.join("Documents").join("Site survey.mp4");
    std::fs::create_dir_all(source.parent().unwrap()).unwrap();
    // Random, so compression on the Bluetooth lane cannot shrink it.
    let mut content = vec![0u8; size];
    szfriends_crypto::random_bytes(&mut content);
    std::fs::write(&source, &content).unwrap();
    let files = json!({"conversation_id": pair.bo_in_a, "files": [{"path": source}], "client_token": token()});
    let transfer = pair.ada.send("send_files", files)["transfer_ids"][0].as_str().unwrap().to_owned();
    let chat = pair.ada_in_b.clone();
    sees(&mut pair.bo, &chat, &transfer, "the offer at Bo", |i| texts(i).contains("accept_offer"));
    pair.bo.send("accept_offer", json!({"transfer_id": transfer}));
    (transfer, content)
}

#[test]
fn go_faster_moves_the_rest_over_the_link_and_comes_back() {
    let mut pair = start("boost-go");
    let (transfer, content) = offer(&mut pair, 10 << 20);
    let (bo_in_a, ada_in_b) = (pair.bo_in_a.clone(), pair.ada_in_b.clone());

    // After 10 s on Bluetooth alone the file is still minutes from done: Ada, who would lose her only Internet, is
    // asked, in words about her Wi-Fi and Bo.
    let asked =
        sees(&mut pair.ada, &bo_in_a, &transfer, "the question at Ada", |i| texts(i).contains("boost_transfer"));
    let note = asked["route_note"].as_str().unwrap_or_default().to_owned();
    assert!(note.starts_with("Go faster? Bo isn’t on your Wi-Fi, so this is going over Bluetooth (about "), "{note}");
    assert!(note.contains("Leave “HomeWiFi” for about "), "{note}");
    assert!(note.ends_with("Your computer rejoins it by itself when it’s done."), "{note}");
    assert!(texts(&asked).contains("skip_boost"), "{asked}");
    assert!(!log_of(&pair.homes.1 .0).contains("host"), "nothing is hosted before Ada agrees");
    // Bo keeps his Wi-Fi: his row never asks.
    let at_bo = sees(&mut pair.bo, &ada_in_b, &transfer, "Bo's row", |i| i["state"] == "receiving");
    assert!(!texts(&at_bo).contains("boost_transfer"), "{at_bo}");

    pair.ada.send("boost_transfer", json!({"transfer_id": transfer}));
    let received = sees(&mut pair.bo, &ada_in_b, &transfer, "the file at Bo", |i| i["state"] == "received");
    let path = received["file"]["path"].as_str().map(str::to_owned).unwrap_or_default();
    if !path.is_empty() {
        assert_eq!(std::fs::read(&path).unwrap(), content, "the same bytes");
    }
    // The rest came over the link: well under the 70 s Bluetooth alone needs for 10 MiB.
    let (ada_home, bo_home) = (pair.homes.0 .0.clone(), pair.homes.1 .0.clone());
    wait_for("Ada back on HomeWiFi", Duration::from_secs(20), || {
        log_of(&ada_home).contains("rejoin HomeWiFi from DIRECT-") && !ada_home.join("direct-wifi.json").exists()
    });
    let ada_log = log_of(&ada_home);
    let bo_log = log_of(&bo_home);
    let joined = ada_log.lines().find_map(|l| l.strip_prefix("join ")).expect("Ada joined").to_owned();
    assert!(bo_log.contains(&format!("host {joined}")), "Ada joined the link Bo hosted: {bo_log} / {ada_log}");
    wait_for("Bo stops hosting", Duration::from_secs(10), || log_of(&bo_home).contains("stop"));
    assert!(joined.starts_with("DIRECT-") && joined.len() == 17, "{joined}");
    assert!(!ada_log.contains("Ada") && !ada_log.contains("Bo "), "the link names nobody: {ada_log}");
}

#[test]
fn not_now_is_final_for_that_file() {
    let mut pair = start("boost-not-now");
    let (transfer, _) = offer(&mut pair, 10 << 20);
    let bo_in_a = pair.bo_in_a.clone();
    sees(&mut pair.ada, &bo_in_a, &transfer, "the question at Ada", |i| texts(i).contains("boost_transfer"));
    pair.ada.send("skip_boost", json!({"transfer_id": transfer}));
    let after = sees(&mut pair.ada, &bo_in_a, &transfer, "the question gone", |i| {
        !texts(i).contains("boost_transfer") && i["state"] == "sending"
    });
    assert!(!after["route_note"].as_str().unwrap_or_default().starts_with("Go faster"), "{after}");
    // A second answer finds nothing to answer.
    assert_eq!(pair.ada.refused("boost_transfer", json!({"transfer_id": transfer})), "stale");
    std::thread::sleep(Duration::from_secs(4));
    assert!(log_of(&pair.homes.1 .0).is_empty(), "nothing hosted: {}", log_of(&pair.homes.1 .0));
    let still = sees(&mut pair.ada, &bo_in_a, &transfer, "still sending", |i| i["state"] == "sending");
    assert!(!texts(&still).contains("boost_transfer"), "asked again: {still}");
    pair.ada.send("cancel_transfer", json!({"transfer_id": transfer}));
}

#[test]
fn a_record_left_by_a_crash_brings_the_device_back_at_launch() {
    let home = Temp::new("boost-crash");
    let record = json!({"version": 1, "network": "HomeWiFi", "network_name": "HomeWiFi",
                        "joined": "DIRECT-k3Qp7xTz2a", "left_at": 1_800_000_000.0});
    std::fs::create_dir_all(&home.0).unwrap();
    std::fs::write(home.0.join("direct-wifi.json"), record.to_string()).unwrap();
    let _client = {
        let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var(ENV_STATE_DIR, &home.0);
        std::env::set_var(ENV_TEST_DIRECT_WIFI, "join");
        // It crashed while on the link.
        std::env::set_var(ENV_TEST_WIFI, "DIRECT-k3Qp7xTz2a");
        let client = Client::connect_with(&home.0, CAPABILITIES);
        std::env::remove_var(ENV_TEST_DIRECT_WIFI);
        std::env::remove_var(ENV_TEST_WIFI);
        client
    };
    let path = home.0.clone();
    wait_for("back on HomeWiFi and the record gone", Duration::from_secs(10), || {
        log_of(&path).contains("rejoin HomeWiFi from DIRECT-k3Qp7xTz2a") && !path.join("direct-wifi.json").exists()
    });
}
