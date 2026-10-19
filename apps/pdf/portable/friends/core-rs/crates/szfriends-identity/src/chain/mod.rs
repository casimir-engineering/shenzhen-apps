//! The device chain: one person, several computers (ADR 0012; `SZFriendsDeviceChain.h`). A person is their root key,
//! the Ed25519 identity key of their first device. The chain says which device keys speak for the root: a set of
//! signed links, each naming by hash the links its signer had seen, so concurrent branches merge by union and every
//! holder of the same links computes the same devices ([`rules`]). Byte for byte the helper's format: the suites
//! replay `fixtures/vectors/objc-chain.json`.

mod build;
mod link;
mod rules;

pub use build::DeviceChain;
pub use link::{ChainLink, LinkKind};

use unicode_segmentation::UnicodeSegmentation;

use crate::identity::{verify, Identity};

pub const LINK_DOMAIN: &str = "SZFriends chain link v1";
pub const CONSENT_DOMAIN: &str = "SZFriends device consent v1";
pub(crate) const HASH_DOMAIN: &str = "SZFriends chain hash v1";

/// One CHAIN frame holds a chain: 128 links of at most 495 encoded bytes.
pub const MAX_LINKS: usize = 128;
/// Renames stop here so adds and revocations always have room.
pub const RENAME_LIMIT: usize = 112;
pub const ENCODED_MAX: usize = 64_000;
pub const PARENTS_MAX: usize = 8;
pub const NAME_MAX: usize = 64;
pub const SYSTEM_MAX: usize = 64;

/// `SZFriendsDeviceChainError`, by the helper's codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChainError {
    /// Not a chain: lengths, version, a missing or later parent, a duplicate.
    Malformed = 1,
    /// A signature or a device's consent does not verify.
    Forged = 2,
    /// Signed by a key the chain had not added before that link.
    Unauthorized = 3,
    /// Adds a device that was revoked before: never re-added.
    RevokedDevice = 4,
    /// Another root, or another genesis for the same root (a fork).
    WrongRoot = 5,
    Full = 6,
    /// A builder asked for what the rules forbid.
    Refused = 7,
}

impl std::fmt::Display for ChainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for ChainError {}

/// `SZFriendsChainDeviceState`; no state is 0, so a missing device never reads as authorized.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeviceState {
    /// Speaks for the person: friends accept it, own devices sync with it.
    Authorized = 1,
    Revoked = 2,
    /// Added only by links rule 3 voids: not authorized, may be added again.
    Void = 3,
}

impl DeviceState {
    pub fn from_i64(value: i64) -> Option<Self> {
        match value {
            1 => Some(Self::Authorized),
            2 => Some(Self::Revoked),
            3 => Some(Self::Void),
            _ => None,
        }
    }
}

/// One device of a chain under the rules.
#[derive(Clone, Debug, PartialEq)]
pub struct ChainDevice {
    pub device_key: [u8; 32],
    pub static_key: [u8; 32],
    pub name: String,
    pub system: String,
    /// Unix seconds (the signer's milliseconds / 1000).
    pub added_at: f64,
    /// The earliest revocation that counts.
    pub revoked_at: Option<f64>,
    pub state: DeviceState,
    /// The first device, whose device key is the root key.
    pub is_root: bool,
}

fn is_control(c: char) -> bool {
    (c as u32) < 0x20 || (0x7f..=0x9f).contains(&(c as u32))
}

/// `SZFriendsChainLabel`: C0 and C1 controls removed, whitespace trimmed, then cut on a character (grapheme)
/// boundary to at most `max_bytes` of UTF-8.
pub fn chain_label(text: &str, max_bytes: usize) -> String {
    let stripped: String = text.chars().filter(|c| !is_control(*c)).collect();
    let trimmed = stripped.trim_matches(char::is_whitespace);
    let mut label = String::new();
    for grapheme in trimmed.graphemes(true) {
        if label.len() + grapheme.len() > max_bytes {
            break;
        }
        label.push_str(grapheme);
    }
    label
}

/// The joining device's consent to be added under `root_key`: its own signature over root || device || static key.
pub fn device_consent(device: &Identity, root_key: &[u8; 32]) -> [u8; 64] {
    let message = [&root_key[..], &device.public_key(), &device.static_public_key()].concat();
    device.sign(&message, CONSENT_DOMAIN)
}

pub fn verify_device_consent(consent: &[u8], device_key: &[u8], static_key: &[u8], root_key: &[u8]) -> bool {
    if root_key.len() != 32 || device_key.len() != 32 || static_key.len() != 32 {
        return false;
    }
    let message = [root_key, device_key, static_key].concat();
    verify(consent, &message, CONSENT_DOMAIN, device_key)
}

/// What a link's clock becomes: milliseconds, never before 1970 (`llround(max(seconds, 0) * 1000)`).
pub fn milliseconds(seconds: f64) -> u64 {
    (seconds.max(0.0) * 1000.0).round() as u64
}
