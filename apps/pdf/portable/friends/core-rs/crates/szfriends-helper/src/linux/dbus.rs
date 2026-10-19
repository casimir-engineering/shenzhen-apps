//! A small D-Bus client: what the Secret Service store and logind's sleep signal need, and nothing more. Unix
//! socket transport, EXTERNAL authentication, method calls with replies, signals, and the marshalling of the types
//! those use (`y b u i s o g v a ( ) { }`). WHY not a D-Bus crate: the full ones bring an async runtime and several
//! hundred kilobytes to a helper with a 6 MB budget, for six methods and one signal.

use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use super::marshal::{Decoder, Encoder, Value};

const METHOD_CALL: u8 = 1;
const METHOD_RETURN: u8 = 2;
const ERROR: u8 = 3;
const SIGNAL: u8 = 4;
/// The longest message this client accepts (the specification's limit is 128 MiB; ours are small).
const MESSAGE_MAX: usize = 4 * 1024 * 1024;

/// A message received: its kind, header fields and body.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Message {
    pub kind: u8,
    pub serial: u32,
    pub reply_serial: Option<u32>,
    pub path: Option<String>,
    pub interface: Option<String>,
    pub member: Option<String>,
    pub error_name: Option<String>,
    pub sender: Option<String>,
    pub body: Vec<Value>,
}

impl Message {
    pub fn is_signal(&self, interface: &str, member: &str) -> bool {
        self.kind == SIGNAL && self.interface.as_deref() == Some(interface) && self.member.as_deref() == Some(member)
    }
}

/// A failed call: the bus or the service answered with an error, or the connection failed.
#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Remote { name: String, message: String },
    Protocol(&'static str),
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
            Self::Remote { name, message } => write!(f, "{name}: {message}"),
            Self::Protocol(what) => write!(f, "D-Bus protocol: {what}"),
        }
    }
}

/// One connection to a bus.
#[derive(Debug)]
pub struct Bus {
    stream: UnixStream,
    serial: u32,
    /// Signals that arrived while a call waited for its reply.
    queued: VecDeque<Message>,
}

/// `unix:path=…` or `unix:abstract=…`, the first of `;`-separated addresses that connects.
fn connect_address(address: &str) -> io::Result<UnixStream> {
    let mut last = io::Error::new(io::ErrorKind::NotFound, "no usable D-Bus address");
    for entry in address.split(';') {
        let Some(parameters) = entry.strip_prefix("unix:") else { continue };
        for parameter in parameters.split(',') {
            let attempt = if let Some(path) = parameter.strip_prefix("path=") {
                UnixStream::connect(unescape(path))
            } else if let Some(name) = parameter.strip_prefix("abstract=") {
                use std::os::linux::net::SocketAddrExt;
                std::os::unix::net::SocketAddr::from_abstract_name(unescape(name).as_bytes())
                    .and_then(|a| UnixStream::connect_addr(&a))
            } else {
                continue;
            };
            match attempt {
                Ok(stream) => return Ok(stream),
                Err(error) => last = error,
            }
        }
    }
    Err(last)
}

