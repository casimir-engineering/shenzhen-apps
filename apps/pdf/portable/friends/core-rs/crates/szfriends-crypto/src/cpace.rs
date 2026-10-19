//! CPace (draft-irtf-cfrg-cpace-13) over ristretto255 with SHA-512, as the helper runs it on libsodium
//! (`SZFriendsCPace.m`), and the join exchange's inputs and tags (ADR 0013, `SZFriendsJoinWire.m`).
//!
//! Joining a profile runs it with the 8-digit code one of the person's computers shows: a plain hash of so short a
//! code would fall to offline guessing, while CPace gives whoever does not know the code one guess per run.

use curve25519_dalek::ristretto::{CompressedRistretto, RistrettoPoint};
use curve25519_dalek::scalar::Scalar;
use sha2::{Digest, Sha512};
use zeroize::Zeroizing;

pub const SHARE_LEN: usize = 32;
pub const SCALAR_LEN: usize = 32;
pub const ISK_LEN: usize = 64;

const DSI: &[u8] = b"CPaceRistretto255";
const DSI_ISK: &[u8] = b"CPaceRistretto255_ISK";
/// SHA-512's input block, `s_in_bytes`.
const HASH_BLOCK: usize = 128;

fn leb128(mut value: usize, out: &mut Vec<u8>) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

/// `prepend_len` (Appendix A.1.1): `data` after its length in LEB128.
pub fn prepend_len(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 2);
    leb128(data.len(), &mut out);
    out.extend_from_slice(data);
    out
}

/// `lv_cat` (Appendix A.1.3): every part with its length prepended, concatenated.
pub fn lv_cat(parts: &[&[u8]]) -> Vec<u8> {
    parts.iter().flat_map(|part| prepend_len(part)).collect()
}

/// `generator_string` (§ 7.1) with DSI "CPaceRistretto255" and SHA-512's 128-byte block.
pub fn generator_string(prs: &[u8], ci: &[u8], sid: &[u8]) -> Vec<u8> {
    let used = 1 + prepend_len(prs).len() + prepend_len(DSI).len();
    let zpad = vec![0u8; HASH_BLOCK.saturating_sub(used)];
    lv_cat(&[DSI, prs, &zpad, ci, sid])
}

/// `calculate_generator` (§ 7.3): the element mapped from SHA-512 of the generator string, encoded.
pub fn generator(prs: &[u8], ci: &[u8], sid: &[u8]) -> [u8; SHARE_LEN] {
    let string = Zeroizing::new(generator_string(prs, ci, sid));
    let hash: Zeroizing<[u8; 64]> = Zeroizing::new(Sha512::digest(string.as_slice()).into());
    RistrettoPoint::from_uniform_bytes(&hash).compress().to_bytes()
}

/// libsodium's `crypto_scalarmult_ristretto255`: the scalar's top bit cleared, a canonical element, and a result
/// that is not the identity. Points have prime order, so reducing the scalar changes nothing else.
fn scalar_of(scalar: &[u8; SCALAR_LEN]) -> Scalar {
    let mut bytes = Zeroizing::new(*scalar);
    bytes[31] &= 0x7f;
    Scalar::from_bytes_mod_order(*bytes)
}

/// `scalar_mult`: `y * g`; `None` for an invalid encoding or an identity result.
pub fn scalar_mult(scalar: &[u8; SCALAR_LEN], element: &[u8]) -> Option<[u8; SHARE_LEN]> {
    let point = CompressedRistretto::from_slice(element).ok()?.decompress()?;
    let product = (scalar_of(scalar) * point).compress().to_bytes();
    (product != [0u8; SHARE_LEN]).then_some(product)
}

/// `scalar_mult_vfy`: `y * Y`, or `None` where the draft returns the neutral element (Y invalid, or the identity) and
/// the protocol aborts.
pub fn scalar_mult_vfy(scalar: &[u8; SCALAR_LEN], element: &[u8]) -> Option<[u8; SHARE_LEN]> {
    scalar_mult(scalar, element)
}

