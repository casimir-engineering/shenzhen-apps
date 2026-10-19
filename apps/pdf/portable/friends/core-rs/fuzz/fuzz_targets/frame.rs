//! The frame and field decoder (`Frame::decode`), which sees every decrypted byte a peer sends, with the invariants of
//! the helper's harness (`service/thumbnails/fuzz/SZFriendsFuzzFrame.m`): a frame that decodes re-encodes and decodes
//! again to the same type and fields, and its typed accessors agree with its raw fields.

#![no_main]

use libfuzzer_sys::fuzz_target;
use szfriends_wire::{fields, Frame, HandshakePayload};

fuzz_target!(|data: &[u8]| {
    if let Ok(frame) = Frame::decode(data) {
        let encoded = frame.encode().expect("a decoded frame re-encodes");
        assert_eq!(Frame::decode(&encoded).expect("and decodes again"), frame);
        for (&tag, value) in &frame.fields {
            assert_eq!(frame.get(tag), Some(value.as_slice()), "every decoded field passed its rule");
            let _ = frame.text(tag);
            if let Some(number) = frame.integer(tag) {
                assert_eq!(&fields::integer(number, tag).expect("fits its width"), value);
            }
        }
    }
    // Handshake payloads are the same fields without a type byte: the whole input, and the input after one byte.
    let _ = HandshakePayload::decode(data);
    if let Some(tail) = data.get(1..) {
        if let Ok(payload) = HandshakePayload::decode(tail) {
            let _ = payload.encode();
        }
    }
});
