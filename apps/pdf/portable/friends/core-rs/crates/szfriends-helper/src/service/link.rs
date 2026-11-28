//! A session's link: a reader thread and a writer thread feeding the service's one event loop, so neither side's
//! writes can block its reads (two peers filling each other's buffers would deadlock a single thread). Over TCP,
//! closing writes everything still queued, sends FIN, and reads on for up to two seconds so the peer's last bytes are
//! not answered with a reset (the interop suite's link, which this mirrors). Over a stream the platform owns (a
//! Bluetooth channel), bytes cross through its channels and the end is said in order after the last write, each
//! write only as fast as the radio carries them (`radio_pace.rs`), so the platform's stack never holds seconds of file
//! data ahead of a message. A friend
//! reached online gets the same two threads over the data channel's stream. The writer seals the session's transport
//! messages itself (`LinkWrite`), so the service's thread only orders them, and over TCP gathers the writes waiting
//! into one.

use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use szfriends_core::session::LinkWrite;
#[cfg(feature = "online")]
use szfriends_online::transport::{ChannelStream, StreamInput};

use super::radio_pace::RadioPace;
use crate::nearby::stream::{LinkStream, PlatformStream};

/// What the link reports to the loop, tagged with the session it belongs to.
#[derive(Debug)]
pub enum LinkEvent {
    Bytes(u64, Vec<u8>),
    /// The peer closed, or the connection failed.
    Eof(u64),
    /// One write handed to the link is on the wire.
    Written(u64),
}

/// A test home's emulated route: the rate this side writes at (`SZFRIENDS_TEST_ROUTE_RATES`), the file (and route
/// name) that silences it (`SZFRIENDS_TEST_ROUTE_SILENCE`), and over a platform's stream how many bytes its stack takes
/// ahead of the radio (`SZFRIENDS_TEST_ROUTE_BUFFERS`) and how long they take to cross (`SZFRIENDS_TEST_ROUTE_DELAYS`).
#[derive(Clone, Debug, Default)]
pub struct Emulated {
    pub rate: Option<f64>,
    pub silence: Option<(std::path::PathBuf, String)>,
    pub buffer: Option<f64>,
    pub delay: Option<Duration>,
}

/// The writer holds each write's bytes for as long as the route's rate would take to carry them, so the session's
/// in-flight budget and window see a slow route. With a buffer, writes return at once until the route holds that many
/// bytes not yet carried, as an Android phone's Bluetooth stack does; each arrives once carried, after the delay.
#[derive(Clone, Debug)]
struct Pace {
    bytes_per_second: f64,
    free_at: Instant,
    /// A test home's silenced route (`SZFRIENDS_TEST_ROUTE_SILENCE`): while this file names the route, nothing is
    /// written, as a route out of range.
    silence: Option<(std::path::PathBuf, String)>,
    buffer: f64,
    delay: Duration,
}

impl Pace {
    fn new(emulated: Option<Emulated>) -> Option<Self> {
        let emulated = emulated?;
        let bytes_per_second = emulated.rate.unwrap_or(f64::INFINITY);
        Some(Self {
            bytes_per_second,
            free_at: Instant::now(),
            silence: emulated.silence,
            buffer: emulated.buffer.unwrap_or(0.0),
            delay: emulated.delay.unwrap_or_default(),
        })
    }

