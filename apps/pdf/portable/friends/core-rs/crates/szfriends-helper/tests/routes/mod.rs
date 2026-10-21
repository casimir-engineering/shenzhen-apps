//! The owner's route order where nearby and online meet, as one set of scenarios for every kind of session: a friend's
//! conversation (`route_order.rs`) and the sync between one person's own computers after a join (`profile_routes.rs`)
//! run exactly these, so files and profiles keep the same order: direct on the same network, then peer to peer (a
//! direct Internet connection here), then Bluetooth, then the relay. A better route takes over; a worse one never does.
#![allow(dead_code)] // each test file uses what it needs

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use szfriends_helper::nearby::test_air::ENV_TEST_BLUETOOTH;
use szfriends_helper::service::ENV_TEST_LOOPBACK;

pub const LAN: &str = "Nearby, on your network";
pub const BLUETOOTH: &str = "Nearby, over Bluetooth";
pub const DIRECT: &str = "Online, direct";
pub const RELAY: &str = "Online, through the Friends relay";

/// Copies each side's own entries to the other until dropped: the two test networks (or airs) become one.
pub struct Joined(Arc<AtomicBool>);

impl Joined {
    pub fn new(a: PathBuf, b: PathBuf) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let running = stop.clone();
        std::thread::spawn(move || {
            let (mut copied_into_a, mut copied_into_b) = (HashSet::new(), HashSet::new());
            while !running.load(Ordering::SeqCst) {
                copy_own(&a, &b, &copied_into_a, &mut copied_into_b);
                copy_own(&b, &a, &copied_into_b, &mut copied_into_a);
                std::thread::sleep(Duration::from_millis(50));
            }
        });
        Self(stop)
    }
}

impl Drop for Joined {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// Entries written in `from` itself (not ones copied there) reach `to` whenever they change.
fn copy_own(from: &Path, to: &Path, foreign: &HashSet<String>, copied: &mut HashSet<String>) {
    let Ok(entries) = std::fs::read_dir(from) else { return };
    for entry in entries.flatten() {
        let Ok(name) = entry.file_name().into_string() else { continue };
        if name.starts_with('.') || foreign.contains(&name) || !entry.path().is_file() {
            continue;
        }
        let Ok(bytes) = std::fs::read(entry.path()) else { continue };
        if std::fs::read(to.join(&name)).ok().as_deref() == Some(bytes.as_slice()) {
            continue;
        }
        let temporary = to.join(format!(".{name}.copy"));
        if std::fs::write(&temporary, &bytes).is_ok() && std::fs::rename(&temporary, to.join(&name)).is_ok() {
            copied.insert(name);
        }
    }
}

/// Two helpers' services in test homes, each on a nearby test network (or air) of its own until joined, both reaching
/// the other online through the local host first.
pub trait RoutePair: Sized {
    /// `variable` names the nearby test medium (`SZFRIENDS_TEST_LOOPBACK` or `SZFRIENDS_TEST_BLUETOOTH`) each side gets
    /// a directory of; `relayed` blocks direct Internet connections on both sides.
    fn start(label: &str, variable: &str, relayed: bool) -> Self;
    /// The two nearby media become one, as two people (or one person's two computers) walking into the same room.
    fn join(&self) -> Joined;
    /// Something new on one side reaches the other, and the route shown is `route`.
    fn carry_over(&mut self, route: &str);
    /// The route shown is `route`, once the sessions settle.
    fn shows(&mut self, route: &str);
    /// The route shown now, as the snapshot carries it (for asserting what never appears).
    fn shown(&mut self) -> String;
}

/// Online direct first; once they share a network, the network carries them.
pub fn the_network_takes_over_from_a_direct_connection<P: RoutePair>(label: &str) {
    let mut pair = P::start(&format!("{label}-lan"), ENV_TEST_LOOPBACK, false);
    pair.carry_over(DIRECT);
    let _joined = pair.join();
    pair.shows(LAN);
    pair.carry_over(LAN);
}

/// Through the relay first; once they are in Bluetooth range, Bluetooth carries them.
pub fn bluetooth_takes_over_from_the_relay<P: RoutePair>(label: &str) {
    let mut pair = P::start(&format!("{label}-bt-relay"), ENV_TEST_BLUETOOTH, true);
    pair.carry_over(RELAY);
    let _joined = pair.join();
    pair.shows(BLUETOOTH);
    pair.carry_over(BLUETOOTH);
}

/// Online direct first; Bluetooth in range changes nothing, since it ranks after a direct connection.
pub fn a_direct_connection_keeps_them_when_bluetooth_comes<P: RoutePair>(label: &str) {
    let mut pair = P::start(&format!("{label}-bt-direct"), ENV_TEST_BLUETOOTH, false);
    pair.carry_over(DIRECT);
    let _joined = pair.join();
    std::thread::sleep(Duration::from_secs(4));
    pair.carry_over(DIRECT);
    let shown = pair.shown();
    assert!(!shown.contains(BLUETOOTH), "Bluetooth took over: {shown}");
}

/// The owner's order, every scenario, for one kind of pair.
pub fn owners_route_order<P: RoutePair>(label: &str) {
    the_network_takes_over_from_a_direct_connection::<P>(label);
    bluetooth_takes_over_from_the_relay::<P>(label);
    a_direct_connection_keeps_them_when_bluetooth_comes::<P>(label);
}
