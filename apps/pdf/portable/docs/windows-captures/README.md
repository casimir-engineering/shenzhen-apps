# Windows captures

The first screenshots of a ShenzhenPDF window on Windows.

Until 2026-09-01 there were none, and there could not be: the port was built
from a macOS host driving a Parallels VM through `prlctl exec`, which runs as
`nt authority\system` and has no interactive desktop. Every visual claim in this
repo was a build, an exit code, or an offscreen render — `windows-port-handoff.md`
§0 states it plainly: *"Nobody has ever seen a ShenzhenPDF window open on
Windows."* These are the counter-evidence, and they are the Windows counterpart
to `portable/docs/gtk4-captures/` and `portable/docs/linux-captures/`.

| file | what it shows |
|---|---|
| `01-window-light.png` | The light window at 1500×950 on a 144 dpi (150%) display |
| `02-window-dark.png` | The same, `--dark` |
| `03-markdown-light.png` | `portable/win/tests/fixtures/readme-style.md` open as a paginated document: its headings are the Chapters list, page 1 of 4 at fit width, badges, emphasis, a blockquote and a callout |
| `04-markdown-dark.png` | The same Markdown document in the dark reading theme: the Obsidian-style dark rendition the core lays out beside the light one, chrome and paper both dark |
| `05-markdown-code-light.png` | Page 2: the code boxes with per-language syntax highlighting (C, Python, JSON, YAML, shell), light theme |
| `06-markdown-page3-light.png` | Page 3 of the same fixture as a bare page render (`--render-png`, no chrome): the Images section -- a local figure with its caption, the placeholder a remote badge shows before its fetch has landed, an inline image in a sentence -- then inline and display math and the start of the long section |
| `07-search-section-headless.png` | The Search section, composed OFFSCREEN: `--render-window-png --chrome --find fixture` over `outline.pdf` at 150%, with the four matches grouped under their chapter headings, the active one ringed, and the strip and scroller markers |
| `08-window-light.png` | The light window again on 2026-09-03, at HEAD `0fb7d8d92`. Same document and size as 01, so the two are a **before/after of the caption hoist**: 01 still has an OS title bar above the tab strip, 08 has one header band with the app's own caption buttons, and the toolbar's icons are the current set |
| `09-window-dark.png` | The same, `--dark`. Gutter `#121212`, paper `#1E1E1E`, page border `#333333`, and the fixture's own 4 pt red box **remapped** to `#FF565B`-ish rather than inverted — the luma remap seen on a colour that is not ink |
| `10-markdown-light.png` | `readme-style.md` at HEAD, live: the headings as the Chapters list, page 1 of 4 at fit width, with today's chrome |
| `11-search-results-live.png` | The Search section in a **live window**, which 07 could only show offscreen: the query TYPED into the find field (`drive-uia.ps1` `cmd:26` then `type:fixture`), the Search segment selected, four results grouped under their chapter headings with "match *n* of 4", the active match ringed red over yellow, heat-map ticks on the scroller **and** yellow marker bars inside the minimap thumbnails |
| `12-comments-sidebar.png` | The **Comments** section with a real comment in it, created live: a click on the page, Add Comment, author and text typed into the dialog, Add. The note marker is on the page, the section header reads `Page 1`, the row reads `Reviewer: Check this heading agains…` / `Text - Page 1`, and the filter field says "Filter Comments" |
| `13-presentation-mode.png` | Presentation mode (View ▸ Presentation, `cmd:41`), chrome-free at the display's full 2880×1800, page fit to height on the light surround, with the comment marker still drawn |
| `14-add-comment-dialog.png` | The **Add Comment** dialog, live — the first modal in this port ever captured. Author and Comment fields, Add and Cancel. The author is prefilled from the Windows account name, so a capture must override it (see the rule below) |
| `15-shortcuts-sheet.png` | The Keyboard Shortcuts sheet (F1), live: generated from the menu table, class `SpdfWinShortcutsSheet`, dismissed with Escape |
| `16-about-box.png` | The About box, live: the resource icon at 64 px, version 26.9.2 (build 1), MuPDF 1.27.2, the host build, the licence line |

01 to 05 are **live windows** captured with `portable/win/screenshot-window.ps1`
(`PrintWindow` with `PW_RENDERFULLCONTENT`), not offscreen renders. 06 is one
page through the core (`--render-png`), the byte-for-byte comparison path. 07 is
the whole window composed with no window and no desktop (`--render-window-png
--chrome`): the frame `spdf_win_paint()` produces for the pixel cases, kept
because on a locked or non-compositing desktop it is the only way to look.

**08 to 16 are live too**, taken 2026-09-03 at HEAD `0fb7d8d92` on an UNLOCKED
workstation — the condition every earlier attempt at 11 to 16 lacked. 08 to 10
come from `screenshot-window.ps1`; 11 to 16 from `portable/win/drive-uia.ps1`,
which is new and exists because those six cannot be reached any other way: a
search with results needs the query TYPED, a comment needs a modal dialog
FILLED IN, and a modal dialog is not something `drive-window.ps1` can address —
it clicks client coordinates, and a dialog's controls are child windows this
repo does not lay out. 01 is deliberately NOT overwritten by 08: it is the only
picture in the repo of `--find` working on a windowed launch, which it no longer
does (`windows-native-observations.md` §10.2).

