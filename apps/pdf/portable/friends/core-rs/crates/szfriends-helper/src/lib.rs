//! The Shenzhen Friends helper for Windows and Linux desktops (ADR 0015 § 3, § 8, § 14, § 16): one process per
//! person, shared by every app that hosts Friends, speaking PROTOCOL.md over a Unix socket or a named pipe, with the
//! Objective-C helper's lifecycle (single instance by lock, connect-or-spawn from a versioned per-user copy, exit
//! after the last client, handover to a newer build). The library is also the client an app's bridge uses.
//!
//! | Module | What |
//! |---|---|
//! | [`server`], [`lifecycle`] | the protocol server and the exit rules, transport-independent |
//! | [`presentation`] | what the server asks of the Friends service; the stub served when it cannot start |
//! | [`client`], [`copy`] | connect (checks first), connect-or-spawn, `--handover`; the per-user copy and spawn |
//! | [`stamp`] | the version and build every helper binary carries |
//! | [`events`] | sleep, wake and network changes |
//! | [`nearby`] | discovery's adapters: listeners, DNS-SD backends, the firewall's word (ADR 0015 § 9, § 15) |
//! | `linux`, `windows` | the platform's lock, socket or pipe, and key store |

pub mod client;
pub mod copy;
pub mod events;
pub mod lifecycle;
#[cfg(target_os = "linux")]
pub mod linux;
pub mod log;
pub mod nearby;
pub mod presentation;
#[cfg(any(target_os = "linux", windows))]
pub mod run;
pub mod server;
pub mod service;
pub mod stamp;
pub mod state;
pub mod transport;
#[cfg(windows)]
pub mod windows;

/// The key store the identity lives in on this desktop (ADR 0015 § 7): DPAPI files on Windows; on Linux the Secret
/// Service, or 0600 files where none runs, as recorded in the state directory. A test home
/// (`$SZFRIENDS_STATE_DIR`) on Linux keeps its key in a 0600 file of its own, never in the person's keyring.
#[cfg(any(target_os = "linux", windows))]
pub fn key_store(state: &state::StateDir) -> Box<dyn szfriends_identity::keystore::KeyStore> {
    #[cfg(target_os = "linux")]
    if std::env::var_os(state::ENV_STATE_DIR).is_some() {
        return Box::new(szfriends_identity::keystore::FileKeyStore::new(state.path.join("keys")));
    }
    #[cfg(target_os = "linux")]
    let store = {
        let scope = format!("{:016x}", szfriends_contract::socket::fnv1a64(state.canonical.as_bytes()));
        linux::keystore::LinuxKeyStore::new(state.path.clone(), scope)
    };
    #[cfg(windows)]
    let store = windows::keystore::DpapiKeyStore::new(state.path.join("keys"));
    Box::new(store)
}
