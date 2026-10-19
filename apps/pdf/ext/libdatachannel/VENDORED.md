# libdatachannel (vendored for Shenzhen Friends)

WebRTC data channels for Friends' online routes (ADR 0009, `portable/friends/docs/adr/0009-online-transport.md`).
Built with its bundled dependencies, each vendored beside it: `ext/libjuice` (ICE), `ext/usrsctp` (SCTP),
`ext/plog` (logging) and `ext/mbedtls` (DTLS). Upstream: <https://github.com/paullouisageneau/libdatachannel>.

## Source

- Version: 0.24.6, tag `v0.24.6`, commit `6b1e2e620f1e37f0eafeee702eaea0043cb305fd`.
- Archive: <https://codeload.github.com/paullouisageneau/libdatachannel/tar.gz/refs/tags/v0.24.6>
- SHA-256: `22a66aebebd8dae561d8e5181da96f2fcc203e067c5b2186c07b39af913464c0` (downloaded 2026-10-13; the stack
  spike recorded the same hash on the same day, `m2-stack/SOURCES.md`).
- Licence: MPL-2.0 (`LICENSE`), without the "Incompatible With Secondary Licenses" notice. Its full text is in
  `portable/friends/ACKNOWLEDGEMENTS.txt`; the source of every file the app uses is this directory, unmodified.

The release archive leaves the submodules empty. libdatachannel 0.24.6 pins them at these commits, vendored as
their own directories: libjuice `b89c792` (`ext/libjuice`), usrsctp `fec583d` (`ext/usrsctp`, libdatachannel's
fork), plog `94899e0` (`ext/plog`). Its other two submodules, nlohmann/json (examples only) and libsrtp (media
only), are not built with media and examples off, so they are not vendored. libdatachannel 0.24.6 requires Mbed TLS
3 (`find_package(MbedTLS 3 REQUIRED)`); `ext/mbedtls` is 3.6.7.

## What is here

- `include/rtc/` and `src/` (with `src/impl/`): the archive's directories, unmodified.
- `LICENSE`.

Left out: `examples/` (58 MB, nearly all of it the streamer example's sample media), `test/`, `pages/`, `cmake/`, the
empty `deps/`, the build files (`CMakeLists.txt`, `Makefile`, `Jamfile`), the documentation (`README.md`,
`BUILDING.md`, `DOC.md`) and the repository dotfiles (`.github/`, `.gitmodules`, `.clang-format` and others).

Local changes: none.

## How it is built

`portable/friends/deps/datachannel.mk` compiles every `.cpp` under `src/` with clang, C++17, data channels only
(`RTC_ENABLE_MEDIA=0`, `RTC_ENABLE_WEBSOCKET=0`, `USE_MBEDTLS=1`), into `$(BUILD)/friends/deps/libdatachannel.a`.
It explains why it does not use CMake and how its macro sets were checked.

When vendored, all 214 objects of the stack (62 here, 21 libjuice, 23 usrsctp, 108 Mbed TLS) built by
`datachannel.mk` were byte-identical to the objects CMake 4.4.4 built from the same sources with the stack spike's
configuration (`-DUSE_MBEDTLS=ON -DNO_WEBSOCKET=ON -DNO_MEDIA=ON`, `-O2 -DNDEBUG -fvisibility=hidden`, arm64, macOS
12), recompiled from the paths under `ext/` so that `__FILE__` strings match. The one deliberate difference is that
Mbed TLS is compiled with `-fvisibility=hidden` too; the reference compile was given the same flag.

`friends-datachannel-check` (`portable/friends/deps/tests/`) links a C program against the six archives, opens a
data channel between two peers over 127.0.0.1, and checks that the program needs only libc++ and libSystem, targets
macOS 12 on arm64, exports nothing of the stack, and that two builds give byte-identical archives.

## Verifying this copy

```sh
d=$(mktemp -d) && cd "$d"
curl -fsSL -o ldc.tar.gz https://codeload.github.com/paullouisageneau/libdatachannel/tar.gz/refs/tags/v0.24.6
echo "22a66aebebd8dae561d8e5181da96f2fcc203e067c5b2186c07b39af913464c0  ldc.tar.gz" | shasum -a 256 -c
mkdir x && tar -xzf ldc.tar.gz -C x --strip-components 1
E=<repository>/ext/libdatachannel
diff -r x/include "$E/include" && diff -r x/src "$E/src" && cmp x/LICENSE "$E/LICENSE" && echo identical
```

## Upgrading

Upgrade libdatachannel, libjuice, usrsctp and plog together, to the commits the new libdatachannel release pins.
Replace `include/` and `src/` from the new archive, update this file and the other four `VENDORED.md` files, then
repeat the CMake comparison in a scratch directory: configure upstream with `CMAKE_EXPORT_COMPILE_COMMANDS=ON`,
recompile each entry from the `ext/` paths, and compare with the objects `datachannel.mk` builds. Any difference is
a macro or flag `datachannel.mk` must follow. Run `make friends-datachannel-check` and update
`portable/friends/ACKNOWLEDGEMENTS.txt` if a licence or copyright line changed.
