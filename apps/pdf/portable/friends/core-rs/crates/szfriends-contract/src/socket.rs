//! PROTOCOL.md § Transport: where a desktop helper listens. The primary path is
//! `<canonical state dir>/ipc/helper.sock` when it fits `sockaddr_un`; otherwise
//! `<user temp dir>/szfriends-<16 hex>/helper.sock`, the hex being the FNV-1a 64 hash of the canonical state directory.
//! Windows uses a named pipe instead ([`crate::pipe`], ADR 0015 § Desktop IPC).

/// 64-bit FNV-1a: offset basis 0xcbf29ce484222325, prime 0x100000001b3, XOR then multiply per byte. It only names a
/// directory; it is not a security boundary.
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, &b| (hash ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3))
}

/// `sun_path` bytes including the terminating NUL, as the C client library counts them on every platform (104, the
/// Apple size; Linux allows 108). One number everywhere, so every client derives the same path from a state dir.
pub const SUN_PATH_MAX: usize = 104;

/// The socket path for an already canonical state directory, and whether it is the fallback; `None` when neither
/// form fits. `user_temp_dir` is `$XDG_RUNTIME_DIR` (or `/tmp`) on Linux.
pub fn socket_path(canonical_state_dir: &str, user_temp_dir: &str, sun_path_max: usize) -> Option<(String, bool)> {
    let primary = format!("{canonical_state_dir}/ipc/helper.sock");
    if primary.len() < sun_path_max {
        return Some((primary, false));
    }
    let separator = if user_temp_dir.ends_with('/') { "" } else { "/" };
    let hash = fnv1a64(canonical_state_dir.as_bytes());
    let fallback = format!("{user_temp_dir}{separator}szfriends-{hash:016x}/helper.sock");
    (fallback.len() < sun_path_max).then_some((fallback, true))
}
