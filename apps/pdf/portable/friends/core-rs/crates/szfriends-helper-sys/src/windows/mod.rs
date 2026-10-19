//! Shared pieces of the Win32 bindings: owned handles, wide strings, memory Windows allocated for us.

pub mod dnssd;
pub mod dpapi;
pub mod events;
pub mod firewall;
pub mod lock;
pub mod pipe;
#[cfg(feature = "testing")]
pub mod testing;
pub mod token;

use std::ffi::{c_void, OsStr};
use std::os::windows::ffi::OsStrExt;

use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;

/// A NUL-terminated UTF-16 copy of `text`.
pub(crate) fn wide(text: impl AsRef<OsStr>) -> Vec<u16> {
    text.as_ref().encode_wide().chain(Some(0)).collect()
}

/// A kernel handle this crate opened; closed when dropped.
#[derive(Debug)]
pub(crate) struct Handle(HANDLE);

impl Handle {
    /// `None` for the two values Win32 calls return on failure.
    pub(crate) fn new(raw: HANDLE) -> Option<Self> {
        (raw != 0 && raw != INVALID_HANDLE_VALUE).then_some(Self(raw))
    }

    pub(crate) fn raw(&self) -> HANDLE {
        self.0
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: the handle was returned open by a Win32 call and is owned by this value alone.
        unsafe { CloseHandle(self.0) };
    }
}

/// Memory a Win32 call allocated with `LocalAlloc` for the caller; freed when dropped.
pub(crate) struct LocalMemory(pub(crate) *mut c_void);

impl std::fmt::Debug for LocalMemory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("LocalMemory")
    }
}

impl Drop for LocalMemory {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: the pointer came from a call documented to allocate it with LocalAlloc, and is freed once.
            unsafe { LocalFree(self.0) };
        }
    }
}

/// The text of a NUL-terminated UTF-16 string.
///
/// # Safety
/// `text` must point to a readable, NUL-terminated UTF-16 string.
pub(crate) unsafe fn from_wide(text: *const u16) -> String {
    let mut length = 0;
    // SAFETY: the caller promises a NUL terminator, so every offset up to it is readable.
    while unsafe { *text.add(length) } != 0 {
        length += 1;
    }
    // SAFETY: `length` units were just read from `text`.
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, length) })
}

/// A SID's string form (`S-1-5-…`), or `None` when Windows cannot convert it.
///
/// # Safety
/// `sid` must point to a valid SID for the duration of the call.
pub(crate) unsafe fn sid_string(sid: *mut c_void) -> Option<String> {
    let mut text: *mut u16 = std::ptr::null_mut();
    // SAFETY: `sid` is valid (the caller's promise); `text` receives a LocalAlloc'd string on success.
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 || text.is_null() {
        return None;
    }
    let owned = LocalMemory(text.cast());
    // SAFETY: ConvertSidToStringSidW wrote a NUL-terminated string there.
    let result = unsafe { from_wide(text) };
    drop(owned);
    Some(result)
}
