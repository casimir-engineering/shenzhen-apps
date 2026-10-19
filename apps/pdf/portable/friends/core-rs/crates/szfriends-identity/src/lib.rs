//! Shenzhen Friends identity, interoperable with the Objective-C helper's identity area (`SZFriendsIdentity.h`).
//!
//! The one rule that matters most: an identity secret that exists but cannot be read is unavailable, never a reason
//! to make a new key. Every friend would see a silent regeneration as a key change. Only an explicit reset creates a
//! new identity over an old one ([`keystore::IdentityManager`]).

pub mod chain;
pub mod friends_id;
pub mod identity;
pub mod join;
pub mod keystore;
pub mod request_by_id;

pub use identity::{Identity, IdentityError};
