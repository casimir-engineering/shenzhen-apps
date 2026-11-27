//! The transport after a handshake's Split() (`super::Handshake::into_transport`): one CipherState per direction,
//! nonces counted here so batches can be sealed and opened on several cores, REKEY, and a session's switch to
//! AES-256-GCM from its second message in each direction (ADR 0018 § 9.2 (c)).

use snow::params::CipherChoice;
use snow::resolvers::{CryptoResolver, DefaultResolver};
use snow::types::Cipher;
use zeroize::Zeroizing;

use szfriends_wire::consts::{FRAME_PLAINTEXT_MAX, NOISE_MESSAGE_MAX, NOISE_TAG_LEN};
use szfriends_wire::NoiseCipher;

use super::{map_error, NoiseError};

/// `"SZFriends AES session v1"`: what the AES-256-GCM key of a session's later messages is derived with (ADR 0018
/// § 9.2 (c), [`Transport::aes_from_second_message`]).
pub const AES_SESSION_LABEL: &[u8; 24] = b"SZFriends AES session v1";

fn resolve_cipher(choice: NoiseCipher) -> Result<Box<dyn Cipher>, NoiseError> {
    let choice = match choice {
        NoiseCipher::ChaChaPoly => CipherChoice::ChaChaPoly,
        NoiseCipher::AesGcm => CipherChoice::AESGCM,
    };
    DefaultResolver.resolve_cipher(&choice).ok_or(NoiseError::Argument)
}

/// One direction's CipherState: its key, kept for REKEY and for the switch to AES-256-GCM, and the cipher set to it.
struct Direction {
    key: Zeroizing<[u8; 32]>,
    cipher: Box<dyn Cipher>,
    /// Armed by [`Transport::aes_from_second_message`] and not yet switched: messages from nonce 1 on go under
    /// AES-256-GCM with the key derived from `key` as it is when message 1 is first sealed or opened.
    aes_from_second: bool,
    /// That cipher, made for a batch that reaches nonce 1, until a message at nonce 1 or later was counted.
    next: Option<(Zeroizing<[u8; 32]>, Box<dyn Cipher>)>,
}

impl Direction {
    fn new(choice: NoiseCipher, key: Zeroizing<[u8; 32]>) -> Result<Self, NoiseError> {
        let mut cipher = resolve_cipher(choice)?;
        cipher.set(&key);
        Ok(Self { key, cipher, aes_from_second: false, next: None })
    }

    fn cipher_for(&self, nonce: u64) -> &dyn Cipher {
        match &self.next {
            Some((_, aes)) if nonce >= 1 => aes.as_ref(),
            _ => self.cipher.as_ref(),
        }
    }

    /// Before sealing or opening messages up to nonce `last`: the AES cipher, if this direction switches by then.
    fn prepare(&mut self, last: u64) -> Result<(), NoiseError> {
        if !self.aes_from_second || self.next.is_some() || last < 1 {
            return Ok(());
        }
        use blake2::digest::{KeyInit, Mac};
        let mut mac = <blake2::Blake2bMac<blake2::digest::consts::U32> as KeyInit>::new_from_slice(&self.key[..])
            .map_err(|_| NoiseError::Argument)?;
        mac.update(AES_SESSION_LABEL);
        let key = Zeroizing::new(<[u8; 32]>::from(mac.finalize().into_bytes()));
        let mut aes = resolve_cipher(NoiseCipher::AesGcm)?;
        aes.set(&key);
        self.next = Some((key, aes));
        Ok(())
    }

    /// After counting messages up to `counter` (the next nonce): once message 1 was counted, AES is the cipher.
    fn commit(&mut self, counter: u64) {
        if counter >= 2 {
            if let Some((key, cipher)) = self.next.take() {
                self.key = key;
                self.cipher = cipher;
                self.aes_from_second = false;
            }
        }
    }

    /// `k = first 32 bytes of ENCRYPT(k, 2^64-1, empty, zeros)` with the cipher in use; the nonce is kept. A switch
    /// prepared but not yet used is made again from the new key.
    fn rekey(&mut self) {
        self.next = None;
        let mut out = Zeroizing::new([0u8; 32 + NOISE_TAG_LEN]);
        self.cipher.encrypt(u64::MAX, &[], &[0u8; 32], &mut out[..]);
        self.key.copy_from_slice(&out[..32]);
        self.cipher.set(&self.key);
    }
}

