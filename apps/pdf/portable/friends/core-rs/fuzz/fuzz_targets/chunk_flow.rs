//! The chunk flow fed arbitrary frames as a peer would send them: CHUNK, PROGRESS and DONE for any offer, offset and
//! length. The receiver's offsets only grow, never past the size or the window; the sender's durable offset never
//! passes what it sent.

#![no_main]

use libfuzzer_sys::fuzz_target;
use szfriends_core::session::{ChunkReceiver, ChunkSender};
use szfriends_core::wire::Frame;

fuzz_target!(|data: &[u8]| {
    let Some((&sizes, rest)) = data.split_first() else { return };
    let size = u64::from(sizes) * 997;
    let id = [5u8; 16];
    let window = 8 * 4096;
    let (Some(mut receiver), Some(mut sender)) =
        (ChunkReceiver::new(&id, size, 0, 4096, window), ChunkSender::new(&id, size, 0, 4096, window))
    else {
        return;
    };
    for piece in rest.split(|b| *b == 0xff) {
        let Ok(frame) = Frame::decode(piece) else { continue };
        let before = receiver.received_offset();
        if receiver.accept_chunk(&frame).is_ok() {
            assert!(receiver.received_offset() > before && receiver.received_offset() <= size);
            assert!(receiver.received_offset() <= receiver.reported_offset() + window);
        }
        let _ = receiver.accept_done(&frame);
        if let Some((_, length)) = sender.next_chunk() {
            let _ = sender.chunk_frame(&vec![0; length]);
        }
        let _ = sender.handle_progress(&frame);
        assert!(sender.durable_offset() <= sender.sent_offset() && sender.sent_offset() <= size);
    }
});
