//! A TLS 1.2 client over a `TcpStream`, for the host connection's `wss://` (HOST-PROTOCOL.md § Transport), on the
//! Mbed TLS this crate already builds for the stack's DTLS (`src/tls.c` says why 1.2, and how the server is checked).
//!
//! Who the server is: [`Roots::System`] is what a browser on the same system would accept: the system's CA files on
//! Linux and Android, checked by Mbed TLS, and the system's own verifier on Windows (`CertGetCertificateChain` with
//! the SSL policy) and on Apple systems (`SecTrust`). [`Roots::Pem`] trusts exactly the certificates given (tests: a
//! CA of their own). Either way the name in the URL must be the certificate's, and nothing is written to the server
//! before it has been checked.

use std::ffi::{c_char, c_int, c_void, CString};
use std::io::{self, ErrorKind, Read, Write};
use std::net::TcpStream;
use std::time::Duration;

const WANT_READ: c_int = -0x6900;
const WANT_WRITE: c_int = -0x6880;
const PEER_CLOSE_NOTIFY: c_int = -0x7880;
const NET_SEND_FAILED: c_int = -0x004E;
const NET_RECV_FAILED: c_int = -0x004C;

#[repr(C)]
struct Context {
    _private: [u8; 0],
}

type SendFn = extern "C" fn(*mut c_void, *const u8, usize) -> c_int;
type RecvFn = extern "C" fn(*mut c_void, *mut u8, usize) -> c_int;

extern "C" {
    fn szf_tls_new() -> *mut Context;
    fn szf_tls_free(tls: *mut Context);
    fn szf_tls_add_roots(tls: *mut Context, data: *const u8, len: usize) -> c_int;
    fn szf_tls_setup(tls: *mut Context, hostname: *const c_char, io: *mut c_void, send: SendFn, recv: RecvFn) -> c_int;
    fn szf_tls_handshake(tls: *mut Context) -> c_int;
    fn szf_tls_read(tls: *mut Context, buf: *mut u8, len: usize) -> c_int;
    fn szf_tls_write(tls: *mut Context, buf: *const u8, len: usize) -> c_int;
    fn szf_tls_close_notify(tls: *mut Context);
    fn szf_tls_verified(tls: *mut Context, hostname: *const c_char) -> c_int;
}

/// Which certificates the server's chain must end in.
#[derive(Clone, Debug)]
pub enum Roots {
    /// The system's, as a browser there would decide.
    System,
    /// Exactly these PEM certificates (tests).
    Pem(Vec<u8>),
}

fn would_block(error: &io::Error) -> bool {
    matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted)
}

extern "C" fn send(io: *mut c_void, buf: *const u8, len: usize) -> c_int {
    // SAFETY: `io` is the `TcpStream` a `TlsStream` boxed for its whole life; `buf` holds `len` bytes for the call.
    let (stream, data) = unsafe { (&*(io as *const TcpStream), std::slice::from_raw_parts(buf, len)) };
    match (&*stream).write(data) {
        Ok(n) => c_int::try_from(n).unwrap_or(c_int::MAX),
        Err(error) if would_block(&error) => WANT_WRITE,
        Err(_) => NET_SEND_FAILED,
    }
}

extern "C" fn recv(io: *mut c_void, buf: *mut u8, len: usize) -> c_int {
    // SAFETY: as in `send`; `buf` is writable for `len` bytes for the call.
    let (stream, data) = unsafe { (&*(io as *const TcpStream), std::slice::from_raw_parts_mut(buf, len)) };
    match (&*stream).read(data) {
        Ok(n) => c_int::try_from(n).unwrap_or(c_int::MAX),
        Err(error) if would_block(&error) => WANT_READ,
        Err(_) => NET_RECV_FAILED,
    }
}

/// The system's CA certificates where they are files (Linux, Android); none elsewhere, where the system verifies.
fn system_roots() -> Vec<Vec<u8>> {
    let mut found = Vec::new();
    if cfg!(target_os = "android") {
        for directory in ["/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"] {
            let Ok(entries) = std::fs::read_dir(directory) else { continue };
            found.extend(entries.filter_map(|e| std::fs::read(e.ok()?.path()).ok()));
            if !found.is_empty() {
                break;
            }
        }
    } else if cfg!(all(unix, not(target_vendor = "apple"))) {
        let bundles = [
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/ca-bundle.pem",
            "/etc/ssl/cert.pem",
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
        ];
        found.extend(bundles.iter().find_map(|path| std::fs::read(path).ok()));
    }
    found
}

