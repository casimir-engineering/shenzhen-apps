//! Every scenario with a Rust peer on each side, over real TCP on loopback, on every platform the suites run on (the
//! Windows and Ubuntu VMs, the simulators). The same scenarios run against the Objective-C helper in `objc_interop.rs`.

use szfriends_core::identity::Identity;
use szfriends_interop::scenarios::{
    add_by_id, migrate_route, send_after_close, tamper_everywhere, transfer, xx_request,
};
use szfriends_interop::{RustPeer, TempHome};

fn identity(name: &str) -> Identity {
    let seed = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} seed").as_bytes()]);
    let mut private = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} static").as_bytes()]);
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&seed, &private)
}

fn pair(a: &str, b: &str) -> (TempHome, TempHome, RustPeer, RustPeer) {
    let (home_a, home_b) = (TempHome::new(a), TempHome::new(b));
    let peer_a = RustPeer::start(home_a.path().join("state"), identity(a));
    let peer_b = RustPeer::start(home_b.path().join("state"), identity(b));
    (home_a, home_b, peer_a, peer_b)
}

#[test]
fn a_friend_request_over_xx_with_codes() {
    let (_ha, _hb, mut alice, mut bob) = pair("alice", "bob");
    xx_request(&mut alice, &mut bob);
}

#[test]
fn add_by_id_over_nn_answered_by_ik() {
    let (_ha, _hb, mut alice, mut bob) = pair("alice", "bob");
    add_by_id(&mut alice, &mut bob);
}

#[test]
fn a_file_moves_whole_across_rekeys() {
    let (_ha, _hb, mut alice, mut bob) = pair("alice", "bob");
    let moved = transfer(&mut alice, &mut bob, 24 << 20, 4 << 20, None);
    assert!(moved.resumed_at.is_none());
}

#[test]
fn a_file_resumes_after_the_route_is_cut() {
    let (_ha, _hb, mut alice, mut bob) = pair("alice", "bob");
    let moved = transfer(&mut alice, &mut bob, 24 << 20, 4 << 20, Some(13 << 20));
    assert!(moved.resumed_at.is_some_and(|offset| offset > 0));
}

#[test]
fn a_file_moves_to_a_faster_route() {
    let (_ha, _hb, mut alice, mut bob) = pair("alice", "bob");
    migrate_route(&mut alice, &mut bob, 16 << 20);
}

#[test]
fn a_flipped_byte_anywhere_is_refused() {
    let (_ha, _hb, mut alice, mut bob) = pair("alice", "bob");
    let (errors, stalls) = tamper_everywhere(&mut alice, &mut bob, 6);
    assert_eq!(errors + stalls, 16);
}

#[test]
fn a_closed_session_refuses_sends_at_both_ends() {
    let (_ha, _hb, mut alice, mut bob) = pair("alice", "bob");
    send_after_close(&mut alice, &mut bob);
}
