//! Two channels joined by an in-memory link with a manual clock, for the session suites. Delivery is immediate and in
//! order; every write completes as soon as it is delivered. An optional tamper flips one byte of one direction.

#![allow(dead_code)]

use std::sync::Arc;
use std::time::Duration;

use szfriends_core::identity::Identity;
use szfriends_core::session::{
    ChannelIdentity, Event, HandshakeOptions, RemoteKeyPolicy, ReplayCache, SecureChannel, SessionError,
};
use szfriends_core::wire::{tag, Fields, Frame, FrameType, Pattern, RouteMethod};

pub fn label_bytes<const N: usize>(label: &str) -> [u8; N] {
    szfriends_core::crypto::blake2b::<N>(None, &[label.as_bytes()])
}

pub fn identity(name: &str) -> Identity {
    let mut private = label_bytes::<32>(&format!("{name} static"));
    private[0] &= 248;
    private[31] = (private[31] & 127) | 64;
    Identity::from_secrets(&label_bytes::<32>(&format!("{name} seed")), &private)
}

pub fn keys(identity: &Identity) -> ChannelIdentity {
    ChannelIdentity::new(identity)
}

pub fn allow_all() -> RemoteKeyPolicy {
    Box::new(|_, _, _| true)
}

pub fn profile(name: &str) -> Fields {
    let mut fields = Fields::new();
    fields.insert(tag::NAME, name.as_bytes().to_vec());
    fields
}

pub fn message(text: &str, id: u8) -> Frame {
    Frame::new(FrameType::Message)
        .with(tag::ID, [id; 16])
        .with(tag::SENT_AT, 1_791_787_668_000u64.to_be_bytes())
        .with(tag::TEXT, text.as_bytes())
}

pub fn options(pattern: Pattern) -> HandshakeOptions {
    HandshakeOptions::new(pattern, RouteMethod::Lan)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Initiator,
    Responder,
}

pub struct Pipe {
    pub initiator: SecureChannel,
    pub responder: SecureChannel,
    pub now: Duration,
    /// Every byte each side handed to the link, in order.
    pub sent_by_initiator: Vec<u8>,
    pub sent_by_responder: Vec<u8>,
    pub initiator_events: Vec<Event>,
    pub responder_events: Vec<Event>,
    /// (direction, byte index within that direction, xor mask).
    pub tamper: Option<(Side, usize, u8)>,
    initiator_link_closed: bool,
    responder_link_closed: bool,
}

impl Pipe {
    /// Starts both sides at t = 1000 s, each responder with its own replay cache unless one is set later.
    pub fn new(initiator: SecureChannel, responder: SecureChannel) -> Self {
        Self::with_tamper(initiator, responder, None)
    }

    /// The same with one byte of one direction flipped: (direction, index within it, xor mask).
    pub fn with_tamper(
        mut initiator: SecureChannel,
        mut responder: SecureChannel,
        tamper: Option<(Side, usize, u8)>,
    ) -> Self {
        responder.set_replay_cache(Arc::new(ReplayCache::new(64, None)));
        let now = Duration::from_secs(1000);
        initiator.start(now);
        responder.start(now);
        let mut pipe = Self {
            initiator,
            responder,
            now,
            sent_by_initiator: Vec::new(),
            sent_by_responder: Vec::new(),
            initiator_events: Vec::new(),
            responder_events: Vec::new(),
            tamper,
            initiator_link_closed: false,
            responder_link_closed: false,
        };
        pipe.run();
        pipe
    }

    /// Moves bytes both ways until neither side has anything left to say.
    pub fn run(&mut self) {
        loop {
            let mut moved = false;
            while let Some(write) = self.initiator.poll_transmit() {
                let mut bytes = write.bytes;
                Self::apply_tamper(self.tamper, Side::Initiator, self.sent_by_initiator.len(), &mut bytes);
                self.sent_by_initiator.extend_from_slice(&bytes);
                self.responder.receive(&bytes, self.now);
                self.initiator.write_completed(self.now);
                moved = true;
            }
            while let Some(write) = self.responder.poll_transmit() {
                let mut bytes = write.bytes;
                Self::apply_tamper(self.tamper, Side::Responder, self.sent_by_responder.len(), &mut bytes);
                self.sent_by_responder.extend_from_slice(&bytes);
                self.initiator.receive(&bytes, self.now);
                self.responder.write_completed(self.now);
                moved = true;
            }
            if self.initiator.link_should_close() && !self.initiator_link_closed {
                self.initiator_link_closed = true;
                self.responder.link_closed_by_peer();
                moved = true;
            }
            if self.responder.link_should_close() && !self.responder_link_closed {
                self.responder_link_closed = true;
                self.initiator.link_closed_by_peer();
                moved = true;
            }
            while let Some(event) = self.initiator.poll_event() {
                self.initiator_events.push(event);
                moved = true;
            }
            while let Some(event) = self.responder.poll_event() {
                self.responder_events.push(event);
                moved = true;
            }
            if !moved {
                return;
            }
        }
    }

    fn apply_tamper(tamper: Option<(Side, usize, u8)>, side: Side, before: usize, bytes: &mut [u8]) {
        if let Some((direction, index, mask)) = tamper {
            if direction == side && index >= before && index < before + bytes.len() {
                bytes[index - before] ^= mask;
            }
        }
    }

    /// Lets time pass and runs every timer that came due.
    pub fn advance(&mut self, by: Duration) {
        self.now += by;
        self.initiator.handle_timeout(self.now);
        self.responder.handle_timeout(self.now);
        self.run();
    }

    pub fn send(&mut self, side: Side, frame: &Frame) -> bool {
        let now = self.now;
        let sent = match side {
            Side::Initiator => self.initiator.send_frame(frame, now),
            Side::Responder => self.responder.send_frame(frame, now),
        };
        self.run();
        sent
    }

    pub fn frames(events: &[Event]) -> Vec<Frame> {
        events.iter().filter_map(|e| if let Event::Frame(f) = e { Some(f.clone()) } else { None }).collect()
    }

    pub fn closed(events: &[Event]) -> Option<Option<SessionError>> {
        events.iter().find_map(|e| if let Event::Closed(error) = e { Some(*error) } else { None })
    }

    pub fn established(events: &[Event]) -> bool {
        events.contains(&Event::Established)
    }

    pub fn codes(events: &[Event]) -> Vec<Result<String, SessionError>> {
        events.iter().filter_map(|e| if let Event::Code(code) = e { Some(code.clone()) } else { None }).collect()
    }
}

/// An XX pair: Bob's public listener and Alice dialing it, continuing after his profile.
pub fn xx_pair() -> Pipe {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut initiator = SecureChannel::initiator(keys(&alice), options(Pattern::XX));
    initiator.set_profile_decision(Box::new(|profile| profile.get(&tag::NAME).is_some()));
    let responder = SecureChannel::responder(keys(&bob), Some(profile("Bob")), allow_all());
    Pipe::new(initiator, responder)
}

/// An IK pair: Alice dialing Bob, who knows her.
pub fn ik_pair() -> Pipe {
    let (alice, bob) = (identity("alice"), identity("bob"));
    let mut options = options(Pattern::IK);
    options.remote_static = Some(bob.static_public_key());
    options.expected_identity = Some(bob.public_key());
    let alice_key = alice.public_key();
    let initiator = SecureChannel::initiator(keys(&alice), options);
    let policy: RemoteKeyPolicy = Box::new(move |key, _, _| key == Some(&alice_key));
    let responder = SecureChannel::responder(keys(&bob), None, policy);
    Pipe::new(initiator, responder)
}
