//! A TCP connection on loopback as a session's link: a reader thread and a writer thread feeding the peer's one
//! event loop, so neither side's writes can block its reads (two peers filling each other's buffers would deadlock a
//! single thread). Closing writes everything still queued, sends FIN, and reads on for up to two seconds so the peer's
//! last bytes are not answered with a reset.

use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::time::Duration;

use szfriends_online::transport::{ChannelStream, StreamInput, StreamWriter};

/// What the link reports to the loop, tagged with the session it belongs to.
#[derive(Debug)]
pub enum LinkEvent {
    Bytes(u64, Vec<u8>),
    /// The peer closed, or the connection failed.
    Eof(u64),
    /// One write handed to the link is on the wire.
    Written(u64),
}

enum WriterMessage {
    Bytes(Vec<u8>),
    Finish,
}

#[derive(Debug)]
pub struct Link {
    writer: Sender<WriterMessage>,
    stream: Option<TcpStream>,
    online: Option<StreamWriter>,
    finished: bool,
}

impl Link {
    /// Starts both threads for `stream`; events go to `events` wrapped by `wrap`.
    pub fn start<E: Send + 'static>(
        id: u64,
        stream: TcpStream,
        events: Sender<E>,
        wrap: fn(LinkEvent) -> E,
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
            while let Ok(message) = inbox.recv() {
                match message {
                    WriterMessage::Bytes(bytes) => {
                        if out.write_all(&bytes).is_err() {
                            let _ = events.send(wrap(LinkEvent::Eof(id)));
                            return;
                        }
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
        Ok(Self { writer, stream: Some(stream), online: None, finished: false })
    }

    /// A data channel as a session's link (the online suites): its messages in, writes out in messages of at most
    /// 64 KiB, held while the channel buffers more than its high-water mark; finishing closes the channel once what was
    /// written has left.
    pub fn start_online<E: Send + 'static>(
        id: u64,
        stream: ChannelStream,
        events: Sender<E>,
        wrap: fn(LinkEvent) -> E,
    ) -> Self {
        let ChannelStream { incoming, writer: dc } = stream;
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
        let out = dc.clone();
        std::thread::spawn(move || {
            while let Ok(message) = inbox.recv() {
                match message {
                    WriterMessage::Bytes(bytes) => {
                        if !out.write(&bytes) {
                            let _ = events.send(wrap(LinkEvent::Eof(id)));
                            return;
                        }
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
        Self { writer, stream: None, online: Some(dc), finished: false }
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

    /// Ends the connection at once, whatever is queued: a cut route.
    pub fn abort(&mut self) {
        self.finished = true;
        if let Some(stream) = &self.stream {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Some(online) = &self.online {
            online.close();
        }
    }
}
