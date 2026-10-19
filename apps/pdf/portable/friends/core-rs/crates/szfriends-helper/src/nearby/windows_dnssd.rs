//! DNS-SD on Windows through the system's API (`szfriends-helper-sys::dnssd`): registered and browsed by the DNS
//! client, so the helper opens no multicast socket and meets no firewall rule (ADR 0015 § 15). Browsing reports names;
//! each is resolved for its port, addresses and TXT, and resolved again every so often, since the API reports a
//! changed TXT (new callback slots within a window) only when asked.

use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use szfriends_helper_sys::dnssd::{self, BrowseRecord, Registration};

use super::dnssd::{BrowseEvent, BrowseSink, DnsSd};

const RESOLVE_TIMEOUT: Duration = Duration::from_secs(5);
const RESOLVE_AGAIN: Duration = Duration::from_secs(20);

type Known = Arc<Mutex<HashMap<String, BrowseEvent>>>;

/// See the module documentation.
pub struct WindowsDnsSd {
    service: String,
    host: String,
    registrations: HashMap<String, Registration>,
    browse: Option<dnssd::Browse>,
    stop: Arc<AtomicBool>,
}

impl std::fmt::Debug for WindowsDnsSd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WindowsDnsSd").field("service", &self.service).finish()
    }
}

fn resolve(service: &str, name: &str) -> Option<BrowseEvent> {
    let instance = dnssd::resolve(&format!("{name}.{service}"), 0, RESOLVE_TIMEOUT).ok()??;
    let mut addresses: Vec<SocketAddr> = Vec::new();
    addresses.extend(instance.ipv4.map(|a| SocketAddr::from((a, instance.port))));
    addresses.extend(instance.ipv6.map(|a| SocketAddr::from((a, instance.port))));
    let txt = instance.properties.into_iter().map(|(k, v)| (k, v.into_bytes())).collect();
    Some(BrowseEvent::Found { name: name.to_owned(), addresses, txt })
}

fn found(service: String, name: String, known: Known, sink: Arc<BrowseSink>) {
    if let Some(event) = resolve(&service, &name) {
        let mut table = known.lock().unwrap_or_else(|e| e.into_inner());
        if table.get(&name) != Some(&event) {
            table.insert(name, event.clone());
            drop(table);
            sink(event);
        }
    }
}

impl WindowsDnsSd {
    pub fn new(service_type: &str) -> Self {
        let computer = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "windows".into()).to_lowercase();
        Self {
            service: format!("{service_type}.local"),
            host: format!("{computer}.local"),
            registrations: HashMap::new(),
            browse: None,
            stop: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl DnsSd for WindowsDnsSd {
    fn browse(&mut self, sink: BrowseSink) -> io::Result<()> {
        self.stop.store(true, Ordering::SeqCst);
        self.browse = None;
        self.stop = Arc::new(AtomicBool::new(false));
        let sink = Arc::new(sink);
        let known: Known = Arc::new(Mutex::new(HashMap::new()));
        let suffix = format!(".{}", self.service);
        let (service, callback_known, callback_sink) = (self.service.clone(), known.clone(), sink.clone());
        let callback = move |record: BrowseRecord| {
            let (added, full) = match record {
                BrowseRecord::Added(full) => (true, full),
                BrowseRecord::Removed(full) => (false, full),
            };
            let Some(name) = full.strip_suffix(&suffix).map(str::to_owned) else { return };
            if added {
                let (service, known, sink) = (service.clone(), callback_known.clone(), callback_sink.clone());
                std::thread::spawn(move || found(service, name, known, sink));
            } else if callback_known.lock().unwrap_or_else(|e| e.into_inner()).remove(&name).is_some() {
                callback_sink(BrowseEvent::Lost { name });
            }
        };
        self.browse = Some(dnssd::browse(&self.service, 0, Box::new(callback))?);
        sink(BrowseEvent::Ready);
        let (stop, service) = (self.stop.clone(), self.service.clone());
        std::thread::Builder::new().name("szfriends-dnssd".into()).spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                std::thread::sleep(RESOLVE_AGAIN);
                let names: Vec<String> = known.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
                for name in names {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    found(service.clone(), name, known.clone(), sink.clone());
                }
            }
        })?;
        Ok(())
    }

    fn register(&mut self, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()> {
        // A changed TXT is a new registration under the same name: the old one goes first.
        self.registrations.remove(name);
        let full = format!("{name}.{}", self.service);
        let registration = dnssd::register(&full, &self.host, port, txt, 0)?;
        self.registrations.insert(name.to_owned(), registration);
        Ok(())
    }

    fn unregister(&mut self, name: &str) {
        self.registrations.remove(name);
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.browse = None;
        self.registrations.clear();
    }
}

impl Drop for WindowsDnsSd {
    fn drop(&mut self) {
        self.stop();
    }
}
