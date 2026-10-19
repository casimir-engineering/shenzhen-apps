//! Nearby discovery on the desktops (ADR 0004, ADR 0015 § 9 and § 15): the adapters that find friends and let them
//! in. The decisions are `szfriends-core::nearby`'s and the service's (`service/nearby`); this is the I/O.
//!
//! One adapter per method, each reporting to the service's thread on its own ([`Event`]):
//!
//! - the LAN adapter ([`lan`]): a hidden TCP listener that moves to a fresh port every presence window, a public one
//!   during the person's 5 minutes, and a DNS-SD backend that registers both and browses for others:
//!   - Linux: `mdns-sd` ([`mdns`]), beside Avahi;
//!   - Windows: the system's DNS-SD API ([`windows_dnssd`]), so no socket of ours meets the firewall, and the
//!     listeners only when the firewall already admits them ([`firewall`]);
//!   - test homes: a directory of entries on loopback ([`registry`]), or on a Mac the system's Bonjour through
//!     `dns-sd -i lo0` ([`dns_sd_cli`]), which is how a Rust helper meets the Objective-C helper's test entries;
//! - the Bluetooth adapter ([`bluetooth`]) over a radio: BlueZ on Linux (`bluez`, the `bluetooth` feature), the
//!   phone's own (installed by the app, [`platform`]), or a test home's test air ([`test_air`]); none on Windows (no
//!   LE L2CAP channels for apps there).
//!
//! Nothing here starts before the service asks (`activate`, or launch once the person was asked), so no prompt or
//! firewall dialog ever appears before Friends is opened.

pub mod bluetooth;
#[cfg(all(target_os = "linux", feature = "bluetooth"))]
pub mod bluez;
#[cfg(target_os = "macos")]
pub mod dns_sd_cli;
pub mod dnssd;
pub mod firewall;
pub mod lan;
pub mod listeners;
#[cfg(target_os = "linux")]
pub mod mdns;
pub mod platform;
pub mod radio;
pub mod registry;
pub mod stream;
pub mod test_air;
#[cfg(windows)]
pub mod windows_dnssd;

use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};

use szfriends_core::nearby::{AdapterState, Method, Permission, Sighting, Tag};
use szfriends_core::wire::RouteMethod;

/// A test network instead of the person's: a directory of entries on loopback (`$SZFRIENDS_TEST_LOOPBACK`, in a test
/// home only).
pub const ENV_TEST_NETWORK: &str = "SZFRIENDS_TEST_LOOPBACK";
/// A test service type for the system's DNS-SD on loopback (`$SZFRIENDS_TEST_SERVICE_TYPE`, in a test home only).
pub const ENV_TEST_SERVICE_TYPE: &str = "SZFRIENDS_TEST_SERVICE_TYPE";
/// Whether a test home on the test network accepts connections (`$SZFRIENDS_TEST_INBOUND`): `blocked` never, as a
/// computer whose firewall admits nothing; `firewall` as this computer's firewall decides (Windows), still on loopback
/// only when it admits. Unset: on loopback. Read again before every hidden listener and every set-up.
pub const ENV_TEST_INBOUND: &str = "SZFRIENDS_TEST_INBOUND";

/// The binding a test home's test network listens with.
fn test_binding(state_dir: &Path) -> lan::Binding {
    match std::env::var(ENV_TEST_INBOUND).as_deref() {
        Ok("blocked") => lan::Binding::Nowhere,
        Ok("firewall") => match firewall::binding(state_dir) {
            lan::Binding::Nowhere => lan::Binding::Nowhere,
            _ => lan::Binding::Loopback,
        },
        _ => lan::Binding::Loopback,
    }
}

/// What adapters tell the service, each on its own.
#[derive(Debug)]
pub enum Event {
    State(Method, AdapterState),
    /// What a DNS-SD backend found or lost, for the LAN adapter to read on the service's thread.
    Browse(dnssd::BrowseEvent),
    /// What a Bluetooth radio reported, for the Bluetooth adapter.
    Radio(bluetooth::RadioEvent),
    Sighted(Sighting),
    Lost(Method, String),
    /// An incoming connection; nothing is trusted before its handshake completes.
    Accepted {
        stream: stream::LinkStream,
        route: RouteMethod,
        public: bool,
        listener: String,
        address: Option<String>,
    },
    /// The connection a dial asked for, or why not.
    Dialed {
        dial: u64,
        stream: Option<stream::LinkStream>,
    },
}

/// Where adapter events go: the service's input, wrapped.
pub type Sink = Box<dyn Fn(Event) + Send + Sync>;

/// One discovery method (`SZFriendsDiscoveryAdapter`). Methods run on the service's thread and return at once; work
/// that waits runs on the adapter's own threads and reports through the sink.
pub trait Adapter: Send {
    fn method(&self) -> Method;
    fn state(&self) -> AdapterState;
    /// What the platform says without prompting (ADR 0004 § Permissions at launch).
    fn permission(&self) -> Permission {
        Permission::Unknown
    }
    /// Starting is what may prompt or meet the firewall: only after `activate`, or at launch once asked.
    fn start(&mut self);
    fn stop(&mut self);
    /// What to advertise: our presence tag, exactly four callback slots, and whether the public entry is on. May be
    /// called before `start`. A new tag is a new window: the hidden entry moves to a fresh listener.
    fn advertise(&mut self, tag: Option<Tag>, slots: &[Tag], public: bool);
    /// Reads a browse result, returning what it means for the merger.
    fn browse_event(&mut self, event: dnssd::BrowseEvent) -> Vec<Event>;
    /// Reads a radio report, returning what it means for the merger and the service.
    fn radio_event(&mut self, event: bluetooth::RadioEvent) -> Vec<Event> {
        let _ = event;
        Vec::new()
    }
    /// Opens a stream to a sighted endpoint; the result arrives as [`Event::Dialed`] with this `dial`.
    fn dial(&mut self, endpoint: &str, dial: u64) -> bool;
    /// Looks again now.
    fn refresh(&mut self) {}
    /// Whether this computer accepts connections nearby (the Nearby page's line when it does not).
    fn listening(&self) -> bool {
        true
    }
    /// Periodic work: listeners past their overlap close, a failed method sets itself up again.
    fn tick(&mut self) {}
}

