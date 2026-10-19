//! One link (`SZFriendsDeviceChainLink.m`):
//!
//! ```text
//! version u8 (1) | kind u8 | milliseconds u64be | parent count u8 | parents (32 each) | signer (32) | subject (32)
//! genesis, add:  static key (32) | name length u8 | name | system length u8 | system | consent (64)
//! rename:        name length u8 | name | system length u8 | system
//! then the signer's signature (64), domain "SZFriends chain link v1", over root key || every byte before it.
//! ```
//!
//! The hash children name is BLAKE2b-256("SZFriends chain hash v1" || the whole link).

use super::{
    chain_label, verify_device_consent, ChainError, HASH_DOMAIN, LINK_DOMAIN, NAME_MAX, PARENTS_MAX, SYSTEM_MAX,
};
use crate::identity::{verify, Identity};

const VERSION: u8 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkKind {
    Genesis = 0,
    Add = 1,
    Revoke = 2,
    Rename = 3,
}

impl LinkKind {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Genesis),
            1 => Some(Self::Add),
            2 => Some(Self::Revoke),
            3 => Some(Self::Rename),
            _ => None,
        }
    }

    fn carries_keys(self) -> bool {
        matches!(self, Self::Genesis | Self::Add)
    }

    fn carries_labels(self) -> bool {
        self != Self::Revoke
    }
}

/// One signed link, immutable.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChainLink {
    pub kind: LinkKind,
    pub parents: Vec<[u8; 32]>,
    pub signer: [u8; 32],
    pub subject: [u8; 32],
    pub static_key: Option<[u8; 32]>,
    pub consent: Option<[u8; 64]>,
    pub name: Option<String>,
    pub system: Option<String>,
    pub milliseconds: u64,
    pub hash: [u8; 32],
    pub encoded: Vec<u8>,
}

/// The fields of a link before it is signed.
pub(crate) struct LinkFields<'a> {
    pub kind: LinkKind,
    pub parents: &'a [[u8; 32]],
    pub subject: [u8; 32],
    pub static_key: Option<[u8; 32]>,
    pub consent: Option<[u8; 64]>,
    pub name: Option<&'a str>,
    pub system: Option<&'a str>,
    pub milliseconds: u64,
}

fn link_hash(encoded: &[u8]) -> [u8; 32] {
    szfriends_crypto::blake2b::<32>(None, &[HASH_DOMAIN.as_bytes(), encoded])
}

fn push_label(out: &mut Vec<u8>, label: &str) {
    out.push(label.len() as u8);
    out.extend_from_slice(label.as_bytes());
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        let slice = self.bytes.get(self.at..self.at.checked_add(count)?)?;
        self.at += count;
        Some(slice)
    }

    fn key(&mut self) -> Option<[u8; 32]> {
        self.take(32).map(|b| b.try_into().expect("32"))
    }

    /// 1 to `max` bytes of UTF-8 that cleaning would not change.
    fn label(&mut self, max: usize) -> Option<String> {
        let length = *self.take(1)?.first()? as usize;
        if length == 0 || length > max {
            return None;
        }
        let text = std::str::from_utf8(self.take(length)?).ok()?;
        (chain_label(text, max) == text).then(|| text.to_owned())
    }
}

impl ChainLink {
    pub(crate) fn signed(fields: LinkFields<'_>, signer: &Identity, root_key: &[u8; 32]) -> Result<Self, ChainError> {
        let kind = fields.kind;
        let name = fields.name.map(|n| chain_label(n, NAME_MAX));
        let system = fields.system.map(|s| chain_label(s, SYSTEM_MAX));
        let keys_ok = !kind.carries_keys() || (fields.static_key.is_some() && fields.consent.is_some());
        let labels_ok = !kind.carries_labels()
            || (name.as_deref().is_some_and(|n| !n.is_empty()) && system.as_deref().is_some_and(|s| !s.is_empty()));
        if !keys_ok || !labels_ok || fields.parents.len() > PARENTS_MAX {
            return Err(ChainError::Refused);
        }
        let mut encoded = vec![VERSION, kind as u8];
        encoded.extend_from_slice(&fields.milliseconds.to_be_bytes());
        encoded.push(fields.parents.len() as u8);
        for parent in fields.parents {
            encoded.extend_from_slice(parent);
        }
        encoded.extend_from_slice(&signer.public_key());
        encoded.extend_from_slice(&fields.subject);
        if kind.carries_keys() {
            encoded.extend_from_slice(&fields.static_key.expect("checked"));
        }
        if kind.carries_labels() {
            push_label(&mut encoded, name.as_deref().expect("checked"));
            push_label(&mut encoded, system.as_deref().expect("checked"));
        }
        if kind.carries_keys() {
            encoded.extend_from_slice(&fields.consent.expect("checked"));
        }
        let message = [&root_key[..], &encoded].concat();
        encoded.extend_from_slice(&signer.sign(&message, LINK_DOMAIN));
        Ok(Self {
            kind,
            parents: fields.parents.to_vec(),
            signer: signer.public_key(),
            subject: fields.subject,
            static_key: fields.static_key.filter(|_| kind.carries_keys()),
            consent: fields.consent.filter(|_| kind.carries_keys()),
            name: name.filter(|_| kind.carries_labels()),
            system: system.filter(|_| kind.carries_labels()),
            milliseconds: fields.milliseconds,
            hash: link_hash(&encoded),
            encoded,
        })
    }

