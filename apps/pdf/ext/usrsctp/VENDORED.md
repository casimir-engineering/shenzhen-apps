# usrsctp (vendored for Shenzhen Friends)

Userspace SCTP, which carries WebRTC data channels inside DTLS, used by `ext/libdatachannel` (ADR 0009). This is
libdatachannel's fork, <https://github.com/paullouisageneau/usrsctp>, of <https://github.com/sctplab/usrsctp>.
Upstream usrsctp is dormant (`m2-decision-brief.md`), so security fixes are expected through the fork.

## Source

- Version: commit `fec583d54493f879d2ae44a743423bf8a04371ab` of the fork, libdatachannel 0.24.6's `deps/usrsctp`
  submodule (as recorded by the stack spike, `m2-stack/SOURCES.md`). The library calls itself 0.9.5.0.
- Archive: <https://codeload.github.com/paullouisageneau/usrsctp/tar.gz/fec583d54493f879d2ae44a743423bf8a04371ab>
- SHA-256: `e5c114afe73c9a0ec419fab5f5b3f63f3ce57b09b90d06ea85e63dca8aed3e7c` (downloaded 2026-10-13).
- Licence: BSD-3-Clause (`LICENSE.md`). The file headers carry further copyright lines under the same or a
  BSD-2-Clause licence (`netinet/sctp_ss_functions.c`), and the FreeBSD-derived files are under the University of
  California's BSD licence without the advertising clause. `ACKNOWLEDGEMENTS.txt` reproduces the licence text and
  every copyright line of the compiled files. `netinet/sctp_userspace.c` also quotes the ACE/TAO (DOC software)
  licence for its Windows-only `getifaddrs` code, which is not compiled on macOS.

## What is here

- `usrsctplib/`: every `.c` and `.h` file of the archive's `usrsctplib/`, unmodified.
- `LICENSE.md`.

Left out: `usrsctplib/`'s build files (`CMakeLists.txt`, `Makefile.am`, `Makefile.nmake`, `meson.build`, also in
`netinet/` and `netinet6/`), and everything outside `usrsctplib/` (`programs/`, `fuzzer/`, the autotools, CMake and
Meson build, the manual).

Local changes: none.

## How it is built

`portable/friends/deps/datachannel.mk` compiles `usrsctplib/*.c`, `netinet/*.c` and `netinet6/*.c` with clang into
`$(BUILD)/friends/deps/libusrsctp.a`, with the macros usrsctp's CMake build defines on macOS for libdatachannel:
userspace, AF_CONN only (no `INET` or `INET6`; libdatachannel turns those sockets off), and `SCTP_DEBUG`, usrsctp's
default. Verification of the build: see `ext/libdatachannel/VENDORED.md`.

One upstream quirk is visible in a linked program: on Apple platforms `netinet/sctp_userspace.c` defines its own
`timingsafe_bcmp`, a name macOS's `<string.h>` declares with default visibility, so it stays exported despite
`-fvisibility=hidden` and replaces libSystem's for the whole program. Both compare in constant time.

## Verifying this copy

```sh
d=$(mktemp -d) && cd "$d"
curl -fsSL -o sctp.tar.gz \
    https://codeload.github.com/paullouisageneau/usrsctp/tar.gz/fec583d54493f879d2ae44a743423bf8a04371ab
echo "e5c114afe73c9a0ec419fab5f5b3f63f3ce57b09b90d06ea85e63dca8aed3e7c  sctp.tar.gz" | shasum -a 256 -c
mkdir x && tar -xzf sctp.tar.gz -C x --strip-components 1
E=<repository>/ext/usrsctp
diff -r -x CMakeLists.txt -x Makefile.am -x Makefile.nmake -x meson.build x/usrsctplib "$E/usrsctplib" &&
    cmp x/LICENSE.md "$E/LICENSE.md" && echo identical
```

## Upgrading

Only together with libdatachannel, to the commit its release pins: see `ext/libdatachannel/VENDORED.md`.
