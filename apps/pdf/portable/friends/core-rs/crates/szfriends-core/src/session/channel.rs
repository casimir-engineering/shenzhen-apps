//! `SecureChannel`: lifecycle, inbound bytes and length framing, timers, and closing (`SZFriendsSecureChannel.m`).
//! The handshake, the transport and the comparison codes extend it in their own files.

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;

use szfriends_crypto::noise::{Handshake, Transport};
use szfriends_wire::consts::{RESPONDER_HANDSHAKE_MAX, SESSION_MAJOR};
use szfriends_wire::{Fields, Pattern, RouteMethod};

use super::{ChannelConfig, ChannelIdentity, Event, PublicProfile, ReplayCache, SessionError, SessionRandom};

/// The responder's view of IK or NN message 1, or XX message 3, before any reply: whether this remote may continue
/// (`SZFriendsRemoteKeyPolicy`). Arguments: the remote identity key (none for NN), the pattern, and the token an IK
/// callback presented. Pure until [`Event::Established`]: it may count toward a rate limit and nothing else, because
/// IK message 1 can be replayed and only HELLO cannot.
pub type RemoteKeyPolicy = Box<dyn FnMut(Option<&[u8; 32]>, Pattern, Option<&[u8]>) -> bool + Send>;

/// XX initiator: the responder's public profile from message 2. `true` continues (message 3 reveals us), `false`
/// closes without revealing anything.
pub type ProfileDecision = Box<dyn FnMut(&Fields) -> bool + Send>;

/// A listener's admission hooks (`SZFriendsByteStream`'s optional methods). Every method has a default, so a link
/// without limits implements nothing.
pub trait ListenerHooks: Send {
    /// Asked once, when the preamble names the pattern and before any Diffie-Hellman: `false` refuses the connection
    /// like a key-policy refusal.
    fn admit_pattern(&mut self, _pattern: Pattern) -> bool {
        true
    }
    /// A complete message 1 arrived, before any work on it.
    fn first_message_received(&mut self) {}
    /// The initiator is known (IK message 1 or XX message 3 accepted by the policy; NN at HELLO). Once.
    fn authenticated(&mut self) {}
}

/// What the initiator knows before dialing (`SZFriendsHandshakeOptions`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HandshakeOptions {
    pub pattern: Pattern,
    /// The route this attempt runs over; required (LAN to relay) for XX and IK, ignored for NN.
    pub route: RouteMethod,
    /// IK: the friend's stored X25519 static key.
    pub remote_static: Option<[u8; 32]>,
    /// The Ed25519 identity key the responder's certificate must name.
    pub expected_identity: Option<[u8; 32]>,
    /// IK callback after Add by ID: the requester's 16-byte token.
    pub request_token: Option<Vec<u8>>,
    /// XX against a public entry: stop after message 2 unless a [`ProfileDecision`] says to continue.
    pub browse_only: bool,
    /// IK: a lane of a live session's group (ADR 0018 § 6), its 16-byte token in message 1's payload.
    pub lane: Option<[u8; 16]>,
}

impl HandshakeOptions {
    pub fn new(pattern: Pattern, route: RouteMethod) -> Self {
        Self {
            pattern,
            route,
            remote_static: None,
            expected_identity: None,
            request_token: None,
            browse_only: false,
            lane: None,
        }
    }
}

/// One write for the link, in order. `counted` writes are transport messages and count against the in-flight budget
/// until [`SecureChannel::write_completed`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Transmit {
    pub bytes: Vec<u8>,
    pub counted: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum State {
    Idle,
    AwaitingPreamble,
    Handshaking,
    AwaitingHello,
    Established,
    Closing,
    Refusing,
    Closed,
}

pub(super) enum Role {
    Initiator { options: HandshakeOptions, on_profile: Option<ProfileDecision> },
    Responder { public_profile: Option<PublicProfile>, policy: Option<RemoteKeyPolicy> },
}

