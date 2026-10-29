//! Block ranges (ADR 0018 § 3): the Ranges and Durable fields of WANT and HAVE, pairs of u32be `(first block, count)`,
//! ascending and not overlapping, at most 8,000 pairs per field. Decoding refuses an empty range, an overlap, a range
//! out of order or one that runs past `u32::MAX`; encoding merges adjacent ranges.

use crate::consts::RANGES_PER_FIELD;

/// Decodes a Ranges or Durable value: `None` for anything not canonical enough to trust (see the module).
pub fn decode(bytes: &[u8]) -> Option<Vec<(u32, u32)>> {
    if bytes.len() % 8 != 0 || bytes.len() / 8 > RANGES_PER_FIELD {
        return None;
    }
    let mut ranges = Vec::with_capacity(bytes.len() / 8);
    let mut next_free: u64 = 0;
    for pair in bytes.chunks_exact(8) {
        let first = u32::from_be_bytes(pair[..4].try_into().expect("4"));
        let count = u32::from_be_bytes(pair[4..].try_into().expect("4"));
        let end = u64::from(first) + u64::from(count);
        if count == 0 || u64::from(first) < next_free || end > u64::from(u32::MAX) + 1 {
            return None;
        }
        next_free = end;
        ranges.push((first, count));
    }
    Some(ranges)
}

/// Encodes ascending, non-overlapping ranges, merging adjacent ones, in fields of at most 8,000 pairs each (one
/// field's worth per element). Empty ranges are skipped; an empty input gives no fields.
pub fn encode(ranges: &[(u32, u32)]) -> Vec<Vec<u8>> {
    let mut merged: Vec<(u32, u32)> = Vec::new();
    for &(first, count) in ranges.iter().filter(|(_, count)| *count > 0) {
        match merged.last_mut() {
            Some(last) if u64::from(last.0) + u64::from(last.1) == u64::from(first) => last.1 += count,
            _ => merged.push((first, count)),
        }
    }
    merged
        .chunks(RANGES_PER_FIELD)
        .map(|chunk| {
            chunk.iter().flat_map(|(first, count)| [first.to_be_bytes(), count.to_be_bytes()]).flatten().collect()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_round_trip_and_refuse_what_is_not_canonical() {
        let fields = encode(&[(0, 2), (2, 3), (9, 1)]);
        assert_eq!(fields.len(), 1);
        assert_eq!(decode(&fields[0]), Some(vec![(0, 5), (9, 1)]));
        let pair = |first: u32, count: u32| [first.to_be_bytes(), count.to_be_bytes()].concat();
        assert_eq!(decode(&[pair(3, 1), pair(1, 1)].concat()), None, "out of order");
        assert_eq!(decode(&[pair(1, 3), pair(2, 1)].concat()), None, "overlap");
        assert_eq!(decode(&pair(1, 0)), None, "empty");
        assert_eq!(decode(&pair(u32::MAX, 2)), None, "past the last block");
        assert_eq!(decode(&pair(u32::MAX, 1)), Some(vec![(u32::MAX, 1)]));
        assert_eq!(decode(&[0; 7]), None);
        let many: Vec<(u32, u32)> = (0..9_000).map(|i| (i * 2, 1)).collect();
        assert_eq!(encode(&many).len(), 2);
    }
}
