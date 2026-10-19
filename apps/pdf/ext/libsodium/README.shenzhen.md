# libsodium vendoring note

This directory contains libsodium 1.0.22 (released 2026-04-09), used by the
Shenzhen Friends helper for identity keys, the Noise session and host-list
signatures. Upstream: <https://libsodium.org>, <https://github.com/jedisct1/libsodium>.

## Source and verification

- Tarball: <https://download.libsodium.org/libsodium/releases/libsodium-1.0.22.tar.gz>,
  byte-identical to the `1.0.22-RELEASE` asset on GitHub.
- SHA-256: `adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349`
- Minisign signature (`.minisig`) verified against the key published in the
  libsodium documentation, `RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3`.
  The minisign binary was not installed, so the documented minisign format
  (prehashed Ed25519 over BLAKE2b-512, plus the trusted-comment signature) was
  checked with Python's `cryptography` package; a one-byte change to the tarball
  failed the same check.
- GPG signature (`.sig`) verified in a throwaway keyring against the RSA key in
  the same documentation (good signature from key
  `0C7983A8FD9A104C623172CB62F25B592B6F76DA`, primary
  `54A2B8892CC3D6A597B92B6C210627AABA709FE1`).
- GitHub's recorded digest for the release asset matches the SHA-256 above.

## What is here

- `src/libsodium/`: the tarball's `src/libsodium/` unmodified, except that the
  seven x86-64 assembly files (`*.S`), `Makefile.am`, `Makefile.in` and
  `version.h.in` are left out. The assembly is optional x86-64 acceleration and
  the C implementations cover every primitive; the build never runs autotools.
- `src/libsodium/include/sodium/version.h`: the tarball's
  `builds/msvc/version.h`, identical to the one configure generates.
- `LICENSE` (ISC) and `AUTHORS`.

`portable/friends/deps/deps.mk` compiles the sources directly with clang into a
static library and explains why it does not run configure.

## Upgrading

1. Download the new `libsodium-X.Y.Z.tar.gz` and its `.minisig` from
   <https://download.libsodium.org/libsodium/releases/> and verify:
   `minisign -VP RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3 -m libsodium-X.Y.Z.tar.gz`.
2. Replace `src/libsodium/` with the new release's, leaving out the same files,
   and copy `builds/msvc/version.h` to `src/libsodium/include/sodium/`.
3. Run `portable/friends/deps/check-sodium-config.sh <extracted release>`. It
   confirms the vendored tree matches the release and that every object built
   by `deps.mk` is byte-identical to upstream's configured build. If objects
   differ, update the macro list in `deps.mk` from configure's `DEFS` line.
4. Run `make -C portable friends-deps-check` and update `ext/versions.txt`.