/// One session on one link (`SZFriendsSecureChannel`). See the module documentation for how a driver runs it.
pub struct SecureChannel {
    pub(super) role: Role,
    pub(super) identity: ChannelIdentity,
    pub(super) config: ChannelConfig,
    pub(super) rng: Box<dyn SessionRandom>,
    pub(super) replay: Arc<ReplayCache>,
    pub(super) hooks: Option<Box<dyn ListenerHooks>>,
    pub(super) state: State,
    pub(super) pattern: Pattern,
    pub(super) handshake: Option<Handshake>,
    pub(super) transport: Option<Transport>,
    pub(super) inbound: Vec<u8>,
    pub(super) control_queue: VecDeque<Vec<u8>>,
    pub(super) bulk_queue: VecDeque<Vec<u8>>,
    pub(super) transmit: VecDeque<Transmit>,
    pub(super) outstanding: VecDeque<(usize, bool)>,
    pub(super) in_flight: usize,
    pub(super) close_written: bool,
    pub(super) closing_error: Option<SessionError>,
    pub(super) link_closed: bool,
    pub(super) events: VecDeque<Event>,
    pub(super) started_at: Duration,
    pub(super) established_at: Duration,
    pub(super) last_send_rekey_at: Duration,
    pub(super) bytes_since_send_rekey: u64,
    pub(super) input_arrived_at: Duration,
    pub(super) refusal_deadline: Option<Duration>,
    pub(super) refusal_error: Option<SessionError>,
    pub(super) responder_replied: bool,
    pub(super) told_authenticated: bool,
    pub(super) received_request_by_id: bool,
    pub(super) received_received: bool,
    pub(super) code: super::code::CodeExchange,
    pub(super) local_attestation: Option<Vec<u8>>,
    pub(super) handshake_step: usize,
    pub(super) message1_certificate_checks: usize,
    pub(super) rekeys_sent: u64,
    pub(super) rekeys_received: u64,
    // What the handshake established; valid once live.
    pub(super) initiator_route: RouteMethod,
    pub(super) remote_identity: Option<[u8; 32]>,
    pub(super) remote_certificate: Option<Vec<u8>>,
    pub(super) remote_attestation: Option<Vec<u8>>,
    pub(super) remote_static: Option<[u8; 32]>,
    pub(super) presented_token: Option<Vec<u8>>,
    pub(super) presented_lane: Option<[u8; 16]>,
    pub(super) handshake_hash: Option<[u8; 64]>,
    pub(super) negotiated_minor: u16,
    pub(super) liveness: super::liveness::Liveness,
    pub(super) remote_capabilities: u32,
}

impl std::fmt::Debug for SecureChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SecureChannel")
            .field("initiator", &self.is_initiator())
            .field("pattern", &self.pattern)
            .field("state", &self.state)
            .finish_non_exhaustive()
    }
}

impl SecureChannel {
    fn with_role(role: Role, identity: ChannelIdentity, pattern: Pattern, route: RouteMethod) -> Self {
        Self {
            role,
            identity,
            config: ChannelConfig::default(),
            rng: Box::new(super::SystemRandom),
            replay: ReplayCache::shared(),
            hooks: None,
            state: State::Idle,
            pattern,
            handshake: None,
            transport: None,
            inbound: Vec::new(),
            control_queue: VecDeque::new(),
            bulk_queue: VecDeque::new(),
            transmit: VecDeque::new(),
            outstanding: VecDeque::new(),
            in_flight: 0,
            close_written: false,
            closing_error: None,
            link_closed: false,
            events: VecDeque::new(),
            started_at: Duration::ZERO,
            established_at: Duration::ZERO,
            last_send_rekey_at: Duration::ZERO,
            bytes_since_send_rekey: 0,
            input_arrived_at: Duration::ZERO,
            refusal_deadline: None,
            refusal_error: None,
            responder_replied: false,
            told_authenticated: false,
            received_request_by_id: false,
            received_received: false,
            code: Default::default(),
            local_attestation: None,
            handshake_step: 0,
            message1_certificate_checks: 0,
            rekeys_sent: 0,
            rekeys_received: 0,
            initiator_route: route,
            remote_identity: None,
            remote_certificate: None,
            remote_attestation: None,
            remote_static: None,
            presented_token: None,
            presented_lane: None,
            handshake_hash: None,
            negotiated_minor: 0,
            liveness: Default::default(),
            remote_capabilities: 0,
        }
    }

    pub fn initiator(identity: ChannelIdentity, options: HandshakeOptions) -> Self {
        let (pattern, route) = (options.pattern, options.route);
        Self::with_role(Role::Initiator { options, on_profile: None }, identity, pattern, route)
    }

    /// `public_profile`: PROFILE fields served in XX message 2 while this listener's public entry is on; `None` for a
    /// hidden listener, which refuses XX at the preamble.
    pub fn responder(
        identity: ChannelIdentity,
        public_profile: Option<PublicProfile>,
        policy: RemoteKeyPolicy,
    ) -> Self {
        let role = Role::Responder { public_profile, policy: Some(policy) };
        Self::with_role(role, identity, Pattern::XX, RouteMethod::None)
    }

