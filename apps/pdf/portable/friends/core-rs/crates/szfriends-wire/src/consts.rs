//! Session constants (`SZFriendsSession.h`, `SZFriendsSessionLimits.m`). Times are in seconds.

/// The preamble's major version.
pub const SESSION_MAJOR: u8 = 1;
/// The highest session minor this build speaks: 1 added THUMBNAIL, 2 CHAIN (and JOIN, SYNC), 3 AGAIN, 4 fast transfers
/// (HASHES, WANT, PART, HAVE; ADR 0018), used only when both sides also set [`CAPABILITY_FAST_TRANSFERS`].
pub const SESSION_MINOR: u16 = 4;
/// The minor that brought fast transfers.
pub const FAST_TRANSFERS_MINOR: u16 = 4;

/// Handshake capability bits (field 26). A side uses what a bit names only when both set it and the negotiated minor
/// knows it; unknown bits are ignored.
/// Bit 0: this side runs ADR 0018's transfers (blocks, the tree, WANT and HAVE).
pub const CAPABILITY_FAST_TRANSFERS: u32 = 1 << 0;
/// Bit 1: AES-GCM lanes (ADR 0018 § 9.2): this side has hardware AES; lanes of a group whose two sides set it run
/// `Noise_IK_25519_AESGCM_BLAKE2b`.
pub const CAPABILITY_AES_LANES: u32 = 1 << 1;
/// Bit 2: compressed parts, zstd (ADR 0018 § 9.4): this side reads PARTs with Codec 1.
pub const CAPABILITY_COMPRESSED_PARTS: u32 = 1 << 2;
/// Bit 3: Pieces (field 47) in WANT and HAVE (ADR 0018 § 3). Sent only to a peer that sets it, so helpers built before
/// pieces (minor 4 never shipped without them, but development builds did) keep working with whole blocks.
pub const CAPABILITY_PIECES: u32 = 1 << 3;
/// Bit 4: compressed parts, LZ4 block format (ADR 0018 § 9.4): this side reads PARTs with Codec 2. Phones whose
/// library has no room for zstd set this one alone.
pub const CAPABILITY_LZ4_PARTS: u32 = 1 << 4;

/// Every Noise message, handshake or transport, including the 16-byte tag.
pub const NOISE_MESSAGE_MAX: usize = 65_535;
/// The AEAD tag Noise adds to every encrypted payload.
pub const NOISE_TAG_LEN: usize = 16;
/// One frame per transport message: the message limit minus the tag.
pub const FRAME_PLAINTEXT_MAX: usize = NOISE_MESSAGE_MAX - NOISE_TAG_LEN;
/// A responder refuses a longer handshake message on its length prefix, before buffering it (ADR 0001 amendment 8).
pub const RESPONDER_HANDSHAKE_MAX: usize = 1_024;

/// `"SZFriends session"` and its terminating NUL: the prologue's fixed first 18 bytes.
pub const PROLOGUE_LABEL: &[u8; 18] = b"SZFriends session\0";

pub const FRAME_TEXT_MAX: usize = 32_768;
pub const FRAME_PICTURE_MAX: usize = 49_152;
pub const FRAME_THUMBNAIL_MAX: usize = 64_000;
pub const FRAME_CHAIN_MAX: usize = 64_000;
pub const FRAME_JOIN_MAX: usize = 1_000;
pub const FRAME_SYNC_MAX: usize = 64_000;
pub const FRAME_AGAIN_MAX: usize = 64_000;
pub const ATTESTATION_MAX: usize = 512;

/// Data per CHUNK on LAN, peer-to-peer Wi-Fi and the Internet routes.
pub const CHUNK_BYTES_WIFI: usize = 61_440;
/// Data per CHUNK on Bluetooth.
pub const CHUNK_BYTES_BLUETOOTH: usize = 4_096;
/// Bytes sent but not yet covered by PROGRESS.
pub const SEND_WINDOW_WIFI: u64 = 8 * 1024 * 1024;
pub const SEND_WINDOW_BLUETOOTH: u64 = 256 * 1024;

/// Per direction: send REKEY after this many bytes or this long since that direction's last rekey.
pub const REKEY_AFTER_BYTES: u64 = 1 << 30;
pub const REKEY_AFTER_SECONDS: u64 = 900;
/// A session older than this is closed and redialed for a fresh Diffie-Hellman.
pub const SESSION_MAX_AGE_SECONDS: u64 = 86_400;
/// A handshake not live this long after it started closes.
pub const HANDSHAKE_TIMEOUT_SECONDS: u64 = 10;
/// While a transfer runs (ADR 0018 § 7): PING after this long without sending anything, so the peer always hears us.
pub const KEEPALIVE_MILLISECONDS: u64 = 1_000;
/// While a transfer runs: a session that heard nothing this long is closed locally and redialed (Bluetooth: longer).
pub const SILENCE_MILLISECONDS: u64 = 8_000;
pub const SILENCE_BLUETOOTH_MILLISECONDS: u64 = 12_000;
/// Every refusal before the responder's first reply closes exactly this long after the deciding bytes arrived.
pub const REFUSAL_DELAY_MILLISECONDS: u64 = 1_500;
/// How long a responder remembers message 1's ephemeral key against replay.
pub const REPLAY_WINDOW_SECONDS: u64 = 600;

/// Fast transfers (ADR 0018 § 2 and 3): block sizes are 2^shift bytes, shift 20 (1 MiB) to 24 (16 MiB).
pub const BLOCK_SHIFT_MIN: u8 = 20;
pub const BLOCK_SHIFT_MAX: u8 = 24;
/// Blocks in one file at most; a file needing more at 16 MiB (over 1 TiB) goes by CHUNK.
pub const BLOCKS_MAX: u32 = 65_536;
/// One leaf hash.
pub const LEAF_BYTES: usize = 32;
/// A HASHES frame's leaves at most (64,000 bytes).
pub const HASHES_PER_FRAME: usize = 2_000;
/// Range pairs `(first u32be, count u32be)` in one Ranges or Durable field at most (64,000 bytes).
pub const RANGES_PER_FIELD: usize = 8_000;
/// Data in one PART at most, and what a compressed part may expand to.
pub const PART_BYTES_MAX: usize = 61_440;
/// Per transfer: blocks wanted, partly received and not complete at once, and their bytes.
pub const BLOCKS_IN_FLIGHT_MAX: usize = 64;
pub const BYTES_IN_FLIGHT_MAX: u64 = 64 << 20;
/// Pieces (WANT and HAVE's Pieces field) are 2^14 = 16 KiB of the file; piece p covers bytes p × 16,384 up to the
/// next multiple or the end of the file.
pub const PIECE_SHIFT: u8 = 14;
/// PART's Codec values (§ 9.4): 1 is zstd.
pub const CODEC_ZSTD: u8 = 1;
/// PART's Codec 2: the LZ4 block format (no frame), Bluetooth lanes only.
pub const CODEC_LZ4: u8 = 2;
