//! DPAPI for the current user (ADR 0015 § 7): what the identity key file holds on Windows. A blob protected here
//! opens only for the same user on the same PC (or a domain user's roamed master key); restored onto another account
//! or PC it fails to open, which the key store reports as unavailable, never as absent.

use std::io;

use windows_sys::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
};

use super::{wide, LocalMemory};

fn blob(bytes: &[u8]) -> CRYPT_INTEGER_BLOB {
    CRYPT_INTEGER_BLOB { cbData: bytes.len() as u32, pbData: bytes.as_ptr().cast_mut() }
}

/// The bytes Windows returned in `output`, copied out; the original is wiped (when `wipe`) and freed.
///
/// # Safety
/// `output` must describe memory a DPAPI call allocated with `LocalAlloc`.
unsafe fn take(output: CRYPT_INTEGER_BLOB, wipe: bool) -> Vec<u8> {
    let owned = LocalMemory(output.pbData.cast());
    if output.pbData.is_null() {
        return Vec::new();
    }
    // SAFETY: DPAPI wrote `cbData` bytes at `pbData`.
    let bytes = unsafe { std::slice::from_raw_parts_mut(output.pbData, output.cbData as usize) };
    let copy = bytes.to_vec();
    if wipe {
        for byte in bytes.iter_mut() {
            // SAFETY: an exclusive reference to one byte; volatile, so the wipe is not optimised away.
            unsafe { std::ptr::write_volatile(byte, 0) };
        }
    }
    drop(owned);
    copy
}

/// Protects `secret` for the current user, bound to `entropy` (which must be passed again to open it). Never shows
/// any interface.
pub fn protect(secret: &[u8], entropy: &[u8], description: &str) -> io::Result<Vec<u8>> {
    if secret.len() > u32::MAX as usize || entropy.len() > u32::MAX as usize {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    let (input, extra) = (blob(secret), blob(entropy));
    let description = wide(description);
    let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    // SAFETY: the input blobs point at live slices for the call; DPAPI only reads them and allocates `output`.
    let ok = unsafe {
        CryptProtectData(
            &input,
            description.as_ptr(),
            &extra,
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `output` was allocated by CryptProtectData.
    Ok(unsafe { take(output, false) })
}

/// Opens a blob [`protect`] made, with the same `entropy`. Fails for another user's or another PC's blob, a damaged
/// one, or the wrong entropy. The caller owns the secret it returns and must wipe it.
pub fn unprotect(protected: &[u8], entropy: &[u8]) -> io::Result<Vec<u8>> {
    if protected.len() > u32::MAX as usize || entropy.len() > u32::MAX as usize {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    let (input, extra) = (blob(protected), blob(entropy));
    let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    // SAFETY: as in `protect`; no description is asked for.
    let ok = unsafe {
        CryptUnprotectData(
            &input,
            std::ptr::null_mut(),
            &extra,
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `output` was allocated by CryptUnprotectData; it holds the secret, so it is wiped before it is freed.
    Ok(unsafe { take(output, true) })
}
