//! Compressed parts (ADR 0018 § 9.4): on Bluetooth and relay lanes, where bytes cost most, a block whose first 64 KiB
//! shrink by at least a tenth goes as compressed PARTs; anything else (photos, video, archives, most PDFs) goes as it
//! is, after costing one sample. Each part is compressed on its own, so a part stays the unit a lane carries and a
//! piece arrives whole or not at all; a part that would not shrink goes plain.
//!
//! Two codecs, each with its capability bit, which says this side reads it:
//! - zstd level 1 (Codec 1, bit 2): the better ratio (STEP to 17 %, text to 45 %), on Bluetooth and relay lanes. Not
//!   built for Android, whose library has no room for it (ADR 0015's 5 MB).
//! - LZ4 block format (Codec 2, bit 4): about half zstd's gain (STEP to 33 %, text to 65 %) for a few kilobytes of pure
//!   Rust, everywhere; what a pair uses when one of them is a phone without zstd. Bluetooth lanes only, since LZ4 has
//!   no padding the relay could be shown instead of the exact size.
//!
//! A sender uses zstd when both sides read it, else LZ4 when both read that.
//!
//! A compressed PART carries Codec (field 44) and Length (field 45, u32be): the bytes Data expands to, at most 61,440,
//! which the receiver checks exactly before the part counts. Its Offset and the block rules are a plain part's.
//!
//! The relay sees the length of every encrypted message. So that it learns little about how compressible each part
//! is, a zstd part on a relay lane is padded to a multiple of 8 KiB with a zstd skippable frame (which every zstd
//! decoder skips): the relay sees one of seven sizes per 60 KiB part, never the exact ratio. Bluetooth is between two
//! devices in radio range; its parts are not padded.

use std::borrow::Cow;
#[cfg(not(target_os = "android"))]
use std::cell::RefCell;

#[cfg(not(target_os = "android"))]
use szfriends_wire::consts::CODEC_ZSTD;
use szfriends_wire::consts::{CAPABILITY_COMPRESSED_PARTS, CAPABILITY_LZ4_PARTS, CODEC_LZ4, PART_BYTES_MAX};
use szfriends_wire::{tag, Frame, FrameType, RouteMethod};

/// The block's first bytes tried before deciding.
pub const SAMPLE_BYTES: usize = 64 * 1024;
/// zstd's fastest level: severalfold on text and CAD files at hundreds of MB/s, far above these routes' rates.
pub const LEVEL: i32 = 1;
/// The window a zstd part may ask of the decoder at most: a part is one window.
#[cfg(not(target_os = "android"))]
const WINDOW_LOG_MAX: u32 = 17;
/// A zstd part on a relay lane is padded to a multiple of this.
pub const RELAY_PAD_BYTES: usize = 8 * 1024;
/// A zstd skippable frame: magic 0x184D2A50 (little-endian), then the length of what follows (little-endian u32).
#[cfg(not(target_os = "android"))]
const SKIPPABLE_MAGIC: u32 = 0x184D_2A50;

/// The capability bits of the codecs this build reads (and writes): zstd and LZ4, or LZ4 alone on Android.
pub fn capabilities() -> u32 {
    if cfg!(target_os = "android") {
        CAPABILITY_LZ4_PARTS
    } else {
        CAPABILITY_COMPRESSED_PARTS | CAPABILITY_LZ4_PARTS
    }
}

/// The capability bit that says a side reads `codec`; 0 for an unknown codec.
pub fn codec_bit(codec: u8) -> u32 {
    match codec {
        1 => CAPABILITY_COMPRESSED_PARTS,
        CODEC_LZ4 => CAPABILITY_LZ4_PARTS,
        _ => 0,
    }
}

/// The codec two sides use, from the bits both set (`both` = ours & theirs): zstd, else LZ4, else none.
pub fn codec_for(both: u32) -> Option<u8> {
    if both & CAPABILITY_COMPRESSED_PARTS != 0 && cfg!(not(target_os = "android")) {
        Some(1)
    } else if both & CAPABILITY_LZ4_PARTS != 0 {
        Some(CODEC_LZ4)
    } else {
        None
    }
}

