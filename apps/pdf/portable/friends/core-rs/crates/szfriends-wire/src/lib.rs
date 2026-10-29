//! The Shenzhen Friends session wire format, byte for byte as the Objective-C helper speaks it (ADR 0001).
//!
//! Layering, bottom up, identical on every route (TCP, L2CAP, a WebRTC data channel):
//!
//! 1. An ordered byte stream.
//! 2. The initiator's 4-byte preamble `'S' 'Z' major pattern` ([`stream::Preamble`]), then Noise messages, each
//!    preceded by a 16-bit big-endian length and at most 65,535 bytes ([`stream::MessageReader`]). The Noise prologue
//!    is `"SZFriends session\0" || preamble` ([`stream::prologue`]).
//! 3. One application frame per Noise transport message: `type:u8`, then fields `tag:u8 len:u16be value`
//!    ([`frame`]). Handshake payloads use the same fields without a type byte ([`payload`]).
//!
//! Pure and allocation-bounded: nothing here does I/O or cryptography, and every length is checked before anything
//! sized by the peer is allocated. The numbers are wire values shared with
//! `portable/friends/service/session/SZFriendsSession.h` and are never renumbered.

pub mod consts;
pub mod error;
pub mod fields;
pub mod frame;
pub mod payload;
pub mod ranges;
pub mod route;
pub mod rules;
pub mod stream;
pub mod types;

pub use error::WireError;
pub use fields::Fields;
pub use frame::Frame;
pub use payload::HandshakePayload;
pub use route::RouteMethod;
pub use types::{tag, CloseReason, FrameType, Pattern};
