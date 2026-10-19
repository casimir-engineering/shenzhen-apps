//! An in-memory connection pair for the server's tests, on every platform.

#![allow(dead_code)]

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use szfriends_contract::framing::{encode, LineReader};
use szfriends_helper::transport::Duplex;

mod remove;
#[allow(unused_imports)]
pub use remove::remove_tree;

/// One end of the pair.
pub type End = szfriends_helper::transport::MemoryEnd;

pub fn pair() -> (Arc<End>, Arc<End>) {
    szfriends_helper::transport::memory_pair()
}

/// The test's side of a connection: frames out, frames in.
pub struct Peer {
    pub end: Arc<End>,
    reader: LineReader,
    frames: VecDeque<Value>,
}

impl Peer {
    pub fn new(end: Arc<End>) -> Self {
        Self { end, reader: LineReader::new(), frames: VecDeque::new() }
    }

    pub fn send(&self, frame: &Value) {
        self.end.write_all(&encode(frame).unwrap()).unwrap();
    }

    pub fn send_raw(&self, bytes: &[u8]) {
        let _ = self.end.write_all(bytes);
    }

    /// The next frame, or `None` at the end.
    pub fn next(&mut self) -> Option<Value> {
        let mut buffer = [0u8; 4096];
        while self.frames.is_empty() {
            let n = self.end.read(&mut buffer).unwrap();
            if n == 0 {
                return None;
            }
            self.frames.extend(self.reader.push(&buffer[..n]).unwrap());
        }
        self.frames.pop_front()
    }
}

/// Waits up to two seconds for `condition`.
pub fn eventually(condition: impl Fn() -> bool) -> bool {
    for _ in 0..200 {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    condition()
}