    /// Parses one link and checks its own signature and consent against `root_key` (`None` for the genesis, which
    /// signs for itself).
    pub(crate) fn decode(data: &[u8], root_key: Option<&[u8; 32]>) -> Result<Self, ChainError> {
        let mut reader = Reader { bytes: data, at: 0 };
        let head = reader.take(2).ok_or(ChainError::Malformed)?;
        let time = reader.take(8).ok_or(ChainError::Malformed)?;
        let count = *reader.take(1).ok_or(ChainError::Malformed)?.first().expect("1") as usize;
        let kind = LinkKind::from_byte(head[1]).filter(|_| head[0] == VERSION).ok_or(ChainError::Malformed)?;
        let genesis = kind == LinkKind::Genesis;
        if if genesis { count != 0 } else { count == 0 || count > PARENTS_MAX } {
            return Err(ChainError::Malformed);
        }
        let milliseconds = u64::from_be_bytes(time.try_into().expect("8"));
        let mut parents: Vec<[u8; 32]> = Vec::with_capacity(count);
        for _ in 0..count {
            let parent = reader.key().ok_or(ChainError::Malformed)?;
            if parents.contains(&parent) {
                return Err(ChainError::Malformed);
            }
            parents.push(parent);
        }
        let signer = reader.key();
        let subject = reader.key();
        let static_key = if kind.carries_keys() { reader.key() } else { None };
        let name = if kind.carries_labels() { reader.label(NAME_MAX) } else { None };
        let system = if kind.carries_labels() { reader.label(SYSTEM_MAX) } else { None };
        let consent: Option<[u8; 64]> =
            if kind.carries_keys() { reader.take(64).map(|b| b.try_into().expect("64")) } else { None };
        let body_length = reader.at;
        let signature = reader.take(64);
        let fields_ok = signer.is_some()
            && subject.is_some()
            && signature.is_some()
            && (!kind.carries_keys() || (static_key.is_some() && consent.is_some()))
            && (!kind.carries_labels() || (name.is_some() && system.is_some()));
        if !fields_ok || reader.at != data.len() {
            return Err(ChainError::Malformed);
        }
        let (signer, subject, signature) = (signer.expect("ok"), subject.expect("ok"), signature.expect("ok"));
        if (genesis || kind == LinkKind::Rename) && signer != subject {
            return Err(ChainError::Unauthorized);
        }
        let root = if genesis { signer } else { *root_key.ok_or(ChainError::Malformed)? };
        if genesis && root_key.is_some_and(|r| *r != signer) {
            return Err(ChainError::WrongRoot);
        }
        let message = [&root[..], &data[..body_length]].concat();
        let consent_ok =
            consent.is_none_or(|c| verify_device_consent(&c, &subject, &static_key.expect("with consent"), &root));
        if !verify(signature, &message, LINK_DOMAIN, &signer) || !consent_ok {
            return Err(ChainError::Forged);
        }
        Ok(Self {
            kind,
            parents,
            signer,
            subject,
            static_key,
            consent,
            name,
            system,
            milliseconds,
            hash: link_hash(data),
            encoded: data.to_vec(),
        })
    }

    /// Unix seconds of the signer's clock.
    pub fn date(&self) -> f64 {
        self.milliseconds as f64 / 1000.0
    }

    pub(crate) fn adds(&self, key: &[u8; 32]) -> bool {
        matches!(self.kind, LinkKind::Genesis | LinkKind::Add) && &self.subject == key
    }
}
