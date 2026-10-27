//! Client mode on a Mac: the Objective-C helper, the one ShenzhenPDF, Shenzhen Files and Shenzhen 3D's Electron
//! app share, with one identity per Mac user (ADR 0015 § 2). Nothing Rust serves Friends here. The rules are
//! PROTOCOL.md § Transport's, as the C client library applies them: the socket path from the canonical state
//! directory, the socket directory checked before connecting, the helper's uid checked before a byte is sent, and
//! in a team-signed app the helper's code signature too ([`super::super::mac_signing`]).

use std::ffi::CStr;
use std::io::ErrorKind;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use szfriends_contract::lifecycle::{backoff, RETRY_FIRST};
use szfriends_contract::socket::{socket_path, SUN_PATH_MAX};
use szfriends_helper::client::ClientConnection;
use szfriends_helper::stamp::Stamp;
use szfriends_helper::state::{StateDir, ENV_STATE_DIR};

use super::{Connector, NotConnected};

const PATIENCE: Duration = Duration::from_secs(10);

/// The helper an app embeds: its executable inside `Shenzhen Friends.app`, and the version keys of its
/// `Info.plist`, sent in hello so an older running helper hands over.
#[derive(Clone, Debug)]
pub struct MacHelper {
    pub executable: PathBuf,
    pub version: String,
    pub build: u64,
}

impl MacHelper {
    /// Reads `<app>/Contents/Info.plist` (XML) for CFBundleShortVersionString and CFBundleVersion; a missing or
    /// malformed build is 0, which never wins a handover.
    pub fn from_bundle(app: &Path) -> Option<Self> {
        let plist = std::fs::read_to_string(app.join("Contents/Info.plist")).ok()?;
        let value = |key: &str| {
            let after = plist.split(&format!("<key>{key}</key>")).nth(1)?;
            let start = after.find("<string>")? + "<string>".len();
            let end = after[start..].find("</string>")?;
            after[..start + end].trim_start().starts_with("<string>").then(|| after[start..start + end].to_owned())
        };
        let name = app.file_stem()?.to_str()?;
        Some(Self {
            executable: app.join("Contents/MacOS").join(name),
            version: value("CFBundleShortVersionString").unwrap_or_else(|| "0".into()),
            build: value("CFBundleVersion").and_then(|b| b.parse().ok()).unwrap_or(0),
        })
    }
}

#[derive(Debug)]
pub struct MacConnector {
    state: StateDir,
    /// Whether the state directory is a development or test home (passed on to a helper we start).
    overridden: bool,
    helper: Option<MacHelper>,
    team: Option<String>,
}

/// `~/Library/Application Support/Shenzhen Friends`, or `home` (`Config::state_dir`, a development or test run's
/// own) when the app is not signed by a team: a team-signed build ignores it, as the helper ignores
/// `$SZFRIENDS_STATE_DIR` there.
pub fn state_dir(team_signed: bool, home: Option<PathBuf>) -> Option<(PathBuf, bool)> {
    if let Some(dir) = home.filter(|p| p.is_absolute() && !team_signed) {
        return Some((dir, true));
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).filter(|p| p.is_absolute())?;
    Some((home.join("Library/Application Support/Shenzhen Friends"), false))
}

fn user_temp_dir() -> Option<String> {
    let mut buffer = vec![0u8; 1024];
    // SAFETY: confstr writes at most buffer.len() bytes, NUL-terminated, into the buffer we own.
    let length = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buffer.as_mut_ptr().cast(), buffer.len()) };
    if length == 0 || length > buffer.len() {
        return None;
    }
    let text = CStr::from_bytes_until_nul(&buffer).ok()?.to_str().ok()?;
    Some(text.to_owned())
}

fn own_uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: the descriptor is a connected Unix socket we own; uid and gid are valid out-pointers.
    let result = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    (result == 0).then_some(uid)
}

impl MacConnector {
    pub fn new(helper: Option<MacHelper>, team: Option<String>, home: Option<PathBuf>) -> Option<Self> {
        let (path, overridden) = state_dir(team.is_some(), home)?;
        Some(Self { state: StateDir::new(path), overridden, helper, team })
    }

    pub fn state_dir(&self) -> &Path {
        &self.state.path
    }

    fn socket(&self) -> Result<PathBuf, NotConnected> {
        let temp = user_temp_dir().ok_or_else(|| NotConnected::because("no user temporary directory"))?;
        socket_path(&self.state.canonical, &temp, SUN_PATH_MAX)
            .map(|(path, _)| PathBuf::from(path))
            .ok_or_else(|| NotConnected::because("no socket path fits"))
    }

    /// One attempt; `Ok(None)` when no helper answers.
    fn try_connect(&self) -> Result<Option<UnixStream>, NotConnected> {
        let path = self.socket()?;
        let directory = path.parent().ok_or_else(|| NotConnected::because("no socket directory"))?;
        match std::fs::symlink_metadata(directory) {
            Ok(m) if m.is_dir() && m.uid() == own_uid() && m.permissions().mode() & 0o077 == 0 => {}
            Ok(_) => return Err(NotConnected::because("unsafe_directory")),
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(NotConnected::because(e.to_string())),
        }
        let stream = match UnixStream::connect(&path) {
            Ok(stream) => stream,
            Err(e) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::ConnectionRefused) => return Ok(None),
            Err(e) => return Err(NotConnected::because(e.to_string())),
        };
        if peer_uid(&stream) != Some(own_uid()) {
            return Err(NotConnected::because("peer_uid"));
        }
        if let Some(team) = &self.team {
            if !crate::mac_signing::peer_signed_by(&stream, team) {
                return Err(NotConnected::because("peer_signature"));
            }
        }
        Ok(Some(stream))
    }

    /// Starts the helper detached: its own process group, no inherited streams, reaped by a thread of ours. Only
    /// a test home is passed on; the person's own helper finds its home itself.
    fn spawn(&self, helper: &MacHelper) -> std::io::Result<()> {
        let mut command = Command::new(&helper.executable);
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).env_remove(ENV_STATE_DIR);
        if self.overridden {
            command.env(ENV_STATE_DIR, &self.state.path);
        }
        std::os::unix::process::CommandExt::process_group(&mut command, 0);
        let mut child = command.spawn()?;
        std::thread::spawn(move || child.wait());
        Ok(())
    }
}

impl Connector for MacConnector {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        let deadline = Instant::now() + PATIENCE;
        let mut base = RETRY_FIRST;
        let mut spawned = false;
        loop {
            if let Some(stream) = self.try_connect()? {
                return Ok(ClientConnection::new(Arc::new(stream)));
            }
            let Some(helper) = &self.helper else { return Err(NotConnected::because("no helper is running")) };
            // Any number of apps may spawn at once; the helper's lock lets one win. Once per attempt is enough:
            // a duplicate exits at once.
            if !spawned {
                self.spawn(helper).map_err(|e| NotConnected::because(format!("cannot start the helper: {e}")))?;
                spawned = true;
            }
            let mut random = [0u8; 4];
            szfriends_crypto::random_bytes(&mut random);
            let (delay, next) = backoff(base, u32::from_le_bytes(random));
            base = next;
            if Instant::now() + delay > deadline {
                return Err(NotConnected::because("the helper did not answer"));
            }
            std::thread::sleep(delay);
        }
    }

    fn embedded(&self) -> Option<Stamp> {
        self.helper.as_ref().map(|h| Stamp { version: h.version.clone(), build: h.build })
    }
}
