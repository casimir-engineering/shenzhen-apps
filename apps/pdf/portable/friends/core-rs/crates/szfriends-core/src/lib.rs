//! The Friends service in Rust: what the Objective-C helper (`portable/friends/service`) does, for hosts on Windows,
//! Linux, Android and iOS. ADR 0015 is the decision and `portable/docs/plans/friends-portable-core.md` the plan; the
//! areas arrive in its waves, each mirroring the helper area of the same name and tested against the same vectors and
//! fixtures:
//!
//! | Wave | Module         | Mirrors (`service/`)       |
//! |------|----------------|----------------------------|
//! | 2    | `session`      | `session/` secure channel, chunk flow, replay cache |
//! | 2    | `store`        | `store/` (schema v1 to v9, migrations, outbox, transfers, ADR 0003) |
//! | 3    | `presentation` | `presentation/` (snapshots and the string catalog, PROTOCOL.md) |
//! | 3    | `ipc`          | `helper/` (the client protocol over a socket, a named pipe or in-process) |
//! | 4    | `nearby`       | `discovery/` (LAN discovery; Bluetooth through the platform layer) |
//! | 5    | `online`       | `online/`, `host/` (WebRTC data channels, rendezvous, relay, ADR 0009 to 0011) |
//! | 6    | `devices`      | `identity/` chain and join, `sync/` (ADR 0012 to 0014) |
//!
//! Wave 1 gave it where state lives on each platform (`paths`); wave 2 the session area and the store; wave 3 the
//! presentation (snapshots, the string catalog, mentions) and the intents' field rules and replies (`intents`).

pub mod intents;
pub mod nearby;
pub mod paths;
pub mod presentation;
pub mod session;
pub mod store;
pub mod sync;

pub use szfriends_contract as contract;
pub use szfriends_crypto as crypto;
pub use szfriends_identity as identity;
pub use szfriends_wire as wire;
