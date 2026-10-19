# Mbed TLS (vendored for Shenzhen Friends)

DTLS 1.2 and the X.509 certificates behind WebRTC fingerprints, used by `ext/libdatachannel` for Friends' online
routes (ADR 0009). Upstream: <https://www.trustedfirmware.org/projects/mbed-tls/>,
<https://github.com/Mbed-TLS/mbedtls>.

## Source

- Version: 3.6.7, from the 3.6 long-term-support branch. libdatachannel 0.24.6 requires Mbed TLS 3.
- Archive: <https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2>
- SHA-256: `a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6` (downloaded 2026-10-13; the stack
  spike recorded the same hash and found it matches the digest GitHub publishes for the release asset).
- Licence: Apache-2.0 OR GPL-2.0-or-later (`LICENSE` holds both texts). Shenzhen Friends uses it under
  Apache-2.0, whose text is in `portable/friends/ACKNOWLEDGEMENTS.txt`. The release has no NOTICE file.

## What is here

- `include/mbedtls/` and `include/psa/`: the archive's public headers, unmodified.
- `library/`: every `.c` and `.h` file of the archive's `library/`, unmodified.
- `LICENSE`.

Left out: `3rdparty/` (Everest and p256-m, both off in the default configuration and never compiled), the build
files (`CMakeLists.txt`, `Makefile`, `.gitignore` in `include/` and `library/`, and the top-level ones), and
everything else in the archive: `tests/`, `programs/`, `framework/`, `scripts/`, `configs/`, `docs/`, `doxygen/`,
`visualc/`, `pkgconfig/`, `ChangeLog*` and the other top-level documents. Nothing is regenerated: the generated
sources (`error.c`, `version_features.c`, `ssl_debug_helpers_generated.c`,
`psa_crypto_driver_wrappers_no_static.c`, `psa_crypto_driver_wrappers.h`) are the release's own.

Local changes: none. The configuration is upstream's default `include/mbedtls/mbedtls_config.h` plus one option,
`MBEDTLS_SSL_DTLS_SRTP`, which libdatachannel's DTLS code needs even without media. It is defined on the compiler
command line by `portable/friends/deps/datachannel.mk` (`FRIENDS_MBEDTLS_CONFIG`), not by editing the header, and
must reach every file that includes an Mbed TLS header because it changes `struct mbedtls_ssl_context`.

## How it is built

`portable/friends/deps/datachannel.mk` compiles `library/*.c` with clang, `-O2` without `NDEBUG` as upstream's
Release build does, into upstream's three archives: `libmbedcrypto.a`, `libmbedx509.a` and `libmbedtls.a` in
`$(BUILD)/friends/deps/`, with `library/CMakeLists.txt`'s source lists (`ecp_curves_new.c`, a comment-only
placeholder, is not built there either). Unlike upstream it uses `-fvisibility=hidden`, like the rest of the stack,
so `-dead_strip` can drop what libdatachannel never calls. Verification of the build: see
`ext/libdatachannel/VENDORED.md`.

## Verifying this copy

```sh
d=$(mktemp -d) && cd "$d"
curl -fsSL -o mbedtls.tar.bz2 \
    https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2
echo "a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6  mbedtls.tar.bz2" | shasum -a 256 -c
mkdir x && tar -xjf mbedtls.tar.bz2 -C x --strip-components 1
E=<repository>/ext/mbedtls
diff -r -x CMakeLists.txt -x .gitignore x/include "$E/include" &&
    diff -r -x CMakeLists.txt -x Makefile -x .gitignore x/library "$E/library" &&
    cmp x/LICENSE "$E/LICENSE" && echo identical
```

## Upgrading

Stay on the 3.6 LTS branch while libdatachannel requires Mbed TLS 3, and check that branch's end of support (the
decision brief lists it as unchecked). Replace `include/` and `library/` from the new release, keep the source
lists in `datachannel.mk` in step with `library/CMakeLists.txt`, repeat the CMake comparison described in
`ext/libdatachannel/VENDORED.md`, and run `make friends-datachannel-check`.
