//! Per-type field rules (`SZFriendsFrameSchema.m`). Limits are format bounds, not product rules: the codec refuses
//! what no honest peer sends before anything is allocated; the store and presentation apply product rules later.

use crate::consts::{
    ATTESTATION_MAX, CHUNK_BYTES_WIFI, FRAME_AGAIN_MAX, FRAME_CHAIN_MAX, FRAME_JOIN_MAX, FRAME_PICTURE_MAX,
    FRAME_SYNC_MAX, FRAME_TEXT_MAX, FRAME_THUMBNAIL_MAX, HASHES_PER_FRAME, LEAF_BYTES, PART_BYTES_MAX,
    RANGES_PER_FIELD,
};
use crate::types::{tag, FrameType};

/// The field must be present.
pub const REQUIRED: u8 = 1 << 0;
/// One byte, 0 or 1.
pub const BOOLEAN: u8 = 1 << 1;
/// A list of 16-byte IDs.
pub const MULTIPLE_OF_16: u8 = 1 << 2;
/// A list of 32-byte hashes.
pub const MULTIPLE_OF_32: u8 = 1 << 3;
/// A list of 8-byte block ranges.
pub const MULTIPLE_OF_8: u8 = 1 << 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FieldRule {
    pub tag: u8,
    pub min: u16,
    pub max: u16,
    pub flags: u8,
}

impl FieldRule {
    pub fn allows(&self, value: &[u8]) -> bool {
        let length = value.len();
        if length < self.min as usize || length > self.max as usize {
            return false;
        }
        if self.flags & BOOLEAN != 0 && value[0] > 1 {
            return false;
        }
        !((self.flags & MULTIPLE_OF_16 != 0 && length % 16 != 0)
            || (self.flags & MULTIPLE_OF_32 != 0 && length % 32 != 0)
            || (self.flags & MULTIPLE_OF_8 != 0 && length % 8 != 0))
    }

    pub fn required(&self) -> bool {
        self.flags & REQUIRED != 0
    }
}

const fn rule(tag: u8, min: usize, max: usize, flags: u8) -> FieldRule {
    FieldRule { tag, min: min as u16, max: max as u16, flags }
}

const NAME_MAX: usize = 1024;
const FILE_TYPE_MAX: usize = 256;
const FRIENDS_ID_MAX: usize = 64;
const OFFER_IDS_MAX: usize = 20 * 16;
const ID: FieldRule = rule(tag::ID, 16, 16, REQUIRED);

const PROFILE: &[FieldRule] = &[
    rule(tag::NAME, 0, NAME_MAX, 0),
    rule(tag::FRIENDS_ID, 0, FRIENDS_ID_MAX, 0),
    rule(tag::PICTURE_SET, 2, 2, 0),
    rule(tag::PICTURE_INDEX, 2, 2, 0),
    rule(tag::DATA, 1, FRAME_PICTURE_MAX, 0),
    rule(tag::ATTESTATION, 1, ATTESTATION_MAX, 0),
];
const PRESENCE_SECRET: &[FieldRule] = &[ID, rule(tag::SECRET, 32, 32, REQUIRED)];
const REQUEST: &[FieldRule] = &[ID, rule(tag::SENT_AT, 8, 8, REQUIRED), rule(tag::TEXT, 0, FRAME_TEXT_MAX, 0)];
const ID_ONLY: &[FieldRule] = &[ID];
const ID_AND_REASON: &[FieldRule] = &[ID, rule(tag::REASON, 1, 1, 0)];
const REQUEST_BY_ID: &[FieldRule] = &[
    rule(tag::FRIENDS_ID, 1, FRIENDS_ID_MAX, REQUIRED),
    rule(tag::TOKEN, 16, 16, REQUIRED),
    rule(tag::CALLBACK_SECRET, 32, 32, REQUIRED),
    rule(tag::CERTIFICATE, 96, 96, REQUIRED),
    rule(tag::STATIC_KEY, 32, 32, REQUIRED),
    rule(tag::SIGNATURE, 64, 64, REQUIRED),
    rule(tag::INVITE_PROOF, 32, 32, 0),
];
const CODE_COMMIT: &[FieldRule] = &[rule(tag::COMMITMENT, 32, 32, REQUIRED)];
const CODE_NONCE: &[FieldRule] = &[rule(tag::NONCE, 32, 32, REQUIRED)];
const MESSAGE: &[FieldRule] = &[
    ID,
    rule(tag::SENT_AT, 8, 8, REQUIRED),
    rule(tag::TEXT, 0, FRAME_TEXT_MAX, 0),
    rule(tag::OFFER_IDS, 16, OFFER_IDS_MAX, MULTIPLE_OF_16),
    rule(tag::VIA_ASSISTANT, 1, 1, BOOLEAN),
];
const OFFER: &[FieldRule] = &[
    ID,
    rule(tag::NAME, 1, NAME_MAX, REQUIRED),
    rule(tag::FILE_TYPE, 0, FILE_TYPE_MAX, 0),
    rule(tag::SIZE, 8, 8, REQUIRED),
    rule(tag::DIGEST, 32, 32, REQUIRED),
    rule(tag::VIA_ASSISTANT, 1, 1, BOOLEAN),
    rule(tag::TREE_ROOT, 32, 32, 0),
    rule(tag::BLOCK_SHIFT, 1, 1, 0),
];
const OFFER_REPLY: &[FieldRule] =
    &[ID, rule(tag::ACCEPT, 1, 1, REQUIRED | BOOLEAN), rule(tag::OFFSET, 8, 8, 0), rule(tag::BLOCKS, 1, 1, BOOLEAN)];
