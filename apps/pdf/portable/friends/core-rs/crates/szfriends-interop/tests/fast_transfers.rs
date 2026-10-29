//! ADR 0018 between whole Rust helpers on the loopback test network: two new helpers move a file by blocks and resume
//! it from exactly the blocks that arrived after the receiver restarts mid-file; a new helper and one that plays a
//! released helper (`SZFRIENDS_TEST_FAST_TRANSFERS=0`) move files both ways as before, with no tree in sight.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{json, Value};
use szfriends_interop::helpers::{rust_helper_with, Client, Room};
use szfriends_interop::{nearby, routes, TempHome};

/// Helpers read the environment as they start: one start at a time.
static START: Mutex<()> = Mutex::new(());

fn start(name: &str, home: &TempHome, net: &TempHome, fast: bool, room: Option<&Room>) -> Client {
    let _guard = START.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var("SZFRIENDS_STATE_DIR", home.path());
    std::env::set_var("SZFRIENDS_TEST_LOOPBACK", net.path());
    std::env::remove_var("SZFRIENDS_TEST_SERVICE_TYPE");
    let mut env: Vec<(&str, String)> = room.map(Room::env).unwrap_or_default();
    if !fast {
        env.push(("SZFRIENDS_TEST_FAST_TRANSFERS", "0".into()));
    }
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
    rust_helper_with(name, &home.path().join("state"), &env)
}

fn befriend(a: &mut Client, a_name: &str, b: &mut Client, b_name: &str) -> (String, String) {
    nearby::visible_request(a, a_name, b, b_name);
    (routes::conversation_with(a, b_name), routes::conversation_with(b, a_name))
}

fn item<'a>(data: &'a Value, transfer: &str) -> Option<&'a Value> {
    data["items"].as_array()?.iter().find(|i| i["transfer_id"] == transfer)
}

fn fraction(data: &Value, transfer: &str) -> Option<f64> {
    item(data, transfer)?["progress"]["fraction"].as_f64()
}

fn offer(from: &mut Client, conversation: &str, to: &mut Client, chat: &str, name: &str, size: usize) -> String {
    let path = from.make_file(name, size);
    // Each send its own token: the same token is a retry of the same press.
    let mut token = [0u8; 8];
    szfriends_core::crypto::random_bytes(&mut token);
    let token: String = token.iter().map(|b| format!("{b:02x}")).collect();
    let files = json!({"conversation_id": conversation, "files": [{"path": path}], "client_token": token});
    let transfer = from.send("send_files", files)["transfer_ids"][0].as_str().expect("a transfer").to_owned();
    to.snapshot(chat, "the offer", |d| item(d, &transfer).is_some_and(|i| i.to_string().contains("accept_offer")));
    transfer
}

fn received(to: &mut Client, chat: &str, transfer: &str) {
    to.snapshot(chat, "the file received", |d| item(d, transfer).is_some_and(|i| i["state"] == "received"));
}

fn map_of(home: &TempHome, transfer: &str) -> PathBuf {
    home.path().join("state/received/.partial").join(format!("{transfer}.map"))
}

/// The received file whose name is `name`, anywhere under `dir`.
fn found(dir: &Path, name: &str) -> Option<PathBuf> {
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if let Some(hit) = found(&path, name) {
                return Some(hit);
            }
        } else if path.file_name().is_some_and(|n| n == name) && !path.starts_with(dir.join("outgoing-files")) {
            return Some(path);
        }
    }
    None
}

fn pattern(size: usize) -> Vec<u8> {
    (0..size).map(|i| (i % 251) as u8).collect()
}

