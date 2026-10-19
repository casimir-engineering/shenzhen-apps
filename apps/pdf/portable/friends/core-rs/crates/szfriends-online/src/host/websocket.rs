//! The host connection's WebSocket (RFC 6455; `SZFriendsHostWebSocket.m`): a client over one TCP stream, text frames
//! of JSON, at most 64 KiB from the host (HOST-PROTOCOL.md § Transport), pings answered, every frame masked. A
//! reader thread hands each message to the owner; writes go through a writer thread, so the owner never blocks on
//! the network. `wss://` runs over TLS 1.2 (`szfriends_datachannel_sys::tls`), the server checked as the system would
//! check it (or against a test's own CA); cleartext `ws://` is for the loopback test host only.

use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use sha1::{Digest, Sha1};
pub use szfriends_datachannel_sys::tls::Roots;
use szfriends_datachannel_sys::tls::TlsStream;

/// The largest message the host sends.
pub const MESSAGE_MAX: usize = 64 * 1024;
const GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// What the reader reports.
#[derive(Debug)]
pub enum SocketEvent {
    Text(String),
    Pong,
    /// The connection closed, with the host's close code when it sent one.
    Closed(Option<u16>),
}

/// A `wss://host[:port]/path` URL, or a cleartext `ws://` one on loopback only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub path: String,
    pub tls: bool,
}

impl Endpoint {
    pub fn parse(url: &str) -> Option<Self> {
        let (tls, rest) = match url.strip_prefix("wss://") {
            Some(rest) => (true, rest),
            None => (false, url.strip_prefix("ws://")?),
        };
        let default_port = if tls { 443 } else { 80 };
        let (authority, path) = rest.split_once('/').map_or((rest, "/".to_owned()), |(a, p)| (a, format!("/{p}")));
        let (host, port) = if let Some(inner) = authority.strip_prefix('[') {
            let (host, tail) = inner.split_once(']')?;
            (host.to_owned(), tail.strip_prefix(':').map_or(Some(default_port), |p| p.parse().ok())?)
        } else {
            let (host, port) =
                authority.split_once(':').map_or((authority, Some(default_port)), |(h, p)| (h, p.parse().ok()));
            (host.to_owned(), port?)
        };
        let loopback = matches!(host.as_str(), "127.0.0.1" | "::1" | "localhost");
        let host_ok = !host.is_empty() && !host.contains(['@', ' ', '/', '#', '?']);
        ((tls || loopback) && host_ok && !path.contains(['#', ' '])).then_some(Self { host, port, path, tls })
    }
}

/// How long a TLS reader holds the connection before letting a writer in.
const TLS_SLICE: Duration = Duration::from_millis(20);

/// The reading half of a TLS connection, shared with the writer behind a lock.
struct TlsReader {
    tls: Arc<Mutex<TlsStream>>,
    /// While set (the upgrade), reading gives up at this instant; afterwards it waits as long as it takes.
    deadline: Arc<Mutex<Option<Instant>>>,
}

impl Read for TlsReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            match self.tls.lock().unwrap_or_else(|e| e.into_inner()).read(buf) {
                Err(error) if error.kind() == ErrorKind::WouldBlock => {}
                other => return other,
            }
            let deadline = *self.deadline.lock().unwrap_or_else(|e| e.into_inner());
            if deadline.is_some_and(|d| Instant::now() >= d) {
                return Err(ErrorKind::TimedOut.into());
            }
            std::thread::yield_now();
        }
    }
}

struct TlsWriter(Arc<Mutex<TlsStream>>);

impl Write for TlsWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

type Halves = (Box<dyn Read + Send>, Box<dyn Write + Send>, TcpStream, Option<Arc<Mutex<Option<Instant>>>>);

