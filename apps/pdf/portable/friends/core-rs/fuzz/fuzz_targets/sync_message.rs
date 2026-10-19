//! What another of our devices sends over SYNC (ADR 0014): body fields, version vectors and event headers with and
//! without bodies. Nothing may panic; a vector or fields that decode re-encode to the same bytes, and an event that
//! verifies under the fixed root keeps its header.

#![no_main]

use libfuzzer_sys::fuzz_target;
use szfriends_core::sync::{decode_vector, encode_vector, Event, Fields};

fuzz_target!(|data: &[u8]| {
    if let Some(fields) = Fields::decode(data) {
        assert_eq!(fields.encode(), data, "one encoding per body");
    }
    if let Some((vector, used)) = decode_vector(data) {
        assert_eq!(encode_vector(&vector), &data[..used], "one encoding per vector");
    }
    let split = data.first().map_or(0, |b| *b as usize).min(data.len().saturating_sub(1));
    let (header, body) = data.get(1..).unwrap_or_default().split_at(split.min(data.len().saturating_sub(1)));
    for body in [None, Some(body)] {
        if let Ok(event) = Event::verified(header, body, &[9; 32]) {
            assert_eq!(event.header, header);
        }
    }
});
