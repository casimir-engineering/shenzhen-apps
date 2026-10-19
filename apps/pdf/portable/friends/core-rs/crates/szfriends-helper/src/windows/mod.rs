//! Windows: the lock, the named pipe and its trust checks of ADR 0015 § 8, and the DPAPI key store. The Win32 calls
//! are `szfriends-helper-sys`'s; the decisions are `szfriends-contract::pipe`'s.

pub mod ipc;
pub mod keystore;
