> **Superseded wheel direction:** the document-switching interpretation below was rejected. The canonical replacement is `control-wheel-study.md`; the wheel contains reader commands only.

# Mobile reader — independent creative and technical direction

**Historical direction, not the implementation contract.** `spec.md` is canonical after critique round 1. It supersedes these exploratory choices: Reader uses header Organizer plus bottom Contents/Find/Switch/More; Groups navigates to a dedicated document list; deletion moves documents to General; Close removes working membership only; current wheel slots are neutral and hold uses a center-arming corridor. SQLite/jobs are foreground TypeScript repository-owned. This note records the independent creative contribution and is retained rather than silently rewritten.

Date: 2026-09-24. Specification research only; no mobile implementation is claimed.
Source baseline: `portable/docs/agent-handoff.md` and `portable/docs/releases/26.9.23-1.md`.

## Recommendation

Build the experience around **a quiet page and a small working set**. The reading surface is the destination;
Groups is a separate place for choosing and arranging documents; Collection is a durable archive. These three
concepts must never be called tabs, files, and history interchangeably.

Provisionally choose React Native + TypeScript + Expo development builds, with React Native Web exercising the
same shared screen components and state transitions in a browser. Keep document engines and storage behind
small native adapters. This recommendation follows the requested development workflow, not an unsupported claim
that React Native is the fastest reader framework. Confirm it with an early Android rendering/opening spike
before building a large UI. Flutter is the credible second choice; Kotlin/Compose wins if Android-native engine
integration demonstrably dominates the project and the extra iPhone UI work is accepted.

A quick browser feedback lane is a requirement. A browser mock that silently replaces the actual app's state
logic is a false economy. Browser visual confidence and native performance confidence are separate deliverables.

## Experience direction

### A page with room to breathe

Use warm paper, ink-black type and one restrained vermilion accent. Borrow the macOS app's readable group colors
and document continuity, not its window and sidebar geometry. Group color is a short edge mark plus a name;
it is never the only identifier. Document titles and actual content dominate, not giant book covers or statistics.

The reader has no persistent bottom app-navigation bar. Its compact top row contains Back, an elided document
title, and More. A small bottom reading strip has position/chapter and a clearly labeled Switch control. Tapping
unlinked page whitespace hides or restores chrome, but no hidden gesture is required to exit. Text selection,
links, page scrolling, zoom, and native back must take precedence over global gestures.

PDF opens at useful width with continuous vertical reading; double-tap toggles useful width and a closer zoom.
EPUB and Markdown use reflowed text with independent type size, line spacing and theme controls. Avoid forcing
phone prose into miniature A4 sheets. Reflow preferences preserve a semantic reading anchor, not a pixel offset.
PDF positions preserve page + normalized point + fit mode. Chapters are a bottom sheet; an actual search match
has a contextual Return action so a detour does not lose the original reading place.

### First use and opening

First app launch: one sentence, an Open document button, and a small Try a sample action. No account, tour,
permission carousel, archive indexing, or full-library scanning. An external Open With or share intent goes
directly to its document, not through that welcome screen.

When the first document becomes readable, offer a nonblocking Collection choice at the next natural pause:
“Keep a local copy and earlier versions?” with Keep copies and Not now. Explain that this uses device storage;
show the storage budget in the setting, not a misleading “free” promise. Before choice, durable history capture
is off. If opening requires a temporary local copy, label it as temporary reader data, distinct from Collection.

Opening has explicit states: resolving source, reading available bytes, readable, unavailable permission,
password required, unsupported/protected format, corrupt file, canceled. Do not report a provider download as a
renderer regression. Show progress and cancel for slow external providers; leave the current page usable until
the incoming document is ready. A failed switch keeps the old page and exposes Retry/Open another.

First visible page means actual readable document content, not a skeleton, title, cached cover, or spinner.
“Instant” becomes a defined performance gate on named local fixtures; large, encrypted, and remote inputs have
separate measured cases.

### Groups are the desk, Collection is the archive

The Groups screen has a persistent Search field, a Continue row, then compact group rows. Each row shows name,
color mark, document count and last-used title; expansion reveals dense document rows. Empty groups show Add
documents. Creating, renaming, reordering and moving documents has ordinary menu/button alternatives to drag.

