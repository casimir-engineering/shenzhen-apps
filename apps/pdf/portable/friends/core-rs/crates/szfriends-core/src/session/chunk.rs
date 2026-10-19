//! Windowed CHUNK flow, PROGRESS and resume (`SZFriendsChunkFlow.m`; ADR 0001 § Files, § Resume and route
//! migration). Pure state machines: the service reads file bytes, writes them to the store and sends the frames.
//!
//! Offsets and lengths are checked against what this session agreed, never trusted from the peer: a CHUNK must
//! continue exactly where the last one ended, stay inside the offered size and inside the window past the last
//! PROGRESS, so a peer can neither make the recipient seek nor make it buffer more than the window. Resume and route
//! migration are one mechanism: a new session gets a new sender starting at the offset of the recipient's PROGRESS.

use std::fmt;

use szfriends_wire::consts::{CHUNK_BYTES_BLUETOOTH, CHUNK_BYTES_WIFI, SEND_WINDOW_BLUETOOTH, SEND_WINDOW_WIFI};
use szfriends_wire::{tag, Frame, FrameType, RouteMethod};

/// A frame that breaks the flow: close the session (`SZFriendsSessionErrorProtocol`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FlowError {
    AnotherTransfer,
    WentBackwards,
    NeverSent,
    NotContiguous,
    TooLarge,
    BeyondWindow,
    EarlyDone,
}

impl fmt::Display for FlowError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::AnotherTransfer => "frame for another transfer",
            Self::WentBackwards => "PROGRESS went backwards",
            Self::NeverSent => "PROGRESS for bytes never sent",
            Self::NotContiguous => "CHUNK does not continue where the last one ended",
            Self::TooLarge => "CHUNK larger than the route allows or past the offered size",
            Self::BeyondWindow => "CHUNK beyond the window past the last PROGRESS",
            Self::EarlyDone => "DONE before every byte arrived",
        })
    }
}

impl std::error::Error for FlowError {}

/// Bluetooth gets the small chunk and window, every other route the Wi-Fi ones.
pub fn chunk_bytes_for_route(route: RouteMethod) -> usize {
    if route == RouteMethod::Bluetooth {
        CHUNK_BYTES_BLUETOOTH
    } else {
        CHUNK_BYTES_WIFI
    }
}

pub fn send_window_for_route(route: RouteMethod) -> u64 {
    if route == RouteMethod::Bluetooth {
        SEND_WINDOW_BLUETOOTH
    } else {
        SEND_WINDOW_WIFI
    }
}

fn parameters_valid(offer_id: &[u8], size: u64, offset: u64, chunk_bytes: usize, window: u64) -> bool {
    offer_id.len() == 16
        && offset <= size
        && chunk_bytes > 0
        && chunk_bytes <= CHUNK_BYTES_WIFI
        && chunk_bytes as u64 <= window
}

fn progress_frame(offer_id: &[u8; 16], offset: u64) -> Frame {
    Frame::new(FrameType::Progress).with(tag::ID, offer_id.to_vec()).with(tag::OFFSET, offset.to_be_bytes())
}

fn id_matches(frame: &Frame, frame_type: FrameType, offer_id: &[u8; 16]) -> bool {
    frame.frame_type == frame_type && frame.get(tag::ID) == Some(offer_id.as_slice())
}

/// The sending side of one accepted transfer within one session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkSender {
    offer_id: [u8; 16],
    size: u64,
    sent: u64,
    durable: u64,
    chunk_bytes: usize,
    window: u64,
}

impl ChunkSender {
    /// `None` when `resume_offset` is past `size`, or `chunk_bytes` is 0, above 60 KiB or larger than the window.
    pub fn new(offer_id: &[u8], size: u64, resume_offset: u64, chunk_bytes: usize, window: u64) -> Option<Self> {
        parameters_valid(offer_id, size, resume_offset, chunk_bytes, window).then(|| Self {
            offer_id: offer_id.try_into().expect("16 bytes"),
            size,
            sent: resume_offset,
            durable: resume_offset,
            chunk_bytes,
            window,
        })
    }

    pub fn for_route(offer_id: &[u8], size: u64, resume_offset: u64, route: RouteMethod) -> Option<Self> {
        Self::new(offer_id, size, resume_offset, chunk_bytes_for_route(route), send_window_for_route(route))
    }

