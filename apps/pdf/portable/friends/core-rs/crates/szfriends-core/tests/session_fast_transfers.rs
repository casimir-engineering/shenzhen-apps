//! ADR 0018 § 1: fast transfers are negotiated in the handshake (minor 4 and capability bit 0 on both sides), and a
//! peer that did not negotiate them never receives one of their frames or fields: OFFER reaches it as ADR 0001 has it.

mod support;

use support::*;
use szfriends_core::session::{ChannelConfig, SecureChannel};
use szfriends_core::wire::{tag, Frame, FrameType, Pattern};

fn pair(initiator_capabilities: u32, responder_capabilities: u32) -> Pipe {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = options(Pattern::IK);
    options.remote_static = Some(bob.static_public_key());
    options.expected_identity = Some(bob.public_key());
    let alice_key = alice.public_key();
    let mut initiator = SecureChannel::initiator(keys(&alice), options);
    initiator.set_config(ChannelConfig { capabilities: initiator_capabilities, ..ChannelConfig::default() });
    let mut responder = SecureChannel::responder(keys(&bob), None, Box::new(move |key, _, _| key == Some(&alice_key)));
    responder.set_config(ChannelConfig { capabilities: responder_capabilities, ..ChannelConfig::default() });
    Pipe::new(initiator, responder)
}

fn offer() -> Frame {
    Frame::new(FrameType::Offer)
        .with(tag::ID, [3; 16])
        .with(tag::NAME, b"a.bin".to_vec())
        .with(tag::SIZE, 5u64.to_be_bytes())
        .with(tag::DIGEST, [4; 32])
        .with(tag::TREE_ROOT, [5; 32])
        .with(tag::BLOCK_SHIFT, [20])
}

#[test]
fn both_sides_with_the_bit_run_fast_transfers() {
    let mut pipe = pair(1, 1);
    assert!(Pipe::established(&pipe.initiator_events));
    assert!(pipe.initiator.fast_transfers() && pipe.responder.fast_transfers());
    assert_eq!(pipe.responder.remote_capabilities(), 1);
    let hashes =
        Frame::new(FrameType::Hashes).with(tag::ID, [3; 16]).with(tag::INDEX, [0; 4]).with(tag::HASHES, [1; 32]);
    assert!(pipe.send(Side::Initiator, &offer()));
    assert!(pipe.send(Side::Initiator, &hashes));
    assert_eq!(Pipe::frames(&pipe.responder_events), vec![offer(), hashes]);
}

#[test]
fn a_peer_without_the_bit_gets_the_flow_of_today() {
    for (a, b) in [(1, 0), (0, 1), (0, 0)] {
        let mut pipe = pair(a, b);
        assert!(Pipe::established(&pipe.initiator_events));
        assert_eq!(pipe.initiator.negotiated_minor(), 4);
        assert!(!pipe.initiator.fast_transfers() && !pipe.responder.fast_transfers());
        let want = Frame::new(FrameType::Want).with(tag::ID, [3; 16]).with(tag::RANGES, [0, 0, 0, 0, 0, 0, 0, 1]);
        assert!(!pipe.send(Side::Initiator, &want), "no WANT to a peer without them");
        assert!(pipe.send(Side::Initiator, &offer()));
        let mut plain = offer();
        plain.fields.remove(&tag::TREE_ROOT);
        plain.fields.remove(&tag::BLOCK_SHIFT);
        assert_eq!(Pipe::frames(&pipe.responder_events), vec![plain], "the tree's fields are left out");
    }
}
