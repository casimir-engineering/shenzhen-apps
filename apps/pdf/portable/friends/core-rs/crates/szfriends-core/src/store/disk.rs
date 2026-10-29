//! The disk work transfers do (ADR 0018 § 4 and § 9.1), one function per operation with each platform's cheapest
//! way of doing it:
//!
//! - [`clone_snapshot`]: a snapshot shares the source's blocks (`fclonefileat` on APFS, `FICLONE` on Btrfs and XFS)
//!   and is copied only where it cannot (`copy_file_range` through `std::io::copy` on Linux and Android), and is not
//!   flushed: an offer is checked against the snapshot's digest before every resume, and a block against its leaf as
//!   it is sent, so a snapshot a crash tore fails its check instead of being sent.
//! - [`order_writes`] and [`make_durable`]: the two halves of a durability batch. The first only orders the batch's
//!   blocks before the map that claims them (a plain `fsync` on Apple systems, which skips the drive cache flush
//!   `F_FULLFSYNC` adds; `fdatasync` elsewhere), the second makes both durable (`F_FULLFSYNC`, `fsync`). WP1's block
//!   map calls them; the CHUNK path of released peers keeps its full flush per batch.
//! - [`read_ahead`] and [`OutgoingFile`]: a snapshot read once, in order, at offsets, through one descriptor.

use std::fs::{File, OpenOptions};
use std::io;
use std::path::Path;

/// Creates `destination` (exclusively, 0600, never following a link) with the bytes of `source`: a clone where the
/// file system shares blocks, a copy otherwise. Reads from the one descriptor opened here, so the snapshot is of the
/// file that descriptor names, whatever happens to the path meanwhile.
pub fn clone_snapshot(source: &Path, destination: &Path) -> io::Result<()> {
    let from = File::open(source)?;
    if !from.metadata()?.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a file"));
    }
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        use rustix::fs::{fclonefileat, CloneFlags, CWD};
        if fclonefileat(&from, CWD, destination, CloneFlags::NOFOLLOW).is_ok() {
            // The clone carries the source's mode, owner and flags; the snapshot is private and ours to delete.
            let _ = rustix::fs::chmod(destination, rustix::fs::Mode::from_raw_mode(0o600));
            return Ok(());
        }
    }
    let mut to = create_private(destination)?;
    #[cfg(any(target_os = "linux", target_os = "android"))]
    if rustix::fs::ioctl_ficlone(&to, &from).is_ok() {
        return Ok(());
    }
    let mut from = from;
    if let Err(error) = io::copy(&mut from, &mut to) {
        drop(to);
        let _ = std::fs::remove_file(destination);
        return Err(error);
    }
    Ok(())
}

fn create_private(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    options.open(path)
}

/// Orders what was written to `file` before anything written after this returns, without waiting for the drive's
/// cache: the first half of a durability batch (blocks before the map that claims them).
pub fn order_writes(file: &File) -> io::Result<()> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        rustix::fs::fsync(file).map_err(io::Error::from)
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        file.sync_data()
    }
}

/// Makes everything written to `file` durable, through the drive's cache (`F_FULLFSYNC` on Apple systems).
pub fn make_durable(file: &File) -> io::Result<()> {
    file.sync_all()
}

/// Tells the system `file` is about to be read once from start to end, so it reads ahead (`F_RDADVISE` on Apple
/// systems, `POSIX_FADV_SEQUENTIAL` elsewhere on Unix). Advice only: failure changes nothing.
pub fn read_ahead(file: &File, length: u64) {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let _ = rustix::fs::fcntl_rdadvise(file, 0, length.min(i32::MAX as u64));
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let _ = rustix::fs::fadvise(file, 0, std::num::NonZeroU64::new(length), rustix::fs::Advice::Sequential);
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux", target_os = "android")))]
    let _ = (file, length);
}

/// An outgoing transfer's snapshot, open for the whole transfer: each chunk or part is read at its offset into the
/// caller's buffer, with no open, seek or allocation per read.
#[derive(Debug)]
pub struct OutgoingFile {
    file: File,
}

impl OutgoingFile {
    pub fn open(path: &Path, size: u64) -> io::Result<Self> {
        let file = File::open(path)?;
        read_ahead(&file, size);
        Ok(Self { file })
    }

    /// Fills `buffer` from `offset`; an error when the snapshot is shorter.
    pub fn read_at(&self, offset: u64, buffer: &mut [u8]) -> io::Result<()> {
        #[cfg(unix)]
        {
            std::os::unix::fs::FileExt::read_exact_at(&self.file, buffer, offset)
        }
        #[cfg(windows)]
        {
            let mut done = 0;
            while done < buffer.len() {
                let read =
                    std::os::windows::fs::FileExt::seek_read(&self.file, &mut buffer[done..], offset + done as u64)?;
                if read == 0 {
                    return Err(io::ErrorKind::UnexpectedEof.into());
                }
                done += read;
            }
            Ok(())
        }
    }
}
