//! The preamble, the Noise handshake messages, their payloads and the key policy (`SZFriendsSecureChannel+Handshake`).
//! Which message carries what: `szfriends_wire::payload`.

use std::time::Duration;

use szfriends_crypto::noise::{dummy_dh, Handshake, HandshakeKeys, NoiseError, DH_LEN};
use szfriends_identity::identity::identity_key_from_certificate;
use szfriends_wire::consts::{CAPABILITY_AES_LANES, PROLOGUE_LABEL, SESSION_MINOR};
use szfriends_wire::payload::negotiate_minor;
use szfriends_wire::stream::Preamble;
use szfriends_wire::{HandshakePayload, NoiseCipher, Pattern, RouteMethod};
use zeroize::Zeroizing;

use super::channel::{Role, SecureChannel, State, Transmit};
use super::SessionError;

/// What the full path of IK message 1 costs a responder: two X25519 operations and one certificate check.
const FULL_PATH_DH: usize = 2;
const FULL_PATH_CERTIFICATE_CHECKS: usize = 1;

fn route_is_known(route: RouteMethod) -> bool {
    (RouteMethod::Lan as u8..=RouteMethod::Relay as u8).contains(&(route as u8))
}

impl SecureChannel {
    fn initialize_handshake(&mut self, preamble: [u8; 4]) -> bool {
        let pattern = self.pattern;
        let mut ephemeral = Zeroizing::new([0u8; DH_LEN]);
        self.rng.fill(ephemeral.as_mut());
        let mut keys = HandshakeKeys { fixed_ephemeral: Some(ephemeral), ..HandshakeKeys::default() };
        if pattern != Pattern::NN {
            keys.local_static = Some(self.identity.static_private.clone());
        }
        if let Role::Initiator { options, .. } = &self.role {
            if pattern == Pattern::IK {
                keys.remote_static = options.remote_static;
            }
        }
        let mut prologue = PROLOGUE_LABEL.to_vec();
        prologue.extend_from_slice(&preamble);
        match Handshake::with_cipher(pattern, self.cipher, self.is_initiator(), &prologue, &keys) {
            Ok(handshake) => {
                self.handshake = Some(handshake);
                true
            }
            Err(_) => false,
        }
    }

    fn local_payload(&self, with_certificate: bool) -> HandshakePayload {
        let mut payload = HandshakePayload::local();
        payload.minor_range = Some((0, self.config.minor_max.min(SESSION_MINOR)));
        payload.capabilities = self.config.capabilities;
        if with_certificate {
            payload.certificate = Some(self.identity.certificate.to_vec());
            // The attestation names our identity, so it goes only where the certificate already does.
            payload.attestation = self.local_attestation.clone();
        }
        payload
    }

    /// The next handshake message for `payload`, with its length prefix; `None` after failing the channel.
    fn framed_handshake_message(&mut self, payload: Option<&HandshakePayload>, now: Duration) -> Option<Vec<u8>> {
        let encoded = match payload.map(HandshakePayload::encode) {
            None => Vec::new(),
            Some(Ok(bytes)) => bytes,
            Some(Err(_)) => {
                self.fail(SessionError::FrameInvalid, now);
                return None;
            }
        };
        let written = self.handshake.as_mut().map(|handshake| handshake.write(&encoded));
        match written {
            Some(Ok(message)) => {
                let mut framed = (message.len() as u16).to_be_bytes().to_vec();
                framed.extend_from_slice(&message);
                Some(framed)
            }
            Some(Err(NoiseError::Size)) => {
                self.fail(SessionError::FrameInvalid, now);
                None
            }
            _ => {
                self.fail(SessionError::HandshakeFailed, now);
                None
            }
        }
    }

    /// Handshake messages are small and precede every transport frame, so they skip the send queues.
    fn write_handshake_bytes(&mut self, bytes: Vec<u8>) {
        if !self.is_initiator() {
            self.responder_replied = true; // from here a refusal no longer hides behind the refusal deadline
        }
        self.transmit.push_back(Transmit { bytes, counted: false });
    }

