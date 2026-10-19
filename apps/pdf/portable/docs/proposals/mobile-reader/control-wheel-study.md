# The reader controls wheel

**Touch Tools. Slide to a reader command. Release once.**

Revised UX study · 24 September 2026. The earlier document-switching wheel was a misinterpretation of the brief. This design replaces it. Groups and document switching stay in the organizer; the wheel contains controls for the current document only. The earlier 9.57 scores do not validate this new design.

## 1. What this study establishes

This is comparative research from primary manuals, an interaction design, and a browser walkthrough with reproducible gesture scenarios. It is not a participant study or proof of Android/iPhone gesture compatibility. Below, **documented** describes a source; **proposed** describes our design; **observed** is reserved for recorded prototype checks. Native-engine and physical-thumb tests have their own acceptance gates.

The deliverable includes competing trigger designs, the full control map, gesture ownership, success/cancel sequences, error states, Android/iPhone placement rules, an interactive prototype, and a real-device study protocol. A picture of an open wheel alone cannot establish whether the gesture works.

## 2. What existing interfaces teach us

The detailed [comparative study](control-wheel-comparables.md) records each source, input device and evidence limitation. These are useful precedents for different parts of the problem:

| Reference | Documented sequence | Borrow | Do not copy blindly |
|---|---|---|---|
| Procreate QuickMenu, iPad | Configured Touch → keep contact → drag toward a function → lift to select | One contact, release-to-select, stable positions | Its canvas Touch shortcut can assume Pencil drawing; our page needs finger scrolling. [Handbook](https://help.procreate.com/procreate/handbook/interface-gestures/quickmenu) |
| Sketchbook Pro Lagoon, desktop | Press a category control → move to highlighted tool → release; expert flicks can precede visible icons | A dedicated origin and a learnable directional path | Desktop stylus/mouse evidence is not phone-thumb evidence. [Manual](https://help.sketchbook.com/docs/basic-ui-elements) |
| Concepts Tool Wheel | Tap an outer tool; inner settings expose parameters | Separate tool selection from values; bounded tool inventory | The manual does not establish same-contact release selection. [Workspace](https://concepts.app/en/manual/workspace) |
| Samsung Air command | Pen removal/hover-button or floating entry → choose a command | Invocation separated from ordinary content input | A pen-dependent or invoke-then-tap interaction does not meet our default finger brief. [Guide](https://www.samsung.com/us/support/answer/ANS10002892/) |
| Acrobat / PDF Expert | Page scrolling, zooming, text selection, page navigation and search already occupy touch input | Preserve established reading gestures | Do not repurpose page long-press, double-tap or pinch for the wheel. [Acrobat navigation](https://www.adobe.com/devnet-docs/acrobat/android/en/navigatesearch.html), [PDF Expert reading](https://pdfexpert.com/ios/how-to-view-pdf) |

These references support a **marking menu**, not the assumption that every circular menu is a marking menu. Classic research describes hierarchical directional strokes and correction through inward motion. Its findings are not a phone performance guarantee. Google's M3 research also reports practical adoption problems for traditional marking menus; shape, learning and screen space need testing, not an automatic “radial is faster” claim. [Kurtenbach & Buxton](https://www.billbuxton.com/MMExpert.html), [Google M3 research](https://research.google/pubs/m3-gesture-menu-design-and-experimental-analyses-of-marking-menus-for-touchscreen-mobile-interaction/).

## 3. Choose the origin before drawing the wheel

| Candidate | Document conflict | System conflict | Decision |
|---|---|---|---|
| Long-press anywhere on a page | Competes with selection, links, annotations; adds a hold | None inherently | Reject |
| Drag from a screen edge | Competes with page turns/panning near edges | Android Back/Home; iPhone navigation and Home | Reject |
| Two-finger gesture | Competes with pinch/pan and accessibility | Depends on platform/accessibility mode | Reject as default |
| Invisible page hot zone | User cannot distinguish scroll from commands | Can extend into edges | Reject |
| Floating puck over page text | Explicit, but obscures content and steals that part of the page | Avoidable with insets | Keep only as a future tested option |
| **Visible Tools origin in reserved reading chrome** | Page viewport ends above its strip | Insets keep the origin away from system areas | **Prototype this** |

Use a labeled, at least 48 dp/pt **Tools** origin in a small bottom control strip. It stays visible when secondary chrome hides, so there is no preliminary “show controls” tap. The reader reserves that strip; the last line/page can scroll above it. A separate standard **Controls list** button exposes the same commands for keyboard, switch access and screen readers. Tapping that button is an alternative, never a prerequisite for the continuous gesture.

The tradeoff is explicit: a small amount of permanent chrome buys predictable gesture ownership. An invisible activation zone would save pixels by making ordinary document input ambiguous.

## 4. One contact, two directional stages

The selected candidate is an **upward fan anchored to Tools**, not a full circle moved above the thumb. A full bottom-origin circle wastes its lower half near system navigation. A relocated center adds a travel corridor before selection. Neither is needed here.

1. **Down on Tools:** show the six reader-control families immediately. No mandatory hold, first tap, haptic delay or timer unlock. The coordinate origin is the fixed center of the Tools control, not the exact down point within its hit target.
2. **Slide through a family:** crossing its gate locks the family. Only that family's commands expand across the entire upper fan. We do not squeeze several children into each tiny parent wedge.
3. **Continue into a command:** the same finger can bend toward a broad leaf target. A label above the thumb says the exact action and eligibility. Preview its selection; do not change the document yet.
4. **Release over an enabled command:** execute it once. The wheel disappears. A reversible view action shows the result immediately; the active document identity does not change.

For a practiced user this is one continuous two-leg slide, not two separate swipes. There is no claim that every command is a straight-line flick. The novice follows labels along exactly the same route. The family/command layout is frozen for the contact; no recency ranking, reordering, mirrored layout change or capability refresh occurs under the finger.

**Correction:** retreat into the inner family zone to choose a different branch while keeping contact. **Cancel:** return to the origin after leaving it (terminal until lift, even if the finger moves outward again), release in a gap/outside the permitted fan, lose contact ownership, receive a system cancellation, rotate/change layout, background the app, or add another finger. A cancelled gesture makes no document change. No command fires merely because the finger crossed its tile.

### Prototype geometry, not a proven ergonomic optimum

For a 360 CSS-pixel portrait fixture: origin at the center of the bottom Tools control; six 30° family directions over the upper semicircle; family lock radius 90; branch retreat radius 62; center cancellation radius 24; child band 108–160; up to eight child directions at 22.5° spacing. Use radius 134 for child labels. A 48-unit circular target can fit within this band/sector geometry, but thumb occlusion, font size and movement errors still need measurement.

This is the canonical candidate; the comparative research's earlier four-child sketches are exploratory. Eight is a ceiling for full reader coverage, not a reason to fill every format with unavailable tools. Disabled slots retain their location and explain why. A finger starting at the edge of Tools must not shift the fan toward a screen edge. Hit testing follows the rendered, frozen geometry; round corners and shadows do not define hit regions.

Family locking uses the **first outward segment intersection** with radius 90, rather than the latest event's endpoint. A sparse event can cross both family and child bands; it must evaluate both in the same update. A straight continuation intentionally selects the aligned child. Angles are partitioned into half-open sectors from left to right; an exact internal boundary belongs to its right-hand sector. There is no angular hysteresis in this candidate. A locked family stays locked while traversing children outside radius 62. An inward segment crossing that radius unlocks it; a later outward crossing of radius 90 on the same sparse segment can lock a different family. Thus a cross-fan correction that should retain its family must follow an arc outside the retreat zone, not cut through it. This prevents event frequency from choosing a different family, but boundary jitter and the cost of opposite-side corrections remain usability tests.

Actual layout uses available safe width/height, not a hard-coded 20-pixel universal exclusion strip. The browser fixture switches explicitly to its readable Controls list below 360 CSS pixels width, with less than 245 pixels from content-header bottom to Tools center, or in its 200% text scenario. The rest-state notice says the continuous fan is unavailable, and Tools changes to List. This is a disclosed limitation, not the same gesture under another label. Native release cannot silently claim that a smaller fan is equally usable. Left/right preferences may choose a prevalidated layout at rest; they never mirror the wheel during a gesture.

## 5. Every reader control has a home

This is the proposed command inventory, grounded in the desktop reader's page, zoom, Find, comment and document menus. It is a route map, not a promise that every desktop operation is already implemented on mobile. No Open document, Switch document, Groups, Collection management, account, app settings or library search belongs here.

| Family | Stable command routes | Result of release |
|---|---|---|
| **Navigate** | Previous page, Next page, First page, Last page, Page entry/scrub, Contents, Page favorites, Return to prior location | Direct page commands move immediately; outline/favorites/page entry opens the relevant reader control |
| **Zoom** | Fit width, Fit page, Fit height, Adjust zoom, Zoom in, Zoom out, 150%, Actual size | Fits/presets/steps apply immediately; continue beyond Adjust for a same-contact value rail, or release on it for numeric entry; pinch stays available on the page |
| **View** | Continuous, Page-by-page, Rotate left, Rotate right, Night, Light, Focus, Keep awake | Reversible view setting applies immediately; rotation changes viewing orientation, not source bytes |
| **Find** | Find text, Next match, Previous match, Regex, Match case, Copy selection, Translate selection, Search selected text on web | Match navigation/toggles act immediately; Find focuses a query editor; external/translation actions are explicit and never background uploads |
| **Notes** | Favorite page, Add comment, Comments, Edit comment, Delete comment, Undo, Redo, Highlight | Contextual comment actions require an eligible selection/comment. Destructive deletion opens confirmation; annotation tooling is a capability-gated later delivery |
| **Document** | History, Save a copy, Share, Print, Copy page image, Copy page PDF, OCR, Properties | Opens the current document's relevant tool or system sheet. Never navigates to another document/group |

PDF gets page/zoom/rotation semantics. EPUB and Markdown retain these family locations but use format-appropriate reading controls—e.g. text size/reflow options instead of unsupported PDF rotation/copy-page operations. Comments disappear from Markdown capability routes; absence does not shift targets during an active gesture. Read-only versions cannot acquire editing actions. OCR, annotation editing and full translation remain explicit implementation gates rather than fake working buttons.

### Coverage and capability audit

The desktop inventory was checked against `portable/mac/ShenzhenPDFMac.mm` (page/zoom/view menus, Find, comments, favorites and file actions) and `portable/mac/SPDFMacContextMenuIntegration.mm` (selection, copy-page and document actions). The prototype's 48 slots are routes, not a claim that 48 native tools have shipped.

- **Find result count, overview, clear and return:** belong to the Find editor/results control opened by Find text; next/previous have direct routes. Text selection remains standard page long-press; Copy selection acts on that selection.
- **Minimap / page overview:** mobile page navigation is covered by Page scrub and Contents. A desktop minimap is not duplicated as a seventh family. **Presentation / hide chrome:** View → Focus controls reader chrome. It does not claim external-display presentation support.
- **Image colors:** reader themes preserve image colors by default. Theme changes affect viewing, not exported source bytes; advanced per-image transformations are outside this mobile v1.
- **Favorites:** Navigate → Favorites opens the location list; Notes → Favorite page toggles the current location. These are distinct list and mutation actions.
- **Typography:** EPUB/Markdown use text size, line spacing and reflow controls in the Zoom/View families; PDF percentage/rotation slots become labeled format alternatives at rest. A per-format map must be frozen before native delivery. No changing slots during contact.

| Source condition | Available routes | Disabled / replaced routes |
|---|---|---|
| Unlocked text PDF | Page, fit, view, Find and selection; document tools according to permissions | Annotation editing and OCR remain later implementation gates |
| Scanned PDF | Page, fit, view, save/share/print where permitted | Text search/selection explain “No text layer”; OCR is a later gate, not a working browser button |
| Password-locked PDF | Unlock first through an ordinary secure prompt | Reading controls disabled until unlock; no wheel workaround for access rights |
| Read-only historical PDF | Navigation, view, Find, History, permitted export/copy | Add/edit/delete annotations unavailable; no source-writing action |
| EPUB | Chapters, semantic progress, reflow/typography, Find, favorites and document metadata/history | PDF rotation/page-copy replaced or unavailable; no fabricated PDF page numbers |
| Markdown | Headings, semantic location, typography, Find, favorites and document metadata/history | Comment actions absent; PDF-specific operations unavailable |

The live browser fixture is an unlocked text PDF sample. It labels engine/system-sheet placeholders and does not simulate encrypted PDFs, real annotation storage or EPUB reflow. Disabled selection tools explain the missing selection; placeholder panels are visibly identified as prototype routes.

**What “one slide” does and does not mean:** Fit width, Night, Next match and other discrete commands complete on that release. Find opens its focused field; entering arbitrary text cannot be encoded by the same slide. A comment still needs content/placement, and a system share/print/save sheet still needs its destination. Those are the task's inputs, not extra taps to select the command. Parameter scrubbing is evaluated separately below; do not relabel a panel-opening gesture as a completed zoom adjustment.

### Continuous values deserve a separate treatment

Keep native pinch as the primary continuous zoom gesture and the ordinary document scrubber as a page-navigation affordance. The prototype additionally models a same-contact **outward continuation rail** for Adjust zoom and Page scrub. Continue through the central command and outward across radius 172 without lifting. This locks the parameter; horizontal movement previews a value. Release commits that value once. Releasing over the ordinary command band instead opens numeric entry, explicitly a different route.

The entry value is the current value, with no jump on entering the rail. From the entry x coordinate, movement toward either safe endpoint linearly maps the remaining distance to that value bound, quantized to 5% zoom or one page. The browser fixture uses 50–200% and pages 1–48; these are demonstration bounds, not mobile engine limits. The fixed rail endpoints are 20 CSS pixels from each fixture edge. Native endpoints must derive from actual safe bounds. Release is valid only inside those endpoints and within 44 units vertically of entry. Returning to the hub cancels; releasing outside the rail cancels. Values remain previews until release, so cancellation preserves zoom, page and location exactly. The prototype does not mutate the document while choosing.

This is one contact with three movement phases, not a second tap. It adds motor complexity: device testing must compare it with pinch and the ordinary page scrubber before adopting it. The zoom anchor should be the viewport's current center; native testing must verify it preserves that document point. Numeric entry remains the precision alternative.

## 6. Gesture ownership: the page and the OS keep their gestures

Ownership is decided by the **initial down**, not by where the finger eventually moves. The wheel recognizer attaches only to Tools; it does not install a full-page long-press detector. The ordinary page renderer gets contacts that start on the page, without waiting for the wheel to fail.

| Starting contact / event | Owner and expected outcome | Wheel rule |
|---|---|---|
| Page drag / fling | Scroll or pan the document, including crossing the bottom strip | Never adopt the contact midway |
| Page pinch / double-tap | Renderer zoom behavior | No wheel invocation or global preventDefault |
| Text long-press / selection handles / links | Renderer selection/link behavior | No hold shortcut on content |
| Android left/right edge swipe | System Back / predictive Back | No exclusion rectangles to make the wheel win |
| Bottom system navigation area | Home / task switching | No launcher, slider endpoint or command target there |
| iPhone edge navigation / Home | Platform navigation recognizers and Home | No system-gesture deferral to rescue the wheel |
| Tools down → slide | Wheel owns this contact through release/cancel | Exactly one eligible command at most |
| Second finger during Tools gesture | Cancel safely; wait for fresh contacts | Do not synthesize a half-started pinch into the renderer |
| OS cancellation, rotation, interruption | Roll back preview and dismiss | Never commit on cancel/lost pointer capture |

Android documents Back from either side edge and non-overridable mandatory gesture regions. Its layout guidance says interactive targets should avoid system insets. Use current window/system/mandatory gesture insets and display cutouts; re-evaluate at rest after rotation, navigation-mode changes, keyboard and multi-window changes. This reader should not request exclusion rectangles for its wheel. [Android gesture compatibility](https://developer.android.com/develop/ui/views/touch-and-input/gestures/gesturenav), [edge-to-edge guidance](https://developer.android.com/design/ui/mobile/guides/layout-and-content/edge-to-edge).

Apple recommends custom gestures avoid system conflicts and retain standard alternatives. Safe-area layout provides a baseline for unobscured placement; it is not a universal map of every recognizer's activation area. Keep the launcher in app chrome, preserve the navigation controller's edge gesture, and honor cancellation. Do not enable preferred system-gesture deferral. [Apple gestures](https://developer.apple.com/design/human-interface-guidelines/gestures), [safeAreaInsets](https://developer.apple.com/documentation/uikit/uiview/safeareainsets).

A browser cannot exercise Android predictive Back, iPhone Home, hardware touch arbitration or a native PDF surface. The prototype demonstrates pointer ownership and declared reserved zones, while those OS claims remain native acceptance tests.

## 7. Implement the interaction as a small contract

Use one pure state machine: `idle → families → commands → optional parameter → commit/cancel → idle`. Store the fixed control center, bounds, command capability snapshot, document/revision ID and contact ID at down. Layout changes cancel rather than move targets. A reducer returns a candidate command; only a valid up creates one command intent. Each intent has a generation token, and stale-document intents are rejected.

Native adapters use the existing reader contracts for commands. Keep gesture tracking and highlighting off a busy JavaScript thread; do not message the PDF engine on every hover. A mode preview is separate from document mutation. Pointer capture belongs to the Tools-origin interaction, and loss of capture cancels. A release outside valid targets has no action. Page-origin contacts never acquire wheel capture. The visual overlay must not become a transparent full-screen hit target before invocation.

The browser prototype and native state machine should run the same trace fixtures: down/move/up, sparse coalesced moves, center retreat, off-fan release, second finger, renderer generation change, rotation and interruption. A single final screenshot does not cover those transitions.

## 8. Validation plan and decision gates

**Recorded browser checks** belong in the attached evidence log, with source hashes, viewport, exact path and observed result. Check fit-width, Night and Next match from one down/up; verify zero commands before release and exactly one after; cancel restores state; page-origin drags do not open Tools; unavailable controls stay inert. Inspect every command family, small portrait, landscape, both themes, long translations and 200% text/list mode. Distinguish a shown unavailable capability from an implemented action.

**Native non-interference gate:** on a current Android device with gesture navigation and three-button navigation, plus an iPhone with Home indicator, perform at least 30 trials per origin/gesture: page scroll crossing Tools, horizontal paging, zoomed pan, pinch, selection long-press/handles, links, left/right system edges where applicable, bottom Home/task switching, rotation and interruption. Include PDF/EPUB/Markdown native surfaces, keyboard open, TalkBack/VoiceOver and one low-memory device. Pass: no wheel activation from page/system origins, no lost document gestures, no action on cancellation, and OS navigation remains available. Thirty trials are a screening gate, not proof of zero field failures.

**Formative usability study, not yet run:** recruit 12 people covering both dominant hands, smaller/larger phones and mixed reader experience; run a separate accessibility session using the ordinary list with assistive technology users. Compare the proposed fan against a conventional toolbar/list, counterbalance order, and include first-use plus a short practiced block. Tasks: Fit width, Night, Next match, page jump, Find a phrase, inspect Contents, cancel a mistaken command and resume scrolling. Record completion time, wrong command, cancellation success, accidental activation, finger travel, reach/occlusion and participant explanation of the gesture.

Advance the fan only if at least 90% of first-use tasks and 95% of practiced discrete-command tasks succeed, cancellation succeeds at least 95%, no system-navigation interception is observed, and practiced discrete commands are no slower than the toolbar baseline median. Report small-sample uncertainty and individual failures; do not hide an average that masks one-handed or accessibility failures. If the eight-child fan fails, split the command inventory more carefully or keep the conventional list as default; do not make targets smaller to force a wheel.

The user should review the interaction route and command map, then a native spike should prove gesture ownership before this becomes the mobile app's navigation architecture. Previous scores do not apply; this revision is a researched, inspectable proposal with native and participant validation still outstanding.