/// Whether a lane on `route` sends parts compressed with `codec`: Bluetooth, and the relay for zstd only.
pub fn route_compresses(route: RouteMethod, codec: u8) -> bool {
    match route {
        RouteMethod::Bluetooth => true,
        RouteMethod::Relay => codec == 1,
        _ => false,
    }
}

#[cfg(not(target_os = "android"))]
thread_local! {
    static COMPRESSOR: RefCell<Option<zstd::bulk::Compressor<'static>>> = const { RefCell::new(None) };
    static DECOMPRESSOR: RefCell<Option<zstd::bulk::Decompressor<'static>>> = const { RefCell::new(None) };
}

#[cfg(not(target_os = "android"))]
fn zstd_compress(data: &[u8]) -> Option<Vec<u8>> {
    COMPRESSOR.with(|cell| {
        let mut cell = cell.borrow_mut();
        if cell.is_none() {
            *cell = zstd::bulk::Compressor::new(LEVEL).ok();
        }
        cell.as_mut()?.compress(data).ok()
    })
}

#[cfg(target_os = "android")]
fn zstd_compress(_: &[u8]) -> Option<Vec<u8>> {
    None
}

fn compress(data: &[u8], codec: u8) -> Option<Vec<u8>> {
    match codec {
        CODEC_LZ4 => Some(lz4_flex::block::compress(data)),
        1 => zstd_compress(data),
        _ => None,
    }
}

/// Whether a block is worth compressing with `codec`: its first [`SAMPLE_BYTES`] shrink by at least 10 %.
pub fn worth(block: &[u8], codec: u8) -> bool {
    let sample = &block[..block.len().min(SAMPLE_BYTES)];
    !sample.is_empty() && compress(sample, codec).is_some_and(|c| c.len() * 10 <= sample.len() * 9)
}

/// `packed` padded to the next multiple of [`RELAY_PAD_BYTES`] with a skippable frame (at least its 8-byte header).
#[cfg(not(target_os = "android"))]
fn padded(mut packed: Vec<u8>) -> Vec<u8> {
    let target = (packed.len() + 8).div_ceil(RELAY_PAD_BYTES) * RELAY_PAD_BYTES;
    let filler = target - packed.len() - 8;
    packed.extend_from_slice(&SKIPPABLE_MAGIC.to_le_bytes());
    packed.extend_from_slice(&(filler as u32).to_le_bytes());
    packed.resize(target, 0);
    packed
}

#[cfg(target_os = "android")]
fn padded(packed: Vec<u8>) -> Vec<u8> {
    packed
}

/// `part` (a plain PART) compressed with `codec` for a lane on `route`, when that makes it smaller (a zstd part padded
/// on the relay); otherwise unchanged.
pub fn compress_part(part: Frame, route: RouteMethod, codec: u8) -> Frame {
    let Some(data) = part.get(tag::DATA) else { return part };
    let relay = route == RouteMethod::Relay;
    let packed = compress(data, codec).map(|p| if relay && codec == 1 { padded(p) } else { p });
    match packed {
        Some(packed) if packed.len() < data.len() => {
            let length = data.len() as u32;
            let mut frame = part.with(tag::CODEC, [codec]).with(tag::LENGTH, length.to_be_bytes());
            frame.fields.insert(tag::DATA, packed);
            frame
        }
        _ => part,
    }
}

/// Why a compressed part was refused; the session closes, as for any malformed part.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExpandError {
    /// A codec this build does not read, or Length without Codec.
    Codec,
    /// Codec without Length, or Length 0 or over 61,440.
    Length,
    /// Data that does not expand to exactly Length bytes.
    Data,
}

#[cfg(not(target_os = "android"))]
fn zstd_expand(data: &[u8], length: usize) -> Option<Vec<u8>> {
    DECOMPRESSOR.with(|cell| {
        let mut cell = cell.borrow_mut();
        if cell.is_none() {
            let mut decompressor = zstd::bulk::Decompressor::new().ok()?;
            decompressor.window_log_max(WINDOW_LOG_MAX).ok()?;
            *cell = Some(decompressor);
        }
        cell.as_mut()?.decompress(data, length).ok()
    })
}

