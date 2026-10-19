//! One attempt toward one peer (`SZFriendsOnlinePeerConnection.m`, `+Events.m`): a peer connection and its one data
//! channel. The owner (an attempt) calls in on its own thread; what the stack reports comes back as [`ConnEvent`]s in
//! the order the helper's header promises: one local description; candidates and at most one end of gathering after
//! it; then streams and route changes; at most one failure, after which nothing more.

use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};

use szfriends_datachannel_sys::{sdp_fingerprint, Config, DataChannel, Event, PeerConnection, State};

use super::candidate::{self, Allowances, Candidate, CandidateType};
use super::description::{turn_server_url, Description};
use super::stream::{ChannelStream, SharedSinks, Sinks, StreamWriter};
use super::{
    configure_stack, Kind, OnlineError, Purpose, Request, Role, Route, Technique, TransportConfig, MESSAGE_MAX,
};

const CHANNEL_LABEL: &str = "szfriends";
const REMOTE_CANDIDATE_MAX: usize = candidate::REMOTE_CANDIDATE_MAX;

/// What the connection reports to its owner.
#[derive(Debug)]
pub enum ConnEvent {
    /// The offer (offerer) or answer (answerer), with this side's fingerprint, for the authenticated exchange.
    Description {
        sdp: String,
        fingerprint: [u8; 32],
    },
    Candidate {
        line: String,
        technique: Technique,
    },
    GatheringDone,
    Stream {
        stream: ChannelStream,
        route: Route,
    },
    RouteChanged(Route),
    /// The stream closed (the peer closed its channel, or the path ended).
    StreamClosed,
    Failed(OnlineError),
}

/// Everything the stack reports for a connection, tagged with its id, to the owner's thread.
pub type Forward = Arc<dyn Fn(u64, Event) + Send + Sync>;

pub struct Connection {
    pub id: u64,
    pub purpose: Purpose,
    pub role: Role,
    pub kind: Kind,
    pub peer: Vec<u8>,
    pc: Option<PeerConnection>,
    offerer_channel: Option<Arc<DataChannel>>,
    stream_channel: Option<Arc<DataChannel>>,
    sinks: SharedSinks,
    allow: Allowances,
    pub bound_port: u16,
    pub local_fingerprint: Option<[u8; 32]>,
    description_sent: bool,
    held_local: Vec<(String, Technique)>,
    local: HashMap<String, (Candidate, Technique)>,
    remote: HashMap<String, (Candidate, Technique)>,
    stack_candidates: usize,
    answer_applied: bool,
    remote_mid: Option<String>,
    gathering_finished: bool,
    gathering_reported: bool,
    relay_candidates: usize,
    ice_connected: bool,
    stream_ever_opened: bool,
    pub route: Route,
    stream_ended: bool,
    closed: bool,
    on_stream_close: Arc<dyn Fn() + Send + Sync>,
}

impl std::fmt::Debug for Connection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Connection").field("id", &self.id).field("kind", &self.kind).field("role", &self.role).finish()
    }
}

/// The stack's events for one connection go to `forward`, except data-channel messages, which go straight to the
/// stream's receiver (held until the stream exists).
fn spawn_forwarder(id: u64, events: Receiver<Event>, sinks: SharedSinks, forward: Forward) {
    let spawned = std::thread::Builder::new().name("szfriends-online-pc".into()).spawn(move || {
        for event in events {
            match event {
                Event::Message { channel, data, text: false } => Sinks::deliver(&sinks, channel, data),
                other => forward(id, other),
            }
        }
    });
    if spawned.is_err() {
        // Without the thread nothing is ever reported: the owner's timers end the attempt.
    }
}

