//! The real helper binary on Linux and Windows: one helper per person by lock, the protocol over the socket or
//! pipe, exit when nobody comes or the last client leaves, connect-or-spawn from the versioned per-user copy with
//! older copies pruned, and an install over a running helper followed by `--handover` (ADR 0015 § 14).

#![cfg(any(target_os = "linux", windows))]

mod desktop;

use std::time::Duration;

use desktop::{eventually, hello, helper_binary, lock_is_free, process_image, start, wait_connect, wait_exit, Scratch};
use serde_json::json;
use szfriends_helper::client::{connect, connect_or_spawn, hand_over, ConnectError, Handover};
use szfriends_helper::copy::EmbeddedHelper;
use szfriends_helper::stamp::{self, restamp};

const SECONDS: fn(u64) -> Duration = Duration::from_secs;

#[test]
fn one_helper_per_person_serving_the_protocol() {
    let scratch = Scratch::new("one");
    let state = scratch.state();
    let mut first = start(&helper_binary(), &state, &[]);
    let mut client = wait_connect(&state, SECONDS(10));
    let welcome = hello(&mut client, None);
    assert_eq!(welcome["helper"]["pid"], first.id(), "the first helper answers");
    assert_eq!(welcome["helper"]["build_number"], stamp::own().build);

    let mut second = start(&helper_binary(), &state, &[]);
    let status = wait_exit(&mut second, SECONDS(10)).expect("the second helper leaves");
    assert!(status.success(), "a helper that finds the lock taken exits quietly: {status:?}");

    client.send(&json!({"type": "subscribe", "id": "2", "view": "badge"})).unwrap();
    assert_eq!(client.next_frame().unwrap().unwrap()["data"]["accessibility_label"], "Friends");
    assert_eq!(client.next_frame().unwrap().unwrap()["ok"], true);
    assert!(wait_exit(&mut first, Duration::from_millis(700)).is_none(), "stays while a client is connected");
    client.close();
    let status = wait_exit(&mut first, SECONDS(10))
        .unwrap_or_else(|| panic!("leaves after the last client; log:\n{}", desktop::log_of(&state)));
    assert!(status.success());
    assert!(matches!(connect(&state), Err(ConnectError::NoHelper)), "and nothing answers any more");
}

#[test]
fn a_helper_nobody_connects_to_leaves() {
    let scratch = Scratch::new("nobody");
    let state = scratch.state();
    let mut helper = start(&helper_binary(), &state, &[]);
    assert!(wait_exit(&mut helper, Duration::from_millis(1000)).is_none(), "waits for its first client");
    assert!(wait_exit(&mut helper, SECONDS(10)).expect("then leaves").success());
    assert!(lock_is_free(&state));
}

#[test]
fn connect_or_spawn_runs_the_versioned_copy_and_prunes_older_ones() {
    let scratch = Scratch::new("copy");
    let state = scratch.state();
    desktop::init();
    let embedded = EmbeddedHelper::inspect(&helper_binary()).expect("the built helper carries a stamp");
    let copies = state.path.join("helper");
    std::fs::create_dir_all(copies.join("0.0.1-1-0000000000000000")).unwrap();
    std::fs::create_dir_all(copies.join("999.0.0-1-ffffffffffffffff")).unwrap();

    let mut client = connect_or_spawn(&state, &embedded, SECONDS(15)).expect("spawned and connected");
    let welcome = hello(&mut client, Some(&embedded.stamp));
    let pid = scratch.helper(welcome["helper"]["pid"].as_u64().unwrap() as u32);
    let copy_dir = embedded.copy_dir(&state).unwrap();
    let image = process_image(pid).expect("the helper's executable");
    assert_eq!(std::fs::canonicalize(image.parent().unwrap()).unwrap(), std::fs::canonicalize(&copy_dir).unwrap());
    assert!(eventually(SECONDS(5), || !copies.join("0.0.1-1-0000000000000000").exists()), "older copy pruned");
    assert!(copies.join("999.0.0-1-ffffffffffffffff").exists(), "a newer copy is never touched");

    let mut again = connect_or_spawn(&state, &embedded, SECONDS(5)).expect("the running helper");
    assert_eq!(hello(&mut again, Some(&embedded.stamp))["helper"]["pid"], pid, "reused, not spawned again");
    client.close();
    again.close();
    assert!(eventually(SECONDS(10), || lock_is_free(&state)), "it leaves after its last client");
}

#[test]
fn an_update_installs_over_a_running_helper_which_hands_over() {
    let scratch = Scratch::new("update");
    let state = scratch.state();
    desktop::init();
    let name = helper_binary().file_name().unwrap().to_owned();
    // The installed app: its own copy of the helper, as an installer lays it down.
    let app = scratch.0.join("app");
    std::fs::create_dir_all(&app).unwrap();
    let installed = app.join(&name);
    std::fs::copy(helper_binary(), &installed).unwrap();
    let old = EmbeddedHelper::inspect(&installed).unwrap();
    let mut client = connect_or_spawn(&state, &old, SECONDS(15)).expect("the old helper runs");
    let old_pid = scratch.helper(hello(&mut client, Some(&old.stamp))["helper"]["pid"].as_u64().unwrap() as u32);
    let running_copy = old.copy_dir(&state).unwrap().join(&name);

    // The update replaces the app's files while the helper runs: it runs from its own copy, so nothing is in use.
    let mut newer = std::fs::read(helper_binary()).unwrap();
    assert_eq!(restamp(&mut newer, old.stamp.build + 1), 1);
    std::fs::write(&installed, &newer).expect("the installer replaces the app's helper");
    #[cfg(windows)]
    {
        let error = std::fs::write(&running_copy, b"x").expect_err("a running executable cannot be replaced");
        assert_eq!(error.raw_os_error(), Some(32), "ERROR_SHARING_VIOLATION: why the helper never runs from the app");
    }
    #[cfg(target_os = "linux")]
    assert!(running_copy.exists());

    // The installer runs the new helper with --handover: the old one says goodbye to every client and leaves.
    let mut handover = start(&installed, &state, &["--handover"]);
    let goodbye = client.next_frame().unwrap().expect("a goodbye");
    assert_eq!(goodbye["reason"], "handover");
    assert_eq!(goodbye["successor"]["build_number"], old.stamp.build + 1);
    assert!(wait_exit(&mut handover, SECONDS(20)).expect("--handover returns").success());
    assert!(eventually(SECONDS(10), || process_image(old_pid).is_none()), "the old helper is gone");

    // The app (or its next start) connects again with the new embedded helper: a new copy, the old one pruned.
    let new = EmbeddedHelper::inspect(&installed).unwrap();
    assert_eq!(new.stamp.build, old.stamp.build + 1);
    let mut client = connect_or_spawn(&state, &new, SECONDS(15)).expect("the new helper runs");
    let welcome = hello(&mut client, Some(&new.stamp));
    assert_eq!(welcome["helper"]["build_number"], new.stamp.build);
    scratch.helper(welcome["helper"]["pid"].as_u64().unwrap() as u32);
    assert!(eventually(SECONDS(5), || !old.copy_dir(&state).unwrap().exists()), "the older copy is removed");
    assert_eq!(hand_over(&state, &old.stamp).unwrap(), Handover::NotNeeded, "an older build asks for nothing");
    client.close();
    assert!(eventually(SECONDS(10), || lock_is_free(&state)));
    assert_eq!(hand_over(&state, &new.stamp).unwrap(), Handover::NoHelper);
}