/// A PART's file bytes: its Data, expanded when it carries Codec. Checks what § 8 asks: a codec this build reads,
/// Length present and at most 61,440, and Data expanding to exactly Length bytes (never more is allocated). Whether
/// the session negotiated that codec is the caller's check ([`codec_bit`]).
pub fn part_data(frame: &Frame) -> Result<Cow<'_, [u8]>, ExpandError> {
    debug_assert_eq!(frame.frame_type, FrameType::Part);
    let data = frame.get(tag::DATA).unwrap_or_default();
    let (codec, length) = (frame.get(tag::CODEC), frame.integer(tag::LENGTH));
    let codec = match (codec, length) {
        (None, None) => return Ok(Cow::Borrowed(data)),
        (Some([codec]), _) if capabilities() & codec_bit(*codec) != 0 => *codec,
        _ => return Err(ExpandError::Codec),
    };
    let Some(length) = length.filter(|l| (1..=PART_BYTES_MAX as u64).contains(l)) else {
        return Err(ExpandError::Length);
    };
    let length = length as usize;
    let expanded = match codec {
        CODEC_LZ4 => {
            let mut out = vec![0u8; length];
            lz4_flex::block::decompress_into(data, &mut out).ok().filter(|n| *n == length).map(|_| out)
        }
        #[cfg(not(target_os = "android"))]
        CODEC_ZSTD => zstd_expand(data, length),
        _ => None,
    };
    match expanded {
        Some(bytes) if bytes.len() == length => Ok(Cow::Owned(bytes)),
        _ => Err(ExpandError::Data),
    }
}

