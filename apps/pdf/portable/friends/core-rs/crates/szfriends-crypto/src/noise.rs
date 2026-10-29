//! Noise revision 34, `Noise_{XX,IK,NN}_25519_ChaChaPoly_BLAKE2b`, as ADR 0001 specifies it, on `snow`; and
//! `Noise_IK_25519_AESGCM_BLAKE2b` for lanes where both sides have hardware AES (ADR 0018 § 9.2).
//!
//! What this adds to `snow`, each a rule the Objective-C helper's C state machine (`szfriends_noise.h`) enforces:
//!
//! - An X25519 result of all zeros (a low-order public key) fails the handshake ([`CheckedX25519`]).
//! - The key material each pattern needs is checked up front: XX needs a static key, IK one on both sides and the
//!   responder's on the initiator, and NN refuses any, so an NN session can never reveal a static key by mistake.
//! - A handshake that has returned an error is dead and refuses every later call.
//! - Transport plaintext is one frame, at most 65,519 bytes; nonces never wrap (`snow` refuses 2^64-1).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use curve25519_dalek::montgomery::MontgomeryPoint;
use snow::params::{CipherChoice, DHChoice, HashChoice};
use snow::resolvers::{CryptoResolver, DefaultResolver};
use snow::types::{Cipher, Dh, Hash, Random};
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

use szfriends_wire::consts::{FRAME_PLAINTEXT_MAX, NOISE_MESSAGE_MAX, NOISE_TAG_LEN};
use szfriends_wire::{NoiseCipher, Pattern};

pub const DH_LEN: usize = 32;
pub const HASH_LEN: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoiseError {
    /// A key the pattern needs is missing, or NN was given one.
    Argument,
    /// Out of turn, finished, or dead after an earlier error.
    State,
    /// A message over 65,535 bytes, a frame over 65,519, or a message too short for its tokens.
    Size,
    /// Authentication failed.
    Decrypt,
    /// X25519 produced all zeros.
    Dh,
    /// The counter reached 2^64-1.
    Nonce,
}

impl std::fmt::Display for NoiseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for NoiseError {}

fn map_error(error: snow::Error) -> NoiseError {
    match error {
        snow::Error::Dh => NoiseError::Dh,
        snow::Error::Decrypt => NoiseError::Decrypt,
        snow::Error::Input => NoiseError::Size,
        snow::Error::State(snow::error::StateProblem::Exhausted) => NoiseError::Nonce,
        snow::Error::State(_) => NoiseError::State,
        _ => NoiseError::Argument,
    }
}

/// X25519 that refuses an all-zero shared secret, in constant time. Otherwise `snow`'s own Curve25519, clamping
/// private keys at use as libsodium's `crypto_scalarmult` does. Counts its Diffie-Hellman operations when given a
/// counter, so a responder can make every IK message 1 cost the same work ([`Handshake::dh_count`]).
#[derive(Default)]
pub struct CheckedX25519 {
    private: [u8; DH_LEN],
    public: [u8; DH_LEN],
    counter: Option<Arc<AtomicUsize>>,
}

impl std::fmt::Debug for CheckedX25519 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CheckedX25519").field("public", &self.public).finish_non_exhaustive()
    }
}

impl Drop for CheckedX25519 {
    fn drop(&mut self) {
        self.private.zeroize();
    }
}

