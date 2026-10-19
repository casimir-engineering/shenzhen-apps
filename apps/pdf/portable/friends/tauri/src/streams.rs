//! The native streams a phone's plugin holds open into the core (`nearby.rs`): their bytes, as the plugin reports
//! them, go to the stream the core was handed for each id. The plugin starts reading the moment a connection opens,
//! on a thread of its own, so a peer's first bytes (or even its end) may arrive before the event that names the
//! stream: those wait here until the stream is claimed. Anything for a stream that already ended is dropped.

use std::collections::{HashMap, HashSet};
use std::sync::mpsc::Sender;
use std::sync::Mutex;

#[derive(Default)]
struct Early {
    bytes: Vec<Vec<u8>>,
    closed: bool,
}

#[derive(Default)]
struct Table {
    open: HashMap<u64, Sender<Vec<u8>>>,
    early: HashMap<u64, Early>,
    claimed: HashSet<u64>,
}

/// See the module documentation.
#[derive(Default)]
pub struct StreamTable(Mutex<Table>);

impl std::fmt::Debug for StreamTable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("StreamTable")
    }
}

impl StreamTable {
    fn table(&self) -> std::sync::MutexGuard<'_, Table> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The stream for `id` now has a reader: what came early goes first. An empty piece is the end.
    pub fn claim(&self, id: u64, sender: Sender<Vec<u8>>) {
        let mut table = self.table();
        if !table.claimed.insert(id) {
            return;
        }
        let early = table.early.remove(&id).unwrap_or_default();
        for bytes in early.bytes {
            let _ = sender.send(bytes);
        }
        if early.closed {
            let _ = sender.send(Vec::new());
        } else {
            table.open.insert(id, sender);
        }
    }

    pub fn bytes(&self, id: u64, data: Vec<u8>) {
        if data.is_empty() {
            return;
        }
        let mut table = self.table();
        if let Some(sender) = table.open.get(&id) {
            if sender.send(data).is_err() {
                table.open.remove(&id);
            }
        } else if !table.claimed.contains(&id) {
            table.early.entry(id).or_default().bytes.push(data);
        }
    }

    pub fn closed(&self, id: u64) {
        let mut table = self.table();
        if let Some(sender) = table.open.remove(&id) {
            let _ = sender.send(Vec::new());
        } else if !table.claimed.contains(&id) {
            table.early.entry(id).or_default().closed = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc::channel;

    use super::*;

    #[test]
    fn early_bytes_and_end_wait_for_their_stream() {
        let table = StreamTable::default();
        table.bytes(7, b"hello".to_vec());
        table.bytes(7, b" there".to_vec());
        let (sender, received) = channel();
        table.claim(7, sender);
        table.bytes(7, b"!".to_vec());
        table.closed(7);
        let got: Vec<Vec<u8>> = received.try_iter().collect();
        assert_eq!(got, [b"hello".to_vec(), b" there".to_vec(), b"!".to_vec(), Vec::new()]);
        // After its end, nothing more for it is kept.
        table.bytes(7, b"late".to_vec());
        table.closed(7);
        assert!(table.table().early.is_empty());
    }

    #[test]
    fn a_stream_that_ended_before_it_was_named_ends_at_once() {
        let table = StreamTable::default();
        table.bytes(3, b"last words".to_vec());
        table.closed(3);
        let (sender, received) = channel();
        table.claim(3, sender);
        let got: Vec<Vec<u8>> = received.try_iter().collect();
        assert_eq!(got, [b"last words".to_vec(), Vec::new()]);
        assert!(table.table().open.is_empty());
    }
}
