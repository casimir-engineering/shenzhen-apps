# Independent sidebar review — native final pass

24 September 2026. **Beauty: 8.9/10. Usability: 8.9/10. Approve the bounded sidebar change.** These are fresh, separate grades. They do not inherit the old component approvals, certify live whole-app usability, or describe the mobile proposal.

The change addresses the user's balance complaint with better proportions and hierarchy: a quieter compact navigation stack, more room for actual group/version content, and a smaller History action area. It preserves the requested vertical icon-and-text modes and the existing state model. No unresolved major or medium issue remains in the inspected native states after the narrow History correction.

## Evidence boundary

I independently inspected the A/B/C whole-reader CSS captures in `evidence/`, production source and focused test assertions, and the final AppKit renders in `native/`. Native evidence includes true 176×296 Groups, minimum Chapters, 176pt hidden/active Groups, 240pt dark Groups, no-matches/filter-focus states, and final History minimum/dark/linked/empty/scrolled-actions states. The earlier `/tmp` History images used the old navigation and were not used to grade final navigation.

The CSS images establish the composition comparison. The AppKit images establish actual component fitting and rendering. Neither is a screenshot of the user's running reader; no native app was launched, quit or captured. Child CUA had no browser available; root supplied the browser captures. I inspected those files directly rather than claiming to operate root's browser.

Root reports the final 25-suite UI runner, including the date-width assertion, exited 0; four focused sidebar suites also pass. Root additionally reports the app built, signatures verified and distributed files matched by hash. These execution/build results are coordinator-reported; source assertions were read here, not independently re-executed. No live VoiceOver/trackpad session is claimed.

## What improved, with concrete evidence

- **Whole-reader balance:** A is the strongest comparison. The page remains dominant, the sidebar keeps its 240pt default, and selected mode versus current content use different visual weights. B creates an extra navigation column and spends 100pt more than the default; C moves mode access away from its task without recovering height.
- **Navigation:** five modes fall from 161pt to 139pt intrinsic height. 26pt targets and visible labels remain; the selected mode uses a neutral fill, while enabled labels remain readable rather than resembling disabled controls. The result is consistent in light and dark.
- **Groups:** the 42pt search-only header and 22pt counts footer replace the extra summary/header/help bands. 36pt group rows and 26pt document rows yield an 81pt list at the actual 176×296 minimum fixture: **two complete groups are visible**, compared with one group in the older, taller 220×340 fixture. Disclosure, visibility, search and footer stay within bounds.
- **Group state clarity:** the 176pt hidden/active fixture preserves both “Hidden · Active”; the count moves beside the name for this combined state. Long names truncate before the eye target. The current document retains its own accent and document icon. No-matches text makes the group-name search scope clear.
- **History:** the repeated heading and five-button tower are gone. Document context is compact, versions precede recovery, and the primary comparison plus Keep/Actions area is smaller. Save Copy, Compare Previous and Manage remain named menu destinations. Missing-source recovery is explicit, and scrolled minimum-height evidence shows its links and action controls reachable.
- **Narrow revision identity:** the first final candidate lost the latest date as “23 S…” at 176pt. This was a medium issue, not acceptable truncation. The corrected 56pt row now puts the full date on its own line, time plus Latest on the second, and reason/size on the third. The final minimum image shows **23 Sep 2026**, 08:00, Latest and Saved · 2 KB without losing identity. The dark render also fits. The correction respects the user's scrollbar preference.

## Separate grades

| Beauty dimension | Weight | Grade | Assessment |
|---|---:|---:|---|
| Whole-reader hierarchy | 40% | 9.0 | Page versus mode versus current-content hierarchy is substantially clearer. |
| Proportion and density | 30% | 8.6 | Useful rows replace overhead; permanent five-mode navigation still occupies a large part of 296pt. |
| Alignment and typography | 20% | 9.0 | Consistent gutters, readable enabled modes, compact metadata and corrected revision identity. |
| Light/dark coherence | 10% | 9.0 | Neutral mode selection and accented content remain distinct and readable. |
| **Beauty total** | **100%** | **8.9** | Rounded from 8.88. |

| Usability dimension | Weight | Grade | Assessment |
|---|---:|---:|---|
| Useful content and access to actions | 35% | 9.0 | Two minimum Groups rows; initial History revision visible; explicit recovery and labeled actions. |
| Narrow/short resilience | 25% | 8.8 | Real 176×296 evidence passes after the date correction. Scrolling remains necessary. |
| Scope and state clarity | 20% | 9.2 | Group-name scope, hidden/active/current distinctions and Latest/older identity remain visible. |
| Keyboard/accessibility/state preservation | 20% | 8.7 | Focused tests and unchanged persistence paths support preservation; live assistive-technology and trackpad behavior were not exercised here. |
| **Usability total** | **100%** | **8.9** | Rounded from 8.93. |

## Presentation closeout — resolved

Verified the corrected `design.md`: it now specifies the full date, time plus Latest, and reason/size on three lines within the 56pt row. The comparison labels History as native evidence and replaces its obsolete CSS scene with an explicit retirement notice and link to the native gallery. The gallery separates production-view renders from whole-reader CSS illustrations and explains why the old History scene was retired. Both minor presentation notes are resolved; grades remain unchanged.

## Limits and retained tradeoffs

Keeping all five vertical modes visible necessarily leaves a compact task viewport at 296pt. The result is usable and more balanced, not spacious. History still has an outer content scroller and a version-list scroller; the headless checks establish reachability, not subjective trackpad behavior. No claim is made that arbitrary long localized metadata, every accessibility setting or a live integrated reader has been visually exercised.

The design retains mode/width/visibility and Groups query/expansion/scroll state, chapter behavior and lazy loading rather than creating a new navigation model. Final build, YAML integration and broader regression results belong to the coordinator's verification. Further cosmetic score loops are not warranted by the inspected evidence; address a concrete new failure if one appears.
