//! Online signalling (`SZFriendsSignaling.h`): what two helpers say to each other through the host's connection
//! setup (`sig_open`, `sig_msg`), and the sealed blob of a rendezvous record. The host forwards every payload unread.

pub mod items;
pub mod noise;
pub mod record;

pub use items::{Item, ItemType};
pub use noise::{ReplayCache, SignalError, SignalingSession};
