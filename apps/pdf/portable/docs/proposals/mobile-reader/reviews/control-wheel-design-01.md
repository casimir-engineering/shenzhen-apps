# Independent adversarial review — controls-only marking menu

24 September 2026. New brief, new review. The previous document-switcher interpretation was rejected by the user; its scores do **not** validate this controls-only design. This is a review of the proposed protocol and desk study, before the new implementation and movement sequences are supplied. **No implementation score is assigned.**

Reviewed proposal: a dedicated 48dp Tools origin in reader chrome, immediate down → continuous slide → release, no preliminary tap or hold timer, page-origin gestures never adopted; six families Navigate / Zoom / View / Find / Notes / Document; family gate around 90dp, retreat below 62dp, origin cancellation below 24dp. The updated child hit band is **108–160dp**, up to eight children over the upper fan. The original 128–160dp proposal is superseded for this review.

Also read `control-wheel-comparables.md` and the actual desktop control inventory in `docs/features.md`. Reader controls are actions affecting the current document; document lists, Groups, Collection and library/global search remain outside the wheel.

## What is directionally sound

The dedicated origin is a strong answer to the page-gesture conflict. Requiring initial down inside it, with no later adoption of page contacts, gives pan, pinch, text selection and links a clean ownership rule. Showing categories immediately avoids recreating the rejected hold-to-open interaction. Replacing the family layer with a broad child fan is more plausible than cramming every command into nested narrow wedges. A conventional accessible command list is already correctly described as an equivalent route, not a prerequisite for ordinary one-contact use.

The comparable study is appropriately cautious: it distinguishes a circular appearance from a continuous-contact protocol and does not claim that every referenced product implements the proposed cancellation rules. Its provisional geometry and family inventory now differ from the current proposal, however; those must not both appear canonical.

## Blocker to declaring the new brief satisfied

### B1 — “All controls in one movement” needs an explicit completion contract

A completed Fit width action and opening a Find panel are not the same outcome. A page-number keyboard cannot be entered by a directional release; placing a comment on the document cannot be accomplished by releasing over a menu sector. Calling every leaf a “command” must not conceal this difference.

**Required before the study claims success:** inventory each leaf with its release result, using these concrete categories:

| Action type | What the continuous contact actually finishes | What remains |
|---|---|---|
| Discrete action: fit width, rotate, next match, theme preset | Apply exactly that action on valid release | Nothing beyond observing the result |
| Parameter control: exact zoom, page number, font size | Either select a value during this same contact, or open a specifically named editor | State explicitly if a second interaction is required |
| Text/placement action: Find query, text comment, highlight without a selection | Open the appropriate input or placement mode on release | Text entry, page selection/placement and confirmation are subsequent work |
| Tool mode: select text, annotation tool | Activate the named mode on release | Tool use is a later page interaction, with a visible exit |

Do not describe “opens Zoom…” as “sets zoom in one movement.” If the user expects continuous zoom adjustment or page scrubbing, those need their own same-contact parameter lane design, with pending value preview and release-to-commit. They cannot be silently relegated to a later roadmap while the study claims all controls satisfy the stronger interpretation. Explicitly delimit the unavoidable text/placement cases instead of promising impossible text entry by flick.

## Major findings / decisions

### M1 — Family locking, child arming and correction are underspecified

Crossing radius 90 replaces one angular map with another only 18dp before the child band starts. A straight rapid stroke can cross both thresholds between two delivered events. A curved correction can also cross a newly mapped child before the user has understood the layer transition. The design needs to support expert speed without depending on a timer or accidentally committing whatever appears beneath the finger.

**Specify:** whether the first outward crossing locks a family; exact angular boundary/hysteresis rules; how coalesced or sparse movement samples determine that crossing; whether a straight continuation intentionally selects a child aligned with that family; and what release in each region does. Freeze branch, layout and enabled-command identities for the contact. A family release must cancel, not execute an arbitrary default child. After inward retreat below 62, remove the child candidate before reevaluating families. After origin cancellation, say whether the gesture is terminal until lift or can be rearmed; do not allow accidental later release to revive an old command.

The next sequence must show a hard case such as far-left family → far-right child, then retreat → different family, while the same contact stays down. The ordinary straight-path demo alone does not test the remapping cost.

### M2 — Origin choice and actual hit regions determine whether the fan fits

The updated geometry is arithmetically plausible. At a 134dp midpoint, a 22.5° child sector has about **26.1dp perpendicular clearance to each angular edge**; the 108–160dp band gives **26dp radial clearance**. A 48dp-diameter hit circle centered there can fit. This resolves the old 32dp-depth objection. It is not evidence of one-thumb accuracy or readable eight-item labels.

The claimed 20dp side clearance in a 360dp viewport assumes a fixed, centered origin. If the menu instead uses the actual down coordinate anywhere inside a 48dp trigger, its center can shift roughly 24dp horizontally and clip an edge. A corner down also lies outside a 24dp-radius cancel circle measured from the control center.

**Specify:** fixed control-center versus contact-down origin; screen-coordinate transforms; dp/point units; allowed safe width; label and focus-preview bounds as well as hit bounds. Hit regions must follow displayed geometry. Do not shift the fan after down. If a smaller viewport, keyboard, landscape, large text or inset makes the layout impossible, name the alternative and its input sequence; silently shrinking targets or adding a preliminary tap breaks the contract. The separately accessible list remains valid, but should not disguise a broken ordinary-touch layout.

### M3 — Prove command coverage with a finite inventory, not six attractive labels