/// D-Bus addresses escape bytes as `%xx`.
fn unescape(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 3 <= bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(byte) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl Bus {
    /// The session bus: `$DBUS_SESSION_BUS_ADDRESS`, else `$XDG_RUNTIME_DIR/bus`.
    pub fn session() -> Result<Self, Error> {
        let address = std::env::var("DBUS_SESSION_BUS_ADDRESS").ok().filter(|a| !a.is_empty()).or_else(|| {
            std::env::var("XDG_RUNTIME_DIR").ok().filter(|d| d.starts_with('/')).map(|d| format!("unix:path={d}/bus"))
        });
        Self::connect(&address.ok_or(Error::Protocol("no session bus"))?)
    }

    /// The system bus: `$DBUS_SYSTEM_BUS_ADDRESS`, else the standard socket.
    pub fn system() -> Result<Self, Error> {
        let address = std::env::var("DBUS_SYSTEM_BUS_ADDRESS")
            .ok()
            .filter(|a| !a.is_empty())
            .unwrap_or_else(|| "unix:path=/var/run/dbus/system_bus_socket".to_owned());
        Self::connect(&address)
    }

    /// Connects, authenticates as this process's user and says Hello.
    pub fn connect(address: &str) -> Result<Self, Error> {
        let mut stream = connect_address(address)?;
        stream.set_read_timeout(Some(Duration::from_secs(10)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;
        let uid = rustix::process::geteuid().as_raw().to_string();
        let hex: String = uid.bytes().map(|b| format!("{b:02x}")).collect();
        stream.write_all(format!("\0AUTH EXTERNAL {hex}\r\n").as_bytes())?;
        let answer = read_line(&mut stream)?;
        if !answer.starts_with("OK ") {
            return Err(Error::Protocol("authentication refused"));
        }
        stream.write_all(b"BEGIN\r\n")?;
        let mut bus = Self { stream, serial: 0, queued: VecDeque::new() };
        bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", &[])?;
        Ok(bus)
    }

    /// How long a call or [`Bus::next_message`] waits; `None` waits for ever.
    pub fn set_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    /// Calls a method and returns its reply's body.
    pub fn call(
        &mut self,
        destination: &str,
        path: &str,
        interface: &str,
        member: &str,
        arguments: &[Value],
    ) -> Result<Vec<Value>, Error> {
        self.serial = self.serial.wrapping_add(1).max(1);
        let serial = self.serial;
        let mut body = Encoder::new();
        let mut signature = String::new();
        for argument in arguments {
            signature.push_str(&argument.signature());
            body.value(argument);
        }
        let mut fields = vec![
            Value::Struct(vec![Value::Byte(1), Value::Variant(Box::new(Value::ObjectPath(path.into())))]),
            Value::Struct(vec![Value::Byte(2), Value::Variant(Box::new(Value::Str(interface.into())))]),
            Value::Struct(vec![Value::Byte(3), Value::Variant(Box::new(Value::Str(member.into())))]),
            Value::Struct(vec![Value::Byte(6), Value::Variant(Box::new(Value::Str(destination.into())))]),
        ];
        if !signature.is_empty() {
            fields.push(Value::Struct(vec![Value::Byte(8), Value::Variant(Box::new(Value::Signature(signature)))]));
        }
        let body = body.finish();
        let mut header = Encoder::new();
        for byte in [b'l', METHOD_CALL, 0, 1] {
            header.value(&Value::Byte(byte));
        }
        header.value(&Value::U32(body.len() as u32));
        header.value(&Value::U32(serial));
        header.value(&Value::Array("(yv)".into(), fields));
        header.align(8);
        let mut message = header.finish();
        message.extend_from_slice(&body);
        self.stream.write_all(&message)?;
        loop {
            let reply = self.read_message()?;
            match reply.kind {
                METHOD_RETURN if reply.reply_serial == Some(serial) => return Ok(reply.body),
                ERROR if reply.reply_serial == Some(serial) => {
                    let message = match reply.body.first() {
                        Some(Value::Str(text)) => text.clone(),
                        _ => String::new(),
                    };
                    return Err(Error::Remote { name: reply.error_name.unwrap_or_default(), message });
                }
                SIGNAL => self.queued.push_back(reply),
                _ => {}
            }
        }
    }

    /// The next signal (or other message not answering a call of ours).
    pub fn next_message(&mut self) -> Result<Message, Error> {
        if let Some(message) = self.queued.pop_front() {
            return Ok(message);
        }
        self.read_message()
    }

    fn read_message(&mut self) -> Result<Message, Error> {
        let mut fixed = [0u8; 16];
        self.stream.read_exact(&mut fixed)?;
        let big = match fixed[0] {
            b'l' => false,
            b'B' => true,
            _ => return Err(Error::Protocol("bad byte order")),
        };
        let number = |at: usize| {
            let bytes = [fixed[at], fixed[at + 1], fixed[at + 2], fixed[at + 3]];
            if big {
                u32::from_be_bytes(bytes)
            } else {
                u32::from_le_bytes(bytes)
            }
        };
        let (body_length, fields_length) = (number(4) as usize, number(12) as usize);
        let header_length = (16 + fields_length).div_ceil(8) * 8;
        if header_length + body_length > MESSAGE_MAX {
            return Err(Error::Protocol("message too large"));
        }
        let mut bytes = fixed.to_vec();
        bytes.resize(header_length + body_length, 0);
        self.stream.read_exact(&mut bytes[16..])?;
        let mut message = Message { kind: fixed[1], serial: number(8), ..Message::default() };
        let mut header = Decoder::new(&bytes[..header_length], big, 12);
        let Some(Value::Array(_, fields)) = header.value("a(yv)") else {
            return Err(Error::Protocol("bad header fields"));
        };
        let mut signature = String::new();
        for field in fields {
            let Value::Struct(parts) = field else { continue };
            let (Some(Value::Byte(code)), Some(Value::Variant(value))) = (parts.first(), parts.get(1)) else {
                continue;
            };
            match (code, value.as_ref()) {
                (1, Value::ObjectPath(text)) => message.path = Some(text.clone()),
                (2, Value::Str(text)) => message.interface = Some(text.clone()),
                (3, Value::Str(text)) => message.member = Some(text.clone()),
                (4, Value::Str(text)) => message.error_name = Some(text.clone()),
                (5, Value::U32(serial)) => message.reply_serial = Some(*serial),
                (7, Value::Str(text)) => message.sender = Some(text.clone()),
                (8, Value::Signature(text)) => signature = text.clone(),
                _ => {}
            }
        }
        let mut body = Decoder::new(&bytes[header_length..], big, 0);
        message.body = body.values(&signature).ok_or(Error::Protocol("bad body"))?;
        Ok(message)
    }
}

fn read_line(stream: &mut UnixStream) -> io::Result<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    while !line.ends_with(b"\r\n") {
        if line.len() > 512 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "authentication line too long"));
        }
        stream.read_exact(&mut byte)?;
        line.push(byte[0]);
    }
    Ok(String::from_utf8_lossy(&line).trim_end().to_owned())
}

#[cfg(test)]
mod tests {
    use super::unescape;

    #[test]
    fn addresses_unescape() {
        assert_eq!(unescape("/run/user/1000/bus"), "/run/user/1000/bus");
        assert_eq!(unescape("/tmp/dbus%2dtest"), "/tmp/dbus-test");
        assert_eq!(unescape("50%"), "50%");
    }
}
