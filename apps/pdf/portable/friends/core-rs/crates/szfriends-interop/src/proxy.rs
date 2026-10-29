//! A loopback proxy between a dialer and a listener, for one connection at a time: it forwards both ways and can make
//! that connection look like a route. It paces each direction to a rate, delays it by a one-way time, models packet
//! loss, goes silent (a route out of range: sockets stay open, nothing moves, for a while or for good, once or
//! flapping), cuts the route after a number of bytes in one direction (a lost Wi-Fi link) or flips one byte (an
//! attacker on the path). It counts what passed each way and remembers when the route went away.
//!
//! Loss is a model, not dropped packets: loopback TCP never loses, and real loss needs root (dummynet). Each direction
//! keeps a Reno-like congestion window over 1,448-byte segments: it grows by a segment per round trip (doubling in
//! slow start), a lost segment halves it and holds the stream for one round trip, as a fast retransmit does, and the
//! direction never passes more than a window per round trip. That gives TCP's throughput under loss (Mathis et al.:
//! about MSS / RTT × 1.22 / √p) to whatever runs over it; CUBIC with SACK does somewhat better on real paths.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

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
    /// Delays every byte by this much in each direction (half the route's round trip).
    pub one_way_delay: Option<Duration>,
    /// Segments lost per million, in each direction (see the module's note on the model).
    pub loss_per_million: u32,
    /// Goes silent once this many bytes passed, both directions together: nothing is read or delivered, sockets stay
    /// open, as a route out of range looks to TCP.
    pub silence_after: Option<u64>,
    /// How long the silence lasts; `None`: until the connection ends.
    pub silence_for: Option<Duration>,
    /// Silence only the dialer-to-listener direction; the other keeps flowing.
    pub silence_one_way: bool,
    /// Flapping: from the start, up for the first duration, silent for the second, again and again.
    pub flap: Option<(Duration, Duration)>,
}

#[derive(Debug)]
pub struct Proxy {
    port: u16,
    tamper: Arc<Mutex<Tamper>>,
    to_listener: Arc<AtomicU64>,
    to_dialer: Arc<AtomicU64>,
    lost_at: Arc<Mutex<Option<Instant>>>,
}

impl Proxy {
    /// Listens on a loopback port and forwards each connection to `target` on loopback.
    pub fn start(target: u16) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port");
        let port = listener.local_addr().expect("bound").port();
        let tamper = Arc::new(Mutex::new(Tamper::default()));
        let (to_listener, to_dialer) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0)));
        let lost_at = Arc::new(Mutex::new(None));
        let (shared, up, down, lost) = (tamper.clone(), to_listener.clone(), to_dialer.clone(), lost_at.clone());
        std::thread::spawn(move || {
            for dialer in listener.incoming().flatten() {
                let Ok(upstream) = TcpStream::connect(("127.0.0.1", target)) else { continue };
                let _ = (dialer.set_nodelay(true), upstream.set_nodelay(true));
                let rules = *shared.lock().unwrap();
                up.store(0, Ordering::SeqCst);
                down.store(0, Ordering::SeqCst);
                *lost.lock().unwrap() = None;
                let route = Arc::new(Route {
                    started: Instant::now(),
                    rules,
                    dark_since: Mutex::new(None),
                    lost_at: lost.clone(),
                    ends: (dialer.try_clone().unwrap(), upstream.try_clone().unwrap()),
                    passed: (up.clone(), down.clone()),
                });
                let pair = (dialer.try_clone().unwrap(), upstream.try_clone().unwrap());
                let up_rules =
                    Direction { flip: rules.flip_to_listener, cut: rules.cut_to_listener_after, to_listener: true };
                let down_rules =
                    Direction { flip: rules.flip_to_dialer, cut: rules.cut_to_dialer_after, to_listener: false };
                let (route_up, counter_up, counter_down) = (route.clone(), up.clone(), down.clone());
                std::thread::spawn(move || forward(dialer, upstream, up_rules, counter_up, &route_up));
                std::thread::spawn(move || forward(pair.1, pair.0, down_rules, counter_down, &route));
            }
        });
        Self { port, tamper, to_listener, to_dialer, lost_at }
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

    /// When the current connection was cut or first went silent.
    pub fn lost_at(&self) -> Option<Instant> {
        *self.lost_at.lock().unwrap()
    }
}

