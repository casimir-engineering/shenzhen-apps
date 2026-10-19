//! One platform's Bluetooth as the Bluetooth adapter ([`super::bluetooth`]) drives it (`SZFriendsBluetoothRadio`):
//! BlueZ on Linux, the phone's own through the app, or a test home's test air. What a radio finds, reads and
//! accepts comes back as [`RadioEvent`]s on the service's thread.

use std::sync::Arc;

pub use szfriends_core::nearby::Permission;

use super::stream::LinkStream;
use super::{Event, Sink};

/// The radio's state (`SZFriendsRadioPower`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Power {
    /// Unknown or resetting: wait for the next update.
    Unknown,
    On,
    Off,
    Unauthorized,
    Unsupported,
}

/// What a radio reports, from any thread, for the adapter on the service's thread.
#[derive(Debug)]
pub enum RadioEvent {
    Power(Power),
    /// A scan result for the Friends service; `public` when the public UUID was advertised too.
    Discovered {
        peripheral: String,
        public: bool,
    },
    /// The presence characteristic's value (`None` when the read failed), and the public one's when asked for.
    Read {
        peripheral: String,
        value: Option<Vec<u8>>,
        public_value: Option<Vec<u8>>,
    },
    /// A channel published for an entry; psm 0: publishing failed.
    Published {
        psm: u16,
        public: bool,
    },
    /// Someone opened one of our channels; `peer` is what the per-address admission limit counts.
    Accepted {
        stream: LinkStream,
        public: bool,
        peer: Option<String>,
    },
}

/// Where a radio reports.
#[derive(Clone)]
pub struct RadioReports(Arc<Sink>);

impl std::fmt::Debug for RadioReports {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RadioReports")
    }
}

impl RadioReports {
    pub fn new(sink: Arc<Sink>) -> Self {
        Self(sink)
    }

    pub fn report(&self, event: RadioEvent) {
        (self.0)(Event::Radio(event));
    }

    /// The channel a dial asked for, or `None`.
    pub fn opened(&self, dial: u64, stream: Option<LinkStream>) {
        (self.0)(Event::Dialed { dial, stream });
    }
}

/// One platform's Bluetooth (`SZFriendsBluetoothRadio`). Every method returns at once; results come as reports.
pub trait Radio: Send {
    /// Reading it never prompts.
    fn permission(&self) -> Permission;
    /// The one call that may prompt.
    fn power_up(&mut self, reports: RadioReports);
    /// Stops everything: scanning, advertising, every channel.
    fn power_down(&mut self);
    fn start_scanning(&mut self);
    fn stop_scanning(&mut self);
    /// Advertises the Friends service (and the public UUID when `public` is given), serving both values to reads.
    fn advertise(&mut self, presence: &[u8], public: Option<&[u8]>);
    fn stop_advertising(&mut self);
    fn publish_channel(&mut self, public: bool);
    fn unpublish_channel(&mut self, psm: u16);
    /// Reads the presence characteristic, and the public one too when `public`, in one connection.
    fn read_presence(&mut self, peripheral: &str, public: bool);
    /// Opens a channel; the result comes as [`RadioReports::opened`] with this `dial`.
    fn open_channel(&mut self, peripheral: &str, psm: u16, dial: u64);
}
