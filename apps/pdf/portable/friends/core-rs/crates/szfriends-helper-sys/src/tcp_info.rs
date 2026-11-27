//! A TCP connection's own counters from the kernel (ADR 0018 § 7.2): what it sent and what it had to send again, so
//! the helper can tell a lossy path. macOS and iOS: `TCP_CONNECTION_INFO` (bytes); Linux and Android: `TCP_INFO`
//! (segments). Elsewhere, `None`.

/// (sent, retransmitted) so far: bytes on Apple platforms, segments on Linux and Android.
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub fn counters(fd: i32) -> Option<(u64, u64)> {
    // <netinet/tcp.h> struct tcp_connection_info, 112 bytes: tcpi_txbytes, a u64 at byte 64, and
    // tcpi_txretransmitbytes at 72 (libc's copy spells its bitfields as whole words, so its offsets are wrong).
    let mut info = [0u8; 112];
    let mut len = info.len() as libc::socklen_t;
    // SAFETY: `info` is as large as `len` says, and the kernel writes at most `len` bytes into it.
    let ok = unsafe {
        libc::getsockopt(fd, libc::IPPROTO_TCP, libc::TCP_CONNECTION_INFO, info.as_mut_ptr().cast(), &mut len)
    } == 0;
    if !ok || (len as usize) < 80 {
        return None;
    }
    let at = |offset: usize| u64::from_ne_bytes(info[offset..offset + 8].try_into().unwrap_or([0; 8]));
    Some((at(64), at(72)))
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn counters(fd: i32) -> Option<(u64, u64)> {
    // <linux/tcp.h> struct tcp_info (not in libc for every target): tcpi_total_retrans, a u32 at byte 100, and
    // tcpi_segs_out, a u32 at byte 136 (kernels since 4.2).
    let mut info = [0u8; 232];
    let mut len = info.len() as libc::socklen_t;
    // SAFETY: `info` is as large as `len` says, and the kernel writes at most `len` bytes into it.
    let ok =
        unsafe { libc::getsockopt(fd, libc::IPPROTO_TCP, libc::TCP_INFO, info.as_mut_ptr().cast(), &mut len) } == 0;
    if !ok || (len as usize) < 140 {
        return None;
    }
    let at = |offset: usize| {
        u64::from(u32::from_ne_bytes([info[offset], info[offset + 1], info[offset + 2], info[offset + 3]]))
    };
    Some((at(136), at(100)))
}

#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux", target_os = "android")))]
pub fn counters(_fd: i32) -> Option<(u64, u64)> {
    None
}