struct Route {
    started: Instant,
    rules: Tamper,
    /// When the one-time silence began.
    dark_since: Mutex<Option<Instant>>,
    lost_at: Arc<Mutex<Option<Instant>>>,
    ends: (TcpStream, TcpStream),
    passed: (Arc<AtomicU64>, Arc<AtomicU64>),
}

impl Route {
    fn lost(&self) {
        self.lost_at.lock().unwrap().get_or_insert_with(Instant::now);
    }

    fn cut(&self) {
        self.lost();
        // The route is gone: both ends see the connection drop at once.
        let _ = self.ends.0.shutdown(Shutdown::Both);
        let _ = self.ends.1.shutdown(Shutdown::Both);
    }

    /// Whether this direction is silent now.
    fn dark(&self, to_listener: bool) -> bool {
        if self.rules.silence_one_way && !to_listener {
            return false;
        }
        if let Some((up, down)) = self.rules.flap {
            let period = (up + down).as_secs_f64();
            if period > 0.0 && self.started.elapsed().as_secs_f64() % period >= up.as_secs_f64() {
                self.lost();
                return true;
            }
        }
        let Some(after) = self.rules.silence_after else { return false };
        let mut since = self.dark_since.lock().unwrap();
        let passed = self.passed.0.load(Ordering::SeqCst) + self.passed.1.load(Ordering::SeqCst);
        if since.is_none() && passed >= after {
            *since = Some(Instant::now());
            self.lost();
        }
        since.is_some_and(|at| self.rules.silence_for.is_none_or(|length| at.elapsed() < length))
    }

