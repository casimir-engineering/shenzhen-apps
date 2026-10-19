//! Test tools for the pipe test plan (ADR 0015 § 8), built only with the `testing` feature: they forge what an
//! attacker could arrange, so a test can show the client refusing it.

use std::io;

use windows_sys::Win32::Foundation::{DuplicateHandle, DUPLICATE_SAME_ACCESS, HANDLE, PSID};
use windows_sys::Win32::Security::Authorization::{ConvertStringSidToSidW, SetSecurityInfo, SE_KERNEL_OBJECT};
use windows_sys::Win32::Security::OWNER_SECURITY_INFORMATION;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcess, PROCESS_DUP_HANDLE};

use super::{wide, Handle, LocalMemory};

/// Makes `owner` the owner of the kernel object behind `handle` in process `pid`. The handle must carry
/// `WRITE_OWNER`, and the calling process must be allowed to name that owner (its own SID, for one): run as SYSTEM,
/// this gives a pipe that another user's process created an owner that is not that user.
pub fn set_owner_of_remote_handle(pid: u32, handle: HANDLE, owner: &str) -> io::Result<()> {
    // SAFETY: plain call; failure returns 0.
    let process =
        Handle::new(unsafe { OpenProcess(PROCESS_DUP_HANDLE, 0, pid) }).ok_or_else(io::Error::last_os_error)?;
    let mut copy: HANDLE = 0;
    // SAFETY: duplicates the other process's handle into ours with the same access.
    let ok =
        unsafe { DuplicateHandle(process.raw(), handle, GetCurrentProcess(), &mut copy, 0, 0, DUPLICATE_SAME_ACCESS) };
    let copy = (ok != 0).then(|| Handle::new(copy)).flatten().ok_or_else(io::Error::last_os_error)?;
    let text = wide(owner);
    let mut sid: PSID = std::ptr::null_mut();
    // SAFETY: a NUL-terminated SID string; `sid` receives LocalAlloc'd memory.
    if unsafe { ConvertStringSidToSidW(text.as_ptr(), &mut sid) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let _sid = LocalMemory(sid);
    // SAFETY: a live handle and a valid SID; only the owner is set.
    let status = unsafe {
        SetSecurityInfo(
            copy.raw(),
            SE_KERNEL_OBJECT,
            OWNER_SECURITY_INFORMATION,
            sid,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    Ok(())
}
