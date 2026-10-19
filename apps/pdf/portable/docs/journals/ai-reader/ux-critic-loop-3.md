# UX critic — loop 3 of at most 4

Date: 2026-10-09. Independent native-render, source and headless test review,
with explicitly attributed production interaction observations from the parent.

## Verdict

Beauty: **9.0/10**. Usability of the reviewed Settings/chat surfaces: **9.0/10**.
No known P0–P2 defect remains in this review's scope after the final source fixes.
This meets the design review bar; it is not a claim that paid provider requests,
every document tool, or the final rebuilt application's complete workflow have
been exercised by this critic.

Settings has a clear hierarchy and a restrained, consistent native appearance.
The completion action is recognizably primary without dominating the reader.
Chat has readable rich text, visible citations, clear input bounds in both
appearances, explicit newest-first ordering, and task controls whose states mean
something. Removing the misleading history composer makes that view decisively
simpler. The result now feels like one reader experience rather than disconnected
setup and AI panels.

## Evidence for closing prior findings

- Reviewed refreshed Settings overview, AI and Reading images and stopped-history
  native image. The image-default label states its scope. Empty history shows a
  disabled Delete all action; the false editor and Send action are absent.
- `updateState:` now updates existing status controls rather than rebuilding the
  section. Focused model/key editor tests assert draft, selection, editor identity
  and focus survive asynchronous updates. Secure text is still cleared at submit,
  section exit and window close.
- Fresh `mac-unified-settings-tests` and explicitly rebuilt chat-view suite each
  exited **0**, zero failures. Logs: `/tmp/sz-critic-loop3-settings.log`,
  `/tmp/sz-critic-loop3-build.log`, `/tmp/sz-critic-loop3-chat.log`.
- Reran Settings tests after the final secure-field action change: exit **0**,
  `/tmp/sz-critic-loop3-settings-final.log`. The new credential test verifies the
  field's action wiring and invokes that action with a dummy value; it does not
  synthesize a physical Return keypress. That distinction matters for the live
  keyboard follow-up.
- History tests verify its input is hidden, empty Delete all is disabled, task
  status updates, and visible action corners remain reachable. Prior fresh
  narrow-layout checks continue to pass; current normal-width renders have no
  clipped first role label.
- Source verifies connection-status resets after fallback-key submission and
  disconnect. Authentication generation checks ignore stale completion updates.
  Both closing methods now invalidate pending authentication, matching the copy.
- Manage storage now routes through `showCollectionSettings:` to the companion's
  Settings destination; it is no longer merely the general Collection route.
- During this loop the critic found missing composer focus after returning from
  history and ambiguous Return behavior in the API field. The parent added
  explicit composer focus for current/new/load, cleared cross-chat drafts for
  fresh/new/load entries, and assigned the secure field's save action. These final
  changes were source-reviewed; production keyboard validation remains below.

## Production observations reported by the parent

The parent launched a separate isolated application instance. It reported that
first-run Settings appeared, the AI section accepted its first click, Collection
could be disabled and Start reading closed Settings, a Markdown fixture opened,
and Cmd K then Return opened chat with composer focus. Typing a question then
Return correctly opened AI Settings with enablement guidance. Closing Settings
and using Chats then Return to current chat retained the exact draft.

The copied binary used for that pass predated the final focus fix and exhibited
the missing-focus issue. The parent is rebuilding before repeating that path.
This report does not count the old-binary failure as evidence against the final
source, or count the unperformed final-binary repetition as a pass.

## Remaining ranked improvements and validation

1. **P3 / required final verification — keyboard paths in the rebuilt app.**
   Repeat Return to current chat, New chat and loading a saved chat; type without
   an extra click and verify focus, fresh draft behavior and Return/Shift Return.
   Check physical Return in the fallback-key field using an isolated/mock
   credential path. Headless target/action verification is narrower evidence.

2. **P3 — finish the contextual copy polish.**
   Reopened Settings could say Done instead of Start reading. The image preference
   could read “Keep original image colors in dark theme by default” to retain both
   scope and theme context. Neither affects current behavior.

3. **P3 — populated history and preview visual coverage.**
   Add/inspect a production render with real-length conversation titles, Delete
   actions, a trusted page image and its page-opening control. Current extra
   renders cover empty/stopped/long transcript states; they do not visually prove
   every populated-history or image-preview composition. Run deletion and citation
   navigation in the isolated app. Source and headless support are promising, but
   they are not substitutes for the requested actual user paths.

4. **P3 — connection return affordance.**
   A dedicated Cancel connection control and a Return to chat action after setup
   could reduce navigation effort. Existing close-to-cancel and draft-retaining
   paths are now coherent, so this is refinement rather than a release blocker.

No implementation was modified by this critic. No user instance was touched.
