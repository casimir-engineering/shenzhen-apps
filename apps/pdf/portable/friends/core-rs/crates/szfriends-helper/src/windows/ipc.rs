//! ADR 0015 § 8 on Windows: `LockFileEx` on `ipc\helper.lock` decides the single instance; the holder creates a pipe
//! with an unguessable name (a DACL and owner for the user alone, the first instance claimed, remote clients
//! rejected) and advertises it in `ipc\helper.pipe`; a client accepts only that name, for its own user and state
//! directory, and checks the server before sending a byte; the helper checks each client the same way.

use std::fs::{File, OpenOptions};
use std::io::{self, ErrorKind, Read, Write};
use std::os::windows::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use szfriends_contract::pipe::{
    advertised_name, advertised_name_path, check_client, check_server, lock_owner, lock_owner_line, lock_path,
    pipe_name, IntegrityLevel, OwnToken, PeerFacts, PeerRefusal, Sid, LOCKED_BYTE,
};
use szfriends_helper_sys::pipe::{PipeListener, PipeStream};
use szfriends_helper_sys::{lock, token};

use crate::client::ConnectError;
use crate::log;
use crate::state::StateDir;
use crate::transport::{Duplex, Listener, PeerInfo};

/// `FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`: clients read the holder's line while it holds the lock.
const SHARE_ALL: u32 = 0x7;
/// `ERROR_FILE_NOT_FOUND`: no pipe of that name exists.
const ERROR_FILE_NOT_FOUND: i32 = 2;

/// This process's user and integrity level; `None` when Windows will not say.
pub fn own_token() -> Option<OwnToken> {
    let facts = token::own();
    Some(OwnToken { user: Sid::parse(facts.user.as_deref()?)?, integrity: IntegrityLevel(facts.integrity?) })
}

/// What Windows reports about process `pid` (and, for a client's check, the pipe's owner).
fn peer_facts(pid: Option<u32>, pipe_owner: Option<String>) -> PeerFacts {
    let token = pid.map(token::of_process).unwrap_or_default();
    PeerFacts {
        process_id: pid,
        process_user: token.user.as_deref().and_then(Sid::parse),
        integrity: token.integrity.map(IntegrityLevel),
        app_container: token.app_container,
        pipe_owner: pipe_owner.as_deref().and_then(Sid::parse),
    }
}

fn ipc_dir(state: &StateDir) -> PathBuf {
    state.path.join("ipc")
}