/// ISK (§ 6.2), initiator-responder transcript:
/// `SHA-512(lv_cat(DSI_ISK, sid, K) || lv_cat(Ya, ADa) || lv_cat(Yb, ADb))`.
pub fn isk(sid: &[u8], secret: &[u8], share_a: &[u8], ad_a: &[u8], share_b: &[u8], ad_b: &[u8]) -> [u8; ISK_LEN] {
    let mut hasher = Sha512::new();
    hasher.update(Zeroizing::new(lv_cat(&[DSI_ISK, sid, secret])));
    hasher.update(lv_cat(&[share_a, ad_a]));
    hasher.update(lv_cat(&[share_b, ad_b]));
    hasher.finalize().into()
}

/// A uniformly random scalar, encoded.
pub fn random_scalar() -> [u8; SCALAR_LEN] {
    let mut wide = Zeroizing::new([0u8; 64]);
    crate::random_bytes(wide.as_mut());
    Scalar::from_bytes_mod_order_wide(&wide).to_bytes()
}

/// One side of one run. The initiator (A) sends its share first; the responder (B) answers with its own. A wrong
/// code, an invalid share or a different sid gives the two sides different keys, which the caller's tags reveal.
pub struct CPace {
    scalar: Zeroizing<[u8; SCALAR_LEN]>,
    sid: Vec<u8>,
    share: [u8; SHARE_LEN],
}

impl std::fmt::Debug for CPace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CPace").field("share", &self.share).finish_non_exhaustive()
    }
}

impl CPace {
    /// `prs` is the password (the typed code), `ci` the channel identifier and `sid` the session id. `scalar` is for
    /// golden vectors; `None` draws one.
    pub fn new(prs: &[u8], ci: &[u8], sid: &[u8], scalar: Option<[u8; SCALAR_LEN]>) -> Option<Self> {
        let scalar = Zeroizing::new(scalar.unwrap_or_else(random_scalar));
        let share = scalar_mult(&scalar, &generator(prs, ci, sid))?;
        Some(Self { scalar, sid: sid.to_vec(), share })
    }

    /// Y, to send.
    pub fn share(&self) -> [u8; SHARE_LEN] {
        self.share
    }

    /// ISK as initiator A; `None` when the peer's share is invalid.
    pub fn isk_as_initiator(&self, own_ad: &[u8], peer_share: &[u8], peer_ad: &[u8]) -> Option<Zeroizing<[u8; 64]>> {
        let secret = Zeroizing::new(scalar_mult_vfy(&self.scalar, peer_share)?);
        Some(Zeroizing::new(isk(&self.sid, secret.as_ref(), &self.share, own_ad, peer_share, peer_ad)))
    }

    /// ISK as responder B.
    pub fn isk_as_responder(&self, own_ad: &[u8], peer_share: &[u8], peer_ad: &[u8]) -> Option<Zeroizing<[u8; 64]>> {
        let secret = Zeroizing::new(scalar_mult_vfy(&self.scalar, peer_share)?);
        Some(Zeroizing::new(isk(&self.sid, secret.as_ref(), peer_share, peer_ad, &self.share, own_ad)))
    }
}

/// The join exchange's CPace inputs and keyed tags (ADR 0013).
pub mod join {
    use subtle::ConstantTimeEq;

    pub const RESPONDER_TAG_DOMAIN: &str = "SZFriends join responder v1";
    pub const INITIATOR_TAG_DOMAIN: &str = "SZFriends join initiator v1";
    pub const WELCOME_TAG_DOMAIN: &str = "SZFriends join welcome v1";
    const CHANNEL_DOMAIN: &[u8] = b"SZFriends join v1";

    /// CI = `lv_cat("SZFriends join v1", request id, device key, static key)`.
    pub fn channel_identifier(request_id: &[u8], device_key: &[u8], static_key: &[u8]) -> Vec<u8> {
        super::lv_cat(&[CHANNEL_DOMAIN, request_id, device_key, static_key])
    }

    /// ADb = the approving device's key || the profile's root key, so ISK binds the root.
    pub fn approver_ad(approver_key: &[u8], root_key: &[u8]) -> Vec<u8> {
        [approver_key, root_key].concat()
    }

    /// BLAKE2b-256 keyed with ISK over `UTF-8(domain) || extra`.
    pub fn tag(isk: &[u8], domain: &str, extra: &[u8]) -> [u8; 32] {
        crate::blake2b::<32>(Some(isk), &[domain.as_bytes(), extra])
    }

    /// Constant time; `false` unless both are 32 bytes.
    pub fn tags_equal(a: &[u8], b: &[u8]) -> bool {
        a.len() == 32 && b.len() == 32 && bool::from(a.ct_eq(b))
    }
}
