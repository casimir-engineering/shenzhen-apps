//! Signalling items (`SZFriendsSignaling.h`, `SZFriendsSignaling.m`): the one format every signalling payload and
//! rendezvous record body uses. A payload is one or more items, `type:u8 len:u16be value`, the value being fields
//! `tag:u8 len:u16be value`. Unknown item types and unknown tags are skipped, so later versions can add both; a
//! duplicate tag, a known field of the wrong length or a missing required field fails the whole payload.

use std::collections::BTreeMap;

/// Every payload, sealed, is at most this: the host's limit on `sig_open` and `sig_msg` payloads.
pub const PAYLOAD_MAX: usize = 4096;
pub const SDP_MAX: usize = 3072;
pub const CANDIDATE_MAX: usize = 256;
pub const FRAME_MAX: usize = 1024;
/// The attestation field's bound (`SZFriendsAttestationMax`).
pub const ATTESTATION_MAX: usize = szfriends_wire::consts::ATTESTATION_MAX;
/// IK message 1 carries the caller's clock; an answerer refuses one further than this from its own.
pub const CLOCK_SKEW_MAX: f64 = 300.0;
/// The highest signalling version this build speaks.
pub const MINOR: u16 = 0;

/// Item types. Wire values: never renumber.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ItemType {
    Hello = 1,
    Description = 2,
    Candidate = 3,
    CandidatesEnd = 4,
    Nat = 5,
    Start = 6,
    Frame = 7,
    End = 8,
    LinkNonce = 9,
    LinkChallenge = 10,
    LinkProof = 11,
}

impl ItemType {
    fn from_byte(byte: u8) -> Option<Self> {
        Some(match byte {
            1 => Self::Hello,
            2 => Self::Description,
            3 => Self::Candidate,
            4 => Self::CandidatesEnd,
            5 => Self::Nat,
            6 => Self::Start,
            7 => Self::Frame,
            8 => Self::End,
            9 => Self::LinkNonce,
            10 => Self::LinkChallenge,
            11 => Self::LinkProof,
            _ => return None,
        })
    }

    fn required(self) -> &'static [u8] {
        match self {
            Self::Hello => &[tag::MINOR_MIN, tag::MINOR_MAX],
            Self::Description => &[tag::CONNECTION, tag::KIND, tag::SDP, tag::FINGERPRINT],
            Self::Candidate => &[tag::CONNECTION, tag::TECHNIQUE, tag::CANDIDATE],
            Self::CandidatesEnd => &[tag::CONNECTION],
            Self::Nat => &[tag::NAT_CLASS],
            Self::Start => &[tag::CONNECTION, tag::KIND],
            Self::Frame => &[tag::FRAME],
            Self::End => &[tag::REASON],
            Self::LinkNonce | Self::LinkChallenge => &[tag::NONCE],
            Self::LinkProof => &[tag::PROOF],
        }
    }
}

/// Field tags, one namespace for every item type.
pub mod tag {
    pub const CONNECTION: u8 = 1;
    pub const KIND: u8 = 2;
    pub const SDP: u8 = 3;
    pub const FINGERPRINT: u8 = 4;
    pub const TECHNIQUE: u8 = 5;
    pub const CANDIDATE: u8 = 6;
    pub const NAT_CLASS: u8 = 7;
    pub const NAT_STEP: u8 = 8;
    pub const TIME: u8 = 9;
    pub const MINOR_MIN: u8 = 10;
    pub const MINOR_MAX: u8 = 11;
    pub const CERTIFICATE: u8 = 12;
    pub const ATTESTATION: u8 = 13;
    pub const TOKEN: u8 = 14;
    pub const FRAME: u8 = 15;
    pub const REASON: u8 = 16;
    pub const NONCE: u8 = 17;
    pub const PROOF: u8 = 18;
}

/// ADR 0011 § NAT class, as the signalling carries it.
pub mod nat_class {
    pub const UNKNOWN: u8 = 0;
    pub const INDEPENDENT: u8 = 1;
    pub const PER_DESTINATION: u8 = 2;
}

/// Why the sender's attempt is over.
pub mod end_reason {
    pub const DONE: u8 = 0;
    pub const DECLINED: u8 = 1;
    pub const FAILED: u8 = 2;
}

