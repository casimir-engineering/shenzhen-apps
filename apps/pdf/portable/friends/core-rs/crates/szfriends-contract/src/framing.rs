//! PROTOCOL.md § Framing: one JSON object per line, at most 8 MiB, never pretty-printed.

use serde_json::Value;

/// A frame is at most 8,388,608 bytes, not counting the line feed.
pub const FRAME_MAX: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FramingError {
    /// A pending line exceeded the cap: `goodbye` with `protocol_error`, code `frame_too_large`, then close.
    FrameTooLarge,
    /// A line that is not a JSON object: `goodbye` with `protocol_error`, code `bad_frame`, then close.
    BadFrame,
}

/// Encodes one frame: compact JSON (a line feed inside a string is escaped as `\n`), then a line feed. Refuses a frame
/// over the cap rather than sending it.
pub fn encode(frame: &Value) -> Result<Vec<u8>, FramingError> {
    if !frame.is_object() {
        return Err(FramingError::BadFrame);
    }
    let mut bytes = serde_json::to_vec(frame).map_err(|_| FramingError::BadFrame)?;
    if bytes.len() > FRAME_MAX {
        return Err(FramingError::FrameTooLarge);
    }
    bytes.push(b'\n');
    Ok(bytes)
}

/// Splits a stream into frames. Stops buffering as soon as a pending line exceeds the cap. Empty lines are skipped;
/// whitespace around the object, a carriage return included, is tolerated. After an error the reader is dead.
#[derive(Debug, Default)]
pub struct LineReader {
    pending: Vec<u8>,
    failed: bool,
}

impl LineReader {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, mut bytes: &[u8]) -> Result<Vec<Value>, FramingError> {
        if self.failed {
            return Err(FramingError::BadFrame);
        }
        let mut frames = Vec::new();
        while let Some(end) = bytes.iter().position(|&b| b == b'\n') {
            let fits = self.pending.len() + end <= FRAME_MAX;
            if fits {
                self.pending.extend_from_slice(&bytes[..end]);
            }
            bytes = &bytes[end + 1..];
            let line = std::mem::take(&mut self.pending);
            if !fits {
                return self.fail(FramingError::FrameTooLarge);
            }
            let text = line.trim_ascii();
            if text.is_empty() {
                continue;
            }
            match serde_json::from_slice::<Value>(text) {
                Ok(frame) if frame.is_object() => frames.push(frame),
                _ => return self.fail(FramingError::BadFrame),
            }
        }
        if self.pending.len() + bytes.len() > FRAME_MAX {
            return self.fail(FramingError::FrameTooLarge);
        }
        self.pending.extend_from_slice(bytes);
        Ok(frames)
    }

    fn fail(&mut self, error: FramingError) -> Result<Vec<Value>, FramingError> {
        self.failed = true;
        self.pending = Vec::new();
        Err(error)
    }
}