    pub fn offer_id(&self) -> &[u8; 16] {
        &self.offer_id
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    /// Bytes handed out in CHUNKs so far.
    pub fn sent_offset(&self) -> u64 {
        self.sent
    }

    /// The recipient's latest PROGRESS.
    pub fn durable_offset(&self) -> u64 {
        self.durable
    }

    /// Send DONE now.
    pub fn all_sent(&self) -> bool {
        self.sent == self.size
    }

    /// PROGRESS reached the size.
    pub fn acknowledged(&self) -> bool {
        self.durable == self.size
    }

    /// The next CHUNK's range while the window has room. Full-size chunks only, except the file's last: one that
    /// would cross the window waits for the next PROGRESS rather than going out short.
    pub fn next_chunk(&self) -> Option<(u64, usize)> {
        if self.sent >= self.size {
            return None;
        }
        let next = (self.size - self.sent).min(self.chunk_bytes as u64) as usize;
        (self.sent.saturating_add(next as u64) <= self.durable.saturating_add(self.window)).then_some((self.sent, next))
    }

    /// The CHUNK for exactly that range, advancing; `None`, advancing nothing, for any other length.
    pub fn chunk_frame(&mut self, data: &[u8]) -> Option<Frame> {
        let (offset, length) = self.next_chunk()?;
        if data.len() != length {
            return None;
        }
        self.sent += length as u64;
        Some(
            Frame::new(FrameType::Chunk)
                .with(tag::ID, self.offer_id.to_vec())
                .with(tag::OFFSET, offset.to_be_bytes())
                .with(tag::DATA, data.to_vec()),
        )
    }

    /// PROGRESS from the recipient: an error for another offer, a step backwards or bytes never sent.
    pub fn handle_progress(&mut self, frame: &Frame) -> Result<(), FlowError> {
        let offset = frame.integer(tag::OFFSET);
        let Some(offset) = offset.filter(|_| id_matches(frame, FrameType::Progress, &self.offer_id)) else {
            return Err(FlowError::AnotherTransfer);
        };
        if offset < self.durable {
            return Err(FlowError::WentBackwards);
        }
        if offset > self.sent {
            return Err(FlowError::NeverSent);
        }
        self.durable = offset;
        Ok(())
    }
}

/// The receiving side of one accepted transfer within one session. A CHUNK whose offer has no receiver is
/// unsolicited: the service closes the session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkReceiver {
    offer_id: [u8; 16],
    size: u64,
    received: u64,
    reported: u64,
    chunk_bytes: usize,
    window: u64,
}

impl ChunkReceiver {
    /// `verified_offset`: bytes already written, fsynced and committed; the session starts by sending
    /// [`ChunkReceiver::resume_progress_frame`] so the sender continues from there.
    pub fn new(offer_id: &[u8], size: u64, verified_offset: u64, chunk_bytes: usize, window: u64) -> Option<Self> {
        parameters_valid(offer_id, size, verified_offset, chunk_bytes, window).then(|| Self {
            offer_id: offer_id.try_into().expect("16 bytes"),
            size,
            received: verified_offset,
            reported: verified_offset,
            chunk_bytes,
            window,
        })
    }

    pub fn for_route(offer_id: &[u8], size: u64, verified_offset: u64, route: RouteMethod) -> Option<Self> {
        Self::new(offer_id, size, verified_offset, chunk_bytes_for_route(route), send_window_for_route(route))
    }

    pub fn offer_id(&self) -> &[u8; 16] {
        &self.offer_id
    }

    /// Bytes accepted from CHUNKs.
    pub fn received_offset(&self) -> u64 {
        self.received
    }

    /// The last PROGRESS sent.
    pub fn reported_offset(&self) -> u64 {
        self.reported
    }

    pub fn complete(&self) -> bool {
        self.received == self.size
    }

    pub fn resume_progress_frame(&self) -> Frame {
        progress_frame(&self.offer_id, self.reported)
    }

    /// Checks a CHUNK: same offer, offset exactly where the last ended, 1 to chunk-size bytes, inside the size and
    /// inside the window past the last PROGRESS. Returns the data and advances.
    pub fn accept_chunk<'a>(&mut self, frame: &'a Frame) -> Result<&'a [u8], FlowError> {
        let (offset, data) = (frame.integer(tag::OFFSET), frame.get(tag::DATA));
        let (Some(offset), Some(data)) = (offset, data) else { return Err(FlowError::AnotherTransfer) };
        if !id_matches(frame, FrameType::Chunk, &self.offer_id) {
            return Err(FlowError::AnotherTransfer);
        }
        if offset != self.received {
            return Err(FlowError::NotContiguous);
        }
        if data.len() > self.chunk_bytes || data.len() as u64 > self.size - self.received {
            return Err(FlowError::TooLarge);
        }
        if self.received + data.len() as u64 > self.reported.saturating_add(self.window) {
            return Err(FlowError::BeyondWindow);
        }
        self.received += data.len() as u64;
        Ok(data)
    }

    /// PROGRESS for bytes the store made durable; `None` when behind the last report or past what was received.
    pub fn progress_frame(&mut self, durable_offset: u64) -> Option<Frame> {
        if durable_offset < self.reported || durable_offset > self.received {
            return None;
        }
        self.reported = durable_offset;
        Some(progress_frame(&self.offer_id, durable_offset))
    }

    /// DONE once every byte arrived: its digest, for the store's whole-file check.
    pub fn accept_done(&self, frame: &Frame) -> Result<[u8; 32], FlowError> {
        let digest = frame.get(tag::DIGEST).filter(|_| id_matches(frame, FrameType::Done, &self.offer_id));
        let Some(digest) = digest else { return Err(FlowError::AnotherTransfer) };
        if !self.complete() {
            return Err(FlowError::EarlyDone);
        }
        Ok(digest.try_into().expect("the codec checked 32 bytes"))
    }
}
