//! The secure channel's handshakes, Rust against Rust: each pattern, the key policy, quiet refusals, the replay cache,
//! the handshake bound and timeout, admission hooks and the comparison codes (`SZFriendsChannelTests`,
//! `SZFriendsChannelRefusalTests`, `SZFriendsChannelPolicyTests`).

mod support;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use support::*;
use szfriends_core::identity::request_by_id;
use szfriends_core::session::{Event, HandshakeOptions, ListenerHooks, ReplayCache, SecureChannel, SessionError};
use szfriends_core::wire::{Frame, FrameType, Pattern, RouteMethod};

const REFUSAL: Duration = Duration::from_millis(1500);

#[test]
fn xx_request_goes_live_with_identities_profile_and_equal_codes() {
    let mut pipe = xx_pair();
    assert!(Pipe::established(&pipe.initiator_events) && Pipe::established(&pipe.responder_events));
    assert_eq!(pipe.initiator.remote_identity(), Some(&identity("bob").public_key()));
    assert_eq!(pipe.responder.remote_identity(), Some(&identity("alice").public_key()));
    assert_eq!(pipe.responder.initiator_route(), RouteMethod::Lan);
    assert_eq!(pipe.initiator.handshake_hash(), pipe.responder.handshake_hash());
    assert_eq!(pipe.initiator.negotiated_minor(), 4);
    assert!(pipe.initiator.fast_transfers() && pipe.responder.fast_transfers());
    assert!(pipe.send(Side::Initiator, &message("hello", 1)));
    assert_eq!(Pipe::frames(&pipe.responder_events), vec![message("hello", 1)]);
    let now = pipe.now;
    pipe.responder.run_code_exchange(now);
    pipe.initiator.run_code_exchange(now);
    pipe.run();
    let (a, b) = (Pipe::codes(&pipe.initiator_events), Pipe::codes(&pipe.responder_events));
    assert_eq!(a.len(), 1);
    assert_eq!(a, b);
    assert_eq!(a[0].as_ref().map(String::len), Ok(6));
    // Once per session.
    pipe.initiator.run_code_exchange(now);
    pipe.run();
    assert_eq!(Pipe::codes(&pipe.initiator_events).last(), Some(&Err(SessionError::Protocol)));
    pipe.initiator.close(now);
    pipe.run();
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(None));
    assert_eq!(Pipe::closed(&pipe.responder_events), Some(Some(SessionError::PeerClosed(0))));
}

#[test]
fn xx_browse_only_closes_after_the_profile_without_revealing_us() {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = options(Pattern::XX);
    options.browse_only = true;
    let initiator = SecureChannel::initiator(keys(&alice), options);
    let responder = SecureChannel::responder(keys(&bob), Some(profile("Bob")), allow_all());
    let pipe = Pipe::new(initiator, responder);
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(None));
    assert_eq!(Pipe::closed(&pipe.responder_events), Some(Some(SessionError::StreamClosed)));
    assert_eq!(pipe.responder.remote_identity(), None);
}

#[test]
fn a_hidden_listener_refuses_xx_quietly_after_the_delay() {
    let initiator = SecureChannel::initiator(keys(&identity("alice")), options(Pattern::XX));
    let responder = SecureChannel::responder(keys(&identity("bob")), None, allow_all());
    let mut pipe = Pipe::new(initiator, responder);
    assert!(pipe.sent_by_responder.is_empty() && Pipe::closed(&pipe.responder_events).is_none());
    pipe.advance(REFUSAL - Duration::from_millis(1));
    assert!(Pipe::closed(&pipe.responder_events).is_none());
    pipe.advance(Duration::from_millis(1));
    assert_eq!(Pipe::closed(&pipe.responder_events), Some(Some(SessionError::Rejected)));
    assert!(pipe.sent_by_responder.is_empty());
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(Some(SessionError::StreamClosed)));
}