impl Connection {
    /// Starts a connection: an offerer creates its offer, an answerer applies the authenticated offer and creates its
    /// answer, both then gather. Refuses what breaks the gating rule as far as the request shows it.
    pub fn open(
        id: u64,
        request: &Request,
        config: &TransportConfig,
        forward: Forward,
        on_stream_close: Arc<dyn Fn() + Send + Sync>,
        now: f64,
    ) -> Result<Self, OnlineError> {
        let peer_length = if request.purpose == Purpose::Link { 16 } else { 32 };
        let answerer = request.role == Role::Answerer;
        if request.peer.len() != peer_length
            || answerer != request.remote_offer.is_some()
            || (request.kind == Kind::Relay) != request.relay.is_some()
            || (request.kind == Kind::ProbeHandover && request.local_port == 0)
            || (request.stun_uri.is_some()
                && (request.kind == Kind::Relay
                    || !super::description::stun_uri_valid(request.stun_uri.as_deref().unwrap_or(""))))
        {
            return Err(OnlineError::NotAuthorized);
        }
        let server = match &request.relay {
            Some(relay) => Some(turn_server_url(relay, now)?),
            None => request.stun_uri.clone(),
        };
        let offer = match &request.remote_offer {
            Some((sdp, fingerprint)) => {
                let offer = Description::parse(sdp)?;
                if offer.fingerprint != *fingerprint {
                    return Err(OnlineError::FingerprintMismatch);
                }
                Some(offer)
            }
            None => None,
        };
        configure_stack();
        let pc_config = Config {
            bind_address: config.bind_address.clone(),
            port_range: (request.local_port != 0).then_some((request.local_port, request.local_port)),
            ice_servers: server.into_iter().collect(),
            relay_only: request.kind == Kind::Relay,
            max_message_size: MESSAGE_MAX,
        };
        let (pc, events) = PeerConnection::new(&pc_config).map_err(|_| OnlineError::Unavailable)?;
        let sinks: SharedSinks = Arc::new(Mutex::new(Sinks::default()));
        spawn_forwarder(id, events, sinks.clone(), forward);
        let mut connection = Self {
            id,
            purpose: request.purpose,
            role: request.role,
            kind: request.kind,
            peer: request.peer.clone(),
            pc: Some(pc),
            offerer_channel: None,
            stream_channel: None,
            sinks,
            allow: Allowances { loopback: config.allow_loopback, test_links: config.links_use_local_addresses },
            bound_port: request.local_port,
            local_fingerprint: None,
            description_sent: false,
            held_local: Vec::new(),
            local: HashMap::new(),
            remote: HashMap::new(),
            stack_candidates: 0,
            answer_applied: false,
            remote_mid: None,
            gathering_finished: false,
            gathering_reported: false,
            relay_candidates: 0,
            ice_connected: false,
            stream_ever_opened: false,
            route: Route::NONE,
            stream_ended: false,
            closed: false,
            on_stream_close,
        };
        let pc = connection.pc.as_ref().expect("just made");
        match offer {
            None => {
                let channel = pc.create_data_channel(CHANNEL_LABEL).map_err(|_| OnlineError::Unavailable)?;
                connection.offerer_channel = Some(Arc::new(channel));
            }
            Some(offer) => {
                connection.remote_mid = Some(offer.mid.clone());
                if pc.set_remote_description(&offer.sdp, "offer").is_err() {
                    let code = if request.local_port != 0 {
                        OnlineError::Unavailable
                    } else {
                        OnlineError::DescriptionInvalid
                    };
                    return Err(code);
                }
                for line in &offer.candidates {
                    let _ = connection.apply_remote(line, Technique::None);
                }
            }
        }
        Ok(connection)
    }

    /// Offerer only, once: the answer and fingerprint from the authenticated exchange.
    pub fn apply_answer(&mut self, sdp: &str, fingerprint: &[u8]) -> Result<(), OnlineError> {
        if self.closed || self.role != Role::Offerer || self.answer_applied {
            return Err(OnlineError::DescriptionInvalid);
        }
        let answer = Description::parse(sdp)?;
        if fingerprint != answer.fingerprint {
            return Err(OnlineError::FingerprintMismatch);
        }
        let pc = self.pc.as_ref().ok_or(OnlineError::DescriptionInvalid)?;
        pc.set_remote_description(&answer.sdp, "answer").map_err(|_| OnlineError::DescriptionInvalid)?;
        self.answer_applied = true;
        self.remote_mid = Some(answer.mid.clone());
        for line in &answer.candidates {
            let _ = self.apply_remote(line, Technique::None);
        }
        Ok(())
    }

    /// A remote candidate from the authenticated exchange. An offerer takes them only after its answer.
    pub fn add_remote_candidate(&mut self, line: &str, technique: Technique) -> Result<(), OnlineError> {
        if self.closed {
            return Err(OnlineError::CandidateRefused);
        }
        if self.role == Role::Offerer && !self.answer_applied {
            return Err(OnlineError::NotAuthorized);
        }
        self.apply_remote(line, technique)
    }

