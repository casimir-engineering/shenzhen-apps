//! A responder channel fed whatever a stranger sends, in arbitrary slices and at arbitrary times: the preamble,
//! handshake messages under the 1,024-byte bound, junk after a refusal. It must never panic, never write before a
//! valid message 1, and always end with exactly one Closed once its timers run out.

#![no_main]

use std::time::Duration;

use libfuzzer_sys::fuzz_target;
use szfriends_core::identity::Identity;
use szfriends_core::session::{ChannelIdentity, Event, SecureChannel};
use szfriends_core::wire::{tag, Fields};

fuzz_target!(|data: &[u8]| {
    let identity = Identity::from_secrets(&[7; 32], &[9; 32]);
    let mut profile = Fields::new();
    profile.insert(tag::NAME, b"Bob".to_vec());
    let public = data.first().is_some_and(|b| b & 1 == 1);
    let mut channel =
        SecureChannel::responder(ChannelIdentity::new(&identity), public.then_some(profile), Box::new(|_, _, _| true));
    let mut now = Duration::from_secs(1);
    channel.start(now);
    for piece in data.get(1..).unwrap_or_default().chunks(37) {
        now += Duration::from_millis(u64::from(piece[0]));
        channel.receive(piece, now);
        channel.handle_timeout(now);
        while let Some(write) = channel.poll_transmit() {
            assert!(write.bytes.len() <= 65_537);
            channel.write_completed(now);
        }
    }
    channel.handle_timeout(now + Duration::from_secs(3600));
    channel.link_closed_by_peer();
    let closes = std::iter::from_fn(|| channel.poll_event()).filter(|e| matches!(e, Event::Closed(_))).count();
    assert_eq!(closes, 1);
});
