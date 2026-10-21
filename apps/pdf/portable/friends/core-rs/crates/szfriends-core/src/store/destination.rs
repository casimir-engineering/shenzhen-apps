//! Where received files are published (PROTOCOL.md § Views, `settings`, "The folder received files go to"): the
//! folder the person chose on this computer (`received-folder` in the state directory, one absolute path, never
//! synced), else the default Downloads, else the store's own `received/`, so a file is never lost.
//!
//! Bytes still arrive in `received/.partial/` and are checked there. Publishing renames the checked file into the
//! folder without ever replacing anything ("Name (2).ext" on a clash); on another volume it is copied into a hidden
//! `.<name>.part` beside its final name first, so nothing half-written ever shows under that name.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::{params, Connection};

use super::saved::{record_fallback, ReceivedFallback};
#[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
use super::transfer_files::move_no_replace;
use super::transfer_files::{ensure_private_directory, unique_destination};
use super::{new_identifier, unix_now, Result, Store};

/// The state directory's file naming the folder the person chose.
pub const RECEIVED_FOLDER_FILE: &str = "received-folder";
/// Tests: the default folder received files go to.
pub const ENV_DOWNLOADS_DIR: &str = "SZFRIENDS_DOWNLOADS_DIR";
/// The newest files the `received` view lists.
pub const RECEIVED_VIEW_MAX: usize = 100;

/// Publishes into a place the core cannot write itself (Android's public Downloads, through MediaStore).
pub trait ExternalPublisher: Send + Sync {
    /// Copies the checked file at `staged` there as `name` (made unique there); returns what the app later opens and
    /// shares (a path or a content URI) and the name it was given. `staged` stays; the caller removes it.
    fn publish(&self, staged: &Path, name: &str) -> io::Result<(String, String)>;
    /// The size of what `publish` left at `location` now, or `None` when it is gone (the person deleted it).
    fn size(&self, _location: &str) -> Option<u64> {
        None
    }
    /// A file this process can read with what is at `location` now, copied out of the place it cannot read itself.
    fn copy_out(&self, _location: &str) -> Option<PathBuf> {
        None
    }
}

/// A phone's place for received files, which the person cannot change from Friends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhoneFolder {
    /// Android: the public Downloads (MediaStore).
    Downloads,
    /// iOS: the app's Documents, shown in the Files app under On My iPhone.
    AppFiles,
    /// Android 9 and earlier: kept in the app, leaving it through Share….
    App,
}

/// Where received files go when the person chose nothing.
#[derive(Clone, Default)]
pub struct ReceivedDefaults {
    /// The default folder (Downloads); created when missing.
    pub folder: Option<PathBuf>,
    /// Tried before `folder` (Android's MediaStore).
    pub external: Option<Arc<dyn ExternalPublisher>>,
    /// On a phone the folder cannot be changed.
    pub phone: Option<PhoneFolder>,
}

impl std::fmt::Debug for ReceivedDefaults {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReceivedDefaults")
            .field("folder", &self.folder)
            .field("external", &self.external.is_some())
            .field("phone", &self.phone)
            .finish()
    }
}

impl ReceivedDefaults {
    /// `$SZFRIENDS_DOWNLOADS_DIR` when absolute, else `Downloads` inside `state_dir`: what a store under test or
    /// without a platform gets, so it never reaches the person's own Downloads.
    pub fn contained(state_dir: &Path) -> Self {
        Self { folder: Some(downloads_override().unwrap_or_else(|| state_dir.join("Downloads"))), ..Self::default() }
    }

    pub fn folder(folder: PathBuf) -> Self {
        Self { folder: Some(folder), ..Self::default() }
    }
}

/// `$SZFRIENDS_DOWNLOADS_DIR`, when set to an absolute path.
pub fn downloads_override() -> Option<PathBuf> {
    std::env::var_os(ENV_DOWNLOADS_DIR).map(PathBuf::from).filter(|p| p.is_absolute())
}

/// Why `set_received_folder` refused a path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FolderRefusal {
    /// Not an absolute path (`invalid_field`).
    NotAbsolute,
    /// Missing or unreadable (`file_missing`).
    Missing,
    /// Not a folder, not writable, inside the state directory, or on a phone (`not_allowed`).
    NotAllowed,
}

/// How a received file came: a friend's transfer, a download link, a copy from another of the person's devices.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReceivedSource {
    Friend,
    Link,
    Device,
}

impl ReceivedSource {
    pub fn name(self) -> &'static str {
        match self {
            Self::Friend => "friend",
            Self::Link => "link",
            Self::Device => "device",
        }
    }

    /// The store's `received_via`.
    pub(crate) fn via(self) -> i64 {
        match self {
            Self::Friend => 0,
            Self::Link => 1,
            Self::Device => 2,
        }
    }

    fn from_via(via: i64) -> Self {
        match via {
            1 => Self::Link,
            2 => Self::Device,
            _ => Self::Friend,
        }
    }
}

