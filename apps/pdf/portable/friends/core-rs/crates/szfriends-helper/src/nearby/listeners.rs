//! The TCP listeners nearby friends connect to: each on its own accept thread, reporting connections to the service
//! with the listener they came through and the address they count under for admission (`txt::admission_key`).

use std::io::ErrorKind;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use szfriends_core::nearby::txt::admission_key;
use szfriends_core::wire::RouteMethod;

use super::{Event, Sink};
use crate::log;

/// Where the listeners bind (ADR 0015 § 15).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Binding {
    /// 127.0.0.1 only: test networks.
    Loopback,
    /// Every address, any port.
    Network,
    /// Every address, within these port ranges (a firewall rule's): a fixed-port rule keeps one port.
    Within(Vec<(u16, u16)>),
    /// Not at all: this computer connects to friends nearby itself.
    Nowhere,
    /// The platform listens itself, one listener per entry (iOS's `NWListener`, peer-to-peer Wi-Fi included).
    Platform,
}

/// One listening socket and its accept thread; dropping it stops both.
#[derive(Debug)]
pub struct Listener {
    port: u16,
    stop: Arc<AtomicBool>,
}

fn accept_loop(listener: TcpListener, stop: Arc<AtomicBool>, public: bool, id: String, sink: Arc<Sink>) {
    while !stop.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, from)) => {
                if stream.set_nonblocking(false).is_err() {
                    continue;
                }
                let scope = match from {
                    SocketAddr::V6(v6) => v6.scope_id(),
                    SocketAddr::V4(_) => 0,
                };
                let address = Some(admission_key(from.ip(), scope));
                let listener = id.clone();
                sink(Event::Accepted { stream: stream.into(), route: RouteMethod::Lan, public, listener, address });
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(50)),
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) => {
                log!("nearby listener: {error}");
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    }
}

fn candidates(binding: &Binding) -> Vec<SocketAddr> {
    let any = IpAddr::V4(Ipv4Addr::UNSPECIFIED);
    match binding {
        Binding::Loopback => vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)],
        Binding::Network => vec![SocketAddr::new(any, 0)],
        Binding::Within(ranges) => {
            // A random port inside the admitted ranges, a few tries, so each window can move as the rules allow.
            let mut ports = Vec::new();
            for _ in 0..8 {
                let (low, high) = ranges[random_index(ranges.len())];
                let span = u32::from(high) - u32::from(low) + 1;
                ports.push(low + (random_index(span as usize) as u16));
            }
            ports.into_iter().map(|port| SocketAddr::new(any, port)).collect()
        }
        Binding::Nowhere | Binding::Platform => Vec::new(),
    }
}

fn random_index(bound: usize) -> usize {
    let mut bytes = [0u8; 8];
    szfriends_core::crypto::random_bytes(&mut bytes);
    (u64::from_le_bytes(bytes) % bound.max(1) as u64) as usize
}

impl Listener {
    /// Binds per `binding` and starts accepting; `id` names the listener for admission ("hidden", "public").
    pub fn start(binding: &Binding, public: bool, id: &str, sink: Arc<Sink>) -> std::io::Result<Self> {
        let mut last = std::io::Error::new(ErrorKind::AddrNotAvailable, "no address to listen on");
        for address in candidates(binding) {
            match TcpListener::bind(address) {
                Ok(listener) => {
                    let port = listener.local_addr()?.port();
                    listener.set_nonblocking(true)?;
                    let stop = Arc::new(AtomicBool::new(false));
                    // IPv6 too where the network allows it, on the same port.
                    if *binding == Binding::Network {
                        if let Ok(v6) = TcpListener::bind(SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port)) {
                            v6.set_nonblocking(true)?;
                            let (stop, id, sink) = (stop.clone(), id.to_owned(), sink.clone());
                            std::thread::Builder::new()
                                .name("szfriends-listen6".into())
                                .spawn(move || accept_loop(v6, stop, public, id, sink))?;
                        }
                    }
                    let (thread_stop, id) = (stop.clone(), id.to_owned());
                    std::thread::Builder::new()
                        .name("szfriends-listen".into())
                        .spawn(move || accept_loop(listener, thread_stop, public, id, sink))?;
                    return Ok(Self { port, stop });
                }
                Err(error) => last = error,
            }
        }
        Err(last)
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}
