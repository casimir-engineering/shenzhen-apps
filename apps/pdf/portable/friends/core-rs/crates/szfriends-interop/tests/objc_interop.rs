//! The Rust core against the helper's own code (`tools/objc-session-peer`: the secure channel, chunk flow, identity,
//! store, transfers and Network.framework stream of `service/`), on loopback, each scenario in both directions:
//! a friend request over XX with codes, Add by ID over NN answered by IK, 200 MiB moved with its digest checked,
//! resumed after the route is cut and across rekeys, and a byte flipped anywhere in a session. Run by
//! `make friends-core-rs-interop-check`, which builds the peer and sets `SZFRIENDS_OBJC_PEER`; without it (any platform
//! but a Mac with the helper built) each test says so and passes.

use std::path::PathBuf;

use szfriends_core::identity::Identity;
use szfriends_interop::scenarios::{
    add_by_id, migrate_route, send_after_close, tamper_everywhere, transfer, xx_request,
};
use szfriends_interop::{ObjcPeer, Peer, RustPeer, TempHome};

const MIB: u64 = 1 << 20;

fn identity(name: &str) -> Identity {
    let seed = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} seed").as_bytes()]);
    let mut private = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} static").as_bytes()]);
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&seed, &private)
}

struct Pair {
    _homes: (TempHome, TempHome),
    rust: RustPeer,
    objc: ObjcPeer,
}

fn pair(rust_name: &str, objc_name: &str) -> Option<Pair> {
    let Some(binary) = ObjcPeer::binary() else {
        eprintln!("SZFRIENDS_OBJC_PEER is not set: the helper's peer is built by make friends-core-rs-interop-check");
        return None;
    };
    let homes = (TempHome::new(rust_name), TempHome::new(objc_name));
    let rust = RustPeer::start(homes.0.path().join("state"), identity(rust_name));
    let objc_home: PathBuf = homes.1.path().join("state");
    let objc = ObjcPeer::start(&binary, &objc_home, objc_name);
    Some(Pair { _homes: homes, rust, objc })
}

/// Both peers agree on who is who before anything else: the Objective-C peer derives its identity as the vectors do.
fn check_identities(pair: &mut Pair, objc_name: &str) {
    let objc_keys = szfriends_interop::keys(&mut pair.objc as &mut dyn Peer);
    assert_eq!(objc_keys.identity, hex(&identity(objc_name).public_key()));
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn friend_request_rust_to_objc() {
    let Some(mut p) = pair("alice", "bob") else { return };
    check_identities(&mut p, "bob");
    xx_request(&mut p.rust, &mut p.objc);
}

#[test]
fn friend_request_objc_to_rust() {
    let Some(mut p) = pair("bob", "alice") else { return };
    xx_request(&mut p.objc, &mut p.rust);
}

#[test]
fn add_by_id_rust_asks_objc_holds() {
    let Some(mut p) = pair("alice", "bob") else { return };
    add_by_id(&mut p.rust, &mut p.objc);
}

#[test]
fn add_by_id_objc_asks_rust_holds() {
    let Some(mut p) = pair("bob", "alice") else { return };
    add_by_id(&mut p.objc, &mut p.rust);
}

#[test]
fn two_hundred_mib_rust_to_objc() {
    let Some(mut p) = pair("alice", "bob") else { return };
    let moved = transfer(&mut p.rust, &mut p.objc, 200 * MIB, 16 * MIB, None);
    eprintln!("200 MiB Rust to Objective-C: {:.1} s", moved.seconds);
}

#[test]
fn two_hundred_mib_objc_to_rust() {
    let Some(mut p) = pair("alice", "bob") else { return };
    let moved = transfer(&mut p.objc, &mut p.rust, 200 * MIB, 16 * MIB, None);
    eprintln!("200 MiB Objective-C to Rust: {:.1} s", moved.seconds);
}

#[test]
fn resume_after_a_cut_rust_to_objc() {
    let Some(mut p) = pair("alice", "bob") else { return };
    let moved = transfer(&mut p.rust, &mut p.objc, 200 * MIB, 16 * MIB, Some(117 * MIB));
    eprintln!("200 MiB Rust to Objective-C, cut and resumed at {:?}: {:.1} s", moved.resumed_at, moved.seconds);
}

#[test]
fn resume_after_a_cut_objc_to_rust() {
    let Some(mut p) = pair("alice", "bob") else { return };
    let moved = transfer(&mut p.objc, &mut p.rust, 200 * MIB, 16 * MIB, Some(83 * MIB));
    eprintln!("200 MiB Objective-C to Rust, cut and resumed at {:?}: {:.1} s", moved.resumed_at, moved.seconds);
}

#[test]
fn route_migration_rust_to_objc() {
    let Some(mut p) = pair("alice", "bob") else { return };
    let offset = migrate_route(&mut p.rust, &mut p.objc, 64 * MIB);
    eprintln!("64 MiB Rust to Objective-C moved to a faster route at byte {offset}");
}

#[test]
fn route_migration_objc_to_rust() {
    let Some(mut p) = pair("alice", "bob") else { return };
    let offset = migrate_route(&mut p.objc, &mut p.rust, 64 * MIB);
    eprintln!("64 MiB Objective-C to Rust moved to a faster route at byte {offset}");
}

#[test]
fn tampering_rust_dials_objc() {
    let Some(mut p) = pair("alice", "bob") else { return };
    let (errors, stalls) = tamper_everywhere(&mut p.rust, &mut p.objc, 12);
    eprintln!(
        "Rust dialing Objective-C, one byte flipped per session: {errors} refused with an error, {stalls} stalled"
    );
}

#[test]
fn tampering_objc_dials_rust() {
    let Some(mut p) = pair("alice", "bob") else { return };
    let (errors, stalls) = tamper_everywhere(&mut p.objc, &mut p.rust, 12);
    eprintln!(
        "Objective-C dialing Rust, one byte flipped per session: {errors} refused with an error, {stalls} stalled"
    );
}

#[test]
fn closed_session_refuses_sends_rust_dials_objc() {
    let Some(mut p) = pair("alice", "bob") else { return };
    send_after_close(&mut p.rust, &mut p.objc);
}

#[test]
fn closed_session_refuses_sends_objc_dials_rust() {
    let Some(mut p) = pair("alice", "bob") else { return };
    send_after_close(&mut p.objc, &mut p.rust);
}

/// One person's devices across implementations (ADR 0012 to 0014): the first device approves, the second joins with
/// the code, both sync a friend and history each way, an erased chat reaches the other, and the first removes the
/// second. `first_is_objc` picks which side runs the helper's own code.
fn devices(first_is_objc: bool) {
    let (first_name, second_name) = ("mei-first", "mei-second");
    let (objc_name, rust_name) = if first_is_objc { (first_name, second_name) } else { (second_name, first_name) };
    let Some(mut p) = pair(rust_name, objc_name) else { return };
    check_identities(&mut p, objc_name);
    let carol = identity("carol");
    let keys = (hex(&carol.public_key()), hex(&carol.static_public_key()));
    let friend = (keys.0.as_str(), keys.1.as_str());
    if first_is_objc {
        szfriends_interop::device_scenarios::join_sync_remove(&mut p.objc, &mut p.rust, friend);
    } else {
        szfriends_interop::device_scenarios::join_sync_remove(&mut p.rust, &mut p.objc, friend);
    }
}

#[test]
fn devices_objc_approves_rust_joins() {
    devices(true);
}

#[test]
fn devices_rust_approves_objc_joins() {
    devices(false);
}
