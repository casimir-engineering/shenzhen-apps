//! Add by ID online (`SZFriendsOnlineDriver+ByID.m`; ADR 0004 step 1 through the host, ADR 0010 § Connection setup):
//! Noise NN over a sid opened to a Friends ID.
//!
//! ```text
//! requester                          host                         holder of the ID
//! NN message 1 (Hello only) ---- sig_open to.friends_id ----> NN message 2 (Hello only)
//! REQUEST_BY_ID (Frame item) -------- sig_msg -------------> RECEIVED (Frame item), then the sid is let go
//! ```
//!
//! Nothing else travels and nothing else is read: no description, no candidate, no peer connection, whoever asks. The
//! request's signature is bound to this session's handshake hash, so a host running one NN session with each side
//! cannot pass one off as the other. What the person does with the request is the helper's; once they accept, the
//! holder reaches the requester with IK presenting the request's token (the driver's callback admission).

use std::collections::HashMap;

use szfriends_wire::frame::Frame;
use szfriends_wire::types::{FrameType, Pattern};

use crate::host::HostClient;
use crate::signal::items::{tag, Item, ItemType};
use crate::signal::{ReplayCache, SignalingSession};

/// The host's budget for opens by Friends ID: 5 an hour per identity; a sixth would only be refused.
const OPENS_PER_HOUR: usize = 5;
const OPEN_WINDOW: f64 = 3600.0;
/// Each step waits as long as an offer waits for its answer.
const STEP_TIMEOUT: f64 = crate::driver::ANSWER_TIMEOUT;
/// The holder lets go of its sid this long after RECEIVED, so the reply is forwarded first.
const RECEIVED_LINGER: f64 = 2.0;
/// Exchanges at once, both ways: a flood of NN opens costs a handful of sessions, never more.
const EXCHANGES_MAX: usize = 8;
const REPLAY_CAPACITY: usize = 256;
/// Open tokens of these exchanges never meet the driver's attempts or the links' relay requests.
pub const OPEN_TOKENS: u64 = 1 << 52;

/// Makes the REQUEST_BY_ID frame (encoded) for this session's handshake hash, on the online thread.
pub type RequestFrame = Box<dyn FnOnce(&[u8]) -> Option<Vec<u8>> + Send>;

/// What the exchanges report.
#[derive(Debug, PartialEq, Eq)]
pub enum IdEvent {
    /// Our request `request` was delivered (RECEIVED came back) or not.
    Sent { request: u64, received: bool },
    /// Someone's REQUEST_BY_ID (encoded) and the handshake hash it must be signed over; RECEIVED already went back.
    Request { frame: Vec<u8>, handshake_hash: Vec<u8> },
}

struct Exchange {
    session: SignalingSession,
    sid: Option<String>,
    /// Requester: the request's number and its frame, until it is sent.
    request: Option<(u64, Option<RequestFrame>)>,
    deadline: f64,
}

/// Every exchange in flight and the hourly budget.
#[derive(Default)]
pub struct IdExchanges {
    exchanges: HashMap<u64, Exchange>,
    next: u64,
    opens: Vec<f64>,
    replay: Option<ReplayCache>,
    lingering: Vec<(String, f64)>,
    events: Vec<IdEvent>,
}

impl std::fmt::Debug for IdExchanges {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IdExchanges").field("exchanges", &self.exchanges.len()).finish()
    }
}

fn frame_in(items: &[Item]) -> Option<Frame> {
    let mut frames = items.iter().filter(|i| i.kind == ItemType::Frame);
    let found = frames.next()?.data(tag::FRAME)?;
    if frames.next().is_some() {
        return None;
    }
    Frame::decode(found).ok()
}

impl IdExchanges {
    pub fn take_events(&mut self) -> Vec<IdEvent> {
        std::mem::take(&mut self.events)
    }

    /// Requester: opens to `friends_id` with NN message 1; `false` (nothing sent) over the budget or the limit.
    pub fn request(
        &mut self,
        host: &mut HostClient,
        request: u64,
        friends_id: &str,
        frame: RequestFrame,
        now: f64,
    ) -> bool {
        self.opens.retain(|at| now - at < OPEN_WINDOW);
        if friends_id.is_empty() || self.opens.len() >= OPENS_PER_HOUR || self.exchanges.len() >= EXCHANGES_MAX {
            return false;
        }
        let Some(mut session) = SignalingSession::nn_initiator() else { return false };
        let Ok(message) = session.opening_message(&[], now as u64) else { return false };
        self.opens.push(now);
        let id = self.next;
        self.next += 1;
        let deadline = now + STEP_TIMEOUT;
        self.exchanges.insert(id, Exchange { session, sid: None, request: Some((request, Some(frame))), deadline });
        host.open_to_friends_id(OPEN_TOKENS + id, friends_id, &message);
        true
    }

    pub fn owns_token(token: u64) -> bool {
        (OPEN_TOKENS..OPEN_TOKENS + (1 << 40)).contains(&token)
    }

    pub fn owns_sid(&self, sid: &str) -> bool {
        self.exchanges.values().any(|e| e.sid.as_deref() == Some(sid))
    }

