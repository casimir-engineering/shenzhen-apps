//! Sessions (`service/session/`, ADR 0001): the Noise secure channel above every route, the replay cache, and the
//! windowed chunk flow of file transfers.
//!
//! The channel is sans-IO: it never touches a socket, a thread or a clock. Its driver feeds it the bytes the route
//! delivered ([`SecureChannel::receive`]) and the time ([`SecureChannel::handle_timeout`] at
//! [`SecureChannel::poll_timeout`]), writes what [`SecureChannel::poll_transmit`] hands out in order, reports each
//! write done ([`SecureChannel::write_completed`]), and reads [`Event`]s. The same state machine then runs over TCP,
//! L2CAP, a data channel or a test's memory pipe, and every timer is testable without waiting. It mirrors
//! `SZFriendsSecureChannel` rule for rule, and the transcripts the helper exports (`objc-session.json`) replay through
//! it byte for byte.
//!
//! Time is a [`Duration`] since an arbitrary origin that keeps counting while the device sleeps
//! ([`monotonic_now`]), so a session that slept through the night is old.

mod channel;
mod chunk;
mod closing;
mod code;
mod handshake;
pub mod lanes;
mod liveness;
mod replay;
mod transport;

use std::fmt;
use std::time::Duration;

use szfriends_identity::Identity;
use szfriends_wire::consts;
use szfriends_wire::{Fields, Frame};
use zeroize::Zeroizing;

pub use channel::{HandshakeOptions, ListenerHooks, ProfileDecision, RemoteKeyPolicy, SecureChannel, Transmit};
pub use chunk::{
    chunk_bytes_for_route, send_window_for_route, transfer_liveness, ChunkReceiver, ChunkSender, FlowError,
};
pub use replay::ReplayCache;

/// Why a channel closed (`SZFriendsSessionError`). None of these are shown to people; the service maps them to
/// retries and logs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionError {
    /// Codec: bad length, duplicate tag, over a limit, unknown type.
    FrameInvalid,
    /// A well-formed frame out of place (before HELLO, wrong direction, a second Add by ID frame).
    Protocol,
    /// Did not authenticate: wrong key, bad certificate, tampering, no minor version in common.
    HandshakeFailed,
    /// The key policy refused the remote, a hidden listener got XX, or the admission rate is full.
    Rejected,
    /// A transport message failed authentication: tampered, replayed, reordered or truncated.
    DecryptFailed,
    /// The link ended without CLOSE.
    StreamClosed,
    /// The peer sent CLOSE with this reason (`CloseReason` values, unknown ones kept as numbers).
    PeerClosed(u8),
    /// Older than the maximum session age, or out of nonces: redial.
    Expired,
    /// The comparison-code commitment did not verify.
    CodeMismatch,
    /// The handshake did not go live within the handshake timeout.
    TimedOut,
    /// Message 1 repeated an initiator ephemeral key seen within the replay window.
    Replayed,
    /// While a transfer ran, nothing arrived for the silence limit: the route went quiet (out of range, a dead path).
    Silent,
}

impl SessionError {
    /// The helper's `SZFriendsSessionError` code, for logs and the exported transcripts.
    pub fn code(self) -> u8 {
        match self {
            Self::FrameInvalid => 1,
            Self::Protocol => 2,
            Self::HandshakeFailed => 3,
            Self::Rejected => 4,
            Self::DecryptFailed => 5,
            Self::StreamClosed => 6,
            Self::PeerClosed(_) => 7,
            Self::Expired => 8,
            Self::CodeMismatch => 9,
            Self::TimedOut => 10,
            Self::Replayed => 11,
            Self::Silent => 12,
        }
    }
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for SessionError {}

/// What a channel reports, in order, through [`SecureChannel::poll_event`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Initiator: the handshake completed. Responder: the initiator's HELLO arrived (IK message 1 can be replayed, so
    /// nothing acts on a handshake before HELLO).
    Established,
    /// An application frame. Channel frames (HELLO, CODE_*, REKEY, PING, CLOSE) never appear here.
    Frame(Frame),
    /// The comparison-code exchange finished: six ASCII digits, or why not.
    Code(Result<String, SessionError>),
    /// Once, last. `None` when this side closed deliberately (`close`, browse-only, a profile declined).
    Closed(Option<SessionError>),
}

/// Randomness for ephemeral keys, comparison-code nonces and the dummy work that equalises refusals. Production uses
/// the system's secure source ([`SystemRandom`]); the transcript replays inject the draws the helper made.
pub trait SessionRandom: Send {
    fn fill(&mut self, out: &mut [u8]);
}

