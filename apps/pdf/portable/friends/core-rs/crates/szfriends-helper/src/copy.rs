//! The per-user copy of the helper (ADR 0015 § 14): an app never spawns the helper from its own install, because a
//! Windows installer cannot replace an executable that is running, and an AppImage's files vanish with the mount
//! when the app that mounted it quits. So the app copies its embedded helper to
//! `<state dir>/helper/<version>-<build>-<16 hex of SHA-256>/` (written under a temporary name, synced, renamed into
//! place, checked against the digest; an existing copy is reused and never rewritten) and spawns that copy, detached.
//! The running helper prunes copies older than itself.

use std::fs::{self, OpenOptions};
use std::io::{self, ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use sha2::{Digest, Sha256};
use szfriends_core::paths::{helper_copy_dir, helper_executable, stale_helper_copies, Platform};

use crate::log;
use crate::stamp::{self, Stamp};
use crate::state::{StateDir, ENV_STATE_DIR};

/// The helper an app carries: where it is, its stamp and its digest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbeddedHelper {
    pub path: PathBuf,
    pub stamp: Stamp,
    pub digest: [u8; 32],
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn sha256_of(path: &Path) -> io::Result<[u8; 32]> {
    Ok(Sha256::digest(fs::read(path)?).into())
}

impl EmbeddedHelper {
    /// Reads the helper binary at `path`: it must carry a stamp.
    pub fn inspect(path: &Path) -> io::Result<Self> {
        let bytes = fs::read(path)?;
        let stamp = stamp::find(&bytes).ok_or_else(|| io::Error::new(ErrorKind::InvalidData, "not a helper"))?;
        Ok(Self { path: path.to_owned(), stamp, digest: Sha256::digest(&bytes).into() })
    }

    /// The copy directory's name for this binary.
    pub fn copy_dir(&self, state: &StateDir) -> io::Result<PathBuf> {
        let build = u32::try_from(self.stamp.build).map_err(|_| io::Error::from(ErrorKind::InvalidData))?;
        helper_copy_dir(&state.path, &self.stamp.version, build, &hex(&self.digest))
            .ok_or_else(|| io::Error::new(ErrorKind::InvalidData, "no copy directory for this helper"))
    }
}

/// Why the per-user copy cannot be run: it was made, or found, and then its executable was gone. Antivirus software
/// does this when it quarantines a file (Microsoft Defender removes it and leaves the directory), so the copy is made
/// again once per process; when it is gone again the error carries this, which [`is_blocked`] recognises.
#[derive(Debug)]
pub struct CopyRemoved(pub PathBuf);

impl std::fmt::Display for CopyRemoved {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} was removed after it was made, as security software removes a file it blocks", self.0.display())
    }
}

impl std::error::Error for CopyRemoved {}

/// Whether `error` says security software stopped the helper: Windows refused the file as infected or potentially
/// unwanted (`ERROR_VIRUS_INFECTED`, `ERROR_VIRUS_DELETED`), or the copy was removed again after it was made.
pub fn is_blocked(error: &io::Error) -> bool {
    const ERROR_VIRUS_INFECTED: i32 = 225;
    const ERROR_VIRUS_DELETED: i32 = 226;
    matches!(error.raw_os_error(), Some(ERROR_VIRUS_INFECTED | ERROR_VIRUS_DELETED))
        || error.get_ref().is_some_and(|inner| inner.is::<CopyRemoved>())
}

/// Copy directories whose missing executable this process already wrote again: once each, so security software that
/// removes the file every time is not handed a new one every few seconds.
fn rewritten() -> &'static std::sync::Mutex<std::collections::HashSet<PathBuf>> {
    static REWRITTEN: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<PathBuf>>> =
        std::sync::OnceLock::new();
    REWRITTEN.get_or_init(Default::default)
}

