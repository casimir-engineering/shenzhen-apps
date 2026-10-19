//! Codec errors. Descriptions name tags and lengths, never values: frames carry text, keys and secrets.

use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WireError {
    /// Empty, or over the plaintext limit.
    FrameLength(usize),
    UnknownType(u8),
    TruncatedField,
    FieldOverrun(u8),
    DuplicateField(u8),
    FieldOutOfLimits {
        tag: u8,
        length: usize,
    },
    MissingField(u8),
    /// Encoding: a field the type (or the payload) does not define.
    FieldNotDefined(u8),
    /// Encoding: an integer too wide for its tag, or a tag that is not an integer.
    BadInteger(u8),
    /// A message length prefix of 0 or above the limit.
    MessageLength(usize),
    /// A preamble that is not `'S' 'Z' 1 pattern`.
    Preamble,
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::FrameLength(n) => write!(f, "frame of {n} bytes"),
            Self::UnknownType(t) => write!(f, "unknown frame type {t}"),
            Self::TruncatedField => write!(f, "truncated field header"),
            Self::FieldOverrun(t) => write!(f, "field {t} overruns the frame"),
            Self::DuplicateField(t) => write!(f, "duplicate field {t}"),
            Self::FieldOutOfLimits { tag, length } => write!(f, "field {tag} outside its limits ({length} bytes)"),
            Self::MissingField(t) => write!(f, "missing field {t}"),
            Self::FieldNotDefined(t) => write!(f, "field {t} is not defined here"),
            Self::BadInteger(t) => write!(f, "field {t} is not an integer of that width"),
            Self::MessageLength(n) => write!(f, "message length {n}"),
            Self::Preamble => write!(f, "unknown preamble"),
        }
    }
}

impl std::error::Error for WireError {}
