//! Joining a profile from a new computer (ADR 0013; `SZFriendsJoin.h`, `SZFriendsJoinWire.m`): the request, the code
//! the approving computer shows, CPace over the NN session carrying the exchange, and the signed add link and profile
//! the new computer receives. Pure: no store, no clock (every `now` is Unix seconds passed in), no transport.
//!
//! A message is `version u8 (1) | kind u8 | fields`, each field `tag u8 | length u16be | value`, tags ascending and
//! each at most once, every field its kind requires and no other: one encoding per message.

mod approver;
mod joiner;

pub use approver::{welcome_parts, Approval, Approver, Receipt, RequestState, WaitingRequest, Welcome};
pub use joiner::{Attempt, Joiner, Step};

use std::collections::BTreeMap;

use unicode_segmentation::UnicodeSegmentation;

use crate::identity::{verify, Identity};

pub const CODE_DIGITS: usize = 8;
pub const ATTEMPTS_MAX: u32 = 3;
pub const CODE_LIFETIME: f64 = 300.0;
pub const OPEN_REQUESTS_MAX: usize = 3;
pub const NEW_REQUESTS_PER_HOUR: usize = 6;
pub const REQUEST_LIFETIME: f64 = 1800.0;
pub const CLOCK_SKEW_MAX: f64 = 600.0;
pub const MESSAGE_MAX: usize = 1000;
pub const PART_MAX: usize = 900;

const VERSION: u8 = 1;
const REQUEST_DOMAIN: &str = "SZFriends join request v1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageKind {
    Request = 1,
    Code = 2,
    Reply = 3,
    Confirm = 4,
    Part = 5,
    Ended = 6,
    /// Never sent whole: the welcome's Parts reassemble into it.
    Welcome = 7,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    Denied = 1,
    Expired = 2,
    TooManyAttempts = 3,
}

impl EndReason {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Denied),
            2 => Some(Self::Expired),
            3 => Some(Self::TooManyAttempts),
            _ => None,
        }
    }
}

/// Field tags (`SZFriendsJoinField`).
pub mod field {
    pub const REQUEST_ID: u8 = 1;
    pub const DEVICE_KEY: u8 = 2;
    pub const STATIC_KEY: u8 = 3;
    pub const NAME: u8 = 4;
    pub const SYSTEM: u8 = 5;
    pub const FRIENDS_ID: u8 = 6;
    pub const TIME: u8 = 7;
    pub const SIGNATURE: u8 = 8;
    pub const SHARE: u8 = 9;
    pub const ROOT_KEY: u8 = 10;
    pub const TAG: u8 = 11;
    pub const CONSENT: u8 = 12;
    pub const PART_INDEX: u8 = 13;
    pub const PART_COUNT: u8 = 14;
    pub const PART_DATA: u8 = 15;
    pub const REASON: u8 = 16;
    pub const CHAIN: u8 = 17;
    pub const PROFILE: u8 = 18;
    pub const ID_STATE: u8 = 19;
    pub const APPROVER_KEY: u8 = 20;
}

pub type Fields = BTreeMap<u8, Vec<u8>>;

fn bounds(tag: u8) -> Option<(usize, usize)> {
    Some(match tag {
        1 => (16, 16),
        2 | 3 | 9 | 10 | 11 | 20 => (32, 32),
        4..=6 => (1, 64),
        7 => (8, 8),
        8 | 12 => (64, 64),
        13 | 14 | 16 | 19 => (1, 1),
        15 => (1, PART_MAX),
        17 => (1, 64_000),
        18 => (1, 65_535),
        _ => return None,
    })
}

fn fields_of(kind: MessageKind) -> &'static [u8] {
    match kind {
        MessageKind::Request => &[1, 2, 3, 4, 5, 6, 7, 8],
        MessageKind::Code => &[field::REQUEST_ID, field::SHARE],
        MessageKind::Reply => &[field::SHARE, field::ROOT_KEY, field::TAG, field::APPROVER_KEY],
        MessageKind::Confirm => &[field::TAG, field::CONSENT],
        MessageKind::Part => &[field::PART_INDEX, field::PART_COUNT, field::PART_DATA],
        MessageKind::Ended => &[field::REASON],
        MessageKind::Welcome => &[field::TAG, field::CHAIN, field::PROFILE, field::ID_STATE],
    }
}

