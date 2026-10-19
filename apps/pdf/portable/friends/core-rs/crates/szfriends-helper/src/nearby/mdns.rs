//! DNS-SD on Linux through `mdns-sd` (ADR 0015 § 9): pure Rust, beside Avahi (both share UDP 5353). The daemon,
//! which opens the multicast sockets, is made only when Nearby starts. Entries go out under a random host name of
//! their own, never the computer's, so nothing in them names the person or links one run to the next.

use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, SocketAddr, SocketAddrV6};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use mdns_sd::{IfKind, ScopedIp, ServiceDaemon, ServiceEvent, ServiceInfo};

use super::dnssd::{BrowseEvent, BrowseSink, DnsSd};

/// Which interfaces the daemon uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interfaces {
    /// Every network interface but loopback: the person's networks.
    Network,
    /// Loopback only: test homes (a test network namespace in the Linux VM).
    Loopback,
}

/// See the module documentation.
pub struct Mdns {
    ty_domain: String,
    interfaces: Interfaces,
    daemon: Option<ServiceDaemon>,
    host: String,
    registered: HashMap<String, String>,
    browsing: Option<Arc<AtomicBool>>,
}

impl std::fmt::Debug for Mdns {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Mdns").field("ty_domain", &self.ty_domain).field("interfaces", &self.interfaces).finish()
    }
}

fn error(e: mdns_sd::Error) -> io::Error {
    io::Error::other(e.to_string())
}

fn socket_address(ip: &ScopedIp, port: u16) -> SocketAddr {
    match ip {
        ScopedIp::V6(v6) => SocketAddr::V6(SocketAddrV6::new(*v6.addr(), port, 0, v6.scope_id().index)),
        other => SocketAddr::new(other.to_ip_addr(), port),
    }
}

impl Mdns {
    pub fn new(service_type: &str, interfaces: Interfaces) -> Self {
        let mut bytes = [0u8; 6];
        szfriends_core::crypto::random_bytes(&mut bytes);
        Self {
            ty_domain: format!("{service_type}.local."),
            interfaces,
            daemon: None,
            host: format!("{}.local.", hex::encode(bytes)),
            registered: HashMap::new(),
            browsing: None,
        }
    }

    fn daemon(&mut self) -> io::Result<&ServiceDaemon> {
        if self.daemon.is_none() {
            let daemon = ServiceDaemon::new().map_err(error)?;
            match self.interfaces {
                Interfaces::Network => {
                    daemon.disable_interface(vec![IfKind::LoopbackV4, IfKind::LoopbackV6]).map_err(error)?;
                }
                Interfaces::Loopback => {
                    daemon.disable_interface(IfKind::All).map_err(error)?;
                    daemon.enable_interface(IfKind::LoopbackV4).map_err(error)?;
                    daemon.set_multicast_loop_v4(true).map_err(error)?;
                }
            }
            self.daemon = Some(daemon);
        }
        Ok(self.daemon.as_ref().expect("made above"))
    }
}

impl DnsSd for Mdns {
    fn browse(&mut self, sink: BrowseSink) -> io::Result<()> {
        if let Some(stop) = self.browsing.take() {
            stop.store(true, Ordering::SeqCst);
        }
        let ty_domain = self.ty_domain.clone();
        let receiver = self.daemon()?.browse(&ty_domain).map_err(error)?;
        let stop = Arc::new(AtomicBool::new(false));
        self.browsing = Some(stop.clone());
        let suffix = format!(".{ty_domain}");
        std::thread::Builder::new().name("szfriends-mdns".into()).spawn(move || {
            sink(BrowseEvent::Ready);
            while !stop.load(Ordering::SeqCst) {
                let Ok(event) = receiver.recv_timeout(Duration::from_millis(250)) else {
                    if receiver.is_disconnected() {
                        return;
                    }
                    continue;
                };
                match event {
                    ServiceEvent::ServiceResolved(info) => {
                        let Some(name) = info.fullname.strip_suffix(&suffix).map(|n| n.replace("\\.", ".")) else {
                            continue;
                        };
                        let addresses = info.addresses.iter().map(|ip| socket_address(ip, info.port)).collect();
                        let txt = info
                            .txt_properties
                            .iter()
                            .map(|p| (p.key().to_owned(), p.val().unwrap_or_default().to_vec()))
                            .collect();
                        sink(BrowseEvent::Found { name, addresses, txt });
                    }
                    ServiceEvent::ServiceRemoved(_, fullname) => {
                        if let Some(name) = fullname.strip_suffix(&suffix) {
                            sink(BrowseEvent::Lost { name: name.replace("\\.", ".") });
                        }
                    }
                    _ => {}
                }
            }
        })?;
        Ok(())
    }

    fn register(&mut self, name: &str, port: u16, txt: &[(String, String)]) -> io::Result<()> {
        let properties: HashMap<String, String> = txt.iter().cloned().collect();
        let (ty_domain, host, interfaces) = (self.ty_domain.clone(), self.host.clone(), self.interfaces);
        let info = match interfaces {
            Interfaces::Loopback => {
                ServiceInfo::new(&ty_domain, name, &host, IpAddr::from([127, 0, 0, 1]), port, properties)
            }
            Interfaces::Network => {
                ServiceInfo::new(&ty_domain, name, &host, (), port, properties).map(ServiceInfo::enable_addr_auto)
            }
        }
        .map_err(error)?;
        let fullname = info.get_fullname().to_owned();
        self.daemon()?.register(info).map_err(error)?;
        self.registered.insert(name.to_owned(), fullname);
        Ok(())
    }

    fn unregister(&mut self, name: &str) {
        if let (Some(fullname), Some(daemon)) = (self.registered.remove(name), self.daemon.as_ref()) {
            let _ = daemon.unregister(&fullname);
        }
    }

    fn stop(&mut self) {
        if let Some(stop) = self.browsing.take() {
            stop.store(true, Ordering::SeqCst);
        }
        let names: Vec<String> = self.registered.keys().cloned().collect();
        for name in names {
            self.unregister(&name);
        }
        if let Some(daemon) = self.daemon.take() {
            // Goodbyes for what was registered go out before the sockets close.
            if let Ok(done) = daemon.shutdown() {
                let _ = done.recv_timeout(Duration::from_secs(1));
            }
        }
    }
}

impl Drop for Mdns {
    fn drop(&mut self) {
        self.stop();
    }
}