/// The system's secure random source.
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemRandom;

impl SessionRandom for SystemRandom {
    fn fill(&mut self, out: &mut [u8]) {
        szfriends_crypto::random_bytes(out);
    }
}

/// The numbers a channel runs by. Production uses [`ChannelConfig::default`], ADR 0001's; tests shorten them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ChannelConfig {
    /// Per direction: send REKEY after this many plaintext bytes, or this long, since that direction's last rekey.
    pub rekey_after_bytes: u64,
    pub rekey_after: Duration,
    /// A session older than this closes (CLOSE Expired) and is redialed for a fresh Diffie-Hellman.
    pub max_age: Duration,
    /// A handshake not live this long after `start` closes.
    pub handshake_timeout: Duration,
    /// Every refusal before a responder's first reply closes exactly this long after the deciding bytes arrived.
    pub refusal_delay: Duration,
    /// The route's efficient write size; the bytes handed to the link stay under four times it (at least 4 KiB), so
    /// a message queued now can still overtake file chunks.
    pub preferred_write_size: usize,
    /// While [`SecureChannel::set_liveness`] asks for it: PING after this long without sending anything.
    pub keepalive: Duration,
    /// While [`SecureChannel::set_liveness`] watches: close after hearing nothing this long; on a session whose
    /// initiator declared Bluetooth, `silence_bluetooth`.
    pub silence: Duration,
    pub silence_bluetooth: Duration,
}

impl Default for ChannelConfig {
    fn default() -> Self {
        Self {
            rekey_after_bytes: consts::REKEY_AFTER_BYTES,
            rekey_after: Duration::from_secs(consts::REKEY_AFTER_SECONDS),
            max_age: Duration::from_secs(consts::SESSION_MAX_AGE_SECONDS),
            handshake_timeout: Duration::from_secs(consts::HANDSHAKE_TIMEOUT_SECONDS),
            refusal_delay: Duration::from_millis(consts::REFUSAL_DELAY_MILLISECONDS),
            preferred_write_size: 65_536,
            keepalive: Duration::from_millis(consts::KEEPALIVE_MILLISECONDS),
            silence: Duration::from_millis(consts::SILENCE_MILLISECONDS),
            silence_bluetooth: Duration::from_millis(consts::SILENCE_BLUETOOTH_MILLISECONDS),
        }
    }
}

/// The keys a channel needs from an identity: the X25519 static private key, its public half and the certificate
/// that binds it to the identity key. Debug never prints the private key.
#[derive(Clone)]
pub struct ChannelIdentity {
    pub(crate) static_private: Zeroizing<[u8; 32]>,
    pub(crate) static_public: [u8; 32],
    pub(crate) certificate: [u8; 96],
}

impl ChannelIdentity {
    pub fn new(identity: &Identity) -> Self {
        Self {
            static_private: identity.static_private_key(),
            static_public: identity.static_public_key(),
            certificate: identity.static_certificate(),
        }
    }
}

impl fmt::Debug for ChannelIdentity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ChannelIdentity").field("static_public", &self.static_public).finish_non_exhaustive()
    }
}

/// PROFILE fields served in XX message 2 while a listener's public entry is on.
pub type PublicProfile = Fields;

/// Time since an arbitrary origin that keeps counting while the device sleeps: `CLOCK_BOOTTIME` on Linux and
/// Android, `CLOCK_MONOTONIC` on Apple systems (which counts sleep there), the performance counter on Windows.
pub fn monotonic_now() -> Duration {
    clock::now()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod clock {
    pub fn now() -> std::time::Duration {
        let t = rustix::time::clock_gettime(rustix::time::ClockId::Boottime);
        std::time::Duration::new(t.tv_sec as u64, t.tv_nsec as u32)
    }
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "android"))))]
mod clock {
    pub fn now() -> std::time::Duration {
        let t = rustix::time::clock_gettime(rustix::time::ClockId::Monotonic);
        std::time::Duration::new(t.tv_sec as u64, t.tv_nsec as u32)
    }
}

#[cfg(not(unix))]
mod clock {
    use std::sync::OnceLock;
    use std::time::Instant;

    pub fn now() -> std::time::Duration {
        static ORIGIN: OnceLock<Instant> = OnceLock::new();
        ORIGIN.get_or_init(Instant::now).elapsed()
    }
}
