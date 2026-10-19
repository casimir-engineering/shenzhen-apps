# libjuice (vendored for Shenzhen Friends)

UDP Interactive Connectivity Establishment (ICE), used by `ext/libdatachannel` for Friends' online routes (ADR
0009). Upstream: <https://github.com/paullouisageneau/libjuice>.

## Source

- Version: 1.7.4, commit `b89c792e3612faf2f12cf35bcc56857313a06be3`: the `v1.7.4` tag and libdatachannel 0.24.6's
  `deps/libjuice` submodule (as recorded by the stack spike, `m2-stack/SOURCES.md`).
- Archive: <https://codeload.github.com/paullouisageneau/libjuice/tar.gz/b89c792e3612faf2f12cf35bcc56857313a06be3>
- SHA-256: `713b22174e8cb2e06538fa9bac2650bda21b83c86f5128813ab4dcf8f5bea9ed` (downloaded 2026-10-13).

  Pinned by commit rather than tag on purpose: the spikes downloaded libjuice 1.7.4 through two different URLs and
  recorded two different hashes (`m2-decision-brief.md`); this is the commit archive, whose hash the stack spike
  also recorded.
- Licence: MPL-2.0 (`LICENSE`, identical to libdatachannel's), without the "Incompatible With Secondary Licenses"
  notice. Its full text is in `portable/friends/ACKNOWLEDGEMENTS.txt`.

## What is here

- `include/juice/juice.h` and `src/`: the archive's directories, unmodified.
- `LICENSE`.

Left out: `test/`, `fuzzer/`, `cmake/`, `CMakeLists.txt`, `Makefile`, `README.md` and `CONTRIBUTING.md`.

Local changes: none.

## How it is built

`portable/friends/deps/datachannel.mk` compiles `src/*.c` with clang into `$(BUILD)/friends/deps/libjuice.a`, with
upstream's Release macros (`RELEASE=1`, `USE_NETTLE=0`, `JUICE_STATIC`). The built-in STUN/TURN server stays
compiled, as upstream and the spike had it; `-dead_strip` removes it from a program that never calls
`juice_server_create`. Verification of the build: see `ext/libdatachannel/VENDORED.md`.

## Verifying this copy

```sh
d=$(mktemp -d) && cd "$d"
curl -fsSL -o juice.tar.gz \
    https://codeload.github.com/paullouisageneau/libjuice/tar.gz/b89c792e3612faf2f12cf35bcc56857313a06be3
echo "713b22174e8cb2e06538fa9bac2650bda21b83c86f5128813ab4dcf8f5bea9ed  juice.tar.gz" | shasum -a 256 -c
mkdir x && tar -xzf juice.tar.gz -C x --strip-components 1
E=<repository>/ext/libjuice
diff -r x/include "$E/include" && diff -r x/src "$E/src" && cmp x/LICENSE "$E/LICENSE" && echo identical
```

## Upgrading

Only together with libdatachannel, to the commit its release pins: see `ext/libdatachannel/VENDORED.md`.
