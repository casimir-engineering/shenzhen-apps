# Setup rewrite critique — loop 1

Date: 2026-10-10. This review covers the replacement four-step setup, not the
previous optional welcome page. The requested direction is direct copy, Full
Disk Access, Collection, AI connection/model, and independent default file types.

## Assessment

Beauty: **8.8/10**. Initial usability: **7.5/10**. After the targeted fixes below,
the headless/source assessment is **8.8/10 usability**, pending the host integration
and live popover checks described below. The earlier design's score does not
carry over to this new flow.

The four-step order is clear. Headings are direct, Continue/Back/Done remain in
stable locations, and the full-width rows are easy to scan. AI has browser-first
connection with a separate, initially hidden key field. The automatic upload and
account-credit disclosure is visible before completion, matching the requested
default-on behavior. Accessibility setup is absent. Done closes the wizard.

The default-width dark renders and 650×520 light renders are legible. There is
substantial empty space above/below short steps; removing the unused navigation
row's reserved height in wizard mode would tighten the composition without adding
decoration. The model-list and file-type controls retain native compact sizing.

## Findings and fixes performed

The parent explicitly reassigned this critic to implementation after the findings.
Therefore the fixes below are **self-verified, not an independent approval**.

1. **P1 fixed — invalid storage text lowered the budget.** A native probe proved
   `oops` emitted 0.1 GiB. Blank, malformed, negative, zero and non-finite input now
   leave the prior limit unchanged, restore its value, and show inline feedback.
   Valid positive input still saves. This prevents a typo from pruning history.
2. **P2 fixed — relocation and budget feedback stayed stale.** The probe showed
   neither Moving Collection nor a new location appeared after `updateState:`.
   Existing labels now refresh in place, preserving any active amount editor.
3. **P2 fixed — a query disguised catalogue failure/loading.** With a typed
   query and no catalogue, the picker showed No matching models even while loading
   or after a network error. The catalogue state now takes precedence; genuine
   filtering misses remain distinct.
4. **P2 fixed — opening a picker could change the model on Return.** An unfiltered
   list now selects the current model rather than the first alphabetical result.
5. **P3 fixed — empty file-type search had no feedback.** It now explains no
   matches and accepts dotted extensions such as `.pdf`.

## Remaining ranked work

1. **P2 — ensure Dynamic 80% matches persisted runtime behavior.** The interface
   displays a fixed 80%, but at review time choosing Dynamic emitted only the
   mode; the host only wrote 80 when `collectionDynamicPercent` was included.
   An existing different percentage could therefore disagree with the screen.
   The parent was asked to enforce the requested percentage on dynamic selection
   and setup migration, then verify an existing non-80 setting. This is a host
   integration issue, outside this critic's assigned implementation files.
2. **P2 verification — real popover and production state transitions.** Source and
   delegate tests cover filtering by name/provider, arrows, Return, Escape,
   loading/error rows and preservation of the current choice. They do not open
   the actual NSPopover. Parent should inspect it with long model names and test
   retry after failure, search focus, API-key reveal/Return, connection completion,
   file-type selection feedback and wizard resume/Done in the isolated app.
3. **P3 — accurate empty/collapsed controls.** The API-key row remains mounted after
   successful fallback-key connection until a section rebuild, though Disconnect
   becomes available. Hiding submitted key controls after connection would make
   success clearer. The first-step disabled Back is understandable but could be
   omitted. The extra Unlimited mode should be retained only if intended alongside
   the requested Dynamic/Static choices.
4. **P3 — verify format grouping semantics.** Production exposes sixteen formats;
   the standard wizard fixture renders only three fallback rows. The independent
   narrow probe used the full production format list and showed normal scrolling.
   Per-type buttons call separate actions, but Launch Services uses UTIs, so alias
   extensions can share an association. Avoid promising extension-level isolation
   beyond what the operating system supports.

## Evidence

- Read current UnifiedSettings, SearchablePicker, settings integration, model
  catalogue, default-format implementation and the relevant test source.
- Viewed `/tmp/sz-wizard-{0,1,2,3}.png`, plus independently generated
  `/tmp/sz-wizard-critic-narrow-{0,1,2,3}.png` in light appearance at 650×520.
  The narrow probe used all sixteen production format descriptions.
- `/tmp/sz-wizard-critic-probe.log` records the original invalid-input/stale-label
  defects and confirms its window was never visible. The same constructor and
  narrow-layout sequence finished; no alleged min-height layout hang reproduced.
- `make -C portable mac-unified-settings-tests` passes with exit 0 and zero
  failures after the fixes: `/tmp/sz-settings-critic-fixes.log`.
- The added regression checks compiled against pre-fix HEAD sources fail 14
  assertions with exit 1: `/tmp/sz-settings-critic-old-tests.log`. The subsequent
  picker-current-selection assertion was added after that comparison and passed
  in the final current-source run.
- File-size ratchet and diff whitespace checks pass. No user app was launched,
  quit, captured or otherwise manipulated by this agent.