/// One row of the `received` view.
#[derive(Clone, Debug, PartialEq)]
pub struct ReceivedFile {
    pub transfer_id: String,
    pub path: String,
    pub file_name: String,
    pub received_at: i64,
    pub source: ReceivedSource,
}

/// Where the next file goes, read once: owned, so publishing can record its progress in the store meanwhile.
#[derive(Clone, Debug)]
pub(crate) struct Places {
    chosen: Option<PathBuf>,
    defaults: ReceivedDefaults,
    own: PathBuf,
}

/// The hidden file an across-volume copy is written to before it takes `destination`'s name.
pub(crate) fn part_path(destination: &Path) -> PathBuf {
    let name = destination.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    destination.with_file_name(format!(".{name}.part"))
}

pub(crate) fn sync_directory(directory: &Path) {
    #[cfg(unix)]
    if let Ok(handle) = File::open(directory) {
        let _ = handle.sync_all();
    }
    #[cfg(not(unix))]
    let _ = directory;
}

fn crosses_devices(error: &io::Error) -> bool {
    #[cfg(unix)]
    let raw = error.raw_os_error() == Some(rustix::io::Errno::XDEV.raw_os_error());
    #[cfg(windows)]
    let raw = error.raw_os_error() == Some(17); // ERROR_NOT_SAME_DEVICE
    #[cfg(not(any(unix, windows)))]
    let raw = false;
    raw || error.kind() == io::ErrorKind::CrossesDevices
}

/// Renames `from` to `to`, which must not exist: `AlreadyExists` when it does, never a replacement; `CrossesDevices`
/// (EXDEV) when they are on different volumes.
#[cfg(any(target_os = "linux", target_vendor = "apple"))]
pub(crate) fn rename_no_replace(from: &Path, to: &Path) -> io::Result<()> {
    use rustix::fs::{renameat_with, RenameFlags, CWD};
    use rustix::io::Errno;
    match renameat_with(CWD, from, CWD, to, RenameFlags::NOREPLACE) {
        Ok(()) => Ok(()),
        // A file system without the exclusive rename (some network and FUSE ones): a link, else a claimed name.
        Err(e) if [Errno::INVAL, Errno::NOSYS, Errno::NOTSUP, Errno::OPNOTSUPP].contains(&e) => {
            super::transfer_files::move_no_replace(from, to)
        }
        Err(e) => Err(e.into()),
    }
}

/// Windows, Android (whose system call filter is not asked for renameat2) and the rest: a hard link where the file
/// system has them (another volume answers ERROR_NOT_SAME_DEVICE or EXDEV, and is copied here, hidden until whole),
/// else a name claimed exclusively and the file renamed over the claim (`move_no_replace`).
#[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
pub(crate) fn rename_no_replace(from: &Path, to: &Path) -> io::Result<()> {
    move_no_replace(from, to)
}

/// Publishing's own progress, recorded before each step so a crash is finished at the next start: `Some(path)`
/// is the name about to be taken, `None` that an external publisher is about to be asked.
pub(crate) type Claim<'a> = &'a mut dyn FnMut(Option<&str>) -> Result<()>;

impl Places {
    /// Publishes the checked file at `staged` as `name`; returns where it went (a path, or an external location)
    /// and its name there. The staged file is gone afterwards. A file that could not go where it was meant to is
    /// remembered ([`super::RECEIVED_FALLBACK_FILE`]); one that did clears that.
    pub(crate) fn publish(&self, staged: &Path, name: &str, claim: Claim<'_>) -> Result<(String, String)> {
        let (published, fallback) = self.publish_somewhere(staged, name, claim)?;
        if let Some(state_dir) = self.own.parent() {
            record_fallback(state_dir, fallback);
        }
        Ok(published)
    }

