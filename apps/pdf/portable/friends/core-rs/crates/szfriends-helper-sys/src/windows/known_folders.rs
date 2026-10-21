//! The person's Downloads folder (`FOLDERID_Downloads`), where Friends saves received files until they choose
//! another; it follows the folder wherever the person moved it in Explorer.

use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;

use windows_sys::core::PWSTR;
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::UI::Shell::{FOLDERID_Downloads, SHGetKnownFolderPath};

/// The Downloads known folder's path, `None` when Windows cannot say.
pub fn downloads() -> Option<PathBuf> {
    let mut path: PWSTR = std::ptr::null_mut();
    // SAFETY: a valid GUID, default flags, the current user's token (0), and an out pointer Windows fills with a
    // CoTaskMemAlloc'ed string, freed below whatever the result.
    let result = unsafe { SHGetKnownFolderPath(&FOLDERID_Downloads, 0, 0, &mut path) };
    if path.is_null() {
        return None;
    }
    let folder = (result >= 0).then(|| {
        // SAFETY: on success `path` is a NUL-terminated UTF-16 string.
        let length = (0..).take_while(|&i| unsafe { *path.add(i) } != 0).count();
        let units = unsafe { std::slice::from_raw_parts(path, length) };
        PathBuf::from(OsString::from_wide(units))
    });
    // SAFETY: allocated by SHGetKnownFolderPath with CoTaskMemAlloc.
    unsafe { CoTaskMemFree(path as *const _) };
    folder.filter(|p| p.is_absolute())
}
