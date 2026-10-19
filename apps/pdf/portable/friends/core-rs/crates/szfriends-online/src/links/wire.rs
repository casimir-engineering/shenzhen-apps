//! A download link's keys, setup payloads, records and metadata (`SZFriendsLinkRecords.m`; PROTOCOL.md § Links,
//! Browser downloads): byte for byte what the link pages do with WebCrypto (`server/friends/src/pages/script/`).
//! Every key is HKDF-SHA-256 of the link secret, 32 bytes:
//!
//! | Key | Salt | Info |
//! |---|---|---|
//! | setup | link id | `SZFriends link setup v1` |
//! | proof | link id | `SZFriends link proof v1` |
//! | session | n_o ‖ n_s | `SZFriends link session v1` |
//! | content(a) | n_o ‖ n_s | `SZFriends link content v1` ‖ a |

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use hmac::{Hmac, Mac};
use serde_json::{Map, Value};
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::b64;

pub const NONCE_LENGTH: usize = 16;
pub const RECORD_MAX: usize = 65536;
pub const CHUNK_BYTES: usize = 65280;
pub const CREDIT_MAX: u64 = 1024;
const SETUP_LABEL: &[u8] = b"SZFriends link setup v1";
const PROOF_LABEL: &[u8] = b"SZFriends link proof v1";
const SESSION_LABEL: &[u8] = b"SZFriends link session v1";
const CONTENT_LABEL: &[u8] = b"SZFriends link content v1";
const RECORD_LABEL: &[u8] = b"SZFriends link record v1";
const IV_LENGTH: usize = 12;
const TAG_LENGTH: usize = 16;

pub const SIDE_OPENER: u8 = 0x4f;
pub const SIDE_SENDER: u8 = 0x53;

pub mod record_type {
    pub const METADATA: u8 = 0x4d;
    pub const CHUNK: u8 = 0x43;
    pub const FINAL: u8 = 0x46;
    pub const END: u8 = 0x45;
    pub const CONTROL: u8 = 0x51;
}

type HmacSha256 = Hmac<Sha256>;

/// HKDF-SHA-256 (RFC 5869), 32 bytes: WebCrypto's deriveBits({name: "HKDF", hash: "SHA-256", salt, info}, 256).
pub fn hkdf(secret: &[u8], salt: &[u8], info: &[u8]) -> Zeroizing<[u8; 32]> {
    let mut extract = <HmacSha256 as Mac>::new_from_slice(salt).expect("any key length");
    extract.update(secret);
    let prk: Zeroizing<[u8; 32]> = Zeroizing::new(extract.finalize().into_bytes().into());
    let mut expand = <HmacSha256 as Mac>::new_from_slice(&prk[..]).expect("any key length");
    expand.update(info);
    expand.update(&[1]);
    Zeroizing::new(expand.finalize().into_bytes().into())
}

fn seal(key: &[u8; 32], iv: &[u8; IV_LENGTH], aad: &[u8], plaintext: &[u8]) -> Option<Vec<u8>> {
    let cipher = Aes256Gcm::new_from_slice(key).ok()?;
    cipher.encrypt(Nonce::from_slice(iv), Payload { msg: plaintext, aad }).ok()
}

fn open(key: &[u8; 32], iv: &[u8], aad: &[u8], sealed: &[u8]) -> Option<Vec<u8>> {
    let cipher = Aes256Gcm::new_from_slice(key).ok()?;
    cipher.decrypt(Nonce::from_slice(iv), Payload { msg: sealed, aad }).ok()
}

/// One link's keys, for one opening.
pub struct LinkKeys {
    pub link_id: [u8; 16],
    secret: Zeroizing<[u8; 32]>,
    setup: Zeroizing<[u8; 32]>,
    proof: Zeroizing<[u8; 32]>,
    session: Option<Zeroizing<[u8; 32]>>,
    nonces: Option<([u8; NONCE_LENGTH], [u8; NONCE_LENGTH])>,
}

impl std::fmt::Debug for LinkKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinkKeys").field("session", &self.session.is_some()).finish()
    }
}

impl LinkKeys {
    pub fn new(link_id: [u8; 16], secret: &[u8; 32]) -> Self {
        Self {
            link_id,
            secret: Zeroizing::new(*secret),
            setup: hkdf(secret, &link_id, SETUP_LABEL),
            proof: hkdf(secret, &link_id, PROOF_LABEL),
            session: None,
            nonces: None,
        }
    }

