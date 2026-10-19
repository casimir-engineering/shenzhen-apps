//! Comparison codes (ADR 0001 § Comparison codes): commit-then-reveal over the session's handshake hash, so neither
//! side, nor anyone between them, can grind the six digits. The responder commits to its nonce, the initiator reveals
//! its own, then the responder reveals and the initiator checks the commitment.

use subtle::ConstantTimeEq;

const COMMIT_LABEL: &[u8] = b"SZFriends code commit v1";
const CODE_LABEL: &[u8] = b"SZFriends code v1";
pub const NONCE_LEN: usize = 32;

/// `BLAKE2b-256("SZFriends code commit v1" || h || responder_nonce)`.
pub fn commitment(handshake_hash: &[u8], responder_nonce: &[u8]) -> [u8; 32] {
    crate::blake2b::<32>(None, &[COMMIT_LABEL, handshake_hash, responder_nonce])
}

/// Whether a revealed nonce matches the commitment received earlier, in constant time.
pub fn commitment_matches(commitment_received: &[u8], handshake_hash: &[u8], responder_nonce: &[u8]) -> bool {
    commitment_received.len() == 32
        && bool::from(commitment(handshake_hash, responder_nonce).ct_eq(commitment_received))
}

/// First 8 bytes of `BLAKE2b-256("SZFriends code v1" || h || initiator_nonce || responder_nonce)` as a big-endian
/// integer mod 1,000,000, as six ASCII digits. Presentation groups them for display.
pub fn comparison_code(handshake_hash: &[u8], initiator_nonce: &[u8], responder_nonce: &[u8]) -> String {
    let digest = crate::blake2b::<32>(None, &[CODE_LABEL, handshake_hash, initiator_nonce, responder_nonce]);
    let value = u64::from_be_bytes(digest[..8].try_into().expect("8 bytes"));
    format!("{:06}", value % 1_000_000)
}