    /// Before `start`: the numbers to run by.
    pub fn set_config(&mut self, config: ChannelConfig) {
        self.config = config;
    }

    /// Before `start`: the random source (tests and the transcript replays).
    pub fn set_random(&mut self, rng: Box<dyn SessionRandom>) {
        self.rng = rng;
    }

    /// Responder, before `start`: where message 1's ephemeral keys are remembered (default: the process-wide cache).
    pub fn set_replay_cache(&mut self, cache: Arc<ReplayCache>) {
        self.replay = cache;
    }

    /// Responder, before `start`: the listener's admission hooks.
    pub fn set_listener_hooks(&mut self, hooks: Box<dyn ListenerHooks>) {
        self.hooks = Some(hooks);
    }

    /// XX initiator, before `start`: decides on the responder's public profile.
    pub fn set_profile_decision(&mut self, decision: ProfileDecision) {
        if let Role::Initiator { on_profile, .. } = &mut self.role {
            *on_profile = Some(decision);
        }
    }

    /// Before `start`: this side's host-issued Friends ID attestation, sent beside our certificate (never in NN).
    /// One longer than 512 bytes fails the handshake rather than being cut.
    pub fn set_local_attestation(&mut self, attestation: Option<Vec<u8>>) {
        self.local_attestation = attestation;
    }

    pub fn is_initiator(&self) -> bool {
        matches!(self.role, Role::Initiator { .. })
    }

    pub fn pattern(&self) -> Pattern {
        self.pattern
    }

    pub fn is_established(&self) -> bool {
        self.state == State::Established
    }

    pub fn is_closed(&self) -> bool {
        self.state == State::Closed
    }

    /// The route the initiator declared (the session race and the chunk sizes use it).
    pub fn initiator_route(&self) -> RouteMethod {
        self.initiator_route
    }

    /// Ed25519 identity key from the peer's certificate; `None` for NN.
    pub fn remote_identity(&self) -> Option<&[u8; 32]> {
        self.remote_identity.as_ref()
    }

    /// The verified 96-byte certificate the peer presented; `None` for NN.
    pub fn remote_certificate(&self) -> Option<&[u8]> {
        self.remote_certificate.as_deref()
    }

    /// The peer's attestation, unverified.
    pub fn remote_attestation(&self) -> Option<&[u8]> {
        self.remote_attestation.as_deref()
    }

    pub fn remote_static(&self) -> Option<&[u8; 32]> {
        self.remote_static.as_ref()
    }

    /// Responder: the token an IK callback presented.
    pub fn presented_token(&self) -> Option<&[u8]> {
        self.presented_token.as_deref()
    }

    /// Responder: the lane token IK message 1 presented (ADR 0018 § 6). The driver admits the lane into the group it
    /// names once the session is live, or closes it with CLOSE `LaneRefused`; a lane never enters the session race.
    pub fn presented_lane(&self) -> Option<&[u8; 16]> {
        self.presented_lane.as_ref()
    }

    pub fn handshake_hash(&self) -> Option<&[u8; 64]> {
        self.handshake_hash.as_ref()
    }

    pub fn negotiated_minor(&self) -> u16 {
        self.negotiated_minor
    }

    /// The capability bits the peer's handshake set.
    pub fn remote_capabilities(&self) -> u32 {
        self.remote_capabilities
    }

    /// ADR 0018 § 1: this session runs fast transfers when its negotiated minor is 4 or more and both sides set bit 0.
    /// Otherwise nothing of them is sent, and nothing of them is accepted.
    pub fn fast_transfers(&self) -> bool {
        let bit = szfriends_wire::consts::CAPABILITY_FAST_TRANSFERS;
        self.negotiated_minor >= szfriends_wire::consts::FAST_TRANSFERS_MINOR
            && self.config.capabilities & bit != 0
            && self.remote_capabilities & bit != 0
    }

    /// ADR 0018 § 3: Pieces in WANT and HAVE go to this peer (both set capability bit 3 on a fast session).
    pub fn pieces(&self) -> bool {
        let bit = szfriends_wire::consts::CAPABILITY_PIECES;
        self.fast_transfers() && self.config.capabilities & bit != 0 && self.remote_capabilities & bit != 0
    }

    pub fn rekeys(&self) -> (u64, u64) {
        (self.rekeys_sent, self.rekeys_received)
    }