Keep a simple ownership rule for MVP: each working document belongs to one group; opening from outside goes to
General unless explicitly opened into a group. Moving documents changes membership, not bytes or identity.
The same archived document can be reopened without making a duplicate document identity. Closing a document
removes it from the working set; removing a group offers Move documents to General or Close its documents,
and neither action deletes originals or Collection versions.

Groups and Collection are two destinations in the organizer, not a tab bar over the page. Return to reader is
one action and preserves exact position. The organizer remembers its filter, expansion, selection and scroll.

Collection shows one compact latest-document row, with a separate History action. History is a chronological
list with timestamp, source label, saved/kept status, and storage contribution where meaningful. One document
with 300 versions must not flood search with 300 indistinguishable titles. Earlier versions appear only after
an explicit history scope or a selected document's history. Archived reader mode has an unmistakable dated
badge and Save a copy; it never implies in-place editing of immutable history.

Storage UI reports actual physical bytes, reclaimable cache, protected versions, and a budget. “10 versions,
12 MB stored” is useful; an unverified “90% saved” badge is not. If deduplication shares storage, explain why
removing a version may reclaim zero bytes. A Keep marker protects that selected version, with separately named
Keep all history if supported; never let the UI and retention policy disagree.

### The weapons wheel: switch documents without leaving the page

Use the wheel for **documents**, not a mixture of documents, commands and group management. This is the proposed
interpretation of weapons-wheel navigation: a short direction gesture reaches a familiar item in a working set.
Keep normal reader actions in ordinary controls.

The bottom Switch control has a minimum 48 dp target. Tap opens the switcher without a timer. Hold for 220 ms,
then drag toward a slot and release to switch. The center is Cancel/current document. Returning to the center,
lifting outside an active slot, native Back, or a canceled pointer closes it without changing documents.
Wheel opening itself never changes the active document. Provide a one-time “Hold, slide, release” hint after
ordinary tap use; never block the page with training.

Use at most six slots drawn in a full circle in a lower-screen overlay, not six wedges squeezed into a semicircle.
Show short titles, format, and an identifying thumbnail/glyph, with the complete focused title above the wheel.
Place the wheel fully inside safe areas rather than clipping it around the user's initial touch location. The
hold starts on Switch, the pointer remains captured, and selection uses the displayed wheel's coordinate space.
A short neutral travel corridor from the trigger to the wheel center avoids accidentally selecting the lower slot.
The exact radius, delay and corridor need device validation; the prototype must demonstrate them explicitly.

Slots are a persisted per-group order, populated from group order and changed only through explicit arrangement
or membership changes; do not reshuffle on each read. Omit the current document from selectable slots, but leave
its assigned position neutral rather than rotating all remaining positions. Beyond six, a plainly labeled
All documents control opens the full group sheet; no nested wheels and no invisible seventh slice. With zero
alternatives show an empty switcher and Add document. With one alternative show its ordinary large button.

Tap mode offers the same six documents plus All documents in accessible focus order. At large text sizes,
Switch opens a vertical list; screen readers always get a normal labeled list and do not require drag gestures.
Expose current title, group, format and reading progress in item labels. Haptics are optional feedback, never
the sole confirmation. Reduce Motion removes scale/rotation animation. Left-handed placement mirrors the
trigger position without reordering persisted slots. The reader remains visible behind a quiet dim layer.

This control is distinctive because it preserves spatial document memory. Do not squander that advantage on
recency sorting that changes direction every time the reader returns.

### Search and reading continuity

Search starts with immediate filename and group matches; document-content results appear as available without
holding names hostage to indexing. Use visible scope chips: Everything, This group, Collection. In-reader Find
is explicitly scoped to the open document and opens from a stable reader control. Do not reuse one unlabeled
search box for incompatible scopes.

Results show title, format, scope and a short context snippet. Match navigation opens the precise page or semantic
anchor with a highlight. Recent queries and indexing status are clear. “No matches” differs from “Some documents
not indexed yet”; canceled queries cannot replace newer results. External or unavailable documents show status
instead of disappearing. Global search must never synchronously render every page or unlock every encrypted file.

Keyboard accessibility on tablets/desktop previews includes Tab focus, Escape dismissal, Enter activation,
Cmd/Ctrl+K global search, and a previous-document action. Android Back closes overlays before leaving a reader.
Focus returns to the invoking control after any sheet closes. Targets are at least 48 dp on Android; text scales
without truncating essential actions; high contrast and non-color status cues apply in every state.

