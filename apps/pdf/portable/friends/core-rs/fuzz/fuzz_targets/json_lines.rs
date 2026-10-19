//! The client protocol's line reader (PROTOCOL.md § Framing), which the helper runs on whatever a local client writes:
//! fed in arbitrary slices, it returns the same values as when fed whole, or fails either way.

#![no_main]

use libfuzzer_sys::fuzz_target;
use szfriends_contract::framing::LineReader;

fuzz_target!(|data: &[u8]| {
    let Some((&split, rest)) = data.split_first() else { return };
    let whole = LineReader::new().push(rest);
    let mut reader = LineReader::new();
    let mut values = Vec::new();
    let mut failed = false;
    for piece in rest.chunks(usize::from(split.max(1))) {
        match reader.push(piece) {
            Ok(more) => values.extend(more),
            Err(_) => {
                failed = true;
                break;
            }
        }
    }
    if let Ok(all) = whole {
        assert!(!failed && all == values);
    }
});
