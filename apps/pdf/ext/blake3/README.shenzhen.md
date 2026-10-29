# BLAKE3 vendoring note

This directory holds the C implementation of BLAKE3 1.8.5, which the Shenzhen Friends helper uses for the hash tree
of fast transfers (ADR 0018 § 2). The Rust core uses the `blake3` crate of the same version; both must give the
vectors in `portable/friends/fixtures/vectors/transfer/`. Upstream: <https://github.com/BLAKE3-team/BLAKE3>.

## Source and verification

- Taken from the `blake3-1.8.5.crate` that `portable/friends/core-rs/Cargo.lock` pins, whose SHA-256
  `0aa83c34e62843d924f905e0f5c866eb1dd6545fc4d719e803d9ba6030371fce` (Cargo.lock's checksum) was checked against
  the archive, extracted into an empty directory. The crate carries upstream's `c/` directory unchanged; its
  `blake3.h` says 1.8.5.

## What is here

- `c/`: `blake3.c`, `blake3.h`, `blake3_impl.h`, `blake3_dispatch.c`, `blake3_portable.c`, `blake3_neon.c` and the
  x86 intrinsics files `blake3_sse2.c`, `blake3_sse41.c`, `blake3_avx2.c`, `blake3_avx512.c`, unmodified. Left out:
  the assembly (`*.S`, `*.asm`; the intrinsics cover the same instruction sets), the TBB file, CMake and the
  examples and tests.
- `LICENSE_A2`, `LICENSE_A2LLVM`, `LICENSE_CC0`: upstream's licences (CC0 1.0, or Apache 2.0, or Apache 2.0 with
  LLVM exceptions, at the user's choice).

`portable/friends/deps/deps.mk` compiles it into `libblake3.a`: on arm64 with the NEON code, on x86_64 with each
intrinsics file at its own instruction set, chosen at run time by `blake3_dispatch.c`.
