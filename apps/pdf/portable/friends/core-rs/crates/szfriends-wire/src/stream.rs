//! The byte stream under Noise: the initiator's preamble, the prologue it fixes, and 16-bit length-prefixed messages
//! (ADR 0001 § Wire format). Length 0, or a length over the limit, closes the session; there is no
//! resynchronisation.

use crate::consts::{NOISE_MESSAGE_MAX, PROLOGUE_LABEL, SESSION_MAJOR};
use crate::error::WireError;
use crate::types::Pattern;

/// `'S' 'Z' major pattern`, sent by the initiator before message 1.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Preamble {
    pub pattern: Pattern,
}

impl Preamble {
    pub const LEN: usize = 4;

    pub fn bytes(self) -> [u8; 4] {
        [b'S', b'Z', SESSION_MAJOR, self.pattern as u8]
    }

    /// An unknown major or pattern closes the connection.
    pub fn parse(bytes: &[u8]) -> Result<Self, WireError> {
        match bytes {
            [b'S', b'Z', major, pattern] if *major == SESSION_MAJOR => {
                Pattern::from_byte(*pattern).map(|pattern| Self { pattern }).ok_or(WireError::Preamble)
            }
            _ => Err(WireError::Preamble),
        }
    }
}

/// `"SZFriends session\0" || preamble`, so a tampered preamble fails the handshake instead of downgrading it.
pub fn prologue(preamble: Preamble) -> [u8; 22] {
    let mut out = [0u8; 22];
    out[..18].copy_from_slice(PROLOGUE_LABEL);
    out[18..].copy_from_slice(&preamble.bytes());
    out
}

/// Appends `message` with its 16-bit big-endian length.
pub fn write_message(output: &mut Vec<u8>, message: &[u8]) -> Result<(), WireError> {
    if message.is_empty() || message.len() > NOISE_MESSAGE_MAX {
        return Err(WireError::MessageLength(message.len()));
    }
    output.extend_from_slice(&(message.len() as u16).to_be_bytes());
    output.extend_from_slice(message);
    Ok(())
}

/// Splits an incoming byte stream into Noise messages. Feed it whatever the route delivered; between calls it keeps
/// only the bytes of one unfinished message, and it refuses a bad length as soon as the two length bytes arrive. A
/// responder sets [`MessageReader::set_limit`] to `RESPONDER_HANDSHAKE_MAX` while reading handshake messages.
#[derive(Debug)]
pub struct MessageReader {
    buffer: Vec<u8>,
    limit: usize,
    failed: bool,
}

impl Default for MessageReader {
    fn default() -> Self {
        Self { buffer: Vec::new(), limit: NOISE_MESSAGE_MAX, failed: false }
    }
}

impl MessageReader {
    pub fn new() -> Self {
        Self::default()
    }

    /// The largest message accepted from now on (at most 65,535).
    pub fn set_limit(&mut self, limit: usize) {
        self.limit = limit.min(NOISE_MESSAGE_MAX);
    }

    /// Buffers `bytes` and returns every complete message. After an error the reader is dead and refuses everything,
    /// as the session it belongs to closes.
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>, WireError> {
        if self.failed {
            return Err(WireError::MessageLength(0));
        }
        self.buffer.extend_from_slice(bytes);
        let mut messages = Vec::new();
        loop {
            if self.buffer.len() < 2 {
                return Ok(messages);
            }
            let length = usize::from(u16::from_be_bytes([self.buffer[0], self.buffer[1]]));
            if length == 0 || length > self.limit {
                self.failed = true;
                self.buffer.clear();
                return Err(WireError::MessageLength(length));
            }
            if self.buffer.len() < 2 + length {
                return Ok(messages);
            }
            messages.push(self.buffer[2..2 + length].to_vec());
            self.buffer.drain(..2 + length);
        }
    }

    /// Bytes received but not yet part of a whole message.
    pub fn pending(&self) -> usize {
        self.buffer.len()
    }
}