    fn wait_while_dark(&self, to_listener: bool) {
        while self.dark(to_listener) {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

struct Direction {
    flip: Option<u64>,
    cut: Option<u64>,
    to_listener: bool,
}

const SEGMENT: f64 = 1448.0;

/// A Reno-like congestion window for one direction (see the module's note).
struct Window {
    loss: f64,
    round_trip: Duration,
    window: f64,
    threshold: f64,
    seed: u64,
}

impl Window {
    fn new(rules: &Tamper, to_listener: bool) -> Option<Self> {
        if rules.loss_per_million == 0 {
            return None;
        }
        let round_trip = (rules.one_way_delay.unwrap_or_default() * 2).max(Duration::from_millis(1));
        let seed = 0x9e37_79b9_7f4a_7c15 ^ u64::from(to_listener);
        Some(Self {
            loss: rules.loss_per_million as f64 / 1e6,
            round_trip,
            window: 10.0 * SEGMENT,
            threshold: f64::MAX,
            seed,
        })
    }

    fn random(&mut self) -> f64 {
        // xorshift64*: the same losses on every run.
        self.seed ^= self.seed >> 12;
        self.seed ^= self.seed << 25;
        self.seed ^= self.seed >> 27;
        (self.seed.wrapping_mul(0x2545_f491_4f6c_dd1d) >> 11) as f64 / (1u64 << 53) as f64
    }

    /// Passes `bytes`: returns how long they take at the window's rate, plus a round trip for each loss among them.
    fn pass(&mut self, bytes: usize) -> Duration {
        let segments = (bytes as f64 / SEGMENT).ceil() as u64;
        let mut stall = Duration::ZERO;
        for _ in 0..segments {
            if self.random() < self.loss {
                self.threshold = (self.window / 2.0).max(2.0 * SEGMENT);
                self.window = self.threshold;
                stall += self.round_trip;
            } else if self.window < self.threshold {
                self.window += SEGMENT;
            } else {
                self.window += SEGMENT * SEGMENT / self.window;
            }
        }
        self.window = self.window.min(64.0 * 1024.0 * 1024.0);
        let paced = Duration::from_secs_f64(bytes as f64 * self.round_trip.as_secs_f64() / self.window);
        paced + stall
    }
}

fn forward(mut from: TcpStream, to: TcpStream, rules: Direction, counter: Arc<AtomicU64>, route: &Arc<Route>) {
    let tamper = route.rules;
    let rate = tamper.bytes_per_second;
    let delay = tamper.one_way_delay.unwrap_or_default();
    let mut window = Window::new(&tamper, rules.to_listener);
    let mut buffer = vec![0u8; if rate.is_some() { 16_384 } else { 65_536 }];
    let mut passed = 0u64;
    // When the link is free for the next byte (rate and window), and the delivery line for delayed bytes.
    let mut next_free = Instant::now();
    let delayed = !delay.is_zero() || window.is_some() || tamper.silence_after.is_some() || tamper.flap.is_some();
    let mut writer = Some(to);
    let line = delayed.then(|| {
        let (tx, rx) = mpsc::sync_channel::<(Instant, Vec<u8>)>(1024);
        let mut to = writer.take().expect("one writer");
        let route = route.clone();
        let to_listener = rules.to_listener;
        std::thread::spawn(move || {
            for (due, bytes) in rx {
                if let Some(wait) = due.checked_duration_since(Instant::now()) {
                    std::thread::sleep(wait);
                }
                route.wait_while_dark(to_listener);
                if to.write_all(&bytes).is_err() {
                    return;
                }
            }
            let _ = to.shutdown(Shutdown::Write);
        });
        tx
    });
    loop {
        route.wait_while_dark(rules.to_listener);
        if let Some(wait) = next_free.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
        let n = match from.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let mut piece = &mut buffer[..n];
        if let Some(index) = rules.flip.filter(|i| *i >= passed && *i < passed + n as u64) {
            piece[(index - passed) as usize] ^= 0x01;
        }
        let mut cut_now = false;
        if let Some(limit) = rules.cut {
            if passed + n as u64 >= limit {
                piece = &mut piece[..(limit - passed) as usize];
                cut_now = true;
            }
        }
        let now = Instant::now();
        let mut busy = rate.map_or(Duration::ZERO, |r| Duration::from_secs_f64(piece.len() as f64 / r as f64));
        if let Some(window) = window.as_mut() {
            busy = busy.max(window.pass(piece.len()));
        }
        next_free = next_free.max(now) + busy;
        let sent = match (&line, writer.as_mut()) {
            (Some(line), _) => line.send((next_free + delay, piece.to_vec())).is_ok(),
            (None, Some(to)) => to.write_all(piece).is_ok(),
            (None, None) => false,
        };
        passed += piece.len() as u64;
        counter.fetch_add(piece.len() as u64, Ordering::SeqCst);
        if cut_now {
            route.cut();
            return;
        }
        if !sent {
            break;
        }
    }
    if let Some(to) = writer {
        let _ = to.shutdown(Shutdown::Write);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The loss model gives about TCP's throughput under loss: within a third of Mathis's estimate at 150 ms and 1 %.
    #[test]
    fn loss_model_follows_tcp() {
        let rules =
            Tamper { one_way_delay: Some(Duration::from_millis(75)), loss_per_million: 10_000, ..Tamper::default() };
        let mut window = Window::new(&rules, true).expect("a window under loss");
        let bytes = 64 << 20;
        let seconds: f64 = (0..bytes / 16_384).map(|_| window.pass(16_384).as_secs_f64()).sum();
        let mathis = SEGMENT / 0.150 * 1.22 / 0.01f64.sqrt();
        let rate = bytes as f64 / seconds;
        assert!((rate / mathis - 1.0).abs() < 0.34, "{rate:.0} B/s against {mathis:.0}");
        assert!(Window::new(&Tamper::default(), true).is_none(), "no window without loss");
    }
}
