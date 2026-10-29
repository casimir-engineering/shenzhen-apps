//! A session's link: a reader thread and a writer thread feeding the service's one event loop, so neither side's
//! writes can block its reads (two peers filling each other's buffers would deadlock a single thread). Over TCP,
//! closing writes everything still queued, sends FIN, and reads on for up to two seconds so the peer's last bytes are
//! not answered with a reset (the interop suite's link, which this mirrors). Over a stream the platform owns (a
//! Bluetooth channel), bytes cross through its channels and the end is said in order after the last write. A friend
//! reached online gets the same two threads over the data channel's stream.

use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[cfg(feature = "online")]
use szfriends_online::transport::{ChannelStream, StreamInput};

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

/// A test home's emulated route (`SZFRIENDS_TEST_ROUTE_RATES`): the writer holds each write's bytes for as long as
/// the route's rate would take to carry them, so the session's in-flight budget and window see a slow route.
#[derive(Clone, Copy, Debug)]
struct Pace {
    bytes_per_second: f64,
    free_at: Instant,
}

impl Pace {
    fn new(rate: Option<f64>) -> Option<Self> {
        rate.map(|bytes_per_second| Self { bytes_per_second, free_at: Instant::now() })
    }

    fn carried(pace: &mut Option<Self>, bytes: usize) {
        let Some(pace) = pace else { return };
        let now = Instant::now();
        pace.free_at = pace.free_at.max(now) + Duration::from_secs_f64(bytes as f64 / pace.bytes_per_second);
        if pace.free_at > now {
            std::thread::sleep(pace.free_at - now);
        }
    }
}

enum WriterMessage {
    Bytes(Vec<u8>),
    Finish,
}

#[derive(Debug)]
pub struct Link {
    writer: Sender<WriterMessage>,
    finished: bool,
}

impl Link {
    /// Starts both threads for `stream`; events go to `events` wrapped by `wrap`. `rate`: a test home's emulated
    /// route, in bytes per second this side writes at; `None` everywhere else.
    pub fn start<E: Send + 'static>(
        id: u64,
        stream: LinkStream,
        events: Sender<E>,
        wrap: fn(LinkEvent) -> E,
        rate: Option<f64>,
    ) -> std::io::Result<Self> {
        let pace = Pace::new(rate);
        match stream {
            LinkStream::Tcp(stream) => Self::start_tcp(id, stream, events, wrap, pace),
            LinkStream::Platform(stream) => Ok(Self::start_platform(id, stream, events, wrap, pace)),
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
        let (writer, inbox) = channel::<WriterMessage>();
        std::thread::spawn(move || {
            while let Ok(message) = inbox.recv() {
                match message {
                    WriterMessage::Bytes(bytes) => {
                        let length = bytes.len();
                        outgoing(Some(bytes));
                        Pace::carried(&mut pace, length);
                        if events.send(wrap(LinkEvent::Written(id))).is_err() {
                            return;
                        }
                    }
                    WriterMessage::Finish => break,
                }
            }
            outgoing(None);
        });
        Self { writer, finished: false }
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
            let mut buffer = vec![0u8; 65_536];
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
            while let Ok(message) = inbox.recv() {
                match message {
                    WriterMessage::Bytes(bytes) => {
                        if out.write_all(&bytes).is_err() {
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
            let _ = out.flush();
            let _ = out.shutdown(Shutdown::Write);
            finishing.store(true, Ordering::SeqCst);
            let _ = out.set_read_timeout(Some(Duration::from_secs(2)));
        });
        Ok(Self { writer, finished: false })
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
                    WriterMessage::Bytes(bytes) => {
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
        Self { writer, finished: false }
    }

    pub fn write(&self, bytes: Vec<u8>) {
        let _ = self.writer.send(WriterMessage::Bytes(bytes));
    }

    /// Everything written so far goes out, then FIN.
    pub fn finish(&mut self) {
        if !self.finished {
            self.finished = true;
            let _ = self.writer.send(WriterMessage::Finish);
        }
    }
}
