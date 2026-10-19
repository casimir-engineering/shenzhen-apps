# Independent review — visual round 6

Reviewed 2026-09-24: frozen round-six prototype source, `prototype-evidence/final/source-hashes.json`, fresh rendered images in that folder, and root-operated live CUA observations. This critic still has no browser surface in CUA; screenshots were inspected directly and live interactions are attributed to root. The images and source are design-prototype evidence, not native PDF/EPUB, Android accessibility, durable storage or performance evidence.

## Score: 9.14 / 10

| Dimension | Weight | Score | Weighted contribution |
|---|---:|---:|---:|
| Product clarity | 25% | 9.2 | 2.30 |
| Technical feasibility expressed by interactions | 25% | 9.2 | 2.30 |
| AI development and reproducible feedback | 20% | 9.5 | 1.90 |
| Storage/reliability UX and truthful state | 20% | 9.0 | 1.80 |
| Accessibility and responsive recovery | 10% | 8.4 | 0.84 |
| **Total** | **100%** | | **9.14** |

## Resolved and improved

- **V1 resolved:** root read EPUB, inspected another PDF's Collection menu, dismissed it, and returned to the same EPUB. EPUB Contents and History now show EPUB context. Source separates menu target from active reader.
- **V2 substantially resolved:** the new fixture scales meaningful text to a measured 2×. Inspected 360×800 consent, switcher, Groups, History and Storage screenshots show readable wrapping and scrolling. Root reached/clicked both consent choices, confirmed 28px buttons from a 14px baseline, reached the last History action and Storage cleanup controls. Long titles, overflow and one-alternative list images are provided. Dark evidence exposes the remaining issue below.
- **V3 resolved:** root verified Contents/Escape restores Contents; another document's menu restores that menu; Groups Create/Escape restores Create; Storage cleanup Cancel restores its invoker. Source retains invoker identity.
- **V4 resolved for the modeled sample:** Find has a real unmatched state, “light” returns two results, the second opens a visible sample-text highlight, and Return clears the detour. Global search is reachable and returns two “quiet” results. Collection counts/highlights derive from the query. Stale-match evidence visibly preserves the 12 September revision and offers Return/Open latest.
- **V5 substantially resolved:** the inspected stale screen and root's direct reading/export test agree on 12 September across header, footer and export. A separate History-row export path remains wrong below.
- Root's fresh 412px wheel interaction armed via center, selected the northeast alternative and opened EPUB. Prior supplied portrait/landscape evidence establishes the intended wheel geometry; native touch remains a future gate.

The corrected prototype now demonstrates the important state transitions instead of only describing them. The improved score is warranted, but three concrete defects prevent visual acceptance.

## Major — V6: dark theme makes primary navigation nearly invisible

**Evidence:** `final/dark.png`; `prototype-adaptive.css` and inherited base styles.

The reader document is visible, but the header title, Organizer control, status foreground and Contents/Find/More tools are extremely dark against dark backgrounds. The subtitle/dek is also much less legible than the body. The dark theme changes `--ink` inside `.dark` without setting the container foreground, so the already-computed body color remains inherited by many controls.

**Required change:** set the actual dark container foreground and audit hard-coded secondary text and control colors. Inspect dark Reader, organizer, sheets and wheel/list; a single body-paragraph color fix is insufficient. Provide fresh screenshots showing readable navigation, primary labels and meaningful secondary text, and check contrast for those tokens. No theme should hide the escape/navigation path.

## Medium findings

### V7 — Return from unverified capture does not return to the verified copy

Root confirmed: recovery → explicitly open 24 September unverified capture → Return to latest still shows the 24 September unverified capture. Source clears `older` but leaves `unverified` and its date unchanged. This is a failure of the recovery interaction added to demonstrate the accepted text contract.

**Required change:** when the original is missing, expose Return to latest verified and resolve it to 18 September in this fixture. Clear unverified state while preserving original-unavailable state and dated saved-copy labels. When no verified recovery exists, do not present a false return-to-verified action. Verify both recovery cases, not just their initial sheets.

### V8 — Export from a History row exports the current reader's identity

Root confirmed that Save a copy on the 18 September row opens a dialog saying Current readable version. The row action lacks a revision target; the dialog infers it from active reading state. Direct export after first opening an older revision works, but that does not validate the row action.

**Required change:** pass the row's explicit document/revision identity to export and derive the dialog from that identity. Do not change the active reader merely to select an export target. Verify the 18 September row while the latest is active, and direct export while reading 12 September.

## Scope and next step

No further broad visual redesign is needed. Preserve the calm layouts, readable reflow, practical list density and truthful simulation labeling. Fix these three finite paths, capture updated dark/recovery/export evidence and run one focused regression round. Text remains accepted at **9.57/10**. Visual phase remains open. **Round count: 6 of 8.**