/// Whether a PART is compressed, and with which codec (0 for Length without Codec, which is refused).
pub fn codec_of(frame: &Frame) -> Option<u8> {
    match (frame.get(tag::CODEC), frame.get(tag::LENGTH)) {
        (Some([codec]), _) => Some(*codec),
        (Some(_), _) | (None, Some(_)) => Some(0),
        (None, None) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transfer::frames;

    const ZSTD: u8 = 1;

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

    fn with(codec: Option<u8>, length: Option<u32>, data: &[u8]) -> Frame {
        let mut frame = frames::part(&[1; 16], 0, data);
        if let Some(codec) = codec {
            frame = frame.with(tag::CODEC, [codec]);
        }
        if let Some(length) = length {
            frame = frame.with(tag::LENGTH, length.to_be_bytes());
        }
        frame
    }

    #[test]
    fn text_goes_compressed_with_either_codec_and_comes_back_exactly() {
        let block = text(1 << 20);
        for (codec, at_most) in [(ZSTD, 2_000), (CODEC_LZ4, 6_000)] {
            assert!(worth(&block, codec));
            let part = compress_part(frames::part(&[1; 16], 4096, &block[..16_384]), RouteMethod::Bluetooth, codec);
            assert_eq!(part.get(tag::CODEC), Some(&[codec][..]));
            assert_eq!(part.integer(tag::LENGTH), Some(16_384));
            assert!(part.get(tag::DATA).unwrap().len() < at_most, "codec {codec}");
            let decoded = Frame::decode(&part.encode().unwrap()).unwrap();
            assert_eq!(part_data(&decoded).unwrap().as_ref(), &block[..16_384]);
        }
    }

    #[test]
    fn incompressible_blocks_and_parts_go_plain() {
        let block = noise(1 << 20);
        for codec in [ZSTD, CODEC_LZ4] {
            assert!(!worth(&block, codec));
            let part = compress_part(frames::part(&[1; 16], 0, &noise(4_096)), RouteMethod::Bluetooth, codec);
            assert_eq!(codec_of(&part), None);
        }
    }

    #[test]
    fn a_part_must_expand_to_exactly_its_length() {
        let data = text(20_000);
        for (codec, packed) in
            [(ZSTD, zstd::bulk::compress(&data, LEVEL).unwrap()), (CODEC_LZ4, lz4_flex::block::compress(&data))]
        {
            assert!(part_data(&with(Some(codec), Some(20_000), &packed)).is_ok());
            assert_eq!(part_data(&with(Some(codec), Some(19_999), &packed)), Err(ExpandError::Data), "{codec}");
            assert_eq!(part_data(&with(Some(codec), Some(20_001), &packed)), Err(ExpandError::Data), "{codec}");
            assert_eq!(part_data(&with(Some(codec), None, &packed)), Err(ExpandError::Length));
            assert_eq!(part_data(&with(Some(codec), Some(0), &packed)), Err(ExpandError::Length));
            assert_eq!(part_data(&with(Some(codec), Some(61_441), &packed)), Err(ExpandError::Length));
            let cut = &packed[..packed.len() - 1];
            assert_eq!(part_data(&with(Some(codec), Some(20_000), cut)), Err(ExpandError::Data), "{codec}");
        }
        let packed = zstd::bulk::compress(&data, LEVEL).unwrap();
        assert_eq!(part_data(&with(Some(3), Some(20_000), &packed)), Err(ExpandError::Codec));
        assert_eq!(part_data(&with(None, Some(20_000), &packed)), Err(ExpandError::Codec));
        // Bombs: a megabyte of zeros said to be 61,440 bytes.
        let zeros = vec![0u8; 1 << 20];
        let bombs =
            [(ZSTD, zstd::bulk::compress(&zeros, LEVEL).unwrap()), (CODEC_LZ4, lz4_flex::block::compress(&zeros))];
        for (codec, bomb) in bombs {
            assert_eq!(part_data(&with(Some(codec), Some(61_440), &bomb)), Err(ExpandError::Data), "{codec}");
        }
    }

    #[test]
    fn relay_parts_are_zstd_padded_to_8_kib_and_still_expand_exactly() {
        let data = text(61_440);
        let bluetooth = compress_part(frames::part(&[1; 16], 0, &data), RouteMethod::Bluetooth, ZSTD);
        let relay = compress_part(frames::part(&[1; 16], 0, &data), RouteMethod::Relay, ZSTD);
        let (exact, padded) = (bluetooth.get(tag::DATA).unwrap().len(), relay.get(tag::DATA).unwrap().len());
        assert!(exact < RELAY_PAD_BYTES - 8, "{exact}");
        assert_eq!(padded, RELAY_PAD_BYTES);
        assert_eq!(part_data(&relay).unwrap().as_ref(), &data[..]);
        let mut half = text(30_720);
        half.extend(noise(30_720));
        let relay = compress_part(frames::part(&[1; 16], 0, &half), RouteMethod::Relay, ZSTD);
        assert_eq!(relay.get(tag::DATA).unwrap().len() % RELAY_PAD_BYTES, 0);
        assert_eq!(part_data(&relay).unwrap().as_ref(), &half[..]);
        let mostly = [text(4_096), noise(57_344)].concat();
        assert_eq!(codec_of(&compress_part(frames::part(&[1; 16], 0, &mostly), RouteMethod::Relay, ZSTD)), None);
    }

    #[test]
    fn zstd_first_lz4_with_a_phone_and_lz4_never_on_the_relay() {
        assert_eq!(codec_for(CAPABILITY_COMPRESSED_PARTS | CAPABILITY_LZ4_PARTS), Some(ZSTD));
        assert_eq!(codec_for(CAPABILITY_LZ4_PARTS), Some(CODEC_LZ4));
        assert_eq!(codec_for(0), None);
        assert!(route_compresses(RouteMethod::Bluetooth, CODEC_LZ4) && route_compresses(RouteMethod::Relay, ZSTD));
        assert!(!route_compresses(RouteMethod::Relay, CODEC_LZ4));
        assert!(!route_compresses(RouteMethod::Lan, ZSTD) && !route_compresses(RouteMethod::Internet, ZSTD));
    }
}
