//! Wire enumerations: handshake patterns, frame types, field tags and close reasons (`SZFriendsSession.h`).

/// The three Noise patterns Friends uses. The value is also the preamble's pattern byte.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Pattern {
    /// First contact: friend requests, and public entries during visibility.
    XX = 0,
    /// A known friend, or the holder's callback after Add by ID presenting its token.
    IK = 1,
    /// Add by ID nearby and joining: encrypted, reveals no static key on either side.
    NN = 2,
}

impl Pattern {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::XX),
            1 => Some(Self::IK),
            2 => Some(Self::NN),
            _ => None,
        }
    }

    /// The Noise protocol name, `Noise_<pattern>_25519_ChaChaPoly_BLAKE2b`.
    pub fn protocol_name(self) -> &'static str {
        match self {
            Self::XX => "Noise_XX_25519_ChaChaPoly_BLAKE2b",
            Self::IK => "Noise_IK_25519_ChaChaPoly_BLAKE2b",
            Self::NN => "Noise_NN_25519_ChaChaPoly_BLAKE2b",
        }
    }

    /// The Noise protocol name with `cipher`: `Noise_IK_25519_AESGCM_BLAKE2b` for an AES-GCM lane (ADR 0018 § 9.2).
    pub fn protocol_name_with(self, cipher: NoiseCipher) -> &'static str {
        match (self, cipher) {
            (_, NoiseCipher::ChaChaPoly) => self.protocol_name(),
            (Self::XX, NoiseCipher::AesGcm) => "Noise_XX_25519_AESGCM_BLAKE2b",
            (Self::IK, NoiseCipher::AesGcm) => "Noise_IK_25519_AESGCM_BLAKE2b",
            (Self::NN, NoiseCipher::AesGcm) => "Noise_NN_25519_AESGCM_BLAKE2b",
        }
    }

    /// Handshake messages in the pattern.
    pub fn message_count(self) -> usize {
        match self {
            Self::XX => 3,
            Self::IK | Self::NN => 2,
        }
    }
}

/// The AEAD under a session's Noise protocol. ChaChaPoly everywhere (ADR 0001); AES-256-GCM only on a lane whose
/// group's first session had both sides set capability bit 1, hardware AES (ADR 0018 § 9.2). The preamble's pattern
/// byte carries it as bit 7 ([`crate::stream::Preamble`]), so the responder knows the protocol name before message 1.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum NoiseCipher {
    #[default]
    ChaChaPoly,
    AesGcm,
}

/// Transport frame types. Senders use only types the peer's negotiated minor knows; an unknown type closes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum FrameType {
    Hello = 1,
    Profile = 2,
    PresenceSecret = 3,
    Request = 4,
    Accept = 5,
    Decline = 6,
    RequestById = 7,
    Received = 8,
    CodeCommit = 9,
    CodeNonce = 10,
    CodeReveal = 11,
    Message = 12,
    Ack = 13,
    Offer = 14,
    OfferReply = 15,
    Cancel = 16,
    Chunk = 17,
    Progress = 18,
    Done = 19,
    Rekey = 20,
    Ping = 21,
    Close = 22,
    /// Session minor 1.
    Thumbnail = 23,
    /// Session minor 2.
    Chain = 24,
    Join = 25,
    Sync = 26,
    /// Session minor 3.
    Again = 27,
    /// Session minor 4, and only when both sides set the fast-transfers capability (ADR 0018 § 3).
    Hashes = 28,
    Want = 29,
    Part = 30,
    Have = 31,
    /// Session minor 4, and only when both sides set the Wi-Fi Direct boost capability (ADR 0019).
    Boost = 32,
}

impl FrameType {
    pub const ALL: [FrameType; 32] = [
        Self::Hello,
        Self::Profile,
        Self::PresenceSecret,
        Self::Request,
        Self::Accept,
        Self::Decline,
        Self::RequestById,
        Self::Received,
        Self::CodeCommit,
        Self::CodeNonce,
        Self::CodeReveal,
        Self::Message,
        Self::Ack,
        Self::Offer,
        Self::OfferReply,
        Self::Cancel,
        Self::Chunk,
        Self::Progress,
        Self::Done,
        Self::Rekey,
        Self::Ping,
        Self::Close,
        Self::Thumbnail,
        Self::Chain,
        Self::Join,
        Self::Sync,
        Self::Again,
        Self::Hashes,
        Self::Want,
        Self::Part,
        Self::Have,
        Self::Boost,
    ];

    pub fn from_byte(byte: u8) -> Option<Self> {
        Self::ALL.iter().copied().find(|t| *t as u8 == byte)
    }

    /// The session minor version that introduced this type: a sender never sends it to a peer below that.
    pub fn minimum_minor(self) -> u16 {
        match self {
            Self::Thumbnail => 1,
            Self::Chain | Self::Join | Self::Sync => 2,
            Self::Again => 3,
            Self::Hashes | Self::Want | Self::Part | Self::Have | Self::Boost => 4,
            _ => 0,
        }
    }
}