/// The TCP connection (any address for `wss://`, loopback only for `ws://`) and, for `wss://`, TLS over it.
fn open(endpoint: &Endpoint, roots: &Roots, timeout: Duration) -> std::io::Result<Halves> {
    let addresses = (endpoint.host.as_str(), endpoint.port).to_socket_addrs()?;
    let mut last = std::io::Error::other("not a loopback host");
    let mut stream = None;
    for address in addresses.filter(|a| endpoint.tls || a.ip().is_loopback()) {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(connected) => {
                stream = Some(connected);
                break;
            }
            Err(error) => last = error,
        }
    }
    let stream = stream.ok_or(last)?;
    stream.set_nodelay(true)?;
    let shutdown = stream.try_clone()?;
    if !endpoint.tls {
        stream.set_read_timeout(Some(timeout))?;
        return Ok((Box::new(stream.try_clone()?), Box::new(stream), shutdown, None));
    }
    let tls = TlsStream::connect(stream, &endpoint.host, roots, timeout)?;
    tls.tcp().set_read_timeout(Some(TLS_SLICE))?;
    let tls = Arc::new(Mutex::new(tls));
    let deadline = Arc::new(Mutex::new(Some(Instant::now() + timeout)));
    let reader = TlsReader { tls: tls.clone(), deadline: deadline.clone() };
    Ok((Box::new(reader), Box::new(TlsWriter(tls)), shutdown, Some(deadline)))
}

#[derive(Debug)]
enum Outgoing {
    Frame(u8, Vec<u8>),
    Close,
}

/// The writing half; dropping it closes the connection.
#[derive(Debug)]
pub struct Socket {
    writer: Sender<Outgoing>,
}

fn mask_key() -> [u8; 4] {
    let mut key = [0u8; 4];
    szfriends_crypto::random_bytes(&mut key);
    key
}

fn frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = vec![0x80 | opcode];
    match payload.len() {
        n if n < 126 => out.push(0x80 | n as u8),
        n if n <= 0xffff => {
            out.push(0x80 | 126);
            out.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            out.push(0x80 | 127);
            out.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    let key = mask_key();
    out.extend_from_slice(&key);
    out.extend(payload.iter().enumerate().map(|(i, b)| b ^ key[i % 4]));
    out
}

impl Socket {
    /// Connects, upgrades, and starts the reader (events to `events`) and the writer. Blocks for the handshake; call
    /// it off the owner's thread.
    pub fn connect(
        endpoint: &Endpoint,
        roots: &Roots,
        events: impl Fn(SocketEvent) + Send + 'static,
        timeout: Duration,
    ) -> std::io::Result<Self> {
        let (reader, mut out, shutdown, deadline) = open(endpoint, roots, timeout)?;
        let mut key = [0u8; 16];
        szfriends_crypto::random_bytes(&mut key);
        let key = crate::b64::encode_standard(&key);
        let host = if endpoint.host.contains(':') { format!("[{}]", endpoint.host) } else { endpoint.host.clone() };
        let request = format!(
            "GET {} HTTP/1.1\r\nHost: {host}:{}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
             Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            endpoint.path, endpoint.port
        );
        out.write_all(request.as_bytes())?;
        let mut reader = BufReader::new(reader);
        let mut status = String::new();
        reader.read_line(&mut status)?;
        if !status.starts_with("HTTP/1.1 101") {
            return Err(std::io::Error::other("the host refused the upgrade"));
        }
        let expected = crate::b64::encode_standard(&Sha1::digest(format!("{key}{GUID}").as_bytes()));
        let mut accepted = false;
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line)? == 0 {
                return Err(std::io::Error::other("the upgrade ended early"));
            }
            let line = line.trim_end();
            if line.is_empty() {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                if name.eq_ignore_ascii_case("sec-websocket-accept") && value.trim() == expected {
                    accepted = true;
                }
            }
        }
        if !accepted {
            return Err(std::io::Error::other("the upgrade was not accepted"));
        }
        match deadline {
            Some(deadline) => *deadline.lock().unwrap_or_else(|e| e.into_inner()) = None,
            None => shutdown.set_read_timeout(None)?,
        }
        let (writer, outgoing) = channel::<Outgoing>();
        let pong = writer.clone();
        std::thread::Builder::new().name("szfriends-host-write".into()).spawn(move || {
            for message in outgoing {
                let bytes = match message {
                    Outgoing::Frame(opcode, payload) => frame(opcode, &payload),
                    Outgoing::Close => {
                        let _ = out.write_all(&frame(0x8, &1000u16.to_be_bytes()));
                        break;
                    }
                };
                if out.write_all(&bytes).is_err() {
                    break;
                }
            }
            let _ = shutdown.shutdown(Shutdown::Both);
        })?;
        std::thread::Builder::new().name("szfriends-host-read".into()).spawn(move || {
            let code = read_frames(&mut reader, &events, &pong);
            events(SocketEvent::Closed(code));
        })?;
        Ok(Self { writer })
    }

    /// One text message.
    pub fn send_text(&self, text: &str) -> bool {
        self.writer.send(Outgoing::Frame(0x1, text.as_bytes().to_vec())).is_ok()
    }

    pub fn ping(&self) -> bool {
        self.writer.send(Outgoing::Frame(0x9, Vec::new())).is_ok()
    }

    pub fn close(&self) {
        let _ = self.writer.send(Outgoing::Close);
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        self.close();
    }
}

