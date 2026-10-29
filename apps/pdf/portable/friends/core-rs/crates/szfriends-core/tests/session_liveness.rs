//! Liveness while a transfer runs (ADR 0018 § 7): PING after a second without sending, a session closed after 8 s
//! (Bluetooth 12 s) without hearing anything, only while watching, and never because this side itself stalled.

mod support;

use std::time::Duration;

use support::*;
use szfriends_core::session::{
    transfer_liveness, ChannelConfig, ChunkReceiver, ChunkSender, Event, HandshakeOptions, SecureChannel, SessionError,
};
use szfriends_core::wire::{tag, Frame, FrameType};
use szfriends_core::wire::{Pattern, RouteMethod};

const STEP: Duration = Duration::from_millis(250);

fn pair(route: RouteMethod) -> Pipe {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = HandshakeOptions::new(Pattern::IK, route);
    options.remote_static = Some(bob.static_public_key());
    let initiator = SecureChannel::initiator(keys(&alice), options);
    let responder = SecureChannel::responder(keys(&bob), None, allow_all());
    let pipe = Pipe::new(initiator, responder);
    assert!(Pipe::established(&pipe.initiator_events) && Pipe::established(&pipe.responder_events));
    pipe
}

/// Time passes for the initiator alone, every `step`, and nothing it sends arrives: the route went quiet.
fn initiator_alone(pipe: &mut Pipe, for_: Duration, step: Duration) -> Option<Duration> {
    let started = pipe.now;
    while pipe.now < started + for_ {
        pipe.now += step;
        pipe.initiator.handle_timeout(pipe.now);
        while pipe.initiator.poll_transmit().is_some() {}
        while let Some(event) = pipe.initiator.poll_event() {
            if event == Event::Closed(Some(SessionError::Silent)) {
                return Some(pipe.now - started);
            }
            assert!(!matches!(event, Event::Closed(_)), "{event:?}");
        }
    }
    None
}

#[test]
fn both_sides_ping_while_a_transfer_waits_and_nobody_closes() {
    let mut pipe = pair(RouteMethod::Lan);
    let now = pipe.now;
    pipe.initiator.set_liveness(true, true, now);
    pipe.responder.set_liveness(true, true, now);
    let before = (pipe.sent_by_initiator.len(), pipe.sent_by_responder.len());
    for _ in 0..120 {
        pipe.advance(STEP);
    }
    // Thirty seconds without a frame from either side: PINGs only, about one a second each way, never an event.
    let pings = |bytes: usize| bytes / (2 + 1 + 16);
    let (initiator, responder) =
        (pings(pipe.sent_by_initiator.len() - before.0), pings(pipe.sent_by_responder.len() - before.1));
    assert!((25..=31).contains(&initiator) && (25..=31).contains(&responder), "{initiator} {responder}");
    assert!(Pipe::frames(&pipe.initiator_events).is_empty() && Pipe::frames(&pipe.responder_events).is_empty());
    assert!(!pipe.initiator.is_closed() && !pipe.responder.is_closed());
}

#[test]
fn a_silent_route_closes_after_eight_seconds_and_bluetooth_after_twelve() {
    for (route, limit) in
        [(RouteMethod::Lan, 8_000), (RouteMethod::PeerToPeerWifi, 8_000), (RouteMethod::Bluetooth, 12_000)]
    {
        let mut pipe = pair(route);
        let now = pipe.now;
        pipe.initiator.set_liveness(true, true, now);
        let closed = initiator_alone(&mut pipe, Duration::from_secs(30), STEP).expect("closed");
        assert!(
            closed >= Duration::from_millis(limit) && closed <= Duration::from_millis(limit) + STEP,
            "{route:?} {closed:?}"
        );
        assert!(pipe.initiator.link_should_close());
    }
}

#[test]
fn the_driver_wakes_the_channel_in_time() {
    let mut pipe = pair(RouteMethod::Lan);
    let now = pipe.now;
    pipe.initiator.set_liveness(true, true, now);
    // Each run at exactly the time the channel asked for.
    let started = pipe.now;
    loop {
        let at = pipe.initiator.poll_timeout().expect("a timer");
        assert!(at > pipe.now && at <= pipe.now + Duration::from_secs(1), "{:?}", at - pipe.now);
        pipe.now = at;
        pipe.initiator.handle_timeout(pipe.now);
        while pipe.initiator.poll_transmit().is_some() {}
        if pipe.initiator.is_closed() {
            break;
        }
    }
    assert_eq!(pipe.now - started, Duration::from_secs(8));
}

