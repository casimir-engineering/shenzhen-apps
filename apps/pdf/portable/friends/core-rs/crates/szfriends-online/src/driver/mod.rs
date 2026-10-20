//! The online driver (`SZFriendsOnlineDriver.m`): attempts toward friends, joining the host's connection setup, the
//! signalling, the order, the transport and the NAT techniques. Everything runs on one thread (the online thread, or a
//! test's): what the stack, the prober and the classifier report comes back to it as [`Input`]s, and the host's sids
//! are reached through [`SignalHost`].
//!
//! Pre-authentication, end to end: an attempt toward a friend creates its offer only to seal it into IK message 1 to
//! that friend's stored static key and applies nothing remote until IK message 2 authenticated the friend; an
//! incoming message 1 is decrypted, its certificate checked, the replay cache consulted, its clock checked and the
//! friend policy asked before any peer connection exists for it, and a refusal is silence.

pub mod attempt;
mod attempt_conn;
mod attempt_nat;
pub mod context;

use std::collections::HashMap;
use std::sync::Arc;

use szfriends_datachannel_sys::Event;
use szfriends_identity::Identity;
use szfriends_wire::route::{rank, RouteMethod};
use szfriends_wire::types::Pattern;

pub use attempt::Attempt;
pub use context::{Context, DirectBlocked, Friends, OnlineFriend, Sink};

use crate::nat::classifier::Classification;
use crate::nat::prober::ProberEvent;
use crate::order::{attempt_worth_starting, EndReason};
use crate::signal::{ReplayCache, SignalingSession};
use crate::transport::{ChannelStream, RelayCredentials, Role, Route, TransportConfig};

/// An offer whose sid gets no answer within this is given up: a friend who is not online stays silent.
pub const ANSWER_TIMEOUT: f64 = 15.0;
/// After an attempt that reached nobody or found no path: the next one waits this long, doubling to the maximum.
pub const BACKOFF_FIRST: f64 = 30.0;
pub const BACKOFF_MAX: f64 = 900.0;
/// Connection numbers are one byte in the signalling.
pub const CONNECTIONS_MAX: usize = 250;
/// How often the selected pair under an open stream is read again.
pub const ROUTE_INTERVAL: f64 = 2.0;
const REPLAY_CAPACITY: usize = 4096;

/// What comes back to the online thread from the stack's, the prober's and the classifier's threads.
#[derive(Debug)]
pub enum Input {
    Connection(u64, Event),
    StreamClosed(u64),
    Prober(u64, ProberEvent),
    Classified(String, Option<Classification>),
}

/// The host's connection setup as attempts use it (`SZFriendsOnlineSignalChannel`); the host client implements it, and
/// the NAT emulator's peer passes the same over a socket pair.
pub trait SignalHost {
    /// `sig_open` to a rendezvous key; the answer comes back as [`Driver::sid_opened`].
    fn open(&mut self, attempt: u64, rdv_key: [u8; 32], payload: Vec<u8>);
    /// One payload; `false` once the sid ended or for the 65th.
    fn send(&mut self, sid: &str, payload: &[u8]) -> bool;
    fn close(&mut self, sid: &str);
    /// Relay credentials for this sid; the answer comes back as [`Driver::relay_credentials`].
    fn request_relay(&mut self, attempt: u64, sid: &str);
}

/// What the driver tells its owner.
#[derive(Debug)]
pub enum Output {
    /// A connected path: a new ADR 0001 session with this friend; the offerer's side is the initiator.
    Stream {
        attempt: u64,
        friend: [u8; 32],
        stream: ChannelStream,
        route: Route,
        initiator: bool,
    },
    Ended(u64),
}

/// What a call into an attempt can reach.
pub struct Ctx<'a> {
    pub context: &'a mut Context,
    pub host: &'a mut dyn SignalHost,
    pub out: &'a mut Vec<Output>,
}

impl std::fmt::Debug for Ctx<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Ctx").field("outputs", &self.out.len()).finish()
    }
}

/// What the helper hears from the driver.
#[derive(Debug)]
pub enum DriverEvent {
    Stream {
        friend: [u8; 32],
        stream: ChannelStream,
        route: Route,
        initiator: bool,
    },
    /// An attempt started or ended.
    ReachChanged([u8; 32]),
    /// An attempt ended; its technique log entry.
    AttemptEnded {
        friend: [u8; 32],
        role: Role,
        entry: crate::order::LogEntry,
    },
}

