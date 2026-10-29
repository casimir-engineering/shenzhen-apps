//! Files the transfers keep (`SZFriendsTransferFiles.m`, `SZFriendsTransferChecks.m`): private directories and files,
//! staging files named by this device, snapshots, digests, and safe names for received files.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use blake2::digest::{Update, VariableOutput};
use unicode_normalization::UnicodeNormalization;

use super::new_identifier;

/// Longest sanitised name in UTF-8 bytes, and the longest extension kept apart when shortening.
const SANITIZED_MAX_BYTES: usize = 200;
const MAX_EXTENSION_CHARS: usize = 16;

/// A private (0700) directory that is a real directory of ours, not a symlink planted to redirect files elsewhere.
pub fn ensure_private_directory(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            builder.recursive(true);
            #[cfg(unix)]
            std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
            builder.create(path)?;
        }
        Err(e) => return Err(e),
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || !owned_by_us(&metadata) {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "not our directory"));
    }
    Ok(())
}

#[cfg(unix)]
fn owned_by_us(metadata: &fs::Metadata) -> bool {
    std::os::unix::fs::MetadataExt::uid(metadata) == rustix::process::geteuid().as_raw()
}

#[cfg(not(unix))]
fn owned_by_us(_metadata: &fs::Metadata) -> bool {
    true // %LOCALAPPDATA% is the account's own; its ACL is the protection there.
}

fn private_options(options: &mut OpenOptions) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    #[cfg(not(unix))]
    let _ = options;
}

/// Moves `from` to `to`, which must not exist yet: a file is never replaced. A hard link where the system allows one
/// (`from` is then removed). Where it refuses with a permission error (Android's SELinux policy gives apps no hard
/// links) or the file system has none (FAT and exFAT drives), `to` is claimed with an exclusive create and `from`
/// renamed over the claim; a crash between the two leaves an empty file at `to`, which crash recovery removes before
/// publishing again. `AlreadyExists` when `to` is taken; another volume's error when `to` is on one.
pub fn move_no_replace(from: &Path, to: &Path) -> io::Result<()> {
    match fs::hard_link(from, to) {
        Ok(()) => {
            let _ = fs::remove_file(from);
            return Ok(());
        }
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied || no_hard_links(&e) => {}
        Err(e) => return Err(e),
    }
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    private_options(&mut options);
    drop(options.open(to)?);
    fs::rename(from, to)
}

/// A file system without hard links: EPERM/EOPNOTSUPP on Unix, ERROR_INVALID_FUNCTION or ERROR_NOT_SUPPORTED on
/// Windows.
fn no_hard_links(error: &io::Error) -> bool {
    #[cfg(windows)]
    let raw = matches!(error.raw_os_error(), Some(1 | 50));
    #[cfg(unix)]
    let raw = error.raw_os_error() == Some(rustix::io::Errno::OPNOTSUPP.raw_os_error());
    #[cfg(not(any(unix, windows)))]
    let raw = false;
    raw || error.kind() == io::ErrorKind::Unsupported
}

/// Creates `path` 0600 if it is missing (never following a symlink there), so SQLite's -wal and -shm files get the
/// database's own mode and the history stays private whatever the umask.
pub fn create_private_file(path: &Path) -> io::Result<()> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    private_options(&mut options);
    options.open(path)?;
    make_private(path);
    Ok(())
}