Six families × eight children gives a capacity ceiling, not proof of completeness. The desktop reader has enough controls that omissions and vague catch-alls are likely. Use the following audit matrix; explicitly mark each operation supported now, deliberately later, inapplicable, or covered by another named command. This is a coverage check, not an instruction to ship every desktop feature on mobile.

| Family | Operations that need an explicit disposition |
|---|---|
| Navigate | Contents/outline, page entry/scrub, next/previous, first/last, return from link/search detour, bookmarks or locations |
| Zoom | In/out, fit width/page/height, actual size, custom percentage; define fit behavior versus PDF display density |
| View | Rotation both directions, continuous/page mode if supported, reading theme, preserve image colors, hide/show chrome, presentation; EPUB/Markdown typography alternatives |
| Find | New/edit current-document query, next/previous result, match overview/count, clear/return, supported search options; never global/library search |
| Notes | Copy selection/page text, selection mode, bookmarks if placed here, existing notes list, highlight/comment/edit/delete or their explicit later status; annotations require write/read-only capability |
| Document | Properties, save/export/share/print of this document, current-document history if included; no document switcher or organizer destinations |

Avoid ambiguous overlap: for example, put Bookmarks in exactly one family, and distinguish page rotation from rotation lock and reader theme from exported colors. Keep family/leaf locations stable. Disabled commands should not cause the remaining actions to shift directions. A format/capability table is necessary for PDF scans, locked/read-only revisions, reflowable EPUB and Markdown. Do not put an unsupported Notes feature in the prototype as though it works merely to fill six families.

### M4 — Native arbitration must match the clean start-origin rule

The proposal is good only if the native engine and menu implement it literally. A parent pan recognizer that waits for movement and then steals a page contact would reintroduce the conflict. A JS-only overlay that cannot claim the initiating Tools down consistently over a native reader surface would also fail the protocol.

**Required contract:** Tools owns its initial down through up/cancel; page-owned contacts stay page-owned even across Tools; a second contact during Tools cancels the menu without synthesizing a page pinch; pointer cancellation, lost ownership, app interruption, rotation/resize and document-generation change cancel pending action. Accept at most one terminal commit for the original pointer/generation. A stale or newly disabled command must not execute on another document after a source/open transition.

Use current system insets, not a screenshot's home-bar estimate. Android says bottom home/quick-switch gestures cannot be opted out of like side Back gestures and provides mandatory gesture insets. Keep the Tools hit target wholly above that region; request no exclusion to rescue the design. Android also documents that late parent interception sends `ACTION_CANCEL` to the child, which is why late adoption is inappropriate here. [Android gesture navigation](https://developer.android.com/develop/ui/views/touch-and-input/gestures/gesturenav), [Android touch interception](https://developer.android.com/develop/ui/views/touch-and-input/gestures/viewgroup).

The iPhone phase needs the same tested ownership policy against its actual recognizer hierarchy and safe regions. Merely citing UIKit or sharing React state does not certify it. No native OS gesture validation has been performed in this review.

## Medium findings

### D1 — Continuous parameters need a distinct control grammar

If a same-contact numeric lane is chosen, define its coordinate system after leaf selection, gain, bounds, detents, displayed pending value, return/back route and commit/cancel behavior. Do not map family angle, child angle and numeric value simultaneously. Zoom should preserve a defined anchor; page scrubbing must specify whether release commits a previewed page or opens a page entry field. No live document mutation should occur while the user is merely choosing a family/leaf. A canceled value adjustment must restore the exact old value and position.

### D2 — The alternative list needs an actual entry and semantic parity

The comparable study proposes the right alternative; now show its actual reachable control. A touch down/up on Tools currently cancels, so an ordinary button activation cannot be assumed to open that list. Expose a labeled standard Reader controls action for TalkBack, keyboard and switch access, or an explicit accessibility activation on Tools. Its items must invoke the same command IDs and checked/disabled states. The gesture route must remain immediate and require no preliminary tap. Verify label visibility outside the thumb, selection by more than color, and command feedback after release.

Android recommends at least 48×48dp touch/focus targets, with semantics describing the action's result. The radial hit arithmetic above does not substitute for the accessible list or native testing. [Android accessibility guidance](https://developer.android.com/guide/topics/ui/accessibility/apps).

### D3 — Maintain one canonical geometry and family map

`control-wheel-comparables.md` currently illustrates four children at radius 164 and a category gate around 132, and gives a different family set. The current candidate is eight children, 108–160 hit band and gate 90. Both can be legitimate alternatives in a study, but only one may be labeled the actual prototype contract. Mark the other as rejected/alternative with its tradeoff. Similarly, the old document-switching sections of `spec.md` are not evidence for this corrected brief and must be superseded before a final proposal is presented.

## Minimal evidence requested next

1. Actual down → family crossing → child selection → up frames, with one continuous pointer trace and unchanged reader state until release. Include immediate fast movement; no hold timer or preliminary tap.
2. Difficult opposite-side child path, retreat to another family, origin cancel, outside release and interrupted/multitouch cancellation. Log zero or one committed command as appropriate.
3. One discrete action, one toggle, one parameter path and one text/placement action, with their different completion boundaries labeled honestly.
4. Page scroll crossing Tools, page pinch, text-selection long-press and OS-origin input: no menu activation or late takeover. Browser simulations prove the model only; native reader-surface arbitration remains a separate gate.
5. Complete finite command map with stable positions/capabilities, plus 360dp, small-height, left/right-hand and large-text layout evidence. Show the equivalent list entry and focus behavior.

The core proposal is worth prototyping. Its greatest risk is not the circle styling; it is quietly changing the meaning of a moving finger at the family transition, or declaring all controls complete when many leaves only open another interface. Resolve those explicitly before evaluating the new implementation.