impl Dh for CheckedX25519 {
    fn name(&self) -> &'static str {
        "25519"
    }

    fn pub_len(&self) -> usize {
        DH_LEN
    }

    fn priv_len(&self) -> usize {
        DH_LEN
    }

    fn set(&mut self, private: &[u8]) {
        self.private.copy_from_slice(&private[..DH_LEN]);
        self.public = MontgomeryPoint::mul_base_clamped(self.private).to_bytes();
    }

    fn generate(&mut self, rng: &mut dyn Random) -> Result<(), snow::Error> {
        let mut private = Zeroizing::new([0u8; DH_LEN]);
        rng.try_fill_bytes(private.as_mut())?;
        self.set(private.as_ref());
        Ok(())
    }

    fn pubkey(&self) -> &[u8] {
        &self.public
    }

    fn privkey(&self) -> &[u8] {
        &self.private
    }

    fn dh(&self, public: &[u8], out: &mut [u8]) -> Result<(), snow::Error> {
        if let Some(counter) = &self.counter {
            counter.fetch_add(1, Ordering::Relaxed);
        }
        let point: &[u8; DH_LEN] = public.get(..DH_LEN).and_then(|p| p.try_into().ok()).ok_or(snow::Error::Dh)?;
        let shared = checked_x25519(&self.private, point).ok_or(snow::Error::Dh)?;
        out[..DH_LEN].copy_from_slice(shared.as_ref());
        Ok(())
    }
}

/// X25519 as the helper's `crypto_scalarmult` computes it: the private key clamped at use, the public key's top bit
/// ignored, and `None` for an all-zero result (a low-order public key), checked in constant time.
pub fn checked_x25519(private: &[u8; DH_LEN], public: &[u8; DH_LEN]) -> Option<Zeroizing<[u8; DH_LEN]>> {
    let shared = Zeroizing::new(MontgomeryPoint(*public).mul_clamped(*private).to_bytes());
    (!bool::from(shared.ct_eq(&[0u8; DH_LEN]))).then_some(shared)
}

/// The ladder a DH token runs, on the base point taken as an ordinary public key, for work that must cost what a real
/// Diffie-Hellman costs (`szfriends_noise_dummy_dh`). The caller draws `scalar` at random.
pub fn dummy_dh(scalar: &[u8; DH_LEN]) {
    let mut base = [0u8; DH_LEN];
    base[0] = 9;
    let shared = Zeroizing::new(MontgomeryPoint(base).mul_clamped(*scalar).to_bytes());
    std::hint::black_box(&shared);
}

/// `snow`'s default primitives with [`CheckedX25519`] in place of its Curve25519.
#[derive(Debug, Default)]
pub struct FriendsResolver {
    dh_count: Option<Arc<AtomicUsize>>,
}

impl CryptoResolver for FriendsResolver {
    fn resolve_rng(&self) -> Option<Box<dyn Random>> {
        DefaultResolver.resolve_rng()
    }

    fn resolve_dh(&self, choice: &DHChoice) -> Option<Box<dyn Dh>> {
        let counter = self.dh_count.clone();
        matches!(choice, DHChoice::Curve25519)
            .then(|| Box::new(CheckedX25519 { counter, ..CheckedX25519::default() }) as Box<dyn Dh>)
    }

    fn resolve_hash(&self, choice: &HashChoice) -> Option<Box<dyn Hash>> {
        DefaultResolver.resolve_hash(choice)
    }

    fn resolve_cipher(&self, choice: &CipherChoice) -> Option<Box<dyn Cipher>> {
        DefaultResolver.resolve_cipher(choice)
    }
}

/// What one side brings to a handshake.
#[derive(Clone, Default)]
pub struct HandshakeKeys {
    /// This side's X25519 static private key: XX and IK.
    pub local_static: Option<Zeroizing<[u8; DH_LEN]>>,
    /// The responder's static public key, known before dialing: the IK initiator only.
    pub remote_static: Option<[u8; DH_LEN]>,
    /// Golden vectors only: fixes the ephemeral key. Production leaves it `None` and draws one per handshake.
    pub fixed_ephemeral: Option<Zeroizing<[u8; DH_LEN]>>,
}

impl std::fmt::Debug for HandshakeKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HandshakeKeys")
            .field("local_static", &self.local_static.is_some())
            .field("remote_static", &self.remote_static.is_some())
            .field("fixed_ephemeral", &self.fixed_ephemeral.is_some())
            .finish()
    }
}

/// One side of one handshake.
pub struct Handshake {
    state: Option<snow::HandshakeState>,
    pattern: Pattern,
    dh_count: Arc<AtomicUsize>,
}

