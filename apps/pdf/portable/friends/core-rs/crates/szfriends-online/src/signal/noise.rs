//! Noise signalling (`SZFriendsSignalingNoise.m`): IK for friends and own devices, NN for Add by ID online, carried as
//! opaque payloads by the host. ADR 0001's suite under its own prologue, `"SZFriends signal v1\0" || header`, the
//! header being message 1's first two bytes (`'S'`, pattern), with whole payloads as messages. Message 1 carries a
//! Hello (the signalling versions; for IK the certificate, the time and an optional token) before the caller's
//! items; message 2 the answerer's Hello and items; every later payload is one Noise transport message. A failure
//! kills the session.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use szfriends_crypto::noise::{Handshake, HandshakeKeys, Transport, HASH_LEN};
use szfriends_identity::identity::identity_key_from_certificate;
use szfriends_identity::Identity;
use szfriends_wire::types::Pattern;
use zeroize::Zeroizing;

use super::items::{self, tag, Item, ItemType, CLOCK_SKEW_MAX, MINOR, PAYLOAD_MAX};

const PROLOGUE_LABEL: &[u8; 20] = b"SZFriends signal v1\0";
const HEADER_MAGIC: u8 = b'S';
const HEADER_LENGTH: usize = 2;
const TAG_LENGTH: usize = 16;
const EPHEMERAL_LENGTH: usize = 32;

/// Why signalling failed, as the session area names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignalError {
    /// Out of order, or used after it failed.
    Protocol,
    HandshakeFailed,
    /// The key policy, or a pattern this side does not take.
    Rejected,
    /// Message 1 repeated an ephemeral key the cache holds.
    Replayed,
    DecryptFailed,
    /// Items that do not encode (nothing was sealed; the session stays usable).
    Invalid,
}

/// Message 1 ephemeral keys seen lately (Noise § 7.7), recorded only once message 1 decrypted and the policy admitted
/// the caller, so junk cannot evict a friend's entry. Entries last 600 s; past the capacity the oldest goes.
#[derive(Debug)]
pub struct ReplayCache {
    capacity: usize,
    seen: HashMap<[u8; 32], Instant>,
    order: VecDeque<[u8; 32]>,
}

impl ReplayCache {
    pub fn new(capacity: usize) -> Self {
        Self { capacity: capacity.max(1), seen: HashMap::new(), order: VecDeque::new() }
    }

    /// `true`, recording it, unless `key` was seen within the window.
    pub fn record(&mut self, key: &[u8; 32]) -> bool {
        let now = Instant::now();
        let window = Duration::from_secs(600);
        while let Some(oldest) = self.order.front() {
            if self.seen.get(oldest).is_some_and(|at| now.duration_since(*at) < window)
                && self.order.len() < self.capacity
            {
                break;
            }
            let oldest = self.order.pop_front().expect("front");
            self.seen.remove(&oldest);
        }
        if self.seen.contains_key(key) {
            return false;
        }
        self.seen.insert(*key, now);
        self.order.push_back(*key);
        true
    }
}

/// Who may call: the caller's identity key (IK; `None` for NN), the pattern and an IK token. Pure.
pub type KeyPolicy<'a> = &'a mut dyn FnMut(Option<&[u8; 32]>, Pattern, Option<&[u8]>) -> bool;

/// One signalling exchange, for one sid.
pub struct SignalingSession {
    pattern: Pattern,
    initiator: bool,
    handshake: Option<Handshake>,
    transport: Option<Transport>,
    dead: bool,
    message1: bool,
    expected_identity: Option<[u8; 32]>,
    request_token: Option<[u8; 16]>,
    certificate: Option<[u8; 96]>,
    /// This side's Friends ID attestation, sent beside its certificate.
    pub local_attestation: Option<Vec<u8>>,
    pub remote_identity: Option<[u8; 32]>,
    pub remote_static: Option<[u8; 32]>,
    pub remote_attestation: Option<Vec<u8>>,
    pub presented_token: Option<Vec<u8>>,
    pub handshake_hash: Option<[u8; HASH_LEN]>,
    pub negotiated_minor: u16,
}

