//! Windows: the lock, the named pipe and its trust checks of ADR 0015 § 8, and the DPAPI key store. The Win32 calls
//! are `szfriends-helper-sys`'s; the decisions are `szfriends-contract::pipe`'s.

pub mod ipc;
pub mod keystore;

/// Friends' firewall rule, which only an administrator's yes can add (ADR 0015 § 15).
pub mod firewall {
    pub use szfriends_helper_sys::firewall::netsh_elevated;
}