/// `NSCharacterSet.controlCharacterSet`: general categories Cc and Cf.
fn is_control_or_format(c: char) -> bool {
    let u = c as u32;
    c.is_control()
        || matches!(u, 0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E | 0x200B..=0x200F)
        || matches!(u, 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB)
        || matches!(u, 0x110BD | 0x110CD | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A)
        || matches!(u, 0xE0001 | 0xE0020..=0xE007F)
}

/// `whitespaceCharacterSet`: Zs and tab.
fn is_space(c: char) -> bool {
    matches!(c as u32, 0x09 | 0x20 | 0xA0 | 0x1680 | 0x2000..=0x200A | 0x202F | 0x205F | 0x3000)
}

/// Names are shown on the person's other computers: valid UTF-8 and no control characters.
fn label_is_clean(bytes: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(bytes) else { return false };
    !text.is_empty() && !text.chars().any(is_control_or_format) && !text.trim_matches(is_space).is_empty()
}

fn field_is_valid(tag: u8, value: &[u8]) -> bool {
    let Some((min, max)) = bounds(tag) else { return false };
    if value.len() < min || value.len() > max {
        return false;
    }
    match tag {
        field::NAME | field::SYSTEM | field::FRIENDS_ID => label_is_clean(value),
        field::PART_COUNT => value[0] >= 1,
        _ => true,
    }
}

/// Canonical encoding; `None` for a field outside its bounds or one the kind does not take.
pub fn encode(kind: MessageKind, fields: &Fields) -> Option<Vec<u8>> {
    let tags = fields_of(kind);
    if fields.len() != tags.len() {
        return None;
    }
    let mut out = vec![VERSION, kind as u8];
    for tag in tags {
        let value = fields.get(tag)?;
        if !field_is_valid(*tag, value) {
            return None;
        }
        out.push(*tag);
        out.extend_from_slice(&(value.len() as u16).to_be_bytes());
        out.extend_from_slice(value);
    }
    Some(out)
}

/// Strict decoding of a message of `kind`.
pub fn decode(message: &[u8], kind: MessageKind) -> Option<Fields> {
    let tags = fields_of(kind);
    if message.len() < 2 || message[0] != VERSION || message[1] != kind as u8 {
        return None;
    }
    if kind != MessageKind::Welcome && message.len() > MESSAGE_MAX {
        return None;
    }
    let mut fields = Fields::new();
    let mut offset = 2;
    let mut previous: i32 = -1;
    while offset < message.len() {
        if message.len() - offset < 3 {
            return None;
        }
        let tag = message[offset];
        let size = u16::from_be_bytes([message[offset + 1], message[offset + 2]]) as usize;
        offset += 3;
        if i32::from(tag) <= previous || size > message.len() - offset || !tags.contains(&tag) {
            return None;
        }
        let value = &message[offset..offset + size];
        if !field_is_valid(tag, value) {
            return None;
        }
        fields.insert(tag, value.to_vec());
        previous = i32::from(tag);
        offset += size;
    }
    (fields.len() == tags.len()).then_some(fields)
}

/// The kind of a message this version reads (Request to Ended), or `None`.
pub fn message_kind(message: &[u8]) -> Option<MessageKind> {
    if message.len() < 2 || message[0] != VERSION {
        return None;
    }
    use MessageKind::*;
    [Request, Code, Reply, Confirm, Part, Ended].into_iter().find(|k| *k as u8 == message[1])
}

pub fn ended_message(reason: EndReason) -> Vec<u8> {
    encode(MessageKind::Ended, &Fields::from([(field::REASON, vec![reason as u8])])).expect("valid")
}

pub fn end_reason(message: &[u8]) -> Option<EndReason> {
    decode(message, MessageKind::Ended)?.get(&field::REASON).and_then(|r| EndReason::from_byte(r[0]))
}