impl std::fmt::Debug for Handshake {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Handshake").field("pattern", &self.pattern).field("alive", &self.state.is_some()).finish()
    }
}

impl Handshake {
    /// Initialize(): protocol name, MixHash(prologue), then IK's pre-message.
    pub fn new(pattern: Pattern, initiator: bool, prologue: &[u8], keys: &HandshakeKeys) -> Result<Self, NoiseError> {
        Self::with_cipher(pattern, NoiseCipher::ChaChaPoly, initiator, prologue, keys)
    }

    /// The same with `cipher`: AES-256-GCM only for IK lanes (ADR 0018 § 9.2).
    pub fn with_cipher(
        pattern: Pattern,
        cipher: NoiseCipher,
        initiator: bool,
        prologue: &[u8],
        keys: &HandshakeKeys,
    ) -> Result<Self, NoiseError> {
        if cipher == NoiseCipher::AesGcm && pattern != Pattern::IK {
            return Err(NoiseError::Argument);
        }
        let needs_static = pattern != Pattern::NN;
        let needs_remote = pattern == Pattern::IK && initiator;
        if keys.local_static.is_some() != needs_static || keys.remote_static.is_some() != needs_remote {
            return Err(NoiseError::Argument);
        }
        let params = pattern.protocol_name_with(cipher).parse().map_err(map_error)?;
        let dh_count = Arc::new(AtomicUsize::new(0));
        let resolver = FriendsResolver { dh_count: Some(dh_count.clone()) };
        let mut builder = snow::Builder::with_resolver(params, Box::new(resolver));
        builder = builder.prologue(prologue).map_err(map_error)?;
        if let Some(local) = &keys.local_static {
            builder = builder.local_private_key(local.as_ref()).map_err(map_error)?;
        }
        if let Some(remote) = &keys.remote_static {
            builder = builder.remote_public_key(remote).map_err(map_error)?;
        }
        if let Some(ephemeral) = &keys.fixed_ephemeral {
            builder = builder.fixed_ephemeral_key_for_testing_only(ephemeral.as_ref());
        }
        let state = if initiator { builder.build_initiator() } else { builder.build_responder() };
        Ok(Self { state: Some(state.map_err(map_error)?), pattern, dh_count })
    }

    pub fn pattern(&self) -> Pattern {
        self.pattern
    }

    /// X25519 operations run so far, the failed one included: what reading a message cost.
    pub fn dh_count(&self) -> usize {
        self.dh_count.load(Ordering::Relaxed)
    }

    fn alive(&mut self) -> Result<&mut snow::HandshakeState, NoiseError> {
        self.state.as_mut().ok_or(NoiseError::State)
    }

    /// Runs `step`; any error kills the handshake (its SymmetricState may be half-mixed).
    fn guarded<T>(
        &mut self,
        step: impl FnOnce(&mut snow::HandshakeState) -> Result<T, NoiseError>,
    ) -> Result<T, NoiseError> {
        let result = step(self.alive()?);
        if result.is_err() {
            self.state = None;
        }
        result
    }

    /// Writes the next handshake message carrying `payload`.
    pub fn write(&mut self, payload: &[u8]) -> Result<Vec<u8>, NoiseError> {
        self.guarded(|state| {
            let mut out = vec![0u8; NOISE_MESSAGE_MAX];
            let length = state.write_message(payload, &mut out).map_err(map_error)?;
            out.truncate(length);
            Ok(out)
        })
    }

    /// Reads the peer's next handshake message and returns its payload.
    pub fn read(&mut self, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        self.guarded(|state| {
            if message.len() > NOISE_MESSAGE_MAX {
                return Err(NoiseError::Size);
            }
            let mut out = vec![0u8; NOISE_MESSAGE_MAX];
            let length = state.read_message(message, &mut out).map_err(map_error)?;
            out.truncate(length);
            Ok(out)
        })
    }

