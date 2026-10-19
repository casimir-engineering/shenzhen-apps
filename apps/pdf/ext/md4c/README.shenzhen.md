# MD4C vendoring note

This directory contains the parser source and public header from MD4C
`release-0.5.3`, upstream commit `472c417005c2c71b8617de4f7b8d6b30411d78f4`.

Upstream: <https://github.com/mity/md4c>

The unmodified upstream files are:

- `md4c.c`
- `md4c.h`
- `LICENSE.md`

Shenzhen PDF compiles `md4c.c` as C and uses the SAX-style parser API. The
HTML renderer is intentionally not vendored: Markdown is rendered to native
AppKit attributed text and raw HTML is disabled at parse time.
