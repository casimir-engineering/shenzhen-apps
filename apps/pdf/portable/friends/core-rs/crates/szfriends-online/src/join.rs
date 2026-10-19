//! Joining a profile through the Friends host (`SZFriendsOnlineDriver+Join.m`, `SZFriendsNearbyService+JoinOnline.m`;
//! ADR 0013, PROTOCOL.md § Joining). Protocol 3's `to.join` hands an open to every connected device of the Friends
//! ID's holder, and the host keeps nothing:
//!
//! ```text
//! new computer                       host                          the person's computers
//! sig_open to.join, 'J' 1 + Request ---------------------> every device takes the request; nobody answers
//! sig_open to.join, 'J' 2 + NN message 1 ----------------> the device holding an approval answers NN message 2;
//!                                                          the others stay silent, which is nobody to the caller
//! ```
//!
//! After message 2 every JOIN message travels sealed in that NN session, at most three to a payload, through a pipe
//! the helper drives exactly as a nearby session (its join messages, approvals and attempts are the same).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use szfriends_wire::frame::Frame;
use szfriends_wire::types::{FrameType, Pattern};

use crate::host::HostClient;
use crate::signal::items::{tag, Item, ItemType};
use crate::signal::{ReplayCache, SignalingSession};

pub const OPEN_PREFIX: u8 = b'J';
pub const OPEN_REQUEST: u8 = 1;
pub const OPEN_CODE: u8 = 2;
/// The host's own budget for join opens: 40 an hour, apart from Add by ID's 5.
const OPENS_PER_HOUR: usize = 40;
const OPEN_WINDOW: f64 = 3600.0;
const FRAMES_PER_PAYLOAD: usize = 3;
const REPLAY_CAPACITY: usize = 64;
/// A pipe silent this long is let go (a run's steps answer in seconds).
const PIPE_TIMEOUT: f64 = 60.0;
/// Open tokens of joining never meet the driver's, the links' or Add by ID's.
pub const OPEN_TOKENS: u64 = 1 << 53;
const JOIN_FIELD: u8 = szfriends_wire::tag::JOIN;
/// The numbers of pipes another computer opened, apart from the helper's own session numbers.
pub const INCOMING_PIPES: u64 = 1 << 62;

/// What joining's sids report to the helper.
#[derive(Debug, PartialEq, Eq)]
pub enum JoinEvent {
    /// Every device: a new computer's Request message (nobody answers it).
    Request(Vec<u8>),
    /// A pipe's NN session is established: the hash a code's run is bound to.
    Ready {
        pipe: u64,
        initiator: bool,
        handshake_hash: Vec<u8>,
    },
    /// JOIN messages that arrived on a pipe, in order.
    Messages {
        pipe: u64,
        messages: Vec<Vec<u8>>,
    },
    Ended(u64),
}

struct Pipe {
    session: SignalingSession,
    sid: Option<String>,
    initiator: bool,
    deadline: f64,
    /// Closes at this time (the last payloads leave the host first).
    closing_at: Option<f64>,
}

/// The pipes in flight, the request opens waiting for their sid, the hourly budget.
#[derive(Default)]
pub struct JoinPipes {
    pipes: HashMap<u64, Pipe>,
    requests: HashMap<u64, ()>,
    next_request: u64,
    next_incoming: u64,
    opens: Vec<f64>,
    replay: Option<ReplayCache>,
    /// Set by the helper while this device holds an approval: only then does it answer a code.
    pub holds_approval: Arc<AtomicBool>,
    events: Vec<JoinEvent>,
}

impl std::fmt::Debug for JoinPipes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("JoinPipes").field("pipes", &self.pipes.len()).finish()
    }
}

fn open_payload(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut payload = vec![OPEN_PREFIX, kind];
    payload.extend_from_slice(body);
    payload
}

impl JoinPipes {
    pub fn take_events(&mut self) -> Vec<JoinEvent> {
        std::mem::take(&mut self.events)
    }

    fn take_open(&mut self, now: f64) -> bool {
        self.opens.retain(|at| now - at < OPEN_WINDOW);
        if self.opens.len() >= OPENS_PER_HOUR {
            return false;
        }
        self.opens.push(now);
        true
    }

