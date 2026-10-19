//! The client protocol between Friends and the views (PROTOCOL.md): what every host speaks, whether the core runs
//! in another process (a desktop helper) or in-process (a mobile app), so one React UI renders the same snapshots and
//! sends the same intents everywhere.
//!
//! This crate holds the transport-independent part: framing, ids, the handshake's frames, the lifecycle's
//! decisions, the socket path rule and the Windows pipe rules.
//! Snapshot and intent schemas are checked against PROTOCOL.md's fixtures in the tests; their builders come with the
//! presentation wave.

pub mod framing;
pub mod handshake;
pub mod ids;
pub mod lifecycle;
pub mod pipe;
pub mod socket;