#[test]
fn only_a_watching_session_closes_on_silence() {
    let mut pipe = pair(RouteMethod::Lan);
    let now = pipe.now;
    // Pinging but not watching (a sender whose bytes are all confirmed, an offer waiting for an answer).
    pipe.initiator.set_liveness(true, false, now);
    assert_eq!(initiator_alone(&mut pipe, Duration::from_secs(60), STEP), None);
    // Watching starts the count afresh, whatever came before.
    let now = pipe.now;
    pipe.initiator.set_liveness(true, true, now);
    assert_eq!(initiator_alone(&mut pipe, Duration::from_secs(30), STEP), Some(Duration::from_secs(8)));
}

#[test]
fn this_side_stalling_is_not_the_peer_s_silence() {
    let mut pipe = pair(RouteMethod::Lan);
    let now = pipe.now;
    pipe.initiator.set_liveness(true, true, now);
    // Twenty seconds without running (a long disk operation, sleep): the bytes the peer sent may still be unread.
    assert_eq!(initiator_alone(&mut pipe, Duration::from_secs(20), Duration::from_secs(20)), None);
    // Still nothing afterwards: closed eight seconds later.
    assert_eq!(initiator_alone(&mut pipe, Duration::from_secs(30), STEP), Some(Duration::from_secs(8)));
}

#[test]
fn a_released_peer_s_own_traffic_keeps_the_session_open() {
    // The responder stands for a released peer: it never pings, but sends what its transfer requires.
    let mut pipe = pair(RouteMethod::Lan);
    let now = pipe.now;
    pipe.initiator.set_liveness(true, true, now);
    for i in 0..60u8 {
        pipe.advance(Duration::from_millis(500));
        if i % 6 == 0 {
            pipe.send(Side::Responder, &message("progress", i));
        }
    }
    assert!(!pipe.initiator.is_closed());
    // It goes quiet: closed within the limit.
    assert!(initiator_alone(&mut pipe, Duration::from_secs(10), STEP).is_some());
}

#[test]
fn pings_wait_one_at_a_time_on_a_link_that_takes_nothing() {
    let config = ChannelConfig { preferred_write_size: 1024, ..ChannelConfig::default() };
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = HandshakeOptions::new(Pattern::IK, RouteMethod::Lan);
    options.remote_static = Some(bob.static_public_key());
    let mut initiator = SecureChannel::initiator(keys(&alice), options);
    initiator.set_config(config);
    let responder = SecureChannel::responder(keys(&bob), None, allow_all());
    let mut pipe = Pipe::new(initiator, responder);
    let now = pipe.now;
    pipe.initiator.set_liveness(true, false, now);
    // Writes are handed out but never complete: a large message fills the budget, and PINGs do not pile up behind it.
    assert!(pipe.initiator.send_frame(&message(&"x".repeat(30_000), 1), now));
    let mut handed = 0;
    for _ in 0..40 {
        pipe.now += STEP;
        pipe.initiator.handle_timeout(pipe.now);
        while pipe.initiator.poll_transmit().is_some() {
            handed += 1;
        }
    }
    assert_eq!(handed, 1);
    assert!(pipe.initiator.queued_frames().0 <= 1, "{:?}", pipe.initiator.queued_frames());
}

#[test]
fn transfers_watch_only_while_the_peer_owes_something() {
    let id = [7u8; 16];
    let none: [&ChunkSender; 0] = [];
    let mut sender = ChunkSender::new(&id, 10_000, 0, 1_000, 4_000).unwrap();
    let mut receiver = ChunkReceiver::new(&id, 10_000, 0, 1_000, 4_000).unwrap();
    assert_eq!(transfer_liveness(none, []), (false, false));
    // Accepted, nothing sent yet: ping, but nothing is due from the peer.
    assert_eq!(transfer_liveness([&sender], [&receiver]), (true, false));
    let chunk = sender.chunk_frame(&[1; 1_000]).unwrap();
    assert_eq!(transfer_liveness([&sender], []), (true, true), "PROGRESS is due for the bytes sent");
    assert_eq!(
        transfer_liveness(none, [&receiver]),
        (true, false),
        "a released sender may hash before its first chunk"
    );
    receiver.accept_chunk(&chunk).unwrap();
    assert_eq!(transfer_liveness(none, [&receiver]), (true, true), "chunks are arriving");
    let progress = receiver.progress_frame(1_000).unwrap();
    sender.handle_progress(&progress).unwrap();
    assert_eq!(transfer_liveness([&sender], []), (true, false));
    // The whole file arrived: between DONE and ACK a released receiver checks it in silence.
    let mut offset = 1_000u64;
    while offset < 10_000 {
        let frame = Frame::new(FrameType::Chunk).with(tag::ID, id.to_vec()).with(tag::OFFSET, offset.to_be_bytes());
        receiver.accept_chunk(&frame.with(tag::DATA, vec![1; 1_000])).unwrap();
        offset += 1_000;
        receiver.progress_frame(offset).unwrap();
    }
    assert_eq!(transfer_liveness(none, [&receiver]), (true, false));
}