    pub fn is_finished(&self) -> bool {
        self.state.as_ref().is_some_and(snow::HandshakeState::is_handshake_finished)
    }

    pub fn is_write_turn(&self) -> bool {
        self.state.as_ref().is_some_and(snow::HandshakeState::is_my_turn)
    }

    /// h: the comparison codes, REQUEST_BY_ID's signature and CPace's sid all bind to it.
    pub fn handshake_hash(&self) -> Option<[u8; HASH_LEN]> {
        let hash = self.state.as_ref()?.get_handshake_hash();
        hash.try_into().ok()
    }

    /// The remote static key once a message carried it (or IK's pre-message gave it).
    pub fn remote_static(&self) -> Option<[u8; DH_LEN]> {
        self.state.as_ref()?.get_remote_static()?.try_into().ok()
    }

    /// Split(), after the last message.
    pub fn into_transport(mut self) -> Result<Transport, NoiseError> {
        let state = self.state.take().ok_or(NoiseError::State)?;
        if !state.is_handshake_finished() {
            return Err(NoiseError::State);
        }
        Ok(Transport { state: state.into_stateless_transport_mode().map_err(map_error)?, sending: 0, receiving: 0 })
    }
}

/// The two CipherStates after Split(), oriented so `encrypt` uses this side's sending key. The nonces are counted here
/// (snow's stateless transport takes them explicitly), so a batch of messages can be sealed or opened on several cores
/// at once ([`Transport::encrypt_many`], [`Transport::decrypt_many`]) with exactly the nonces one at a time would use.
pub struct Transport {
    state: snow::StatelessTransportState,
    sending: u64,
    receiving: u64,
}

impl std::fmt::Debug for Transport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Transport")
            .field("sending_nonce", &self.sending)
            .field("receiving_nonce", &self.receiving)
            .finish()
    }
}

/// A batch goes to other cores only when it is worth a thread: at least two messages and this many bytes.
const PARALLEL_MIN_BYTES: usize = 96 * 1024;
/// Threads for one batch at most, the caller's included.
const PARALLEL_THREADS: usize = 4;

/// Runs `work` over `items` in order, on up to [`PARALLEL_THREADS`] threads when the batch is large enough.
fn map_batch<T: Sync, R: Send>(items: &[T], bytes: usize, work: impl Fn(usize, &T) -> R + Sync) -> Vec<R> {
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(PARALLEL_THREADS).min(items.len());
    if threads < 2 || bytes < PARALLEL_MIN_BYTES {
        return items.iter().enumerate().map(|(n, item)| work(n, item)).collect();
    }
    let per = items.len().div_ceil(threads);
    std::thread::scope(|scope| {
        let work = &work;
        let mut chunks = items.chunks(per).enumerate();
        let (_, first) = chunks.next().expect("at least one item");
        let handles: Vec<_> = chunks
            .map(|(c, chunk)| {
                scope.spawn(move || {
                    chunk.iter().enumerate().map(|(n, item)| work(c * per + n, item)).collect::<Vec<R>>()
                })
            })
            .collect();
        let mut out: Vec<R> = first.iter().enumerate().map(|(n, item)| work(n, item)).collect();
        for handle in handles {
            out.extend(handle.join().expect("cipher thread"));
        }
        out
    })
}

impl Transport {
    fn seal(&self, nonce: u64, plaintext: &[u8]) -> Result<Vec<u8>, NoiseError> {
        if plaintext.len() > FRAME_PLAINTEXT_MAX {
            return Err(NoiseError::Size);
        }
        let mut out = vec![0u8; plaintext.len() + NOISE_TAG_LEN];
        let length = self.state.write_message(nonce, plaintext, &mut out).map_err(map_error)?;
        out.truncate(length);
        Ok(out)
    }

    fn open(&self, nonce: u64, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        if message.len() > NOISE_MESSAGE_MAX || message.len() < NOISE_TAG_LEN {
            return Err(NoiseError::Size);
        }
        let mut out = vec![0u8; message.len()];
        let length = self.state.read_message(nonce, message, &mut out).map_err(map_error)?;
        out.truncate(length);
        Ok(out)
    }

