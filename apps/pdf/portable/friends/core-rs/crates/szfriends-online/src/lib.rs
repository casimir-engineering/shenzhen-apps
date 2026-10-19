//! Shenzhen Friends online, for the portable core (ADR 0015 § 9, wave 5): what the Objective-C helper's
//! `service/online/`, `service/host/` and the online half of `service/session/` do, again, on every platform.
//!
//! - [`signal`]: signalling items, the Noise signalling sessions (IK for friends, NN for Add by ID) and the sealed
//!   rendezvous records (ADR 0010);
//! - [`host`]: the host protocol 3 client over `wss://` (or `ws://` on loopback): check-in, the signed host list,
//!   rendezvous records and lookups, connection setup (`sig_*`) and relay credentials (HOST-PROTOCOL.md,
//!   HOST-PROTOCOL-ONLINE.md);
//! - [`nat`]: STUN, the two-port NAT classifier, port prediction, hard-NAT probing and router port mapping (ADR 0011);
//! - [`order`]: when an attempt opens which connection, the direct phase's timers, the relay and leaving it;
//! - [`transport`]: the data-channel stack (`szfriends-datachannel-sys`) under the helper's candidate, description
//!   and fingerprint rules (ADR 0009 § Who may reach the stack);
//! - [`driver`]: attempts toward friends, joining all of the above;
//! - [`links`]: download links served to a browser (PROTOCOL.md § Links, Browser downloads);
//! - [`byid`]: Add by ID over the host (NN to a Friends ID's holder);
//! - [`join`]: joining a profile over the host (`to.join`), as pipes the helper drives like nearby sessions.
//!
//! Nothing here logs an address, a candidate, a key or a payload (ADR 0011 § Technique log).

pub mod b64;
pub mod byid;
pub mod driver;
pub mod host;
pub mod join;
pub mod links;
pub mod nat;
pub mod online;
pub mod order;
pub mod signal;
pub mod transport;

pub use online::{Online, OnlineConfig, OnlineEvent};