    fn publish_somewhere(
        &self,
        staged: &Path,
        name: &str,
        claim: Claim<'_>,
    ) -> Result<((String, String), Option<ReceivedFallback>)> {
        if let Some(chosen) = &self.chosen {
            if let Ok(path) = publish_into(chosen, staged, name, claim)? {
                return Ok((done(path), None));
            }
        }
        if self.chosen.is_none() {
            if let Some(external) = &self.defaults.external {
                claim(None)?;
                if let Ok((location, shown)) = external.publish(staged, name) {
                    claim(Some(&location))?;
                    let _ = fs::remove_file(staged);
                    return Ok(((location, shown), None));
                }
            }
        }
        if let Some(folder) = &self.defaults.folder {
            // The default folder is made when missing, with the system's usual permissions.
            if fs::create_dir_all(folder).is_ok() {
                if let Ok(path) = publish_into(folder, staged, name, claim)? {
                    // Where it was meant to go, unless the person chose a folder (or MediaStore was meant).
                    let meant = self.chosen.is_none() && self.defaults.external.is_none();
                    return Ok((done(path), (!meant).then_some(ReceivedFallback::Downloads)));
                }
            }
        }
        ensure_private_directory(&self.own)?;
        match publish_into(&self.own, staged, name, claim)? {
            Ok(path) => Ok((done(path), Some(ReceivedFallback::Kept))),
            Err(error) => Err(error.into()),
        }
    }
}

fn done(path: PathBuf) -> (String, String) {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    (path.to_string_lossy().into_owned(), name)
}

