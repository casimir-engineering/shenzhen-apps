//! A test home's network held back (`$SZFRIENDS_TEST_NETWORK_HOLD`, in a test home only): while the named file
//! exists, the network adapter it wraps does not start (no entry registered, no browse, no listener) and reports
//! its radio off, as a computer with Wi-Fi off; once the file is gone it starts on the service's next tick (every
//! 250 ms at most while idle), as Wi-Fi coming up. Creating the file again stops it again. Tests use it to let two
//! helpers meet over the test air first and over the network later; the Objective-C helper does the same
//! (`SZFriendsHelperNetworkHold.m`).

use std::path::PathBuf;
use std::sync::Arc;

use szfriends_core::nearby::{AdapterState, Method, Permission, Tag};

use super::{bluetooth, dnssd, Adapter, Event, Sink};
use crate::log;

/// The hold file's path (`$SZFRIENDS_TEST_NETWORK_HOLD`), absolute; read once as the helper makes its adapters.
pub const ENV_TEST_NETWORK_HOLD: &str = "SZFRIENDS_TEST_NETWORK_HOLD";

/// See the module documentation.
pub struct Held {
    inner: Box<dyn Adapter>,
    file: PathBuf,
    sink: Arc<Sink>,
    /// The service asked the adapter to start.
    wanted: bool,
    /// Asked to start, and held back by the file.
    held: bool,
}

impl std::fmt::Debug for Held {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Held").field("file", &self.file).field("held", &self.held).finish()
    }
}

impl Held {
    pub fn new(inner: Box<dyn Adapter>, file: PathBuf, sink: Arc<Sink>) -> Self {
        Self { inner, file, sink, wanted: false, held: false }
    }

    /// Starts or stops the inner adapter as the file now says.
    fn follow(&mut self) {
        if !self.wanted {
            return;
        }
        let hold = self.file.exists();
        if hold == self.held {
            return;
        }
        self.held = hold;
        if hold {
            log!("nearby network: held by the test");
            self.inner.stop();
            (self.sink)(Event::State(self.inner.method(), AdapterState::RadioOff));
        } else {
            log!("nearby network: released by the test");
            self.inner.start();
        }
    }
}

impl Adapter for Held {
    fn method(&self) -> Method {
        self.inner.method()
    }

    fn state(&self) -> AdapterState {
        if self.held {
            AdapterState::RadioOff
        } else {
            self.inner.state()
        }
    }

    fn permission(&self) -> Permission {
        self.inner.permission()
    }

    fn start(&mut self) {
        if self.wanted {
            return;
        }
        self.wanted = true;
        self.held = self.file.exists();
        if self.held {
            log!("nearby network: held by the test");
            (self.sink)(Event::State(self.inner.method(), AdapterState::RadioOff));
        } else {
            self.inner.start();
        }
    }

    fn stop(&mut self) {
        if !self.wanted {
            return;
        }
        self.wanted = false;
        if std::mem::take(&mut self.held) {
            (self.sink)(Event::State(self.inner.method(), AdapterState::NotAsked));
        } else {
            self.inner.stop();
        }
    }

    fn advertise(&mut self, tag: Option<Tag>, slots: &[Tag], public: bool) {
        // Kept by the inner adapter until it runs.
        self.inner.advertise(tag, slots, public);
    }

    fn browse_event(&mut self, event: dnssd::BrowseEvent) -> Vec<Event> {
        if self.held {
            return Vec::new();
        }
        self.inner.browse_event(event)
    }

    fn radio_event(&mut self, event: bluetooth::RadioEvent) -> Vec<Event> {
        self.inner.radio_event(event)
    }

    fn dial(&mut self, endpoint: &str, dial: u64) -> bool {
        !self.held && self.inner.dial(endpoint, dial)
    }

    fn refresh(&mut self) {
        self.follow();
        if !self.held {
            self.inner.refresh();
        }
    }

    fn listening(&self) -> bool {
        self.inner.listening()
    }

    fn tick(&mut self) {
        self.follow();
        self.inner.tick();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    #[derive(Default)]
    struct Calls(Mutex<Vec<&'static str>>);

    struct Recorder(Arc<Calls>, bool);

    impl Adapter for Recorder {
        fn method(&self) -> Method {
            Method::Network
        }
        fn state(&self) -> AdapterState {
            if self.1 {
                AdapterState::Working
            } else {
                AdapterState::NotAsked
            }
        }
        fn start(&mut self) {
            self.1 = true;
            self.0 .0.lock().unwrap().push("start");
        }
        fn stop(&mut self) {
            self.1 = false;
            self.0 .0.lock().unwrap().push("stop");
        }
        fn advertise(&mut self, _: Option<Tag>, _: &[Tag], _: bool) {
            self.0 .0.lock().unwrap().push("advertise");
        }
        fn browse_event(&mut self, _: dnssd::BrowseEvent) -> Vec<Event> {
            Vec::new()
        }
        fn dial(&mut self, _: &str, _: u64) -> bool {
            true
        }
    }

    #[test]
    fn starts_only_once_the_file_is_gone_and_stops_when_it_returns() {
        let directory = std::env::temp_dir().join(format!("szf-hold-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let file = directory.join("hold");
        std::fs::write(&file, b"").unwrap();
        let calls = Arc::new(Calls::default());
        let states = Arc::new(Mutex::new(Vec::new()));
        let seen = states.clone();
        let sink: Arc<Sink> = Arc::new(Box::new(move |event| {
            if let Event::State(_, state) = event {
                seen.lock().unwrap().push(state);
            }
        }));
        let mut held = Held::new(Box::new(Recorder(calls.clone(), false)), file.clone(), sink);
        held.advertise(None, &[], false);
        held.start();
        held.tick();
        assert_eq!(held.state(), AdapterState::RadioOff);
        assert!(!held.dial("n:x", 1), "nothing is dialled while held");
        assert_eq!(*calls.0.lock().unwrap(), ["advertise"], "not started while the file exists");
        std::fs::remove_file(&file).unwrap();
        held.tick();
        assert_eq!(held.state(), AdapterState::Working);
        assert_eq!(*calls.0.lock().unwrap(), ["advertise", "start"]);
        std::fs::write(&file, b"").unwrap();
        held.tick();
        assert_eq!(held.state(), AdapterState::RadioOff);
        assert_eq!(*calls.0.lock().unwrap(), ["advertise", "start", "stop"]);
        held.stop();
        assert_eq!(held.state(), AdapterState::NotAsked);
        assert_eq!(*states.lock().unwrap(), [AdapterState::RadioOff, AdapterState::RadioOff, AdapterState::NotAsked]);
        let _ = std::fs::remove_file(&file);
        let _ = std::fs::remove_dir(&directory);
    }
}
