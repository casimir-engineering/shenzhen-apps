//! Online between the Rust core and the helper's own check-in client and online driver (`tools/objc-session-peer` in
//! its online mode), through the local Node host and a coturn at the host's 5 Mbit/s cap, all on loopback: direct and
//! relayed, each side offering, an ADR 0001 session over the data channel carrying a message each way and a file.
//! Then two Rust cores the same way. And whole helpers, a Rust helper and the Objective-C helper with nothing nearby
//! and only the local host between them: a new computer joins the other's profile through the host and the two
//! computers sync online, each implementation joining the other's; and Add by ID through the host, each asking.
//! Run by `make friends-core-rs-online-check`, which builds the peer and the helper and sets `SZFRIENDS_OBJC_PEER`,
//! `SZFRIENDS_OBJC_HELPER`, `SZFRIENDS_HOST_SERVER_DIR` and `FRIENDS_TEST_COTURN`; without them each test says what
//! is missing and passes.

use szfriends_core::identity::Identity;
use szfriends_interop::host::{self, LocalHost};
use szfriends_interop::online_scenarios::{download_link, online_session, OnlineRun};
use szfriends_interop::{ObjcPeer, Peer, RustPeer, TempHome};

const MIB: u64 = 1 << 20;

fn identity(name: &str) -> Identity {
    let seed = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} seed").as_bytes()]);
    let mut private = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} static").as_bytes()]);
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&seed, &private)
}

struct World {
    _dir: TempHome,
    host: LocalHost,
    homes: Vec<TempHome>,
}

fn world(relay: bool) -> Option<World> {
    let Some(server) = host::server_dir() else {
        eprintln!("SZFRIENDS_HOST_SERVER_DIR is not set: make friends-core-rs-online-check sets it");
        return None;
    };
    if let Some(why) = host::unavailable(&server, relay) {
        eprintln!("skipped: {why}");
        return None;
    }
    let dir = TempHome::new("online-host");
    let host = LocalHost::start(&server, dir.path(), relay);
    Some(World { _dir: dir, host, homes: Vec::new() })
}

impl World {
    fn rust(&mut self, name: &str) -> RustPeer {
        let home = TempHome::new(name);
        let peer = RustPeer::start(home.path().join("state"), identity(name));
        self.homes.push(home);
        peer
    }

    fn objc(&mut self, name: &str) -> Option<ObjcPeer> {
        let Some(binary) = ObjcPeer::binary() else {
            eprintln!("SZFRIENDS_OBJC_PEER is not set: make friends-core-rs-online-check builds the helper's peer");
            return None;
        };
        let home = TempHome::new(name);
        let peer = ObjcPeer::start(&binary, &home.path().join("state"), name);
        self.homes.push(home);
        Some(peer)
    }
}

fn report(what: &str, run: &OnlineRun) {
    println!(
        "{what}: {} in {:.2} s, the file at {:.2} Mbit/s",
        run.route,
        run.seconds_to_session,
        run.bits_per_second / 1e6
    );
}

/// Relayed through coturn at max-bps=625000: the cap holds. coturn lets a short burst through first, so a file of a
/// few megabytes averages a little above 5 Mbit/s of payload, and far below what the same path carries direct.
fn check_cap(run: &OnlineRun) {
    assert!(run.bits_per_second < 6.5e6, "the relay holds its 5 Mbit/s cap: {:.2} Mbit/s", run.bits_per_second / 1e6);
}

fn objc_pair(relay: bool, rust_offers: bool) {
    let Some(mut w) = world(relay) else { return };
    let mut rust = w.rust("alice");
    let Some(mut objc) = w.objc("bob") else { return };
    let size = if relay { 6 * MIB } else { 16 * MIB };
    let run = if rust_offers {
        online_session(&mut rust as &mut dyn Peer, &mut objc, &w.host, relay, size)
    } else {
        online_session(&mut objc as &mut dyn Peer, &mut rust, &w.host, relay, size)
    };
    report(if rust_offers { "Rust to the helper" } else { "the helper to Rust" }, &run);
    if relay {
        check_cap(&run);
    }
}

