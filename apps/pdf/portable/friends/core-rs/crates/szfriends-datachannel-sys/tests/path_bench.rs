//! A data channel over an emulated Internet path (ADR 0018 § 9.9, WP3): two peers in this process on 127.0.0.1, with
//! every UDP packet between them passing a shaper that adds a one-way delay, drops a share of packets at random, and
//! holds the rate to a bottleneck with a drop-tail queue. It measures what one channel carries with the stack's
//! defaults (1 MiB of SCTP buffers, 1 MiB buffered in the channel) against 8 MiB of each, and with H-TCP.
//!
//!   cargo test --release -p szfriends-datachannel-sys --test path_bench -- --ignored --nocapture
//!   PATH_BENCH_CASES=rtt80,rtt300-loss1 PATH_BENCH_MIB=64 to narrow it. One JSON line per run.

mod support;

use std::collections::{HashMap, VecDeque};
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use support::{loopback_candidate, Peer, Signal};
use szfriends_datachannel_sys::{set_sctp_settings, SctpSettings, MESSAGE_MAX};

#[derive(Clone, Copy, Debug)]
struct Path {
    name: &'static str,
    one_way: Duration,
    loss: f64,
    bytes_per_second: f64,
}

/// One direction of the shaper: packets leave in order, each after the one-way delay and its turn at the bottleneck.
struct Lane {
    queue: VecDeque<(Instant, Vec<u8>, SocketAddr, Arc<UdpSocket>)>,
    free_at: Instant,
    queued_bytes: usize,
}

/// A UDP shaper in front of `target`: what reaches its port goes on to `target` from a socket per source, and what
/// `target` answers goes back the same way, both directions delayed, thinned and rate-limited.
struct Shaper {
    port: u16,
    stop: Arc<AtomicBool>,
}

impl Shaper {
    fn start(target: SocketAddr, path: Path, seed: u64) -> Self {
        let front = Arc::new(UdpSocket::bind("127.0.0.1:0").unwrap());
        front.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
        let port = front.local_addr().unwrap().port();
        let stop = Arc::new(AtomicBool::new(false));
        let lanes = Arc::new(Mutex::new([Lane::new(), Lane::new()]));
        let rng = Arc::new(Mutex::new(seed | 1));
        // The pacer: sends what is due.
        {
            let (lanes, stop) = (lanes.clone(), stop.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    let now = Instant::now();
                    let mut due = Vec::new();
                    for lane in lanes.lock().unwrap().iter_mut() {
                        while lane.queue.front().is_some_and(|(at, ..)| *at <= now) {
                            let (_, bytes, to, socket) = lane.queue.pop_front().unwrap();
                            lane.queued_bytes -= bytes.len();
                            due.push((bytes, to, socket));
                        }
                    }
                    for (bytes, to, socket) in due {
                        let _ = socket.send_to(&bytes, to);
                    }
                    std::thread::sleep(Duration::from_micros(200));
                }
            });
        }
        let enqueue = move |lanes: &Mutex<[Lane; 2]>,
                            rng: &Mutex<u64>,
                            direction: usize,
                            bytes: Vec<u8>,
                            to: SocketAddr,
                            socket: Arc<UdpSocket>| {
            let mut state = rng.lock().unwrap();
            *state ^= *state << 13;
            *state ^= *state >> 7;
            *state ^= *state << 17;
            if (*state % 1_000_000) as f64 / 1e6 < path.loss {
                return;
            }
            drop(state);
            let mut lanes = lanes.lock().unwrap();
            let lane = &mut lanes[direction];
            // Drop-tail at about 100 ms of the bottleneck, as a home router's queue.
            if lane.queued_bytes as f64 > path.bytes_per_second * 0.1 {
                return;
            }
            let now = Instant::now();
            lane.free_at = lane.free_at.max(now) + Duration::from_secs_f64(bytes.len() as f64 / path.bytes_per_second);
            let at = lane.free_at + path.one_way;
            lane.queued_bytes += bytes.len();
            lane.queue.push_back((at, bytes, to, socket));
        };
        {
            let (front, stop, lanes, rng) = (front.clone(), stop.clone(), lanes.clone(), rng.clone());
            std::thread::spawn(move || {
                let mut back: HashMap<SocketAddr, Arc<UdpSocket>> = HashMap::new();
                let mut buffer = vec![0u8; 65_536];
                while !stop.load(Ordering::Relaxed) {
                    let Ok((n, from)) = front.recv_from(&mut buffer) else { continue };
                    let upstream = back.entry(from).or_insert_with(|| {
                        let socket = Arc::new(UdpSocket::bind("127.0.0.1:0").unwrap());
                        socket.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
                        let (socket2, front2, lanes2, rng2, stop2) =
                            (socket.clone(), front.clone(), lanes.clone(), rng.clone(), stop.clone());
                        std::thread::spawn(move || {
                            let mut buffer = vec![0u8; 65_536];
                            while !stop2.load(Ordering::Relaxed) {
                                if let Ok((n, _)) = socket2.recv_from(&mut buffer) {
                                    enqueue(&lanes2, &rng2, 1, buffer[..n].to_vec(), from, front2.clone());
                                }
                            }
                        });
                        socket
                    });
                    enqueue(&lanes, &rng, 0, buffer[..n].to_vec(), target, upstream.clone());
                }
            });
        }
        Self { port, stop }
    }
}