    pub fn poll_event(&mut self) -> Option<Event> {
        self.events.pop_front()
    }

    /// The next write for the link, in order.
    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        let item = self.transmit.pop_front()?;
        self.outstanding.push_back((item.bytes.len(), item.counted));
        Some(item)
    }

    /// The oldest write handed out is on the link: its bytes leave the in-flight budget and more may follow.
    pub fn write_completed(&mut self, now: Duration) {
        let Some((length, counted)) = self.outstanding.pop_front() else { return };
        if self.state == State::Closed || !counted {
            return;
        }
        self.in_flight -= length.min(self.in_flight);
        self.pump_writes(now);
    }

    /// Whether the driver should close the link once every write handed out is written.
    pub fn link_should_close(&self) -> bool {
        self.link_closed
    }

    /// When `handle_timeout` must run next.
    pub fn poll_timeout(&self) -> Option<Duration> {
        match self.state {
            State::Idle | State::Closed => None,
            State::Refusing => self.refusal_deadline,
            State::Established | State::Closing => {
                let age = self.established_at + self.config.max_age;
                Some(self.liveness_deadline().map_or(age, |at| at.min(age)))
            }
            _ => Some(self.started_at + self.config.handshake_timeout),
        }
    }

    pub fn handle_timeout(&mut self, now: Duration) {
        match self.state {
            State::Refusing => {
                if self.refusal_deadline.is_some_and(|deadline| now >= deadline) {
                    let error = self.refusal_error;
                    self.terminate(error, None);
                }
            }
            State::Established | State::Closing => {
                if self.check_session_age(now) {
                    self.check_liveness(now);
                }
            }
            State::Idle | State::Closed => {}
            _ => {
                // A quiet refusal has its own deadline; a timeout refuses nothing the peer sent, so it closes at once.
                if now >= self.started_at + self.config.handshake_timeout {
                    self.terminate(Some(SessionError::TimedOut), None);
                }
            }
        }
    }

    pub fn start(&mut self, now: Duration) {
        if self.state != State::Idle {
            return;
        }
        self.started_at = now;
        self.input_arrived_at = now;
        if self.is_initiator() {
            self.state = State::Handshaking;
            self.start_initiator_handshake();
        } else {
            self.state = State::AwaitingPreamble;
        }
    }

    /// Bytes the link delivered. A peer can make us hold at most one 65,537-byte message plus one delivery.
    pub fn receive(&mut self, bytes: &[u8], now: Duration) {
        if matches!(self.state, State::Closed | State::Idle | State::Refusing) {
            return;
        }
        // Before any work on these bytes: a refusal they cause closes a fixed time after this moment.
        self.input_arrived_at = now;
        self.note_heard(now);
        self.inbound.extend_from_slice(bytes);
        let mut offset = 0;
        while !matches!(self.state, State::Closed | State::Refusing) {
            let available = self.inbound.len() - offset;
            if self.state == State::AwaitingPreamble {
                if available < 4 {
                    break;
                }
                let preamble: [u8; 4] = self.inbound[offset..offset + 4].try_into().expect("four bytes");
                offset += 4;
                if !self.consume_preamble(preamble) {
                    return;
                }
                continue;
            }
            if available < 2 {
                break;
            }
            let length = usize::from(u16::from_be_bytes([self.inbound[offset], self.inbound[offset + 1]]));
            if length == 0 {
                self.fail(SessionError::FrameInvalid, now);
                return;
            }
            // A responder decides on the length alone, before any Diffie-Hellman and before buffering the body.
            if self.state == State::Handshaking && !self.is_initiator() && length > RESPONDER_HANDSHAKE_MAX {
                self.fail(SessionError::FrameInvalid, now);
                return;
            }
            if available < 2 + length {
                break;
            }
            let message = self.inbound[offset + 2..offset + 2 + length].to_vec();
            offset += 2 + length;
            match self.state {
                State::Handshaking => self.handle_handshake_message(&message, now),
                State::Closing => {} // after `close` nothing more reaches the caller; the bytes are only drained
                _ => self.handle_transport_message(&message, now),
            }
        }
        if matches!(self.state, State::Closed | State::Refusing) {
            return;
        }
        self.inbound.drain(..offset);
    }

    pub(super) fn preamble_bytes(pattern: Pattern) -> [u8; 4] {
        [b'S', b'Z', SESSION_MAJOR, pattern as u8]
    }
}