/// The two CipherStates after Split(), oriented so `encrypt` uses this side's sending key. The nonces are counted here
/// (snow's stateless transport takes them explicitly), so a batch of messages can be sealed or opened on several cores
/// at once ([`Transport::encrypt_many`], [`Transport::decrypt_many`]) with exactly the nonces one at a time would use.
pub struct Transport {
    send: Direction,
    receive: Direction,
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
    /// Split()'s two keys, this side's sending key first.
    pub(super) fn from_split(
        cipher: NoiseCipher,
        send: Zeroizing<[u8; 32]>,
        receive: Zeroizing<[u8; 32]>,
    ) -> Result<Self, NoiseError> {
        Ok(Transport {
            send: Direction::new(cipher, send)?,
            receive: Direction::new(cipher, receive)?,
            sending: 0,
            receiving: 0,
        })
    }

    fn seal(&self, nonce: u64, plaintext: &[u8]) -> Result<Vec<u8>, NoiseError> {
        if plaintext.len() > FRAME_PLAINTEXT_MAX {
            return Err(NoiseError::Size);
        }
        if nonce == u64::MAX {
            return Err(NoiseError::Nonce);
        }
        let mut out = vec![0u8; plaintext.len() + NOISE_TAG_LEN];
        let length = self.send.cipher_for(nonce).encrypt(nonce, &[], plaintext, &mut out);
        out.truncate(length);
        Ok(out)
    }

    fn open(&self, nonce: u64, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        if message.len() > NOISE_MESSAGE_MAX || message.len() < NOISE_TAG_LEN {
            return Err(NoiseError::Size);
        }
        if nonce == u64::MAX {
            return Err(NoiseError::Nonce);
        }
        let mut out = vec![0u8; message.len() - NOISE_TAG_LEN];
        let length = self.receive.cipher_for(nonce).decrypt(nonce, &[], message, &mut out).map_err(map_error)?;
        out.truncate(length);
        Ok(out)
    }

    /// ADR 0018 § 9.2 (c), a session whose two handshakes set capability bit 7: in each direction the first message
    /// stays under the handshake's cipher (ChaChaPoly) and every later one is AES-256-GCM, Noise's `AESGCM` nonces, under
    /// `BLAKE2b-256(key: k, "SZFriends AES session v1")`, k being that direction's key when its message 1 goes. REKEY
    /// after that rekeys the AES key the same way. Called right after Split(), before any message.
    pub fn aes_from_second_message(&mut self) {
        self.send.aes_from_second = true;
        self.receive.aes_from_second = true;
    }

    /// One frame's plaintext, at most 65,519 bytes, to one transport message.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, NoiseError> {
        self.send.prepare(self.sending)?;
        let message = self.seal(self.sending, plaintext)?;
        self.sending += 1;
        self.send.commit(self.sending);
        Ok(message)
    }

    /// Several frames to their messages, in order, with the nonces one call each would use; on several cores when the
    /// batch is large (ADR 0018 § 9.2: a lane's parts are sealed in batches). All or nothing: on an error no nonce is
    /// used.
    pub fn encrypt_many(&mut self, plaintexts: &[&[u8]]) -> Result<Vec<Vec<u8>>, NoiseError> {
        let bytes = plaintexts.iter().map(|p| p.len()).sum();
        let first = self.sending;
        self.send.prepare(first + plaintexts.len().saturating_sub(1) as u64)?;
        let sealed = map_batch(plaintexts, bytes, |n, plaintext| self.seal(first + n as u64, plaintext));
        let sealed: Vec<Vec<u8>> = sealed.into_iter().collect::<Result<_, _>>()?;
        self.sending += sealed.len() as u64;
        self.send.commit(self.sending);
        Ok(sealed)
    }

    /// Any failure closes the session: there is no resynchronisation.
    pub fn decrypt(&mut self, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        self.receive.prepare(self.receiving)?;
        let plaintext = self.open(self.receiving, message)?;
        self.receiving += 1;
        self.receive.commit(self.receiving);
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
        // Message 0 alone while the switch to AES is ahead: it may be a REKEY, which changes the key AES comes from.
        if self.receive.aes_from_second && first == 0 && messages.len() > 1 {
            return vec![self.decrypt(messages[0])];
        }
        if let Err(error) = self.receive.prepare(first + messages.len().saturating_sub(1) as u64) {
            return vec![Err(error)];
        }
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
        self.receive.commit(self.receiving);
        out
    }

    /// After sending REKEY: `k = first 32 bytes of ENCRYPT(k, 2^64-1, empty, zeros)`; the nonce is kept.
    pub fn rekey_outgoing(&mut self) {
        self.send.rekey();
    }

    /// Right after decrypting the peer's REKEY.
    pub fn rekey_incoming(&mut self) {
        self.receive.rekey();
    }

    pub fn sending_nonce(&self) -> u64 {
        self.sending
    }

    pub fn receiving_nonce(&self) -> u64 {
        self.receiving
    }
}
