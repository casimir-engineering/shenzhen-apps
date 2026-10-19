# cJSON vendoring note

This directory contains cJSON 1.7.19 (released 2025-09-09), used by the Shenzhen
Friends C client library to read and write the helper's newline-JSON protocol.
Upstream: <https://github.com/DaveGamble/cJSON>.

## Source and verification

- Archive: <https://github.com/DaveGamble/cJSON/archive/refs/tags/v1.7.19.tar.gz>,
  tag `v1.7.19` at commit `c859b25da02955fef659d658b8f324b5cde87be3`.
- Archive SHA-256: `7fa616e3046edfa7a28a32d5f9eacfd23f92900fe1f8ccd988c1662f30454562`
- cJSON publishes no signatures or checksums. The three files below were
  compared byte for byte with the same files fetched separately at the tagged
  commit (`raw.githubusercontent.com/DaveGamble/cJSON/<commit>/...`).

The unmodified upstream files are:

| File | SHA-256 |
|---|---|
| `cJSON.c` | `298581a04a36c0165da4b0aade235c23088cb2faa58651d720ea2f3706ed0b0d` |
| `cJSON.h` | `25b0145150d500498e4d209cec69c18c42cf818bffcc54690be3b895a2a16dee` |
| `LICENSE` (MIT) | `a36dda207c36db5818729c54e7ad4e8b0c6fba847491ba64f372c1a2037b6d5c` |

`cJSON_Utils` (JSON Pointer and Patch) is not vendored; the protocol does not
need it. `portable/friends/deps/deps.mk` compiles `cJSON.c` as C99 with hidden
symbol visibility and the default nesting limit (`CJSON_NESTING_LIMIT`, 1000).

## Upgrading

Download the tag's archive from the official repository, compare `cJSON.c`,
`cJSON.h` and `LICENSE` with the files at the tag's commit, replace them here,
update the hashes above and `ext/versions.txt`, then run
`make -C portable friends-deps-check`.
