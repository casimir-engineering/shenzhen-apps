# Working in this repository

ShenzhenPDF is a native **macOS** reader (AppKit) for PDFs and Markdown, built on a
portable C core wrapping MuPDF, with a GTK4 Linux frontend and a native Win32
frontend sharing that core. Everything lives under `portable/`; the inherited
SumatraPDF Win32 tree that used to sit in `src/`, with its build tooling and CI,
has been deleted. `ext/` and `mupdf/` remain because the portable build compiles
against them, and `gfx/` because the macOS icon is built from it.

Read these rather than duplicating them here:

| Topic | Where |
|---|---|
| **Start here**: architecture map, philosophy, tools, release flow, traps, open threads | `portable/docs/agent-handoff.md` |
| Portable layout, build/test commands, release process | `portable/README.md` |
| Rendering pipeline, view, scroll, zoom, minimap internals | `portable/docs/architecture.md` |
| Per-file size caps and how to change one | `tools/file-size-limits.md` |
| Markdown engine contract (canonical coordinates, budgets) | `portable/mac/markdown/README.md` |
| What the product ships | `readme.md` |

## Rules that live nowhere else

**Do not launch, quit, or screenshot the app to verify your work.** The user
usually has ShenzhenPDF open while work is in progress, and restarting it
interrupts them. Verify headlessly — the test suites, or a probe binary that
writes PNGs you sample programmatically — and launch only when asked.

**Judge test results by exit code, not by piping into `grep`.**
`run-tests.sh | grep -c passed` reports *grep's* exit status, so a failed compile
can look green. Redirect to a file and check `$?`.

**Prefer extracting a focused file over raising a size cap**, and when a cap must
move, justify it in `tools/file-size-limits.tsv` in the style already there.

**Keep the render path deterministic and explicit.** Theme variants, render
options and page configurations are threaded through as parameters, never read
from ambient app state deep inside rendering; colors in rendered output are
concrete sRGB constants, never appearance-dynamic, so screen, print and export
always produce the same page.

**Speed is a standing requirement.** A feature must cost nothing for documents
that do not use it, and nothing new may run on the launch path. Prove laziness
with a test rather than asserting it.

**Commit each meaningful, tested change set.** Do not commit half-finished work.