    fn apply_remote(&mut self, line: &str, technique: Technique) -> Result<(), OnlineError> {
        let candidate = Candidate::parse(line).ok_or(OnlineError::CandidateRefused)?;
        if !candidate::may_dial(&candidate, self.purpose, self.kind, self.allow) {
            return Err(OnlineError::CandidateRefused);
        }
        let endpoint = candidate.endpoint();
        if self.remote.contains_key(&endpoint) {
            return Ok(());
        }
        // No TCP path in this core yet (ADR 0011's simultaneous open): TCP candidates are not dialled.
        if candidate.tcp || self.stack_candidates >= REMOTE_CANDIDATE_MAX {
            return Err(OnlineError::CandidateRefused);
        }
        let pc = self.pc.as_ref().ok_or(OnlineError::CandidateRefused)?;
        pc.add_remote_candidate(&candidate.line(), self.remote_mid.as_deref())
            .map_err(|_| OnlineError::CandidateRefused)?;
        self.stack_candidates += 1;
        self.remote.insert(endpoint, (candidate, technique));
        Ok(())
    }

    /// A candidate found outside the stack (a router mapping), under the same rules as gathered ones.
    pub fn add_local_candidate(&mut self, line: &str, technique: Technique) -> Vec<ConnEvent> {
        let Some(candidate) = Candidate::parse(line).filter(|c| !c.tcp && !self.closed) else { return Vec::new() };
        if technique == Technique::None
            || candidate::local_technique(&candidate, self.purpose, self.kind, true, self.allow) == Technique::None
        {
            return Vec::new();
        }
        self.offer_local(candidate, technique)
    }

    fn offer_local(&mut self, candidate: Candidate, technique: Technique) -> Vec<ConnEvent> {
        let line = candidate.line();
        self.local.insert(candidate.endpoint(), (candidate, technique));
        if !self.description_sent {
            self.held_local.push((line, technique));
            return Vec::new();
        }
        vec![ConnEvent::Candidate { line, technique }]
    }

    pub fn stack_candidates(&self) -> usize {
        self.stack_candidates
    }

    /// One event from the stack, on the owner's thread.
    pub fn handle(&mut self, event: Event) -> Vec<ConnEvent> {
        if self.closed {
            return Vec::new();
        }
        match event {
            Event::LocalDescription { sdp, .. } => self.local_description(&sdp),
            Event::LocalCandidate { candidate, .. } => self.local_candidate(&candidate),
            Event::GatheringComplete => {
                self.gathering_finished = true;
                if self.kind == Kind::Relay && self.relay_candidates == 0 {
                    return self.fail(OnlineError::RelayRefused);
                }
                self.report_gathering()
            }
            Event::StateChanged(State::Connected) => {
                self.ice_connected = true;
                self.refresh_route()
            }
            Event::StateChanged(State::Failed | State::Closed) => self.path_ended(),
            Event::StateChanged(_) => Vec::new(),
            Event::DataChannel(channel) => self.channel_opened(Arc::new(channel)),
            Event::ChannelOpen(id) => match self.offerer_channel.clone().filter(|c| c.id() == id) {
                Some(channel) => self.channel_opened(channel),
                None => Vec::new(),
            },
            Event::ChannelClosed(id) | Event::ChannelError { channel: id, .. } => self.channel_closed(id),
            Event::Message { channel, text: true, .. } => self.channel_closed(channel),
            Event::Message { .. } => Vec::new(),
        }
    }

    fn local_description(&mut self, sdp: &str) -> Vec<ConnEvent> {
        if self.description_sent {
            return Vec::new();
        }
        let Some(description) = Description::parse(sdp).ok().filter(|d| Some(d.fingerprint) == sdp_fingerprint(sdp))
        else {
            return self.fail(OnlineError::Unavailable);
        };
        self.local_fingerprint = Some(description.fingerprint);
        self.description_sent = true;
        let mut events = vec![ConnEvent::Description { sdp: description.sdp, fingerprint: description.fingerprint }];
        for (line, technique) in std::mem::take(&mut self.held_local) {
            events.push(ConnEvent::Candidate { line, technique });
        }
        events.extend(self.report_gathering());
        events
    }

    fn local_candidate(&mut self, line: &str) -> Vec<ConnEvent> {
        let Some(candidate) = Candidate::parse(line) else { return Vec::new() };
        let technique = candidate::local_technique(&candidate, self.purpose, self.kind, true, self.allow);
        let base = match candidate.kind {
            CandidateType::Host => candidate.address.port(),
            CandidateType::ServerReflexive => candidate.related_port,
            _ => 0,
        };
        if self.bound_port == 0 && base != 0 {
            self.bound_port = base;
        }
        if technique == Technique::Relay {
            self.relay_candidates += 1;
        }
        if technique == Technique::None {
            return Vec::new();
        }
        self.offer_local(candidate, technique)
    }

