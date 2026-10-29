//! The Objective-C helper's WebRTC data-channel stack for the portable core (ADR 0015 § 9): libdatachannel 0.24.6 with
//! libjuice, usrsctp and Mbed TLS 3.6.7 from the pinned sources under `ext/`, compiled by `build.rs` with `cc`, and a
//! small safe interface over its C API: a peer connection, its local and remote descriptions, trickled ICE candidates,
//! and reliable, ordered data channels that open, send and receive.
//!
//! Everything the stack reports arrives as an [`Event`] on the receiver [`PeerConnection::new`] returns, sent from
//! libdatachannel's threads. A [`DataChannel`] keeps its connection's handle, and no handle is ever released on one
//! of the stack's threads (`connection.rs` says how). Every handle is counted until it is deleted, and the stack ends
//! after the last of them, before the process's globals do (`lifetime.rs`). This is the one crate of the workspace
//! with `unsafe` (the FFI); every block says why it holds.

mod connection;
mod ffi;
mod layout;
mod lifetime;
pub mod tls;

use std::ffi::{c_char, c_int, CStr, CString};
use std::fmt;

pub use connection::{DataChannel, PeerConnection};
pub use lifetime::{live_handles, release_in_background, shutdown, wait_released};

/// The libdatachannel release the sources under `ext/libdatachannel` are (its `VENDORED.md`).
pub const LIBDATACHANNEL_VERSION: &str = "0.24.6";

/// The largest message the helper sends or accepts on its data channel (`SZFriendsOnlineMessageMax`, ADR 0009).
pub const MESSAGE_MAX: usize = 65536;

/// What a call into the stack can fail with: libdatachannel's error codes, or a string with an interior NUL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Failure,
    NotAvailable,
    TooSmall,
    InteriorNul,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Error::Invalid => "invalid argument",
            Error::Failure => "runtime error",
            Error::NotAvailable => "not available",
            Error::TooSmall => "buffer too small",
            Error::InteriorNul => "string contains a NUL byte",
        })
    }
}

impl std::error::Error for Error {}

fn check(code: c_int) -> Result<c_int, Error> {
    match code {
        code if code >= 0 => Ok(code),
        ffi::RTC_ERR_INVALID => Err(Error::Invalid),
        ffi::RTC_ERR_NOT_AVAIL => Err(Error::NotAvailable),
        ffi::RTC_ERR_TOO_SMALL => Err(Error::TooSmall),
        _ => Err(Error::Failure),
    }
}

fn c_string(value: &str) -> Result<CString, Error> {
    CString::new(value).map_err(|_| Error::InteriorNul)
}

/// The peer connection's state (libdatachannel's `rtcState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    New,
    Connecting,
    Connected,
    Disconnected,
    Failed,
    Closed,
}

impl State {
    fn from_raw(raw: ffi::rtcState) -> State {
        match raw {
            0 => State::New,
            1 => State::Connecting,
            2 => State::Connected,
            3 => State::Disconnected,
            4 => State::Failed,
            _ => State::Closed,
        }
    }
}

/// What the stack reports, in the order it reports it for one peer connection.
#[derive(Debug)]
pub enum Event {
    /// The offer (after the first data channel is created) or the answer (after the remote offer is applied), for
    /// the signalling layer to send. `kind` is "offer" or "answer". Candidates trickle; the SDP carries none.
    LocalDescription {
        sdp: String,
        kind: String,
    },
    /// One gathered candidate, without "a=" ("candidate:1 1 UDP ..."), and the media section it belongs to.
    LocalCandidate {
        candidate: String,
        mid: String,
    },
    GatheringComplete,
    StateChanged(State),
    /// The remote side opened a data channel; it is open when this arrives.
    DataChannel(DataChannel),
    /// A channel this side created opened.
    ChannelOpen(i32),
    /// One message. `text` marks a string message (the helper treats it as a protocol error).
    Message {
        channel: i32,
        data: Vec<u8>,
        text: bool,
    },
    ChannelClosed(i32),
    ChannelError {
        channel: i32,
        error: String,
    },
}