impl Lane {
    fn new() -> Self {
        Self { queue: VecDeque::new(), free_at: Instant::now(), queued_bytes: 0 }
    }
}

impl Drop for Shaper {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// One round of signals between the two peers, each side's candidates replaced by its shaper's port.
fn pump_once(offerer: &mut Peer, answerer: &mut Peer, shapers: &(Shaper, Shaper)) {
    let rewrite = |signal: Signal, shaper: &Shaper| match signal {
        Signal::Candidate { candidate, mid } if candidate.contains(" 127.0.0.1 ") => {
            Some(Signal::Candidate { candidate: loopback_candidate(shaper.port), mid })
        }
        Signal::Candidate { .. } => None,
        other => Some(other),
    };
    for signal in offerer.pump(Duration::from_millis(1)) {
        if let Some(signal) = rewrite(signal, &shapers.0) {
            answerer.apply(signal);
        }
    }
    for signal in answerer.pump(Duration::from_millis(1)) {
        if let Some(signal) = rewrite(signal, &shapers.1) {
            offerer.apply(signal);
        }
    }
}

fn run(path: Path, mib: usize, buffers: u32, high_water: usize, cc: u8) -> String {
    set_sctp_settings(SctpSettings {
        receive_buffer: Some(buffers),
        send_buffer: Some(buffers),
        congestion_control: Some(cc),
    });
    let mut offerer = Peer::new("offerer", false);
    let mut answerer = Peer::new("answerer", false);
    let shapers = (
        Shaper::start(format!("127.0.0.1:{}", offerer.port).parse().unwrap(), path, 0x9e37_79b9),
        Shaper::start(format!("127.0.0.1:{}", answerer.port).parse().unwrap(), path, 0x85eb_ca6b),
    );
    offerer.open_channel();
    let deadline = Instant::now() + Duration::from_secs(60);
    while !(offerer.open && answerer.open) && Instant::now() < deadline {
        pump_once(&mut offerer, &mut answerer, &shapers);
    }
    assert!(offerer.open && answerer.open, "the channel opens through the shapers");
    let total = mib << 20;
    let message = vec![7u8; MESSAGE_MAX];
    let started = Instant::now();
    let mut sent = 0;
    while answerer.received.len() < total && started.elapsed() < Duration::from_secs(600) {
        let channel = offerer.channel.as_ref().expect("open");
        while sent < total && channel.buffered_amount() <= high_water {
            let n = MESSAGE_MAX.min(total - sent);
            channel.send(&message[..n]).expect("send");
            sent += n;
        }
        pump_once(&mut offerer, &mut answerer, &shapers);
    }
    let seconds = started.elapsed().as_secs_f64();
    let rate = answerer.received.len() as f64 / seconds;
    format!(
        "{{\"path\":\"{}\",\"rtt_ms\":{},\"loss\":{},\"bottleneck_mb_s\":{:.2},\"mib\":{mib},\"sctp_buffers\":{buffers},\
\"high_water\":{high_water},\"cc\":{cc},\"seconds\":{seconds:.2},\"mb_s\":{:.2},\"share\":{:.2}}}",
        path.name,
        path.one_way.as_millis() * 2,
        path.loss,
        path.bytes_per_second / 1e6,
        rate / 1e6,
        rate / path.bytes_per_second
    )
}

#[test]
#[ignore = "a bench: minutes on emulated paths"]
fn data_channel_over_delayed_and_lossy_paths() {
    let ms = Duration::from_millis;
    let paths = [
        Path { name: "rtt80", one_way: ms(40), loss: 0.0, bytes_per_second: 12.5e6 },
        Path { name: "rtt80-loss1", one_way: ms(40), loss: 0.01, bytes_per_second: 12.5e6 },
        Path { name: "rtt300", one_way: ms(150), loss: 0.0, bytes_per_second: 12.5e6 },
        Path { name: "rtt300-loss1", one_way: ms(150), loss: 0.01, bytes_per_second: 12.5e6 },
    ];
    let wanted = std::env::var("PATH_BENCH_CASES").unwrap_or_default();
    let mib: usize = std::env::var("PATH_BENCH_MIB").ok().and_then(|v| v.parse().ok()).unwrap_or(48);
    for path in paths {
        if !wanted.is_empty() && !wanted.split(',').any(|w| w == path.name) {
            continue;
        }
        for (buffers, high_water, cc) in [(1 << 20, 1 << 20, 0), (8 << 20, 8 << 20, 0), (8 << 20, 8 << 20, 2)] {
            println!("{}", run(path, mib, buffers, high_water, cc));
        }
    }
}
