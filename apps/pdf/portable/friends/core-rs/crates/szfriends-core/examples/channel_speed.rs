//! How fast one session moves PARTs through this build's channel, in one process: 1 GiB of 60 KiB frames sealed by
//! one channel and opened by another, with ChaChaPoly (every first session) and AES-256-GCM (a lane where both sides
//! have hardware AES), sealing and opening one message at a time or in batches on several cores (ADR 0018 § 9.2).
//! Prints the best of five runs, wall time and the process's CPU time per GB.
//!
//!   cargo run --release -p szfriends-core --example channel_speed

use std::time::{Duration, Instant};

use szfriends_core::session::{ChannelConfig, ChannelIdentity, HandshakeOptions, SecureChannel};
use szfriends_core::transfer::frames;
use szfriends_core::wire::consts::{CAPABILITY_AES_LANES, CAPABILITY_FAST_TRANSFERS};
use szfriends_core::wire::{NoiseCipher, Pattern, RouteMethod};

fn cpu_seconds() -> f64 {
    let t = rustix::time::clock_gettime(rustix::time::ClockId::ProcessCPUTime);
    t.tv_sec as f64 + t.tv_nsec as f64 / 1e9
}

fn run(cipher: NoiseCipher, batches: bool) -> (f64, f64) {
    let identity = |_: u8| szfriends_core::identity::identity::Identity::generate();
    let (alice, bob) = (identity(1), identity(2));
    let config = ChannelConfig {
        capabilities: CAPABILITY_FAST_TRANSFERS | CAPABILITY_AES_LANES,
        crypto_batches: batches,
        ..Default::default()
    };
    let mut options = HandshakeOptions::new(Pattern::IK, RouteMethod::Lan);
    options.remote_static = Some(bob.static_public_key());
    if cipher == NoiseCipher::AesGcm {
        options.lane = Some([9; 16]);
        options.cipher = cipher;
    }
    let mut sender = SecureChannel::initiator(ChannelIdentity::new(&alice), options);
    sender.set_config(config);
    let policy: szfriends_core::session::RemoteKeyPolicy = Box::new(|_, _, _| true);
    let mut receiver = SecureChannel::responder(ChannelIdentity::new(&bob), None, policy);
    receiver.set_config(config);
    let now = Duration::from_secs(1);
    sender.start(now);
    receiver.start(now);
    let shuttle = |from: &mut SecureChannel, to: &mut SecureChannel| {
        let mut moved = false;
        let mut chunk = Vec::new();
        while let Some(write) = from.poll_transmit() {
            chunk.extend_from_slice(&write.bytes);
            from.write_completed(now);
            moved = true;
            // A link delivers what it read: up to 256 KiB at a time.
            if chunk.len() >= 256 * 1024 {
                to.receive(&chunk, now);
                chunk.clear();
            }
        }
        if !chunk.is_empty() {
            to.receive(&chunk, now);
        }
        moved
    };
    while shuttle(&mut sender, &mut receiver) | shuttle(&mut receiver, &mut sender) {}
    assert!(sender.is_established(), "the session came up");
    while receiver.poll_event().is_some() {}
    let data = vec![0x5au8; 61_440];
    let total: u64 = 1 << 30;
    let (started, cpu) = (Instant::now(), cpu_seconds());
    let mut sent = 0u64;
    let mut received = 0u64;
    while received < total {
        while sent < total && sender.queued_frames().1 < 8 {
            sender.send_frame(&frames::part(&[1; 16], sent, &data), now);
            sent += data.len() as u64;
        }
        shuttle(&mut sender, &mut receiver);
        while let Some(event) = receiver.poll_event() {
            if let szfriends_core::session::Event::Frame(_) = event {
                received += data.len() as u64;
            }
        }
    }
    (started.elapsed().as_secs_f64(), cpu_seconds() - cpu)
}

fn main() {
    for cipher in [NoiseCipher::ChaChaPoly, NoiseCipher::AesGcm] {
        for batches in [false, true] {
            let runs: Vec<(f64, f64)> = (0..5).map(|_| run(cipher, batches)).collect();
            let best = runs.iter().map(|r| r.0).fold(f64::MAX, f64::min);
            let cpu = runs.iter().map(|r| r.1).fold(f64::MAX, f64::min);
            println!(
                "{cipher:?}, {}: {:.0} MB/s, {:.2} CPU-s/GB (send and receive)",
                if batches { "batches" } else { "one at a time" },
                (1u64 << 30) as f64 / best / 1e6,
                cpu / ((1u64 << 30) as f64 / 1e9),
            );
        }
    }
}
