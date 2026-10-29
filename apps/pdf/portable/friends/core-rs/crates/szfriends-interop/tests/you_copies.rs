//! The You row on the computer a file is copied from, between whole Rust helpers on the loopback test network, with
//! copies by blocks: "Copying to your other computers · N%" while the other computer copies it, rising, then "On all
//! your computers" once it has it; and when the other computer goes away mid-copy, the row stops saying it copies.
//! (The Mac helper's row stayed at "Copying… 0%" after copies by blocks came, 18e999d8.)

use std::cell::Cell;

use serde_json::{json, Value};
use szfriends_interop::helpers::{rust_helper_with, Client};
use szfriends_interop::{nearby_devices, TempHome};

fn start(name: &str, home: &TempHome, net: &TempHome) -> Client {
    std::env::set_var("SZFRIENDS_STATE_DIR", home.path());
    std::env::set_var("SZFRIENDS_TEST_LOOPBACK", net.path());
    std::env::remove_var("SZFRIENDS_TEST_SERVICE_TYPE");
    rust_helper_with(name, &home.path().join("state"), &[("SZFRIENDS_TEST_COPIES_BY_BLOCKS", "1")])
}

fn item(data: &Value, transfer: &str) -> Option<Value> {
    data["items"].as_array()?.iter().find(|i| i["transfer_id"] == transfer).cloned()
}

/// Sends a You file of `mib` MiB from `first`; returns its transfer.
fn send_to_you(first: &mut Client, mib: usize, token: &str) -> String {
    let source = first.make_file(&format!("Drawing {mib}.step"), mib << 20);
    let files = json!({"conversation_id": "you", "files": [{"path": source}], "client_token": token});
    first.send("send_files", files)["transfer_ids"][0].as_str().expect("a transfer").to_owned()
}

/// Waits on `first`'s You chat until the row is "Copying to your other computers" with more than `above` of the file
/// there; returns how far.
fn copying_past(first: &mut Client, chat: &str, transfer: &str, above: f64) -> f64 {
    let seen = Cell::new(0.0);
    first.snapshot(chat, "the row copying", |d| {
        let Some(i) = item(d, transfer) else { return false };
        let fraction = i.pointer("/progress/fraction").and_then(Value::as_f64).unwrap_or(0.0);
        if i["state"] == "sending" {
            assert!(i["status_label"].as_str().is_some_and(|s| s.starts_with("Copying to your other computers")));
            seen.set(fraction);
        }
        i["state"] == "sending" && fraction > above
    });
    seen.get()
}

#[test]
fn the_you_row_follows_a_copy_by_blocks_and_clears() {
    let (h1, h2, net) = (TempHome::new("you-a1"), TempHome::new("you-a2"), TempHome::new("you-net"));
    let mut first = start("Ida", &h1, &net);
    let mut second = start("Ida's laptop", &h2, &net);
    first.send("activate", json!({}));
    second.send("activate", json!({}));
    nearby_devices::join(&mut first, &mut second);
    let chat = first.open("you");

    // A copy that goes through: the row rises, then says the file is everywhere.
    let transfer = send_to_you(&mut first, 128, "a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0");
    let some = copying_past(&mut first, &chat, &transfer, 0.0);
    first.snapshot(&chat, "the copy done", |d| {
        item(d, &transfer).is_some_and(|i| {
            assert!(i["state"] != "sending" || i.pointer("/progress/fraction").and_then(Value::as_f64) >= Some(some));
            i["state"] == "delivered"
        })
    });

    // The other computer goes away half-way: the row no longer says it copies (it copies when that one is back).
    let transfer = send_to_you(&mut first, 256, "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1");
    copying_past(&mut first, &chat, &transfer, 0.2);
    drop(second);
    let waiting =
        first.snapshot(&chat, "the copy stopped", |d| item(d, &transfer).is_some_and(|i| i["state"] == "queued"));
    let row = item(&waiting, &transfer).expect("checked");
    assert_eq!(row["status_label"], "Copies to your other computers when they connect", "{row}");
}
