# Interactive mobile design prototype

Open `prototype.html` from a local HTTP server. The page fills its viewport; the document’s showcase embeds it
at 390 × 844. Use `?scene=reader|epub|markdown|groups|documents|collection|history|storage|wheel|switcher|missing|consent`.
`?scene=older` shows a dated version and Return to latest. Add `&large=1` for the large-text variant. The fixture
starts fresh after reload. Nothing accesses device files, stores document bytes, or runs a native reader engine.

## Exercise the interactions

- Reader: Contents, Find, Switch and More open sheets. Organizer opens Groups. More exposes History, appearance,
  simulated export, missing-source recovery, and Collection consent.
- Tap Switch for the normal document list. Hold it for 220 ms for the wheel; slide through its center to arm,
  then to another document and release. Center, the current-document sector, outside release, pointer cancellation,
  and Escape cancel. Directions never reorder after selection. The large-text setting uses the list.
- A directly opened wheel scene supports pointer press/drag/release on the wheel. Its List & all groups button
  is the equivalent keyboard/tap route. The visual sectors are not substitutes for accessible buttons.
- Groups: filter group names, open a dedicated group document list, create a group, and open sample documents.
- Collection: filter PDF/EPUB/Markdown and search sample titles/snippets; “quiet” demonstrates text matching.
  Document menus expose History, Move and Pin.
- History: open older/latest, toggle Keep, or simulate exporting a separate copy. Native rendering, exact byte
  export and persistence remain specification requirements, not claims about these fixtures.
- Storage: Review cleanup exposes an explicit proposal; applying it changes illustrative accounting by 62 MiB.
  New-capture toggling preserves sample history. Sample storage figures are labeled throughout.
- Missing original: simulate a matching original or a rejected different file. No device locations are searched.
- Consent: Keep copies/Not now change fixture state. Nothing is captured before or after either choice.

## Validation boundary

Check screenshots at 390 × 844 and 360 × 800, plus landscape and large text. Inspect layout, scroll reachability,
button labels, focus trapping and Escape dismissal. Use browser pointer events for the hold/cancel flow. Native
TalkBack, URI permissions, engine gesture conflicts, frame timing and crash-safe storage need their separate native
gates. Do not count mock text or a painted page as successful PDF/EPUB engine validation.

JS syntax: `node --check` each `prototype*.js`. Each maintained source stays under 500 physical lines. Scripts
are split into data/helpers, screen rendering, sheets/wheel geometry, and interaction state. Styles are split into
base, reader, organizer, sheets, wheel, and adaptive rules. The prototype uses only local files and system fonts.

## Round-six state and accessibility fixtures

New scenes: `dark`, `longtitles`, `overflow` (seven group documents), `onealternative`, `stale` (a match in the
12 September saved revision), `recovery` (18 September Latest verified with a newer unverified capture), and
`unverified` (choice required before opening the only captured copy). All state is illustrative and resets on reload.

`large=1` now measures the normal computed font size of every meaningful UI element and applies exactly 2×.
It excludes simulated OS chrome and decorative thumbnails. Sheets and screen bodies scroll; the wheel becomes
a list. It is a browser text-scale fixture, not proof of native Dynamic Type or TalkBack. The default simulated
status/home areas reserve space for an Android gesture-navigation layout; real system insets and Back need device testing.

Find searches the actual sample reading DOM, reports no matches, highlights a selected occurrence, and offers
Return to its previous reading position. Collection text hits highlight the selected query in sample content and
Return restores the Collection query/filter/scroll. Global Search (magnifier beside Create group) searches sample
titles, group names and snippets; `col:` excludes groups. Newer source changes use the explicit stale fixture,
which keeps the old match in its dated saved version and offers Open latest. None of these claims a native index.

Round-six source validation includes syntax checks and eight pure fixture-search assertions. Earlier screenshot
and automated evidence in `prototype-evidence` describe the earlier rendering; fresh root-operated CUA evidence
is required for these accessibility and state corrections.

Final focused state regressions: `node prototype-state-tests.cjs` (18 assertions covering search, recovery and
explicit export identity). Root-operated CUA evidence and its scope are recorded in
`prototype-evidence/final/live-checks.md`; the final source identity is `source-hashes-final.json`.
Historical `prototype-test.cjs` output is not a replacement for those later UI checks.