/// The lengths a known field may have; `None` for a tag this build does not know.
fn field_length(tag: u8) -> Option<(usize, usize)> {
    Some(match tag {
        tag::CONNECTION | tag::KIND | tag::TECHNIQUE | tag::NAT_CLASS | tag::REASON => (1, 1),
        tag::NAT_STEP | tag::MINOR_MIN | tag::MINOR_MAX => (2, 2),
        tag::TIME => (8, 8),
        tag::TOKEN => (16, 16),
        tag::FINGERPRINT | tag::NONCE | tag::PROOF => (32, 32),
        tag::CERTIFICATE => (96, 96),
        tag::SDP => (1, SDP_MAX),
        tag::CANDIDATE => (1, CANDIDATE_MAX),
        tag::ATTESTATION => (1, ATTESTATION_MAX),
        tag::FRAME => (1, FRAME_MAX),
        _ => return None,
    })
}

/// SDP is UTF-8 without NUL; a candidate line printable ASCII, so it can never smuggle a second SDP line.
fn text_valid(tag: u8, value: &[u8]) -> bool {
    if tag != tag::SDP && tag != tag::CANDIDATE {
        return true;
    }
    if value.contains(&0) || (tag == tag::CANDIDATE && value.iter().any(|b| !(0x20..=0x7e).contains(b))) {
        return false;
    }
    std::str::from_utf8(value).is_ok()
}

/// Why a payload was refused (`SZFriendsSessionErrorFrameInvalid`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Invalid;

/// One item: its type and its known fields, by tag.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    pub kind: ItemType,
    pub fields: BTreeMap<u8, Vec<u8>>,
}

impl Item {
    pub fn new(kind: ItemType, fields: impl IntoIterator<Item = (u8, Vec<u8>)>) -> Self {
        Self { kind, fields: fields.into_iter().collect() }
    }

    pub fn description(connection: u8, kind: u8, sdp: &str, fingerprint: &[u8; 32]) -> Self {
        Self::new(
            ItemType::Description,
            [
                (tag::CONNECTION, vec![connection]),
                (tag::KIND, vec![kind]),
                (tag::SDP, sdp.as_bytes().to_vec()),
                (tag::FINGERPRINT, fingerprint.to_vec()),
            ],
        )
    }

    pub fn candidate(connection: u8, technique: u8, line: &str) -> Self {
        Self::new(
            ItemType::Candidate,
            [
                (tag::CONNECTION, vec![connection]),
                (tag::TECHNIQUE, vec![technique]),
                (tag::CANDIDATE, line.as_bytes().to_vec()),
            ],
        )
    }

    pub fn candidates_end(connection: u8) -> Self {
        Self::new(ItemType::CandidatesEnd, [(tag::CONNECTION, vec![connection])])
    }

    /// `step` is sent only for a per-destination NAT.
    pub fn nat(class: u8, step: i16) -> Self {
        let mut item = Self::new(ItemType::Nat, [(tag::NAT_CLASS, vec![class])]);
        if class == nat_class::PER_DESTINATION {
            item.fields.insert(tag::NAT_STEP, step.to_be_bytes().to_vec());
        }
        item
    }

    pub fn start(connection: u8, kind: u8) -> Self {
        Self::new(ItemType::Start, [(tag::CONNECTION, vec![connection]), (tag::KIND, vec![kind])])
    }

    pub fn frame(encoded: Vec<u8>) -> Self {
        Self::new(ItemType::Frame, [(tag::FRAME, encoded)])
    }

    pub fn end(reason: u8) -> Self {
        Self::new(ItemType::End, [(tag::REASON, vec![reason])])
    }

    pub fn data(&self, tag: u8) -> Option<&[u8]> {
        self.fields.get(&tag).map(Vec::as_slice)
    }

    /// A text field, when present and UTF-8.
    pub fn text(&self, tag: u8) -> Option<&str> {
        std::str::from_utf8(self.data(tag)?).ok()
    }

    /// An unsigned field at its width.
    pub fn unsigned(&self, tag: u8) -> Option<u64> {
        let data = self.data(tag)?;
        (data.len() <= 8).then(|| data.iter().fold(0u64, |acc, b| (acc << 8) | u64::from(*b)))
    }

    /// A one-byte field, 0 when absent.
    pub fn byte(&self, tag: u8) -> u8 {
        self.unsigned(tag).unwrap_or(0) as u8
    }

    /// NATStep as signed; 0 when absent.
    pub fn nat_step(&self) -> i16 {
        self.unsigned(tag::NAT_STEP).map_or(0, |raw| raw as u16 as i16)
    }

    fn valid(&self) -> bool {
        self.kind.required().iter().all(|t| self.fields.contains_key(t))
            && self.fields.iter().all(|(&tag, value)| {
                field_length(tag).is_some_and(|(min, max)| (min..=max).contains(&value.len())) && text_valid(tag, value)
            })
    }
}

