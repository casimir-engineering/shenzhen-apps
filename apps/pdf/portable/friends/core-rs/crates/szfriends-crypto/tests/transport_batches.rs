//! Batches of transport messages sealed and opened on several cores give exactly the messages, nonces and failures one
//! at a time would, with both ciphers (ADR 0018 § 9.2).

use szfriends_crypto::noise::{x25519_public, Handshake, HandshakeKeys, NoiseError, Transport};
use szfriends_wire::{NoiseCipher, Pattern};
use zeroize::Zeroizing;

fn pair(cipher: NoiseCipher) -> (Transport, Transport) {
    let (a, b) = ([0x11u8; 32], [0x22u8; 32]);
    let keys = |local: [u8; 32], remote: Option<[u8; 32]>, e: u8| HandshakeKeys {
        local_static: Some(Zeroizing::new(local)),
        remote_static: remote,
        fixed_ephemeral: Some(Zeroizing::new([e; 32])),
    };
    let mut i =
        Handshake::with_cipher(Pattern::IK, cipher, true, b"batch", &keys(a, Some(x25519_public(&b)), 3)).unwrap();
    let mut r = Handshake::with_cipher(Pattern::IK, cipher, false, b"batch", &keys(b, None, 4)).unwrap();
    r.read(&i.write(&[]).unwrap()).unwrap();
    i.read(&r.write(&[]).unwrap()).unwrap();
    (i.into_transport().unwrap(), r.into_transport().unwrap())
}

fn frames() -> Vec<Vec<u8>> {
    (0..9u8).map(|n| vec![n; if n % 3 == 0 { 61_440 } else { 1_000 + usize::from(n) }]).collect()
}

#[test]
fn a_batch_seals_what_one_at_a_time_seals() {
    for cipher in [NoiseCipher::ChaChaPoly, NoiseCipher::AesGcm] {
        let frames = frames();
        let refs: Vec<&[u8]> = frames.iter().map(Vec::as_slice).collect();
        let (mut one, mut peer_one) = pair(cipher);
        let (mut many, mut peer_many) = pair(cipher);
        let singly: Vec<Vec<u8>> = refs.iter().map(|f| one.encrypt(f).unwrap()).collect();
        let batched = many.encrypt_many(&refs).unwrap();
        assert_eq!(singly, batched, "{cipher:?}");
        assert_eq!(many.sending_nonce(), 9);
        for (message, frame) in batched.iter().zip(&frames) {
            assert_eq!(&peer_one.decrypt(message).unwrap(), frame);
        }
        let opened = peer_many.decrypt_many(&batched.iter().map(Vec::as_slice).collect::<Vec<_>>(), |_| false);
        assert_eq!(opened.into_iter().map(Result::unwrap).collect::<Vec<_>>(), frames);
        assert_eq!(peer_many.receiving_nonce(), 9);
    }
}

#[test]
fn opening_stops_after_a_rekey_and_at_a_failure() {
    let (mut sender, mut receiver) = pair(NoiseCipher::AesGcm);
    let frames = frames();
    let mut messages: Vec<Vec<u8>> = frames[..4].iter().map(|f| sender.encrypt(f).unwrap()).collect();
    // Frame 2 says "rekey": what follows it is under the next key, so the batch stops there.
    let opened = receiver.decrypt_many(&messages.iter().map(Vec::as_slice).collect::<Vec<_>>(), |p| p[0] == 2);
    assert_eq!(opened.len(), 3);
    assert_eq!(receiver.receiving_nonce(), 3);
    // A flipped byte: the batch stops at it and its nonce stays unused.
    messages[3][10] ^= 1;
    let opened = receiver.decrypt_many(&[messages[3].as_slice()], |_| false);
    assert_eq!(opened, vec![Err(NoiseError::Decrypt)]);
    assert_eq!(receiver.receiving_nonce(), 3);
}
