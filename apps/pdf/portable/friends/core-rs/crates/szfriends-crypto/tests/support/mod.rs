//! Shared by this crate's vector suites.

use serde_json::Value;
use szfriends_crypto::noise::{Handshake, HandshakeKeys, Transport};
use szfriends_vectors::field;
use szfriends_wire::Pattern;
use zeroize::Zeroizing;

pub fn key(value: &Value, name: &str) -> Option<Zeroizing<[u8; 32]>> {
    value.get(name).filter(|v| !v.is_null()).map(|_| Zeroizing::new(field(value, name).try_into().expect("32")))
}

pub fn public(value: &Value, name: &str) -> Option<[u8; 32]> {
    key(value, name).map(|k| *k)
}

/// Builds both sides from a vector's keys (`init_*`/`resp_*`, or the Friends exporter's names).
pub fn pair(
    pattern: Pattern,
    prologue: &[u8],
    initiator: HandshakeKeys,
    responder: HandshakeKeys,
) -> (Handshake, Handshake) {
    (
        Handshake::new(pattern, true, prologue, &initiator).expect("initiator"),
        Handshake::new(pattern, false, prologue, &responder).expect("responder"),
    )
}

/// Runs `messages` alternately from the initiator, checking every ciphertext and payload, through the handshake
/// and on into transport; returns the hash and the transports.
pub fn run(
    mut i: Handshake,
    mut r: Handshake,
    messages: &[Value],
    label: &str,
) -> ([u8; 64], Option<(Transport, Transport)>) {
    let count = i.pattern().message_count();
    for (n, message) in messages.iter().take(count).enumerate() {
        let (writer, reader) = if n % 2 == 0 { (&mut i, &mut r) } else { (&mut r, &mut i) };
        let payload = field(message, "payload");
        let ciphertext = writer.write(&payload).unwrap_or_else(|e| panic!("{label} message {n}: {e}"));
        assert_eq!(ciphertext, field(message, "ciphertext"), "{label} message {n}");
        assert_eq!(reader.read(&ciphertext).expect("read"), payload, "{label} message {n} payload");
    }
    let hash = i.handshake_hash().expect("hash");
    assert_eq!(Some(hash), r.handshake_hash(), "{label}: both sides agree on h");
    let (mut ti, mut tr) = (i.into_transport().expect("split"), r.into_transport().expect("split"));
    for (n, message) in messages.iter().enumerate().skip(count) {
        let (sender, receiver) = if n % 2 == 0 { (&mut ti, &mut tr) } else { (&mut tr, &mut ti) };
        let payload = field(message, "payload");
        let ciphertext = sender.encrypt(&payload).expect("encrypt");
        assert_eq!(ciphertext, field(message, "ciphertext"), "{label} transport {n}");
        assert_eq!(receiver.decrypt(&ciphertext).expect("decrypt"), payload);
    }
    (hash, Some((ti, tr)))
}
