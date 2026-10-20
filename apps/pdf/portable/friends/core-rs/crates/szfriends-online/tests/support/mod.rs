//! Two online drivers in one process, friends of each other, their sids passed in memory as the host forwards them,
//! and a STUN responder on two loopback ports: everything stays on 127.0.0.1.

#![allow(dead_code)]

use std::collections::{HashMap, VecDeque};
use std::net::{SocketAddr, UdpSocket};
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use std::time::{Duration, Instant};

use szfriends_identity::Identity;
use szfriends_online::driver::{Driver, DriverEvent, Friends, Input, OnlineFriend, SignalHost};
use szfriends_online::nat::stun;
use szfriends_online::transport::{ChannelStream, Route, TransportConfig};
use szfriends_wire::route::RouteMethod;

pub fn identity(n: u8) -> Identity {
    let mut seed = [n; 32];
    seed[31] = 0x5a;
    Identity::from_secrets(&seed, &[n.wrapping_mul(3).wrapping_add(1); 32])
}

/// A STUN Binding responder on one loopback port.
pub fn stun_responder() -> SocketAddr {
    let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let address = socket.local_addr().unwrap();
    std::thread::spawn(move || {
        let mut buffer = [0u8; 600];
        while let Ok((n, from)) = socket.recv_from(&mut buffer) {
            if let Some(m) = stun::parse(&buffer[..n]).filter(|m| m.kind == stun::BINDING_REQUEST) {
                let _ = socket.send_to(&stun::binding_success(&m.transaction, from, None), from);
            }
        }
    });
    address
}

struct OneFriend(OnlineFriend);

impl Friends for OneFriend {
    fn friend(&self, key: &[u8; 32]) -> Option<OnlineFriend> {
        (self.0.identity_key == *key).then(|| self.0.clone())
    }

    fn nearby_route(&self, _: &[u8; 32]) -> RouteMethod {
        RouteMethod::None
    }

    fn own_presence_secret(&self) -> Option<[u8; 32]> {
        None
    }
}

/// What one side asked of the host, to be delivered to the other.
#[derive(Debug)]
enum Wire {
    Open { attempt: u64, payload: Vec<u8> },
    Message { sid: String, payload: Vec<u8> },
    Close { sid: String },
    Relay { attempt: u64 },
}

#[derive(Default)]
struct Host {
    queue: VecDeque<Wire>,
    sent: HashMap<String, usize>,
}

impl SignalHost for Host {
    fn open(&mut self, attempt: u64, _rdv_key: [u8; 32], payload: Vec<u8>) {
        self.queue.push_back(Wire::Open { attempt, payload });
    }

    fn send(&mut self, sid: &str, payload: &[u8]) -> bool {
        let sent = self.sent.entry(sid.to_owned()).or_default();
        if *sent >= 64 {
            return false;
        }
        *sent += 1;
        self.queue.push_back(Wire::Message { sid: sid.to_owned(), payload: payload.to_vec() });
        true
    }

    fn close(&mut self, sid: &str) {
        self.queue.push_back(Wire::Close { sid: sid.to_owned() });
    }

    fn request_relay(&mut self, attempt: u64, _sid: &str) {
        self.queue.push_back(Wire::Relay { attempt });
    }
}

pub struct Side {
    pub driver: Driver,
    inbox: Receiver<Input>,
    host: Host,
    pub key: [u8; 32],
    pub streams: Vec<(ChannelStream, Route, bool)>,
}

pub struct Pair {
    pub sides: [Side; 2],
    next_sid: u32,
    /// A side that is away: the host gives opens toward it a sid and delivers them to nobody.
    pub away: [bool; 2],
}

impl Pair {
    pub fn new(stun: Option<(SocketAddr, SocketAddr)>) -> Self {
        let ids = [identity(1), identity(2)];
        let keys = [ids[0].public_key(), ids[1].public_key()];
        let friend = |i: usize| OnlineFriend {
            identity_key: ids[i].public_key(),
            static_key: ids[i].static_public_key(),
            presence_secret: None,
            request_token: None,
            root_key: None,
        };
        let friends = [friend(1), friend(0)];
        let mut sides = Vec::new();
        for (i, identity) in ids.into_iter().enumerate() {
            let (sender, inbox) = channel();
            let friends = Box::new(OneFriend(friends[i].clone()));
            let sink = std::sync::Mutex::new(sender);
            let sink: szfriends_online::driver::Sink = Arc::new(move |input| {
                let _ = sink.lock().unwrap().send(input);
            });
            let mut driver = Driver::new(Arc::new(identity), TransportConfig::loopback(), true, friends, sink);
            if let Some((primary, secondary)) = stun {
                driver.context.stun_primary = Some(primary);
                driver.context.stun_secondary = Some(secondary);
            }
            sides.push(Side { driver, inbox, host: Host::default(), key: keys[i], streams: Vec::new() });
        }
        let sides: [Side; 2] = sides.try_into().map_err(|_| ()).expect("two");
        Self { sides, next_sid: 1, away: [false; 2] }
    }

    pub fn reach(&mut self, from: usize) {
        let key = self.sides[1 - from].key;
        let side = &mut self.sides[from];
        side.driver.reach_friend(&key, &mut side.host);
    }

    /// Runs both drivers until `done` or the deadline.
    pub fn run_until(&mut self, limit: Duration, mut done: impl FnMut(&mut Pair) -> bool) -> bool {
        let deadline = Instant::now() + limit;
        while Instant::now() < deadline {
            if done(self) {
                return true;
            }
            for i in 0..2 {
                let side = &mut self.sides[i];
                while let Ok(input) = side.inbox.try_recv() {
                    side.driver.input(input, &mut side.host);
                }
                side.driver.tick(&mut side.host);
                for event in side.driver.take_events() {
                    if let DriverEvent::Stream { stream, route, initiator, .. } = event {
                        side.streams.push((stream, route, initiator));
                    }
                }
                self.deliver(i);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        done(self)
    }

    fn deliver(&mut self, from: usize) {
        let to = 1 - from;
        while let Some(wire) = self.sides[from].host.queue.pop_front() {
            match wire {
                Wire::Open { attempt, payload } => {
                    let sid = format!("sid{}", self.next_sid);
                    self.next_sid += 1;
                    let sender = &mut self.sides[from];
                    sender.driver.sid_opened(attempt, Some(sid.clone()), &mut sender.host);
                    if self.away[to] {
                        continue;
                    }
                    let target = &mut self.sides[to];
                    target.driver.incoming(sid, &payload, &mut target.host);
                }
                Wire::Message { sid, payload } => {
                    let target = &mut self.sides[to];
                    target.driver.sid_payload(&sid, &payload, &mut target.host);
                }
                Wire::Close { sid } => {
                    let target = &mut self.sides[to];
                    target.driver.sid_ended(&sid, &mut target.host);
                }
                Wire::Relay { attempt } => {
                    let sender = &mut self.sides[from];
                    sender.driver.relay_credentials(attempt, None, &mut sender.host);
                }
            }
        }
    }
}