    /// The new computer's request, to every device of the profile; `false` when not sent.
    pub fn request(&mut self, host: &mut HostClient, friends_id: &str, message: &[u8], now: f64) -> bool {
        if !self.take_open(now) {
            return false;
        }
        let token = OPEN_TOKENS + (1 << 40) + self.next_request;
        self.next_request += 1;
        self.requests.insert(token, ());
        host.open_to_join(token, friends_id, &open_payload(OPEN_REQUEST, message));
        true
    }

    /// The new computer's code: NN message 1 on a pipe numbered `pipe` by the helper.
    pub fn code(&mut self, host: &mut HostClient, pipe: u64, friends_id: &str, now: f64) -> bool {
        let Some(mut session) = SignalingSession::nn_initiator() else { return false };
        let Ok(message) = session.opening_message(&[], now as u64) else { return false };
        if !self.take_open(now) {
            return false;
        }
        let deadline = now + PIPE_TIMEOUT;
        self.pipes.insert(pipe, Pipe { session, sid: None, initiator: true, deadline, closing_at: None });
        host.open_to_join(OPEN_TOKENS + (pipe & ((1 << 40) - 1)), friends_id, &open_payload(OPEN_CODE, &message));
        true
    }

    pub fn owns_token(token: u64) -> bool {
        (OPEN_TOKENS..OPEN_TOKENS + (1 << 41)).contains(&token)
    }

    pub fn owns_sid(&self, sid: &str) -> bool {
        self.pipes.values().any(|p| p.sid.as_deref() == Some(sid))
    }

    pub fn opened(&mut self, host: &mut HostClient, token: u64, sid: Option<String>) {
        if self.requests.remove(&token).is_some() {
            // Nobody answers a request: the open itself was the message.
            if let Some(sid) = sid {
                host.close_sid(&sid);
            }
            return;
        }
        let low = token - OPEN_TOKENS;
        let pipe =
            self.pipes.iter_mut().find(|(id, p)| p.sid.is_none() && p.initiator && (*id & ((1 << 40) - 1)) == low);
        match (pipe, sid) {
            (Some((_, pipe)), Some(sid)) => pipe.sid = Some(sid),
            (Some((&id, _)), None) => self.end(host, id),
            (None, Some(sid)) => host.close_sid(&sid),
            (None, None) => {}
        }
    }

    /// Every device: an open via `to.join`. A request is taken and nothing answered; a code is answered only while this
    /// device holds an approval, on a pipe numbered here (from [`INCOMING_PIPES`] up).
    pub fn incoming(
        &mut self,
        host: &mut HostClient,
        identity: &szfriends_identity::Identity,
        sid: String,
        payload: &[u8],
        now: f64,
    ) {
        let (kind, body) = match payload {
            [OPEN_PREFIX, kind, body @ ..] if !body.is_empty() => (*kind, body),
            _ => return host.close_sid(&sid),
        };
        if kind == OPEN_REQUEST {
            host.close_sid(&sid);
            return self.events.push(JoinEvent::Request(body.to_vec()));
        }
        if kind != OPEN_CODE || !self.holds_approval.load(Ordering::SeqCst) {
            return host.close_sid(&sid); // silence: to the caller, a device without an approval is nobody
        }
        let replay = self.replay.get_or_insert_with(|| ReplayCache::new(REPLAY_CAPACITY));
        let mut policy = |_: Option<&[u8; 32]>, pattern: Pattern, _: Option<&[u8]>| pattern == Pattern::NN;
        let answered = SignalingSession::responder(body, identity, &[Pattern::NN], replay, &mut policy, now)
            .ok()
            .and_then(|(mut session, _)| session.reply(&[]).ok().map(|reply| (session, reply)));
        let Some((session, reply)) = answered else { return host.close_sid(&sid) };
        if !host.send_payload(&sid, &reply) {
            return host.close_sid(&sid);
        }
        let handshake_hash = session.handshake_hash.map(|h| h.to_vec()).unwrap_or_default();
        let deadline = now + PIPE_TIMEOUT;
        let pipe = INCOMING_PIPES + self.next_incoming;
        self.next_incoming += 1;
        self.pipes.insert(pipe, Pipe { session, sid: Some(sid), initiator: false, deadline, closing_at: None });
        self.events.push(JoinEvent::Ready { pipe, initiator: false, handshake_hash });
    }