pub struct Driver {
    pub context: Context,
    friends: Box<dyn Friends>,
    attempts: HashMap<u64, Attempt>,
    next_attempt: u64,
    backoff_until: HashMap<[u8; 32], f64>,
    backoff_wait: HashMap<[u8; 32], f64>,
    replay: ReplayCache,
    stopped: bool,
    events: Vec<DriverEvent>,
}

impl std::fmt::Debug for Driver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Driver").field("attempts", &self.attempts.len()).finish()
    }
}

impl Driver {
    pub fn new(
        identity: Arc<Identity>,
        transport: TransportConfig,
        loopback_only: bool,
        friends: Box<dyn Friends>,
        inbox: Sink,
    ) -> Self {
        Self {
            context: Context::new(identity, transport, loopback_only, inbox),
            friends,
            attempts: HashMap::new(),
            next_attempt: 1,
            backoff_until: HashMap::new(),
            backoff_wait: HashMap::new(),
            replay: ReplayCache::new(REPLAY_CAPACITY),
            stopped: false,
            events: Vec::new(),
        }
    }

    /// What happened since the last call.
    pub fn take_events(&mut self) -> Vec<DriverEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn attempts(&self) -> impl Iterator<Item = &Attempt> {
        self.attempts.values()
    }

    /// The friend this identity key names now, as the helper last said.
    pub fn friend(&self, key: &[u8; 32]) -> Option<OnlineFriend> {
        self.friends.friend(key)
    }

    pub fn own_presence_secret(&self) -> Option<[u8; 32]> {
        self.friends.own_presence_secret()
    }

    pub fn has_attempt_for(&self, key: &[u8; 32]) -> bool {
        self.attempts.values().any(|a| a.peer() == *key)
    }

