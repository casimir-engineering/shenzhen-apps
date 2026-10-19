//! One reliable, ordered data channel as a byte stream (`SZFriendsOnlineDataChannelStream.m`; ADR 0009: ADR 0001 runs
//! unchanged above it). Messages arrive in order on [`ChannelStream::incoming`], straight from the stack's thread;
//! writes larger than a message are split, and a write waits while the channel buffers more than the high-water mark,
//! so ADR 0001's send window, not the channel, bounds what is in flight.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use szfriends_datachannel_sys::DataChannel;

use super::MESSAGE_MAX;

pub const HIGH_WATER: usize = 1024 * 1024;
/// What a channel may receive before its owner takes the stream; past it the stream ends.
const UNSTARTED_MAX: usize = 256 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum StreamInput {
    Data(Vec<u8>),
    /// The path ended: the peer closed, or the connection failed or closed.
    Closed,
}

/// Where each channel's messages go: a stream's receiver once one exists, held until then.
#[derive(Debug, Default)]
pub(crate) struct Sinks {
    sinks: HashMap<i32, Sender<StreamInput>>,
    pending: HashMap<i32, (Vec<Vec<u8>>, usize)>,
}

pub(crate) type SharedSinks = Arc<Mutex<Sinks>>;

impl Sinks {
    /// From the stack's thread: one message for `channel`.
    pub fn deliver(sinks: &SharedSinks, channel: i32, data: Vec<u8>) {
        let mut sinks = sinks.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(sink) = sinks.sinks.get(&channel) {
            let _ = sink.send(StreamInput::Data(data));
            return;
        }
        let entry = sinks.pending.entry(channel).or_default();
        if entry.1 + data.len() <= UNSTARTED_MAX {
            entry.1 += data.len();
            entry.0.push(data);
        }
    }

    /// Gives `channel` its stream's sender, delivering what arrived before it.
    pub fn attach(sinks: &SharedSinks, channel: i32, sink: Sender<StreamInput>) {
        let mut sinks = sinks.lock().unwrap_or_else(|e| e.into_inner());
        for data in sinks.pending.remove(&channel).map(|p| p.0).unwrap_or_default() {
            let _ = sink.send(StreamInput::Data(data));
        }
        sinks.sinks.insert(channel, sink);
    }

    /// The path ended: the stream hears it after every message that came before.
    pub fn end(sinks: &SharedSinks, channel: i32) {
        let mut sinks = sinks.lock().unwrap_or_else(|e| e.into_inner());
        sinks.pending.remove(&channel);
        if let Some(sink) = sinks.sinks.remove(&channel) {
            let _ = sink.send(StreamInput::Closed);
        }
    }

    pub fn end_all(sinks: &SharedSinks) {
        let channels: Vec<i32> = sinks.lock().unwrap_or_else(|e| e.into_inner()).sinks.keys().copied().collect();
        for channel in channels {
            Self::end(sinks, channel);
        }
    }
}

/// The writing half; cheap to clone. Closing it closes the channel for both sides.
#[derive(Clone)]
pub struct StreamWriter {
    channel: Arc<DataChannel>,
    max: usize,
    closed: Arc<AtomicBool>,
    on_close: Arc<dyn Fn() + Send + Sync>,
}

impl std::fmt::Debug for StreamWriter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StreamWriter").field("channel", &self.channel.id()).field("max", &self.max).finish()
    }
}

impl StreamWriter {
    pub(crate) fn new(channel: Arc<DataChannel>, on_close: Arc<dyn Fn() + Send + Sync>) -> Self {
        let negotiated = channel.max_message_size();
        let max = if negotiated == 0 { MESSAGE_MAX } else { negotiated.min(MESSAGE_MAX) };
        Self { channel, max, closed: Arc::new(AtomicBool::new(false)), on_close }
    }

    /// Sends `bytes` as one message when they fit, else as consecutive messages of the largest size; returns once the
    /// channel's buffer is below the high-water mark again. `false` once the channel is closed.
    pub fn write(&self, bytes: &[u8]) -> bool {
        for chunk in bytes.chunks(self.max.max(1)) {
            if self.closed.load(Ordering::SeqCst) || self.channel.send(chunk).is_err() {
                return false;
            }
        }
        while self.channel.buffered_amount() > HIGH_WATER {
            if self.closed.load(Ordering::SeqCst) {
                return false;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        !self.closed.load(Ordering::SeqCst)
    }

    /// One whole message (the links protocol writes one record per message).
    pub fn write_message(&self, message: &[u8]) -> bool {
        message.len() <= self.max && self.write(message)
    }

    /// Waits, at most `timeout`, until everything written has left the channel's buffer.
    pub fn drain(&self, timeout: Duration) {
        let deadline = std::time::Instant::now() + timeout;
        while self.channel.buffered_amount() > 0 && std::time::Instant::now() < deadline && !self.is_closed() {
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    pub fn max_message(&self) -> usize {
        self.max
    }

    /// Closes this path only. Idempotent.
    pub fn close(&self) {
        if !self.closed.swap(true, Ordering::SeqCst) {
            self.channel.close();
            (self.on_close)();
        }
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }
}

/// One stream: the messages in order, and the writing half.
#[derive(Debug)]
pub struct ChannelStream {
    pub incoming: Receiver<StreamInput>,
    pub writer: StreamWriter,
}
