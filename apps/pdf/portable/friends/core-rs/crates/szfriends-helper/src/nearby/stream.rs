//! What a session runs over: a TCP connection the core opened or accepted itself, or a byte stream the platform owns
//! (a Bluetooth L2CAP channel, a phone's own network connection), whose bytes cross into the core through channels,
//! or a data channel online opened to a friend. Either way the session sees an ordered byte stream (ADR 0001: the
//! same Noise sessions on every route).

use std::net::TcpStream;
use std::sync::mpsc::{channel, Receiver, Sender};

/// Bytes the platform hands the core, in order; an empty piece is the end.
pub type Incoming = Receiver<Vec<u8>>;
/// Bytes the core hands the platform, in order; `None` is the end (everything before it still goes).
pub type Outgoing = Box<dyn FnMut(Option<Vec<u8>>) + Send>;

/// A stream the platform owns.
pub struct PlatformStream {
    pub incoming: Incoming,
    pub outgoing: Outgoing,
}

impl std::fmt::Debug for PlatformStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PlatformStream")
    }
}

impl PlatformStream {
    /// A stream and the platform's end of it: what the platform reads arrives through the sender, what the core
    /// writes reaches `outgoing`.
    pub fn new(outgoing: Outgoing) -> (Self, Sender<Vec<u8>>) {
        let (sender, incoming) = channel();
        (Self { incoming, outgoing }, sender)
    }

    /// Two streams joined back to back, for tests: what one writes the other reads.
    pub fn pair() -> (Self, Self) {
        let (to_b, from_a) = channel::<Vec<u8>>();
        let (to_a, from_b) = channel::<Vec<u8>>();
        let a = Self {
            incoming: from_b,
            outgoing: Box::new(move |bytes| {
                let _ = to_b.send(bytes.unwrap_or_default());
            }),
        };
        let b = Self {
            incoming: from_a,
            outgoing: Box::new(move |bytes| {
                let _ = to_a.send(bytes.unwrap_or_default());
            }),
        };
        (a, b)
    }
}

/// One session's transport.
#[derive(Debug)]
pub enum LinkStream {
    Tcp(TcpStream),
    Platform(PlatformStream),
    /// A data channel the online driver opened.
    #[cfg(feature = "online")]
    Online(szfriends_online::transport::ChannelStream),
}

impl From<TcpStream> for LinkStream {
    fn from(stream: TcpStream) -> Self {
        Self::Tcp(stream)
    }
}
