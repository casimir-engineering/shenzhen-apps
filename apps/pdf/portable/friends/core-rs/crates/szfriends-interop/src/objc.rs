//! The Objective-C peer: `tools/objc-session-peer`, built from the helper's own session, identity, store and transfer
//! sources (and its Network.framework stream) by `make friends-core-rs-interop-check`, run as a child process with a
//! temporary home and driven over its standard input and output, one JSON object per line. Commands are answered in
//! order with `{"reply": ...}`; everything else it prints is an event.

use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};

use crate::Peer;

#[derive(Debug)]
pub struct ObjcPeer {
    child: Child,
    stdin: ChildStdin,
    replies: Receiver<Value>,
    events: Receiver<Value>,
    transcript: Transcript,
}

/// Everything a peer was told and said, in order ("> " commands, "< " output, "! " its standard error), for a bench
/// case that fails (`bench::keep_logs`). The oldest half goes once it holds `TRANSCRIPT_MAX` lines.
pub type Transcript = Arc<Mutex<Vec<String>>>;
const TRANSCRIPT_MAX: usize = 400_000;

fn note(transcript: &Transcript, line: String) {
    let Ok(mut lines) = transcript.lock() else { return };
    if lines.len() >= TRANSCRIPT_MAX {
        lines.drain(..TRANSCRIPT_MAX / 2);
    }
    lines.push(line);
}

impl ObjcPeer {
    /// The peer binary from `$SZFRIENDS_OBJC_PEER`, or `None` when it is not set (a platform without the helper).
    pub fn binary() -> Option<std::path::PathBuf> {
        std::env::var_os("SZFRIENDS_OBJC_PEER").map(Into::into).filter(|p: &std::path::PathBuf| p.exists())
    }

    /// Starts the peer with `home` as its state directory and the identity derived from `name` (seeds as in the
    /// vector exporter: BLAKE2b-256 of "<name> seed" and "<name> static").
    pub fn start(binary: &Path, home: &Path, name: &str) -> Self {
        let mut command = Command::new(binary);
        command.arg(home).arg(name);
        Self::spawn(command)
    }

    /// Any process that speaks this peer's protocol on its standard input and output: the Rust peer of
    /// `examples/session_peer.rs`, a peer built from a release tag, or one on another device through `ssh` or
    /// `adb shell` (the transfer bench and interop matrix).
    pub fn spawn(mut command: Command) -> Self {
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("the Objective-C peer starts");
        let stdin = child.stdin.take().expect("piped");
        let stdout = child.stdout.take().expect("piped");
        let stderr = child.stderr.take().expect("piped");
        let transcript: Transcript = Arc::default();
        let errors = transcript.clone();
        // Its standard error still reaches ours, and is kept in its transcript too.
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines() {
                let Ok(line) = line else { return };
                eprintln!("{line}");
                note(&errors, format!("! {line}"));
            }
        });
        let (reply_tx, replies) = channel();
        let (event_tx, events) = channel();
        let said = transcript.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { return };
                note(&said, format!("< {line}"));
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    eprintln!("objc peer: not JSON: {line}");
                    continue;
                };
                let sent = match value.get("reply") {
                    Some(reply) => reply_tx.send(reply.clone()).is_ok(),
                    None => event_tx.send(value).is_ok(),
                };
                if !sent {
                    return;
                }
            }
        });
        Self { child, stdin, replies, events, transcript }
    }

    /// What it was told and said so far.
    pub fn transcript(&self) -> Transcript {
        self.transcript.clone()
    }

    /// The child's process id, for its CPU time.
    pub fn pid(&self) -> u32 {
        self.child.id()
    }
}

impl Peer for ObjcPeer {
    fn command(&mut self, command: Value) -> Value {
        let line = serde_json::to_string(&command).expect("JSON");
        note(&self.transcript, format!("> {line}"));
        writeln!(self.stdin, "{line}").expect("the peer reads its commands");
        self.stdin.flush().expect("flushed");
        self.replies.recv_timeout(Duration::from_secs(120)).unwrap_or_else(|_| panic!("no reply to {line}"))
    }

    fn next_event(&mut self, timeout: Duration) -> Option<Value> {
        self.events.recv_timeout(timeout).ok()
    }
}

impl Drop for ObjcPeer {
    fn drop(&mut self) {
        let _ = writeln!(self.stdin, "{}", json!({ "cmd": "quit" }));
        let _ = self.stdin.flush();
        for _ in 0..50 {
            if let Ok(Some(_)) = self.child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        // Only the child this harness started, by its own handle.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
