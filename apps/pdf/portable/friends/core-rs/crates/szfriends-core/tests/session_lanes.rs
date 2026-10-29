//! A lane's handshake (ADR 0018 § 6): the token travels in IK message 1's encrypted payload and the responder reads it
//! before HELLO; a session without one presents none; a lane token on anything but IK is refused at the start; and the
//! token of a group's lane is the vector's.

mod support;

use support::*;
use szfriends_core::session::lanes::LaneGroup;
use szfriends_core::session::{HandshakeOptions, SecureChannel};
use szfriends_core::transfer::copies::lane_token;
use szfriends_core::wire::{Pattern, RouteMethod};

fn dial(lane: Option<[u8; 16]>, pattern: Pattern) -> Pipe {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = HandshakeOptions::new(pattern, RouteMethod::Lan);
    if pattern == Pattern::IK {
        options.remote_static = Some(bob.static_public_key());
    }
    options.lane = lane;
    let initiator = SecureChannel::initiator(keys(&alice), options);
    let responder = SecureChannel::responder(keys(&bob), Some(profile("Bob")), allow_all());
    Pipe::new(initiator, responder)
}

#[test]
fn the_lane_token_reaches_the_responder_inside_ik_message_1() {
    let first = dial(None, Pattern::IK);
    assert!(Pipe::established(&first.responder_events));
    assert_eq!(first.responder.presented_lane(), None);
    let h = *first.initiator.handshake_hash().unwrap();
    assert_eq!(first.responder.handshake_hash(), Some(&h));
    // Both sides derive the same fifteen tokens from the first session; the initiator's side takes odd indexes.
    let mut ours = LaneGroup::new(1, [0; 32], true, RouteMethod::Lan, |i| lane_token(&h, i));
    let mut theirs = LaneGroup::new(1, [0; 32], false, RouteMethod::Lan, |i| lane_token(&h, i));
    let (index, token) = ours.reserve(2, RouteMethod::Lan).unwrap();
    let lane = dial(Some(token), Pattern::IK);
    assert!(Pipe::established(&lane.responder_events));
    assert_eq!(lane.responder.presented_lane(), Some(&token));
    assert!(!lane.sent_by_initiator.windows(16).any(|w| w == token), "never in the clear");
    assert_eq!(theirs.admit(2, &token, RouteMethod::Lan), Ok(index));
    assert_eq!(theirs.reserve(3, RouteMethod::Lan).map(|r| r.0), Some(2), "the other side opens even ones");
}

#[test]
fn a_lane_token_goes_only_in_ik() {
    let lane = dial(Some([5; 16]), Pattern::XX);
    assert!(!Pipe::established(&lane.initiator_events));
    assert!(lane.sent_by_initiator.is_empty(), "refused before a byte");
}
