//! The tag-length-value walker shared by frames and handshake payloads (`SZFriendsDecodeFields`,
//! `SZFriendsAppendFields`): `tag:u8 len:u16be value`, one tag namespace, the same limits wherever a field appears.

use std::collections::BTreeMap;

use crate::error::WireError;
use crate::rules::{self, FieldRule};
use crate::types::tag;

/// Fields by tag. Ordered, so encoding writes ascending tags as the Objective-C encoder does.
pub type Fields = BTreeMap<u8, Vec<u8>>;

/// Walks `data` from `offset`, checking every length, duplicate and limit before copying anything. Fields the rules do
/// not define are skipped (unknown tags are ignored, at any length); a duplicate of any tag, known or not, fails.
pub fn decode(data: &[u8], offset: usize, rules: &[FieldRule]) -> Result<Fields, WireError> {
    let mut seen = [0u8; 32];
    let mut position = offset;
    // Pass 1 reads only: nothing sized by the peer exists until every check passed.
    while position < data.len() {
        if data.len() - position < 3 {
            return Err(WireError::TruncatedField);
        }
        let field_tag = data[position];
        let length = usize::from(u16::from_be_bytes([data[position + 1], data[position + 2]]));
        position += 3;
        if length > data.len() - position {
            return Err(WireError::FieldOverrun(field_tag));
        }
        let (byte, bit) = (usize::from(field_tag >> 3), 1u8 << (field_tag & 7));
        if seen[byte] & bit != 0 {
            return Err(WireError::DuplicateField(field_tag));
        }
        seen[byte] |= bit;
        if let Some(rule) = rules::find(rules, field_tag) {
            if !rule.allows(&data[position..position + length]) {
                return Err(WireError::FieldOutOfLimits { tag: field_tag, length });
            }
        }
        position += length;
    }
    for rule in rules.iter().filter(|rule| rule.required()) {
        if seen[usize::from(rule.tag >> 3)] & (1 << (rule.tag & 7)) == 0 {
            return Err(WireError::MissingField(rule.tag));
        }
    }
    let mut fields = Fields::new();
    let mut position = offset;
    while position < data.len() {
        let field_tag = data[position];
        let length = usize::from(u16::from_be_bytes([data[position + 1], data[position + 2]]));
        position += 3;
        if rules::find(rules, field_tag).is_some() {
            fields.insert(field_tag, data[position..position + length].to_vec());
        }
        position += length;
    }
    Ok(fields)
}

/// Appends `fields` in ascending tag order. Strict: fails on a field the rules do not define, a value out of its
/// limits or a missing required field, appending nothing.
pub fn append(output: &mut Vec<u8>, fields: &Fields, rules: &[FieldRule]) -> Result<(), WireError> {
    for (&field_tag, value) in fields {
        let rule = rules::find(rules, field_tag).ok_or(WireError::FieldNotDefined(field_tag))?;
        if !rule.allows(value) {
            return Err(WireError::FieldOutOfLimits { tag: field_tag, length: value.len() });
        }
    }
    if let Some(rule) = rules.iter().find(|rule| rule.required() && !fields.contains_key(&rule.tag)) {
        return Err(WireError::MissingField(rule.tag));
    }
    for (&field_tag, value) in fields {
        output.push(field_tag);
        output.extend_from_slice(&(value.len() as u16).to_be_bytes());
        output.extend_from_slice(value);
    }
    Ok(())
}

/// The big-endian bytes of `value` at `tag`'s integer width.
pub fn integer(value: u64, field_tag: u8) -> Result<Vec<u8>, WireError> {
    let width = tag::integer_width(field_tag);
    if width == 0 || (width < 8 && value >> (8 * width) != 0) {
        return Err(WireError::BadInteger(field_tag));
    }
    Ok(value.to_be_bytes()[8 - width..].to_vec())
}

/// The integer in `bytes` when it has `tag`'s width.
pub fn read_integer(bytes: &[u8], field_tag: u8) -> Option<u64> {
    let width = tag::integer_width(field_tag);
    (width != 0 && bytes.len() == width).then(|| bytes.iter().fold(0u64, |acc, &b| (acc << 8) | u64::from(b)))
}
