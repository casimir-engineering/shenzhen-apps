//! The local identity: an Ed25519 signing key (the identity, by which friends store this person) and an X25519 Noise
//! static key, generated together, stored in one key-store item, both immutable (ADR 0001 § Keys). The static key is
//! not derived from the signing key; a certificate links the two.

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use zeroize::Zeroizing;

use szfriends_crypto::noise::x25519_public;

/// The certificate's domain: `public key || Sig("SZFriends static v1" || static public key)`.
pub const STATIC_CERTIFICATE_DOMAIN: &str = "SZFriends static v1";
const IDENTITY_HASH_DOMAIN: &str = "SZFriends identity hash v1";

/// Every domain the identity key signs under, one per purpose, none a prefix of another. The signature format has no
/// separator before the message, so this list is what keeps purposes apart: a new use adds its domain here.
pub const SIGNATURE_DOMAINS: [&str; 8] = [
    STATIC_CERTIFICATE_DOMAIN,
    "SZFriends request v1",
    "SZFriends checkin v1",
    "SZFriends release v1",
    "SZFriends link sender v1",
    "SZFriends chain link v1",
    "SZFriends device consent v1",
    "SZFriends sync event v1",
];

pub const CERTIFICATE_LEN: usize = 96;
/// `"SZFI" | 1 | Ed25519 seed (32) | X25519 private, clamped (32) | Ed25519 public (32) | X25519 public (32)`.
pub const SECRET_ITEM_LEN: usize = 133;
const SECRET_MAGIC: &[u8; 4] = b"SZFI";
const SECRET_VERSION: u8 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IdentityError {
    /// A secret is present but cannot be read (a locked keychain, a store that refuses).
    Unavailable,
    /// A secret is readable but not a valid key.
    Corrupt,
    /// A new secret could not be written, or one already exists.
    StoreFailed,
    /// No secret exists, but the store holds an identity's history: the store came back from a backup or another
    /// device without its key. Never answered by creating a key; only the person's Start again clears both.
    KeyMissing,
    /// The secret is a different identity from the one the store was made for. Never mixed: refused like
    /// [`KeyMissing`](Self::KeyMissing).
    StoreMismatch,
}

impl std::fmt::Display for IdentityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for IdentityError {}

/// `true` when `domain` and a listed domain differ but one starts with the other: `domain || message` could then
/// coincide across purposes. Equal domains are the same purpose.
fn domain_collides(domain: &str) -> bool {
    for listed in SIGNATURE_DOMAINS {
        if domain == listed {
            return false;
        }
        if domain.starts_with(listed) || listed.starts_with(domain) {
            return true;
        }
    }
    false
}

fn clamp(mut key: [u8; 32]) -> [u8; 32] {
    key[0] &= 248;
    key[31] &= 127;
    key[31] |= 64;
    key
}

pub struct Identity {
    signing: SigningKey,
    static_private: Zeroizing<[u8; 32]>,
    static_public: [u8; 32],
    certificate: [u8; CERTIFICATE_LEN],
}

/// Never the keys: debug output ends up in logs.
impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Identity({})", self.log_fingerprint())
    }
}

impl Identity {
    /// From given secrets: golden vectors, tests, and loading a stored item. Production creates with [`generate`].
    ///
    /// [`generate`]: Identity::generate
    pub fn from_secrets(signing_seed: &[u8; 32], static_private: &[u8; 32]) -> Self {
        let signing = SigningKey::from_bytes(signing_seed);
        let static_public = x25519_public(static_private);
        let mut certificate = [0u8; CERTIFICATE_LEN];
        certificate[..32].copy_from_slice(signing.verifying_key().as_bytes());
        let message = [STATIC_CERTIFICATE_DOMAIN.as_bytes(), &static_public].concat();
        certificate[32..].copy_from_slice(&signing.sign(&message).to_bytes());
        Self { signing, static_private: Zeroizing::new(*static_private), static_public, certificate }
    }

    /// A new identity from the system's secure random source, the static key clamped as the helper stores it.
    pub fn generate() -> Self {
        let mut seed = Zeroizing::new([0u8; 32]);
        let mut static_private = Zeroizing::new([0u8; 32]);
        szfriends_crypto::random_bytes(seed.as_mut());
        szfriends_crypto::random_bytes(static_private.as_mut());
        Self::from_secrets(&seed, &clamp(*static_private))
    }

    /// The Ed25519 public key: the stable identity of this person.
    pub fn public_key(&self) -> [u8; 32] {
        self.signing.verifying_key().to_bytes()
    }

    /// The X25519 Noise static public key.
    pub fn static_public_key(&self) -> [u8; 32] {
        self.static_public
    }

    /// The X25519 private key for Noise handshakes, kept inside the process.
    pub fn static_private_key(&self) -> Zeroizing<[u8; 32]> {
        self.static_private.clone()
    }

