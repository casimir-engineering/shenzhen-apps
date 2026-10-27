//! Who a process runs as: its token's user, mandatory integrity level and AppContainer flag (ADR 0015 § 8), and
//! the executable it runs.

use std::ffi::c_void;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;

use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::Security::{
    GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, TokenIntegrityLevel, TokenIsAppContainer,
    TokenUser, TOKEN_INFORMATION_CLASS, TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TOKEN_USER,
};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, GetCurrentProcessId, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW,
    PROCESS_QUERY_LIMITED_INFORMATION,
};

use super::{sid_string, Handle};

/// What a token says; `None` where Windows would not tell.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TokenFacts {
    /// The token user's SID in string form.
    pub user: Option<String>,
    /// The RID of the token's integrity label (`SECURITY_MANDATORY_*_RID`).
    pub integrity: Option<u32>,
    pub app_container: Option<bool>,
}

/// This process's own token.
pub fn own() -> TokenFacts {
    // SAFETY: GetCurrentProcess returns a pseudo-handle that needs no closing.
    let process = unsafe { GetCurrentProcess() };
    facts_of_process(process)
}

/// The token of process `pid`, as far as this process may read it.
pub fn of_process(pid: u32) -> TokenFacts {
    match open_process(pid) {
        Some(process) => facts_of_process(process.raw()),
        None => TokenFacts::default(),
    }
}

/// This process's id.
pub fn current_process_id() -> u32 {
    // SAFETY: no arguments, no failure.
    unsafe { GetCurrentProcessId() }
}

/// The full path of the executable process `pid` runs.
pub fn process_image(pid: u32) -> Option<PathBuf> {
    let process = open_process(pid)?;
    let mut buffer = vec![0u16; 32768];
    let mut length = buffer.len() as u32;
    // SAFETY: `buffer` holds `length` units; the call writes at most that many and updates `length`.
    let ok = unsafe { QueryFullProcessImageNameW(process.raw(), 0, buffer.as_mut_ptr(), &mut length) };
    (ok != 0).then(|| PathBuf::from(std::ffi::OsString::from_wide(&buffer[..length as usize])))
}

fn open_process(pid: u32) -> Option<Handle> {
    // SAFETY: plain call; a failure returns 0, which Handle::new refuses.
    Handle::new(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) })
}

fn facts_of_process(process: HANDLE) -> TokenFacts {
    let mut token: HANDLE = 0;
    // SAFETY: `process` is a live process handle; `token` receives a new handle on success.
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return TokenFacts::default();
    }
    let Some(token) = Handle::new(token) else { return TokenFacts::default() };
    TokenFacts { user: user(&token), integrity: integrity(&token), app_container: app_container(&token) }
}

/// The token information of `class`, in a buffer aligned for the structures Windows writes there.
fn information(token: &Handle, class: TOKEN_INFORMATION_CLASS) -> Option<Vec<u64>> {
    let mut needed = 0u32;
    // SAFETY: a null buffer of length 0 only asks for the size.
    unsafe { GetTokenInformation(token.raw(), class, std::ptr::null_mut(), 0, &mut needed) };
    if needed == 0 || needed > 64 * 1024 {
        return None;
    }
    let mut buffer = vec![0u64; (needed as usize).div_ceil(8)];
    let length = (buffer.len() * 8) as u32;
    // SAFETY: `buffer` holds `length` bytes, 8-aligned, which covers every TOKEN_* structure's alignment.
    let ok = unsafe { GetTokenInformation(token.raw(), class, buffer.as_mut_ptr().cast(), length, &mut needed) };
    (ok != 0).then_some(buffer)
}

fn user(token: &Handle) -> Option<String> {
    let buffer = information(token, TokenUser)?;
    // SAFETY: GetTokenInformation(TokenUser) wrote a TOKEN_USER at the start of the buffer, whose SID points
    // inside the same buffer, which lives until the end of this function.
    unsafe {
        let user = &*(buffer.as_ptr() as *const TOKEN_USER);
        sid_string(user.User.Sid)
    }
}

fn integrity(token: &Handle) -> Option<u32> {
    let buffer = information(token, TokenIntegrityLevel)?;
    // SAFETY: a TOKEN_MANDATORY_LABEL at the start of the buffer, its SID inside the buffer; the SID functions
    // return pointers into that SID, and the last sub-authority is the integrity RID.
    unsafe {
        let label = &*(buffer.as_ptr() as *const TOKEN_MANDATORY_LABEL);
        let sid: *mut c_void = label.Label.Sid;
        let count = *GetSidSubAuthorityCount(sid);
        if count == 0 {
            return None;
        }
        Some(*GetSidSubAuthority(sid, u32::from(count) - 1))
    }
}

fn app_container(token: &Handle) -> Option<bool> {
    let buffer = information(token, TokenIsAppContainer)?;
    // SAFETY: TokenIsAppContainer writes one DWORD.
    Some(unsafe { *(buffer.as_ptr() as *const u32) } != 0)
}

/// Ends process `pid` at once (`TerminateProcess`); for a helper of this user's that stopped answering, after the
/// caller checked what it runs.
pub fn terminate(pid: u32) -> std::io::Result<()> {
    use windows_sys::Win32::System::Threading::{TerminateProcess, PROCESS_TERMINATE};
    // SAFETY: plain call; a failure returns 0, which Handle::new refuses.
    let process =
        Handle::new(unsafe { OpenProcess(PROCESS_TERMINATE, 0, pid) }).ok_or_else(std::io::Error::last_os_error)?;
    // SAFETY: a live handle opened with PROCESS_TERMINATE.
    if unsafe { TerminateProcess(process.raw(), 1) } == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}