**What 11 to 16 close.** `windows-feature-matrix.md` gap 16, "modal windows
verified live", was the largest hole in this port's evidence and the reason four
DONE rows carried a caveat. The annotation dialog, the shortcuts sheet and the
About box are now shown rather than asserted. The Open and Save pickers and a
print job still are not.

## What is in them, and why each thing is worth seeing

Tab strip, toolbar, Chapters sidebar, page canvas and minimap — the macOS layout,
with every metric transcribed from `ShenzhenPDFMac.mm` and cited to its line.
Beyond the arrangement:

- **The chapter list is the document's real outline**, and it carries
  `Überblick mit Umlaut` and `第一章 CJK section`. That is not decoration: this
  machine's ANSI code page is 1252, and a narrow UTF-8 conversion mangles both
  silently. Seeing them render correctly is seeing `MultiByteToWideChar(CP_UTF8, …)`
  being used everywhere it must be.
- **The minimap thumbnails are real page renders**, produced on a worker pool and
  never on the paint path.
- **The search highlight keeps its colours in both themes.** Yellow fill, red
  active ring, identical in light and dark — because a highlight is a mark *on* a
  surface, not a surface, and has to read over white paper and over `#1E1E1E`
  alike. The reading theme changes around it and it does not move.
- **The scroller carries the search heat-map**, the same relationship macOS has.
- **Dark is a luma remap, not an inversion.** Light ink on dark paper with the
  page's own structure intact, and the window frame follows via
  `DWMWA_USE_IMMERSIVE_DARK_MODE`.

## Provenance, and one rule for adding to this directory

Both were opened from `portable/win/tests/fixtures/outline.pdf` — a repo fixture,
deliberately. **A screenshot of a real document shows its filename in the tab
strip, and a full path shows the user's home directory.** An earlier candidate
for this set was rejected for exactly that: it was the better picture, taken on
an 86-page scan at real scale, and its tab read
`C:\Users\<name>\Documents\…`. Use a fixture, or crop, or do not commit it.

**Two more ways a capture can carry the account name**, both found while taking
08 to 16 and neither about the tab strip:

- **The Add Comment dialog prefills the author from the Windows account.** The
  first take of 14 read `sagan`. Every capture of that dialog, and every
  Comments row underneath it, must have the author overridden first —
  `drive-uia.ps1 childtext:1101=Reviewer` is how 12 and 14 were made.
- **A document opened from a scratch directory still names that directory
  nowhere in the window, but the file must be a fixture anyway**, because
  annotations are written INTO the document: adding the comment for 12 grew
  `outline.pdf` from 6,449 to 7,264 bytes. 12 was taken on a COPY under
  `C:\spdf-build`, and the repo fixture was restored and re-checked against
  `make_outline_fixture.py`'s own output before anything was committed. Never
  annotate a fixture in place.

## Reproducing

```
portable\win\screenshot-window.ps1 -Exe <exe> -Pdf portable\win\tests\fixtures\outline.pdf ^
    -Out 01-window-light.png -Width 1500 -Height 950 -SettleMs 4000
```

The search shown in the live pictures was typed into the find field through
`drive-window.ps1`; the offscreen ones pass `--find fixture` (and `--find-regex`
when wanted) to `--render-window-png`. The `SPDF_FIND_QUERY` environment bridge
these pictures were first made with no longer exists.

**`--find` no longer reaches a windowed launch**, so 11 was typed rather than
passed (`windows-native-observations.md` §10.2 has the one-line cause). 11 to 16
are reproduced with `drive-uia.ps1`, always with a private `-StateDir`-style
`--state-dir` in `-AppArgs`:

```
portable\win\drive-uia.ps1 -Exe <exe> -OutDir <dir> ^
    -AppArgs @('--light','--state-dir','<scratch>','<repo>\portable\win\tests\fixtures\outline.pdf') ^
    -Steps @('size:1500x950','cmd:26','type:fixture','sleep:1500','shot-main:11-search-results-live')

portable\win\drive-uia.ps1 -Exe <exe> -OutDir <dir> ^
    -AppArgs @('--light','--state-dir','<scratch>','<COPY of outline.pdf>') ^
    -Steps @('size:1500x950','click:900,520','cmd:63','wait-dialog', ^
             'childtext:1101=Reviewer','childtext:1102=Check this heading against the outline.', ^
             'shot:14-add-comment-dialog','childclick:1103','sleep:5000','wait-main', ^
             'click:270,150','sleep:3000','shot-main:12-comments-sidebar')
```

Give the strip time after an annotation write: the minimap thumbnails
re-render, and a capture taken 1.5 s after Add shows them mid-render (the
fixture's red box missing from every thumbnail). Five seconds was enough here.
That is a transient, not a defect — the same window five seconds later matches
08's thumbnails.

**The workstation must be unlocked.** A locked session is not composited, so
`PrintWindow` returns black for a Direct2D client area and the capture looks
exactly like an app that painted nothing. `screenshot-window.ps1` detects this
and exits 68 rather than producing that picture; see
`windows-native-observations.md` §4.6, which exists because the false positive
was convincing enough to be believed once.