impl std::fmt::Debug for SignalingSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SignalingSession")
            .field("pattern", &self.pattern)
            .field("initiator", &self.initiator)
            .field("established", &self.is_established())
            .finish()
    }
}

fn prologue(pattern: Pattern) -> Vec<u8> {
    let mut prologue = PROLOGUE_LABEL.to_vec();
    prologue.extend_from_slice(&[HEADER_MAGIC, pattern as u8]);
    prologue
}

impl SignalingSession {
    fn with(pattern: Pattern, initiator: bool, identity: Option<&Identity>, remote: Option<[u8; 32]>) -> Option<Self> {
        let keys = HandshakeKeys {
            local_static: identity.filter(|_| pattern == Pattern::IK).map(Identity::static_private_key),
            remote_static: remote,
            fixed_ephemeral: None,
        };
        let handshake = Handshake::new(pattern, initiator, &prologue(pattern), &keys).ok()?;
        Some(Self {
            pattern,
            initiator,
            handshake: Some(handshake),
            transport: None,
            dead: false,
            message1: false,
            expected_identity: None,
            request_token: None,
            certificate: identity.map(Identity::static_certificate),
            local_attestation: None,
            remote_identity: None,
            remote_static: None,
            remote_attestation: None,
            presented_token: None,
            handshake_hash: None,
            negotiated_minor: 0,
        })
    }

    /// IK toward a friend or one's own device: their stored static key, and the identity its certificate must name.
    pub fn ik_initiator(
        identity: &Identity,
        remote_static: [u8; 32],
        expected_identity: [u8; 32],
        request_token: Option<[u8; 16]>,
    ) -> Option<Self> {
        let mut session = Self::with(Pattern::IK, true, Some(identity), Some(remote_static))?;
        session.expected_identity = Some(expected_identity);
        session.request_token = request_token;
        Some(session)
    }

    /// NN for Add by ID online: reveals no static key on either side.
    pub fn nn_initiator() -> Option<Self> {
        Self::with(Pattern::NN, true, None, None)
    }

    pub fn pattern(&self) -> Pattern {
        self.pattern
    }

    pub fn is_initiator(&self) -> bool {
        self.initiator
    }

    pub fn is_established(&self) -> bool {
        self.transport.is_some() && !self.dead
    }

    fn die(&mut self) -> SignalError {
        self.dead = true;
        self.handshake = None;
        self.transport = None;
        SignalError::HandshakeFailed
    }

    fn fail(&mut self, error: SignalError) -> SignalError {
        self.die();
        error
    }

    fn hello(&self, now: Option<u64>, token: Option<[u8; 16]>) -> Item {
        let mut item = Item::new(
            ItemType::Hello,
            [(tag::MINOR_MIN, 0u16.to_be_bytes().to_vec()), (tag::MINOR_MAX, MINOR.to_be_bytes().to_vec())],
        );
        if self.pattern == Pattern::IK {
            if let Some(certificate) = self.certificate {
                item.fields.insert(tag::CERTIFICATE, certificate.to_vec());
            }
            if let Some(attestation) = &self.local_attestation {
                item.fields.insert(tag::ATTESTATION, attestation.clone());
            }
            if let Some(now) = now {
                item.fields.insert(tag::TIME, now.to_be_bytes().to_vec());
            }
            if let Some(token) = token {
                item.fields.insert(tag::TOKEN, token.to_vec());
            }
        }
        item
    }