/// How a peer connection binds and what it may send. The defaults are the helper's: any address, ports chosen by
/// the system, no STUN or TURN server, 64 KiB messages.
#[derive(Debug, Clone)]
pub struct Config {
    /// Binds the ICE agent to one local address (libjuice); tests use "127.0.0.1".
    pub bind_address: Option<String>,
    /// A fixed local UDP port range; `None` lets the system choose.
    pub port_range: Option<(u16, u16)>,
    /// "stun:host:port" or "turn:user:password@host:port" URLs.
    pub ice_servers: Vec<String>,
    /// Gathers and sends relay candidates only (a relay connection, ADR 0009).
    pub relay_only: bool,
    pub max_message_size: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            bind_address: None,
            port_range: None,
            ice_servers: Vec::new(),
            relay_only: false,
            max_message_size: MESSAGE_MAX,
        }
    }
}

/// Copies a NUL-terminated string from the stack. Null reads as empty.
fn copy_str(text: *const c_char) -> String {
    if text.is_null() {
        return String::new();
    }
    // SAFETY: libdatachannel passes NUL-terminated strings that live for the duration of the callback.
    unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned()
}

// --- Process-wide -------------------------------------------------------------------------------------------------

extern "C" fn on_log(level: ffi::rtcLogLevel, message: *const c_char) {
    let tag = if level <= ffi::RTC_LOG_ERROR { "error" } else { "warning" };
    eprintln!("libdatachannel {tag}: {}", copy_str(message));
}

/// Sends the stack's errors (and warnings when `warnings`) to stderr. Call once, before any peer connection.
pub fn log_to_stderr(warnings: bool) {
    let level = if warnings { ffi::RTC_LOG_WARNING } else { ffi::RTC_LOG_ERROR };
    // SAFETY: `on_log` is a valid callback for the life of the process.
    unsafe { ffi::rtcInitLogger(level, Some(on_log)) };
}

/// One worker thread for every peer connection (ADR 0009 § Configuration; the stack's default is one per core). It
/// applies when the pool's threads are spawned, so call it once, before the first peer connection.
pub fn set_thread_pool_size(count: u32) {
    // SAFETY: a plain setting, read when the stack starts its threads.
    unsafe { ffi::rtcSetThreadPoolSize(count) };
}

/// usrsctp's buffers and congestion control for peer connections created from now on (ADR 0018 § 9.9). `None` keeps
/// the stack's default for that setting (1 MiB buffers, RFC 4960's congestion control).
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SctpSettings {
    pub receive_buffer: Option<u32>,
    pub send_buffer: Option<u32>,
    /// 0 RFC 2581/4960, 1 HighSpeed TCP, 2 H-TCP, 3 RTCC.
    pub congestion_control: Option<u8>,
}

pub fn set_sctp_settings(settings: SctpSettings) {
    let size = |v: Option<u32>| v.map_or(0, |v| c_int::try_from(v).unwrap_or(c_int::MAX));
    let raw = ffi::rtcSctpSettings {
        recvBufferSize: size(settings.receive_buffer),
        sendBufferSize: size(settings.send_buffer),
        congestionControlModule: settings.congestion_control.map_or(0, c_int::from),
        ..ffi::rtcSctpSettings::default()
    };
    // SAFETY: `raw` outlives the call, which copies the settings.
    unsafe { ffi::rtcSetSctpSettings(&raw) };
}

/// The Mbed TLS version compiled into the archive ("3.6.7").
pub fn mbedtls_version() -> String {
    let mut buffer = [0 as c_char; 18];
    // SAFETY: Mbed TLS writes at most 18 bytes including the NUL (its header says so).
    unsafe { ffi::mbedtls_version_get_string(buffer.as_mut_ptr()) };
    copy_str(buffer.as_ptr())
}

/// The SHA-256 certificate fingerprint an SDP carries (a=fingerprint:sha-256 AA:BB:...), which the signalling layer
/// sends beside the description (`SZFriendsOnlineFingerprintLength`, 32 bytes).
pub fn sdp_fingerprint(sdp: &str) -> Option<[u8; 32]> {
    let line = sdp.lines().find_map(|line| line.trim_end().strip_prefix("a=fingerprint:sha-256 "))?;
    let mut fingerprint = [0u8; 32];
    let mut parts = line.split(':');
    for byte in fingerprint.iter_mut() {
        *byte = u8::from_str_radix(parts.next()?, 16).ok()?;
    }
    parts.next().is_none().then_some(fingerprint)
}

/// The data-channel section's mid (a=mid:...), to attach remote candidates to.
pub fn sdp_mid(sdp: &str) -> Option<String> {
    sdp.lines().find_map(|line| line.trim_end().strip_prefix("a=mid:").map(str::to_owned))
}

#[doc(hidden)]
pub use layout::check_layouts;
