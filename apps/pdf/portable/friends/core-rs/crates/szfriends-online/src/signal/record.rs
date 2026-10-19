//! Rendezvous record blobs (`SZFriendsSignalingRecord.m`, ADR 0010): sealed under the publisher's presence secret,
//! which only friends hold, and signed inside by the device that made them. The host keeps them opaque and answers a
//! lookup for anyone else with 512 bytes of filler, which a blob cannot be told apart from without the secret.
//!
//! A blob: 24-byte nonce || XChaCha20-Poly1305 of 472 bytes, the key BLAKE2b-256 keyed with the presence secret over
//! "SZFriends rendezvous seal v1", the associated data that label || rdv key. Inside: version 1, the window (i64be),
//! the device key, its Ed25519 signature ("SZFriends rendezvous seal v1" over rdv key || version || window || device
//! key || body), the body's length (u16be) and the body (items), then zeros.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use sha2::{Digest, Sha256};
use szfriends_identity::identity::verify;
use szfriends_identity::Identity;
use zeroize::Zeroizing;

use super::items::{self, Item};

pub const SEALED_LENGTH: usize = 512;
pub const BODY_MAX: usize = 365;
const KEY_DOMAIN: &str = "SZFriends rendezvous key v1";
const SEAL_DOMAIN: &str = "SZFriends rendezvous seal v1";
const VERSION: u8 = 1;
const NONCE_LENGTH: usize = 24;
const TAG_LENGTH: usize = 16;
const HEADER_LENGTH: usize = 1 + 8 + 32 + 64 + 2;
const PLAINTEXT_LENGTH: usize = SEALED_LENGTH - NONCE_LENGTH - TAG_LENGTH;

/// SHA-256("SZFriends rendezvous key v1" || identity key): the name a person's records are kept under.
pub fn rendezvous_key(identity_key: &[u8; 32]) -> [u8; 32] {
    Sha256::new().chain_update(KEY_DOMAIN.as_bytes()).chain_update(identity_key).finalize().into()
}

fn seal_key(presence_secret: &[u8; 32]) -> Zeroizing<[u8; 32]> {
    Zeroizing::new(szfriends_crypto::blake2b::<32>(Some(presence_secret), &[SEAL_DOMAIN.as_bytes()]))
}

fn associated(rdv_key: &[u8; 32]) -> Vec<u8> {
    [SEAL_DOMAIN.as_bytes(), rdv_key].concat()
}

fn signed(rdv_key: &[u8; 32], window: i64, device_key: &[u8; 32], body: &[u8]) -> Vec<u8> {
    let mut message = rdv_key.to_vec();
    message.push(VERSION);
    message.extend_from_slice(&window.to_be_bytes());
    message.extend_from_slice(device_key);
    message.extend_from_slice(body);
    message
}

/// A freshly sealed blob (a new nonce every time). `person_key` is the identity key the rdv key derives from.
pub fn seal(
    device: &Identity,
    person_key: &[u8; 32],
    presence_secret: &[u8; 32],
    window: i64,
    items: &[Item],
) -> Option<Vec<u8>> {
    let rdv_key = rendezvous_key(person_key);
    let body = if items.is_empty() { Vec::new() } else { items::encode(items, BODY_MAX).ok()? };
    let device_key = device.public_key();
    let signature = device.sign(&signed(&rdv_key, window, &device_key, &body), SEAL_DOMAIN);
    let mut plaintext = Zeroizing::new(vec![0u8; PLAINTEXT_LENGTH]);
    plaintext[0] = VERSION;
    plaintext[1..9].copy_from_slice(&window.to_be_bytes());
    plaintext[9..41].copy_from_slice(&device_key);
    plaintext[41..105].copy_from_slice(&signature);
    plaintext[105..107].copy_from_slice(&(body.len() as u16).to_be_bytes());
    plaintext[HEADER_LENGTH..HEADER_LENGTH + body.len()].copy_from_slice(&body);
    let mut nonce = [0u8; NONCE_LENGTH];
    szfriends_crypto::random_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new_from_slice(seal_key(presence_secret).as_ref()).ok()?;
    let aad = associated(&rdv_key);
    let sealed = cipher.encrypt(XNonce::from_slice(&nonce), Payload { msg: &plaintext, aad: &aad }).ok()?;
    let mut out = nonce.to_vec();
    out.extend_from_slice(&sealed);
    (out.len() == SEALED_LENGTH).then_some(out)
}

/// What an opened record says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub device_key: [u8; 32],
    pub window: i64,
    pub items: Vec<Item>,
}

/// Opens a blob a lookup returned for `person_key`'s rdv key. `None` (filler looks the same) unless it decrypts,
/// names one of `device_keys`, verifies, and its window is `window` or next to it.
pub fn open(
    sealed: &[u8],
    person_key: &[u8; 32],
    presence_secret: &[u8; 32],
    device_keys: &[[u8; 32]],
    window: i64,
) -> Option<Record> {
    if sealed.len() != SEALED_LENGTH {
        return None;
    }
    let rdv_key = rendezvous_key(person_key);
    let cipher = XChaCha20Poly1305::new_from_slice(seal_key(presence_secret).as_ref()).ok()?;
    let aad = associated(&rdv_key);
    let (nonce, body) = sealed.split_at(NONCE_LENGTH);
    let plaintext = Zeroizing::new(cipher.decrypt(XNonce::from_slice(nonce), Payload { msg: body, aad: &aad }).ok()?);
    if plaintext.len() != PLAINTEXT_LENGTH || plaintext[0] != VERSION {
        return None;
    }
    let record_window = i64::from_be_bytes(plaintext[1..9].try_into().expect("8"));
    let body_length = usize::from(u16::from_be_bytes([plaintext[105], plaintext[106]]));
    if body_length > BODY_MAX || record_window < window - 1 || record_window > window + 1 {
        return None;
    }
    let device_key: [u8; 32] = plaintext[9..41].try_into().expect("32");
    let body = &plaintext[HEADER_LENGTH..HEADER_LENGTH + body_length];
    let message = signed(&rdv_key, record_window, &device_key, body);
    if !device_keys.contains(&device_key) || !verify(&plaintext[41..105], &message, SEAL_DOMAIN, &device_key) {
        return None;
    }
    let items = if body_length == 0 { Vec::new() } else { items::decode(body).ok()? };
    Some(Record { device_key, window: record_window, items })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_record_opens_only_with_its_secret_and_window() {
        let device = Identity::from_secrets(&[3; 32], &[4; 32]);
        let key = device.public_key();
        let secret = [9u8; 32];
        let blob = seal(&device, &key, &secret, 1000, &[Item::nat(1, 0)]).unwrap();
        assert_eq!(blob.len(), SEALED_LENGTH);
        let record = open(&blob, &key, &secret, &[key], 1001).unwrap();
        assert_eq!(record.items, vec![Item::nat(1, 0)]);
        assert!(open(&blob, &key, &[8; 32], &[key], 1000).is_none());
        assert!(open(&blob, &key, &secret, &[key], 1002).is_none());
        assert!(open(&blob, &key, &secret, &[[1; 32]], 1000).is_none());
        assert_ne!(seal(&device, &key, &secret, 1000, &[]).unwrap(), seal(&device, &key, &secret, 1000, &[]).unwrap());
    }
}