    /// Checks the Hello that opens `items` and returns the rest.
    fn accept_hello(&mut self, mut items: Vec<Item>, now: Option<f64>) -> Result<Vec<Item>, SignalError> {
        let hello = (!items.is_empty()).then(|| items.remove(0));
        let Some(hello) = hello.filter(|h| h.kind == ItemType::Hello) else {
            return Err(self.fail(SignalError::HandshakeFailed));
        };
        let (Some(min), Some(max)) = (hello.unsigned(tag::MINOR_MIN), hello.unsigned(tag::MINOR_MAX)) else {
            return Err(self.fail(SignalError::HandshakeFailed));
        };
        if min > max || min > u64::from(MINOR) {
            return Err(self.fail(SignalError::HandshakeFailed));
        }
        self.negotiated_minor = max.min(u64::from(MINOR)) as u16;
        if self.pattern == Pattern::IK {
            let remote = self.handshake.as_ref().and_then(Handshake::remote_static);
            let certificate = hello.data(tag::CERTIFICATE);
            let identity = remote.zip(certificate).and_then(|(key, cert)| identity_key_from_certificate(cert, &key));
            let Some(identity) = identity else { return Err(self.fail(SignalError::HandshakeFailed)) };
            if self.initiator && Some(identity) != self.expected_identity {
                return Err(self.fail(SignalError::HandshakeFailed));
            }
            if !self.initiator {
                let sent = hello.unsigned(tag::TIME);
                let current = sent.zip(now).is_some_and(|(sent, now)| (sent as f64 - now).abs() <= CLOCK_SKEW_MAX);
                if !current {
                    return Err(self.fail(SignalError::HandshakeFailed));
                }
                self.presented_token = hello.data(tag::TOKEN).map(<[u8]>::to_vec);
            }
            self.remote_identity = Some(identity);
            self.remote_static = remote;
            self.remote_attestation = hello.data(tag::ATTESTATION).map(<[u8]>::to_vec);
        }
        Ok(items)
    }

    fn write_handshake(&mut self, items: &[Item], header: bool) -> Result<Vec<u8>, SignalError> {
        if self.dead || !self.handshake.as_ref().is_some_and(Handshake::is_write_turn) {
            return Err(self.fail(SignalError::Protocol));
        }
        let prefix = if header { HEADER_LENGTH } else { 0 };
        // DH keys in the clear (32 each) and a tag per encrypted payload, as the pattern's message has them.
        let overhead = match (self.pattern, self.initiator) {
            (Pattern::IK, true) => 32 + 48 + 16,
            (Pattern::IK, false) | (Pattern::NN, false) => 32 + 16,
            _ => 32,
        };
        let plaintext =
            items::encode(items, PAYLOAD_MAX - prefix - overhead).map_err(|_| self.fail(SignalError::Invalid))?;
        let handshake = self.handshake.as_mut().expect("checked");
        let Ok(message) = handshake.write(&plaintext) else { return Err(self.fail(SignalError::HandshakeFailed)) };
        let mut out = Vec::with_capacity(prefix + message.len());
        if header {
            out.extend_from_slice(&[HEADER_MAGIC, self.pattern as u8]);
        }
        out.extend_from_slice(&message);
        Ok(out)
    }

    fn read_handshake(&mut self, message: &[u8]) -> Result<Vec<Item>, SignalError> {
        let Some(handshake) = self.handshake.as_mut().filter(|_| !self.dead) else {
            return Err(self.fail(SignalError::HandshakeFailed));
        };
        let plaintext = handshake.read(message).map_err(|_| SignalError::HandshakeFailed);
        let items = plaintext.and_then(|p| items::decode(&p).map_err(|_| SignalError::HandshakeFailed));
        items.map_err(|e| self.fail(e))
    }

    fn finish(&mut self) -> Result<(), SignalError> {
        let handshake = self.handshake.take().ok_or(SignalError::Protocol)?;
        self.handshake_hash = handshake.handshake_hash();
        match handshake.into_transport() {
            Ok(transport) => {
                self.transport = Some(transport);
                Ok(())
            }
            Err(_) => Err(self.fail(SignalError::HandshakeFailed)),
        }
    }

