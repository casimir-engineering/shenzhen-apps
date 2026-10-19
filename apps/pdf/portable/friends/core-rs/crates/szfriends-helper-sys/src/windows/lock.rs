//! The single-instance lock: one byte of `helper.lock`, past the holder's process id (ADR 0015 § 8). Windows byte
//! locks are mandatory, so locking the whole file would stop clients reading who holds it. Windows releases the lock
//! when the holding process exits, however it exits.

use std::fs::File;
use std::io;
use std::os::windows::io::AsRawHandle;

use windows_sys::Win32::Foundation::{ERROR_LOCK_VIOLATION, HANDLE};
use windows_sys::Win32::Storage::FileSystem::{LockFileEx, LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY};
use windows_sys::Win32::System::IO::OVERLAPPED;

/// Takes an exclusive lock on the byte at `offset` without waiting: `Ok(true)` when taken, `Ok(false)` when
/// another handle holds it. The lock lasts as long as `file` stays open.
pub fn try_lock_byte(file: &File, offset: u64) -> io::Result<bool> {
    // SAFETY: an all-zero OVERLAPPED is valid; only its offset fields are set.
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    overlapped.Anonymous.Anonymous.Offset = offset as u32;
    overlapped.Anonymous.Anonymous.OffsetHigh = (offset >> 32) as u32;
    let flags = LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY;
    let handle = file.as_raw_handle() as HANDLE;
    // SAFETY: `file` is open for the duration; on a synchronous handle with FAIL_IMMEDIATELY the call completes
    // before returning, so `overlapped` outlives its use.
    if unsafe { LockFileEx(handle, flags, 0, 1, 0, &mut overlapped) } != 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) {
        Ok(false)
    } else {
        Err(error)
    }
}
