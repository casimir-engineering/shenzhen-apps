//! Compressed parts (ADR 0018 § 9.4, capability bit 2): on Bluetooth and relay lanes, where bytes cost most, a block
//! whose first 64 KiB shrink by at least a tenth under zstd level 1 goes as compressed PARTs; anything else (photos,
//! video, archives, most PDFs) goes as it is, after costing one sample. Each part is compressed on its own, so a part
//! stays the unit a lane carries and a piece arrives whole or not at all; a part that would not shrink goes plain.
//!
//! A compressed PART carries Codec (field 44, 1 = zstd) and Length (field 45, u32be): the bytes Data expands to, at
//! most 61,440, which the receiver checks exactly before the part counts. Its Offset and the block rules are a plain
//! part's, so nothing else in the transfer changes.
//!
//! The relay sees the length of every encrypted message. So that it learns little about how compressible each part
//! is, a compressed part on a relay lane is padded to a multiple of 8 KiB with a zstd skippable frame (which every
//! zstd decoder skips): the relay sees one of seven sizes per 60 KiB part, never the exact ratio. Bluetooth is
//! between two devices in radio range; its parts are not padded.

use std::borrow::Cow;
use std::cell::RefCell;

use szfriends_wire::consts::{CODEC_ZSTD, PART_BYTES_MAX};
use szfriends_wire::{tag, Frame, FrameType, RouteMethod};

/// The block's first bytes tried before deciding.
pub const SAMPLE_BYTES: usize = 64 * 1024;
/// zstd's fastest level: severalfold on text and CAD files at hundreds of MB/s, far above these routes' rates.
pub const LEVEL: i32 = 1;
/// The window a compressed part may ask of the decoder at most: a part is one window.
const WINDOW_LOG_MAX: u32 = 17;
/// A compressed part on a relay lane is padded to a multiple of this.
pub const RELAY_PAD_BYTES: usize = 8 * 1024;
/// A zstd skippable frame: magic 0x184D2A50 (little-endian), then the length of what follows (little-endian u32).
const SKIPPABLE_MAGIC: u32 = 0x184D_2A50;

/// Whether this route's lanes send compressed parts (on a session that negotiated bit 2): Bluetooth and the relay.
pub fn route_compresses(route: RouteMethod) -> bool {
    matches!(route, RouteMethod::Bluetooth | RouteMethod::Relay)
}

thread_local! {
    static COMPRESSOR: RefCell<Option<zstd::bulk::Compressor<'static>>> = const { RefCell::new(None) };
    static DECOMPRESSOR: RefCell<Option<zstd::bulk::Decompressor<'static>>> = const { RefCell::new(None) };
}

fn compress(data: &[u8]) -> Option<Vec<u8>> {
    COMPRESSOR.with(|cell| {
        let mut cell = cell.borrow_mut();
        if cell.is_none() {
            *cell = zstd::bulk::Compressor::new(LEVEL).ok();
        }
        cell.as_mut()?.compress(data).ok()
    })
}

/// Whether a block is worth compressing: its first [`SAMPLE_BYTES`] shrink by at least 10 %.
pub fn worth(block: &[u8]) -> bool {
    let sample = &block[..block.len().min(SAMPLE_BYTES)];
    !sample.is_empty() && compress(sample).is_some_and(|c| c.len() * 10 <= sample.len() * 9)
}

/// `packed` padded to the next multiple of [`RELAY_PAD_BYTES`] with a skippable frame (at least its 8-byte header).
fn padded(mut packed: Vec<u8>) -> Vec<u8> {
    let target = (packed.len() + 8).div_ceil(RELAY_PAD_BYTES) * RELAY_PAD_BYTES;
    let filler = target - packed.len() - 8;
    packed.extend_from_slice(&SKIPPABLE_MAGIC.to_le_bytes());
    packed.extend_from_slice(&(filler as u32).to_le_bytes());
    packed.resize(target, 0);
    packed
}

