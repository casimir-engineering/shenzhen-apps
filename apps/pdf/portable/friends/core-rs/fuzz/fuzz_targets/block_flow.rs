//! Fast transfers fed arbitrary frames as a peer would send them (ADR 0018 § 3): HASHES, PART, WANT and HAVE for a
//! small file. The receiver holds at most 64 blocks in flight, takes nothing before its leaves and never counts a
//! block complete whose bytes miss its leaf; the sender never names a block past the file; ranges decode only when
//! ascending, disjoint and non-empty.

#![no_main]

use libfuzzer_sys::fuzz_target;
use szfriends_core::transfer::{frames, tree, BlockAssembly, BlockServe, Geometry, PartOutcome};
use szfriends_core::wire::{ranges, tag, Frame, FrameType};

fuzz_target!(|data: &[u8]| {
    let Some((&size_byte, rest)) = data.split_first() else { return };
    let size = u64::from(size_byte) * 40_000 + 1;
    let geometry = Geometry::for_size(size).expect("small");
    let content: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
    let leaves: Vec<tree::Leaf> = (0..geometry.blocks)
        .map(|i| {
            let (offset, length) = geometry.span(i);
            tree::leaf(i, &content[offset as usize..offset as usize + length])
        })
        .collect();
    let root = tree::root_of(&geometry, &leaves).expect("one leaf per block");
    let mut assembly = BlockAssembly::new(geometry, root);
    let mut serve = BlockServe::new(&[5; 16], geometry, leaves.clone(), 4096, 2 << 20);
    for piece in rest.split(|b| *b == 0xff) {
        let Ok(frame) = Frame::decode(piece) else { continue };
        for field in [tag::RANGES, tag::DURABLE] {
            if let Some(Some(list)) = frame.get(field).map(ranges::decode) {
                assert!(list.windows(2).all(|w| u64::from(w[0].0) + u64::from(w[0].1) <= u64::from(w[1].0)));
            }
        }
        match frame.frame_type {
            FrameType::Hashes => {
                let (Some(index), Some(hashes)) = (frame.integer(tag::INDEX), frame.get(tag::HASHES)) else { continue };
                if assembly.accept_hashes(index as u32, hashes) == Ok(true) {
                    assert_eq!(assembly.leaves(), Some(&leaves[..]), "only the true leaves check against the root");
                }
            }
            FrameType::Part => {
                let (Some(offset), Some(bytes)) = (frame.integer(tag::OFFSET), frame.get(tag::DATA)) else { continue };
                if let Ok(PartOutcome::Complete { block, data }) = assembly.accept_part(offset, bytes) {
                    let (start, length) = geometry.span(block);
                    assert_eq!(data, content[start as usize..start as usize + length], "a block that checks is right");
                }
            }
            FrameType::Want | FrameType::Have => {
                let Some(list) = frames::ranges_of(&frame, tag::RANGES) else { continue };
                let _ = if frame.frame_type == FrameType::Want { serve.want(&list) } else { serve.have(&list) };
                if let Some(block) = serve.next_block() {
                    assert!(block < geometry.blocks);
                    let (offset, length) = geometry.span(block);
                    serve.load_block(block, content[offset as usize..offset as usize + length].to_vec()).expect("intact");
                    while serve.next_part().is_some() {}
                }
            }
            _ => {}
        }
    }
});
