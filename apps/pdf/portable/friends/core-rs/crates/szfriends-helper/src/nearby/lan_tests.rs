//! Where the LAN adapter listens, decided again: before each window's hidden listener and at each set-up (a network
//! change or waking restarts the adapter), so a firewall rule or profile that changed takes effect without a restart.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::*;
use crate::nearby::Adapter;

type Registered = Arc<Mutex<Vec<String>>>;

struct Recorder(Registered);

impl DnsSd for Recorder {
    fn browse(&mut self, _sink: super::super::dnssd::BrowseSink) -> std::io::Result<()> {
        Ok(())
    }
    fn register(&mut self, name: &str, _port: u16, _txt: &[(String, String)]) -> std::io::Result<()> {
        let mut names = self.0.lock().unwrap();
        if !names.iter().any(|n| n == name) {
            names.push(name.to_owned());
        }
        Ok(())
    }
    fn unregister(&mut self, name: &str) {
        self.0.lock().unwrap().retain(|n| n != name);
    }
    fn stop(&mut self) {
        self.0.lock().unwrap().clear();
    }
}

fn adapter(blocked: &Arc<AtomicBool>) -> (LanAdapter, Registered) {
    let registered = Registered::default();
    let sink: Arc<Sink> = Arc::new(Box::new(|_| {}));
    let blocked = blocked.clone();
    let rebind: Rebind =
        Box::new(move || if blocked.load(Ordering::SeqCst) { Binding::Nowhere } else { Binding::Loopback });
    let lan = LanAdapter::new(Box::new(Recorder(registered.clone())), Binding::Network, sink).with_rebind(rebind);
    (lan, registered)
}

fn tag(n: u8) -> szfriends_core::nearby::Tag {
    [n; szfriends_crypto::presence::TAG_LEN]
}

fn slots() -> Vec<szfriends_core::nearby::Tag> {
    (2..6).map(tag).collect()
}

#[test]
fn a_firewall_that_closes_takes_effect_at_the_next_set_up() {
    let blocked = Arc::new(AtomicBool::new(false));
    let (mut lan, registered) = adapter(&blocked);
    lan.start();
    assert!(lan.listening());
    assert_eq!(registered.lock().unwrap().len(), 1, "the hidden entry is on the air");
    blocked.store(true, Ordering::SeqCst);
    // What a network change or waking does.
    lan.stop();
    lan.start();
    assert!(!lan.listening(), "nobody can reach this computer now");
    assert!(registered.lock().unwrap().is_empty(), "nothing is advertised that nobody could reach");
}

#[test]
fn each_new_window_asks_again() {
    let blocked = Arc::new(AtomicBool::new(true));
    let (mut lan, registered) = adapter(&blocked);
    lan.start();
    assert!(!lan.listening());
    lan.advertise(Some(tag(1)), &slots(), false);
    assert!(registered.lock().unwrap().is_empty());
    // A rule admits the helper now: the next window listens and is advertised.
    blocked.store(false, Ordering::SeqCst);
    lan.advertise(Some(tag(6)), &slots(), true);
    assert!(lan.listening());
    assert_eq!(registered.lock().unwrap().len(), 2, "the hidden and the public entry");
    // Closed again: the next window takes both off the air.
    blocked.store(true, Ordering::SeqCst);
    lan.advertise(Some(tag(7)), &slots(), true);
    assert!(!lan.listening());
    assert!(registered.lock().unwrap().is_empty());
}
