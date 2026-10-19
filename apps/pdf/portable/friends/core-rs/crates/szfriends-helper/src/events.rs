//! Desktop power and network events (ADR 0015 § 16), as the Mac helper gets them from IOKit and `NWPathMonitor`:
//! before sleep the service pauses transfers at a verified offset; on wake or a network change it announces,
//! browses and races routes again and resumes. Windows: `PowerRegisterSuspendResumeNotification`,
//! `NotifyIpInterfaceChange` and `NotifyUnicastIpAddressChange`. Linux: logind's `PrepareForSleep` and rtnetlink.

use std::sync::mpsc::Sender;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use crate::lifecycle::Event;
use crate::log;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SystemEvent {
    /// The system is about to sleep.
    Sleep,
    /// The system woke.
    Wake,
    /// An interface or an address came, went or changed (a burst arrives as one).
    NetworkChanged,
}

/// How long a burst of network changes must be quiet before it is reported once.
const NETWORK_QUIET: Duration = Duration::from_millis(300);

/// Turns bursts of network notifications into one event after they settle. The last change of a burst is never
/// lost: the report goes out after the quiet period that follows it.
#[derive(Debug, Clone)]
pub struct Debouncer {
    pending: Arc<(Mutex<bool>, Condvar)>,
}

impl Debouncer {
    pub fn new(quiet: Duration, report: impl Fn() + Send + 'static) -> Self {
        let pending = Arc::new((Mutex::new(false), Condvar::new()));
        let shared = pending.clone();
        let spawned = thread::Builder::new().name("szfriends-network".into()).spawn(move || {
            let (flag, changed) = &*shared;
            loop {
                let mut waiting = flag.lock().unwrap_or_else(|e| e.into_inner());
                while !*waiting {
                    waiting = changed.wait(waiting).unwrap_or_else(|e| e.into_inner());
                }
                // Quiet means no new change for `quiet`; each change restarts the wait.
                loop {
                    *waiting = false;
                    let (guard, timeout) = changed.wait_timeout(waiting, quiet).unwrap_or_else(|e| e.into_inner());
                    waiting = guard;
                    if timeout.timed_out() && !*waiting {
                        break;
                    }
                }
                drop(waiting);
                report();
            }
        });
        if spawned.is_err() {
            log!("no thread for network events");
        }
        Self { pending }
    }

    pub fn changed(&self) {
        let (flag, changed) = &*self.pending;
        *flag.lock().unwrap_or_else(|e| e.into_inner()) = true;
        changed.notify_all();
    }
}

/// The platform's registrations; dropping them stops the events.
#[derive(Debug, Default)]
pub struct Watchers {
    #[cfg(windows)]
    _power: Option<szfriends_helper_sys::events::PowerWatch>,
    #[cfg(windows)]
    _network: Option<szfriends_helper_sys::events::NetworkWatch>,
}

/// Starts watching; each event goes to the lifecycle, which hands it to the service.
pub fn start(events: Sender<Event>) -> Watchers {
    let sender = Arc::new(Mutex::new(events));
    let send = move |event: SystemEvent| {
        let _ = sender.lock().unwrap_or_else(|e| e.into_inner()).send(Event::System(event));
    };
    let network_send = send.clone();
    let network = Debouncer::new(NETWORK_QUIET, move || network_send(SystemEvent::NetworkChanged));
    platform::start(send, network)
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{Debouncer, SystemEvent, Watchers};
    use crate::linux::{dbus::Bus, logind, netlink};
    use crate::log;

    pub fn start(send: impl Fn(SystemEvent) + Send + Clone + 'static, network: Debouncer) -> Watchers {
        let _ = std::thread::Builder::new().name("szfriends-logind".into()).spawn(move || {
            let result = Bus::system().and_then(|bus| {
                logind::watch(bus, Some(logind::LOGIND), |sleeping| {
                    send(if sleeping { SystemEvent::Sleep } else { SystemEvent::Wake })
                })
            });
            if let Err(error) = result {
                log!("sleep and wake events unavailable: {error}");
            }
        });
        let _ = std::thread::Builder::new().name("szfriends-netlink".into()).spawn(move || {
            if let Err(error) = netlink::watch(|| network.changed()) {
                log!("network events unavailable: {error}");
            }
        });
        Watchers::default()
    }
}

#[cfg(windows)]
mod platform {
    use szfriends_helper_sys::events::{watch_network, watch_power, PowerEvent};

    use super::{Debouncer, SystemEvent, Watchers};
    use crate::log;

    pub fn start(send: impl Fn(SystemEvent) + Send + Sync + Clone + 'static, network: Debouncer) -> Watchers {
        let power = watch_power(move |event| {
            send(if event == PowerEvent::Suspend { SystemEvent::Sleep } else { SystemEvent::Wake })
        });
        let network = watch_network(move |_| network.changed(), false);
        if let Err(error) = &power {
            log!("sleep and wake events unavailable: {error}");
        }
        if let Err(error) = &network {
            log!("network events unavailable: {error}");
        }
        Watchers { _power: power.ok(), _network: network.ok() }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod platform {
    use super::{Debouncer, SystemEvent, Watchers};

    pub fn start(_send: impl Fn(SystemEvent) + Send + Clone + 'static, _network: Debouncer) -> Watchers {
        Watchers::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;

    #[test]
    fn a_burst_of_changes_is_reported_once_after_it_settles() {
        let (sender, receiver) = channel();
        let debouncer = Debouncer::new(Duration::from_millis(100), move || sender.send(()).unwrap());
        for _ in 0..20 {
            debouncer.changed();
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(receiver.recv_timeout(Duration::from_secs(2)), Ok(()));
        assert!(receiver.recv_timeout(Duration::from_millis(300)).is_err(), "one report for the burst");
        debouncer.changed();
        assert_eq!(receiver.recv_timeout(Duration::from_secs(2)), Ok(()), "a later change is reported again");
    }
}