    /// One frame's plaintext, at most 65,519 bytes, to one transport message.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let message = self.seal(self.sending, plaintext)?;
        self.sending += 1;
        Ok(message)
    }

    /// Several frames to their messages, in order, with the nonces one call each would use; on several cores when the
    /// batch is large (ADR 0018 § 9.2: a lane's parts are sealed in batches). All or nothing: on an error no nonce is
    /// used.
    pub fn encrypt_many(&mut self, plaintexts: &[&[u8]]) -> Result<Vec<Vec<u8>>, NoiseError> {
        let bytes = plaintexts.iter().map(|p| p.len()).sum();
        let first = self.sending;
        let sealed = map_batch(plaintexts, bytes, |n, plaintext| self.seal(first + n as u64, plaintext));
        let sealed: Vec<Vec<u8>> = sealed.into_iter().collect::<Result<_, _>>()?;
        self.sending += sealed.len() as u64;
        Ok(sealed)
    }

    /// Any failure closes the session: there is no resynchronisation.
    pub fn decrypt(&mut self, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let plaintext = self.open(self.receiving, message)?;
        self.receiving += 1;
        Ok(plaintext)
    }

    /// Several messages in order, opened on several cores when the batch is large, as one [`Transport::decrypt`] each
    /// would: the results stop after the first failure, or after the first plaintext `stop` names (a REKEY, after
    /// which the next message is under the new key and must wait for [`Transport::rekey_incoming`]). Only the
    /// messages returned used a nonce; the caller feeds the rest again.
    pub fn decrypt_many(
        &mut self,
        messages: &[&[u8]],
        stop: impl Fn(&[u8]) -> bool,
    ) -> Vec<Result<Vec<u8>, NoiseError>> {
        let bytes = messages.iter().map(|m| m.len()).sum();
        let first = self.receiving;
        let opened = map_batch(messages, bytes, |n, message| self.open(first + n as u64, message));
        let mut out = Vec::with_capacity(opened.len());
        for result in opened {
            let ends = match &result {
                Ok(plaintext) => {
                    self.receiving += 1;
                    stop(plaintext)
                }
                Err(_) => true,
            };
            out.push(result);
            if ends {
                break;
            }
        }
        out
    }

    /// After sending REKEY: `k = first 32 bytes of ENCRYPT(k, 2^64-1, empty, zeros)`; the nonce is kept.
    pub fn rekey_outgoing(&mut self) {
        self.state.rekey_outgoing();
    }

    /// Right after decrypting the peer's REKEY.
    pub fn rekey_incoming(&mut self) {
        self.state.rekey_incoming();
    }

    pub fn sending_nonce(&self) -> u64 {
        self.sending
    }

    pub fn receiving_nonce(&self) -> u64 {
        self.receiving
    }
}

/// Whether this processor encrypts AES-256-GCM in hardware (ARMv8 AES and PMULL, or AES-NI and PCLMULQDQ): the
/// condition for setting capability bit 1 (ADR 0018 § 9.2). Without it AES-GCM is slower than ChaChaPoly and not
/// constant-time, so a side without it never offers AES lanes.
pub fn hardware_aes() -> bool {
    #[cfg(target_arch = "aarch64")]
    {
        std::arch::is_aarch64_feature_detected!("aes") && std::arch::is_aarch64_feature_detected!("pmull")
    }
    #[cfg(target_arch = "x86_64")]
    {
        std::arch::is_x86_feature_detected!("aes") && std::arch::is_x86_feature_detected!("pclmulqdq")
    }
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    {
        false
    }
}

/// An X25519 public key for `private` (clamped at use).
pub fn x25519_public(private: &[u8; DH_LEN]) -> [u8; DH_LEN] {
    MontgomeryPoint::mul_base_clamped(*private).to_bytes()
}