#[test]
fn ik_reaches_a_friend_and_an_unknown_key_is_refused_quietly() {
    let pipe = ik_pair();
    assert!(Pipe::established(&pipe.responder_events));
    assert_eq!(pipe.responder.remote_static(), Some(&identity("alice").static_public_key()));
    let carol = identity("carol");
    let bob = identity("bob");
    let mut options = options(Pattern::IK);
    options.remote_static = Some(bob.static_public_key());
    let initiator = SecureChannel::initiator(keys(&carol), options);
    let alice_key = identity("alice").public_key();
    let responder = SecureChannel::responder(keys(&bob), None, Box::new(move |key, _, _| key == Some(&alice_key)));
    let mut pipe = Pipe::new(initiator, responder);
    assert!(pipe.sent_by_responder.is_empty());
    pipe.advance(REFUSAL);
    assert_eq!(Pipe::closed(&pipe.responder_events), Some(Some(SessionError::Rejected)));
    assert_eq!(pipe.responder.remote_identity(), None);
}

#[test]
fn ik_callback_presents_its_token_and_the_attestation_travels_beside_the_certificate() {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let token = vec![7u8; 16];
    let mut options = options(Pattern::IK);
    options.remote_static = Some(bob.static_public_key());
    options.request_token = Some(token.clone());
    let mut initiator = SecureChannel::initiator(keys(&alice), options);
    initiator.set_local_attestation(Some(vec![0xa5; 512]));
    let seen = Arc::new(Mutex::new(None));
    let record = seen.clone();
    let responder = SecureChannel::responder(
        keys(&bob),
        None,
        Box::new(move |_, pattern, token| {
            *record.lock().unwrap() = Some((pattern, token.map(<[u8]>::to_vec)));
            token == Some(&[7u8; 16][..])
        }),
    );
    let pipe = Pipe::new(initiator, responder);
    assert_eq!(*seen.lock().unwrap(), Some((Pattern::IK, Some(token.clone()))));
    assert!(Pipe::established(&pipe.responder_events));
    assert_eq!(pipe.responder.presented_token(), Some(token.as_slice()));
    assert_eq!(pipe.responder.remote_attestation(), Some(&[0xa5; 512][..]));
    // One byte longer fails the handshake rather than being cut.
    let mut options = support::options(Pattern::IK);
    options.remote_static = Some(bob.static_public_key());
    let mut initiator = SecureChannel::initiator(keys(&alice), options);
    initiator.set_local_attestation(Some(vec![0xa5; 513]));
    let pipe = Pipe::new(initiator, SecureChannel::responder(keys(&bob), None, allow_all()));
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(Some(SessionError::FrameInvalid)));
}

#[test]
fn ik_to_the_wrong_identity_fails_at_the_initiator() {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = options(Pattern::IK);
    options.remote_static = Some(bob.static_public_key());
    options.expected_identity = Some(identity("carol").public_key());
    let initiator = SecureChannel::initiator(keys(&alice), options);
    let pipe = Pipe::new(initiator, SecureChannel::responder(keys(&bob), None, allow_all()));
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(Some(SessionError::HandshakeFailed)));
    // Options that do not fit the pattern never start.
    let mut options = support::options(Pattern::IK);
    options.request_token = Some(vec![1; 15]);
    options.remote_static = Some(bob.static_public_key());
    let mut channel = SecureChannel::initiator(keys(&alice), options);
    channel.start(Duration::ZERO);
    assert_eq!(channel.poll_event(), Some(Event::Closed(Some(SessionError::HandshakeFailed))));
    let xx_without_route = HandshakeOptions::new(Pattern::XX, RouteMethod::None);
    let mut channel = SecureChannel::initiator(keys(&alice), xx_without_route);
    channel.start(Duration::ZERO);
    assert_eq!(channel.poll_event(), Some(Event::Closed(Some(SessionError::HandshakeFailed))));
}