/// Encodes items as one plaintext, strictly: every known field at its length, every type with its required fields,
/// and the whole within `capacity` bytes.
pub fn encode(items: &[Item], capacity: usize) -> Result<Vec<u8>, Invalid> {
    let mut out = Vec::new();
    for item in items {
        if item.fields.is_empty() || !item.valid() {
            return Err(Invalid);
        }
        let mut value = Vec::new();
        for (&tag, data) in &item.fields {
            value.push(tag);
            value.extend_from_slice(&(data.len() as u16).to_be_bytes());
            value.extend_from_slice(data);
        }
        let length = u16::try_from(value.len()).map_err(|_| Invalid)?;
        out.push(item.kind as u8);
        out.extend_from_slice(&length.to_be_bytes());
        out.extend_from_slice(&value);
    }
    if out.is_empty() || out.len() > capacity {
        return Err(Invalid);
    }
    Ok(out)
}

fn decode_fields(bytes: &[u8]) -> Result<BTreeMap<u8, Vec<u8>>, Invalid> {
    let (mut fields, mut seen, mut at) = (BTreeMap::new(), [false; 256], 0);
    while at < bytes.len() {
        if bytes.len() - at < 3 {
            return Err(Invalid);
        }
        let tag = bytes[at];
        let length = usize::from(u16::from_be_bytes([bytes[at + 1], bytes[at + 2]]));
        at += 3;
        if length > bytes.len() - at || seen[usize::from(tag)] {
            return Err(Invalid);
        }
        seen[usize::from(tag)] = true;
        if field_length(tag).is_some() {
            fields.insert(tag, bytes[at..at + length].to_vec());
        }
        at += length;
    }
    Ok(fields)
}

/// Decodes a plaintext: unknown item types and tags are left out; anything malformed fails the whole plaintext.
pub fn decode(plaintext: &[u8]) -> Result<Vec<Item>, Invalid> {
    if plaintext.is_empty() || plaintext.len() > PAYLOAD_MAX {
        return Err(Invalid);
    }
    let (mut items, mut at) = (Vec::new(), 0);
    while at < plaintext.len() {
        if plaintext.len() - at < 3 {
            return Err(Invalid);
        }
        let length = usize::from(u16::from_be_bytes([plaintext[at + 1], plaintext[at + 2]]));
        if length > plaintext.len() - at - 3 {
            return Err(Invalid);
        }
        let kind = plaintext[at];
        let fields = decode_fields(&plaintext[at + 3..at + 3 + length])?;
        at += 3 + length;
        let Some(kind) = ItemType::from_byte(kind) else { continue };
        let item = Item { kind, fields };
        if !item.valid() {
            return Err(Invalid);
        }
        items.push(item);
    }
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn items_round_trip_and_unknown_parts_are_skipped() {
        let items = vec![
            Item::description(0, 1, "v=0\r\n", &[7; 32]),
            Item::candidate(0, 3, "candidate:1 1 UDP 1 192.0.2.1 9 typ srflx"),
            Item::nat(nat_class::PER_DESTINATION, -2),
            Item::end(end_reason::DONE),
        ];
        let bytes = encode(&items, PAYLOAD_MAX).unwrap();
        assert_eq!(decode(&bytes).unwrap(), items);
        assert_eq!(decode(&bytes).unwrap()[2].nat_step(), -2);
        // An unknown item and an unknown tag inside a known item.
        let mut more = bytes.clone();
        more.extend_from_slice(&[200, 0, 3, 1, 0, 0]);
        more.extend_from_slice(&[8, 0, 7, 16, 0, 1, 2, 99, 0, 0]);
        let decoded = decode(&more).unwrap();
        assert_eq!(decoded.len(), 5);
        assert_eq!(decoded[4].byte(tag::REASON), 2);
    }

    #[test]
    fn malformed_payloads_fail_whole() {
        let good = encode(&[Item::end(0)], PAYLOAD_MAX).unwrap();
        assert!(decode(&good[..good.len() - 1]).is_err());
        // A duplicate tag, a wrong length, a missing required field, a candidate with a line break.
        assert!(decode(&[8, 0, 8, 16, 0, 1, 0, 16, 0, 1, 0]).is_err());
        assert!(decode(&[8, 0, 5, 16, 0, 2, 0, 0]).is_err());
        assert!(decode(&[4, 0, 0]).is_err());
        let bad = Item::candidate(0, 3, "candidate:1\r\na=x");
        assert!(encode(&[bad], PAYLOAD_MAX).is_err());
        assert!(encode(&[], PAYLOAD_MAX).is_err());
        assert!(encode(&[Item::end(0)], 4).is_err());
    }
}
