//! A loopback proxy between a dialer and a listener, for one connection at a time: it forwards both ways, and can
//! cut the route after a number of bytes in one direction (a lost Wi-Fi link) or flip one byte (an attacker on the
//! path). It counts what passed each way.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// What the proxy does to the next connection, counted in bytes per direction from its start.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Tamper {
    /// Dialer to listener: flip this byte with 0x01.
    pub flip_to_listener: Option<u64>,
    /// Listener to dialer.
    pub flip_to_dialer: Option<u64>,
    /// Close both directions once this many bytes went from the dialer to the listener.
    pub cut_to_listener_after: Option<u64>,
    /// Or once this many went from the listener to the dialer.
    pub cut_to_dialer_after: Option<u64>,
    /// Paces both directions to this many bytes a second: a slower route.
    pub bytes_per_second: Option<u64>,
}

#[derive(Debug)]
pub struct Proxy {
    port: u16,
    tamper: Arc<Mutex<Tamper>>,
    to_listener: Arc<AtomicU64>,
    to_dialer: Arc<AtomicU64>,
}

impl Proxy {
    /// Listens on a loopback port and forwards each connection to `target` on loopback.
    pub fn start(target: u16) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port");
        let port = listener.local_addr().expect("bound").port();
        let tamper = Arc::new(Mutex::new(Tamper::default()));
        let (to_listener, to_dialer) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0)));
        let (shared, up, down) = (tamper.clone(), to_listener.clone(), to_dialer.clone());
        std::thread::spawn(move || {
            for dialer in listener.incoming().flatten() {
                let Ok(upstream) = TcpStream::connect(("127.0.0.1", target)) else { continue };
                let rules = *shared.lock().unwrap();
                up.store(0, Ordering::SeqCst);
                down.store(0, Ordering::SeqCst);
                let pair = (dialer.try_clone().unwrap(), upstream.try_clone().unwrap());
                let cut = (rules.cut_to_listener_after, rules.cut_to_dialer_after);
                let ends = (dialer.try_clone().unwrap(), upstream.try_clone().unwrap());
                let ends_too = (dialer.try_clone().unwrap(), upstream.try_clone().unwrap());
                let counter = up.clone();
                let rate = rules.bytes_per_second;
                std::thread::spawn(move || {
                    forward(dialer, upstream, (rules.flip_to_listener, cut.0, rate), counter, ends)
                });
                let counter = down.clone();
                std::thread::spawn(move || {
                    forward(pair.1, pair.0, (rules.flip_to_dialer, cut.1, rate), counter, ends_too)
                });
            }
        });
        Self { port, tamper, to_listener, to_dialer }
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// Rules for the next connection.
    pub fn set(&self, tamper: Tamper) {
        *self.tamper.lock().unwrap() = tamper;
    }

    /// Bytes forwarded on the current connection: (dialer to listener, listener to dialer).
    pub fn counts(&self) -> (u64, u64) {
        (self.to_listener.load(Ordering::SeqCst), self.to_dialer.load(Ordering::SeqCst))
    }
}

/// (flip, cut, rate): what to do to this direction.
type Rules = (Option<u64>, Option<u64>, Option<u64>);

fn forward(
    mut from: TcpStream,
    mut to: TcpStream,
    rules: Rules,
    counter: Arc<AtomicU64>,
    ends: (TcpStream, TcpStream),
) {
    let (flip, cut, rate) = rules;
    let started = std::time::Instant::now();
    let mut buffer = vec![0u8; if rate.is_some() { 16_384 } else { 65_536 }];
    let mut passed = 0u64;
    loop {
        if let Some(rate) = rate {
            let due = std::time::Duration::from_secs_f64(passed as f64 / rate as f64);
            if let Some(wait) = due.checked_sub(started.elapsed()) {
                std::thread::sleep(wait);
            }
        }
        let n = match from.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let mut piece = &mut buffer[..n];
        if let Some(index) = flip.filter(|i| *i >= passed && *i < passed + n as u64) {
            piece[(index - passed) as usize] ^= 0x01;
        }
        if let Some(limit) = cut {
            if passed + n as u64 >= limit {
                let keep = (limit - passed) as usize;
                piece = &mut piece[..keep];
                let _ = to.write_all(piece);
                counter.fetch_add(keep as u64, Ordering::SeqCst);
                // The route is gone: both ends see the connection drop at once.
                let _ = ends.0.shutdown(Shutdown::Both);
                let _ = ends.1.shutdown(Shutdown::Both);
                return;
            }
        }
        if to.write_all(piece).is_err() {
            break;
        }
        passed += n as u64;
        counter.fetch_add(n as u64, Ordering::SeqCst);
    }
    let _ = to.shutdown(Shutdown::Write);
}
