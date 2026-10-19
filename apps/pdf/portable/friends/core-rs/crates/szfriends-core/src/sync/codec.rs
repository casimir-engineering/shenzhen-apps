//! Events, their bodies' fields and version vectors on the wire (`SZFriendsSyncEvent.m`). Everything a peer sends is
//! decoded strictly: one encoding per value, every length checked before it is read.
//!
//! Header, integers big-endian: `version u8 (1) | kind u8 | author (32) | seq u64 | lamport u64 | milliseconds u64 |
//! scope length u8 | scope | subject length u8 | subject | body length u32 | BLAKE2b-256(body) | signature (64)` by
//! the author over root key || every byte before it, domain "SZFriends sync event v1".

use std::collections::BTreeMap;

use szfriends_identity::identity::verify;
use szfriends_identity::Identity;

use super::{digest, label_is_valid, Kind, SyncError, BODY_MAX, LABEL_MAX};
use crate::store::sync_log::{LogEvent, Vector};

const DOMAIN: &str = "SZFriends sync event v1";
const VERSION: u8 = 1;
const HEADER_FIXED: usize = 1 + 1 + 32 + 8 + 8 + 8 + 1 + 1 + 4 + 32 + 64;

/// A body's fields: `tag u8 | length u16 | value`, tags strictly ascending.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Fields(BTreeMap<u8, Vec<u8>>);

impl Fields {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() > BODY_MAX {
            return None;
        }
        let mut fields = BTreeMap::new();
        let mut offset = 0;
        let mut previous: i32 = -1;
        while offset < data.len() {
            if data.len() - offset < 3 {
                return None;
            }
            let tag = data[offset];
            let length = u16::from_be_bytes([data[offset + 1], data[offset + 2]]) as usize;
            offset += 3;
            if i32::from(tag) <= previous || data.len() - offset < length {
                return None;
            }
            previous = i32::from(tag);
            fields.insert(tag, data[offset..offset + length].to_vec());
            offset += length;
        }
        Some(Self(fields))
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for (tag, value) in &self.0 {
            out.push(*tag);
            out.extend_from_slice(&(value.len() as u16).to_be_bytes());
            out.extend_from_slice(value);
        }
        out
    }

    /// `None` (or a value too long for its length) removes the field.
    pub fn set_data(&mut self, tag: u8, value: Option<&[u8]>) {
        match value {
            Some(value) if value.len() <= u16::MAX as usize => {
                self.0.insert(tag, value.to_vec());
            }
            _ => {
                self.0.remove(&tag);
            }
        }
    }

    pub fn set_string(&mut self, tag: u8, value: Option<&str>) {
        self.set_data(tag, value.map(str::as_bytes));
    }

    pub fn set_u64(&mut self, tag: u8, value: u64) {
        self.set_data(tag, Some(&value.to_be_bytes()));
    }

    /// The exact double, so times round-trip unchanged.
    pub fn set_date(&mut self, tag: u8, value: Option<f64>) {
        match value {
            Some(seconds) => self.set_u64(tag, seconds.to_bits()),
            None => self.set_data(tag, None),
        }
    }

    pub fn data(&self, tag: u8) -> Option<&[u8]> {
        self.0.get(&tag).map(Vec::as_slice)
    }

    pub fn string(&self, tag: u8) -> Option<String> {
        self.data(tag).and_then(|d| std::str::from_utf8(d).ok()).map(str::to_owned)
    }

    /// 0 when absent or malformed.
    pub fn u64(&self, tag: u8) -> u64 {
        self.data(tag).and_then(|d| <[u8; 8]>::try_from(d).ok()).map_or(0, u64::from_be_bytes)
    }

    pub fn has(&self, tag: u8) -> bool {
        self.0.contains_key(&tag)
    }

    pub fn date(&self, tag: u8) -> Option<f64> {
        let bits = self.data(tag).and_then(|d| <[u8; 8]>::try_from(d).ok()).map(u64::from_be_bytes)?;
        Some(f64::from_bits(bits)).filter(|s| s.is_finite())
    }
}

/// One signed event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub kind: Kind,
    pub author: [u8; 32],
    pub seq: u64,
    pub lamport: u64,
    /// Unix milliseconds of the author's clock.
    pub milliseconds: u64,
    pub scope: String,
    pub subject: String,
    pub body: Option<Vec<u8>>,
    pub header: Vec<u8>,
}

struct Decoded {
    event: Event,
    signed_length: usize,
    digest: [u8; 32],
    body_length: u32,
}

fn decode_header(header: &[u8]) -> Option<Decoded> {
    if header.len() < HEADER_FIXED || header.len() > HEADER_FIXED + 2 * LABEL_MAX || header[0] != VERSION {
        return None;
    }
    let kind = Kind::from_byte(header[1])?;
    let mut offset = 2 + 32 + 24;
    let scope_length = header[offset] as usize;
    if offset + 1 + scope_length + 1 > header.len() {
        return None;
    }
    let scope = &header[offset + 1..offset + 1 + scope_length];
    offset += 1 + scope_length;
    let subject_length = header[offset] as usize;
    if offset + 1 + subject_length + 4 + 32 + 64 != header.len() {
        return None;
    }
    let subject = &header[offset + 1..offset + 1 + subject_length];
    offset += 1 + subject_length;
    let body_length = u32::from_be_bytes(header[offset..offset + 4].try_into().expect("4"));
    let digest: [u8; 32] = header[offset + 4..offset + 36].try_into().expect("32");
    let u64_at = |at: usize| u64::from_be_bytes(header[at..at + 8].try_into().expect("8"));
    let (seq, lamport) = (u64_at(34), u64_at(42));
    let scope = std::str::from_utf8(scope).ok().filter(|s| label_is_valid(s))?.to_owned();
    let subject = std::str::from_utf8(subject).ok().filter(|s| label_is_valid(s))?.to_owned();
    let bounds = (1..=i64::MAX as u64).contains(&seq) && (1..=i64::MAX as u64).contains(&lamport);
    if !bounds || body_length as usize > BODY_MAX {
        return None;
    }
    let event = Event {
        kind,
        author: header[2..34].try_into().expect("32"),
        seq,
        lamport,
        milliseconds: u64_at(50),
        scope,
        subject,
        body: None,
        header: header.to_vec(),
    };
    Some(Decoded { event, signed_length: offset + 36, digest, body_length })
}

