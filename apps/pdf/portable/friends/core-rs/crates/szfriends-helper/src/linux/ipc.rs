//! PROTOCOL.md § Transport on Linux, as written: `flock` on `helper.lock` decides the single instance, the socket
//! lives in a 0700 directory of the user's (or the short fallback under `$XDG_RUNTIME_DIR`), and both ends check
//! the other's uid with `SO_PEERCRED`: the helper closes a stranger's connection without a word, and a client sends
//! nothing to another user's helper.

use std::fs::{File, OpenOptions};
use std::io::{self, ErrorKind};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use rustix::fs::{FlockOperation, Mode, OFlags};
use szfriends_contract::socket::{socket_path, SUN_PATH_MAX};

use crate::client::ConnectError;
use crate::log;
use crate::state::{create_private_dir, StateDir};
use crate::transport::{Duplex, Listener, PeerInfo};

fn own_uid() -> u32 {
    rustix::process::geteuid().as_raw()
}

/// Held for the helper's lifetime; the kernel drops it on any exit, so a stale lock cannot exist.
#[derive(Debug)]
pub struct InstanceLock(#[allow(dead_code)] File);

/// `flock` on `<state dir>/helper.lock`: `Ok(None)` when another helper holds it.
pub fn acquire_lock(state: &StateDir) -> io::Result<Option<InstanceLock>> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags((OFlags::NOFOLLOW | OFlags::CLOEXEC).bits() as i32)
        .open(state.path.join("helper.lock"))?;
    match rustix::fs::flock(&file, FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => Ok(Some(InstanceLock(file))),
        Err(rustix::io::Errno::WOULDBLOCK) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

/// `$XDG_RUNTIME_DIR` when it is absolute, else `/tmp`.
pub fn user_temp_dir() -> String {
    std::env::var("XDG_RUNTIME_DIR").ok().filter(|d| d.starts_with('/')).unwrap_or_else(|| "/tmp".to_owned())
}

/// Where the helper for `state` listens.
pub fn helper_socket(state: &StateDir) -> io::Result<PathBuf> {
    socket_path(&state.canonical, &user_temp_dir(), SUN_PATH_MAX)
        .map(|(path, _)| PathBuf::from(path))
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidInput, "no socket path fits"))
}

/// The socket's directory must be ours, a real directory, and closed to everyone else.
fn directory_is_safe(socket: &Path) -> io::Result<bool> {
    let directory = socket.parent().ok_or_else(|| io::Error::from(ErrorKind::InvalidInput))?;
    let metadata = std::fs::symlink_metadata(directory)?;
    Ok(metadata.is_dir() && metadata.uid() == own_uid() && metadata.permissions().mode() & 0o077 == 0)
}

/// The helper's listening socket.
#[derive(Debug)]
pub struct SocketListener {
    listener: UnixListener,
    path: PathBuf,
    stopped: AtomicBool,
}

impl SocketListener {
    /// Binds `path`. Only the lock holder calls this, so a socket file already there is a dead helper's.
    pub fn bind(path: &Path) -> io::Result<Self> {
        let directory = path.parent().ok_or_else(|| io::Error::from(ErrorKind::InvalidInput))?;
        create_private_dir(directory)?;
        if !directory_is_safe(path)? {
            return Err(io::Error::new(ErrorKind::PermissionDenied, "unsafe socket directory"));
        }
        let _ = std::fs::remove_file(path);
        // Created 0600 from the start, never chmod-ed after bind, so no other user can ever connect.
        let previous = rustix::process::umask(Mode::from_raw_mode(0o077));
        let bound = UnixListener::bind(path);
        rustix::process::umask(previous);
        Ok(Self { listener: bound?, path: path.to_owned(), stopped: AtomicBool::new(false) })
    }
}

/// The uid and pid at the other end of a connected socket.
fn peer(stream: &UnixStream) -> Option<(u32, u32)> {
    let credentials = rustix::net::sockopt::socket_peercred(stream).ok()?;
    Some((credentials.uid.as_raw(), credentials.pid.as_raw_nonzero().get() as u32))
}

impl Listener for SocketListener {
    fn accept(&self) -> io::Result<Option<(Arc<dyn Duplex>, PeerInfo)>> {
        loop {
            let accepted = self.listener.accept();
            if self.stopped.load(Ordering::SeqCst) {
                return Ok(None);
            }
            let (stream, _) = match accepted {
                Ok(pair) => pair,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            };
            match peer(&stream) {
                Some((uid, pid)) if uid == own_uid() => {
                    let executable = Some(PathBuf::from(format!("/proc/{pid}/exe")));
                    return Ok(Some((Arc::new(stream), PeerInfo { pid: Some(pid), executable })));
                }
                // Closed without a word: a refused peer learns nothing about Friends.
                other => log!("refused a connection from uid {:?}", other.map(|(uid, _)| uid)),
            }
        }
    }

    fn stop(&self) {
        if !self.stopped.swap(true, Ordering::SeqCst) {
            // Unlinked while the lock is still held: a client that comes now gets "no helper" and spawns, and the
            // spawned helper waits its turn on the lock instead of finding a socket nobody answers.
            let _ = std::fs::remove_file(&self.path);
            // Wakes the blocked accept().
            let _ = rustix::net::shutdown(&self.listener, rustix::net::Shutdown::Both);
        }
    }
}

/// Connects to the helper for `state`, checking the socket's directory first and the helper's uid before anything
/// is sent.
pub fn connect(state: &StateDir) -> Result<UnixStream, ConnectError> {
    let path = helper_socket(state).map_err(ConnectError::Io)?;
    match directory_is_safe(&path) {
        Ok(true) => {}
        Ok(false) => return Err(ConnectError::Refused("unsafe_directory")),
        Err(e) if e.kind() == ErrorKind::NotFound => return Err(ConnectError::NoHelper),
        Err(e) => return Err(ConnectError::Io(e)),
    }
    let stream = match UnixStream::connect(&path) {
        Ok(stream) => stream,
        Err(e) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::ConnectionRefused) => {
            return Err(ConnectError::NoHelper)
        }
        Err(e) => return Err(ConnectError::Io(e)),
    };
    checked(stream)
}

/// The client's check of a connected socket: the helper at the other end must run as this user.
pub fn checked(stream: UnixStream) -> Result<UnixStream, ConnectError> {
    match peer(&stream) {
        Some((uid, _)) if uid == own_uid() => Ok(stream),
        _ => Err(ConnectError::Refused("peer_uid")),
    }
}
