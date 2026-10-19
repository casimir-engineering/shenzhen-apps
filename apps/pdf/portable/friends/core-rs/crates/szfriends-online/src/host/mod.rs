//! The host protocol 3 client (HOST-PROTOCOL.md, HOST-PROTOCOL-ONLINE.md; the helper's `service/host/`): the signed
//! host list, check-in and Friends ID reservation, and the online side: rendezvous records and lookups, connection
//! setup and relay credentials, download links' registrations.

pub mod attestation;
pub mod client;
pub mod codec;
pub mod list;
pub mod online;
pub mod outcome;
pub mod release;
pub mod reservation;
pub mod websocket;

pub use client::{HostClient, HostInput, HostOutcome, HostSink, Via};
pub use list::HostList;