impl Event {
    /// Signs a new event; the labels and body must be within their limits (the engine checks first).
    #[allow(clippy::too_many_arguments)]
    pub fn signed(
        author: &Identity,
        root: &[u8; 32],
        kind: Kind,
        seq: u64,
        lamport: u64,
        seconds: f64,
        scope: &str,
        subject: &str,
        body: &[u8],
    ) -> Self {
        assert!(label_is_valid(scope) && label_is_valid(subject) && body.len() <= BODY_MAX, "an event out of bounds");
        let mut header = vec![VERSION, kind as u8];
        header.extend_from_slice(&author.public_key());
        header.extend_from_slice(&seq.to_be_bytes());
        header.extend_from_slice(&lamport.to_be_bytes());
        let ms = (seconds * 1000.0).floor();
        header.extend_from_slice(&(if ms > 0.0 { ms as u64 } else { 0 }).to_be_bytes());
        header.push(scope.len() as u8);
        header.extend_from_slice(scope.as_bytes());
        header.push(subject.len() as u8);
        header.extend_from_slice(subject.as_bytes());
        header.extend_from_slice(&(body.len() as u32).to_be_bytes());
        header.extend_from_slice(&digest(body));
        let message = [&root[..], &header].concat();
        header.extend_from_slice(&author.sign(&message, DOMAIN));
        Self::verified(&header, Some(body), root).expect("a fresh event verifies")
    }

    /// Verifies the header's signature against its author and the body against its digest.
    pub fn verified(header: &[u8], body: Option<&[u8]>, root: &[u8; 32]) -> Result<Self, SyncError> {
        let decoded = decode_header(header).ok_or(SyncError::Malformed("a sync event header that does not decode"))?;
        let signature = &header[decoded.signed_length..decoded.signed_length + 64];
        let message = [&root[..], &header[..decoded.signed_length]].concat();
        if !verify(signature, &message, DOMAIN, &decoded.event.author) {
            return Err(SyncError::Forged("a sync event whose signature does not verify"));
        }
        if let Some(body) = body {
            if body.len() != decoded.body_length as usize || digest(body) != decoded.digest {
                return Err(SyncError::Forged("a sync event body that does not match its header"));
            }
        }
        Ok(Event { body: body.map(<[u8]>::to_vec), ..decoded.event })
    }

    /// As the log keeps it (verified when appended): decoded, not verified again.
    pub fn from_log(log: &LogEvent) -> Option<Self> {
        let decoded = decode_header(&log.header)?;
        Some(Event { body: log.body.clone(), ..decoded.event })
    }

    pub fn log_event(&self, applied: bool) -> LogEvent {
        LogEvent {
            author: self.author,
            seq: self.seq,
            lamport: self.lamport,
            kind: self.kind as i64,
            scope: self.scope.clone(),
            subject: self.subject.clone(),
            header: self.header.clone(),
            body: self.body.clone(),
            applied,
        }
    }

    /// Unix seconds of the author's clock.
    pub fn date(&self) -> f64 {
        self.milliseconds as f64 / 1000.0
    }

    pub fn fields(&self) -> Option<Fields> {
        self.body.as_deref().and_then(Fields::decode)
    }
}

/// `count u16 | (author (32) | seq u64)*`, authors ascending, no empty entry.
pub fn encode_vector(vector: &Vector) -> Vec<u8> {
    let entries: Vec<(&[u8; 32], &u64)> = vector.iter().filter(|(_, seq)| **seq > 0).collect();
    let mut out = (entries.len() as u16).to_be_bytes().to_vec();
    for (author, seq) in entries {
        out.extend_from_slice(author);
        out.extend_from_slice(&seq.to_be_bytes());
    }
    out
}

/// A vector and the bytes it took; `None` unless authors are strictly ascending and every entry is 1 to 2^63-1.
pub fn decode_vector(data: &[u8]) -> Option<(Vector, usize)> {
    if data.len() < 2 {
        return None;
    }
    let count = u16::from_be_bytes([data[0], data[1]]) as usize;
    if count > 256 || data.len() < 2 + count * 40 {
        return None;
    }
    let mut vector = Vector::new();
    let mut previous: Option<[u8; 32]> = None;
    for i in 0..count {
        let at = 2 + i * 40;
        let author: [u8; 32] = data[at..at + 32].try_into().expect("32");
        let seq = u64::from_be_bytes(data[at + 32..at + 40].try_into().expect("8"));
        if seq == 0 || seq > i64::MAX as u64 || previous.is_some_and(|p| p >= author) {
            return None;
        }
        previous = Some(author);
        vector.insert(author, seq);
    }
    Some((vector, 2 + count * 40))
}

pub fn vector_covers(vector: &Vector, author: &[u8; 32], seq: u64) -> bool {
    vector.get(author).copied().unwrap_or(0) >= seq
}
