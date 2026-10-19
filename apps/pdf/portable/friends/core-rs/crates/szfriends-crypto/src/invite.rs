//! The friend-link invite proof (`SZFriendsInviteProof`): HMAC-SHA-256 keyed with a link's 16-byte invite token over
//! `"SZFriends invite v1" || h`, so a device that hears a request (every device nearby answers it) learns nothing it
//! could present in another session.

use hmac::{Hmac, Mac};
use sha2::Sha256;

const LABEL: &[u8] = b"SZFriends invite v1";

/// `None` unless the token is 16 bytes and h 64.
pub fn invite_proof(invite_token: &[u8], handshake_hash: &[u8]) -> Option<[u8; 32]> {
    if invite_token.len() != 16 || handshake_hash.len() != 64 {
        return None;
    }
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(invite_token).ok()?;
    mac.update(LABEL);
    mac.update(handshake_hash);
    Some(mac.finalize().into_bytes().into())
}
