//! The byte stream under Noise: the preamble and the length-prefixed message reader, fed in arbitrary slices. The
//! messages it returns are the same however the bytes arrive, and it never holds more than one unfinished message.

#![no_main]

use libfuzzer_sys::fuzz_target;
use szfriends_wire::stream::{MessageReader, Preamble};

fuzz_target!(|data: &[u8]| {
    let Some((&split, rest)) = data.split_first() else { return };
    let _ = Preamble::parse(rest.get(..4).unwrap_or(rest));
    let mut whole = MessageReader::new();
    let all = whole.push(rest);
    let mut pieces = MessageReader::new();
    let step = usize::from(split.max(1));
    let mut collected = Vec::new();
    let mut failed = false;
    for piece in rest.chunks(step) {
        match pieces.push(piece) {
            Ok(messages) => collected.extend(messages),
            Err(_) => {
                failed = true;
                break;
            }
        }
        assert!(pieces.pending() <= 65_537);
    }
    match all {
        Ok(messages) => assert!(!failed && messages == collected),
        Err(_) => assert!(failed),
    }
});