    pub fn has_session(&self) -> bool {
        self.session.is_some()
    }

    pub fn set_nonces(&mut self, opener: [u8; NONCE_LENGTH], sender: [u8; NONCE_LENGTH]) {
        let salt = [opener, sender].concat();
        self.session = Some(hkdf(self.secret.as_ref(), &salt, SESSION_LABEL));
        self.nonces = Some((opener, sender));
    }

    fn key(&self) -> &[u8; 32] {
        self.session.as_deref().unwrap_or(&self.setup)
    }

    fn aad(&self, side: u8) -> Vec<u8> {
        [SETUP_LABEL, &[side], &self.link_id].concat()
    }

    /// Seals one JSON object (with a string "t") as `side`.
    pub fn seal_message(&self, message: &Map<String, Value>, side: u8) -> Option<Vec<u8>> {
        message.get("t")?.as_str()?;
        let json = Value::Object(message.clone()).to_string();
        let mut iv = [0u8; IV_LENGTH];
        szfriends_crypto::random_bytes(&mut iv);
        let mut out = iv.to_vec();
        out.extend(seal(self.key(), &iv, &self.aad(side), json.as_bytes())?);
        Some(out)
    }

    /// A payload the other side sealed: the object, when it opens under the current key and has a string "t".
    pub fn open_message(&self, payload: &[u8], side: u8) -> Option<Map<String, Value>> {
        if payload.len() < IV_LENGTH + TAG_LENGTH {
            return None;
        }
        let plain = open(self.key(), &payload[..IV_LENGTH], &self.aad(side), &payload[IV_LENGTH..])?;
        let Value::Object(object) = serde_json::from_slice(&plain).ok()? else { return None };
        object.get("t")?.as_str()?;
        Some(object)
    }

    /// HMAC-SHA-256 under the proof key over the label, the link id, the sender's nonce and the opener's.
    pub fn proof(&self) -> Option<[u8; 32]> {
        let (opener, sender) = self.nonces?;
        let mut mac = <HmacSha256 as Mac>::new_from_slice(self.proof.as_ref()).expect("any key length");
        for part in [PROOF_LABEL, &self.link_id, &sender, &opener] {
            mac.update(part);
        }
        Some(mac.finalize().into_bytes().into())
    }

    /// Constant time.
    pub fn verify_proof(&self, proof: &[u8]) -> bool {
        let Some(expected) = self.proof() else { return false };
        proof.len() == 32 && expected.iter().zip(proof).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
    }

    pub fn content_key(&self, attempt: u8) -> Option<Zeroizing<[u8; 32]>> {
        let (opener, sender) = self.nonces?;
        let salt = [opener, sender].concat();
        Some(hkdf(self.secret.as_ref(), &salt, &[CONTENT_LABEL, &[attempt]].concat()))
    }
}

fn record_nonce(kind: u8, index: u64) -> [u8; IV_LENGTH] {
    let mut nonce = [0u8; IV_LENGTH];
    nonce[0] = kind;
    nonce[4..].copy_from_slice(&index.to_be_bytes());
    nonce
}

/// One record: its type, then AES-256-GCM under the content key with the nonce `type || 0 0 0 || u64be index`.
pub fn seal_record(key: &[u8; 32], kind: u8, index: u64, plaintext: &[u8]) -> Option<Vec<u8>> {
    if 1 + plaintext.len() + TAG_LENGTH > RECORD_MAX {
        return None;
    }
    let mut out = vec![kind];
    out.extend(seal(key, &record_nonce(kind, index), RECORD_LABEL, plaintext)?);
    Some(out)
}

/// The plaintext of `record` when its type is one of `kinds` and it opens at `index`, with its type.
pub fn open_record(key: &[u8; 32], kinds: &[u8], index: u64, record: &[u8]) -> Option<(u8, Vec<u8>)> {
    if record.len() < 1 + TAG_LENGTH || record.len() > RECORD_MAX || !kinds.contains(&record[0]) {
        return None;
    }
    let plain = open(key, &record_nonce(record[0], index), RECORD_LABEL, &record[1..])?;
    Some((record[0], plain))
}

