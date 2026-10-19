# Shenzhen PDF Notices

Shenzhen PDF is an independent project inspired by the lightweight, fast-reader
philosophy of SumatraPDF. It is not affiliated with, sponsored by, or endorsed
by the SumatraPDF project.

This repository currently retains source code and dependencies that carry their
own licenses and notices. Do not remove copyright notices from source files or
third-party packages when publishing this project.

Important retained notice files include:

- `AUTHORS`
- `COPYING`
- `COPYING.BSD`
- `mupdf/COPYING`
- license files and notices under `ext/`, `packages/`, and `mupdf/`

If a future repository revision removes all inherited code, this notice can be
updated after a source audit confirms the retained license obligations.

## Shenzhen Friends

Shenzhen Friends (`portable/friends/`) adds the following third-party software
and data. `portable/friends/ACKNOWLEDGEMENTS.txt` reproduces their notices, and
ships as `Acknowledgements.txt` in ShenzhenPDF.app
(`Contents/Resources/Friends/`) and in the Shenzhen Friends helper bundle
(`Contents/Resources/`). The helper bundle also carries the license file of
each library it links, in `Contents/Resources/Licenses/`.

- libsodium 1.0.22, ISC License: `ext/libsodium/LICENSE`
- cJSON 1.7.19, MIT License: `ext/cjson/LICENSE`
- libdatachannel 0.24.6, Mozilla Public License 2.0: `ext/libdatachannel/LICENSE`
- libjuice 1.7.4, Mozilla Public License 2.0: `ext/libjuice/LICENSE`
- usrsctp 0.9.5.0 (libdatachannel's fork), BSD 3-Clause License:
  `ext/usrsctp/LICENSE.md`
- plog, MIT License: `ext/plog/LICENSE`
- Mbed TLS 3.6.7, Apache License 2.0 (offered under Apache-2.0 OR
  GPL-2.0-or-later; used under Apache-2.0): `ext/mbedtls/LICENSE`
- miniupnpc 2.3.3, BSD 3-Clause License: `ext/miniupnpc/LICENSE`. One
  function is changed locally; `ext/miniupnpc/VENDORED.md` has the diff.
- The EFF Large Wordlist for Passphrases, CC BY 4.0. Friends ID words are a
  selection from the EFF Large Wordlist for Passphrases by the Electronic
  Frontier Foundation (https://www.eff.org/dice), used under CC BY 4.0
  (https://creativecommons.org/licenses/by/4.0/). Changes: 2,048 of its 7,776
  words selected; none altered.