#[test]
fn rust_reaches_objc_directly() {
    objc_pair(false, true);
}

#[test]
fn objc_reaches_rust_directly() {
    objc_pair(false, false);
}

#[test]
fn rust_reaches_objc_through_the_relay() {
    objc_pair(true, true);
}

#[test]
fn objc_reaches_rust_through_the_relay() {
    objc_pair(true, false);
}

#[test]
fn two_rust_cores_directly_and_relayed() {
    for relay in [false, true] {
        let Some(mut w) = world(relay) else { return };
        let (mut a, mut b) = (w.rust("carol"), w.rust("dave"));
        let size = if relay { 6 * MIB } else { 8 * MIB };
        let run = online_session(&mut a as &mut dyn Peer, &mut b, &w.host, relay, size);
        report("Rust to Rust", &run);
        if relay {
            check_cap(&run);
        }
    }
}

fn link_pair(relay: bool) {
    let Some(mut w) = world(relay) else { return };
    let mut rust = w.rust("erin");
    let Some(mut objc) = w.objc("frank") else { return };
    let seconds = download_link(&mut rust as &mut dyn Peer, &mut objc, &w.host, relay, 5 * MIB + 12345);
    println!(
        "a download link from Rust to the helper's opener: {seconds:.2} s{}",
        if relay { ", relayed" } else { "" }
    );
}

#[test]
fn the_helpers_opener_downloads_a_rust_link_directly() {
    link_pair(false);
}

#[test]
fn the_helpers_opener_downloads_a_rust_link_through_the_relay() {
    link_pair(true);
}

/// A Rust helper's service in this process and the Objective-C helper, each in a test home that checks in with the
/// local host and finds nobody nearby (the Rust one has no nearby adapter, the Objective-C one a test Bonjour type
/// nobody else uses).
#[cfg(target_os = "macos")]
mod helpers_online {
    use szfriends_interop::helpers::{objc_helper_with, rust_helper, Client};
    use szfriends_interop::host::LocalHost;
    use szfriends_interop::TempHome;

    pub struct Pair {
        pub rust: Client,
        pub objc: Client,
        _homes: [TempHome; 2],
    }

    pub fn pair(host: &LocalHost, rust_name: &str, objc_name: &str) -> Option<Pair> {
        let Some(binary) = std::env::var_os("SZFRIENDS_OBJC_HELPER").map(std::path::PathBuf::from) else {
            eprintln!("SZFRIENDS_OBJC_HELPER is not set: make friends-core-rs-online-check builds the helper");
            return None;
        };
        let homes = [TempHome::new(rust_name), TempHome::new(objc_name)];
        let (list, keys) = (host.list_path.to_string_lossy(), host.keys_path.to_string_lossy());
        for (key, value) in [
            ("SZFRIENDS_STATE_DIR", homes[0].path().as_os_str()),
            ("SZFRIENDS_TEST_HOST_LIST", host.list_path.as_os_str()),
            ("SZFRIENDS_TEST_HOST_KEYS", host.keys_path.as_os_str()),
        ] {
            std::env::set_var(key, value);
        }
        for key in ["SZFRIENDS_TEST_LOOPBACK", "SZFRIENDS_TEST_SERVICE_TYPE"] {
            std::env::remove_var(key);
        }
        let rust = rust_helper(rust_name, &homes[0].path().join("state"));
        // The Objective-C helper reconsiders whom to reach only with a nearby adapter: Bonjour on loopback under a
        // service type of its own, where it finds nobody.
        let service_type = szfriends_interop::helpers::test_service_type();
        let env = [
            ("SZFRIENDS_TEST_HOST_LIST", list.as_ref()),
            ("SZFRIENDS_TEST_HOST_KEYS", keys.as_ref()),
            ("SZFRIENDS_TEST_SERVICE_TYPE", service_type.as_str()),
        ];
        let objc = objc_helper_with(objc_name, &binary, &homes[1].path().join("state"), &env);
        Some(Pair { rust, objc, _homes: homes })
    }