/// Who sent a link, for an app opening it: the identity key, Friends ID, the file's BLAKE2b and the signature.
pub type Sender = ([u8; 32], String, [u8; 32], [u8; 64]);

/// The metadata record's plaintext: u32be JSON length, the JSON, then the thumbnail's PNG when it fits.
#[derive(Clone, Debug, Default)]
pub struct Metadata {
    pub name: String,
    pub size: u64,
    pub media_type: String,
    pub sha256: [u8; 32],
    pub sender: String,
    pub thumbnail: Option<Vec<u8>>,
    /// "from": the sender's identity key, Friends ID, the file's BLAKE2b and the signature over them.
    pub from: Option<Sender>,
}

impl Metadata {
    fn plaintext(&self, thumbnail: bool) -> Vec<u8> {
        let media_type = if self.media_type.is_empty() { "application/octet-stream" } else { &self.media_type };
        let mut object = serde_json::json!({
            "name": self.name, "size": self.size, "type": media_type,
            "sha256": b64::encode_url(&self.sha256), "sender": self.sender,
        });
        if let Some((key, friends_id, blake2b, sig)) = &self.from {
            object["from"] = serde_json::json!({
                "identity_key": b64::encode_url(key), "friends_id": friends_id,
                "blake2b": b64::encode_url(blake2b), "sig": b64::encode_url(sig),
            });
        }
        let json = object.to_string();
        let mut plain = (json.len() as u32).to_be_bytes().to_vec();
        plain.extend_from_slice(json.as_bytes());
        if thumbnail {
            if let Some(png) = &self.thumbnail {
                plain.extend_from_slice(png);
            }
        }
        plain
    }

    /// `None` when it would not fit one record (the thumbnail is left out first).
    pub fn record_plaintext(&self) -> Option<Vec<u8>> {
        let room = RECORD_MAX - 1 - TAG_LENGTH;
        let plain = self.plaintext(true);
        let plain = if plain.len() > room { self.plaintext(false) } else { plain };
        (plain.len() <= room).then_some(plain)
    }

    /// What the sender signs (domain "SZFriends link sender v1"): link id, SHA-256, BLAKE2b, u64be size, then the
    /// name, the Friends ID and the sender's name, each u32be-length-prefixed.
    pub fn signed_bytes(
        link_id: &[u8; 16],
        sha256: &[u8; 32],
        blake2b: &[u8; 32],
        size: u64,
        texts: [&str; 3],
    ) -> Vec<u8> {
        let mut bytes = [&link_id[..], sha256, blake2b, &size.to_be_bytes()].concat();
        for text in texts {
            bytes.extend_from_slice(&(text.len() as u32).to_be_bytes());
            bytes.extend_from_slice(text.as_bytes());
        }
        bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hkdf_matches_rfc_5869_case_one() {
        let ikm = [0x0bu8; 22];
        let salt: Vec<u8> = (0..=12).collect();
        let info: Vec<u8> = (0xf0..=0xf9).collect();
        let okm = hkdf(&ikm, &salt, &info);
        assert_eq!(hex::encode(&okm[..]), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf");
    }

    #[test]
    fn setup_payloads_and_records_round_trip() {
        let mut sender = LinkKeys::new([1; 16], &[2; 32]);
        let mut opener = LinkKeys::new([1; 16], &[2; 32]);
        let hello: Map<String, Value> = serde_json::from_str(r#"{"t":"hello","v":1}"#).unwrap();
        let sealed = opener.seal_message(&hello, SIDE_OPENER).unwrap();
        assert_eq!(sender.open_message(&sealed, SIDE_OPENER), Some(hello));
        assert!(sender.open_message(&sealed, SIDE_SENDER).is_none());
        sender.set_nonces([3; 16], [4; 16]);
        opener.set_nonces([3; 16], [4; 16]);
        assert!(sender.verify_proof(&opener.proof().unwrap()));
        let key = sender.content_key(1).unwrap();
        let record = seal_record(&key, record_type::CHUNK, 5, b"bytes").unwrap();
        assert_eq!(open_record(&key, &[record_type::CHUNK], 5, &record), Some((record_type::CHUNK, b"bytes".to_vec())));
        assert!(open_record(&key, &[record_type::CHUNK], 6, &record).is_none());
        assert!(open_record(&key, &[record_type::FINAL], 5, &record).is_none());
    }
}
