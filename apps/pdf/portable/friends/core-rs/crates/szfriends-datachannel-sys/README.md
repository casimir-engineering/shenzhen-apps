# szfriends-datachannel-sys

The Objective-C helper's WebRTC data-channel stack for the portable core
([ADR 0015](../../../docs/adr/0015-portable-core.md) § 9): libdatachannel 0.24.6 with libjuice, usrsctp and Mbed
TLS 3.6.7, from the pinned sources under `ext/` that [ADR 0009](../../../docs/adr/0009-online-transport.md) vetted,
and a small safe Rust interface over its C API.

- `build.rs` compiles the four libraries with `cc` (no CMake) from the same source lists and configuration macros as
  `portable/friends/deps/datachannel.mk`, plus the per-platform macros upstream's CMake checks find (usrsctp's `HAVE_*`,
  the Windows defines). For ADR 0015 § 12's sizes it then leaves out three things the helper's copy keeps: Mbed TLS
  features neither DTLS nor the host connection uses (`src/mbedtls_trim.h`, read by everything that includes Mbed
  TLS; the interop suites run it against the helper's default configuration), the C libraries' unwind tables, and
  libdatachannel's logging (`SZFRIENDS_DATACHANNEL_LOGGING=1` keeps it for `log_to_stderr` while debugging). On
  Android, with the core's other phone settings, they took the whole embedded core from 5.62 to 4.95 MB.
  `SZFRIENDS_DATACHANNEL_NO_NATIVE=1` skips the native build for `cargo check` of targets this machine has no
  compiler for; `SZFRIENDS_EXT_DIR` points at `ext/` when it is not above the crate.
- `src/connection.rs`: `PeerConnection` (local and remote descriptions, trickled candidates, the selected pair) and
  `DataChannel` (reliable and ordered, open, send, receive). Everything the stack reports arrives as an `Event` on a
  channel. Callbacks reach Rust through a registry keyed by number, so a callback racing a drop finds nothing rather
  than freed memory. A `DataChannel` keeps its connection's handle, so the stack's connection is deleted only after
  every channel of it; and no handle is released on the stack's own threads: a channel the remote opens after its
  receiver or connection was dropped goes to the release thread, as do the connections owners hand over
  (`release_in_background`).
- `src/lifetime.rs`: the end of the stack. Every handle is counted until its `rtcDelete*` call returns; `shutdown`
  refuses new connections, waits for the count to reach zero, joins the release thread and calls `rtcCleanup`, which
  joins the stack's own threads. The first connection registers it with `atexit`, so it runs before the C runtime
  destroys the stack's globals (which, with a deletion still running, freed memory twice on glibc and faulted on
  Windows on Arm). This is the one crate allowed `unsafe`;
  `src/layout.rs` checks the hand-written structures against what the target's C compiler makes of `rtc.h`.

- `src/tls.rs`, `src/tls.c`: the host connection's `wss://`, a TLS 1.2 client on the same Mbed TLS (1.2 only, so it
  never shares the PSA key store with the stack's DTLS threads). The server's chain and name are checked by Mbed TLS
  against the system's CA files on Linux and Android, by the system on Windows (`CertGetCertificateChain`, the SSL
  policy) and Apple systems (`SecTrust`), or against a test's own CA. `szfriends-online`'s `tests/tls_host.rs`
  checks it against a Node TLS server.

## Tests

- `tests/loopback.rs` (every platform): two Rust peers on 127.0.0.1 open a channel and echo 1 B, 1000 B, 64 KiB and
  4 MiB in 64 KiB messages, in order; an oversized message is refused; a malformed answer and candidate are refused.
- `tests/shutdown.rs` (every platform, its own process): the stack ends only after a connection on the release
  thread and one still held are deleted, and refuses new connections afterwards.
- `tests/lifetimes.rs` (every platform): a channel the remote opens after the receiver was dropped is released and
  the remote sees it close; a channel kept after its connection was dropped refuses to send and drops cleanly.
- `tests/objc_interop.rs` (macOS, `make friends-datachannel-rs-check`): a Rust peer against the helper's own
  `SZFriendsOnlineDataChannelTransport` in its testing configuration (`tools/objc-dc-peer`), once with each side
  offering. The helper's description and candidate rules accept what this stack produces, the route is reported as a
  direct host pair, and 4 MiB echoes in order. Elsewhere it says it skipped and passes.
- `examples/dc_echo.rs` and `examples/baseline.rs`: what `tools/datachannel-sizes.sh` measures.