    fn finish_handshake(&mut self, now: Duration) {
        let Some(handshake) = self.handshake.take() else {
            self.fail(SessionError::HandshakeFailed, now);
            return;
        };
        self.handshake_hash = handshake.handshake_hash();
        match handshake.into_transport() {
            Ok(transport) => self.transport = Some(transport),
            Err(_) => {
                self.fail(SessionError::HandshakeFailed, now);
                return;
            }
        }
        if self.is_initiator() {
            self.become_established(now);
        } else {
            self.state = State::AwaitingHello;
        }
    }

    pub(super) fn start_initiator_handshake(&mut self) {
        let now = self.started_at;
        let Role::Initiator { options, .. } = &self.role else { return };
        let (pattern, route) = (options.pattern, options.route);
        let token = options.request_token.clone();
        let lane = options.lane;
        // AES-GCM is for lanes only (ADR 0018 § 9.2): a first session must stay what released apps speak.
        let fits = (pattern == Pattern::NN || route_is_known(route))
            && (pattern != Pattern::IK || options.remote_static.is_some())
            && token.as_ref().is_none_or(|token| pattern == Pattern::IK && token.len() == 16)
            && (lane.is_none() || (pattern == Pattern::IK && token.is_none()))
            && (self.cipher == NoiseCipher::ChaChaPoly || lane.is_some());
        if !fits {
            self.fail(SessionError::HandshakeFailed, now);
            return;
        }
        let preamble = Self::preamble_bytes(pattern, self.cipher);
        if !self.initialize_handshake(preamble) {
            self.fail(SessionError::HandshakeFailed, now);
            return;
        }
        // XX message 1 is plaintext and says nothing.
        let payload = match pattern {
            Pattern::XX => None,
            Pattern::NN => Some(self.local_payload(false)),
            Pattern::IK => {
                let mut payload = self.local_payload(true);
                payload.route_class = Some(route as u8);
                payload.request_token = token;
                payload.lane = lane.map(|l| l.to_vec());
                Some(payload)
            }
        };
        let Some(message) = self.framed_handshake_message(payload.as_ref(), now) else { return };
        let mut output = preamble.to_vec();
        output.extend_from_slice(&message);
        self.write_handshake_bytes(output);
    }

    fn initiator_read_payload(&mut self, payload: HandshakePayload, now: Duration) {
        if self.pattern != Pattern::NN {
            let Some(identity) = self.identity_from_payload(&payload, now) else { return };
            let expected = match &self.role {
                Role::Initiator { options, .. } => options.expected_identity,
                Role::Responder { .. } => None,
            };
            if expected.is_some_and(|expected| expected != identity) {
                self.fail(SessionError::HandshakeFailed, now);
                return;
            }
            self.adopt_remote_identity(identity, &payload);
        }
        if !self.accept_minor_range(&payload, now) {
            return;
        }
        if self.pattern == Pattern::XX {
            let proceed = match &mut self.role {
                Role::Initiator { options, on_profile } => match on_profile {
                    Some(decide) => decide(&payload.profile),
                    None => !options.browse_only,
                },
                Role::Responder { .. } => false,
            };
            if self.state == State::Closed {
                return;
            }
            if !proceed {
                // Browsing ends here: message 3 would reveal who we are.
                self.terminate(None, None);
                return;
            }
            let mut reply = self.local_payload(true);
            reply.route_class = Some(self.initiator_route as u8);
            let Some(message) = self.framed_handshake_message(Some(&reply), now) else { return };
            self.write_handshake_bytes(message);
        }
        self.finish_handshake(now);
    }