    /// Runs `step` on one attempt, then handles what it produced.
    fn with_attempt(&mut self, id: u64, host: &mut dyn SignalHost, step: impl FnOnce(&mut Attempt, &mut Ctx<'_>)) {
        let Some(mut attempt) = self.attempts.remove(&id) else { return };
        let mut out = Vec::new();
        {
            let mut ctx = Ctx { context: &mut self.context, host, out: &mut out };
            step(&mut attempt, &mut ctx);
            attempt.flush(&mut ctx);
        }
        let peer = attempt.peer();
        self.attempts.insert(id, attempt);
        for output in out {
            self.output(output, peer, host);
        }
    }

    fn output(&mut self, output: Output, peer: [u8; 32], host: &mut dyn SignalHost) {
        match output {
            Output::Stream { friend, stream, route, initiator, .. } => {
                self.backoff_until.remove(&friend);
                self.backoff_wait.remove(&friend);
                self.events.push(DriverEvent::Stream { friend, stream, route, initiator });
                self.nearby_routes_changed(host);
            }
            Output::Ended(id) => {
                let Some(attempt) = self.attempts.remove(&id) else { return };
                self.context.connections.retain(|_, (owner, _)| *owner != id);
                let nobody = attempt.role() == Role::Offerer && !attempt.answered();
                let unreachable = attempt.order.end_reason() == EndReason::Unreachable;
                if !self.stopped && !attempt.connected() && (nobody || unreachable) {
                    let wait = self.backoff_wait.get(&peer).map_or(BACKOFF_FIRST, |w| (w * 2.0).min(BACKOFF_MAX));
                    self.backoff_wait.insert(peer, wait);
                    self.backoff_until.insert(peer, self.context.now() + wait);
                }
                let entry = attempt.order.log_entry();
                self.events.push(DriverEvent::AttemptEnded { friend: peer, role: attempt.role(), entry });
                self.events.push(DriverEvent::ReachChanged(peer));
                if !self.stopped {
                    self.nearby_routes_changed(host);
                }
            }
        }
    }

    fn start(&mut self, attempt: Attempt, host: &mut dyn SignalHost) {
        let (id, peer) = (attempt.id, attempt.peer());
        self.attempts.insert(id, attempt);
        self.context.measure_nat_class();
        self.events.push(DriverEvent::ReachChanged(peer));
        self.with_attempt(id, host, Attempt::start);
        let other = self.other_route(&peer, Some(id));
        if self.attempts.get(&id).is_some_and(|a| !a.ended()) {
            self.with_attempt(id, host, |a, ctx| a.nearby_route_changed(ctx, other));
        }
    }

    /// The helper wants a session with this friend and no route ranking before Internet carries one.
    pub fn reach_friend(&mut self, key: &[u8; 32], host: &mut dyn SignalHost) {
        if self.stopped || self.has_attempt_for(key) {
            return;
        }
        if self.backoff_until.get(key).is_some_and(|until| *until > self.context.now()) {
            return;
        }
        let Some(friend) = self.friends.friend(key).filter(|f| f.identity_key == *key) else { return };
        if !attempt_worth_starting(self.other_route(key, None)) {
            return;
        }
        let id = self.next_attempt;
        self.next_attempt += 1;
        self.start(Attempt::offerer(id, friend), host);
    }

    /// Ends the backoff of a friend whose record appeared (they came online).
    pub fn friend_appeared(&mut self, key: &[u8; 32]) {
        self.backoff_until.remove(key);
    }

    pub fn backed_off(&self, key: &[u8; 32]) -> bool {
        self.backoff_until.get(key).is_some_and(|until| *until > self.context.now())
    }

    /// The best route carrying a session with this friend outside `except`: nearby's, or another attempt's stream.
    fn other_route(&self, key: &[u8; 32], except: Option<u64>) -> RouteMethod {
        let mut best = self.friends.nearby_route(key);
        for attempt in self.attempts.values().filter(|a| Some(a.id) != except && a.peer() == *key) {
            let carried = attempt.carried_route();
            if carried != RouteMethod::None && rank(carried as u8) < rank(best as u8) {
                best = carried;
            }
        }
        best
    }

    pub fn nearby_routes_changed(&mut self, host: &mut dyn SignalHost) {
        let ids: Vec<u64> = self.attempts.keys().copied().collect();
        for id in ids {
            let Some(peer) = self.attempts.get(&id).filter(|a| !a.ended()).map(Attempt::peer) else { continue };
            let other = self.other_route(&peer, Some(id));
            self.with_attempt(id, host, |a, ctx| a.nearby_route_changed(ctx, other));
        }
    }

    /// Someone opened a sid toward us by rendezvous key: only friends, by IK; a refusal is silence.
    pub fn incoming(&mut self, sid: String, payload: &[u8], host: &mut dyn SignalHost) {
        if self.stopped {
            host.close(&sid);
            return;
        }
        let (mut admitted, mut callback): (Option<OnlineFriend>, bool) = (None, false);
        let friends = &self.friends;
        let mut policy = |key: Option<&[u8; 32]>, pattern: Pattern, token: Option<&[u8]>| {
            let key = key.filter(|_| pattern == Pattern::IK);
            admitted = key.and_then(|k| friends.friend(k));
            if admitted.is_none() {
                // Someone we asked by ID, calling back with our token.
                admitted = key.zip(token).and_then(|(k, t)| friends.answering(k, t).filter(|f| f.identity_key == *k));
                callback = admitted.is_some();
            }
            admitted.is_some()
        };
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
        let identity = self.context.identity.clone();
        let result =
            SignalingSession::responder(payload, &identity, &[Pattern::IK], &mut self.replay, &mut policy, now);
        let Ok((session, items)) = result else {
            host.close(&sid);
            return;
        };
        // The friend must also present the static key we hold for them (a callback's is the one its certificate binds).
        if let (true, Some(friend), Some(static_key)) = (callback, admitted.as_mut(), session.remote_static) {
            friend.static_key = static_key;
        }
        let Some(friend) = admitted
            .filter(|f| session.remote_identity == Some(f.identity_key) && session.remote_static == Some(f.static_key))
        else {
            host.close(&sid);
            return;
        };
        let key = friend.identity_key;
        let answering = self.attempts.values().find(|a| a.peer() == key && a.role() == Role::Answerer).map(|a| a.id);
        if let Some(id) = answering {
            // The friend's own attempt, on a new sid (the old one ran out): it carries on.
            self.with_attempt(id, host, |a, ctx| a.continue_with(ctx, session, sid, items));
            return;
        }
        let ours: Vec<u64> = self.attempts.values().filter(|a| a.peer() == key).map(|a| a.id).collect();
        for id in ours {
            // Both sides started at once: the side whose identity key sorts first offers. Ours goes unless it already
            // carries a stream, and goes again when nobody answered it yet: it may have gone out while they were away
            // and reached nobody, and their open shows they are here now (no wait noted for it).
            if self.attempts[&id].connected() || self.context.identity.public_key() < key {
                host.close(&sid);
                let ours = &self.attempts[&id];
                if !ours.connected() && !ours.answered() {
                    self.with_attempt(id, host, |a, ctx| a.close(ctx));
                    self.backoff_until.remove(&key);
                    self.backoff_wait.remove(&key);
                    self.reach_friend(&key, host);
                }
                return;
            }
            self.with_attempt(id, host, |a, ctx| a.close(ctx));
        }
        let id = self.next_attempt;
        self.next_attempt += 1;
        self.start(Attempt::answerer(id, friend, session, sid, items), host);
    }

    fn attempt_for_sid(&self, sid: &str) -> Option<u64> {
        self.attempts.values().find(|a| a.sid() == Some(sid)).map(|a| a.id)
    }

    pub fn sid_opened(&mut self, attempt: u64, sid: Option<String>, host: &mut dyn SignalHost) {
        if !self.attempts.contains_key(&attempt) {
            if let Some(sid) = sid {
                host.close(&sid);
            }
            return;
        }
        self.with_attempt(attempt, host, |a, ctx| a.sid_opened(ctx, sid));
    }

    pub fn sid_payload(&mut self, sid: &str, payload: &[u8], host: &mut dyn SignalHost) {
        if let Some(id) = self.attempt_for_sid(sid) {
            self.with_attempt(id, host, |a, ctx| a.receive_payload(ctx, payload));
        }
    }

    pub fn sid_ended(&mut self, sid: &str, host: &mut dyn SignalHost) {
        if let Some(id) = self.attempt_for_sid(sid) {
            self.with_attempt(id, host, Attempt::channel_ended);
        }
    }

    pub fn relay_credentials(
        &mut self,
        attempt: u64,
        credentials: Option<RelayCredentials>,
        host: &mut dyn SignalHost,
    ) {
        self.with_attempt(attempt, host, |a, ctx| a.relay_credentials(ctx, credentials));
    }

    /// One of the inputs the driver's own threads sent back.
    pub fn input(&mut self, input: Input, host: &mut dyn SignalHost) {
        match input {
            Input::Connection(id, event) => {
                if let Some(&(attempt, number)) = self.context.connections.get(&id) {
                    self.with_attempt(attempt, host, |a, ctx| a.connection_event(ctx, number, event));
                }
            }
            Input::StreamClosed(id) => {
                if let Some(&(attempt, number)) = self.context.connections.get(&id) {
                    self.with_attempt(attempt, host, |a, ctx| a.stream_closed(ctx, number));
                }
            }
            Input::Prober(attempt, event) => self.with_attempt(attempt, host, |a, ctx| a.prober_event(ctx, event)),
            Input::Classified(network, result) => {
                if self.context.classified(&network, result) {
                    let ids: Vec<u64> = self.attempts.keys().copied().collect();
                    for id in ids {
                        self.with_attempt(id, host, Attempt::local_nat_class_changed);
                    }
                }
            }
        }
    }

    /// When [`tick`](Self::tick) next has something to do, on the context's clock.
    pub fn next_deadline(&self) -> f64 {
        self.attempts.values().map(Attempt::next_deadline).fold(f64::INFINITY, f64::min)
    }

    pub fn tick(&mut self, host: &mut dyn SignalHost) {
        let now = self.context.now();
        let due: Vec<u64> = self.attempts.values().filter(|a| a.next_deadline() <= now).map(|a| a.id).collect();
        for id in due {
            self.with_attempt(id, host, Attempt::fire_timers);
        }
    }

    /// The default route changed: classes are measured again, backoffs end, and attempts try direct again.
    pub fn network_changed(&mut self, host: &mut dyn SignalHost) {
        if self.stopped {
            return;
        }
        self.context.network_changed();
        self.backoff_until.clear();
        self.backoff_wait.clear();
        let ids: Vec<u64> = self.attempts.keys().copied().collect();
        for id in ids {
            self.with_attempt(id, host, Attempt::network_changed);
        }
        if !self.attempts.is_empty() {
            self.context.measure_nat_class();
        }
    }

    /// Exit, disable or Reset Friends: every attempt ends, and nothing is answered any more.
    pub fn stop(&mut self, host: &mut dyn SignalHost) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        let ids: Vec<u64> = self.attempts.keys().copied().collect();
        for id in ids {
            self.with_attempt(id, host, Attempt::close);
        }
        self.attempts.clear();
    }
}