/// `part` (a plain PART) compressed for a lane on `route`, when that makes it smaller (padded on the relay);
/// otherwise unchanged.
pub fn compress_part(part: Frame, route: RouteMethod) -> Frame {
    let Some(data) = part.get(tag::DATA) else { return part };
    let packed = compress(data).map(|p| if route == RouteMethod::Relay { padded(p) } else { p });
    match packed {
        Some(packed) if packed.len() < data.len() => {
            let length = data.len() as u32;
            let mut frame = part.with(tag::CODEC, [CODEC_ZSTD]).with(tag::LENGTH, length.to_be_bytes());
            frame.fields.insert(tag::DATA, packed);
            frame
        }
        _ => part,
    }
}

/// Why a compressed part was refused; the session closes, as for any malformed part.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExpandError {
    /// A codec other than zstd, or Length without Codec.
    Codec,
    /// Codec without Length, or Length 0 or over 61,440.
    Length,
    /// Data that does not expand to exactly Length bytes.
    Data,
}

/// A PART's file bytes: its Data, expanded when it carries Codec. Checks what § 8 asks: the codec is zstd, Length is
/// present and at most 61,440, and Data expands to exactly Length bytes (never more is allocated).
pub fn part_data(frame: &Frame) -> Result<Cow<'_, [u8]>, ExpandError> {
    debug_assert_eq!(frame.frame_type, FrameType::Part);
    let data = frame.get(tag::DATA).unwrap_or_default();
    let (codec, length) = (frame.get(tag::CODEC), frame.integer(tag::LENGTH));
    match (codec, length) {
        (None, None) => Ok(Cow::Borrowed(data)),
        (Some([CODEC_ZSTD]), Some(length)) if (1..=PART_BYTES_MAX as u64).contains(&length) => {
            let expanded = DECOMPRESSOR.with(|cell| {
                let mut cell = cell.borrow_mut();
                if cell.is_none() {
                    let mut decompressor = zstd::bulk::Decompressor::new().ok()?;
                    decompressor.window_log_max(WINDOW_LOG_MAX).ok()?;
                    *cell = Some(decompressor);
                }
                cell.as_mut()?.decompress(data, length as usize).ok()
            });
            match expanded {
                Some(bytes) if bytes.len() as u64 == length => Ok(Cow::Owned(bytes)),
                _ => Err(ExpandError::Data),
            }
        }
        (Some([CODEC_ZSTD]), _) => Err(ExpandError::Length),
        _ => Err(ExpandError::Codec),
    }
}

