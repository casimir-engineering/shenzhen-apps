# UX critic — loop 1 of at most 4

Date: 2026-10-09. Independent source and offscreen native-render review.

## Verdict

Beauty: **8.2/10**. Usability: **6.8/10**. Not at the 9/10 acceptance bar.

The unified Settings direction is coherent and calm: clear headings, restrained
reader palette, compact native controls, useful plain-language consent, and an
obvious path back to reading. It avoids a tour and gives AI appropriate optional
weight. The chat typography is readable, citations stand out, and newest-first
ordering is explicit. These strengths do not excuse dead preference wiring,
missing connection progress, or chat state/control problems.

## Evidence and limits

Read repository `agents.md`, `portable/docs/agent-handoff.md`, the onboarding plan,
interface-design and macos-design-guidelines skills. Inspected Settings, chat,
Markdown, integration, session, sidebar code and test sources. Visually inspected
all eight `/tmp/sz-settings-{overview,ai,collection,reading}-{NSAppearanceNameDarkAqua,NSAppearanceNameAqua}.png`
and both `/tmp/sz-ai-chat-{NSAppearanceNameDarkAqua,NSAppearanceNameAqua}.png`.
These are actual offscreen AppKit views, not screenshots of the user's app.
No app was launched, stopped or captured by this critic. Existing test code was
reviewed; this critic did not rerun tests, so passing results are not independently
asserted. Sidebar icon semantics are source-reviewed but its composed host was
not visually captured. An isolated live-user-path pass is still needed.

## Ranked fixes

1. **P1 — Reading preference is a dead control.**
   `SPDFMacUnifiedSettings.mm` builds `keepImageColors`, but
   `SPDFMacAISettingsIntegration.mm` neither supplies its current value nor handles
   its change. It always looks off and clicking it cannot change the reader.
   Wire the real preference in both directions and test reopening Settings.

2. **P1 — Rejected sends can erase the draft.**
   `aiSendText:` returns YES after calling the session's void `send:` method.
   The session rejects messages above 32,000 characters or a full chat budget,
   but the view then clears the composer. Return acceptance from the session (or
   equivalent authoritative validation) and preserve text on every rejection.

3. **P2 — Connect has no actual connecting state.**
   The UI supports `connecting`, but the host's Connect branch never sends it.
   Repeated clicks cancel/restart authentication; there is no waiting guidance.
   Publish connecting state immediately, disable repeat starts, show an inline
   waiting/error result, and reliably clear state on completion/cancellation.

4. **P2 — Sending while unconfigured opens an unexplained Settings destination.**
   Both enablement and missing-key gates call general `showUnifiedSettings:`.
   It opens the previously selected section, often Start here, with no reason.
   Select AI & documents, explain the precise missing step inline, retain the
   draft, and provide an obvious route back to chat after setup.

5. **P2 — Chat status and Stop become stale in history.**
   `state.session.changed` suppresses all view updates when history is visible.
   `displayChats:` uses a cached `_running`, so a completed/cancelled task can
   leave Stop enabled and the status uninformative. Refresh task status and
   cancellation independently of the history rows; show a Return to current chat
   route while a task runs. Test finish and Stop while viewing history.

6. **P2 — First message label is visibly clipped.**
   In both provided chat renders, the top half of “Assistant” is hidden at the
   scroll viewport edge. Lay out before scrolling to top and preserve a real top
   inset; assert the label's visible bounds after width changes. This is present
   in the evidence despite the current geometry tests passing.

7. **P2 — Light composer lacks an input affordance.**
   `textBackgroundColor` is white on the white reader canvas. In the light render
   only placeholder text identifies the editor; the 68-point input surface
   disappears. Add a subtle semantic stroke or slightly inset surface in both
   appearances and an obvious focus ring. Keep the compact geometry.

8. **P2 — History is not fully reviewable and Undo is misleading.**
   Chat silently stops displaying after 40 visible messages without an Older
   messages affordance; saved older content is effectively inaccessible. Add
   lazy expansion. Undo action is always enabled and its result/error is ignored
   by the host; disable it when unavailable and show a meaningful description
   or result when available. Do not let the control look ready when it cannot act.

9. **P3 — Distinguish primary completion and contextual labels.**
   Start reading has the same quiet fill as secondary actions. Give the default
   action modest native emphasis. Reopened Settings may say Done. Replace the
   header's bare “Esc” control with Close plus a shortcut hint. Distinguish the
   two “Open Settings…” accessibility labels (Accessibility vs Full Disk Access).
   The sidebar's paired speech bubbles are an appropriate Chats symbol and have
   a full 28-point target; add visible hover/press feedback for mode -2, which is
   currently excluded from the row's feedback fill.

## Next-loop acceptance evidence

Rerender both appearances after fixes, including chat empty/history/active/stopped,
long histories and narrow layout. Test every Settings preference round-trip,
connection-state transitions, blocked-send draft retention, history task-state
updates, and message/header visible geometry. A single normal conversation render
cannot prove the requested “no unclickable controls” contract. The parent can
perform the separately authorized isolated live workflow without touching the
existing reader instance.
