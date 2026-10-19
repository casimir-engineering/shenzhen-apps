# UX critic — loop 2 of at most 4

Date: 2026-10-09. Independent native-render, source and headless test review.

## Verdict

Beauty: **8.8/10**. Usability: **8.5/10**. Substantial improvement; two interaction
issues keep this below the requested 9/10 bar. The remaining work is focused,
not a redesign.

The light composer is now unmistakably an input. The first role label is fully
visible in the refreshed normal-width images; transcript spacing and rich text
remain clear. Default completion has modest emphasis. Close has a readable name,
Undo reflects availability, and history can return to the current conversation.
The retained calm visual direction is appropriate for a native document reader.

## Verified fixes from loop 1

- Viewed refreshed light/dark normal chat, empty chat, stopped history and long
  conversation renders under `/tmp/sz-ai-chat-*.png`. No first-label clipping in
  those normal-width images. Both appearances show the composer outline.
- Settings integration supplies and persists the image-color default.
- Send acceptance is derived from whether the session actually adds a message,
  preserving drafts on session-level rejection as well as configuration gates.
- Unconfigured Send selects AI settings and gives a specific reason.
- Authentication now publishes a connecting state and ends it on completion.
- Activity refresh runs even in history, so Stop and Undo can change there.
- Older messages have a lazy expansion control; source and test cover expansion.
- Contextual accessibility labels distinguish the two System Settings actions.

## Remaining ranked findings

1. **P2 — Asynchronous Settings updates destroy active edits.**
   `SPDFMacUnifiedSettingsController updateState:` calls `selectSection:` for every
   update. That method clears `secret.stringValue`, destroys all section controls
   and rebuilds from committed state. A model validation response arriving while
   the user enters the fallback key discards the key draft. A status response
   during model editing similarly replaces the focused field and can lose the
   uncommitted text. Update status labels/buttons in place, or explicitly preserve
   current editor text, selection and first responder while applying unrelated
   state. Secrets should be cleared on submission, section exit and close, not
   because model metadata finished loading. Add a test that types a key/model
   draft, delivers `modelStatus`/`connectionStatus`, and checks text and focus.

2. **P2 — History still presents an input that cannot accept input.**
   The stopped-history render retains the normal outlined composer and “Ask about
   your documents…” placeholder, but `_composer.editable=NO`. This looks like a
   broken control when clicked, directly contrary to the no-unclickable-controls
   requirement. Hide the composer while browsing history, or visibly replace it
   with a compact “Return to current chat to reply” action. Keep Stop/Undo task
   controls accessible. A read-only draft preview should be labelled as such.

3. **P3 — Clarify the scope of image-color preference.**
   The new integration persists `_darkThemePreservesImagesDefault`, matching the
   existing default preference. The label currently sounds like an immediate
   current-document change. Say “Keep original image colors by default” and,
   if needed, explain that document-specific choices remain as they were.

4. **P3 — Refine empty history and setup feedback.**
   Delete all chats remains enabled with no saved chats. Disable or omit it in
   the empty state. Connection status is merged and can outlive its situation
   (for example, a successful-connection sentence after Disconnect); ensure
   disconnect and fallback-key success replace it with current guidance. A
   dedicated connection-cancel action would be clearer than closing Settings,
   though the existing close-to-cancel path is explicitly documented.

## Independent test evidence

Freshly compiled `mac-unified-settings-tests`: exit **0**, zero failures.

The initially existing chat binary was seven seconds older than its source and
failed the narrow-label containment check once, then passed on a second run.
The direct target alone was a Make no-op because the new test makefile was not
included. Rebuilt explicitly with:

```
make -C portable -f Makefile -f mac/tests/ai-reader-tests.mk build/SPDFMacAIChatViewTests
```

The fresh binary passed with exit **0** and zero failures, then passed three
additional runs to resolve the observed timing concern. The current headless
geometry evidence therefore supports the clipping fix. Logs are
`/tmp/sz-critic-loop2-settings.log`, `/tmp/sz-critic-loop2-build-fresh.log`,
`/tmp/sz-critic-loop2-chat-fresh.log` and `/tmp/sz-critic-loop2-repeat-{1,2,3}.log`.
The stale-binary failure remains in `/tmp/sz-critic-loop2-chat.log`; it is not a
current-source regression finding.

No user app interaction occurred. Full isolated production-window interaction,
provider authentication, native keyboard traversal, populated history deletion,
and page-preview navigation remain for the parent's authorized live validation.
The long-conversation PNG shows its top, so it is not visual evidence of the
older-message button itself; test and source establish that control's existence.
