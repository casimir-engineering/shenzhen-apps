//! How fast this build encrypts and decrypts session traffic: one core, 60 KiB frames (a CHUNK or PART's size) through
//! the same Noise transport the sessions use. ADR 0018 § 9.2: the release profiles build the ciphers at opt-level 3
//! with their SIMD backends (NEON on arm64), about four times the speed of a size-optimised build.
//!
//!   cargo run --release -p szfriends-crypto --example transport-speed
//!   cargo run --profile phone -p szfriends-crypto --example transport-speed --config phone.toml

use std::time::Instant;

use szfriends_crypto::noise::{x25519_public, Handshake, HandshakeKeys};
use szfriends_wire::Pattern;
use zeroize::Zeroizing;

fn main() {
    let (a, b) = ([0x11u8; 32], [0x22u8; 32]);
    let keys = |local: [u8; 32], remote: Option<[u8; 32]>| HandshakeKeys {
        local_static: Some(Zeroizing::new(local)),
        remote_static: remote,
        fixed_ephemeral: None,
    };
    let mut initiator = Handshake::new(Pattern::IK, true, b"speed", &keys(a, Some(x25519_public(&b)))).unwrap();
    let mut responder = Handshake::new(Pattern::IK, false, b"speed", &keys(b, None)).unwrap();
    responder.read(&initiator.write(&[]).unwrap()).unwrap();
    initiator.read(&responder.write(&[]).unwrap()).unwrap();
    let (mut sender, mut receiver) = (initiator.into_transport().unwrap(), responder.into_transport().unwrap());
    let frame = vec![0x5au8; 61_440];
    let total = 1usize << 30;
    let messages: Vec<Vec<u8>> = {
        let started = Instant::now();
        let out: Vec<_> = (0..total / frame.len()).map(|_| sender.encrypt(&frame).unwrap()).collect();
        println!("encrypt: {:.0} MB/s", total as f64 / started.elapsed().as_secs_f64() / 1e6);
        out
    };
    let started = Instant::now();
    for message in &messages {
        std::hint::black_box(receiver.decrypt(message).unwrap());
    }
    println!("decrypt: {:.0} MB/s", total as f64 / started.elapsed().as_secs_f64() / 1e6);
}