    /// 96 bytes, carried in every handshake payload that reveals the static key.
    pub fn static_certificate(&self) -> [u8; CERTIFICATE_LEN] {
        self.certificate
    }

    pub fn identity_hash(&self) -> [u8; 32] {
        identity_hash(&self.public_key())
    }

    /// The first 8 hex digits of the identity hash, for logs only; never shown, never used as identity.
    pub fn log_fingerprint(&self) -> String {
        self.identity_hash()[..4].iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Signs `UTF-8(domain) || message`. An empty domain, or one colliding by prefix with a listed domain, is a
    /// programming error and panics, as the helper raises.
    pub fn sign(&self, message: &[u8], domain: &str) -> [u8; 64] {
        assert!(!domain.is_empty() && !domain_collides(domain), "a Friends signature domain collides by prefix");
        let input = Zeroizing::new([domain.as_bytes(), message].concat());
        self.signing.sign(&input).to_bytes()
    }

    /// The 133-byte key-store item. Fresh memory the caller drops (zeroed) after storing.
    pub fn secret_item(&self) -> Zeroizing<Vec<u8>> {
        let mut item = Zeroizing::new(Vec::with_capacity(SECRET_ITEM_LEN));
        item.extend_from_slice(SECRET_MAGIC);
        item.push(SECRET_VERSION);
        item.extend_from_slice(self.signing.as_bytes());
        // Clamped like generated keys, so an identity built from unclamped vector keys also round-trips.
        item.extend_from_slice(&clamp(*self.static_private));
        item.extend_from_slice(&self.public_key());
        item.extend_from_slice(&self.static_public);
        item
    }

    /// Corrupt for a wrong length, magic or version, an unclamped key, or public keys that do not match the private
    /// ones, so a damaged byte never loads as a different identity, which friends would see as a key change.
    pub fn from_secret_item(item: &[u8]) -> Result<Self, IdentityError> {
        if item.len() != SECRET_ITEM_LEN
            || &item[..4] != SECRET_MAGIC
            || item[4] != SECRET_VERSION
            || item[37] & 7 != 0
            || item[68] & 0xc0 != 0x40
        {
            return Err(IdentityError::Corrupt);
        }
        let seed: Zeroizing<[u8; 32]> = Zeroizing::new(item[5..37].try_into().expect("32"));
        let static_private: Zeroizing<[u8; 32]> = Zeroizing::new(item[37..69].try_into().expect("32"));
        let identity = Self::from_secrets(&seed, &static_private);
        let public_ok = subtle::ConstantTimeEq::ct_eq(&identity.public_key()[..], &item[69..101]);
        let static_ok = subtle::ConstantTimeEq::ct_eq(&identity.static_public[..], &item[101..133]);
        if !bool::from(public_ok & static_ok) {
            return Err(IdentityError::Corrupt);
        }
        Ok(identity)
    }
}

/// BLAKE2b-256 of `"SZFriends identity hash v1" || public key`: a stable stand-in for an identity key.
pub fn identity_hash(public_key: &[u8; 32]) -> [u8; 32] {
    szfriends_crypto::blake2b::<32>(None, &[IDENTITY_HASH_DOMAIN.as_bytes(), public_key])
}

/// `false` for a wrong-length key or signature, an empty or colliding domain, a non-canonical or small-order key, or
/// a signature that does not verify. Strict like libsodium's `crypto_sign_verify_detached`: non-canonical S and
/// small-order R are refused too.
pub fn verify(signature: &[u8], message: &[u8], domain: &str, public_key: &[u8]) -> bool {
    if domain.is_empty() || domain_collides(domain) {
        return false;
    }
    let (Ok(signature), Ok(key_bytes)) = (<[u8; 64]>::try_from(signature), <[u8; 32]>::try_from(public_key)) else {
        return false;
    };
    let Ok(key) = VerifyingKey::from_bytes(&key_bytes) else { return false };
    // libsodium also refuses a key whose encoding is not canonical; dalek decodes such keys, so compare re-encoding.
    let canonical = curve25519_dalek::edwards::CompressedEdwardsY(key_bytes)
        .decompress()
        .is_some_and(|point| point.compress().to_bytes() == key_bytes);
    if !canonical {
        return false;
    }
    let input = [domain.as_bytes(), message].concat();
    key.verify_strict(&input, &Signature::from_bytes(&signature)).is_ok()
}

/// Checks a peer's certificate against the static key its handshake used and returns the identity key it binds.
pub fn identity_key_from_certificate(certificate: &[u8], static_public_key: &[u8]) -> Option<[u8; 32]> {
    if certificate.len() != CERTIFICATE_LEN || static_public_key.len() != 32 {
        return None;
    }
    let (key, signature) = certificate.split_at(32);
    verify(signature, static_public_key, STATIC_CERTIFICATE_DOMAIN, key).then(|| key.try_into().expect("32"))
}
