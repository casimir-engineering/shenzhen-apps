//! A batch of transport messages whose nonces were counted ([`super::Transport::reserve`]) and that are sealed later,
//! wherever the link writes them: the session's own thread decides the order, a link's writer thread spends the
//! cores. The ciphers are the ones in use when the nonces were counted; a REKEY after that makes new ones.

use std::sync::Arc;

use snow::types::Cipher;
use szfriends_wire::consts::NOISE_TAG_LEN;

use super::transport::{PARALLEL_MIN_BYTES, PARALLEL_THREADS};

/// Frames counted in order from `first`, under `cipher`, or `from_second` from nonce 1 on when the session switches
/// to AES-256-GCM within this job (as the transport's own `cipher_for`).
pub struct SealJob {
    first: u64,
    plaintexts: Vec<Vec<u8>>,
    cipher: Arc<dyn Cipher>,
    from_second: Option<Arc<dyn Cipher>>,
    parallel: bool,
}

impl std::fmt::Debug for SealJob {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SealJob").field("first", &self.first).field("messages", &self.plaintexts.len()).finish()
    }
}

impl SealJob {
    pub(super) fn new(
        first: u64,
        plaintexts: Vec<Vec<u8>>,
        cipher: Arc<dyn Cipher>,
        from_second: Option<Arc<dyn Cipher>>,
        parallel: bool,
    ) -> Self {
        Self { first, plaintexts, cipher, from_second, parallel }
    }

    /// The bytes [`SealJob::seal_framed`] gives: each message's two-byte length, its ciphertext and tag.
    pub fn framed_len(&self) -> usize {
        self.plaintexts.iter().map(|p| p.len() + NOISE_TAG_LEN + 2).sum()
    }

    pub fn messages(&self) -> usize {
        self.plaintexts.len()
    }

    fn cipher_for(&self, nonce: u64) -> &dyn Cipher {
        match &self.from_second {
            Some(aes) if nonce >= 1 => aes.as_ref(),
            _ => self.cipher.as_ref(),
        }
    }

    /// Sealed and framed as the link carries them, appended to `out`; large jobs on several cores.
    pub fn seal_framed_into(&self, out: &mut Vec<u8>) {
        let start = out.len();
        let total = self.framed_len();
        out.resize(start + total, 0);
        let mut regions: Vec<(u64, &[u8], &mut [u8])> = Vec::with_capacity(self.plaintexts.len());
        let mut rest = &mut out[start..];
        for (n, plaintext) in self.plaintexts.iter().enumerate() {
            let (region, tail) = rest.split_at_mut(plaintext.len() + NOISE_TAG_LEN + 2);
            regions.push((self.first + n as u64, plaintext.as_slice(), region));
            rest = tail;
        }
        let seal = |(nonce, plaintext, region): &mut (u64, &[u8], &mut [u8])| {
            let length = plaintext.len() + NOISE_TAG_LEN;
            region[..2].copy_from_slice(&(length as u16).to_be_bytes());
            let written = self.cipher_for(*nonce).encrypt(*nonce, &[], plaintext, &mut region[2..]);
            debug_assert_eq!(written, length);
        };
        let threads = if self.parallel {
            std::thread::available_parallelism().map_or(1, |n| n.get()).min(PARALLEL_THREADS).min(regions.len())
        } else {
            1
        };
        if threads < 2 || total < PARALLEL_MIN_BYTES {
            regions.iter_mut().for_each(seal);
            return;
        }
        let per = regions.len().div_ceil(threads);
        std::thread::scope(|scope| {
            let seal = &seal;
            let mut chunks = regions.chunks_mut(per);
            let first = chunks.next().expect("at least one message");
            for chunk in chunks {
                scope.spawn(move || chunk.iter_mut().for_each(seal));
            }
            first.iter_mut().for_each(seal);
        });
    }

    /// [`SealJob::seal_framed_into`] a buffer of its own.
    pub fn seal_framed(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.framed_len());
        self.seal_framed_into(&mut out);
        out
    }
}