    pub(super) fn consume_preamble(&mut self, bytes: [u8; 4]) -> bool {
        let now = self.input_arrived_at;
        let Ok(preamble) = Preamble::parse(&bytes) else {
            self.fail(SessionError::HandshakeFailed, now);
            return false;
        };
        self.pattern = preamble.pattern;
        self.cipher = preamble.cipher;
        // An AES-GCM lane only where this side offers them (capability bit 1, hardware AES), refused before any
        // Diffie-Hellman; whether the friend's first session agreed is the group's check once the lane is live.
        if self.cipher == NoiseCipher::AesGcm && self.config.capabilities & CAPABILITY_AES_LANES == 0 {
            self.fail(SessionError::Rejected, now);
            return false;
        }
        // A hidden listener answers only IK and NN; XX would hand a stranger our static key and profile.
        let public = matches!(&self.role, Role::Responder { public_profile: Some(_), .. });
        if self.pattern == Pattern::XX && !public {
            self.fail(SessionError::Rejected, now);
            return false;
        }
        let pattern = self.pattern;
        if let Some(hooks) = self.hooks.as_mut() {
            if !hooks.admit_pattern(pattern) {
                self.fail(SessionError::Rejected, now);
                return false;
            }
        }
        if !self.initialize_handshake(bytes) {
            self.fail(SessionError::HandshakeFailed, now);
            return false;
        }
        self.state = State::Handshaking;
        true
    }

    fn responder_read_payload(&mut self, payload: HandshakePayload, now: Duration) {
        let pattern = self.pattern;
        if pattern == Pattern::XX && self.handshake_step == 1 {
            // Message 1 is plaintext; whatever it carries is ignored.
            let mut reply = self.local_payload(true);
            if let Role::Responder { public_profile: Some(profile), .. } = &self.role {
                reply.profile = profile.clone();
            }
            if let Some(message) = self.framed_handshake_message(Some(&reply), now) {
                self.write_handshake_bytes(message);
            }
            return;
        }
        let mut identity = None;
        if pattern != Pattern::NN {
            identity = self.identity_from_payload(&payload, now);
            if identity.is_none() || !self.accept_route_class(&payload, now) {
                return;
            }
        }
        if !self.accept_minor_range(&payload, now) {
            return;
        }
        let token = if pattern == Pattern::IK { payload.request_token.clone() } else { None };
        // The policy may weigh the attestation, so it sees it unverified first; a refused remote keeps nothing.
        self.remote_attestation = if pattern != Pattern::NN { payload.attestation.clone() } else { None };
        if !self.ask_policy(identity.as_ref(), token.as_deref(), now) {
            self.remote_attestation = None;
            return;
        }
        self.presented_token = token;
        // A lane's token (IK only; anything else in that field is ignored, and a wrong length refused as a lane).
        if pattern == Pattern::IK {
            self.presented_lane = payload.lane.as_deref().map(|l| l.try_into().unwrap_or([0; 16]));
        }
        // AES-GCM carries lanes only: a session without a lane token on it is refused.
        if self.cipher == NoiseCipher::AesGcm && self.presented_lane.is_none() {
            self.fail(SessionError::Rejected, now);
            return;
        }
        if let Some(identity) = identity {
            self.adopt_remote_identity(identity, &payload);
            // Known now: IK message 1 is fresh (the replay cache refused any repeat) and proves the initiator's static
            // key; XX message 3 proves it against our fresh ephemeral.
            self.report_authenticated();
        }
        if pattern != Pattern::XX {
            let reply = self.local_payload(pattern != Pattern::NN);
            let Some(message) = self.framed_handshake_message(Some(&reply), now) else { return };
            self.write_handshake_bytes(message);
        }
        self.finish_handshake(now);
    }

    fn adopt_remote_identity(&mut self, identity: [u8; 32], payload: &HandshakePayload) {
        self.remote_identity = Some(identity);
        self.remote_certificate = payload.certificate.clone();
        self.remote_attestation = payload.attestation.clone();
    }

    pub(super) fn report_authenticated(&mut self) {
        if self.is_initiator() || self.told_authenticated {
            return;
        }
        self.told_authenticated = true;
        if let Some(hooks) = self.hooks.as_mut() {
            hooks.authenticated();
        }
    }

    fn ask_policy(&mut self, identity: Option<&[u8; 32]>, token: Option<&[u8]>, now: Duration) -> bool {
        let pattern = self.pattern;
        let allowed = match &mut self.role {
            Role::Responder { policy: Some(policy), .. } => policy(identity, pattern, token),
            _ => false,
        };
        if self.state == State::Closed {
            return false;
        }
        if !allowed {
            self.fail(SessionError::Rejected, now);
        }
        allowed
    }