/// The copy of `embedded` in the state directory, made if missing. An existing copy whose digest differs is refused,
/// never rewritten: a running helper's file is never touched. A copy directory whose executable is gone (quarantined
/// by antivirus software, or deleted by hand) runs nothing, so its executable is written again, once per process.
pub fn ensure_copy(state: &StateDir, embedded: &EmbeddedHelper) -> io::Result<PathBuf> {
    let directory = embedded.copy_dir(state)?;
    let executable = directory.join(helper_executable(Platform::current()));
    if directory.is_dir() && !executable.exists() {
        let first = rewritten().lock().unwrap_or_else(|e| e.into_inner()).insert(directory.clone());
        if !first {
            return Err(io::Error::new(ErrorKind::NotFound, CopyRemoved(executable)));
        }
        log!("{} is missing; writing it again", executable.display());
        rewrite_executable(&embedded.path, &executable)?;
    }
    if !directory.exists() {
        let parent = directory.parent().ok_or_else(|| io::Error::from(ErrorKind::InvalidInput))?;
        crate::state::create_private_dir(&state.path)?;
        fs::create_dir_all(parent)?;
        let mut random = [0u8; 8];
        szfriends_crypto::random_bytes(&mut random);
        let incoming = parent.join(format!(".incoming-{}", hex(&random)));
        let made = write_copy(&embedded.path, &incoming, helper_executable(Platform::current()))
            .and_then(|()| fs::rename(&incoming, &directory));
        if let Err(error) = made {
            let _ = fs::remove_dir_all(&incoming);
            // Another app made the same copy at the same moment: theirs is as good as ours.
            if !directory.exists() {
                return Err(error);
            }
        }
        if let Ok(handle) = fs::File::open(parent) {
            let _ = handle.sync_all();
        }
    }
    let digest = match sha256_of(&executable) {
        Ok(digest) => digest,
        // Made a moment ago and gone already: removed by something else, not by us.
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Err(io::Error::new(ErrorKind::NotFound, CopyRemoved(executable)))
        }
        Err(error) => return Err(error),
    };
    if digest != embedded.digest {
        return Err(io::Error::new(ErrorKind::InvalidData, format!("{} is not this helper", executable.display())));
    }
    Ok(executable)
}

/// Writes the executable of an existing copy directory again: under a temporary name beside it, synced, then renamed
/// into place, so a helper started meanwhile never runs half a file.
fn rewrite_executable(source: &Path, executable: &Path) -> io::Result<()> {
    let directory = executable.parent().ok_or_else(|| io::Error::from(ErrorKind::InvalidInput))?;
    let mut random = [0u8; 8];
    szfriends_crypto::random_bytes(&mut random);
    let incoming = directory.join(format!(".incoming-{}", hex(&random)));
    let written = write_copy(source, &incoming, helper_executable(Platform::current()))
        .and_then(|()| fs::rename(incoming.join(helper_executable(Platform::current())), executable));
    let _ = fs::remove_dir_all(&incoming);
    written
}

fn write_copy(source: &Path, directory: &Path, file_name: &str) -> io::Result<()> {
    fs::create_dir(directory)?;
    let bytes = fs::read(source)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o700);
    }
    let mut file = options.open(directory.join(file_name))?;
    file.write_all(&bytes)?;
    file.sync_all()
}

/// Starts the helper at `executable`, detached from the app: its own process group (Linux) or a detached process
/// outside the app's job when the job allows (Windows), no inherited standard streams, reaped by a thread of ours.
/// A test or development home is passed on, so the two always agree; the person's own home is not (the helper finds
/// it itself), so a helper serving the person never takes their home for a test one, nor inherits a stray
/// `$SZFRIENDS_STATE_DIR` from the app's environment.
pub fn spawn(executable: &Path, state: &StateDir) -> io::Result<u32> {
    let mut command = Command::new(executable);
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).env_remove(ENV_STATE_DIR);
    if !state.is_platform_default() {
        command.env(ENV_STATE_DIR, &state.path);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    #[cfg(windows)]
    let child = {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x8;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x200;
        const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW;
        // Out of the app's job, so a job that kills its processes with the app does not take Friends down; a job
        // that forbids breaking away refuses the flag, and then the helper stays in it.
        match command.creation_flags(flags | CREATE_BREAKAWAY_FROM_JOB).spawn() {
            Ok(child) => child,
            Err(_) => command.creation_flags(flags).spawn()?,
        }
    };
    #[cfg(not(windows))]
    let child = command.spawn()?;
    let pid = child.id();
    let mut child = child;
    let _ = std::thread::Builder::new().name("szfriends-reaper".into()).spawn(move || {
        let _ = child.wait();
    });
    Ok(pid)
}

