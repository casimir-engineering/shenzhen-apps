# README comparison demonstration — 2026-10-12

Replaced the page-count example with a scripted comparison of two fictional
support plans: 24 versus 18 months, with repairs excluded from the longer plan.
The native chat shows citations to both documents and a pastel **24 months**
answer card labeled **Extended advisory · repairs excluded**, with **View evidence**.
The source page remains visible alongside the answer. The caption explicitly
identifies the conversation as scripted; this is a UI demonstration, not a new
model benchmark or a claim that the model produced this particular answer.

The README now leads with that image, document AI, native Markdown diagrams/math/
code, search and the map, Collection recovery, and groups. Detailed controls are
expandable; setup and engineering/platform information follow the feature tour.
The benchmark link and AI privacy/accuracy limitations remain accessible.

## Reproduction and verification

- Added `mac-ai-readme-probe` and a focused fictional fixture in
  `portable/mac/tests/SPDFMacAIReadmeProbe.mm`; reuses the production reader and
  chat/card components. The existing workspace probe entry point is conditional
  only for this reuse, and its page-count assertion now uses the actual fixture
  PDF count instead of assuming three pages. No runtime app code changed.
- Probe build/run exited 0 with zero failures: valid saved conversation reload,
  evidence button presence and exact source URL forwarding, source page count,
  usable reader layout and no visible windows. No provider requests or credentials.
- Visually inspected the native PNG and a browser preview rendered through GitHub's
  Markdown endpoint. All preview images loaded, sections appeared in the intended
  order, and there was no horizontal overflow. All local README link targets exist.
- File-size ratchet and `git diff --check` passed.
- The broader `mac-workspace-probe` exited 1 with 24 icon-contrast/native-click
  assertions. A separately compiled **unchanged HEAD** version also exited 1 with
  exactly the same 24 assertion messages and multiplicities. These are existing
  failures in this environment, not a passing suite; no extra failures were
  introduced by the fixture reuse. Logs remain at
  `/tmp/sz-readme-workspace-check.log` and
  `/tmp/sz-readme-probe-baseline-run.log`. The dedicated new probe log is
  `/tmp/sz-readme-comparison-build.log`.

This documentation update does not rebuild, replace or republish the released app.

## Concise README and website — 2026-10-12

- Replaced the long feature tour with a 66-line technical README (previously
  344 lines): capabilities, requirements, four examples, and links to detailed
  documentation. Removed metaphors, repeated explanations and expandable lists.
- Updated both website languages to lead with the comparison/card, followed by
  Markdown, search and groups. Disclosed OpenRouter requirements and document
  transmission; retained the benchmark link and scripted-demo caption.
- All four displayed screenshots include the complete native window frame.
  Offscreen AppKit omits active compositor-backed traffic-light fills, so the
  documentation-only capture helper draws those three fills as vectors at the
  native button coordinates. No app activation or user-window capture occurs.
- The refresh script preserves full windows and generates separate optimized
  website WebPs. Total generated site size: 247,069 bytes, including both languages.
- Native AI/card fixture and Collection fixture exited 0. The broader workspace
  probe still reports the same 24 baseline contrast/click assertion failures;
  exact message counts match the previously established unchanged-HEAD baseline.
- Website build/check, localization-key equality, README local-link validation,
  diff whitespace check and source-size ratchet passed. Browser review at desktop
  and 390px mobile widths covered both languages, all four loaded images, no
  horizontal overflow, and working FAQ expansion.

Only documentation, documentation fixtures and the static site changed. App code,
release binaries, launch behavior and updater configuration are unchanged.

## Plain-language presentation — 2026-10-12

Rewrote the website introduction, feature summaries and related README text to
state concrete tasks, local storage and account requirements. Free/open-source
status now leads; AI is explicitly optional and uses the user's OpenRouter
credits. Updated the Chinese copy and page metadata consistently. Website
build/check and whitespace checks passed; checked desktop and narrow layouts.

## Product focus — 2026-10-12

Aligned README and both website languages around fast reading, organization and
information retrieval from Collection as a local document library. The three
website feature summaries now follow those priorities; AI supports retrieval,
comparison and source verification. Static website and whitespace checks passed.
