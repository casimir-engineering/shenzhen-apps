//! What the LAN adapter needs of a DNS-SD implementation: register an entry under a name, browse for others, with
//! each instance resolved to its addresses, port and TXT. The backends are the platform's (`mdns-sd` on Linux,
//! Windows' DNS-SD API) and the test networks'.

use std::io;
use std::net::SocketAddr;

/// A browse result, already resolved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BrowseEvent {
    /// The browser runs.
    Ready,
    /// An instance with its addresses (the port included) and TXT; found again whenever any of it changes.
    Found {
        name: String,
        addresses: Vec<SocketAddr>,
        txt: Vec<(String, Vec<u8>)>,
    },
    /// An instance the platform connects to itself (iOS): no addresses; `peer_to_peer` when only peer-to-peer
    /// Wi-Fi reaches it.
    FoundByPlatform {
        name: String,
        txt: Vec<(String, Vec<u8>)>,
        peer_to_peer: bool,
    },
    Lost {
        name: String,
    },
    /// The person refused local network access (iOS): Nearby says so, and how to allow it.
    Denied,
    /// The backend cannot work (no network, an error); detail for the log only.
    Failed(String),
}

/// Where browse results go (from the backend's threads).
pub type BrowseSink = Box<dyn Fn(BrowseEvent) + Send + Sync>;

/// One DNS-SD implementation. Registering a name again replaces its entry (a TXT change keeps the name).
pub trait DnsSd: Send {
    fn browse(&mut self, sink: BrowseSink) -> io::Result<()>;
    fn register(&mut self, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()>;
    fn unregister(&mut self, name: &str);
    /// Ends browsing and every registration.
    fn stop(&mut self);
    /// Browses afresh (everything known is found again).
    fn refresh(&mut self) {}
    /// Whether the platform listens and connects itself (iOS's `NWListener` and `NWConnection`): entries are
    /// registered without a port, connections arrive from the platform, and dials go through [`DnsSd::dial`].
    fn owns_connections(&self) -> bool {
        false
    }
    /// Takes an entry off the air while its listener keeps accepting a little longer (platform listeners).
    fn withdraw(&mut self, name: &str) {
        self.unregister(name);
    }
    /// Connects to a found instance; the result arrives as the service's `Dialed` with this `dial`.
    fn dial(&mut self, name: &str, dial: u64) -> bool {
        let _ = (name, dial);
        false
    }
}
