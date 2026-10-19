# Chat folders and drawing reasoning — 2026-10-10

## UX intent

Help readers organize conversations without interrupting the document. General
is always the first, collapsible default folder; ordinary folder rows remain
native table drop targets. Titles lead at 13pt medium, dates support at 11pt,
folder labels use the existing 12pt semibold style. Existing semantic window,
text, secondary and selected colors are retained. A 4px spacing rhythm and the
existing compact sidebar row heights remain. Inline editing uses a native
single-line, horizontally scrolling field over the title, 22px high, with no
sheet or animation. Return commits; Escape cancels. New-folder creation starts
editing immediately. Native drop highlighting identifies the destination folder
while AppKit supplies drag scrolling. No screen capture or app restart is used.

## Saved-conversation diagnosis

Inspected the requested “SW-1302 Toggle Switch Travel Range” transcript and
its saved PNGs, read-only. The model captured page 1 several times. The crop
clearly shows the actuator's solid/dashed extreme positions and the 3.1 mm
center-to-center dimension; 1.3 mm is the actuator width. The final answer even
listed 3.1 among the drawing dimensions while incorrectly denying that a total
travel dimension existed. This is a semantic interpretation failure, not
missing pixels or an unreadable crop. The 1.6 ± 0.2 mm table entry is per-step
travel to closure, a different quantity.

Contributing application issues identified and corrected:

1. No active-document context accompanied the initial question. The old system
   instruction explicitly started with workspace discovery, consuming several
   rounds searching other documents before finding the relevant one. Explicit
   sends now include bounded active-document metadata with no file reads.
2. The session discarded provider `reasoning_details` at every tool response.
   Opaque blocks are now returned unchanged in the next tool continuation, held
   only for that user turn and never shown or persisted. This follows the
   [OpenRouter reasoning-continuation contract](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).
3. Four recent crops could evict the overview. The bounded image selection now
   retains an overview of the same page/revision alongside the newest crop.
4. Generic visual guidance did not require interpreting dimension endpoints.
   It now distinguishes alternate positions, dimensions, per-step and total
   motion; readable evidence should be interpreted before recropping or searching
   unrelated documents. No part number or numeric answer is hard-coded.

The configured DeepSeek Flash model advertises image and reasoning input in
OpenRouter's current catalog. A standalone live replay could not obtain the
saved API credential noninteractively (macOS returned errSecAuthFailed). No
credential dialog was opened or access restriction bypassed; no live-model
one-shot success is claimed. The saved crop itself was visually inspected.

## Organization and verification

`list_chats` exposes paginated titles, folders, dates and optional matched text.
`organize_chats` supports atomic create/move/rename batches with a revision
precondition. It uses the same locked organization metadata as the human UI,
separate from message files. Undo/Redo swaps guarded snapshots; stale actions
cannot overwrite later human changes. General uses the existing empty folder
identity, preserving all old unfiled chats without a startup migration or scan.

Headless tests cover default membership, General collapse, inline focus/Return/
Escape, native pasteboard payloads and drop destinations, atomic rollback,
concurrent edits, real tool dispatch and Undo/Redo, request-only reasoning
continuity, active-context laziness and overview retention. Native sidebar
fixtures render light/dark, narrow widths and inline editing for inspection.
Reader acceptance, session, organization, history, launch-policy and updater
suites pass. File-size limits are unchanged.

The new session regression was also compiled against the previous Session source:
it fails specifically on lost provider reasoning and missing active-document
context, and passes against the corrected source. Native fixtures inspected:
[inline rename](chat-inline-rename.png) and [General/folder sidebar](chat-folders-dark.png).