    /// Initiator: message 1, the Hello first, then `items` (none for NN, whose message 1 is plaintext).
    pub fn opening_message(&mut self, items: &[Item], now: u64) -> Result<Vec<u8>, SignalError> {
        if !self.initiator || self.message1 || (self.pattern == Pattern::NN && !items.is_empty()) {
            return Err(self.fail(SignalError::Protocol));
        }
        self.message1 = true;
        let mut all = vec![self.hello(Some(now), self.request_token)];
        all.extend_from_slice(items);
        self.write_handshake(&all, true)
    }

    /// The responder for a received message 1, IK or NN from its header: decrypts it, checks the certificate binds
    /// the static key and the time is current, asks `policy`, and only then records the ephemeral key in `replay`.
    /// On success, message 1's items without its Hello.
    pub fn responder(
        message: &[u8],
        identity: &Identity,
        allowed: &[Pattern],
        replay: &mut ReplayCache,
        policy: KeyPolicy<'_>,
        now: f64,
    ) -> Result<(Self, Vec<Item>), SignalError> {
        if message.len() < HEADER_LENGTH + EPHEMERAL_LENGTH || message.len() > PAYLOAD_MAX || message[0] != HEADER_MAGIC
        {
            return Err(SignalError::HandshakeFailed);
        }
        let pattern = match Pattern::from_byte(message[1]) {
            Some(p @ (Pattern::IK | Pattern::NN)) => p,
            _ => return Err(SignalError::HandshakeFailed),
        };
        if !allowed.contains(&pattern) {
            return Err(SignalError::Rejected);
        }
        let mut session = Self::with(pattern, false, Some(identity), None).ok_or(SignalError::HandshakeFailed)?;
        session.message1 = true;
        let read = session.read_handshake(&message[HEADER_LENGTH..])?;
        let rest = session.accept_hello(read, Some(now))?;
        if pattern == Pattern::NN && !rest.is_empty() {
            return Err(session.fail(SignalError::HandshakeFailed));
        }
        let token = session.presented_token.clone();
        if !policy(session.remote_identity.as_ref(), pattern, token.as_deref()) {
            return Err(session.fail(SignalError::Rejected));
        }
        let ephemeral: [u8; 32] = message[HEADER_LENGTH..HEADER_LENGTH + EPHEMERAL_LENGTH].try_into().expect("32");
        if !replay.record(&ephemeral) {
            return Err(session.fail(SignalError::Replayed));
        }
        Ok((session, rest))
    }

    /// Responder: message 2 (its Hello, then `items`). Established after it.
    pub fn reply(&mut self, items: &[Item]) -> Result<Vec<u8>, SignalError> {
        if self.initiator || !self.message1 || self.transport.is_some() {
            return Err(self.fail(SignalError::Protocol));
        }
        let mut all = vec![self.hello(None, None)];
        all.extend_from_slice(items);
        let message = self.write_handshake(&all, false)?;
        self.finish()?;
        Ok(message)
    }

    /// Initiator: reads message 2; IK checks the certificate names the identity dialled. Established after it.
    pub fn read_reply(&mut self, message: &[u8]) -> Result<Vec<Item>, SignalError> {
        if !self.initiator || !self.message1 || self.transport.is_some() || self.dead {
            return Err(self.fail(SignalError::Protocol));
        }
        let read = self.read_handshake(message)?;
        let rest = self.accept_hello(read, None)?;
        self.finish()?;
        Ok(rest)
    }

    /// Established only: one Noise transport message. Items that do not encode leave the session usable.
    pub fn seal(&mut self, items: &[Item]) -> Result<Vec<u8>, SignalError> {
        if !self.is_established() {
            return Err(self.fail(SignalError::Protocol));
        }
        let plaintext = items::encode(items, PAYLOAD_MAX - TAG_LENGTH).map_err(|_| SignalError::Invalid)?;
        let transport = self.transport.as_mut().expect("established");
        transport.encrypt(&plaintext).map_err(|_| self.fail(SignalError::Protocol))
    }

