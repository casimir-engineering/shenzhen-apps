//! One person's two devices, both Rust, over real TCP on loopback: join, sync both ways, an erased chat, a removal.
//! The same scenario runs with the Objective-C helper as either device in `objc_interop.rs`.

use szfriends_core::identity::Identity;
use szfriends_interop::device_scenarios::join_sync_remove;
use szfriends_interop::{RustPeer, TempHome};

fn identity(name: &str) -> Identity {
    let seed = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} seed").as_bytes()]);
    let mut private = szfriends_core::crypto::blake2b::<32>(None, &[format!("{name} static").as_bytes()]);
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&seed, &private)
}

#[test]
fn a_second_device_joins_syncs_and_is_removed() {
    let (home_a, home_b) = (TempHome::new("mei-first"), TempHome::new("mei-second"));
    let mut first = RustPeer::start(home_a.path().join("state"), identity("mei-first"));
    let mut second = RustPeer::start(home_b.path().join("state"), identity("mei-second"));
    let carol = identity("carol");
    let keys = (hex::encode(carol.public_key()), hex::encode(carol.static_public_key()));
    join_sync_remove(&mut first, &mut second, (&keys.0, &keys.1));
}
