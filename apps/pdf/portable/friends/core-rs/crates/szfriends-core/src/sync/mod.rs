//! Sync between one person's own devices (ADR 0014; `service/sync/`, `SZFriendsSync.h`). Every change becomes an
//! event signed by the device that made it, with its sequence number and a Lamport clock; devices exchange what the
//! other lacks over SYNC frames ([`exchange`]) and apply it under merge rules that give every order of arrival the
//! same store ([`apply`]). Local changes are found by comparing the store with what sync last recorded ([`capture`]).
//! Byte for byte the helper's encodings: `fixtures/vectors/objc-sync.json`.

pub mod again;
mod again_request;
mod again_serve;
mod apply;
pub mod bodies;
mod capture;
pub mod codec;
mod engine;
pub mod exchange;
mod files;
mod purge;
mod revocation;

pub use again::{again_state, set_again_state, AgainFile, AgainMessage};
pub use again_request::AgainRequester;
pub use again_serve::AgainServer;
pub use codec::{decode_vector, encode_vector, vector_covers, Event, Fields};
pub use engine::SyncEngine;
pub use exchange::SyncExchange;
pub use files::local_path_of_transfer;
pub use revocation::{adopt_own_devices_secret, own_devices_secret_in_store};

use crate::store::StoreError;

/// `SZFriendsSyncError`, by the helper's codes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncError {
    Malformed(&'static str),
    Forged(&'static str),
    /// An author our own chain does not hold.
    Unauthorized,
    /// An author's events with a gap.
    OutOfOrder,
    /// No own chain with another device yet, or this device left the profile.
    Inactive,
    Store(StoreError),
}

impl SyncError {
    pub fn code(&self) -> i64 {
        match self {
            Self::Malformed(_) => 1,
            Self::Forged(_) => 2,
            Self::Unauthorized => 3,
            Self::OutOfOrder => 4,
            Self::Inactive => 5,
            Self::Store(_) => 6,
        }
    }
}

impl std::fmt::Display for SyncError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for SyncError {}

impl From<StoreError> for SyncError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

/// `SZFriendsSyncKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Chain = 1,
    Profile = 2,
    Setting = 3,
    Person = 4,
    Item = 5,
    Read = 6,
    Outbox = 7,
    File = 8,
    FileHeld = 9,
    Tombstone = 10,
    Revocation = 11,
}

impl Kind {
    pub fn from_byte(byte: u8) -> Option<Self> {
        use Kind::*;
        [Chain, Profile, Setting, Person, Item, Read, Outbox, File, FileHeld, Tombstone, Revocation]
            .into_iter()
            .find(|k| *k as u8 == byte)
    }
}

/// One event fits one SYNC frame.
pub const BODY_MAX: usize = 60_000;
/// A SYNC frame's payload.
pub const MESSAGE_MAX: usize = 64_000;
/// Scope and subject.
pub const LABEL_MAX: usize = 80;
/// Files at most this large copy to the person's other devices by themselves; You's always.
pub const AUTO_COPY_MAX: u64 = 25_000_000;
pub const FILE_PART_MAX: usize = 48 * 1024;
/// An event whose clock is further than this ahead of ours is refused.
pub const LAMPORT_MARGIN: u64 = 1 << 32;
pub const SECRET_RENEWAL_WAIT: f64 = 600.0;
/// EVENTS messages in flight.
pub const WINDOW: usize = 4;

pub const GROUP_RELATION: &str = "relation";
pub const GROUP_PROFILE: &str = "profile";
pub const GROUP_KEYS: &str = "keys";
pub const GROUP_TRUST: &str = "trust";
/// The order capture walks a person's groups in.
pub const PERSON_GROUPS: [&str; 4] = [GROUP_RELATION, GROUP_KEYS, GROUP_PROFILE, GROUP_TRUST];

pub const SETTING_PRESENCE: &str = "presence";
pub const SETTING_DEVICES: &str = "devices";
pub const SETTING_RENEWED: &str = "renewed";
pub const STATE_DEVICES_SECRET: &str = "own_devices_secret";
pub const STATE_RENEWED: &str = "revocations_renewed_digest";
pub const STATE_PRESENCE_DRAWN: &str = "presence_drawn_here";
pub const STATE_PRESENCE_RETELL: &str = "presence_retell";

/// Body tag every body naming a conversation carries: the author's own id for it.
pub(crate) const TAG_CONVERSATION: u8 = 1;
/// FILE HELD: u64 1, the author no longer holds the bytes (ADR 0016). Absent: it holds them.
pub(crate) const TAG_RELEASED: u8 = 2;

pub fn copies_automatically(size: u64, conversation_id: &str) -> bool {
    size <= AUTO_COPY_MAX || conversation_id == crate::store::sync_log::YOU
}

fn keyed_secret(key: &[u8], domain: &str, device: &[u8]) -> Option<[u8; 32]> {
    (key.len() == 32 && device.len() == 32)
        .then(|| szfriends_crypto::blake2b::<32>(Some(key), &[domain.as_bytes(), device]))
}

/// The secret one of our devices advertises its nearby tags under: friends cannot match it.
pub fn device_tag_secret(own_devices_secret: &[u8], device_key: &[u8]) -> Option<[u8; 32]> {
    keyed_secret(own_devices_secret, "SZFriends own device v1", device_key)
}

/// The secret a person's device other than their first advertises under, so friends know which device they see.
pub fn friend_device_tag_secret(presence_secret: &[u8], device_key: &[u8]) -> Option<[u8; 32]> {
    keyed_secret(presence_secret, "SZFriends device presence v1", device_key)
}

/// Labels (scope, subject) are ids and prefixes: `[A-Za-z0-9_:/-]`, 0 to 80 bytes.
pub fn label_is_valid(label: &str) -> bool {
    label.len() <= LABEL_MAX
        && label.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-' | b':' | b'/'))
}

pub fn digest(data: &[u8]) -> [u8; 32] {
    szfriends_crypto::blake2b::<32>(None, &[data])
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Lowercase hex only, as the helper reads it.
pub(crate) fn from_hex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 || text.bytes().any(|c| !matches!(c, b'0'..=b'9' | b'a'..=b'f')) {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).ok()).collect()
}

/// Which conversation an event is about, as every device can name it: "you", "k:<root key hex>" or "c:<id>".
pub(crate) fn ref_for_person(person: &crate::store::sync_records::SyncPerson) -> String {
    if person.conversation_id == crate::store::sync_log::YOU {
        return person.conversation_id.clone();
    }
    match person.identity_key.as_deref().filter(|k| k.len() == 32) {
        Some(key) => format!("k:{}", hex(key)),
        None => format!("c:{}", person.conversation_id),
    }
}

pub(crate) fn person_key(conversation: &str, group: &str) -> String {
    format!("p/{conversation}/{group}")
}

pub(crate) fn read_key(conversation: &str) -> String {
    format!("r/{conversation}")
}

/// Last writer wins: whether (lamport, author) is later than what the register holds (absent: always).
pub(crate) fn is_later(lamport: u64, author: &[u8], current: Option<&crate::store::sync_log::Register>) -> bool {
    let Some(current) = current else { return true };
    if lamport != current.lamport {
        return lamport > current.lamport;
    }
    author != current.author.as_slice() && author > current.author.as_slice()
}