    /// A friend on another Objective-C helper, online only (its own Bonjour test type, where it finds nobody).
    pub fn objc_friend(host: &LocalHost, name: &str) -> Option<(Client, TempHome)> {
        let binary = std::path::PathBuf::from(std::env::var_os("SZFRIENDS_OBJC_HELPER")?);
        let home = TempHome::new(name);
        let (list, keys) = (host.list_path.to_string_lossy(), host.keys_path.to_string_lossy());
        let service_type = szfriends_interop::helpers::test_service_type();
        let env = [
            ("SZFRIENDS_TEST_HOST_LIST", list.as_ref()),
            ("SZFRIENDS_TEST_HOST_KEYS", keys.as_ref()),
            ("SZFRIENDS_TEST_SERVICE_TYPE", service_type.as_str()),
        ];
        let client = objc_helper_with(name, &binary, &home.path().join("state"), &env);
        Some((client, home))
    }
}

/// The Rust helper reads its test home from the process's environment: one pair at a time.
#[cfg(target_os = "macos")]
static HELPERS: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(target_os = "macos")]
fn helpers(scenario: impl FnOnce(&mut helpers_online::Pair)) {
    let _one = HELPERS.lock().unwrap_or_else(|e| e.into_inner());
    let Some(w) = world(true) else { return };
    let Some(mut pair) = helpers_online::pair(&w.host, "Rosa", "Otto") else { return };
    scenario(&mut pair);
}

/// The first computer befriends Fay through the host, then the other helper joins it online, and the friend, the
/// chat and You move and sync each way (`profile_moves.rs`).
#[cfg(target_os = "macos")]
fn profile_moves(objc_holds: bool) {
    let _one = HELPERS.lock().unwrap_or_else(|e| e.into_inner());
    let Some(w) = world(true) else { return };
    let Some(mut pair) = helpers_online::pair(&w.host, "Rosa", "Otto") else { return };
    let Some((mut fay, _home)) = helpers_online::objc_friend(&w.host, "Fay") else { return };
    let helpers_online::Pair { rust, objc, .. } = &mut pair;
    let (holder, holder_name, joiner) = if objc_holds { (objc, "Otto", rust) } else { (rust, "Rosa", objc) };
    szfriends_interop::online_devices::add_by_id(&mut fay, "Fay", holder, holder_name);
    joiner.send("activate", serde_json::json!({}));
    szfriends_interop::online_devices::reserved_id(joiner);
    let wait = std::time::Duration::from_secs(120);
    szfriends_interop::profile_moves::friends_chats_and_you_move(holder, holder_name, joiner, &mut fay, "Fay", wait);
}

#[test]
fn rust_joins_an_objc_profile_online_and_gets_its_friend_chat_and_you() {
    #[cfg(target_os = "macos")]
    profile_moves(true);
}

#[test]
fn objc_helper_joins_a_rust_profile_online_and_gets_its_friend_chat_and_you() {
    #[cfg(target_os = "macos")]
    profile_moves(false);
}

#[test]
fn rust_joins_an_objc_profile_through_the_host_and_both_sync_online() {
    #[cfg(target_os = "macos")]
    helpers(|p| szfriends_interop::online_devices::join_and_sync(&mut p.objc, "Otto", &mut p.rust));
}

#[test]
fn objc_helper_joins_a_rust_profile_through_the_host_and_both_sync_online() {
    #[cfg(target_os = "macos")]
    helpers(|p| szfriends_interop::online_devices::join_and_sync(&mut p.rust, "Rosa", &mut p.objc));
}

#[test]
fn rust_adds_the_objc_helper_by_id_through_the_host() {
    #[cfg(target_os = "macos")]
    helpers(|p| szfriends_interop::online_devices::add_by_id(&mut p.rust, "Rosa", &mut p.objc, "Otto"));
}

#[test]
fn objc_helper_adds_the_rust_helper_by_id_through_the_host() {
    #[cfg(target_os = "macos")]
    helpers(|p| szfriends_interop::online_devices::add_by_id(&mut p.objc, "Otto", &mut p.rust, "Rosa"));
}
