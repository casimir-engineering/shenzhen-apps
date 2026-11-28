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

- `include/juice/juice.h` and `src/`: the archive's directories, unmodified apart from the local changes below.
- `LICENSE`.

Left out: `test/`, `fuzzer/`, `cmake/`, `CMakeLists.txt`, `Makefile`, `README.md` and `CONTRIBUTING.md`.

Local changes (Shenzhen Friends, 2026-11-27; ADR 0011 § VPN and tunnels, Revised), each marked "Shenzhen Friends" in
the source:

- **Openers** (`src/agent.c`, `src/agent.h`, `src/conn.c`, `src/conn.h`, `src/conn_poll.c`, `src/conn_poll.h`): before
  its first check to a peer address the agent sends Binding indications with TTL 2, 3 and 4 (`AGENT_OPENER_*`), and a
  controlled agent sends only those, every 500 ms, until a check or a check's response comes from the peer or 1.5 s
  pass. A check that reaches a Linux NAT before the peer behind it has sent anything leaves an unreplied conntrack
  entry, and the peer's own packets then leave from another public port; the openers open this side's NATs without
  reaching the peer's. Poll mode only (the one libdatachannel uses without its UDP mux), where each agent owns its
  socket and one datagram can change the TTL under the send mutex. The TTL is put back after each opener; on Apple
  systems a dual-stack socket's hop limit reads -1, and writing -1 back sent its IPv4-mapped datagrams at TTL 255, so
  the system's default TTL (`net.inet.ip.ttl`) is restored instead.
- **Bind address `%<interface>`** (`src/udp.c`): binds the unspecified address with `IP_BOUND_IF` or `IPV6_BOUND_IF`
  on that interface, on Apple systems; a socket that cannot be kept there is not opened. Elsewhere it binds the
  unspecified address.

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
diff -r x/include "$E/include" && cmp x/LICENSE "$E/LICENSE" && echo include identical
diff -r x/src "$E/src" # only the local changes above
```

## Upgrading

Only together with libdatachannel, to the commit its release pins: see `ext/libdatachannel/VENDORED.md`.
