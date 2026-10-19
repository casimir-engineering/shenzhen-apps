//! Linux: the socket and lock of PROTOCOL.md § Transport, the Secret Service key store over a small D-Bus client,
//! sleep, wake and network changes from logind and rtnetlink, and the file manager's Show Items for the app hosts.

pub mod dbus;
pub mod file_manager;
pub mod ipc;
pub mod keystore;
pub mod logind;
pub mod marshal;
pub mod netlink;
pub mod secret_service;
