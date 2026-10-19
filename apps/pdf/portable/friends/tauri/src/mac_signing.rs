//! The signing policy of a team-signed Mac app (ADR 0002 § Peer checks), as Shenzhen 3D's Electron binding applies
//! it: the app reads its own Team ID; when it has one it ignores `$SZFRIENDS_STATE_DIR` and talks only to a helper
//! signed by the same team, judged by the helper's audit token (which, unlike a pid, names exactly the process
//! holding the socket) against the requirement the helper applies to its clients. Ad hoc and development builds
//! keep the uid check alone.

use std::ffi::{c_char, c_void, CStr};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;

type CFTypeRef = *const c_void;
type CFIndex = isize;
type OSStatus = i32;

#[repr(C)]
struct CFDictionaryCallBacks([usize; 6]);

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFTypeDictionaryKeyCallBacks: CFDictionaryCallBacks;
    static kCFTypeDictionaryValueCallBacks: CFDictionaryCallBacks;
    fn CFDataCreate(allocator: CFTypeRef, bytes: *const u8, length: CFIndex) -> CFTypeRef;
    fn CFStringCreateWithCString(allocator: CFTypeRef, text: *const c_char, encoding: u32) -> CFTypeRef;
    fn CFStringGetCString(string: CFTypeRef, buffer: *mut c_char, size: CFIndex, encoding: u32) -> u8;
    fn CFDictionaryCreate(
        allocator: CFTypeRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        count: CFIndex,
        key_callbacks: *const CFDictionaryCallBacks,
        value_callbacks: *const CFDictionaryCallBacks,
    ) -> CFTypeRef;
    fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    fn CFRelease(value: CFTypeRef);
}

#[link(name = "Security", kind = "framework")]
extern "C" {
    static kSecGuestAttributeAudit: CFTypeRef;
    static kSecCodeInfoTeamIdentifier: CFTypeRef;
    fn SecCodeCopySelf(flags: u32, code: *mut CFTypeRef) -> OSStatus;
    fn SecCodeCopyStaticCode(code: CFTypeRef, flags: u32, static_code: *mut CFTypeRef) -> OSStatus;
    fn SecCodeCopySigningInformation(code: CFTypeRef, flags: u32, information: *mut CFTypeRef) -> OSStatus;
    fn SecCodeCopyGuestWithAttributes(
        host: CFTypeRef,
        attributes: CFTypeRef,
        flags: u32,
        guest: *mut CFTypeRef,
    ) -> OSStatus;
    fn SecRequirementCreateWithString(text: CFTypeRef, flags: u32, requirement: *mut CFTypeRef) -> OSStatus;
    fn SecCodeCheckValidity(code: CFTypeRef, flags: u32, requirement: CFTypeRef) -> OSStatus;
}

const UTF8: u32 = 0x0800_0100;
const SIGNING_INFORMATION: u32 = 1 << 1;
const SOL_LOCAL: i32 = 0;
const LOCAL_PEERTOKEN: i32 = 0x006;

/// Releases a Core Foundation object when dropped.
struct Owned(CFTypeRef);

impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: we own one reference to a valid CF object.
            unsafe { CFRelease(self.0) }
        }
    }
}

/// Apple Team IDs are ten capitals and digits; anything else is refused rather than quoted into a requirement.
pub fn team_is_valid(team: &str) -> bool {
    team.len() == 10 && team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
}

/// This app's own Team ID, or None for an ad hoc or unsigned build.
pub fn own_team() -> Option<String> {
    // SAFETY: each call gets valid out-pointers; every returned object is released by `Owned`.
    unsafe {
        let mut code = std::ptr::null();
        if SecCodeCopySelf(0, &mut code) != 0 || code.is_null() {
            return None;
        }
        let code = Owned(code);
        let mut static_code = std::ptr::null();
        if SecCodeCopyStaticCode(code.0, 0, &mut static_code) != 0 || static_code.is_null() {
            return None;
        }
        let static_code = Owned(static_code);
        let mut information = std::ptr::null();
        if SecCodeCopySigningInformation(static_code.0, SIGNING_INFORMATION, &mut information) != 0 {
            return None;
        }
        let information = Owned(information);
        let team = CFDictionaryGetValue(information.0, kSecCodeInfoTeamIdentifier);
        if team.is_null() {
            return None;
        }
        let mut buffer = [0 as c_char; 64];
        if CFStringGetCString(team, buffer.as_mut_ptr(), buffer.len() as CFIndex, UTF8) == 0 {
            return None;
        }
        CStr::from_ptr(buffer.as_ptr()).to_str().ok().map(str::to_owned).filter(|t| !t.is_empty())
    }
}

/// Whether the process holding the other end of `stream` is signed by `team`, by the helper's own requirement.
/// Fails closed: anything unreadable is a refusal.
pub fn peer_signed_by(stream: &UnixStream, team: &str) -> bool {
    if !team_is_valid(team) {
        return false;
    }
    let requirement = format!("anchor apple generic and certificate leaf[subject.OU] = \"{team}\"\0");
    let mut token = [0u32; 8];
    let mut length = std::mem::size_of_val(&token) as libc::socklen_t;
    // SAFETY: the descriptor is a connected Unix socket; token and length are valid out-pointers of that size.
    let read = unsafe {
        libc::getsockopt(stream.as_raw_fd(), SOL_LOCAL, LOCAL_PEERTOKEN, token.as_mut_ptr().cast(), &mut length)
    };
    if read != 0 || length as usize != std::mem::size_of_val(&token) {
        return false;
    }
    // SAFETY: every pointer passed is valid for the call; created objects are released by `Owned`.
    unsafe {
        let data = Owned(CFDataCreate(std::ptr::null(), token.as_ptr().cast(), 32));
        let text = Owned(CFStringCreateWithCString(std::ptr::null(), requirement.as_ptr().cast(), UTF8));
        if data.0.is_null() || text.0.is_null() {
            return false;
        }
        let keys = [kSecGuestAttributeAudit];
        let values = [data.0];
        let attributes = Owned(CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        ));
        let mut code = std::ptr::null();
        if attributes.0.is_null() || SecCodeCopyGuestWithAttributes(std::ptr::null(), attributes.0, 0, &mut code) != 0 {
            return false;
        }
        let code = Owned(code);
        let mut required = std::ptr::null();
        if SecRequirementCreateWithString(text.0, 0, &mut required) != 0 || required.is_null() {
            return false;
        }
        let required = Owned(required);
        !code.0.is_null() && SecCodeCheckValidity(code.0, 0, required.0) == 0
    }
}
