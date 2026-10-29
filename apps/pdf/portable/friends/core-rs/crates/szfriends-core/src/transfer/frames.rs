//! Building and reading the minor-4 frames (ADR 0018 § 3) and the OFFER and OFFER_REPLY fields.

use szfriends_wire::consts::HASHES_PER_FRAME;
use szfriends_wire::{ranges, tag, Frame, FrameType};

use super::geometry::Geometry;
use super::tree::Leaf;

/// HASHES frames carrying every leaf, in order.
pub fn hashes(id: &[u8], leaves: &[Leaf]) -> Vec<Frame> {
    leaves
        .chunks(HASHES_PER_FRAME)
        .enumerate()
        .map(|(n, chunk)| {
            Frame::new(FrameType::Hashes)
                .with(tag::ID, id.to_vec())
                .with(tag::INDEX, ((n * HASHES_PER_FRAME) as u32).to_be_bytes())
                .with(tag::HASHES, chunk.concat())
        })
        .collect()
}

/// WANT frames naming `missing`; none when nothing is missing.
pub fn want(id: &[u8], missing: &[(u32, u32)]) -> Vec<Frame> {
    ranges::encode(missing)
        .into_iter()
        .map(|field| Frame::new(FrameType::Want).with(tag::ID, id.to_vec()).with(tag::RANGES, field))
        .collect()
}

/// WANT frames naming missing blocks and, in blocks partly received, missing pieces (ADR 0018 § 3); none when
/// nothing is missing.
pub fn want_with_pieces(id: &[u8], blocks: &[(u32, u32)], pieces: &[(u32, u32)]) -> Vec<Frame> {
    paired(FrameType::Want, id, &[(tag::RANGES, blocks), (tag::PIECES, pieces)])
}

/// HAVE frames for blocks newly complete and durable, and pieces that arrived in blocks not yet complete.
pub fn have_with_pieces(
    id: &[u8],
    complete: &[(u32, u32)],
    durable: &[(u32, u32)],
    pieces: &[(u32, u32)],
) -> Vec<Frame> {
    paired(FrameType::Have, id, &[(tag::RANGES, complete), (tag::DURABLE, durable), (tag::PIECES, pieces)])
}

/// Frames of `frame_type` carrying each field's ranges, as many frames as the longest needs.
fn paired(frame_type: FrameType, id: &[u8], fields: &[(u8, &[(u32, u32)])]) -> Vec<Frame> {
    let mut encoded: Vec<(u8, std::vec::IntoIter<Vec<u8>>)> =
        fields.iter().map(|(t, r)| (*t, ranges::encode(r).into_iter())).collect();
    let mut frames = Vec::new();
    loop {
        let mut frame = Frame::new(frame_type).with(tag::ID, id.to_vec());
        let mut any = false;
        for (field, values) in &mut encoded {
            if let Some(value) = values.next() {
                frame = frame.with(*field, value);
                any = true;
            }
        }
        if !any {
            return frames;
        }
        frames.push(frame);
    }
}

/// The pieces covering file bytes `[start, end)`: whole pieces only.
pub fn whole_pieces(start: u64, end: u64, size: u64) -> Option<(u32, u32)> {
    let shift = szfriends_wire::consts::PIECE_SHIFT;
    let first = start.div_ceil(1 << shift);
    let last = if end >= size { size.div_ceil(1 << shift) } else { end >> shift };
    (last > first).then(|| (first as u32, (last - first) as u32))
}

/// HAVE frames for blocks newly complete and newly durable; none when neither changed.
pub fn have(id: &[u8], complete: &[(u32, u32)], durable: &[(u32, u32)]) -> Vec<Frame> {
    let (mut complete, mut durable) = (ranges::encode(complete).into_iter(), ranges::encode(durable).into_iter());
    let mut frames = Vec::new();
    loop {
        let (c, d) = (complete.next(), durable.next());
        if c.is_none() && d.is_none() {
            return frames;
        }
        let mut frame = Frame::new(FrameType::Have).with(tag::ID, id.to_vec());
        if let Some(c) = c {
            frame = frame.with(tag::RANGES, c);
        }
        if let Some(d) = d {
            frame = frame.with(tag::DURABLE, d);
        }
        frames.push(frame);
    }
}

pub fn part(id: &[u8], offset: u64, data: &[u8]) -> Frame {
    Frame::new(FrameType::Part).with(tag::ID, id.to_vec()).with(tag::OFFSET, offset.to_be_bytes()).with(tag::DATA, data)
}

/// A Ranges or Durable field, decoded; `Some(empty)` when the frame does not carry it, `None` when it is malformed.
pub fn ranges_of(frame: &Frame, field: u8) -> Option<Vec<(u32, u32)>> {
    match frame.get(field) {
        Some(bytes) => ranges::decode(bytes),
        None => (!frame.fields.contains_key(&field)).then(Vec::new),
    }
}

/// The OFFER fields that announce the tree.
pub fn offer_with_tree(offer: Frame, geometry: &Geometry, root: &Leaf) -> Frame {
    offer.with(tag::TREE_ROOT, root.to_vec()).with(tag::BLOCK_SHIFT, [geometry.shift])
}

/// The tree an OFFER announces, when it announces one that fits its size.
pub fn offered_tree(offer: &Frame) -> Option<(Geometry, Leaf)> {
    let root: Leaf = offer.get(tag::TREE_ROOT)?.try_into().ok()?;
    let shift = offer.integer(tag::BLOCK_SHIFT)? as u8;
    Some((Geometry::new(offer.integer(tag::SIZE)?, shift)?, root))
}

/// OFFER_REPLY's Blocks: the receiver takes the file by blocks.
pub fn takes_blocks(reply: &Frame) -> bool {
    reply.integer(tag::BLOCKS) == Some(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pieces_cover_whole_16_kib_units_and_the_file_end() {
        assert_eq!(whole_pieces(0, 16_384, 100_000), Some((0, 1)));
        assert_eq!(whole_pieces(1, 40_000, 100_000), Some((1, 1)), "a piece counts once every byte of it arrived");
        assert_eq!(whole_pieces(98_304, 100_000, 100_000), Some((6, 1)), "the last piece is shorter");
        assert_eq!(whole_pieces(10, 20, 100_000), None);
        let want = want_with_pieces(&[1; 16], &[], &[(4, 2)]);
        assert_eq!((want.len(), want[0].get(tag::RANGES)), (1, None));
        assert!(want_with_pieces(&[1; 16], &[], &[]).is_empty());
    }
}
