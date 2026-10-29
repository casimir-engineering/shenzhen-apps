//! Fast transfers (ADR 0018, PROTOCOL.md § Fast transfers), sans-IO: a file cut into blocks of 2^shift bytes, a BLAKE3
//! tree over them whose root the OFFER carries, the receiver's assembly that checks every block against its leaf the
//! moment it is complete, the sender's side that serves the blocks a WANT names and checks each against its own leaf
//! as it reads it, and the two sidecar files that let both resume from exactly what arrived. The store does the file
//! I/O (`store/blocks.rs`); the helper moves the frames.
//!
//! Used only on a session whose negotiated minor is 4 or more and where both sides set
//! [`szfriends_wire::consts::CAPABILITY_FAST_TRANSFERS`]; everything else stays ADR 0001's CHUNK flow.

pub mod assembly;
pub mod blockset;
pub mod copies;
pub mod frames;
pub mod geometry;
pub mod serve;
pub mod sidecar;
pub mod tree;

pub use assembly::{AssemblyError, BlockAssembly, PartOutcome};
pub use blockset::BlockSet;
pub use geometry::Geometry;
pub use serve::{BlockServe, ServeError};
pub use tree::{FileHash, Leaf};