    pub fn payload(&mut self, host: &mut HostClient, sid: &str, payload: &[u8], now: f64) {
        let Some((&id, pipe)) = self.pipes.iter_mut().find(|(_, p)| p.sid.as_deref() == Some(sid)) else { return };
        pipe.deadline = now + PIPE_TIMEOUT;
        if pipe.initiator && !pipe.session.is_established() {
            // The approving device's message 2: the hash both now share is what the code's run is bound to.
            if pipe.session.read_reply(payload).is_err() {
                return self.end(host, id);
            }
            let handshake_hash = pipe.session.handshake_hash.map(|h| h.to_vec()).unwrap_or_default();
            return self.events.push(JoinEvent::Ready { pipe: id, initiator: true, handshake_hash });
        }
        let items = pipe.session.open(payload).ok();
        let messages: Option<Vec<Vec<u8>>> = items.map(|items| {
            items
                .iter()
                .filter(|i| i.kind == ItemType::Frame)
                .filter_map(|i| Frame::decode(i.data(tag::FRAME)?).ok())
                .filter(|f| f.frame_type == FrameType::Join)
                .filter_map(|f| f.get(JOIN_FIELD).map(<[u8]>::to_vec))
                .collect()
        });
        match messages.filter(|m| !m.is_empty()) {
            Some(messages) => self.events.push(JoinEvent::Messages { pipe: id, messages }),
            None => self.end(host, id),
        }
    }

    /// JOIN messages on a pipe, three to a payload. `false` once the pipe cannot carry them.
    pub fn send(&mut self, host: &mut HostClient, pipe: u64, messages: &[Vec<u8>]) -> bool {
        // A pipe about to close still carries what is sent before it does (a welcome goes after its linger is set).
        let Some(open) = self.pipes.get_mut(&pipe) else { return false };
        let Some(sid) = open.sid.clone() else { return false };
        for batch in messages.chunks(FRAMES_PER_PAYLOAD) {
            let items: Option<Vec<Item>> = batch
                .iter()
                .map(|m| Frame::new(FrameType::Join).with(JOIN_FIELD, m.clone()).encode().ok().map(Item::frame))
                .collect();
            let sealed = items.and_then(|items| open.session.seal(&items).ok());
            if !sealed.is_some_and(|sealed| host.send_payload(&sid, &sealed)) {
                self.end(host, pipe);
                return false;
            }
        }
        true
    }

    /// Ends a pipe after `linger` seconds, so what it sent last leaves the host first.
    pub fn close(&mut self, pipe: u64, linger: f64, now: f64) {
        if let Some(open) = self.pipes.get_mut(&pipe) {
            open.closing_at = Some(open.closing_at.unwrap_or(now + linger).min(now + linger));
        }
    }

    pub fn sid_ended(&mut self, host: &mut HostClient, sid: &str) {
        if let Some(id) = self.pipes.iter().find(|(_, p)| p.sid.as_deref() == Some(sid)).map(|(id, _)| *id) {
            self.end(host, id);
        }
    }

    fn end(&mut self, host: &mut HostClient, id: u64) {
        if let Some(pipe) = self.pipes.remove(&id) {
            if let Some(sid) = &pipe.sid {
                host.close_sid(sid);
            }
            self.events.push(JoinEvent::Ended(id));
        }
    }

    pub fn next_deadline(&self) -> f64 {
        self.pipes.values().map(|p| p.closing_at.unwrap_or(p.deadline).min(p.deadline)).fold(f64::INFINITY, f64::min)
    }

    pub fn tick(&mut self, host: &mut HostClient, now: f64) {
        let due: Vec<u64> = self
            .pipes
            .iter()
            .filter(|(_, p)| p.deadline <= now || p.closing_at.is_some_and(|at| at <= now))
            .map(|(id, _)| *id)
            .collect();
        for id in due {
            self.end(host, id);
        }
    }

    pub fn stop(&mut self, host: &mut HostClient) {
        let ids: Vec<u64> = self.pipes.keys().copied().collect();
        for id in ids {
            self.end(host, id);
        }
    }
}