    fn report_gathering(&mut self) -> Vec<ConnEvent> {
        if !self.description_sent || !self.gathering_finished || self.gathering_reported {
            return Vec::new();
        }
        self.gathering_reported = true;
        vec![ConnEvent::GatheringDone]
    }

    fn channel_opened(&mut self, channel: Arc<DataChannel>) -> Vec<ConnEvent> {
        let ours = match self.role {
            Role::Offerer => self.offerer_channel.as_ref().is_some_and(|c| c.id() == channel.id()),
            Role::Answerer => self.stream_channel.is_none(),
        };
        if self.stream_channel.is_some() || !ours || !channel.is_reliable_and_ordered() {
            if self.offerer_channel.as_ref().is_none_or(|c| c.id() != channel.id()) {
                channel.close();
            }
            return Vec::new();
        }
        let (sender, incoming) = mpsc::channel();
        Sinks::attach(&self.sinks, channel.id(), sender);
        self.stream_channel = Some(channel.clone());
        self.route = self.selected_route();
        self.stream_ever_opened = true;
        let writer = StreamWriter::new(channel, self.on_stream_close.clone());
        vec![ConnEvent::Stream { stream: ChannelStream { incoming, writer }, route: self.route }]
    }

    fn channel_closed(&mut self, id: i32) -> Vec<ConnEvent> {
        if self.stream_channel.as_ref().is_none_or(|c| c.id() != id) || self.stream_ended {
            return Vec::new();
        }
        self.stream_ended = true;
        Sinks::end(&self.sinks, id);
        vec![ConnEvent::StreamClosed]
    }

    fn path_ended(&mut self) -> Vec<ConnEvent> {
        let error = if self.stream_ever_opened {
            OnlineError::PeerClosed
        } else if self.kind == Kind::Relay && self.relay_candidates == 0 {
            OnlineError::RelayRefused
        } else if self.ice_connected {
            // A checked pair existed, so DTLS failed: the peer's certificate is not the one the signalling named.
            OnlineError::FingerprintMismatch
        } else {
            OnlineError::ConnectivityFailed
        };
        let mut events = Vec::new();
        if let Some(channel) = self.stream_channel.clone() {
            events.extend(self.channel_closed(channel.id()));
        }
        events.extend(self.fail(error));
        events
    }

    fn fail(&mut self, error: OnlineError) -> Vec<ConnEvent> {
        self.close();
        vec![ConnEvent::Failed(error)]
    }

    /// The technique of the selected pair, by what each side said its candidates were.
    fn selected_route(&self) -> Route {
        let pair = self.pc.as_ref().and_then(PeerConnection::selected_pair);
        let parsed = pair.and_then(|(l, r)| Candidate::parse(&l).zip(Candidate::parse(&r)));
        let Some((local, remote)) = parsed else {
            let technique = match self.kind {
                Kind::Relay => Technique::Relay,
                Kind::ProbeHandover => Technique::ProbeHandover,
                Kind::Direct => Technique::HostPrivate,
            };
            return Route { technique, ipv6: false };
        };
        let (local, local_technique) = self.local.get(&local.endpoint()).cloned().unwrap_or((local, Technique::None));
        let (remote, remote_technique) =
            self.remote.get(&remote.endpoint()).cloned().unwrap_or((remote, Technique::None));
        let technique = candidate::pair_technique(&local, local_technique, &remote, remote_technique, self.kind);
        Route { technique, ipv6: remote.ipv6() }
    }

    /// Reads the selected pair again (a relayed connection can settle on a direct pair by itself); the owner calls this
    /// every couple of seconds while a stream is open.
    pub fn refresh_route(&mut self) -> Vec<ConnEvent> {
        if self.closed || self.stream_channel.is_none() || self.stream_ended {
            return Vec::new();
        }
        let route = self.selected_route();
        if route == self.route {
            return Vec::new();
        }
        self.route = route;
        vec![ConnEvent::RouteChanged(route)]
    }

    pub fn has_open_stream(&self) -> bool {
        self.stream_channel.is_some() && !self.stream_ended
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }

    /// Ends this connection and its stream. Idempotent; nothing is reported afterwards.
    pub fn close(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        Sinks::end_all(&self.sinks);
        if let Some(channel) = self.stream_channel.take() {
            channel.close();
        }
        // The stack's deletion blocks until its transports stop: never on the owner's thread.
        super::teardown((self.offerer_channel.take(), self.pc.take()));
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.close();
    }
}
