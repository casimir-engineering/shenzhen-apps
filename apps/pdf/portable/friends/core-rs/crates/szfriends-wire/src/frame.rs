//! Transport frames: one per Noise transport message (`SZFriendsEncodeFrame`, `SZFriendsDecodeFrame`).
//!
//! Decoding: an unknown type, a duplicate tag (known or not), a known field outside its length limits or a missing
//! required field fails; a tag the type does not define is ignored and left out. Encoding is strict: every field
//! must belong to the type.

use crate::consts::FRAME_PLAINTEXT_MAX;
use crate::error::WireError;
use crate::fields::{self, Fields};
use crate::rules;
use crate::types::FrameType;

#[derive(Clone, PartialEq, Eq)]
pub struct Frame {
    pub frame_type: FrameType,
    pub fields: Fields,
}

impl Frame {
    pub fn new(frame_type: FrameType) -> Self {
        Self { frame_type, fields: Fields::new() }
    }

    /// Adds a field; for building frames in code.
    pub fn with(mut self, tag: u8, value: impl Into<Vec<u8>>) -> Self {
        self.fields.insert(tag, value.into());
        self
    }

    /// Adds an integer field at its tag's width.
    pub fn with_integer(self, tag: u8, value: u64) -> Result<Self, WireError> {
        let bytes = fields::integer(value, tag)?;
        Ok(self.with(tag, bytes))
    }

    /// A field's value when the type defines it and it passes the type's rule. A frame built in memory has not been
    /// through the codec, so this applies the decoder's rule rather than trusting the map.
    pub fn get(&self, tag: u8) -> Option<&[u8]> {
        let rule = rules::find(rules::for_type(self.frame_type), tag)?;
        let value = self.fields.get(&tag)?;
        rule.allows(value).then_some(value.as_slice())
    }

    pub fn integer(&self, tag: u8) -> Option<u64> {
        fields::read_integer(self.get(tag)?, tag)
    }

    /// Valid UTF-8 only; `None` otherwise.
    pub fn text(&self, tag: u8) -> Option<&str> {
        std::str::from_utf8(self.get(tag)?).ok()
    }

    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        let mut output = vec![self.frame_type as u8];
        fields::append(&mut output, &self.fields, rules::for_type(self.frame_type))?;
        if output.len() > FRAME_PLAINTEXT_MAX {
            return Err(WireError::FrameLength(output.len()));
        }
        Ok(output)
    }

    pub fn decode(plaintext: &[u8]) -> Result<Self, WireError> {
        if plaintext.is_empty() || plaintext.len() > FRAME_PLAINTEXT_MAX {
            return Err(WireError::FrameLength(plaintext.len()));
        }
        let frame_type = FrameType::from_byte(plaintext[0]).ok_or(WireError::UnknownType(plaintext[0]))?;
        let fields = fields::decode(plaintext, 1, rules::for_type(frame_type))?;
        Ok(Self { frame_type, fields })
    }
}

/// Tags only, never values: frames carry message text, keys and secrets, none of which belong in a log.
impl std::fmt::Debug for Frame {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let tags: Vec<u8> = self.fields.keys().copied().collect();
        write!(f, "Frame {{ type: {:?}, tags: {tags:?} }}", self.frame_type)
    }
}
