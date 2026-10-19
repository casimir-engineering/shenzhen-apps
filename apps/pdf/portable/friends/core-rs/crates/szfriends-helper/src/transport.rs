//! What the server needs of a connection and a listener, whatever carries the bytes: a Unix socket on Linux, a named
//! pipe on Windows, an in-memory pair in tests and in a phone app, where the core runs in the app's own process
//! (ADR 0015 § 3: the same JSON frames, carried by a channel instead of a socket).

use std::collections::VecDeque;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};

/// One connected stream that a reader thread and a writer share.
pub trait Duplex: Send + Sync + 'static {
    /// `Ok(0)` at the end, including after [`Duplex::close`].
    fn read(&self, buffer: &mut [u8]) -> io::Result<usize>;
    fn write_all(&self, bytes: &[u8]) -> io::Result<()>;
    /// Ends reads and writes on every thread; bytes already written still reach the other end.
    fn close(&self);
}

/// What the listener learnt about the process at the other end, after its checks passed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PeerInfo {
    pub pid: Option<u32>,
    /// The executable it runs (`/proc/<pid>/exe` on Linux), read for a handover's build check.
    pub executable: Option<PathBuf>,
}

/// Accepts connections whose peer passed the platform's checks (the same user; on Windows also no sandbox and no
/// lower integrity level). A refused peer is closed without a word and never returned.
pub trait Listener: Send + Sync + 'static {
    /// The next connection, or `None` once [`Listener::stop`] was called.
    fn accept(&self) -> io::Result<Option<(Arc<dyn Duplex>, PeerInfo)>>;
    /// Stops accepting and removes the name clients find the helper by, while the lock is still held, so a client
    /// that comes now spawns a successor instead of waiting on a helper that is leaving.
    fn stop(&self);
}

#[derive(Default)]
struct Pipe {
    /// The bytes not yet read, and whether the writing end closed.
    bytes: Mutex<(VecDeque<u8>, bool)>,
    ready: Condvar,
}

impl Pipe {
    fn close(&self) {
        self.bytes.lock().unwrap_or_else(|e| e.into_inner()).1 = true;
        self.ready.notify_all();
    }
}

/// One end of an in-memory connection ([`memory_pair`]).
pub struct MemoryEnd {
    incoming: Arc<Pipe>,
    outgoing: Arc<Pipe>,
    closed: AtomicBool,
}

impl std::fmt::Debug for MemoryEnd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemoryEnd").field("closed", &self.closed.load(Ordering::SeqCst)).finish()
    }
}

impl Duplex for MemoryEnd {
    fn read(&self, buffer: &mut [u8]) -> io::Result<usize> {
        let mut state = self.incoming.bytes.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if self.closed.load(Ordering::SeqCst) {
                return Ok(0);
            }
            if !state.0.is_empty() {
                let n = buffer.len().min(state.0.len());
                for (slot, byte) in buffer.iter_mut().zip(state.0.drain(..n)) {
                    *slot = byte;
                }
                return Ok(n);
            }
            if state.1 {
                return Ok(0);
            }
            state = self.incoming.ready.wait(state).unwrap_or_else(|e| e.into_inner());
        }
    }

    fn write_all(&self, bytes: &[u8]) -> io::Result<()> {
        let mut state = self.outgoing.bytes.lock().unwrap_or_else(|e| e.into_inner());
        if state.1 || self.closed.load(Ordering::SeqCst) {
            return Err(io::Error::from(io::ErrorKind::BrokenPipe));
        }
        state.0.extend(bytes);
        self.outgoing.ready.notify_all();
        Ok(())
    }

    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.outgoing.close();
        self.incoming.close();
    }
}

/// Two connected in-memory ends: what one writes, the other reads. Closing either ends both.
pub fn memory_pair() -> (Arc<MemoryEnd>, Arc<MemoryEnd>) {
    let (a, b) = (Arc::new(Pipe::default()), Arc::new(Pipe::default()));
    let left = MemoryEnd { incoming: a.clone(), outgoing: b.clone(), closed: AtomicBool::new(false) };
    let right = MemoryEnd { incoming: b, outgoing: a, closed: AtomicBool::new(false) };
    (Arc::new(left), Arc::new(right))
}

#[cfg(unix)]
mod unix_stream {
    use std::io::{self, Read, Write};
    use std::net::Shutdown;
    use std::os::unix::net::UnixStream;

    impl super::Duplex for UnixStream {
        fn read(&self, buffer: &mut [u8]) -> io::Result<usize> {
            loop {
                match Read::read(&mut &*self, buffer) {
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    other => return other,
                }
            }
        }

        fn write_all(&self, bytes: &[u8]) -> io::Result<()> {
            Write::write_all(&mut &*self, bytes)
        }

        fn close(&self) {
            let _ = self.shutdown(Shutdown::Both);
        }
    }
}

#[cfg(windows)]
mod pipe_stream {
    use std::io;

    use szfriends_helper_sys::pipe::PipeStream;

    impl super::Duplex for PipeStream {
        fn read(&self, buffer: &mut [u8]) -> io::Result<usize> {
            PipeStream::read(self, buffer)
        }

        fn write_all(&self, bytes: &[u8]) -> io::Result<()> {
            PipeStream::write_all(self, bytes)
        }

        fn close(&self) {
            PipeStream::close(self)
        }
    }
}
