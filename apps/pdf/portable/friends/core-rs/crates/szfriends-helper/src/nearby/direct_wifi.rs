//! The direct Wi-Fi link of ADR 0019's boost, as the platform makes it: host a Wi-Fi Direct group, join one by name
//! and passphrase, get back on the Wi-Fi network the device was on, and say whether it is online. The decisions are
//! `szfriends_core::transfer::boost`'s and the service's (`service/boost.rs`); this is the I/O.
//!
//! - Phones: the app installs its own ([`install`]): Android's `WifiP2pManager` and `ConnectivityManager`, iOS's
//!   `NEHotspotConfiguration` (joins only), through the plugin's Kotlin and Swift.
//! - Test homes: [`TestDirectWifi`], a pretend radio that "hosts" on loopback, records what it was asked in
//!   `direct-wifi-test.log` and never touches a real network.
//! - Windows, Linux: none. Windows has no Bluetooth route, so the boost's trigger never fires there; Linux could host
//!   through NetworkManager later.
//!
//! Every call returns at once; answers arrive through the `Done` given, on any thread.

use std::io::Write;
use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use szfriends_core::presentation::facts::BoostDevice;
use szfriends_core::transfer::boost::{Abilities, Connectivity, Link};

/// An answer, delivered once.
pub type Done<T> = Box<dyn FnOnce(T) + Send>;

/// What the platform does for the boost.
pub trait DirectWifi: Send + Sync {
    /// What this device can do (BOOST's Abilities).
    fn abilities(&self) -> Abilities;
    /// How it is online right now.
    fn connectivity(&self) -> Connectivity;
    /// The platform's reference to the Wi-Fi network it is on (a name, Android's network id), to come back to;
    /// `None` when on none.
    fn current_network(&self) -> Option<String>;
    /// Which device says "Your … rejoins it", and whether the system asks the person again after Go faster (iOS).
    fn device(&self) -> BoostDevice {
        BoostDevice::Phone
    }
    fn system_asks_too(&self) -> bool {
        false
    }
    /// Host `link`: answers with this device's address on it, or why not.
    fn host(&self, link: &Link, done: Done<Result<IpAddr, String>>);
    fn stop_hosting(&self);
    /// Join `link` (the current network was written down first): whether it is on the link now.
    fn join(&self, link: &Link, done: Done<bool>);
    /// Leave `joined` if still on it, and get back on `network` (`None`: only leave): whether it did.
    fn rejoin(&self, network: Option<&str>, joined: &str, done: Done<bool>);
    /// Whether the device is online (the platform's own path monitor: no traffic of ours).
    fn online(&self, done: Done<bool>);
    /// Where the host's lane listener binds, given its address on the link (test homes: loopback).
    fn listen_address(&self, link_address: IpAddr) -> IpAddr {
        link_address
    }
    /// Where the joining side dials, given the host's address on the link (test homes: loopback).
    fn dial_address(&self, address: IpAddr) -> IpAddr {
        address
    }
}

static INSTALLED: OnceLock<Arc<dyn DirectWifi>> = OnceLock::new();

/// A phone's app installs its platform's link before the core starts.
pub fn install(platform: Arc<dyn DirectWifi>) {
    let _ = INSTALLED.set(platform);
}

pub fn installed() -> Option<Arc<dyn DirectWifi>> {
    INSTALLED.get().cloned()
}

/// A test home's pretend radio: `$SZFRIENDS_TEST_DIRECT_WIFI` lists what it can do (`host`, `join`, `keeps`: both keep
/// the Wi-Fi), `$SZFRIENDS_TEST_WIFI` names the Wi-Fi network it is on (none when unset), and
/// `$SZFRIENDS_TEST_ONLINE_ALSO` says `mobile` or `ethernet`. `$SZFRIENDS_TEST_REJOIN=fail` makes getting back fail.
pub const ENV_TEST_DIRECT_WIFI: &str = "SZFRIENDS_TEST_DIRECT_WIFI";
pub const ENV_TEST_WIFI: &str = "SZFRIENDS_TEST_WIFI";
pub const ENV_TEST_ONLINE_ALSO: &str = "SZFRIENDS_TEST_ONLINE_ALSO";
pub const ENV_TEST_REJOIN: &str = "SZFRIENDS_TEST_REJOIN";
/// What the pretend radio did, one line each: `host DIRECT-…`, `stop`, `join DIRECT-…`, `rejoin HomeWiFi`.
pub const TEST_LOG: &str = "direct-wifi-test.log";

