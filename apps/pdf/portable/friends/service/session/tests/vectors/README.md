# Session test vectors and where they come from

ADR 0001 requires the session suite to reproduce, byte for byte, every message ciphertext and the final handshake
hash of every `Noise_{NN,XX,IK}_25519_ChaChaPoly_BLAKE2b` vector in two independent implementations' files.
`friends-session-check` fails when either file loads zero vectors or misses one of the three patterns.

## Noise vectors

Each JSON file holds a `provenance` object and the selected entries, copied unchanged in the Noise wiki's test
vector format. The selection is exact: `protocol_name` equal to one of the three names above, nothing else (no PSK
modifiers, no fallback, no hybrid forms). Each upstream file was fetched at the pinned commit from
raw.githubusercontent.com and checked against the git blob id GitHub's API reports for that path at that commit;
the SHA-256 of the whole upstream file is recorded too. Retrieved 2026-10-12.

| File | Upstream | Commit | Path | Git blob | License |
|---|---|---|---|---|---|
| `cacophony-25519-chachapoly-blake2b.json` | https://github.com/haskell-cryptography/cacophony (0.11.0) | `8ee9d41e34a1a596cfa3ab12aa4069ff87dc1247` | `vectors/cacophony.txt` | `b8a271ed1aba8b4a56bf429e559d7947827123b4` | The Unlicense |
| `snow-25519-chachapoly-blake2b.json` | https://github.com/mcginty/snow (0.10.0) | `8ac60f51cfe3e010c84f0a454cc575ad9204fa12` | `tests/vectors/snow.txt` | `11f7b7c8b43506f1ad8879dc789cc694cd7c17c0` | Apache-2.0 OR MIT |

Upstream SHA-256: cacophony.txt `3bde7c09a6f349ee11c825c50fcc02649f8f02a47c857a459206b357f9386cae`, snow.txt
`69da433305fd045f6c9f01b656662a389d022688986fd39fbe7af009cd402fd3`.

Each file has one entry per pattern. Cacophony's entries carry `handshake_hash`, which the suite checks; snow's do
not, so for them the suite checks every ciphertext and payload, and that both sides derive the same hash.

cacophony is dedicated to the public domain under The Unlicense (its `LICENSE` file at the commit above). snow is
dual-licensed Apache-2.0 OR MIT (`Cargo.toml`); we use it under MIT, whose notice follows:

```
MIT License

Copyright (c) 2021 Jake McGinty

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Golden values in the tests

The known-answer values in `SZFriendsNoiseUnitTests.m` and `SZFriendsCodeTests.m` were computed once with tools
independent of this code, on 2026-10-12, and pasted in:

- HMAC-BLAKE2b and HKDF (Noise § 4.3): Python 3 `hmac` with `hashlib.blake2b` (block size 128), HKDF written out
  from the spec in a few lines.
- Rekey: OpenSSL 3.6.3's raw ChaCha20 (`openssl enc -chacha20`), keystream at block counter 1 under nonce
  `00000000 ffffffffffffffff`, which is what ENCRYPT(k, 2^64-1, empty, zeros) produces before its tag.
- Comparison-code commitment and code: Python 3 `hashlib.blake2b(digest_size=32)` over the ADR's byte strings.
- Prologue: the ADR's `"SZFriends session\0" || 'S' 'Z' 1 pattern`, spelled out in hex.

ADR 0001 asks the independent reviewer to cross-check the preamble, certificate, code derivation and Rekey goldens
once against another Noise implementation; that review has not happened yet.
