//! REQUEST_BY_ID (ADR 0004 step 1; ADR 0001 Corrections). NN authenticates nobody, so the request carries its own
//! proof: the requester's certificate and a signature over this session's handshake hash. A device in the middle
//! running one NN session with each side holds two different hashes and cannot turn one signature into the other.

use szfriends_wire::{tag, Frame, FrameType};

use crate::identity::{identity_key_from_certificate, verify, Identity};

const DOMAIN: &str = "SZFriends request v1";

/// `h || token || callback secret || static key || Friends ID`: variable length last, so it has one reading.
fn signed_bytes(h: &[u8], token: &[u8], callback: &[u8], static_key: &[u8], friends_id: &[u8]) -> Vec<u8> {
    [h, token, callback, static_key, friends_id].concat()
}

/// `None` for a token that is not 16 bytes, a secret that is not 32, a hash that is not 64, or an empty ID or one over
/// 64 bytes.
pub fn make_frame(
    identity: &Identity,
    friends_id: &str,
    token: &[u8],
    callback_secret: &[u8],
    h: &[u8],
) -> Option<Frame> {
    let id = friends_id.as_bytes();
    if token.len() != 16 || callback_secret.len() != 32 || h.len() != 64 || id.is_empty() || id.len() > 64 {
        return None;
    }
    let static_key = identity.static_public_key();
    let signature = identity.sign(&signed_bytes(h, token, callback_secret, &static_key, id), DOMAIN);
    Some(
        Frame::new(FrameType::RequestById)
            .with(tag::FRIENDS_ID, id)
            .with(tag::TOKEN, token)
            .with(tag::CALLBACK_SECRET, callback_secret)
            .with(tag::CERTIFICATE, identity.static_certificate())
            .with(tag::STATIC_KEY, static_key)
            .with(tag::SIGNATURE, signature),
    )
}

/// The requester's identity key when the certificate binds StaticKey and the signature verifies for this session's
/// `h`. The responder sends RECEIVED either way, before looking anything up.
pub fn verify_frame(frame: &Frame, h: &[u8]) -> Option<[u8; 32]> {
    if frame.frame_type != FrameType::RequestById || h.len() != 64 {
        return None;
    }
    let field = |t| frame.get(t);
    let (id, token, callback) = (field(tag::FRIENDS_ID)?, field(tag::TOKEN)?, field(tag::CALLBACK_SECRET)?);
    let (static_key, signature) = (field(tag::STATIC_KEY)?, field(tag::SIGNATURE)?);
    let identity_key = identity_key_from_certificate(field(tag::CERTIFICATE)?, static_key)?;
    verify(signature, &signed_bytes(h, token, callback, static_key, id), DOMAIN, &identity_key).then_some(identity_key)
}