/// Held for the helper's lifetime; Windows releases the byte lock when the process exits, however it exits.
#[derive(Debug)]
pub struct InstanceLock(#[allow(dead_code)] File);

/// Locks the byte past the holder's line in `ipc\helper.lock`; `Ok(None)` when another helper holds it, in which
/// case nothing in the file is touched.
pub fn acquire_lock(state: &StateDir) -> io::Result<Option<InstanceLock>> {
    std::fs::create_dir_all(ipc_dir(state))?;
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .share_mode(SHARE_ALL)
        .open(lock_path(&state.path))?;
    if !lock::try_lock_byte(&file, LOCKED_BYTE)? {
        return Ok(None);
    }
    file.set_len(0)?;
    file.write_all(lock_owner_line(token::current_process_id()).as_bytes())?;
    file.flush()?;
    Ok(Some(InstanceLock(file)))
}

fn read_shared(path: &std::path::Path) -> io::Result<String> {
    let mut text = String::new();
    OpenOptions::new().read(true).share_mode(SHARE_ALL).open(path)?.take(4096).read_to_string(&mut text)?;
    Ok(text)
}

/// The helper's pipe: its instances and the advertised name.
#[derive(Debug)]
pub struct PipeServer {
    listener: PipeListener,
    own: OwnToken,
    name: String,
    advertised: PathBuf,
    stopped: AtomicBool,
}

impl PipeServer {
    /// Creates the pipe (failing if anyone holds its name) and then advertises it. Only the lock holder calls this.
    pub fn listen(state: &StateDir) -> io::Result<Self> {
        let own = own_token().ok_or_else(|| io::Error::other("this process's token cannot be read"))?;
        let mut nonce = [0u8; 16];
        szfriends_crypto::random_bytes(&mut nonce);
        let name = pipe_name(&own.user, &state.canonical, &nonce);
        let sid = own.user.as_str();
        let listener = PipeListener::create(&name, &format!("O:{sid}D:P(A;;GA;;;{sid})"))?;
        let advertised = advertised_name_path(&state.path);
        let mut suffix = [0u8; 8];
        szfriends_crypto::random_bytes(&mut suffix);
        let hex: String = suffix.iter().map(|b| format!("{b:02x}")).collect();
        let temporary = ipc_dir(state).join(format!("helper.pipe.{hex}.tmp"));
        let written = (|| {
            let mut file = OpenOptions::new().write(true).create_new(true).open(&temporary)?;
            file.write_all(format!("{name}\n").as_bytes())?;
            file.sync_all()?;
            // Replaced in one step, so a client reads the old name or the new one, never half of either.
            std::fs::rename(&temporary, &advertised)
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        written?;
        Ok(Self { listener, own, name, advertised, stopped: AtomicBool::new(false) })
    }

    pub fn name(&self) -> &str {
        &self.name
    }
}

impl Listener for PipeServer {
    fn accept(&self) -> io::Result<Option<(Arc<dyn Duplex>, PeerInfo)>> {
        loop {
            let Some(stream) = self.listener.accept()? else { return Ok(None) };
            let pid = stream.client_process_id();
            match check_client(&self.own, &peer_facts(pid, None)) {
                Ok(()) => {
                    let executable = pid.and_then(token::process_image);
                    return Ok(Some((Arc::new(stream), PeerInfo { pid, executable })));
                }
                Err(refusal) => {
                    // Closed without a word: a refused peer learns nothing about Friends.
                    log!("refused a client (pid {pid:?}): {refusal:?}");
                    stream.close();
                }
            }
        }
    }

    fn stop(&self) {
        if !self.stopped.swap(true, Ordering::SeqCst) {
            self.listener.stop();
            // While the lock is still held: a client that comes now finds no helper and spawns one.
            if read_shared(&self.advertised).is_ok_and(|text| text.trim_end() == self.name) {
                let _ = std::fs::remove_file(&self.advertised);
            }
        }
    }
}

fn refusal_code(refusal: PeerRefusal) -> &'static str {
    match refusal {
        PeerRefusal::Unknown => "peer_unknown",
        PeerRefusal::OtherUser => "peer_other_user",
        PeerRefusal::OtherOwner => "pipe_other_owner",
        PeerRefusal::AppContainer => "peer_app_container",
        PeerRefusal::LowerIntegrity => "peer_lower_integrity",
        PeerRefusal::NotLockOwner => "not_lock_owner",
    }
}

/// Connects to the advertised pipe and checks the server; nothing is sent before every check passed.
pub fn connect(state: &StateDir) -> Result<PipeStream, ConnectError> {
    let own = own_token().ok_or(ConnectError::Refused("own_token"))?;
    let contents = match read_shared(&advertised_name_path(&state.path)) {
        Ok(contents) => contents,
        Err(e) if e.kind() == ErrorKind::NotFound => return Err(ConnectError::NoHelper),
        Err(e) => return Err(ConnectError::Io(e)),
    };
    // A name in any other form, another user's or another directory's, is never opened.
    let Some(name) = advertised_name(&contents, &own.user, &state.canonical) else {
        return Err(ConnectError::Refused("advertised_name"));
    };
    let stream = match PipeStream::connect(&name, Duration::from_secs(2)) {
        Ok(stream) => stream,
        Err(e) if e.raw_os_error() == Some(ERROR_FILE_NOT_FOUND) => return Err(ConnectError::NoHelper),
        Err(e) => return Err(ConnectError::Io(e)),
    };
    // Read after connecting, so a name left behind by a helper that has gone is not trusted.
    let holder = read_shared(&lock_path(&state.path)).ok().and_then(|text| lock_owner(&text));
    let facts = peer_facts(stream.server_process_id(), stream.owner());
    match check_server(&own, holder, &facts) {
        Ok(()) => Ok(stream),
        Err(refusal) => {
            stream.close();
            Err(ConnectError::Refused(refusal_code(refusal)))
        }
    }
}