#[test]
fn new_helpers_move_a_file_by_blocks_and_resume_it_after_a_restart() {
    // Over the test air (the network held), whose small parts make the file take long enough to stop half-way.
    let (ann_home, ben_home, net) = (TempHome::new("fast-ann"), TempHome::new("fast-ben"), TempHome::new("fast-net"));
    let room = Room::new(net.path(), true);
    let mut ann = start("Ann", &ann_home, &net, true, Some(&room));
    let mut ben = start("Ben", &ben_home, &net, true, Some(&room));
    nearby::start(&mut ann, "Ann", &mut ben, "Ben");
    let (ben_in_ann, ann_in_ben) = befriend(&mut ann, "Ann", &mut ben, "Ben");
    let size = 96 << 20;
    let chat = ben.open(&ann_in_ben);
    let transfer = offer(&mut ann, &ben_in_ann, &mut ben, &chat, "Scan.step", size);
    assert!(map_of(&ben_home, &transfer).exists(), "the offer announced its tree");
    ben.send("accept_offer", json!({"transfer_id": transfer}));
    ben.snapshot(&chat, "part of the file", |d| fraction(d, &transfer).is_some_and(|p| p > 0.2 && p < 0.8));
    // Ben's helper stops mid-file and starts again: the transfer carries on from the blocks it kept.
    drop(ben);
    let map = std::fs::read(map_of(&ben_home, &transfer)).expect("the block map survives the restart");
    let mut ben = start("Ben", &ben_home, &net, true, Some(&room));
    let chat = ben.open(&ann_in_ben);
    let resumed = ben.snapshot(&chat, "the transfer listed again", |d| item(d, &transfer).is_some());
    let at_restart = fraction(&resumed, &transfer).unwrap_or(0.0);
    assert!(at_restart > 0.1, "it resumes from what arrived, not from zero: {at_restart}");
    assert!(map.len() > 88, "the map holds the leaves and the durable blocks");
    received(&mut ben, &chat, &transfer);
    let path = found(&ben_home.path().join("state"), "Scan.step")
        .or_else(|| found(ben_home.path(), "Scan.step"))
        .expect("the received file");
    assert!(std::fs::read(path).unwrap() == pattern(size), "the file arrived intact");
    assert!(!map_of(&ben_home, &transfer).exists(), "the map goes once the file is saved");
    let ann_chat = ann.open(&ben_in_ann);
    ann.snapshot(&ann_chat, "the file delivered", |d| item(d, &transfer).is_some_and(|i| i["state"] == "delivered"));
}

#[test]
fn a_new_helper_and_a_released_one_move_files_as_before_both_ways() {
    let (cat_home, dov_home, net) = (TempHome::new("old-cat"), TempHome::new("old-dov"), TempHome::new("old-net"));
    let mut cat = start("Cat", &cat_home, &net, true, None);
    let mut dov = start("Dov", &dov_home, &net, false, None);
    nearby::start(&mut cat, "Cat", &mut dov, "Dov");
    let (dov_in_cat, cat_in_dov) = befriend(&mut cat, "Cat", &mut dov, "Dov");
    let dov_chat = dov.open(&cat_in_dov);
    let to_dov = offer(&mut cat, &dov_in_cat, &mut dov, &dov_chat, "To the old one.bin", 3 << 20);
    assert!(!map_of(&dov_home, &to_dov).exists(), "no tree reaches a helper without fast transfers");
    dov.send("accept_offer", json!({"transfer_id": to_dov}));
    received(&mut dov, &dov_chat, &to_dov);
    let cat_chat = cat.open(&dov_in_cat);
    let to_cat = offer(&mut dov, &cat_in_dov, &mut cat, &cat_chat, "From the old one.bin", 3 << 20);
    assert!(!map_of(&cat_home, &to_cat).exists(), "an offer from it carries no tree either");
    cat.send("accept_offer", json!({"transfer_id": to_cat}));
    received(&mut cat, &cat_chat, &to_cat);
    // The same file again, both ways: filled from the copy each already holds, by the flow each side knows.
    let again = offer(&mut cat, &dov_in_cat, &mut dov, &dov_chat, "To the old one.bin", 3 << 20);
    dov.send("accept_offer", json!({"transfer_id": again}));
    received(&mut dov, &dov_chat, &again);
    let again = offer(&mut dov, &cat_in_dov, &mut cat, &cat_chat, "From the old one.bin", 3 << 20);
    cat.send("accept_offer", json!({"transfer_id": again}));
    received(&mut cat, &cat_chat, &again);
}

#[test]
fn a_file_sent_again_between_new_helpers_is_filled_from_the_copy_already_there() {
    let (eve_home, fay_home, net) =
        (TempHome::new("again-eve"), TempHome::new("again-fay"), TempHome::new("again-net"));
    let mut eve = start("Eve", &eve_home, &net, true, None);
    let mut fay = start("Fay", &fay_home, &net, true, None);
    nearby::start(&mut eve, "Eve", &mut fay, "Fay");
    let (fay_in_eve, eve_in_fay) = befriend(&mut eve, "Eve", &mut fay, "Fay");
    let chat = fay.open(&eve_in_fay);
    for _ in 0..2 {
        let transfer = offer(&mut eve, &fay_in_eve, &mut fay, &chat, "Drawing.step", 20 << 20);
        fay.send("accept_offer", json!({"transfer_id": transfer}));
        received(&mut fay, &chat, &transfer);
    }
}