/// One TLS connection. Reads and writes may run on different threads only behind a lock (the host's WebSocket
/// shares it); a read that finds nothing within the socket's read timeout returns `WouldBlock`.
pub struct TlsStream {
    tls: *mut Context,
    /// Boxed so its address, which the C side holds, never moves.
    io: Box<TcpStream>,
}

// SAFETY: the context is used only through `&mut self` (one thread at a time); Mbed TLS keeps no thread affinity.
unsafe impl Send for TlsStream {}

impl std::fmt::Debug for TlsStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TlsStream").field("peer", &self.io.peer_addr().ok()).finish()
    }
}

impl TlsStream {
    /// Runs the handshake on `stream` (within `timeout`) and checks the server against `roots` and `hostname`.
    pub fn connect(stream: TcpStream, hostname: &str, roots: &Roots, timeout: Duration) -> io::Result<Self> {
        let name = CString::new(hostname).map_err(|_| io::Error::other("host name"))?;
        // SAFETY: a fresh context or null; owned by the `TlsStream` from here on, which frees it once.
        let tls = unsafe { szf_tls_new() };
        if tls.is_null() {
            return Err(io::Error::other("no TLS context"));
        }
        let this = Self { tls, io: Box::new(stream) };
        let pems = match roots {
            Roots::System => system_roots(),
            Roots::Pem(pem) => vec![pem.clone()],
        };
        for mut pem in pems {
            pem.push(0); // Mbed TLS reads PEM up to its NUL
                         // SAFETY: `pem` is readable for its length during the call, which copies what it parses.
            unsafe { szf_tls_add_roots(this.tls, pem.as_ptr(), pem.len()) };
        }
        this.io.set_read_timeout(Some(timeout))?;
        this.io.set_write_timeout(Some(timeout))?;
        let io = (&*this.io as *const TcpStream).cast_mut().cast::<c_void>();
        // SAFETY: the context is live; `name` outlives the call (Mbed TLS copies it); `io` lives as long as `this`.
        if unsafe { szf_tls_setup(this.tls, name.as_ptr(), io, send, recv) } != 0 {
            return Err(io::Error::other("TLS setup"));
        }
        // SAFETY: the context is live and set up. A timeout during the handshake reads as WANT_READ: failure.
        let handshake = unsafe { szf_tls_handshake(this.tls) };
        // SAFETY: as above; `name` outlives the call.
        if handshake != 0 || unsafe { szf_tls_verified(this.tls, name.as_ptr()) } != 1 {
            return Err(io::Error::new(ErrorKind::PermissionDenied, "the host's certificate was not accepted"));
        }
        Ok(this)
    }

    /// The TCP connection underneath, for timeouts and shutting it down.
    pub fn tcp(&self) -> &TcpStream {
        &self.io
    }
}

impl Read for TlsStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            // SAFETY: the context is live; `buf` is writable for its length.
            let n = unsafe { szf_tls_read(self.tls, buf.as_mut_ptr(), buf.len()) };
            return match n {
                n if n > 0 => Ok(n as usize),
                0 | PEER_CLOSE_NOTIFY => Ok(0),
                WANT_READ => Err(ErrorKind::WouldBlock.into()),
                WANT_WRITE => continue,
                _ => Err(io::Error::other("TLS read")),
            };
        }
    }
}

impl Write for TlsStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        loop {
            // SAFETY: the context is live; `buf` is readable for its length.
            let n = unsafe { szf_tls_write(self.tls, buf.as_ptr(), buf.len()) };
            return match n {
                n if n >= 0 => Ok(n as usize),
                WANT_READ | WANT_WRITE => continue,
                _ => Err(io::Error::other("TLS write")),
            };
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for TlsStream {
    fn drop(&mut self) {
        // SAFETY: the context is live until freed here, once; nothing uses it afterwards.
        unsafe {
            szf_tls_close_notify(self.tls);
            szf_tls_free(self.tls);
        }
    }
}
