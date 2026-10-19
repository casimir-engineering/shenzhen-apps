//! X25519 at the points where implementations disagree (low-order and non-canonical u, the ignored top bit), against
//! the helper's `crypto_scalarmult` verdicts (fixtures/vectors/objc-edge-cases.json).

use szfriends_crypto::noise::checked_x25519;
use szfriends_vectors::{cases, field, load};

#[test]
fn x25519_refuses_exactly_what_libsodium_refuses() {
    let vectors = load("objc-edge-cases.json");
    let mut refused = 0;
    for case in cases(&vectors, "x25519") {
        let private: [u8; 32] = field(case, "private_key").try_into().expect("32");
        let public: [u8; 32] = field(case, "public_key").try_into().expect("32");
        let ours = checked_x25519(&private, &public).map(|shared| shared.to_vec());
        let helper = (!case["shared"].is_null()).then(|| field(case, "shared"));
        assert_eq!(ours, helper, "u = {}", case["public_key"]);
        refused += usize::from(helper.is_none());
    }
    assert!(refused >= 14, "every listed low-order point, with and without the top bit");
}

/// Keyed BLAKE2b at 16 bytes is libsodium's crypto_generichash with a key (Python's hashlib.blake2b agrees): the
/// mention request token (`SZFriendsMentionRequestToken`).
#[test]
fn keyed_blake2b_at_sixteen_bytes() {
    let token: [u8; 16] = szfriends_crypto::blake2b(Some(&[1; 32]), &[b"SZFriends mention request v1", &[2; 32]]);
    let expected = [0x6c, 0x50, 0x9f, 0xc4, 0x7e, 0xf6, 0xc3, 0xe9, 0x30, 0xb1, 0x99, 0x23, 0xac, 0x6f, 0x44, 0xb9];
    assert_eq!(token, expected);
}
