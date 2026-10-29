//! AES-256-GCM lanes (ADR 0018 § 9.2): a first session whose two sides both set capability bit 1 lets its lanes run
//! `Noise_IK_25519_AESGCM_BLAKE2b`, named by bit 7 of the preamble's pattern byte; a responder that does not offer them
//! refuses that preamble before any Diffie-Hellman; AES-GCM carries lanes only; and a flipped flag fails the
//! handshake instead of changing the cipher.

mod support;

use support::*;
use szfriends_core::session::{ChannelConfig, HandshakeOptions, SecureChannel, SessionError};
use szfriends_core::wire::consts::{CAPABILITY_AES_LANES, CAPABILITY_FAST_TRANSFERS};
use szfriends_core::wire::{NoiseCipher, Pattern, RouteMethod};

const BOTH: u32 = CAPABILITY_FAST_TRANSFERS | CAPABILITY_AES_LANES;

fn config(capabilities: u32) -> ChannelConfig {
    ChannelConfig { capabilities, ..Default::default() }
}

fn dial(
    cipher: NoiseCipher,
    lane: Option<[u8; 16]>,
    ours: u32,
    theirs: u32,
    tamper: Option<(Side, usize, u8)>,
) -> Pipe {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = HandshakeOptions::new(Pattern::IK, RouteMethod::Lan);
    options.remote_static = Some(bob.static_public_key());
    options.lane = lane;
    options.cipher = cipher;
    let mut initiator = SecureChannel::initiator(keys(&alice), options);
    initiator.set_config(config(ours));
    let mut responder = SecureChannel::responder(keys(&bob), Some(profile("Bob")), allow_all());
    responder.set_config(config(theirs));
    Pipe::with_tamper(initiator, responder, tamper)
}

#[test]
fn both_sides_setting_bit_1_give_aes_lanes() {
    let first = dial(NoiseCipher::ChaChaPoly, None, BOTH, BOTH, None);
    assert!(Pipe::established(&first.responder_events));
    assert!(first.initiator.aes_lanes() && first.responder.aes_lanes());
    assert_eq!(first.initiator.cipher(), NoiseCipher::ChaChaPoly, "a first session stays ChaChaPoly");
    let one_side = dial(NoiseCipher::ChaChaPoly, None, BOTH, CAPABILITY_FAST_TRANSFERS, None);
    assert!(!one_side.initiator.aes_lanes() && !one_side.responder.aes_lanes());
}

#[test]
fn an_aes_lane_carries_frames_under_aes_gcm() {
    let mut lane = dial(NoiseCipher::AesGcm, Some([7; 16]), BOTH, BOTH, None);
    assert!(Pipe::established(&lane.responder_events), "{:?}", lane.responder_events);
    assert_eq!(&lane.sent_by_initiator[..4], b"SZ\x01\x81", "bit 7 of the pattern byte");
    assert_eq!(lane.responder.cipher(), NoiseCipher::AesGcm);
    assert_eq!(lane.responder.presented_lane(), Some(&[7; 16]));
    assert!(lane.send(Side::Initiator, &message("over AES", 1)));
    assert!(lane.send(Side::Responder, &message("and back", 2)));
    assert_eq!(Pipe::frames(&lane.responder_events).len(), 1);
    assert_eq!(Pipe::frames(&lane.initiator_events).len(), 1);
}

#[test]
fn a_responder_without_bit_1_refuses_the_preamble() {
    let mut lane = dial(NoiseCipher::AesGcm, Some([7; 16]), BOTH, CAPABILITY_FAST_TRANSFERS, None);
    lane.advance(std::time::Duration::from_secs(2)); // a refusal closes after the refusal delay
    assert!(!Pipe::established(&lane.responder_events));
    assert_eq!(Pipe::closed(&lane.responder_events), Some(Some(SessionError::Rejected)));
    assert_eq!(lane.responder.handshake_hash(), None);
}

#[test]
fn aes_gcm_goes_only_on_lanes() {
    let first = dial(NoiseCipher::AesGcm, None, BOTH, BOTH, None);
    assert!(!Pipe::established(&first.initiator_events));
    assert!(first.sent_by_initiator.is_empty(), "refused before a byte");
}

#[test]
fn flipping_the_cipher_flag_fails_the_handshake() {
    // ChaChaPoly said AES-GCM, and the other way round: the prologue holds the preamble, and the protocol names differ.
    for (cipher, flipped) in [(NoiseCipher::ChaChaPoly, "to AES-GCM"), (NoiseCipher::AesGcm, "to ChaChaPoly")] {
        let lane = dial(cipher, Some([7; 16]), BOTH, BOTH, Some((Side::Initiator, 3, 0x80)));
        assert!(!Pipe::established(&lane.responder_events), "flipped {flipped}");
        assert!(!Pipe::established(&lane.initiator_events), "flipped {flipped}");
    }
}