const CHUNK: &[FieldRule] = &[ID, rule(tag::OFFSET, 8, 8, REQUIRED), rule(tag::DATA, 1, CHUNK_BYTES_WIFI, REQUIRED)];
const PROGRESS: &[FieldRule] = &[ID, rule(tag::OFFSET, 8, 8, REQUIRED)];
const DONE: &[FieldRule] = &[ID, rule(tag::DIGEST, 32, 32, REQUIRED)];
const CLOSE: &[FieldRule] = &[rule(tag::REASON, 1, 1, 0)];
const THUMBNAIL: &[FieldRule] = &[
    ID,
    rule(tag::WIDTH, 2, 2, REQUIRED),
    rule(tag::HEIGHT, 2, 2, REQUIRED),
    rule(tag::DATA, 23, FRAME_THUMBNAIL_MAX, REQUIRED),
];
const CHAIN: &[FieldRule] = &[rule(tag::CHAIN, 3, FRAME_CHAIN_MAX, REQUIRED)];
const JOIN: &[FieldRule] = &[rule(tag::JOIN, 1, FRAME_JOIN_MAX, REQUIRED)];
const SYNC: &[FieldRule] = &[rule(tag::SYNC, 1, FRAME_SYNC_MAX, REQUIRED)];
const AGAIN: &[FieldRule] = &[rule(tag::AGAIN, 1, FRAME_AGAIN_MAX, REQUIRED)];
const RANGES_MAX: usize = RANGES_PER_FIELD * 8;
const HASHES: &[FieldRule] = &[
    ID,
    rule(tag::INDEX, 4, 4, REQUIRED),
    rule(tag::HASHES, LEAF_BYTES, HASHES_PER_FRAME * LEAF_BYTES, REQUIRED | MULTIPLE_OF_32),
];
const WANT: &[FieldRule] = &[ID, rule(tag::RANGES, 8, RANGES_MAX, REQUIRED | MULTIPLE_OF_8)];
const PART: &[FieldRule] = &[
    ID,
    rule(tag::OFFSET, 8, 8, REQUIRED),
    rule(tag::DATA, 1, PART_BYTES_MAX, REQUIRED),
    rule(tag::CODEC, 1, 1, 0),
    rule(tag::LENGTH, 4, 4, 0),
];
const HAVE: &[FieldRule] =
    &[ID, rule(tag::RANGES, 8, RANGES_MAX, MULTIPLE_OF_8), rule(tag::DURABLE, 8, RANGES_MAX, MULTIPLE_OF_8)];

/// Every field any handshake payload may carry; which ones a given message needs is the channel's check.
pub const HANDSHAKE_PAYLOAD: &[FieldRule] = &[
    rule(tag::NAME, 0, NAME_MAX, 0),
    rule(tag::PICTURE_SET, 2, 2, 0),
    rule(tag::PICTURE_INDEX, 2, 2, 0),
    rule(tag::DATA, 1, FRAME_PICTURE_MAX, 0),
    rule(tag::FRIENDS_ID, 0, FRIENDS_ID_MAX, 0),
    rule(tag::TOKEN, 16, 16, 0),
    rule(tag::CERTIFICATE, 96, 96, 0),
    rule(tag::MINOR_MIN, 2, 2, 0),
    rule(tag::MINOR_MAX, 2, 2, 0),
    rule(tag::CAPABILITIES, 4, 4, 0),
    rule(tag::ROUTE_CLASS, 1, 1, 0),
    rule(tag::ATTESTATION, 1, ATTESTATION_MAX, 0),
    rule(tag::LANE, 16, 16, 0),
];

/// The rules for a frame type. HELLO, RECEIVED, REKEY and PING define no fields: RECEIVED is fixed-size on purpose,
/// so every device's reply is byte-identical (ADR 0004).
pub fn for_type(frame_type: FrameType) -> &'static [FieldRule] {
    use FrameType::*;
    match frame_type {
        Hello | Received | Rekey | Ping => &[],
        Profile => PROFILE,
        PresenceSecret => PRESENCE_SECRET,
        Request => REQUEST,
        Accept | Ack => ID_ONLY,
        Decline | Cancel => ID_AND_REASON,
        RequestById => REQUEST_BY_ID,
        CodeCommit => CODE_COMMIT,
        CodeNonce | CodeReveal => CODE_NONCE,
        Message => MESSAGE,
        Offer => OFFER,
        OfferReply => OFFER_REPLY,
        Chunk => CHUNK,
        Progress => PROGRESS,
        Done => DONE,
        Close => CLOSE,
        Thumbnail => THUMBNAIL,
        Chain => CHAIN,
        Join => JOIN,
        Sync => SYNC,
        Again => AGAIN,
        Hashes => HASHES,
        Want => WANT,
        Part => PART,
        Have => HAVE,
    }
}

/// The rule for `tag` within `rules`, or `None` when that type does not define the tag.
pub fn find(rules: &[FieldRule], tag: u8) -> Option<&FieldRule> {
    rules.iter().find(|rule| rule.tag == tag)
}
