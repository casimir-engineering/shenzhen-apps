//! Shenzhen Friends cryptography, interoperable with the Objective-C helper byte for byte.
//!
//! - [`noise`]: `Noise_{XX,IK,NN}_25519_ChaChaPoly_BLAKE2b` (ADR 0001) on `snow`, with the helper's extra rules: an
//!   all-zero X25519 result fails, a failed handshake is dead, nonces never wrap, rekey per direction.
//! - [`code`]: comparison codes by commit-then-reveal over the handshake hash.
//! - [`presence`]: presence and callback tags (ADR 0004).
//! - [`cpace`]: CPace (draft-irtf-cfrg-cpace-13, ristretto255 with SHA-512) and the join exchange's inputs and tags
//!   (ADR 0013).
//! - [`invite`]: the friend-link invite proof bound to one NN session.
//!
//! `snow` is the independent implementation ADR 0001 names as its second vector source, so agreeing with the helper's
//! own C state machine on Friends' real handshakes (fixtures/vectors/objc-noise.json) is a cross-check, not a copy.

pub mod code;
pub mod cpace;
pub mod invite;
pub mod noise;
pub mod presence;

/// BLAKE2b with a `LEN`-byte output (`crypto_generichash`), optionally keyed (16- or 32-byte output then), over the
/// concatenation of `parts`.
pub fn blake2b<const LEN: usize>(key: Option<&[u8]>, parts: &[&[u8]]) -> [u8; LEN] {
    use blake2::digest::consts::{U16, U32};
    use blake2::digest::{KeyInit, Mac, Update, VariableOutput};
    assert!(LEN == 16 || LEN == 32 || key.is_none(), "keyed BLAKE2b is only used at 16 and 32 bytes");
    let mut out = [0u8; LEN];
    match key {
        Some(key) if LEN == 16 => {
            let mut mac = <blake2::Blake2bMac<U16> as KeyInit>::new_from_slice(key).expect("key of 1 to 64 bytes");
            for part in parts {
                Mac::update(&mut mac, part);
            }
            out.copy_from_slice(&mac.finalize().into_bytes());
        }
        Some(key) => {
            let mut mac = <blake2::Blake2bMac<U32> as KeyInit>::new_from_slice(key).expect("key of 1 to 64 bytes");
            for part in parts {
                Mac::update(&mut mac, part);
            }
            out.copy_from_slice(&mac.finalize().into_bytes());
        }
        None => {
            let mut hasher = blake2::Blake2bVar::new(LEN).expect("output of 1 to 64 bytes");
            for part in parts {
                hasher.update(part);
            }
            hasher.finalize_variable(&mut out).expect("length matches");
        }
    }
    out
}

/// Fills `out` from the system's secure random source.
pub fn random_bytes(out: &mut [u8]) {
    getrandom::fill(out).expect("the system random source failed");
}