## Stack decision, supported claims and explicit limits

| Candidate | Immediate feedback | Native bridge and later iPhone | Decision for this brief |
|---|---|---|---|
| React Native + Expo + RN Web | Shared React screens can render through DOM-backed RN Web; Fast Refresh is universal. Browser DOM inspection and role-based functional tests suit AI iteration. | Expo development builds admit custom native code; native engine modules still require compiling native binaries. iPhone shares shell/state but needs its own engine, files, lifecycle and accessibility validation. | Preferred, conditional on early Android engine/gesture performance gate. |
| Flutter | Stateful hot reload on mobile and web; one widget system for wheel and organizer. Excellent credible alternative for custom UI. | Native-code edits require a full restart; engine/plugin integration and native semantics remain platform work. | Choose if measured engine integration or wheel consistency outweighs the team's TypeScript/DOM feedback advantage. |
| Kotlin + Jetpack Compose | Android Studio Preview and Live Edit provide immediate UI feedback on emulators/devices; current docs include AI-assisted transformations from previews. | Direct Android integration; Kotlin/Compose Android alone is not an iPhone UI plan. Compose Multiplatform or SwiftUI would require a separate explicit decision and gate. | Best native-first fallback; do not dismiss as a slow feedback loop. |

Sources checked 2026-09-24: [Expo web](https://docs.expo.dev/workflow/web/),
[development builds](https://docs.expo.dev/develop/development-builds/faq/),
[Expo native modules](https://docs.expo.dev/modules/overview/),
[Flutter hot reload](https://docs.flutter.dev/tools/hot-reload),
[Compose iterative development](https://developer.android.com/develop/ui/compose/tooling/iterative-development).
The preference itself is an engineering judgment, not a benchmark reported by these sources.

Expo Go is a prebuilt playground with fixed native modules. It cannot validate a custom document engine merely
because a JavaScript prototype opens successfully. Start native validation with a development build. Rebuild the
native client after adding/changing native modules; routine shared UI changes use Fast Refresh. Local builds are
allowed; no mandatory dependency on a cloud build subscription is implied by selecting Expo.

Flutter web is suitable for app-like experiences; its official warning about static text-rich websites does not
disqualify an interactive reader shell. It does mean we should evaluate the actual browser automation/semantics
surface instead of assuming DOM parity. See [Flutter web FAQ](https://docs.flutter.dev/platform-integration/web/faq/).

React Native's own documentation distinguishes JS and UI frame rates and directs performance evaluation to
release builds. Native rendering does not excuse heavy hashing, indexing or parsing on the JS thread. Keep the
wheel gesture/animation independent of queued archive work and pass opaque engine handles rather than page
bitmaps through shared app state. See [React Native performance](https://reactnative.dev/docs/performance).

The macOS Markdown renderer is AppKit/CoreText-based and is not a portable mobile engine. Reuse its behavioral
fixtures and semantic rules where appropriate, not its view hierarchy. No stack selection proves PDF/ePub or
Markdown rendering quality. Engines, licenses and supported format profiles remain separate gates.

## The development workflow is part of the specification

Suggested future boundaries: shared domain types and state machines; shared tokens and screens; browser fixture
adapters; Android adapters; future iOS adapters; document-engine module; Collection store/index worker. Keep
platform branching at adapter boundaries, not sprinkled through reader components. React Native explicitly
supports platform-specific source files; see [platform-specific code](https://reactnative.dev/docs/platform-specific-code).

Every screen must render from deterministic fixture state without a live file provider or native engine. Include
empty, normal, 10,000-document, pending, unavailable, password, history-full, huge-text and failed-save states.
The same reducer/actions must drive fixture screens and native screens. Clock, IDs, locale and font loading are
controlled for screenshots. Native adapters can be absent in browser; the fixture mode must visibly identify
itself so nobody calls a page image a working engine.

The routine loop is: change a bounded component or state transition; run focused logic tests; open its fixture
URL; exercise the transition; inspect screenshot and accessible tree; then run the native gate if the change
affects native behavior. Maintain deep links for exact states instead of asking an agent to navigate twenty taps.
One-command entry points should start preview, reset fixtures, run focused tests and collect an evidence bundle.
Screenshot assertions have platform/font variability, so fix the browser/OS/fonts for baselines and investigate
changes rather than blindly updating them. See [Playwright visual comparisons](https://playwright.dev/docs/test-snapshots).

Acceptance for the toolchain spike, measured locally rather than promised: a warm shared-UI edit appears in the
correct browser state within 2 seconds p95; a known fixture can be reproduced in one command and one link; a
focused functional-plus-visual suite completes within 30 seconds for the small reference set. Record actual
edit-to-feedback and full-native-build time. Failure triggers workflow repair before feature expansion.

Keep maintained source files under 500 lines; split by coherent responsibility. No screen coordinator may own
routing, source I/O, render lifecycle, archive retention, search, gestures and settings. Each new feature states
what it loads lazily and includes evidence that unrelated documents and empty launch do not execute its work.
Store concise manifests of evidence (scenario, build/fixture hash, command, exit status, screenshot paths,
measurements) rather than thousands of lines of transcript. A critic should report concrete defects by state,
not rewrite the whole design or call it a 10/10 without evidence.

Browser checks prove shared layout, actions, ordering, focus and modeled failures. They do not prove SAF/provider
access, a native render surface, real text selection, TalkBack, GPU frame pacing, crash recovery, storage
atomicity, memory pressure, process death, password security, battery behavior, or iOS readiness.

## Scope and gates

MVP: Android local PDF, reflowable DRM-free EPUB and a specified Markdown subset; share/open-with/file picker;
faithful basic reading, selectable text where available, chapters, Find, saved positions; separate Groups;
document wheel plus list equivalent; bounded local Collection/history with truthful byte accounting and
recoverable archived copies; names/group search immediately and lazy content indexing; offline use, explicit
errors, accessibility and release-build performance gates.

Later: iPhone release after native parity gates; revision visual comparison; rich annotations/editing; OCR;
translation; synchronization; remote libraries; arbitrary plugins; DRM; complex fixed-layout/media-overlay EPUB;
desktop parity for every Markdown diagram/math feature; bulk comparison and social/account systems. MVP must
state exactly which unsupported constructs degrade to readable content and which files fail clearly.

Required acceptance scenarios before native MVP:

1. External PDF intent reaches a readable page without organizer, consent or archive work blocking it; a second
   intent during opening cancels/supersedes safely and stale results cannot replace the latest requested file.
2. Switch PDF → EPUB → Markdown → PDF restores PDF page/zoom and reflowable semantic anchors, including after
   process death. Closing a working item does not delete its saved history.
3. Six wheel slots keep direction after five switches; center/outside/canceled gestures do not switch; Back
   closes the wheel; every choice is reachable with TalkBack and with tap-only input.
4. Groups persist rename/order/membership and preserve organizer scroll; moving a document neither duplicates
   stored content nor resets progress. A 10,000-document list remains virtualized and usable.
5. Empty launch creates no Collection store or content index. Archive-disabled reading does not hash/capture;
   a selected file's first visible page arrives before optional capture/index work begins.
6. Collection opt-out preserves old saved history but stops new capture. Budget exhaustion shows status and
   respects protected history; archive/open failures cannot discard the previous readable page.
7. Search typing cannot show stale results; filename matches arrive before content indexing; selecting a result
   highlights the exact destination and Return restores the origin. Old revisions remain opt-in scope.
8. Browser evidence covers 360×800 and 412×915, light/dark, large text, wheel, search, empty and error states.
   Real Android evidence separately covers provider permission loss, keyboard, TalkBack, rotation, memory
   pressure, background/process death and release frame times on a named midrange device.
9. Every claimed speed number records device, OS, build mode, fixture bytes/page count, cache state, sample
   count and percentiles. Browser timings and loading placeholders never count as native first-readable-page.
10. Before promising iPhone later without redesign, run a narrow iOS proof of opening all three formats,
    persisted source access, engine surface layering, switcher gestures and VoiceOver. This is future
    implementation authorization, not work performed by this document/prototype task.

## Critic guidance

Judge text separately from visuals. Text quality requires unambiguous identities, scope, state transitions,
format limits, first-page measurement, storage claims and platform boundaries. Visual quality requires readable
actual content, clear Groups/Collection distinction, efficient density, visible action hierarchy, usable wheel
geometry, real long titles and small-screen/large-text recovery. A high score without functioning transitions,
error states and explicitly marked simulation is not evidence. Stop after the agreed maximum rounds and record
remaining defects honestly rather than rounding a score upward to hit a target.
