# Three additional tab directions

Scope: alternatives to the corrected compact Brave baseline, not another reader-layout redesign. Prepared with the installed [Interface Design skill](/Users/raph/.codex/skills/interface-design/SKILL.md). These are design proposals, not native-app changes or user-study results.

## Working brief

The reader is moving between specifications, notes and earlier versions in a large grouped workspace. They need to recognize the selected document and its group without the controls crowding the reading toolbar. The intended feel is a quiet Mac document workbench.

- **Domain:** document identity, group membership, active reading position, version provenance, workspace restoration, overflow inventory.
- **Color world:** paper white, graphite toolbar, ink text, lavender project markers, coral reference markers, teal working sets. Existing group colors retain meaning; this pass invents no new palette.
- **Signature:** the group’s color carries from its compact label through its visible document members, while the selected document remains recognizable by shape/weight as well as hue.
- **Rejected defaults:** favicons for every document → text-first titles; full-height tab blocks → smaller visible surfaces with bottom clearance; dim inactive text → the same readable foreground for every document.

## Shared craft contract

Intent: switch documents quickly while retaining group context. Hierarchy: the selected document leads through a stronger surface/perimeter and 600 weight. Palette: existing neutral reader surfaces plus semantic group color. Depth: flat surfaces and inset lines, with no floating shadows. Surfaces: no change to the reader, sidebar or toolbars. Typography: existing Mac system face, unchanged 12px/16px title text. Spacing: 28px visible tabs in a 44px titlebar; a 40px inner group with 6px vertical padding and 4px titlebar bottom inset keeps every control on the same centerline; unchanged 4px inter-tab gap; 8px extra after the group label. No file/favicons. Native buttons, keyboard focus, close controls and existing event handlers remain.

The extra bottom clearance is intentional: the tab group reads as part of the window chrome, while the row below is clearly the reader toolbar. The label-to-tab clearance makes the group control distinct without widening every tab gap.

## Alternatives

| ID / name | Selection | Group membership | Tradeoff |
|---|---|---|---|
| `index` — **Index** | Stronger flat fill and a short 2px underline inside the selected tab | Fine continuous rail below all members | Calmest and closest to a reading tool. The two line levels require their separate tab/group baselines to remain visible; less explicit containment than Tray. |
| `tray` — **Group tray** | Stronger same-hue surface with a quiet inset outline | A single softly tinted, rounded enclosure joins the group label and member tabs | **Recommended.** Most explicit membership without returning to tall pills. The enclosure adds more color than Index, especially with many expanded groups. |
| `outline` — **Outline** | Crisp 2px same-hue perimeter and stronger fill | Left color spine on group label plus a shared baseline | Strongest shape-based selection cue, useful when group hues are similar. More linework and a more technical tone than Tray. |

The corrected Brave baseline remains the default. Recommend Tray as the alternative to try first because this user's repeated concern has been recognizing which documents belong together, while still requiring breathing room and a clear current document.

## Integration and checks

Append `tab-options.css` after the existing fragment styles. Set `data-tab-design` on `#sz-workspace` to one of the three IDs; removing it restores the corrected baseline. No extra DOM or control behavior is needed. The parent task owns the browser comparison and visual validation; this document does not claim those checks have already happened.

Check all four choices with the same document/group state, in light and dark themes, at wide and compact widths. Confirm title size remains 12px, visible tab height is 28px, inter-tab gap is 4px, bottom clearance remains visible, and the close button does not collide with a truncated title. Verify selected identity with color desaturated as well as normally. The CSS deliberately leaves responsive visibility and group overflow logic untouched.