    pub fn open(&mut self, payload: &[u8]) -> Result<Vec<Item>, SignalError> {
        if !self.is_established() || payload.len() <= TAG_LENGTH || payload.len() > PAYLOAD_MAX {
            return Err(self.fail(SignalError::DecryptFailed));
        }
        let transport = self.transport.as_mut().expect("established");
        let plaintext = transport.decrypt(payload).map_err(|_| SignalError::DecryptFailed);
        let items = plaintext.and_then(|p| items::decode(&p).map_err(|_| SignalError::DecryptFailed));
        items.map_err(|e| self.fail(e))
    }

    /// 32 bytes bound to this exchange: BLAKE2b-256 keyed with the handshake hash over `label`.
    pub fn export_key(&self, label: &str) -> Option<Zeroizing<[u8; 32]>> {
        let hash = self.handshake_hash.filter(|_| self.is_established() && !label.is_empty())?;
        Some(Zeroizing::new(blake2b_keyed64(&hash, label.as_bytes())))
    }
}

/// `crypto_generichash` with a 64-byte key and a 32-byte output (the crypto crate's keyed form is 32-byte only
/// through its MAC type, which takes any key length).
fn blake2b_keyed64(key: &[u8; 64], input: &[u8]) -> [u8; 32] {
    use szfriends_crypto::blake2b;
    blake2b::<32>(Some(key), &[input])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(n: u8) -> Identity {
        Identity::from_secrets(&[n; 32], &[n.wrapping_add(100); 32])
    }

    fn now() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
    }

    #[test]
    fn ik_exchange_carries_items_both_ways_and_refuses_replays() {
        let (a, b) = (identity(1), identity(2));
        let mut caller = SignalingSession::ik_initiator(&a, b.static_public_key(), b.public_key(), None).unwrap();
        let message1 = caller.opening_message(&[Item::nat(1, 0)], now()).unwrap();
        let mut replay = ReplayCache::new(16);
        let friend = a.public_key();
        let mut policy = |key: Option<&[u8; 32]>, _: Pattern, _: Option<&[u8]>| key == Some(&friend);
        let (mut answerer, items) =
            SignalingSession::responder(&message1, &b, &[Pattern::IK], &mut replay, &mut policy, now() as f64).unwrap();
        assert_eq!(items, vec![Item::nat(1, 0)]);
        assert_eq!(answerer.remote_identity, Some(a.public_key()));
        let message2 = answerer.reply(&[Item::end(0)]).unwrap();
        assert_eq!(caller.read_reply(&message2).unwrap(), vec![Item::end(0)]);
        let sealed = caller.seal(&[Item::candidates_end(3)]).unwrap();
        assert_eq!(answerer.open(&sealed).unwrap(), vec![Item::candidates_end(3)]);
        assert_eq!(*caller.export_key("x").unwrap(), *answerer.export_key("x").unwrap());
        let again = SignalingSession::responder(&message1, &b, &[Pattern::IK], &mut replay, &mut policy, now() as f64);
        assert_eq!(again.err(), Some(SignalError::Replayed));
        let mut stranger = |_: Option<&[u8; 32]>, _: Pattern, _: Option<&[u8]>| false;
        let mut fresh = SignalingSession::ik_initiator(&a, b.static_public_key(), b.public_key(), None).unwrap();
        let other = fresh.opening_message(&[], now()).unwrap();
        let refused = SignalingSession::responder(&other, &b, &[Pattern::IK], &mut replay, &mut stranger, now() as f64);
        assert_eq!(refused.err(), Some(SignalError::Rejected));
        let late =
            SignalingSession::responder(&other, &b, &[Pattern::IK], &mut replay, &mut policy, now() as f64 + 400.0);
        assert_eq!(late.err(), Some(SignalError::HandshakeFailed));
    }
}
