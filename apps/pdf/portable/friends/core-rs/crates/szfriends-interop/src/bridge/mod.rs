//! The test network's bridge into a VM (`szfriends-testnet`): a helper inside the Windows or Ubuntu VM meets helpers
//! on this Mac as if both were on one network, while every socket on either side stays on loopback. The only channel
//! between the two is the standard input and output of `prlctl exec`, which carries:
//!
//! - the entries each side's helpers register (the guest's on its loopback test network, the Mac's on Bonjour over
//!   lo0), each mirrored on the other side by a listener of the bridge's own;
//! - every connection made to a mirror, relayed to the real entry on the other side;
//! - the client protocol of the guest's helper, so a test on the Mac drives it like any other;
//! - small commands (make a file to send).
//!
//! Frames are lines of hex, so nothing a console or `prlctl` does to bytes can change them. [`host`] is the Mac's side
//! (a library the tests use), [`guest`] the VM's (the `szfriends-testnet guest` binary).

pub mod guest;
#[cfg(target_os = "macos")]
pub mod host;

use std::io::{self, BufRead, Write};

use serde_json::Value;

/// One message between the two sides.
#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    /// An entry registered on the sender's side: `{"id", "name", "port", "txt": [[k, v]]}` (port only for the sender).
    Announce(Value),
    Withdraw(String),
    /// A connection reached the mirror of the receiver's entry `entry`; the receiver connects to the real one.
    Open {
        connection: u64,
        entry: String,
    },
    Data {
        connection: u64,
        bytes: Vec<u8>,
    },
    Close {
        connection: u64,
    },
    /// Bytes of the guest helper's client protocol, either way.
    Client(Vec<u8>),
    /// A command for the guest (`{"cmd": "make_file", "name", "size", "id"}`) and its reply.
    Command(Value),
    Reply(Value),
}

impl Message {
    fn kind_and_payload(&self) -> (u8, Vec<u8>) {
        let json = |v: &Value| v.to_string().into_bytes();
        match self {
            Self::Announce(v) => (1, json(v)),
            Self::Withdraw(id) => (2, id.as_bytes().to_vec()),
            Self::Open { connection, entry } => (3, [&connection.to_be_bytes()[..], entry.as_bytes()].concat()),
            Self::Data { connection, bytes } => (4, [&connection.to_be_bytes()[..], bytes].concat()),
            Self::Close { connection } => (5, connection.to_be_bytes().to_vec()),
            Self::Client(bytes) => (6, bytes.clone()),
            Self::Command(v) => (7, json(v)),
            Self::Reply(v) => (8, json(v)),
        }
    }

    /// One line: hex of the kind byte and the payload.
    pub fn encode(&self) -> String {
        let (kind, payload) = self.kind_and_payload();
        let mut line = hex::encode([&[kind][..], &payload].concat());
        line.push('\n');
        line
    }

    pub fn decode(line: &str) -> Option<Self> {
        let bytes = hex::decode(line.trim()).ok()?;
        let (&kind, payload) = bytes.split_first()?;
        let connection = || payload.get(..8).and_then(|b| b.try_into().ok()).map(u64::from_be_bytes);
        let text = |p: &[u8]| String::from_utf8(p.to_vec()).ok();
        let json = || serde_json::from_slice::<Value>(payload).ok();
        Some(match kind {
            1 => Self::Announce(json()?),
            2 => Self::Withdraw(text(payload)?),
            3 => Self::Open { connection: connection()?, entry: text(&payload[8..])? },
            4 => Self::Data { connection: connection()?, bytes: payload[8..].to_vec() },
            5 => Self::Close { connection: connection()? },
            6 => Self::Client(payload.to_vec()),
            7 => Self::Command(json()?),
            8 => Self::Reply(json()?),
            _ => return None,
        })
    }
}

/// Reads messages from `input` until it ends, handing each to `handle`.
pub fn read_messages(input: impl io::Read, mut handle: impl FnMut(Message)) {
    for line in io::BufReader::new(input).lines() {
        let Ok(line) = line else { return };
        if let Some(message) = Message::decode(&line) {
            handle(message);
        }
    }
}

/// A writer thread for `output`: messages sent to the returned channel go out in order.
pub fn writer(mut output: impl Write + Send + 'static) -> std::sync::mpsc::Sender<Message> {
    let (sender, receiver) = std::sync::mpsc::channel::<Message>();
    std::thread::spawn(move || {
        for message in receiver {
            if output.write_all(message.encode().as_bytes()).and_then(|()| output.flush()).is_err() {
                return;
            }
        }
    });
    sender
}

/// Relays one TCP connection's bytes into messages for `connection` until it ends.
pub fn pump(mut stream: std::net::TcpStream, connection: u64, out: std::sync::mpsc::Sender<Message>) {
    std::thread::spawn(move || {
        let mut buffer = vec![0u8; 32 * 1024];
        loop {
            match io::Read::read(&mut stream, &mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out.send(Message::Data { connection, bytes: buffer[..n].to_vec() }).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = out.send(Message::Close { connection });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_round_trip() {
        let messages = [
            Message::Announce(serde_json::json!({"id": "a", "port": 5})),
            Message::Withdraw("a".into()),
            Message::Open { connection: 7, entry: "name".into() },
            Message::Data { connection: 7, bytes: vec![0, 13, 10, 255] },
            Message::Close { connection: 7 },
            Message::Client(b"{\"type\":\"hello\"}\n".to_vec()),
        ];
        for message in messages {
            let line = message.encode().replace('\n', "\r\n");
            assert_eq!(Message::decode(&line), Some(message));
        }
    }
}
