//! The system calls the desktop helper needs that safe Rust cannot make (ADR 0015 § 7, § 8, § 16), behind a narrow
//! safe interface, so `szfriends-helper` itself keeps the workspace's `forbid(unsafe_code)`:
//!
//! - [`lock`]: one byte of `helper.lock` locked with `LockFileEx`, so the holder's process id stays readable.
//! - [`pipe`]: the helper's named pipe (a DACL and owner for the user alone, the first instance claimed, remote
//!   clients rejected), the client's open with identification-only impersonation, overlapped reads and writes that
//!   one thread can cancel while another waits, and what Windows reports about the other end.
//! - [`token`]: a process's token user, integrity level and AppContainer flag, and its executable's path.
//! - [`dpapi`]: `CryptProtectData` for the current user, the identity key's protection.
//! - [`events`]: sleep and wake (`PowerRegisterSuspendResumeNotification`, the same `PBT_*` events a window gets as
//!   `WM_POWERBROADCAST`, without a window) and network changes (`NotifyIpInterfaceChange`,
//!   `NotifyUnicastIpAddressChange`).
//! - [`dnssd`]: the system's DNS-SD (`DnsServiceBrowse`, `DnsServiceResolve`, `DnsServiceRegister`) for nearby
//!   discovery, served by the DNS client with its own mDNS rules (ADR 0015 § 15).
//! - [`firewall`]: what Defender Firewall would do with a listener, read through `INetFwPolicy2` (§ 15).
//!
//! The decisions over these facts are pure functions in `szfriends-contract::pipe`. Everywhere, [`local_time`]: the
//! computer's own time zone for the words about time. Otherwise Linux needs no `unsafe` (rustix covers it).

pub mod local_time;
#[cfg(windows)]
mod windows;

#[cfg(windows)]
pub use windows::{dnssd, dpapi, events, firewall, lock, pipe, token};

#[cfg(all(windows, feature = "testing"))]
pub use windows::testing;