    /// Before a write: nothing leaves while the route is silenced.
    fn silenced(pace: &Option<Self>) {
        let Some((path, route)) = pace.as_ref().and_then(|p| p.silence.as_ref()) else { return };
        while std::fs::read_to_string(path).is_ok_and(|named| named.split_whitespace().any(|n| n == route)) {
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// After a write of `bytes`: waits while the route holds more than its buffer; answers when the last of them is
    /// carried.
    fn carried(pace: &mut Option<Self>, bytes: usize) -> Option<Instant> {
        let pace = pace.as_mut()?;
        let now = Instant::now();
        pace.free_at = pace.free_at.max(now) + Duration::from_secs_f64(bytes as f64 / pace.bytes_per_second);
        let held_until = pace.free_at.checked_sub(Duration::from_secs_f64(pace.buffer / pace.bytes_per_second));
        if let Some(wait) = held_until.and_then(|at| at.checked_duration_since(now)) {
            std::thread::sleep(wait);
        }
        Some(pace.free_at)
    }

    /// Whether writes go through a line of their own (a buffer or a delay to emulate).
    fn lined(pace: &Option<Self>) -> bool {
        pace.as_ref().is_some_and(|p| p.buffer > 0.0 || !p.delay.is_zero())
    }
}

enum WriterMessage {
    Write(LinkWrite),
    Finish,
}

/// One TCP write gathers the writes already waiting, up to this many bytes: fewer, larger system calls.
const GATHER_BYTES: usize = 1 << 20;

/// The writes waiting behind `first` (until `Finish`, kept for after them), sealed here on the writer's thread into
/// one buffer: the session's thread only decided their order and nonces. How many writes it holds, and whether
/// `Finish` came.
fn gather(first: LinkWrite, inbox: &Receiver<WriterMessage>, out: &mut Vec<u8>) -> (usize, bool) {
    out.clear();
    first.append_to(out);
    let mut writes = 1;
    while out.len() < GATHER_BYTES {
        match inbox.try_recv() {
            Ok(WriterMessage::Write(next)) => {
                next.append_to(out);
                writes += 1;
            }
            Ok(WriterMessage::Finish) => return (writes, true),
            Err(_) => break,
        }
    }
    (writes, false)
}

#[derive(Debug)]
pub struct Link {
    writer: Sender<WriterMessage>,
    finished: bool,
    /// A Bluetooth link's pace (`radio_pace.rs`), told of the friend's acknowledgements.
    radio: Option<Arc<RadioPace>>,
}

impl Link {
    /// Starts both threads for `stream`; events go to `events` wrapped by `wrap`. `emulated`: a test home's emulated
    /// route; `None` everywhere else. `bluetooth`: the stream is a Bluetooth channel, paced to its radio
    /// (`radio_pace.rs`) when the platform owns it.
    pub fn start<E: Send + 'static>(
        id: u64,
        stream: LinkStream,
        events: Sender<E>,
        wrap: fn(LinkEvent) -> E,
        emulated: Option<Emulated>,
        bluetooth: bool,
    ) -> std::io::Result<Self> {
        let pace = Pace::new(emulated);
        match stream {
            LinkStream::Tcp(stream) => Self::start_tcp(id, stream, events, wrap, pace),
            LinkStream::Platform(stream) => {
                let radio = bluetooth.then(|| Arc::new(RadioPace::new()));
                let mut link = Self::start_platform(id, stream, events, wrap, pace, radio.clone());
                link.radio = radio;
                Ok(link)
            }
            #[cfg(feature = "online")]
            LinkStream::Online(stream) => Ok(Self::start_online(id, stream, events, wrap, pace)),
        }
    }

    fn start_platform<E: Send + 'static>(
        id: u64,
        stream: PlatformStream,
        events: Sender<E>,
        wrap: fn(LinkEvent) -> E,
        mut pace: Option<Pace>,
        radio: Option<Arc<RadioPace>>,
    ) -> Self {
        let PlatformStream { incoming, mut outgoing } = stream;
        let reader_events = events.clone();
        std::thread::spawn(move || {
            for bytes in incoming {
                if bytes.is_empty() || reader_events.send(wrap(LinkEvent::Bytes(id, bytes))).is_err() {
                    break;
                }
            }
            let _ = reader_events.send(wrap(LinkEvent::Eof(id)));
        });
        // A test home's route with a buffer or a delay: bytes reach the platform once carried, on a line of their own.
        let mut line: Option<Sender<(Instant, Option<Vec<u8>>)>> = None;
        if Pace::lined(&pace) {
            let (to_line, from_writer) = channel::<(Instant, Option<Vec<u8>>)>();
            let delay = pace.as_ref().map(|p| p.delay).unwrap_or_default();
            let mut platform = std::mem::replace(&mut outgoing, Box::new(|_| {}));
            std::thread::spawn(move || {
                for (carried, bytes) in from_writer {
                    if let Some(wait) = (carried + delay).checked_duration_since(Instant::now()) {
                        std::thread::sleep(wait);
                    }
                    let end = bytes.is_none();
                    platform(bytes);
                    if end {
                        return;
                    }
                }
            });
            line = Some(to_line);
        }
        let (writer, inbox) = channel::<WriterMessage>();
        std::thread::spawn(move || {
            // One message at a time, as the platform's channel takes them; sealed here, off the session's thread.
            while let Ok(message) = inbox.recv() {
                match message {
                    WriterMessage::Write(write) => {
                        let bytes = write.into_bytes();
                        let length = bytes.len();
                        if let Some(radio) = &radio {
                            radio.wait_for_room(length);
                        }
                        Pace::silenced(&pace);
                        match &line {
                            Some(line) => {
                                let carried = Pace::carried(&mut pace, length).unwrap_or_else(Instant::now);
                                let _ = line.send((carried, Some(bytes)));
                            }
                            None => {
                                outgoing(Some(bytes));
                                Pace::carried(&mut pace, length);
                            }
                        }
                        if events.send(wrap(LinkEvent::Written(id))).is_err() {
                            return;
                        }
                    }
                    WriterMessage::Finish => break,
                }
            }
            match &line {
                Some(line) => {
                    let _ = line.send((pace.as_ref().map_or_else(Instant::now, |p| p.free_at), None));
                }
                None => outgoing(None),
            }
        });
        Self { writer, finished: false, radio: None }
    }