/// Whether a PART is compressed.
pub fn is_compressed(frame: &Frame) -> bool {
    frame.get(tag::CODEC).is_some() || frame.get(tag::LENGTH).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transfer::frames;

    fn text(length: usize) -> Vec<u8> {
        b"ISO-10303-21; #42=CARTESIAN_POINT('',(0.,12.5,3.));\n".iter().copied().cycle().take(length).collect()
    }

    fn noise(length: usize) -> Vec<u8> {
        let mut state = 0x2545_f491_4f6c_dd1du64;
        (0..length)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect()
    }

    #[test]
    fn text_goes_compressed_and_comes_back_exactly() {
        let block = text(1 << 20);
        assert!(worth(&block));
        let part = compress_part(frames::part(&[1; 16], 4096, &block[..16_384]), RouteMethod::Bluetooth);
        assert_eq!(part.get(tag::CODEC), Some(&[CODEC_ZSTD][..]));
        assert_eq!(part.integer(tag::LENGTH), Some(16_384));
        assert!(part.get(tag::DATA).unwrap().len() < 2_000);
        assert_eq!(part_data(&part).unwrap().as_ref(), &block[..16_384]);
        let decoded = Frame::decode(&part.encode().unwrap()).unwrap();
        assert_eq!(part_data(&decoded).unwrap().as_ref(), &block[..16_384]);
    }

    #[test]
    fn incompressible_blocks_and_parts_go_plain() {
        let block = noise(1 << 20);
        assert!(!worth(&block));
        // A part of noise inside a compressible block stays plain too.
        let part = compress_part(frames::part(&[1; 16], 0, &noise(4_096)), RouteMethod::Bluetooth);
        assert!(!is_compressed(&part));
    }

    #[test]
    fn a_part_must_expand_to_exactly_its_length() {
        let data = text(20_000);
        let packed = zstd::bulk::compress(&data, LEVEL).unwrap();
        let with = |codec: Option<u8>, length: Option<u32>, data: &[u8]| {
            let mut frame = frames::part(&[1; 16], 0, data);
            if let Some(codec) = codec {
                frame = frame.with(tag::CODEC, [codec]);
            }
            if let Some(length) = length {
                frame = frame.with(tag::LENGTH, length.to_be_bytes());
            }
            frame
        };
        assert!(part_data(&with(Some(1), Some(20_000), &packed)).is_ok());
        assert_eq!(part_data(&with(Some(1), Some(19_999), &packed)), Err(ExpandError::Data), "longer than said");
        assert_eq!(part_data(&with(Some(1), Some(20_001), &packed)), Err(ExpandError::Data), "shorter than said");
        assert_eq!(part_data(&with(Some(2), Some(20_000), &packed)), Err(ExpandError::Codec));
        assert_eq!(part_data(&with(None, Some(20_000), &packed)), Err(ExpandError::Codec));
        assert_eq!(part_data(&with(Some(1), None, &packed)), Err(ExpandError::Length));
        assert_eq!(part_data(&with(Some(1), Some(0), &packed)), Err(ExpandError::Length));
        assert_eq!(part_data(&with(Some(1), Some(61_441), &packed)), Err(ExpandError::Length));
        assert_eq!(part_data(&with(Some(1), Some(20_000), &packed[..packed.len() - 1])), Err(ExpandError::Data));
        // A bomb: 61,440 bytes of zeros claims a length within the limit, but would expand past it.
        let bomb = zstd::bulk::compress(&vec![0u8; 1 << 20], LEVEL).unwrap();
        assert_eq!(part_data(&with(Some(1), Some(61_440), &bomb)), Err(ExpandError::Data));
    }

    #[test]
    fn relay_parts_are_padded_to_8_kib_and_still_expand_exactly() {
        let data = text(61_440);
        let bluetooth = compress_part(frames::part(&[1; 16], 0, &data), RouteMethod::Bluetooth);
        let relay = compress_part(frames::part(&[1; 16], 0, &data), RouteMethod::Relay);
        let (exact, padded) = (bluetooth.get(tag::DATA).unwrap().len(), relay.get(tag::DATA).unwrap().len());
        assert!(exact < RELAY_PAD_BYTES - 8, "{exact}");
        assert_eq!(padded, RELAY_PAD_BYTES);
        assert_eq!(part_data(&relay).unwrap().as_ref(), &data[..]);
        // Half compressible: still a multiple of 8 KiB, and plain when padding would not save anything.
        let mut half = text(30_720);
        half.extend(noise(30_720));
        let relay = compress_part(frames::part(&[1; 16], 0, &half), RouteMethod::Relay);
        assert_eq!(relay.get(tag::DATA).unwrap().len() % RELAY_PAD_BYTES, 0);
        assert_eq!(part_data(&relay).unwrap().as_ref(), &half[..]);
        let mostly = [text(4_096), noise(57_344)].concat();
        assert!(!is_compressed(&compress_part(frames::part(&[1; 16], 0, &mostly), RouteMethod::Relay)));
    }

    #[test]
    fn only_bluetooth_and_the_relay_compress() {
        assert!(route_compresses(RouteMethod::Bluetooth) && route_compresses(RouteMethod::Relay));
        assert!(!route_compresses(RouteMethod::Lan) && !route_compresses(RouteMethod::Internet));
    }
}
