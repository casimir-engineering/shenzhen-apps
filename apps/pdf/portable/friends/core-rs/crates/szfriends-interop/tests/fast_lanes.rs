//! Lanes between whole Rust helpers (ADR 0018 § 6), on the loopback test network and the test air, each route held
//! to an emulated rate (`SZFRIENDS_TEST_ROUTE_RATES`): a file sent by blocks over a slow local network gets a
//! Bluetooth lane too, arrives intact, and sooner than over the network alone (`SZFRIENDS_TEST_LANES=0`).
//!
//! `lanes_bench` (ignored; `cargo test --release -p szfriends-interop --test fast_lanes -- --ignored --nocapture`)
//! prints the numbers the journal records: 10 Mbit/s LAN with Bluetooth's 175 KB/s, lanes off and on.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use szfriends_interop::helpers::{rust_helper_with, Client, Room};
use szfriends_interop::{nearby, routes, TempHome};

static START: Mutex<()> = Mutex::new(());

struct Pair {
    ann: Client,
    ben: Client,
    ben_in_ann: String,
    ann_in_ben: String,
    _homes: (TempHome, TempHome, TempHome),
    _room: Room,
}

fn start(name: &str, home: &TempHome, net: &TempHome, room: &Room, rates: &str, lanes: bool) -> Client {
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var("SZFRIENDS_STATE_DIR", home.path());
    std::env::set_var("SZFRIENDS_TEST_LOOPBACK", net.path());
    std::env::remove_var("SZFRIENDS_TEST_SERVICE_TYPE");
    let mut env: Vec<(&str, String)> = room.env();
    env.push(("SZFRIENDS_TEST_ROUTE_RATES", rates.to_owned()));
    if !lanes {
        env.push(("SZFRIENDS_TEST_LANES", "0".into()));
    }
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
    rust_helper_with(name, &home.path().join("state"), &env)
}

/// Two friends; befriending again when the nearby request raced a merge of the two routes' sightings (the person's
/// nearby id changed between finding them and asking: "This isn't here anymore"), which is not what this measures.
fn pair(tag: &str, rates: &str, lanes: bool) -> Pair {
    for _ in 0..2 {
        let made = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| befriended(tag, rates, lanes)));
        if let Ok(pair) = made {
            return pair;
        }
    }
    befriended(tag, rates, lanes)
}

fn befriended(tag: &str, rates: &str, lanes: bool) -> Pair {
    let homes = (
        TempHome::new(&format!("{tag}-ann")),
        TempHome::new(&format!("{tag}-ben")),
        TempHome::new(&format!("{tag}-net")),
    );
    let room = Room::new(homes.2.path(), false);
    // Friends first at full speed (the request and its code are not what is measured), then both helpers again with
    // the routes held to their rates.
    let mut ann = start("Ann", &homes.0, &homes.2, &room, "", lanes);
    let mut ben = start("Ben", &homes.1, &homes.2, &room, "", lanes);
    nearby::start(&mut ann, "Ann", &mut ben, "Ben");
    nearby::visible_request(&mut ann, "Ann", &mut ben, "Ben");
    let (ben_in_ann, ann_in_ben) =
        (routes::conversation_with(&mut ann, "Ben"), routes::conversation_with(&mut ben, "Ann"));
    drop((ann, ben));
    let ann = start("Ann", &homes.0, &homes.2, &room, rates, lanes);
    let ben = start("Ben", &homes.1, &homes.2, &room, rates, lanes);
    Pair { ann, ben, ben_in_ann, ann_in_ben, _homes: homes, _room: room }
}

fn item<'a>(data: &'a Value, transfer: &str) -> Option<&'a Value> {
    data["items"].as_array()?.iter().find(|i| i["transfer_id"] == transfer)
}

/// Ann sends Ben a file of `size` bytes, accepted at once; the seconds from acceptance until Ben saved it.
fn send(pair: &mut Pair, name: &str, size: usize, during: impl FnOnce(&Pair)) -> f64 {
    let path = pair.ann.make_file(name, size);
    let files =
        json!({"conversation_id": pair.ben_in_ann, "files": [{"path": path}], "client_token": "lane0123lane4567"});
    let transfer = pair.ann.send("send_files", files)["transfer_ids"][0].as_str().expect("a transfer").to_owned();
    let chat = pair.ben.open(&pair.ann_in_ben);
    pair.ben
        .snapshot(&chat, "the offer", |d| item(d, &transfer).is_some_and(|i| i.to_string().contains("accept_offer")));
    let started = Instant::now();
    pair.ben.send("accept_offer", json!({"transfer_id": transfer}));
    during(pair);
    let within = Duration::from_secs(600);
    pair.ben.snapshot_within(&chat, "the file received", within, |d| {
        item(d, &transfer).is_some_and(|i| i["state"] == "received")
    });
    started.elapsed().as_secs_f64()
}

const SLOW_LAN: &str = "lan=1000000,bluetooth=1000000";

#[test]
fn a_slow_network_gets_a_bluetooth_lane_and_the_file_arrives_sooner() {
    let size = 12 << 20;
    let mut alone = pair("lanes-off", SLOW_LAN, false);
    let without = send(&mut alone, "Alone.step", size, |_| {});
    drop(alone);
    let mut with = pair("lanes-on", SLOW_LAN, true);
    let with_lanes = send(&mut with, "Together.step", size, |_| {});
    eprintln!("12 MiB, LAN 1 MB/s with Bluetooth 1 MB/s: {without:.1} s alone, {with_lanes:.1} s with lanes");
    assert!(with_lanes < without * 0.85, "lanes helped: {with_lanes:.1} s against {without:.1} s");
}

#[test]
#[ignore = "a bench: minutes at Bluetooth's rate"]
fn lanes_bench() {
    let rates = "lan=1250000,bluetooth=175000";
    // LANES_BENCH_MIB: another size (Bluetooth's share grows with the file: its blocks take 6 s each, and the last
    // ones stay on the faster lane).
    let mib: usize = std::env::var("LANES_BENCH_MIB").ok().and_then(|v| v.parse().ok()).unwrap_or(32);
    let size = mib << 20;
    let mut alone = pair("bench-off", rates, false);
    let without = send(&mut alone, "Alone.step", size, |_| {});
    drop(alone);
    let mut with = pair("bench-on", rates, true);
    let with_lanes = send(&mut with, "Together.step", size, |_| {});
    let bytes = size as f64;
    let lan = bytes / without / 1e6;
    let both = bytes / with_lanes / 1e6;
    println!(
        "{{\"case\":\"lan-10mbit-plus-bluetooth\",\"bytes\":{size},\"lan_alone_s\":{without:.2},\"with_lanes_s\":{with_lanes:.2},\
\"lan_alone_mb_s\":{lan:.3},\"with_lanes_mb_s\":{both:.3},\
\"bluetooth_share_of_its_rate\":{:.2}}}",
        (both - lan) / 0.175
    );
}
