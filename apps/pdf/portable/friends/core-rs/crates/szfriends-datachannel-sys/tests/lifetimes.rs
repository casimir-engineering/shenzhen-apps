//! Handles and threads: a channel the remote opens after its receiver was dropped is released, off the stack's own
//! threads, and the remote sees it close; a channel kept after its connection was dropped fails to send but stays
//! safe to use and to drop. Both on 127.0.0.1, on every platform the suites run on.

mod support;

use std::time::{Duration, Instant};

use support::{pump_pair, Peer, TIMEOUT};

#[test]
fn a_channel_opened_after_the_receiver_was_dropped_is_released() {
    let mut offerer = Peer::new("offerer", false);
    let mut answerer = Peer::new("answerer", true);
    offerer.open_channel();
    // The offer and the answer travel; then the answerer stops listening before its side of the channel exists.
    let deadline = Instant::now() + TIMEOUT;
    while answerer.local_sdp.is_none() {
        assert!(Instant::now() < deadline, "no answer");
        for signal in offerer.pump(Duration::from_millis(5)) {
            answerer.apply(signal);
        }
        for signal in answerer.pump(Duration::from_millis(5)) {
            offerer.apply(signal);
        }
    }
    answerer.stop_listening();
    assert!(answerer.channel.is_none(), "the remote channel arrives only once the connection is up");
    // The answerer's stack still opens its side; nobody takes it, so it is released and the offerer sees it close.
    pump_pair(&mut offerer, &mut answerer, |a, _| a.closed).expect("the unclaimed channel closes");
    assert!(offerer.open, "the offerer saw its channel open first");
    assert!(answerer.channel.is_none());
    let channel = offerer.channel.as_ref().expect("the offerer's channel");
    assert!(channel.send(b"anyone?").is_err(), "a closed channel refuses to send");
}

#[test]
fn a_channel_kept_after_its_connection_is_dropped() {
    let mut offerer = Peer::new("offerer", false);
    let mut answerer = Peer::new("answerer", true);
    offerer.open_channel();
    pump_pair(&mut offerer, &mut answerer, |a, b| a.open && b.open).expect("both sides open the channel");
    let channel = offerer.channel.take().expect("the offerer's channel");
    let id = channel.id();
    drop(offerer);
    // The connection closed with it, so its channel did: sending fails, the handle is still ours to ask and drop.
    assert!(channel.send(b"after the connection").is_err());
    assert_eq!(channel.id(), id);
    assert_eq!(channel.buffered_amount(), 0);
    drop(channel);
    let deadline = Instant::now() + TIMEOUT;
    while !answerer.closed {
        assert!(Instant::now() < deadline, "the answerer never saw the channel close");
        answerer.pump(Duration::from_millis(10));
    }
}

#[test]
fn a_connection_dropped_before_its_channel_is_released_last() {
    let mut offerer = Peer::new("offerer", false);
    offerer.open_channel();
    let channel = offerer.channel.take().expect("a channel");
    // Dropped in the order that used to leave the channel's handle without its connection.
    drop(offerer);
    assert!(channel.send(b"nobody").is_err());
    drop(channel);
}