    fn start_tcp<E: Send + 'static>(
        id: u64,
        stream: TcpStream,
        events: Sender<E>,
        wrap: fn(LinkEvent) -> E,
        mut pace: Option<Pace>,
    ) -> std::io::Result<Self> {
        stream.set_nodelay(true)?;
        let finishing = Arc::new(AtomicBool::new(false));
        let mut reader = stream.try_clone()?;
        let reader_events = events.clone();
        let reader_finishing = finishing.clone();
        std::thread::spawn(move || {
            let mut buffer = vec![0u8; 262_144];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => {
                        if reader_events.send(wrap(LinkEvent::Bytes(id, buffer[..n].to_vec()))).is_err() {
                            return;
                        }
                    }
                    Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                    Err(e)
                        if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut)
                            && !reader_finishing.load(Ordering::SeqCst) =>
                    {
                        continue
                    }
                    Err(_) => break,
                }
            }
            let _ = reader_events.send(wrap(LinkEvent::Eof(id)));
        });
        let (writer, inbox) = channel::<WriterMessage>();
        let mut out = stream.try_clone()?;
        std::thread::spawn(move || {
            let mut buffer = Vec::new();
            while let Ok(message) = inbox.recv() {
                let WriterMessage::Write(first) = message else { break };
                let (writes, finish) = gather(first, &inbox, &mut buffer);
                Pace::silenced(&pace);
                if out.write_all(&buffer).is_err() {
                    let _ = events.send(wrap(LinkEvent::Eof(id)));
                    return;
                }
                Pace::carried(&mut pace, buffer.len());
                for _ in 0..writes {
                    if events.send(wrap(LinkEvent::Written(id))).is_err() {
                        return;
                    }
                }
                if finish {
                    break;
                }
            }
            let _ = out.flush();
            let _ = out.shutdown(Shutdown::Write);
            finishing.store(true, Ordering::SeqCst);
            let _ = out.set_read_timeout(Some(Duration::from_secs(2)));
        });
        Ok(Self { writer, finished: false, radio: None })
    }

    /// Both threads for a data channel the online driver opened: its messages in, the session's bytes out, and on
    /// finishing whatever is queued sent before the channel closes.
    #[cfg(feature = "online")]
    fn start_online<E: Send + 'static>(
        id: u64,
        stream: ChannelStream,
        events: Sender<E>,
        wrap: fn(LinkEvent) -> E,
        mut pace: Option<Pace>,
    ) -> Self {
        let ChannelStream { incoming, writer: out } = stream;
        let reader_events = events.clone();
        std::thread::spawn(move || {
            while let Ok(StreamInput::Data(bytes)) = incoming.recv() {
                if reader_events.send(wrap(LinkEvent::Bytes(id, bytes))).is_err() {
                    return;
                }
            }
            let _ = reader_events.send(wrap(LinkEvent::Eof(id)));
        });
        let (writer, inbox) = channel::<WriterMessage>();
        std::thread::spawn(move || {
            while let Ok(message) = inbox.recv() {
                match message {
                    WriterMessage::Write(write) => {
                        // Sealed here, off the session's thread; the data channel takes the stream as it comes.
                        let bytes = write.into_bytes();
                        Pace::silenced(&pace);
                        if !out.write(&bytes) {
                            let _ = events.send(wrap(LinkEvent::Eof(id)));
                            return;
                        }
                        Pace::carried(&mut pace, bytes.len());
                        if events.send(wrap(LinkEvent::Written(id))).is_err() {
                            return;
                        }
                    }
                    WriterMessage::Finish => break,
                }
            }
            out.drain(Duration::from_secs(2));
            out.close();
        });
        Self { writer, finished: false, radio: None }
    }

    /// The friend acknowledged `bytes` that crossed this link (a HAVE's pieces): a Bluetooth link paces itself by
    /// them.
    pub fn acknowledged(&self, bytes: u64) {
        if let Some(radio) = &self.radio {
            radio.acknowledged(bytes);
        }
    }

    /// A Bluetooth link's pace for a log line, `None` for any other link.
    pub fn pace(&self) -> Option<String> {
        self.radio.as_ref().map(|r| r.describe())
    }

    /// A write the channel handed out ([`szfriends_core::session::SecureChannel::poll_write`]), sealed and written
    /// in order on the writer's thread.
    pub fn write(&self, write: LinkWrite) {
        let _ = self.writer.send(WriterMessage::Write(write));
    }

    /// Everything written so far goes out, then FIN.
    pub fn finish(&mut self) {
        if !self.finished {
            self.finished = true;
            let _ = self.writer.send(WriterMessage::Finish);
        }
    }
}
