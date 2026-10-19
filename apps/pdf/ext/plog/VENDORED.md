# plog (vendored for Shenzhen Friends)

A header-only C++ logging library that `ext/libdatachannel` logs through (ADR 0009). Nothing is compiled from here
on its own: libdatachannel's objects include these headers. Upstream: <https://github.com/SergiusTheBest/plog>.

## Source

- Version: commit `94899e0b926ac1b0f4750bfbd495167b4a6ae9ef`, libdatachannel 0.24.6's `deps/plog` submodule (as
  recorded by the stack spike, `m2-stack/SOURCES.md`).
- Archive: <https://codeload.github.com/SergiusTheBest/plog/tar.gz/94899e0b926ac1b0f4750bfbd495167b4a6ae9ef>
- SHA-256: `92a08bce559b5f28aa88d3fd9071567414b9f43a83fe2a05a6dd14f1da536072` (downloaded 2026-10-13).
- Licence: MIT (`LICENSE`), reproduced in `portable/friends/ACKNOWLEDGEMENTS.txt`.

## What is here

- `include/plog/`: the archive's headers, unmodified.
- `LICENSE`.

Left out: `samples/`, `test/`, `doc/`, the build and packaging files (`CMakeLists.txt`, `library.json`,
`plog.nuspec`, `plog.targets`) and `README.md`.

Local changes: none.

## Verifying this copy

```sh
d=$(mktemp -d) && cd "$d"
curl -fsSL -o plog.tar.gz \
    https://codeload.github.com/SergiusTheBest/plog/tar.gz/94899e0b926ac1b0f4750bfbd495167b4a6ae9ef
echo "92a08bce559b5f28aa88d3fd9071567414b9f43a83fe2a05a6dd14f1da536072  plog.tar.gz" | shasum -a 256 -c
mkdir x && tar -xzf plog.tar.gz -C x --strip-components 1
E=<repository>/ext/plog
diff -r x/include "$E/include" && cmp x/LICENSE "$E/LICENSE" && echo identical
```

## Upgrading

Only together with libdatachannel, to the commit its release pins: see `ext/libdatachannel/VENDORED.md`.