/// Reads frames until the connection ends; the close code the host sent, if any.
fn read_frames(reader: &mut impl Read, events: &impl Fn(SocketEvent), pong: &Sender<Outgoing>) -> Option<u16> {
    let mut message: Vec<u8> = Vec::new();
    loop {
        let mut header = [0u8; 2];
        reader.read_exact(&mut header).ok()?;
        let (fin, opcode, masked) = (header[0] & 0x80 != 0, header[0] & 0x0f, header[1] & 0x80 != 0);
        let length = match header[1] & 0x7f {
            126 => {
                let mut b = [0u8; 2];
                reader.read_exact(&mut b).ok()?;
                usize::from(u16::from_be_bytes(b))
            }
            127 => {
                let mut b = [0u8; 8];
                reader.read_exact(&mut b).ok()?;
                usize::try_from(u64::from_be_bytes(b)).ok()?
            }
            n => usize::from(n),
        };
        // A server never masks; anything over the host's limit is not the host.
        if masked || length > MESSAGE_MAX || message.len() + length > MESSAGE_MAX {
            return None;
        }
        let mut payload = vec![0u8; length];
        reader.read_exact(&mut payload).ok()?;
        match opcode {
            0x0 | 0x1 => {
                message.extend_from_slice(&payload);
                if fin {
                    let text = String::from_utf8(std::mem::take(&mut message)).ok()?;
                    events(SocketEvent::Text(text));
                }
            }
            0x8 => return (payload.len() >= 2).then(|| u16::from_be_bytes([payload[0], payload[1]])),
            0x9 => {
                let _ = pong.send(Outgoing::Frame(0xA, payload));
            }
            0xA => events(SocketEvent::Pong),
            _ => return None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tls_anywhere_and_cleartext_on_loopback_only() {
        let endpoint = Endpoint::parse("ws://127.0.0.1:4567/v1").unwrap();
        assert_eq!((endpoint.port, endpoint.path.as_str(), endpoint.tls), (4567, "/v1", false));
        assert_eq!(Endpoint::parse("ws://[::1]:80/v1?guest=1").unwrap().host, "::1");
        assert!(Endpoint::parse("ws://friends.example:80/v1").is_none(), "cleartext only on loopback");
        let production = Endpoint::parse("wss://friends.example/v1").unwrap();
        assert_eq!((production.host.as_str(), production.port, production.tls), ("friends.example", 443, true));
        assert_eq!(Endpoint::parse("wss://127.0.0.1:8443/v1").unwrap().port, 8443);
        assert!(Endpoint::parse("wss://user@friends.example/v1").is_none());
        assert!(Endpoint::parse("https://friends.example/v1").is_none());
    }
}