    pub(super) fn handle_handshake_message(&mut self, message: &[u8], now: Duration) {
        let first_at_responder = !self.is_initiator() && self.handshake_step == 0;
        if first_at_responder {
            if let Some(hooks) = self.hooks.as_mut() {
                hooks.first_message_received(); // the listener's deadline for a complete message 1 is met
            }
        }
        let records_key = first_at_responder && self.pattern != Pattern::XX;
        let equalise = first_at_responder && self.pattern == Pattern::IK;
        self.message1_certificate_checks = 0;
        let Some(handshake) = self.handshake.as_mut() else { return };
        let dh_before = handshake.dh_count();
        let result = handshake.read(message);
        let dh_done = handshake.dh_count() - dh_before;
        match result {
            Err(_) => self.fail(SessionError::HandshakeFailed, now),
            Ok(plaintext) => {
                self.handshake_step += 1;
                if !records_key || self.is_fresh_message1(message, now) {
                    match HandshakePayload::decode(&plaintext) {
                        Err(_) => self.fail(SessionError::HandshakeFailed, now),
                        Ok(payload) if self.is_initiator() => self.initiator_read_payload(payload, now),
                        Ok(payload) => self.responder_read_payload(payload, now),
                    }
                }
            }
        }
        if equalise {
            self.equalise_message1_work(dh_done);
        }
    }

    /// Every IK message 1 costs what the full path costs: two X25519 operations and one certificate check, the
    /// missing ones run on throwaway inputs, so the time a reply queued behind it takes reveals nothing about whose
    /// listener this is (`-equaliseMessage1Work`).
    fn equalise_message1_work(&mut self, dh_done: usize) {
        for _ in dh_done..FULL_PATH_DH {
            let mut scalar = Zeroizing::new([0u8; DH_LEN]);
            self.rng.fill(scalar.as_mut());
            dummy_dh(&scalar);
        }
        for _ in self.message1_certificate_checks..FULL_PATH_CERTIFICATE_CHECKS {
            let _ = identity_key_from_certificate(&self.identity.certificate, &self.identity.static_public);
        }
    }

    /// A message 1 whose ephemeral key was seen within the replay window is refused, once it has decrypted and before
    /// its payload or the key policy, so junk never enters the shared cache.
    fn is_fresh_message1(&mut self, message: &[u8], now: Duration) -> bool {
        let Some(key) = message.get(..DH_LEN) else {
            self.fail(SessionError::HandshakeFailed, now);
            return false;
        };
        if !self.replay.record(key.try_into().expect("32 bytes")) {
            self.fail(SessionError::Replayed, now);
            return false;
        }
        true
    }

    /// The certificate must bind the static key this handshake authenticated; the identity is the key it names.
    fn identity_from_payload(&mut self, payload: &HandshakePayload, now: Duration) -> Option<[u8; 32]> {
        let remote_static = self.handshake.as_ref().and_then(Handshake::remote_static);
        let identity = match (remote_static, &payload.certificate) {
            (Some(static_key), Some(certificate)) => {
                self.message1_certificate_checks += 1;
                identity_key_from_certificate(certificate, &static_key)
            }
            _ => None,
        };
        if identity.is_none() {
            self.fail(SessionError::HandshakeFailed, now);
            return None;
        }
        self.remote_static = remote_static;
        identity
    }

    fn accept_minor_range(&mut self, payload: &HandshakePayload, now: Duration) -> bool {
        let local = (0, self.config.minor_max.min(SESSION_MINOR));
        match payload.minor_range.and_then(|range| negotiate_minor(local, range)) {
            Some(minor) => {
                self.negotiated_minor = minor;
                self.remote_capabilities = payload.capabilities;
                true
            }
            None => {
                self.fail(SessionError::HandshakeFailed, now);
                false
            }
        }
    }

    fn accept_route_class(&mut self, payload: &HandshakePayload, now: Duration) -> bool {
        let route = payload.route_class.map(RouteMethod::from_byte).unwrap_or(RouteMethod::None);
        if !route_is_known(route) {
            self.fail(SessionError::HandshakeFailed, now);
            return false;
        }
        self.initiator_route = route;
        true
    }
}