/// Field tags: one namespace for transport frames and handshake payloads.
pub mod tag {
    pub const ID: u8 = 1;
    pub const SENT_AT: u8 = 2;
    pub const TEXT: u8 = 3;
    pub const NAME: u8 = 4;
    pub const FILE_TYPE: u8 = 5;
    pub const SIZE: u8 = 6;
    pub const DIGEST: u8 = 7;
    pub const OFFSET: u8 = 8;
    pub const DATA: u8 = 9;
    pub const PICTURE_SET: u8 = 10;
    pub const PICTURE_INDEX: u8 = 11;
    pub const ACCEPT: u8 = 12;
    pub const SECRET: u8 = 13;
    pub const NONCE: u8 = 14;
    pub const COMMITMENT: u8 = 15;
    pub const OFFER_IDS: u8 = 16;
    pub const FRIENDS_ID: u8 = 17;
    pub const TOKEN: u8 = 18;
    pub const CALLBACK_SECRET: u8 = 19;
    pub const CERTIFICATE: u8 = 20;
    pub const STATIC_KEY: u8 = 21;
    pub const SIGNATURE: u8 = 22;
    pub const REASON: u8 = 23;
    pub const MINOR_MIN: u8 = 24;
    pub const MINOR_MAX: u8 = 25;
    pub const CAPABILITIES: u8 = 26;
    pub const ROUTE_CLASS: u8 = 27;
    pub const ATTESTATION: u8 = 28;
    pub const VIA_ASSISTANT: u8 = 29;
    pub const WIDTH: u8 = 30;
    pub const HEIGHT: u8 = 31;
    pub const INVITE_PROOF: u8 = 32;
    pub const CHAIN: u8 = 33;
    pub const JOIN: u8 = 34;
    pub const SYNC: u8 = 35;
    pub const AGAIN: u8 = 36;
    /// Session minor 4, fast transfers only (ADR 0018). OFFER: the tree's root and the block shift.
    pub const TREE_ROOT: u8 = 37;
    pub const BLOCK_SHIFT: u8 = 38;
    /// HASHES: the first leaf's index, then the leaves.
    pub const INDEX: u8 = 39;
    pub const HASHES: u8 = 40;
    /// WANT and HAVE: block ranges, pairs of u32be `(first, count)`; HAVE's blocks made durable.
    pub const RANGES: u8 = 41;
    pub const DURABLE: u8 = 42;
    /// OFFER_REPLY: the receiver takes the file by blocks.
    pub const BLOCKS: u8 = 43;
    /// PART, compressed: the codec and the length the data expands to.
    pub const CODEC: u8 = 44;
    pub const LENGTH: u8 = 45;
    /// Handshake payload: a lane's token (§ 6).
    pub const LANE: u8 = 46;
    /// WANT and HAVE: 16 KiB pieces of the file (`consts::PIECE_SHIFT`), in the Ranges format (ADR 0018 § 3).
    pub const PIECES: u8 = 47;
    /// BOOST (ADR 0019): the step, what this side can do, and the host's link for the joining side.
    pub const STEP: u8 = 48;
    pub const ABILITIES: u8 = 49;
    pub const NETWORK: u8 = 50;
    pub const PASSPHRASE: u8 = 51;
    pub const ADDRESS: u8 = 52;
    pub const PORT: u8 = 53;

    /// The tags only a fast-transfers session carries: never sent to a peer that did not negotiate them.
    pub fn is_fast_transfers(tag: u8) -> bool {
        (TREE_ROOT..=PIECES).contains(&tag)
    }

    /// The tags a public profile may carry, in XX message 2 and in PROFILE.
    pub fn is_profile(tag: u8) -> bool {
        matches!(tag, NAME | FRIENDS_ID | PICTURE_SET | PICTURE_INDEX | DATA)
    }

    /// Byte width of an integer field, 0 for a tag that is not an integer.
    pub fn integer_width(tag: u8) -> usize {
        match tag {
            SENT_AT | SIZE | OFFSET => 8,
            CAPABILITIES | INDEX | LENGTH => 4,
            PICTURE_SET | PICTURE_INDEX | MINOR_MIN | MINOR_MAX | WIDTH | HEIGHT | PORT => 2,
            ACCEPT | REASON | ROUTE_CLASS | VIA_ASSISTANT | BLOCK_SHIFT | BLOCKS | CODEC | STEP | ABILITIES => 1,
            _ => 0,
        }
    }
}

/// CLOSE's reason byte, for logs on both sides. Wire values, never renumbered; unknown values are kept as numbers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum CloseReason {
    Normal = 0,
    ProtocolError = 1,
    /// Lost the session race.
    Superseded = 2,
    /// Older than the maximum session age: redial.
    Expired = 3,
    /// Helper exit, handover, or Friends turned off.
    ShuttingDown = 4,
    /// The comparison-code commitment did not verify.
    CodeMismatch = 5,
    /// A lane the responder would not admit (ADR 0018 § 6).
    LaneRefused = 6,
}

impl CloseReason {
    /// A known reason; `None` for a value this build does not name (logs keep it as a number).
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Normal),
            1 => Some(Self::ProtocolError),
            2 => Some(Self::Superseded),
            3 => Some(Self::Expired),
            4 => Some(Self::ShuttingDown),
            5 => Some(Self::CodeMismatch),
            6 => Some(Self::LaneRefused),
            _ => None,
        }
    }
}