#[test]
fn nn_carries_one_request_by_id_and_one_received_and_nothing_else() {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let initiator = SecureChannel::initiator(keys(&alice), options(Pattern::NN));
    let responder =
        SecureChannel::responder(keys(&bob), None, Box::new(|key, pattern, _| key.is_none() && pattern == Pattern::NN));
    let mut pipe = Pipe::new(initiator, responder);
    assert!(Pipe::established(&pipe.responder_events));
    assert_eq!(pipe.initiator.remote_identity(), None);
    let h = *pipe.initiator.handshake_hash().unwrap();
    let request = request_by_id::make_frame(&alice, "maple-otter", &[1; 16], &[2; 32], &h).unwrap();
    assert!(!pipe.send(Side::Initiator, &message("not here", 1)));
    assert!(!pipe.send(Side::Responder, &request));
    assert!(pipe.send(Side::Initiator, &request));
    let received = Pipe::frames(&pipe.responder_events);
    assert_eq!(
        request_by_id::verify_frame(&received[0], pipe.responder.handshake_hash().unwrap()),
        Some(alice.public_key())
    );
    assert!(pipe.send(Side::Responder, &Frame::new(FrameType::Received)));
    assert_eq!(Pipe::frames(&pipe.initiator_events), vec![Frame::new(FrameType::Received)]);
    let now = pipe.now;
    pipe.initiator.run_code_exchange(now);
    pipe.run();
    assert_eq!(Pipe::codes(&pipe.initiator_events), vec![Err(SessionError::Protocol)]);
    // A second request in one session closes it.
    assert!(pipe.send(Side::Initiator, &request));
    assert_eq!(Pipe::closed(&pipe.responder_events), Some(Some(SessionError::Protocol)));
    assert_eq!(Pipe::closed(&pipe.initiator_events), Some(Some(SessionError::PeerClosed(1))));
}

#[test]
fn a_replayed_message_1_reaches_the_policy_once() {
    let mut pipe = ik_pair();
    let cache = Arc::new(ReplayCache::new(64, None));
    let message1 = pipe.sent_by_initiator.clone();
    let bob = identity("bob");
    let asked = Arc::new(AtomicUsize::new(0));
    let mut replies = Vec::new();
    for _ in 0..2 {
        let count = asked.clone();
        let mut responder = SecureChannel::responder(
            keys(&bob),
            None,
            Box::new(move |_, _, _| {
                count.fetch_add(1, Ordering::SeqCst);
                true
            }),
        );
        responder.set_replay_cache(cache.clone());
        responder.start(pipe.now);
        // The preamble and message 1 only, as captured off the air.
        let length = 6 + usize::from(u16::from_be_bytes([message1[4], message1[5]]));
        responder.receive(&message1[..length], pipe.now);
        responder.handle_timeout(pipe.now + REFUSAL);
        replies.push((responder.poll_transmit().is_some(), std::iter::from_fn(|| responder.poll_event()).last()));
    }
    assert_eq!(asked.load(Ordering::SeqCst), 1);
    assert!(replies[0].0);
    assert_eq!(replies[1], (false, Some(Event::Closed(Some(SessionError::Replayed)))));
    pipe.run();
}

#[test]
fn the_responder_bounds_handshake_messages_and_times_out_silent_peers() {
    let bob = identity("bob");
    let mut responder = SecureChannel::responder(keys(&bob), None, allow_all());
    responder.start(Duration::ZERO);
    responder.receive(&[b'S', b'Z', 1, 1, 0x04, 0x01], Duration::from_secs(1));
    assert!(responder.poll_event().is_none());
    responder.handle_timeout(Duration::from_secs(1) + REFUSAL);
    assert_eq!(responder.poll_event(), Some(Event::Closed(Some(SessionError::FrameInvalid))));
    let mut responder = SecureChannel::responder(keys(&bob), None, allow_all());
    responder.start(Duration::ZERO);
    responder.receive(b"SZ\x01\x01\x00", Duration::from_secs(1));
    responder.handle_timeout(Duration::from_millis(9_999));
    assert!(responder.poll_event().is_none());
    responder.handle_timeout(Duration::from_secs(10));
    assert_eq!(responder.poll_event(), Some(Event::Closed(Some(SessionError::TimedOut))));
    let mut responder = SecureChannel::responder(keys(&bob), None, allow_all());
    responder.start(Duration::ZERO);
    responder.receive(b"SZ\x02\x01", Duration::ZERO);
    assert_eq!(responder.poll_timeout(), Some(REFUSAL));
}