#[derive(Debug)]
pub struct TestDirectWifi {
    abilities: Abilities,
    wifi: Mutex<Option<String>>,
    also: Option<String>,
    rejoin_fails: bool,
    log: PathBuf,
}

impl TestDirectWifi {
    /// The pretend radio a test home asks for, if any.
    pub fn from_environment(state_dir: &std::path::Path) -> Option<Self> {
        let spec = std::env::var(ENV_TEST_DIRECT_WIFI).ok()?;
        let has = |word: &str| spec.split(',').any(|w| w.trim() == word);
        let keeps = has("keeps");
        let abilities =
            Abilities { host: has("host"), join: has("join"), host_keeps_wifi: keeps, join_keeps_wifi: keeps };
        let home = std::env::var(ENV_TEST_WIFI).ok().filter(|n| !n.is_empty());
        Some(Self {
            abilities,
            wifi: Mutex::new(home),
            also: std::env::var(ENV_TEST_ONLINE_ALSO).ok(),
            rejoin_fails: std::env::var(ENV_TEST_REJOIN).is_ok_and(|v| v == "fail"),
            log: state_dir.join(TEST_LOG),
        })
    }

    fn note(&self, line: &str) {
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&self.log) {
            let _ = writeln!(file, "{line}");
        }
    }

    fn wifi(&self) -> Option<String> {
        self.wifi.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

impl DirectWifi for TestDirectWifi {
    fn abilities(&self) -> Abilities {
        self.abilities
    }

    fn connectivity(&self) -> Connectivity {
        let wifi = self.wifi();
        Connectivity {
            on_wifi: wifi.is_some(),
            wifi_name: wifi,
            wired: self.also.as_deref() == Some("ethernet"),
            mobile: self.also.as_deref() == Some("mobile"),
        }
    }

    fn current_network(&self) -> Option<String> {
        self.wifi()
    }

    fn device(&self) -> BoostDevice {
        BoostDevice::Computer
    }

    fn host(&self, link: &Link, done: Done<Result<IpAddr, String>>) {
        self.note(&format!("host {}", link.network));
        done(Ok(IpAddr::V4(Ipv4Addr::new(192, 168, 49, 1))));
    }

    fn stop_hosting(&self) {
        self.note("stop");
    }

    fn join(&self, link: &Link, done: Done<bool>) {
        self.note(&format!("join {}", link.network));
        *self.wifi.lock().unwrap_or_else(|e| e.into_inner()) = Some(link.network.clone());
        done(true);
    }

    fn rejoin(&self, network: Option<&str>, joined: &str, done: Done<bool>) {
        self.note(&format!("rejoin {} from {joined}", network.unwrap_or("-")));
        if self.rejoin_fails {
            return done(false);
        }
        let mut wifi = self.wifi.lock().unwrap_or_else(|e| e.into_inner());
        if wifi.as_deref() == Some(joined) || network.is_some() {
            *wifi = network.map(str::to_owned);
        }
        drop(wifi);
        done(true);
    }

    fn online(&self, done: Done<bool>) {
        // Online on any network but a link (the phone hosts with no Internet sharing), or another way.
        done(self.wifi().is_some_and(|w| !w.starts_with("DIRECT-")) || self.also.is_some());
    }

    fn listen_address(&self, _link_address: IpAddr) -> IpAddr {
        IpAddr::V4(Ipv4Addr::LOCALHOST)
    }

    fn dial_address(&self, _address: IpAddr) -> IpAddr {
        IpAddr::V4(Ipv4Addr::LOCALHOST)
    }
}

/// The platform this helper uses: a phone's installed one, or a test home's pretend radio; none elsewhere.
pub fn for_helper(state_dir: &std::path::Path, test_home: bool) -> Option<Arc<dyn DirectWifi>> {
    if test_home {
        return TestDirectWifi::from_environment(state_dir).map(|t| Arc::new(t) as Arc<dyn DirectWifi>);
    }
    installed()
}