    /// The host's answer to our open.
    pub fn opened(&mut self, host: &mut HostClient, token: u64, sid: Option<String>) {
        let id = token - OPEN_TOKENS;
        match (self.exchanges.get_mut(&id), sid) {
            (Some(exchange), Some(sid)) => exchange.sid = Some(sid),
            (Some(_), None) => self.end(host, id, false),
            (None, Some(sid)) => host.close_sid(&sid),
            (None, None) => {}
        }
    }

    /// Holder: someone opened a sid to our Friends ID. NN only; anything else is silence.
    pub fn incoming(
        &mut self,
        host: &mut HostClient,
        identity: &szfriends_identity::Identity,
        sid: String,
        payload: &[u8],
        now: f64,
    ) {
        if self.exchanges.len() >= EXCHANGES_MAX {
            return host.close_sid(&sid);
        }
        let replay = self.replay.get_or_insert_with(|| ReplayCache::new(REPLAY_CAPACITY));
        let mut policy = |_: Option<&[u8; 32]>, pattern: Pattern, _: Option<&[u8]>| pattern == Pattern::NN;
        let answered = SignalingSession::responder(payload, identity, &[Pattern::NN], replay, &mut policy, now)
            .ok()
            .and_then(|(mut session, _)| session.reply(&[]).ok().map(|reply| (session, reply)));
        let Some((session, reply)) = answered else { return host.close_sid(&sid) };
        if !host.send_payload(&sid, &reply) {
            return host.close_sid(&sid);
        }
        let id = self.next;
        self.next += 1;
        self.exchanges.insert(id, Exchange { session, sid: Some(sid), request: None, deadline: now + STEP_TIMEOUT });
    }

    pub fn payload(&mut self, host: &mut HostClient, sid: &str, payload: &[u8], now: f64) {
        let Some((&id, exchange)) = self.exchanges.iter_mut().find(|(_, e)| e.sid.as_deref() == Some(sid)) else {
            return;
        };
        exchange.deadline = now + STEP_TIMEOUT;
        match exchange.request.as_mut() {
            Some((_, frame @ Some(_))) => {
                // The holder's NN message 2: the hash both sides now share is what the request is signed over.
                let make = frame.take().expect("checked");
                let hash = exchange.session.read_reply(payload).ok().and(exchange.session.handshake_hash);
                let encoded = hash.and_then(|h| make(&h));
                let sealed = encoded.and_then(|f| exchange.session.seal(&[Item::frame(f)]).ok());
                if !sealed.is_some_and(|sealed| host.send_payload(sid, &sealed)) {
                    self.end(host, id, false);
                }
            }
            Some((_, None)) => {
                let received = exchange.session.open(payload).ok().and_then(|items| frame_in(&items));
                let received = received.is_some_and(|f| f.frame_type == FrameType::Received);
                self.end(host, id, received);
            }
            None => {
                let frame = exchange.session.open(payload).ok().and_then(|items| frame_in(&items));
                let (Some(frame), Some(hash)) = (frame, exchange.session.handshake_hash) else {
                    return self.end(host, id, false);
                };
                if frame.frame_type != FrameType::RequestById {
                    return self.end(host, id, false);
                }
                // RECEIVED before anything is looked at, the same bytes whatever follows (ADR 0004 step 2).
                let received = Frame::new(FrameType::Received).encode().ok();
                if let Some(sealed) = received.and_then(|f| exchange.session.seal(&[Item::frame(f)]).ok()) {
                    host.send_payload(sid, &sealed);
                }
                let encoded = frame.encode().unwrap_or_default();
                self.exchanges.remove(&id);
                self.lingering.push((sid.to_owned(), now + RECEIVED_LINGER));
                self.events.push(IdEvent::Request { frame: encoded, handshake_hash: hash.to_vec() });
            }
        }
    }

    pub fn sid_ended(&mut self, host: &mut HostClient, sid: &str) {
        if let Some(id) = self.exchanges.iter().find(|(_, e)| e.sid.as_deref() == Some(sid)).map(|(id, _)| *id) {
            self.end(host, id, false);
        }
    }

    fn end(&mut self, host: &mut HostClient, id: u64, received: bool) {
        let Some(exchange) = self.exchanges.remove(&id) else { return };
        if let Some(sid) = &exchange.sid {
            host.close_sid(sid);
        }
        if let Some((request, _)) = exchange.request {
            self.events.push(IdEvent::Sent { request, received });
        }
    }

    pub fn next_deadline(&self) -> f64 {
        let lingering = self.lingering.iter().map(|(_, at)| *at);
        self.exchanges.values().map(|e| e.deadline).chain(lingering).fold(f64::INFINITY, f64::min)
    }

    pub fn tick(&mut self, host: &mut HostClient, now: f64) {
        let due: Vec<u64> = self.exchanges.iter().filter(|(_, e)| e.deadline <= now).map(|(id, _)| *id).collect();
        for id in due {
            self.end(host, id, false);
        }
        let (over, kept): (Vec<_>, Vec<_>) = self.lingering.drain(..).partition(|(_, at)| *at <= now);
        self.lingering = kept;
        for (sid, _) in over {
            host.close_sid(&sid);
        }
    }

    pub fn stop(&mut self, host: &mut HostClient) {
        let ids: Vec<u64> = self.exchanges.keys().copied().collect();
        for id in ids {
            self.end(host, id, false);
        }
        for (sid, _) in std::mem::take(&mut self.lingering) {
            host.close_sid(&sid);
        }
    }
}
