//! ADR 0018 § 9.6 between whole Rust helpers on the loopback test network: one person's second computer copies a
//! file a friend sent from every device that holds it at once (the first computer by SYNC, the friend by AGAIN), with
//! both holders, with the first computer holding a changed copy (it is left out, the friend serves it all), and with
//! the first computer stopping half-way (the friend serves the rest). Each case prints its time as a JSON line for
//! the fast-transfers journal; `SZF_PULL_MIB` sets the size (default 64).

use std::sync::Mutex;
use std::time::Instant;

use serde_json::json;
use szfriends_interop::again::{conversation_titled, item_when};
use szfriends_interop::helpers::{rust_helper_with, Client};
use szfriends_interop::{nearby, nearby_devices, TempHome};

static START: Mutex<()> = Mutex::new(());

fn start(name: &str, home: &TempHome, net: &TempHome) -> Client {
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var("SZFRIENDS_STATE_DIR", home.path());
    std::env::set_var("SZFRIENDS_TEST_LOOPBACK", net.path());
    std::env::remove_var("SZFRIENDS_TEST_SERVICE_TYPE");
    rust_helper_with(name, &home.path().join("state"), &[("SZFRIENDS_TEST_COPIES_BY_BLOCKS", "1")])
}

fn path_when(client: &mut Client, conversation: &str, transfer: &str, what: &str) -> String {
    let found = item_when(client, conversation, transfer, what, |i| {
        i["file"]["path"].as_str().is_some_and(|p| std::path::Path::new(p).is_file())
    });
    found["file"]["path"].as_str().expect("checked").to_owned()
}

/// Deletes the second computer's copy, asks for it with Get, and returns the seconds until it is back (checked whole).
/// `during` runs once a quarter of the file arrived.
fn get_back(
    second: &mut Client,
    conversation: &str,
    transfer: &str,
    original: &[u8],
    during: Option<&mut dyn FnMut()>,
) -> f64 {
    let path = path_when(second, conversation, transfer, "the copy here");
    std::fs::remove_file(&path).expect("deleted on the second computer");
    item_when(second, conversation, transfer, "Get offered", |i| {
        i["actions"].as_array().is_some_and(|a| a.iter().any(|a| a["action"] == "fetch_from_device"))
    });
    let started = Instant::now();
    second.send("fetch_from_device", json!({"transfer_id": transfer}));
    if let Some(during) = during {
        let chat = second.open(conversation);
        second.snapshot(&chat, "a quarter of the copy", |d| {
            d["items"].as_array().is_some_and(|items| {
                items.iter().any(|i| {
                    i["transfer_id"] == transfer
                        && i.to_string().contains("fraction")
                        && i.pointer("/progress/fraction").and_then(|f| f.as_f64()).is_some_and(|f| f > 0.25)
                })
            })
        });
        during();
    }
    let back = path_when(second, conversation, transfer, "the copy back");
    let seconds = started.elapsed().as_secs_f64();
    assert!(std::fs::read(&back).expect("readable") == original, "the same bytes");
    seconds
}

#[test]
fn a_copy_pulls_from_every_holder_and_survives_a_stale_or_vanishing_one() {
    let mib: usize = std::env::var("SZF_PULL_MIB").ok().and_then(|v| v.parse().ok()).unwrap_or(64);
    let (h1, h2, hf, net) =
        (TempHome::new("pull-a1"), TempHome::new("pull-a2"), TempHome::new("pull-f"), TempHome::new("pull-net"));
    let mut first = start("Ada", &h1, &net);
    let mut second = start("Ada's laptop", &h2, &net);
    let mut friend = start("Fay", &hf, &net);
    nearby::start(&mut first, "Ada", &mut friend, "Fay");
    second.send("activate", json!({}));
    nearby_devices::join(&mut first, &mut second);
    nearby::visible_request(&mut friend, "Fay", &mut first, "Ada");
    let (fay_in_first, ada_in_fay) = (conversation_titled(&mut first, "Fay"), conversation_titled(&mut friend, "Ada"));
    let fay_in_second = conversation_titled(&mut second, "Fay");
    // The second computer talks with the friend too, so a live session can carry Get again.
    // (Once the friendship has synced to it: until then it answers not_friends.)
    let message = json!({"conversation_id": fay_in_second, "text": "Hi from the laptop",
                         "client_token": "11112222333344445555666677778888"});
    let deadline = Instant::now() + std::time::Duration::from_secs(20);
    while second.intent("send_message", message.clone())["ok"] != true {
        assert!(Instant::now() < deadline, "the friendship never reached the second computer");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }

    let source = friend.make_file("Scan.step", mib << 20);
    let original = std::fs::read(&source).unwrap();
    let files = json!({"conversation_id": ada_in_fay, "files": [{"path": source}], "client_token": "aaaa0000bbbb1111cccc2222dddd3333"});
    let transfer = friend.send("send_files", files)["transfer_ids"][0].as_str().unwrap().to_owned();
    item_when(&mut first, &fay_in_first, &transfer, "the offer", |i| i.to_string().contains("accept_offer"));
    first.send("accept_offer", json!({"transfer_id": transfer}));
    let on_first = path_when(&mut first, &fay_in_first, &transfer, "received on the first computer");
    // Larger than what copies by itself: the second computer shows it with Get.
    item_when(&mut second, &fay_in_second, &transfer, "on the first computer", |i| {
        i["actions"].as_array().is_some_and(|a| a.iter().any(|a| a["action"] == "fetch_from_device"))
    });
    // A first Get, so the second computer holds a copy the cases below delete.
    second.send("fetch_from_device", json!({"transfer_id": transfer}));
    path_when(&mut second, &fay_in_second, &transfer, "the first copy");

    let both = get_back(&mut second, &fay_in_second, &transfer, &original, None);
    println!("{}", json!({"bench": "pull", "case": "two holders", "mib": mib, "seconds": both}));

    // The first computer's copy changed (same size): it answers NONE, and the friend serves it all.
    let mut stale = original.clone();
    stale[12_345] ^= 0xff;
    std::fs::write(&on_first, &stale).unwrap();
    let with_stale = get_back(&mut second, &fay_in_second, &transfer, &original, None);
    println!("{}", json!({"bench": "pull", "case": "a stale holder", "mib": mib, "seconds": with_stale}));
    std::fs::write(&on_first, &original).unwrap();

    // The first computer stops a quarter of the way in: its blocks go to the friend.
    let mut first = Some(first);
    let mut stop = || drop(first.take());
    let dropped = get_back(&mut second, &fay_in_second, &transfer, &original, Some(&mut stop));
    println!("{}", json!({"bench": "pull", "case": "a holder gone at 25 %", "mib": mib, "seconds": dropped}));
}
