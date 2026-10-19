//! A data-channel peer on 127.0.0.1 for the tests: it turns the stack's events into signalling for the other side,
//! keeps its channel, and (as an answerer) echoes every message. Nothing leaves the loopback interface: each peer
//! binds to 127.0.0.1, no STUN or TURN server is configured, and only loopback candidates are signalled. libjuice
//! does not always gather a loopback address itself, so each peer also signals its own fixed 127.0.0.1 port, as
//! portable/friends/deps/tests/SZFriendsDataChannelLinkTest.c does.

#![allow(dead_code)]

use std::net::UdpSocket;
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use szfriends_datachannel_sys::{sdp_mid, Config, DataChannel, Event, PeerConnection, State};

pub const LABEL: &str = "szfriends";
pub const TIMEOUT: Duration = Duration::from_secs(20);

/// What one side sends the other through signalling.
#[derive(Debug, Clone)]
pub enum Signal {
    Description { sdp: String, kind: String },
    Candidate { candidate: String, mid: Option<String> },
}

/// A free UDP port on 127.0.0.1 for a peer's fixed port range.
pub fn free_loopback_port() -> u16 {
    let socket = UdpSocket::bind("127.0.0.1:0").expect("a loopback UDP socket");
    socket.local_addr().expect("its address").port()
}

pub fn loopback_candidate(port: u16) -> String {
    format!("candidate:1 1 UDP 2130706431 127.0.0.1 {port} typ host")
}

#[derive(Debug)]
pub struct Peer {
    pub name: &'static str,
    pub pc: PeerConnection,
    events: Receiver<Event>,
    pub port: u16,
    pub echo: bool,
    pub channel: Option<DataChannel>,
    pub open: bool,
    pub closed: bool,
    pub received: Vec<u8>,
    pub messages: usize,
    pub local_sdp: Option<String>,
    pub failure: Option<String>,
}

impl Peer {
    pub fn new(name: &'static str, echo: bool) -> Peer {
        let port = free_loopback_port();
        let config =
            Config { bind_address: Some("127.0.0.1".into()), port_range: Some((port, port)), ..Config::default() };
        let (pc, events) = PeerConnection::new(&config).expect("a peer connection");
        Peer {
            name,
            pc,
            events,
            port,
            echo,
            channel: None,
            open: false,
            closed: false,
            received: Vec::new(),
            messages: 0,
            local_sdp: None,
            failure: None,
        }
    }

    /// The offerer's side: creating the channel creates the offer.
    pub fn open_channel(&mut self) {
        let channel = self.pc.create_data_channel(LABEL).expect("a data channel");
        assert!(channel.is_reliable_and_ordered());
        self.channel = Some(channel);
    }

    /// Handles every pending event; returns what to signal to the other side.
    pub fn pump(&mut self, wait: Duration) -> Vec<Signal> {
        let mut out = Vec::new();
        let mut next = self.events.recv_timeout(wait).ok();
        while let Some(event) = next {
            self.handle(event, &mut out);
            next = self.events.try_recv().ok();
        }
        out
    }

    fn handle(&mut self, event: Event, out: &mut Vec<Signal>) {
        match event {
            Event::LocalDescription { sdp, kind } => {
                let mid = sdp_mid(&sdp);
                self.local_sdp = Some(sdp.clone());
                out.push(Signal::Description { sdp, kind });
                out.push(Signal::Candidate { candidate: loopback_candidate(self.port), mid });
            }
            Event::LocalCandidate { candidate, mid } => {
                // Gathered loopback candidates trickle too; anything else would leave the machine.
                if candidate.contains(" 127.0.0.1 ") {
                    out.push(Signal::Candidate { candidate, mid: Some(mid) });
                }
            }
            Event::DataChannel(channel) => {
                if !channel.is_reliable_and_ordered() {
                    self.failure = Some("the remote channel is not reliable and ordered".into());
                }
                self.channel = Some(channel);
                self.open = true;
            }
            Event::ChannelOpen(_) => self.open = true,
            Event::Message { data, text, .. } => {
                if text {
                    self.failure = Some("a text message".into());
                }
                self.messages += 1;
                if self.echo {
                    let channel = self.channel.as_ref().expect("a message arrives on a channel");
                    if let Err(error) = channel.send(&data) {
                        self.failure = Some(format!("echo: {error}"));
                    }
                } else {
                    self.received.extend_from_slice(&data);
                }
            }
            Event::ChannelError { error, .. } => self.failure = Some(format!("channel error: {error}")),
            Event::StateChanged(State::Failed) => self.failure = Some("the peer connection failed".into()),
            Event::ChannelClosed(_) => self.closed = true,
            Event::StateChanged(_) | Event::GatheringComplete => {}
        }
    }

    /// Drops the receiver of this side's events: from now on the stack's events find nobody listening.
    pub fn stop_listening(&mut self) {
        self.events = std::sync::mpsc::channel().1;
    }

    pub fn apply(&mut self, signal: Signal) {
        let result = match signal {
            Signal::Description { sdp, kind } => self.pc.set_remote_description(&sdp, &kind),
            Signal::Candidate { candidate, mid } => self.pc.add_remote_candidate(&candidate, mid.as_deref()),
        };
        if let Err(error) = result {
            self.failure = Some(format!("{}: applying a signal: {error}", self.name));
        }
    }
}

/// Pumps two in-process peers, forwarding signalling both ways, until `done` holds or a peer fails. Err on timeout.
pub fn pump_pair(a: &mut Peer, b: &mut Peer, done: impl Fn(&Peer, &Peer) -> bool) -> Result<(), String> {
    let deadline = Instant::now() + TIMEOUT;
    while !done(a, b) {
        for signal in a.pump(Duration::from_millis(5)) {
            b.apply(signal);
        }
        for signal in b.pump(Duration::from_millis(5)) {
            a.apply(signal);
        }
        if let Some(failure) = a.failure.clone().or_else(|| b.failure.clone()) {
            return Err(failure);
        }
        if Instant::now() > deadline {
            return Err(format!("timed out (open {} / {})", a.open, b.open));
        }
    }
    Ok(())
}

/// Deterministic test bytes: a counter through a xorshift, so a reordered or dropped message shows.
pub fn pattern(length: usize, seed: u32) -> Vec<u8> {
    let mut state = seed | 1;
    (0..length)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as u8
        })
        .collect()
}
