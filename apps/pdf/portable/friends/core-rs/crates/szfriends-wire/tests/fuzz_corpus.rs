//! Every entry of the helper's libFuzzer corpus for the frame parser (`service/thumbnails/fuzz/corpus/frame`, which
//! also seeds `fuzz/` here), replayed through the Rust codecs with the fuzz target's invariants, on every platform
//! the suites run on: a frame that decodes re-encodes and decodes again to itself, its accessors agree with its raw
//! fields, and payload decoding never panics. A crash a fuzz run once found stays found.

use szfriends_wire::{fields, Frame, HandshakePayload};

#[test]
fn the_helpers_frame_corpus_replays_cleanly() {
    let directory = szfriends_vectors::friends_dir().join("service/thumbnails/fuzz/corpus/frame");
    let entries: Vec<_> =
        std::fs::read_dir(&directory).unwrap_or_else(|e| panic!("{}: {e}", directory.display())).flatten().collect();
    assert!(entries.len() > 100, "the corpus is missing entries");
    let mut decoded = 0;
    for entry in entries {
        let data = std::fs::read(entry.path()).unwrap();
        if let Ok(frame) = Frame::decode(&data) {
            decoded += 1;
            let encoded = frame.encode().expect("a decoded frame re-encodes");
            assert_eq!(Frame::decode(&encoded).expect("and decodes again"), frame);
            for (&tag, value) in &frame.fields {
                assert_eq!(frame.get(tag), Some(value.as_slice()));
                if let Some(number) = frame.integer(tag) {
                    assert_eq!(&fields::integer(number, tag).unwrap(), value);
                }
            }
        }
        let _ = HandshakePayload::decode(&data);
        if let Some(Ok(payload)) = data.get(1..).map(HandshakePayload::decode) {
            let _ = payload.encode();
        }
    }
    assert!(decoded > 0, "no entry decodes: the corpus no longer exercises the decoder");
}