#[derive(Default)]
struct Hooks {
    calls: Arc<Mutex<Vec<&'static str>>>,
    admit: bool,
}

impl ListenerHooks for Hooks {
    fn admit_pattern(&mut self, _pattern: Pattern) -> bool {
        self.calls.lock().unwrap().push("admit");
        self.admit
    }
    fn first_message_received(&mut self) {
        self.calls.lock().unwrap().push("first");
    }
    fn authenticated(&mut self) {
        self.calls.lock().unwrap().push("authenticated");
    }
}

#[test]
fn admission_hooks_hear_the_pattern_message_1_and_authentication() {
    for (pattern, admit) in [(Pattern::NN, true), (Pattern::XX, true), (Pattern::NN, false)] {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let initiator = SecureChannel::initiator(keys(&identity("alice")), options(pattern));
        let mut responder = SecureChannel::responder(keys(&identity("bob")), Some(profile("Bob")), allow_all());
        responder.set_listener_hooks(Box::new(Hooks { calls: calls.clone(), admit }));
        let mut pipe = Pipe::new(initiator, responder);
        pipe.advance(REFUSAL);
        let expected: &[&str] = if admit { &["admit", "first", "authenticated"] } else { &["admit"] };
        assert_eq!(calls.lock().unwrap().as_slice(), expected, "{pattern:?}");
        if !admit {
            assert_eq!(Pipe::closed(&pipe.responder_events), Some(Some(SessionError::Rejected)));
        }
    }
}

#[test]
fn every_tampered_byte_of_a_session_is_refused() {
    let reference = {
        let mut pipe = xx_pair();
        pipe.send(Side::Initiator, &message("first", 1));
        pipe.send(Side::Responder, &message("second", 2));
        pipe
    };
    for side in [Side::Initiator, Side::Responder] {
        let length = match side {
            Side::Initiator => reference.sent_by_initiator.len(),
            Side::Responder => reference.sent_by_responder.len(),
        };
        for index in 0..length {
            let mut pipe = tampered_xx(side, index);
            pipe.send(Side::Initiator, &message("first", 1));
            pipe.send(Side::Responder, &message("second", 2));
            // A length prefix made longer leaves the recipient waiting for bytes that never come: during the
            // handshake its timeout ends it, afterwards the sender's leaving does.
            pipe.advance(Duration::from_secs(10));
            let now = pipe.now;
            match side {
                Side::Initiator => pipe.initiator.close(now),
                Side::Responder => pipe.responder.close(now),
            }
            pipe.run();
            let (events, good) = match side {
                Side::Initiator => (&pipe.responder_events, &reference.responder_events),
                Side::Responder => (&pipe.initiator_events, &reference.initiator_events),
            };
            let closed = Pipe::closed(events);
            assert!(matches!(closed, Some(Some(_))), "{side:?} byte {index}: {closed:?}");
            for frame in Pipe::frames(events) {
                assert!(Pipe::frames(good).contains(&frame), "{side:?} byte {index} delivered a changed frame");
            }
        }
    }
}

fn tampered_xx(side: Side, index: usize) -> Pipe {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut initiator = SecureChannel::initiator(keys(&alice), options(Pattern::XX));
    initiator.set_profile_decision(Box::new(|_| true));
    let responder = SecureChannel::responder(keys(&bob), Some(profile("Bob")), allow_all());
    Pipe::with_tamper(initiator, responder, Some((side, index, 0x01)))
}