/// Publishes into `directory`: `Ok(Err(_))` when that folder cannot take it (missing, not a folder, not writable,
/// refused by the system), so the next place is tried; `Err` only when the store could not record its progress.
fn publish_into(directory: &Path, staged: &Path, name: &str, claim: Claim<'_>) -> Result<io::Result<PathBuf>> {
    match fs::metadata(directory) {
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Ok(Err(io::Error::new(io::ErrorKind::NotADirectory, "not a folder"))),
        Err(error) => return Ok(Err(error)),
    }
    for _ in 0..64 {
        let destination = unique_destination(directory, name);
        claim(Some(&destination.to_string_lossy()))?;
        match rename_no_replace(staged, &destination) {
            Ok(()) => {
                sync_directory(directory);
                return Ok(Ok(destination));
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) if crosses_devices(&e) => return copy_across(directory, staged, name, destination, claim),
            Err(e) => return Ok(Err(e)),
        }
    }
    Ok(Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free name")))
}

/// The destination is on another volume: a hidden copy beside it, made durable, then renamed to its name without
/// replacing anything; the staged file goes last.
fn copy_across(
    directory: &Path,
    staged: &Path,
    name: &str,
    mut destination: PathBuf,
    claim: Claim<'_>,
) -> Result<io::Result<PathBuf>> {
    let part = part_path(&destination);
    let copied = (|| -> io::Result<()> {
        // A leftover of ours from an interrupted copy under this very name: started again.
        if fs::symlink_metadata(&part).is_ok_and(|m| m.is_file()) {
            fs::remove_file(&part)?;
        }
        let mut out = OpenOptions::new().write(true).create_new(true).open(&part)?;
        io::copy(&mut File::open(staged)?, &mut out)?;
        out.sync_all()
    })();
    if let Err(error) = copied {
        let _ = fs::remove_file(&part);
        return Ok(Err(error));
    }
    for _ in 0..64 {
        match rename_no_replace(&part, &destination) {
            Ok(()) => {
                sync_directory(directory);
                let _ = fs::remove_file(staged);
                return Ok(Ok(destination));
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                destination = unique_destination(directory, name);
                claim(Some(&destination.to_string_lossy()))?;
            }
            Err(e) => {
                let _ = fs::remove_file(&part);
                return Ok(Err(e));
            }
        }
    }
    let _ = fs::remove_file(&part);
    Ok(Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free name")))
}

/// The folder's real path, `Missing` when it cannot be resolved.
fn resolved(path: &Path) -> std::result::Result<PathBuf, FolderRefusal> {
    fs::canonicalize(path).map_err(|_| FolderRefusal::Missing)
}

/// Whether a file can be made in `folder`: one is made exclusively under a fresh hidden name and removed again.
fn writable(folder: &Path) -> bool {
    let probe = folder.join(format!(".szfriends-{}", new_identifier()));
    match OpenOptions::new().write(true).create_new(true).open(&probe) {
        Ok(file) => {
            drop(file);
            let _ = fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

impl Store {
    /// Where received files go when the person chose nothing; set by the helper for its platform (a store opens
    /// with [`ReceivedDefaults::contained`]).
    pub fn set_received_defaults(&mut self, defaults: ReceivedDefaults) {
        self.received_defaults = defaults;
    }

    pub fn received_defaults(&self) -> &ReceivedDefaults {
        &self.received_defaults
    }

    /// The folder the person chose on this computer, if any (never on a phone).
    pub fn chosen_received_folder(&self) -> Option<PathBuf> {
        if self.received_defaults.phone.is_some() {
            return None;
        }
        let text = fs::read_to_string(self.state_dir().join(RECEIVED_FOLDER_FILE)).ok()?;
        Some(PathBuf::from(text.trim_end_matches(['\n', '\r']))).filter(|p| p.is_absolute())
    }

    /// The folder received files go to now: the chosen one, else the default; `None` where there is no folder to
    /// show (a phone's MediaStore).
    pub fn received_folder(&self) -> Option<PathBuf> {
        self.chosen_received_folder().or_else(|| {
            if self.received_defaults.external.is_some() {
                None
            } else {
                self.received_defaults.folder.clone()
            }
        })
    }

    pub(crate) fn places(&self) -> Places {
        Places {
            chosen: self.chosen_received_folder(),
            defaults: self.received_defaults.clone(),
            own: self.state_dir().join("received"),
        }
    }

    /// `set_received_folder`: checks `path` and remembers its real path; the default Downloads clears the choice.
    pub fn set_received_folder(&mut self, path: &str) -> std::result::Result<(), FolderRefusal> {
        let given = Path::new(path);
        if path.is_empty() || !given.is_absolute() {
            return Err(FolderRefusal::NotAbsolute);
        }
        let real = resolved(given)?;
        if fs::read_dir(&real).is_err() && real.is_dir() {
            return Err(FolderRefusal::Missing);
        }
        if self.received_defaults.phone.is_some() || !real.is_dir() {
            return Err(FolderRefusal::NotAllowed);
        }
        let file = self.state_dir().join(RECEIVED_FOLDER_FILE);
        // Downloads clears the choice (a test's Downloads may sit inside its home).
        let default = self.received_defaults.folder.as_deref().and_then(|d| fs::canonicalize(d).ok());
        if default.as_deref() == Some(real.as_path()) {
            if let Err(e) = fs::remove_file(&file) {
                if e.kind() != io::ErrorKind::NotFound {
                    return Err(FolderRefusal::NotAllowed);
                }
            }
            // A new folder: what happened to the last file in the old one no longer applies.
            record_fallback(self.state_dir(), None);
            return Ok(());
        }
        let state = fs::canonicalize(self.state_dir()).unwrap_or_else(|_| self.state_dir().to_path_buf());
        if real.starts_with(&state) || real.starts_with(self.state_dir()) || !writable(&real) {
            return Err(FolderRefusal::NotAllowed);
        }
        // Written beside it and renamed over it, so a crash leaves the old choice or the new one, never half.
        let temporary = self.state_dir().join(format!(".{RECEIVED_FOLDER_FILE}.{}", new_identifier()));
        let written = (|| -> io::Result<()> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            let mut out = options.open(&temporary)?;
            io::Write::write_all(&mut out, real.to_string_lossy().as_bytes())?;
            out.sync_all()?;
            fs::rename(&temporary, &file)?;
            sync_directory(self.state_dir());
            Ok(())
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(FolderRefusal::NotAllowed);
        }
        record_fallback(self.state_dir(), None);
        Ok(())
    }

    /// The `received` view's rows: files published since the store records when (schema v10), newest first, at most
    /// 100, whose file still exists.
    pub fn received_files(&self) -> Vec<ReceivedFile> {
        let sql = "SELECT transfer_id, received_path, file_name, received_at, received_via FROM transfers \
                   WHERE received_at IS NOT NULL AND received_path IS NOT NULL \
                   ORDER BY received_at DESC, transfer_id DESC";
        let Ok(mut statement) = self.conn.prepare(sql) else { return Vec::new() };
        let Ok(rows) = statement.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, f64>(3)?,
                r.get::<_, i64>(4)?,
            ))
        }) else {
            return Vec::new();
        };
        let mut files = Vec::new();
        for (transfer_id, path, name, at, via) in rows.flatten() {
            if files.len() == RECEIVED_VIEW_MAX {
                break;
            }
            let local = Path::new(&path);
            // A content URI (Android 10) is not a path to check; the transfer's name stands for its own.
            let file_name = if local.is_absolute() {
                if !fs::metadata(local).is_ok_and(|m| m.is_file()) {
                    continue;
                }
                local.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
            } else {
                name
            };
            let source = ReceivedSource::from_via(via);
            files.push(ReceivedFile { transfer_id, path, file_name, received_at: at.floor() as i64, source });
        }
        files
    }
}

/// Records that a file was published now (`received_at`), and how it came when the caller knows better than the row
/// (`received_via`: a link download says so when it is recorded, a device copy when it is made).
pub(crate) fn mark_published(conn: &Connection, transfer_id: &str, via: Option<ReceivedSource>) -> Result<()> {
    conn.execute("UPDATE transfers SET received_at = ?1 WHERE transfer_id = ?2", params![unix_now(), transfer_id])?;
    if let Some(via) = via {
        conn.execute("UPDATE transfers SET received_via = ?1 WHERE transfer_id = ?2", params![via.via(), transfer_id])?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "destination_tests.rs"]
mod tests;