/// Removes copies older than the running helper's own; a copy still running (Windows) stays until a later start.
pub fn prune_stale_copies(state: &StateDir) {
    let Ok(own) = std::env::current_exe() else { return };
    let base = state.path.join("helper");
    let own_dir = own.parent().filter(|dir| dir.parent() == Some(base.as_path()));
    let Some(current) = own_dir.and_then(|d| d.file_name()).and_then(|n| n.to_str()).map(str::to_owned) else {
        return;
    };
    let Ok(entries) = fs::read_dir(&base) else { return };
    let names: Vec<String> = entries.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect();
    for stale in stale_helper_copies(&names, &current) {
        match fs::remove_dir_all(base.join(stale)) {
            Ok(()) => log!("removed the older helper copy {stale}"),
            Err(error) => log!("older helper copy {stale} stays for now: {error}"),
        }
    }
}

/// Whether the process running `executable` carries helper build `build`: that executable itself (a helper run
/// with `--handover`, or an app that links the helper's client) or a helper beside it (an app's embedded helper).
pub fn executable_carries_build(executable: &Path, build: u64) -> bool {
    let carries = |path: &Path| stamp::read(path).ok().flatten().is_some_and(|s| s.build == build);
    if carries(executable) {
        return true;
    }
    // `/proc/<pid>/exe` names the file; its directory is the link's target's.
    let resolved = fs::read_link(executable).unwrap_or_else(|_| executable.to_owned());
    let Some(directory) = resolved.parent() else { return false };
    let Ok(entries) = fs::read_dir(directory) else { return false };
    entries.filter_map(Result::ok).any(|entry| {
        let name = entry.file_name();
        name.to_str().is_some_and(|n| n.starts_with("szfriends-helper")) && carries(&entry.path())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A state directory of the test's own, removed afterwards.
    struct Home(PathBuf);

    impl Home {
        fn new(name: &str) -> Self {
            let mut random = [0u8; 8];
            szfriends_crypto::random_bytes(&mut random);
            Self(std::env::temp_dir().join(format!("szf-copy-{name}-{}", hex(&random))))
        }
    }

    impl Drop for Home {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// This test binary carries the build stamp, so it stands in for the helper an app embeds.
    fn embedded() -> EmbeddedHelper {
        EmbeddedHelper::inspect(&std::env::current_exe().unwrap()).expect("the test binary carries a stamp")
    }

    #[test]
    fn a_copy_whose_executable_was_removed_is_made_again_once() {
        let home = Home::new("removed");
        let state = StateDir::new(home.0.clone());
        let embedded = embedded();
        let executable = ensure_copy(&state, &embedded).expect("the first copy");
        assert_eq!(sha256_of(&executable).unwrap(), embedded.digest);

        // What a quarantine leaves: the directory, without the file.
        fs::remove_file(&executable).unwrap();
        let again = ensure_copy(&state, &embedded).expect("the copy is made again");
        assert_eq!(again, executable);
        assert_eq!(sha256_of(&again).unwrap(), embedded.digest, "the whole helper, as embedded");
        let leftovers: Vec<_> =
            fs::read_dir(executable.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(leftovers.len(), 1, "nothing but the executable is left: {leftovers:?}");

        // Removed again in the same run: not written a third time, and the error says it was blocked.
        fs::remove_file(&executable).unwrap();
        let error = ensure_copy(&state, &embedded).expect_err("not made a third time");
        assert!(is_blocked(&error), "{error}");
        assert!(!executable.exists());
    }

    #[test]
    fn only_security_refusals_count_as_blocked() {
        assert!(is_blocked(&io::Error::from_raw_os_error(225)));
        assert!(is_blocked(&io::Error::from_raw_os_error(226)));
        assert!(!is_blocked(&io::Error::from(ErrorKind::NotFound)));
        assert!(!is_blocked(&io::Error::from(ErrorKind::PermissionDenied)));
        assert!(is_blocked(&io::Error::new(ErrorKind::NotFound, CopyRemoved(PathBuf::from("x")))));
    }
}