/// 0600 on Unix; nothing elsewhere.
pub fn make_private(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// `<partial>/<fresh identifier>.part`, created exclusively: the name never comes from the sender.
pub fn create_staging_file(partial_directory: &Path) -> io::Result<PathBuf> {
    ensure_private_directory(partial_directory)?;
    for _ in 0..4 {
        let path = partial_directory.join(format!("{}.part", new_identifier()));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        private_options(&mut options);
        match options.open(&path) {
            Ok(_) => return Ok(path),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free staging name"))
}

/// BLAKE2b-256 of a file's first `length` bytes (the whole file with `u64::MAX`).
pub fn file_digest(path: &Path, length: u64) -> io::Result<[u8; 32]> {
    let mut file = File::open(path)?;
    digest_prefix(&mut file, length)
}

pub(super) fn digest_prefix(reader: &mut impl Read, length: u64) -> io::Result<[u8; 32]> {
    let mut hasher = blake2::Blake2bVar::new(32).expect("32-byte output");
    let mut buffer = vec![0u8; 1 << 20];
    let mut remaining = length;
    while remaining > 0 {
        let want = buffer.len().min(usize::try_from(remaining).unwrap_or(usize::MAX));
        let got = reader.read(&mut buffer[..want])?;
        if got == 0 {
            if length == u64::MAX {
                break;
            }
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "shorter than its size"));
        }
        hasher.update(&buffer[..got]);
        remaining -= got as u64;
    }
    let mut out = [0u8; 32];
    hasher.finalize_variable(&mut out).expect("length matches");
    Ok(out)
}

/// Characters that hide or reorder what a file browser shows: controls, bidi overrides and isolates, invisible
/// separators and the byte-order mark.
fn is_stripped(c: char) -> bool {
    let c = u32::from(c);
    c < 0x20
        || (0x7f..=0x9f).contains(&c)
        || (0x202A..=0x202E).contains(&c)
        || (0x2066..=0x2069).contains(&c)
        || (0xFFF9..=0xFFFB).contains(&c)
        || matches!(c, 0x061C | 0x200B | 0x200E | 0x200F | 0x2028 | 0x2029 | 0x2060 | 0xFEFF)
}

/// Leading dots and spaces would hide the file or its real start; trailing spaces would hide its end.
fn trimmed(text: &str) -> &str {
    text.trim_start_matches(|c: char| c == '.' || c.is_whitespace()).trim_end_matches(char::is_whitespace)
}

/// Drops whole characters from the end until the UTF-8 form fits.
fn truncated(text: &str, max_bytes: usize) -> &str {
    let mut end = text.len().min(max_bytes);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

fn split_extension(name: &str) -> Option<(&str, &str)> {
    let (base, extension) = name.rsplit_once('.')?;
    (!base.is_empty() && !extension.is_empty() && extension.chars().count() <= MAX_EXTENSION_CHARS)
        .then_some((base, extension))
}

/// A safe name for received files (`SZFriendsSanitizedFileName`): no separators, controls or bidi overrides, no
/// leading dots or trailing spaces, the extension kept when shortening, never empty ("Untitled").
pub fn sanitized_file_name(proposed: &str) -> String {
    let clean: String = proposed
        .nfc()
        .filter(|c| !is_stripped(*c))
        .map(|c| if matches!(c, '/' | ':' | '\\') { '-' } else { c })
        .collect();
    let mut result = trimmed(&clean).to_owned();
    if result.len() > SANITIZED_MAX_BYTES {
        result = match split_extension(&result) {
            Some((base, extension)) => {
                let room = SANITIZED_MAX_BYTES - extension.len() - 1;
                let base = trimmed(truncated(base, room));
                if base.is_empty() {
                    extension.to_owned()
                } else {
                    format!("{base}.{extension}")
                }
            }
            None => trimmed(truncated(&result, SANITIZED_MAX_BYTES)).to_owned(),
        };
    }
    if result.is_empty() {
        "Untitled".to_owned()
    } else {
        result
    }
}

/// A path inside `directory` that overwrites nothing ("Site photos (2).pdf"); a symlink, even a dangling one, counts as
/// taken. Never leaves the directory, whatever `name` holds.
pub fn unique_destination(directory: &Path, name: &str) -> PathBuf {
    let safe = sanitized_file_name(name);
    let taken = |path: &Path| fs::symlink_metadata(path).is_ok();
    let candidate = directory.join(&safe);
    if !taken(&candidate) {
        return candidate;
    }
    let (base, extension) = match split_extension(&safe) {
        Some((base, extension)) => (base.to_owned(), Some(extension.to_owned())),
        None => (safe.clone(), None),
    };
    let named = |suffix: String| match &extension {
        Some(extension) => format!("{base} ({suffix}).{extension}"),
        None => format!("{base} ({suffix})"),
    };
    for n in 2..10_000 {
        let candidate = directory.join(named(n.to_string()));
        if !taken(&candidate) {
            return candidate;
        }
    }
    directory.join(named(new_identifier()))
}

/// Clones `source` into `destination` as the immutable snapshot an offer is bound to (a copy where the volume cannot
/// clone; `disk::clone_snapshot`), and returns its size and digest as read back from it. Not flushed: before any resume
/// the snapshot is checked against this digest again, so one a crash damaged fails instead of being sent.
pub(super) fn snapshot(source: &Path, destination: &Path) -> io::Result<(u64, [u8; 32])> {
    super::disk::clone_snapshot(source, destination)?;
    let mut file = File::open(destination)?;
    let size = file.metadata()?.len();
    super::disk::read_ahead(&file, size);
    Ok((size, digest_prefix(&mut file, u64::MAX)?))
}

/// A file's modification time in nanoseconds since 1970, or 0 when it cannot be read.
pub fn modified_ns(path: &Path) -> i64 {
    let modified = fs::metadata(path).and_then(|m| m.modified()).ok();
    let since = modified.and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok());
    since.map_or(0, |d| i64::try_from(d.as_nanos()).unwrap_or(i64::MAX))
}