/// The adapters this helper runs, by environment: a test home gets test networks only, never the person's network.
pub fn adapters(state_dir: &Path, test_home: bool, sink: std::sync::Arc<Sink>) -> Vec<Box<dyn Adapter>> {
    let env = |key: &str| std::env::var_os(key);
    let mut adapters: Vec<Box<dyn Adapter>> = Vec::new();
    if test_home {
        if let Some(directory) = env(ENV_TEST_NETWORK).map(PathBuf::from).filter(|d| d.is_absolute() && d.is_dir()) {
            let backend = registry::Registry::new(directory);
            let state_dir = state_dir.to_path_buf();
            let lan = lan::LanAdapter::new(Box::new(backend), lan::Binding::Loopback, sink.clone());
            adapters.push(Box::new(lan.with_rebind(Box::new(move || test_binding(&state_dir)))));
        }
        #[cfg(target_os = "macos")]
        if let Ok(service_type) = std::env::var(ENV_TEST_SERVICE_TYPE) {
            if szfriends_core::nearby::is_test_service_type(&service_type) && adapters.is_empty() {
                let backend = dns_sd_cli::DnsSdCli::new(&service_type);
                adapters.push(Box::new(lan::LanAdapter::new(Box::new(backend), lan::Binding::Loopback, sink.clone())));
            }
        }
        #[cfg(target_os = "linux")]
        if let Ok(service_type) = std::env::var(ENV_TEST_SERVICE_TYPE) {
            if szfriends_core::nearby::is_test_service_type(&service_type) && adapters.is_empty() {
                let backend = mdns::Mdns::new(&service_type, mdns::Interfaces::Loopback);
                adapters.push(Box::new(lan::LanAdapter::new(Box::new(backend), lan::Binding::Loopback, sink.clone())));
            }
        }
        #[cfg(windows)]
        if let Ok(service_type) = std::env::var(ENV_TEST_SERVICE_TYPE) {
            if szfriends_core::nearby::is_test_service_type(&service_type) && adapters.is_empty() {
                let backend = windows_dnssd::WindowsDnsSd::new(&service_type);
                let lan = lan::LanAdapter::new(Box::new(backend), lan::Binding::Nowhere, sink.clone());
                adapters.push(Box::new(lan.with_rebind(firewall::rebind(state_dir))));
            }
        }
        if let Some(directory) = env(test_air::ENV_TEST_BLUETOOTH).map(PathBuf::from).filter(|d| d.is_absolute()) {
            let radio = Box::new(test_air::TestAir::new(directory));
            adapters.push(Box::new(bluetooth::BluetoothAdapter::new(radio, sink.clone())));
        }
        return adapters;
    }
    let _ = (state_dir, &sink);
    // Phones: the app's own DNS-SD (NsdManager, Apple's DNS-SD), installed by the app before the core starts.
    #[cfg(any(target_os = "android", target_os = "ios"))]
    if let Some(discovery) = platform::installed() {
        let binding = if discovery.owns_connections() { lan::Binding::Platform } else { lan::Binding::Network };
        let backend = platform::PlatformDnsSd::new(discovery, szfriends_core::nearby::SERVICE_TYPE, Some(sink.clone()));
        adapters.push(Box::new(lan::LanAdapter::new(Box::new(backend), binding, sink.clone())));
    }
    // Phones: the app's own Bluetooth (CoreBluetooth, Android's BLE and L2CAP).
    #[cfg(any(target_os = "android", target_os = "ios"))]
    if let Some(radio) = platform::radio() {
        adapters.push(Box::new(bluetooth::BluetoothAdapter::new(radio, sink.clone())));
    }
    #[cfg(target_os = "linux")]
    {
        let backend = mdns::Mdns::new(szfriends_core::nearby::SERVICE_TYPE, mdns::Interfaces::Network);
        adapters.push(Box::new(lan::LanAdapter::new(Box::new(backend), lan::Binding::Network, sink.clone())));
    }
    #[cfg(all(target_os = "linux", feature = "bluetooth"))]
    adapters.push(Box::new(bluetooth::BluetoothAdapter::new(Box::new(bluez::BlueZ::new()), sink.clone())));
    #[cfg(windows)]
    {
        let backend = windows_dnssd::WindowsDnsSd::new(szfriends_core::nearby::SERVICE_TYPE);
        let lan = lan::LanAdapter::new(Box::new(backend), lan::Binding::Nowhere, sink.clone());
        adapters.push(Box::new(lan.with_rebind(firewall::rebind(state_dir))));
    }
    adapters
}

/// Connects to the first address that answers, within `timeout` each.
pub fn connect_any(addresses: &[SocketAddr], timeout: std::time::Duration) -> Option<TcpStream> {
    addresses.iter().find_map(|address| TcpStream::connect_timeout(address, timeout).ok())
}