Nothing leaves the loopback interface: peers bind to 127.0.0.1, no STUN or TURN server is set, and only loopback
candidates are signalled.

## Spike results (wave 2, 2026-10-16)

Every target built the stack and opened a data channel; the str0m fallback is not needed for any of them.

| Target | Where it ran | Result |
| --- | --- | --- |
| aarch64-apple-darwin | this Mac | loopback and both interop directions pass |
| x86_64-apple-darwin | this Mac, under Rosetta | loopback passes |
| aarch64-apple-ios-sim | iOS 26.5 simulator | loopback passes |
| aarch64-apple-ios | built and linked for iOS 15 | not run (no device) |
| aarch64-linux-android | Android 16 emulator (API 36), NDK 28.2 at API 24 | loopback passes, dc_echo runs |
| aarch64-unknown-linux-gnu | Ubuntu 24.04 VM, gcc 13.3 | whole workspace passes (44 tests), dc_echo runs |
| aarch64-pc-windows-msvc | Windows 11 VM, MSVC | whole workspace passes (43 tests), dc_echo runs |
| x86_64-pc-windows-msvc | Windows 11 VM, emulated x64 | whole workspace passes (43 tests), dc_echo runs |
| x86_64-unknown-linux-gnu, x86_64-pc-windows-gnu, other Android ABIs | `cargo check` only | pass |

What the stack adds to a stripped release binary (`dc_echo` minus `baseline`, workspace release profile: opt-level s,
thin LTO, symbols stripped), against ADR 0015 § 12 (whole desktop helper at most 6 MB per architecture; whole
embedded core at most 5 MB per Android ABI and iOS architecture, 3 MB in a compressed APK split; the stack's share
estimated at 1.6 MB):

| Target | dc_echo | baseline | Added |
| --- | ---: | ---: | ---: |
| aarch64-apple-darwin | 1,818,880 | 358,720 | 1.46 MB |
| x86_64-apple-darwin | 1,869,044 | 344,200 | 1.52 MB |
| aarch64-apple-ios | 1,804,316 | 355,436 | 1.45 MB |
| aarch64-apple-ios-sim | 1,801,968 | 341,856 | 1.46 MB |
| aarch64-linux-android | 2,507,392 | 339,960 | 2.17 MB (0.88 MB deflated) |
| aarch64-unknown-linux-gnu | 2,038,384 | 332,624 | 1.71 MB |
| aarch64-pc-windows-msvc | 1,737,728 | 165,888 | 1.57 MB |
| x86_64-pc-windows-msvc | 1,738,240 | 166,400 | 1.57 MB |
| aarch64-pc-windows-msvc, static CRT | 2,055,168 | 262,144 | 1.79 MB |
| x86_64-pc-windows-msvc, static CRT | 2,067,968 | 264,192 | 1.80 MB |

Within budget everywhere. Android is the largest because it carries the NDK's static libc++ (an app has one native
library, so it cannot rely on a shared one); Linux and Apple platforms use the system's C++ library.

## Findings for later waves

- **Windows C++ runtime.** With the default dynamic CRT the helper imports `MSVCP140.dll` and `VCRUNTIME140_1.dll`,
  which a pure Rust binary does not, so it would need the Visual C++ redistributable. Built with
  `-C target-feature=+crt-static` (cc follows it with `/MT`) it imports only system DLLs and adds 1.8 MB instead of
  1.6 MB. Decided: the workspace's `.cargo/config.toml` sets it for every Windows MSVC build, the VM suites included.
- **Optimisation level.** The stack now builds at `-O2` in every profile (`build.rs`), as the helper's copy does;
  the sizes above were measured at the release profile's `-Os`, and `-O2` adds about 0.1 MB
  (`tools/embedded-size.sh`).
- **Build time.** `cargo test --workspace` now compiles 215 C and C++ files (about 7 s on this Mac, a few minutes
  in the VMs). `friends-core-rs-cross-check` skips them.
- **Not exercised here:** a physical iOS device, native x86_64 Linux (the Ubuntu VM's toolchain is arm64 only), TURN,
  and the helper's connection order (direct-phase timer, injected candidates, relay as a second connection), which
  wave 5 builds on this interface.
- **Unrelated to this crate:** `szfriends-identity`'s `file_store_refuses_what_is_not_ours` fails on the Android 16
  emulator (`StoreFailed` on the first store, running as the shell user under `/data/local/tmp`).
