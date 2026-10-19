//! Session constants (`SZFriendsSession.h`, `SZFriendsSessionLimits.m`). Times are in seconds.

/// The preamble's major version.
pub const SESSION_MAJOR: u8 = 1;
/// The highest session minor this build speaks: 1 added THUMBNAIL, 2 CHAIN (and JOIN, SYNC).
pub const SESSION_MINOR: u16 = 2;

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
/// Every refusal before the responder's first reply closes exactly this long after the deciding bytes arrived.
pub const REFUSAL_DELAY_MILLISECONDS: u64 = 1_500;
/// How long a responder remembers message 1's ephemeral key against replay.
pub const REPLAY_WINDOW_SECONDS: u64 = 600;