/// A fresh code: eight decimal digits, uniformly drawn.
pub fn new_code() -> String {
    // randombytes_uniform: reject the top values that would bias the modulo.
    const BOUND: u32 = 100_000_000;
    let min = (u32::MAX - BOUND + 1) % BOUND;
    loop {
        let mut bytes = [0u8; 4];
        szfriends_crypto::random_bytes(&mut bytes);
        let value = u32::from_le_bytes(bytes);
        if value >= min {
            return format!("{:08}", value % BOUND);
        }
    }
}

/// What the person typed, as a code: digits (full-width allowed) with spaces and dashes between, or `None`.
pub fn normalized_code(typed: &str) -> Option<String> {
    const SEPARATORS: [u32; 7] = [0x20, 0x2d, 0xa0, 0x2009, 0x202f, 0x2011, 0x3000];
    let mut digits = String::new();
    for grapheme in typed.graphemes(true) {
        let mut chars = grapheme.chars();
        let c = match (chars.next(), chars.next()) {
            (Some(c), None) if (c as u32) <= 0xFFFF => c as u32,
            _ => return None,
        };
        if (0x30..=0x39).contains(&c) {
            digits.push(char::from_u32(c).expect("digit"));
        } else if (0xFF10..=0xFF19).contains(&c) {
            digits.push(char::from_u32(c - 0xFEE0).expect("digit"));
        } else if !SEPARATORS.contains(&c) {
            return None;
        }
    }
    (digits.len() == CODE_DIGITS).then_some(digits)
}

pub use szfriends_crypto::cpace::join::{
    approver_ad, channel_identifier, tag, tags_equal, INITIATOR_TAG_DOMAIN, RESPONDER_TAG_DOMAIN, WELCOME_TAG_DOMAIN,
};

/// The request's fields without the signature, in order, each as tag || length || value.
fn signed_part(fields: &Fields) -> Vec<u8> {
    let mut out = Vec::new();
    for tag in field::REQUEST_ID..field::SIGNATURE {
        let value = fields.get(&tag).map(Vec::as_slice).unwrap_or_default();
        out.push(tag);
        out.extend_from_slice(&(value.len() as u16).to_be_bytes());
        out.extend_from_slice(value);
    }
    out
}

/// A signed request from `device` for the profile holding `friends_id`; `None` for a label outside its bounds.
pub fn request_message(
    device: &Identity,
    request_id: &[u8; 16],
    friends_id: &str,
    name: &str,
    system: &str,
    now: f64,
) -> Option<Vec<u8>> {
    let millis = (now * 1000.0).round() as i64 as u64;
    let mut fields = Fields::from([
        (field::REQUEST_ID, request_id.to_vec()),
        (field::DEVICE_KEY, device.public_key().to_vec()),
        (field::STATIC_KEY, device.static_public_key().to_vec()),
        (field::NAME, name.as_bytes().to_vec()),
        (field::SYSTEM, system.as_bytes().to_vec()),
        (field::FRIENDS_ID, friends_id.as_bytes().to_vec()),
        (field::TIME, millis.to_be_bytes().to_vec()),
    ]);
    fields.insert(field::SIGNATURE, device.sign(&signed_part(&fields), REQUEST_DOMAIN).to_vec());
    encode(MessageKind::Request, &fields)
}

/// A request message's fields once its signature verified.
pub fn verified_request(message: &[u8]) -> Option<Fields> {
    let fields = decode(message, MessageKind::Request)?;
    verify(&fields[&field::SIGNATURE], &signed_part(&fields), REQUEST_DOMAIN, &fields[&field::DEVICE_KEY])
        .then_some(fields)
}

pub(crate) fn key32(fields: &Fields, tag: u8) -> [u8; 32] {
    fields[&tag].as_slice().try_into().expect("bounds checked")
}

pub(crate) fn text(fields: &Fields, tag: u8) -> String {
    String::from_utf8(fields[&tag].clone()).expect("checked UTF-8")
}
