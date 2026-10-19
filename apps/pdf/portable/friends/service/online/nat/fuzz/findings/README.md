# Fuzz findings in miniupnpc 2.3.3

No open findings. Inputs that crash a target go here, with a note, until they are fixed; once fixed, they move into
`../corpus/<target>/`, which `friends-nat-check` replays under AddressSanitizer and UndefinedBehaviorSanitizer and
which must pass.

## Fixed

Both were found by the `http` target (`../szfriends_fuzz_upnp_http.c`) in `getHTTPResponse` (`src/miniwget.c`), and
are fixed by a local patch recorded in `ext/miniupnpc/VENDORED.md` § Local changes. Their inputs are now in
`../corpus/http/`, and `friends-miniupnpc-check` (`ext/miniupnpc/szfriends/szfriends_test_miniwget.c`) checks the
patch's behaviour case by case.

- `finding-content-length-overread.bin`: a heap buffer over-read. The header buffer was not NUL-terminated, and
  `atoi` read the Content-Length value from it; a value that is empty or only whitespace up to the end of the
  received bytes made `atoi` skip the CR LF CR LF and read past the allocation. The header name was also matched by
  prefix, so a header named `Cont:` counted as Content-Length. ASan reported a READ past a 2,048-byte region.
- `finding-content-length-allocation.bin`: `getHTTPResponse` grew its content buffer to the announced
  Content-Length once the body passed 2,048 bytes, so one answer could make the helper allocate up to 2 GB and then
  fill it while the sender kept sending. The replay cannot see an allocation, so this input stays as a seed; the
  regression test above checks the bound.

Who could send these: only a server on the default gateway's own address, because `SZFriendsNATUPnP` fetches a
description and posts control requests only to that address. On a shared network (a café, a hotel) that is whoever
runs the router, or anyone spoofing it.
