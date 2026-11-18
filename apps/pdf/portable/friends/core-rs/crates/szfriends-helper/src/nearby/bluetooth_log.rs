//! The Bluetooth adapter's lines in the log (`service/nearby/trace.rs` says what the log is for): which channel (PSM)
//! each device listens on as read, when that changes, which one a dial opens and how old that read is. A device is
//! named by a short handle of its identifier for this run, never by its address.

use std::hash::{Hash, Hasher};

use crate::log;

/// Four hex digits standing for one device identifier in this run of the helper.
pub(super) fn handle(peripheral: &str) -> String {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    peripheral.hash(&mut hasher);
    format!("{:04x}", hasher.finish() & 0xffff)
}

/// A presence read: the first channel known for the device, or a new one (its helper started again, or a new window).
pub(super) fn read(peripheral: &str, before: Option<u16>, now: u16) {
    match before {
        None => log!("bluetooth: device {} listens on channel {now}", handle(peripheral)),
        Some(before) if before != now => {
            log!("bluetooth: device {} now listens on channel {now} (was {before})", handle(peripheral));
        }
        Some(_) => {}
    }
}

/// A dial opens `psm` on the device, from a read `age` seconds old.
pub(super) fn opening(peripheral: &str, psm: u16, age: Option<f64>) {
    let age = age.map_or("not read".to_owned(), |a| format!("read {a:.0} s ago"));
    log!("bluetooth: opening channel {psm} on device {} ({age})", handle(peripheral));
}

/// A channel that would not open: the device is read again on its next sighting.
pub(super) fn reread(peripheral: &str) {
    log!("bluetooth: channel on device {} would not open: reading it again when next seen", handle(peripheral));
}

/// One of our own channels was published (0: publishing failed).
pub(super) fn published(psm: u16, public: bool) {
    log!("bluetooth: our {} channel is {psm}", if public { "public" } else { "hidden" });
}
