---
paper-size: A4
---
# Reader review and Collection

Independent critic · 22 September 2026 · Implemented 23 September 2026

The findings below preserve the original review and approved design. Implementation, repairs, screenshots and final critic scores are recorded in the [action journal](../journals/collection-implementation/action-journal.md).

## Improve the existing reader

**Save reading positions during use.** After jumping to Markdown page 3, waiting over 12 seconds and abruptly restarting, the app returned to page 1. The saved session still held the old position. Checkpoint navigation and debounce scroll saves. Verified crash-recovery gap; graceful quit was not tested.

**Make tabs accessible.** The actual accessibility tree exposes the toolbar and document but no tabs. Add names, selection, group state, keyboard actions and shortcut help, keeping the approved compact appearance.

**Add Move to Group and grouped overflow.** Source inspection shows New Group without an existing-group destination, and overflow lists filenames without group identity. Add destinations with colors and membership checkmarks; organize overflow by group. These group interactions remain unverified live because computer-use coordinate clicks failed.

**Improve editor selection and copy labels.** The first editor picker visibly starts in the document folder with all files disabled: start in Applications. Context menus should say “Copy Page 3 as PDF/Image” so the target is clear. Copy output itself was not tested.

The table fix, A5 layout and explicit page breaks looked good. Tabs, selected document and window geometry survived abrupt restarts. Group creation, colors, dragging and group persistence still need hands-on verification.

## Collection: the everyday experience

“I opened a supplier drawing last month, then moved the original. I want to find my saved copy and compare it with today's revision.”

Collection remembers documents after their tabs close. One Collection has **Documents**, containing each first-seen original, and **Versions**, containing its history. Tab groups organize the current workspace. Collection is local recovery history, not a backup on a separate device.

**First use:** propose Collection enabled, but ask once before retaining contents: “Keep a local copy and history of documents you open? You will continue using the originals. Copies stay on this Mac; change this in Settings.” Offer **Keep Enabled** and **Turn Off**. Reading starts immediately; capture waits for the answer. Remember the choice. Once the user enables Collection, or has already enabled it, silently import reachable documents from the existing recent-document list in the background, without another prompt. Prioritize the document being opened over this backfill; honor exclusions and a disabled Collection setting. Preserve existing Collection history rather than importing it again. A recent-file import captures the file as it exists now, with an honest capture date; it cannot recreate earlier revisions.

**Opening:** always display the live source at its original path. Immediately schedule a complete background capture after opening; “lazy” means off the critical reading/launch path, not waiting for a later manual action. Already protected, unchanged contents need no duplicate copy. History distinguishes **Saving to Collection**, **Protected**, and **Capture failed**, with the last successful capture time.

**Cmd+K search order:** use clearly labeled sections in this exact order:

1. Open document names.
2. Tab group names.
3. Open document text — first **5** results.
4. Collection document names — first **5** results, excluding documents already open.
5. Collection document text — first **5** results.

Within each section rank by relevance, then recency for ties. Group results activate that group's last-used tab. Text results show a short snippet and page, and jump to the highlighted match. Keep the section order stable as background results arrive. Index Collection content in the background; do not block instant open-document and group-name results. Versions remain nested beneath their document rather than flooding the results.

Typing **`col:<text to search>`** restricts the palette to Collection document titles/names and text, with no open-document or group sections. In this explicit scope, include collected documents even when they are currently open; show up to 5 title matches and 5 text matches, with **Show all in Collection** for the rest. A normal result opens the original whenever available; selecting an archived revision opens its read-only copy.

**Cmd+Backspace:** return to the previously active document tab. If that tab was closed, reopen it with its saved reading position and group when available. The tab just left becomes the return target, so pressing the shortcut twice goes back and forth between the same two documents; it does not walk backward through all tabs. Reveal/expand the target group as needed. In an editable text field, preserve the native text-editing shortcut; use the tab action from the reader or its menu.

**History:** add **Previous Version** and **Version History…** to the tab menu. History opens in the existing left sidebar. An archived preview has a persistent **Archived copy · read-only · date** badge and never replaces the live source silently.

## Preserve, inspect and compare versions

Before ShenzhenPDF overwrites a file, ensure its current revision is durably protected. Normally the immediate-on-open capture has already done this: reuse that revision, without another copy or prompt. If capture is still running, complete it before the write. Capture the completed edit automatically afterward.

**Why could capture fail if the document is readable?** Reading the source and writing a complete, durable archive are separate operations. The source can be readable while the Collection disk is full, its quota is reached, its folder is no longer writable, or the chosen Collection drive is disconnected. A large file may still be copying when an edit begins. An external editor may also replace the source during capture; retry until one consistent revision is saved. A successful open, or pages already cached in memory, does not prove that the complete source has been committed to Collection.

These are exceptional paths, not routine confirmation dialogs. Retry transient capture failures automatically and show progress. If an impending overwrite still has no protected pre-edit revision, offer **Retry**, **Cancel edit**, or explicit **Continue without history**, naming the actual failure. Reading stays available. If only the post-edit capture fails, keep the successful source save and earlier protected revision, mark the newest revision unprotected, and retry; never imply it was archived.

External edits have a narrower guarantee: retain the last observed version and capture the next stable saved version. Do not promise every intermediate revision or changes made while the app was closed. Keep capture times honest.

History shows date, size and reason: First opened, Before annotation, External change detected. Identical contents create no extra revision. Coalesce repeated autosaves into edit sessions while preserving the pre-edit and latest versions. Let users mark useful versions **Keep**.

Selecting a version opens a read-only preview. Offer **Compare with Current**, **Compare with Previous**, and **Save a Copy…**.

**Comparison behaves like two ShenzhenPDF readers side by side:** old version on the left, new version on the right, each with page navigation, zoom, search and a scrollbar. Show filenames/version dates persistently. Reuse the existing reader views inside one comparison window, with linked scrolling and zoom on by default and an option to unlink. Do not require two independent app processes.

Highlight **removed text, images and other content in red on the old version** and **added content in green on the new version**. A replacement appears as red removal plus green addition. Matching red/green markers in each scrollbar work like search-result markers: click to jump to a change; **Previous change / Next change** moves both views to the corresponding locations. Also label changes Added/Removed so color is not the only signal.

This applies to **PDFs as well as Markdown**. Match corresponding pages first, identifying inserted/deleted pages so a page insertion does not make every later page look changed. For text-bearing documents, align text and highlight its page rectangles; compare images and other changed visual regions too. Use visual-region differences for scanned or flattened PDFs, with red/green regions rather than pretending to have exact text edits. Version-specific page coordinates keep highlights and scrollbar markers correct after reflow. Empty counterpart slots make inserted/deleted pages understandable.

Reusing reader views reduces UI work. Reliable page alignment and difference detection are a separate shared component that still needs implementation and testing; the proposal does not assume that placing two windows together provides those results.

**Save a Copy…** creates an independent ordinary file. A later **Restore over Original…** action would require an explicit destination and a protected copy of the current original. Stored archive versions remain immutable.

## Recovery and user control

If the original disappears, keep its tab with a red warning outline and unavailable-source symbol. Preserve the group color on the group boundary. Say **Original unavailable**, offering **Open Archived Copy**, **Locate Original…**, **Save a Copy…**, and **Retry**. Show the archive date. Open it in a distinct read-only tab; keep the original marked unavailable. A disconnected drive is not a deletion.

**Locate Original…** offers **Search This Computer** and **Choose File Manually…**. Automatic search uses the last protected source revision's content hash by default and states that reference version/date. Search accessible local and mounted locations in the background, using indexed metadata and file size to narrow candidates, then verify complete content hashes. Exclude Collection's own storage and temporary working copies. Do not request blanket disk access automatically; explain any unsearched locations and let the user choose them.

Show exact-hash matches in **modification-date order, oldest to newest**, with full path, modified date, size and an Exact content match label. Identical contents can still have different modification dates and locations; the date is a sorting aid, not proof of identity. Let the user preview and choose the file to link—never silently choose the newest or first match. If no match exists, keep manual selection available. A changed revision will not have the same hash; a manually chosen mismatch must show that distinction before linking it to the history. Search is cancellable, and disconnected drives can be retried later.

Verified renames and moves retain history. A normal atomic save of the watched source is a version even if its file identifier changes. An ambiguous unrelated replacement at the same path starts a separate entry unless the user links it. Identical files at different paths remain separate documents; deduplicate their stored bytes only. Validate Locate Original candidates and expose uncertainty. Old locations remain searchable; closing a tab never removes history.

Settings offers **Collection On/Off**, location, storage used and **Manage Collection…**. Turning off stops new capture and indexing while preserving existing search, export and deletion. Say this beside the switch.

**Manage Collection is a dedicated window**, separate from the per-tab History sidebar. Use a view selector on the left, a central document/version list or thumbnail grid, and a persistent **options panel on the right**. Suggested views: **All Documents**, **Versions**, **Originals Unavailable**, **Kept Versions**, **Excluded**, and **Storage**. Offer list and thumbnail views, search, filters and sorting; retain the chosen view and layout across launches.

Selecting an entry updates the right panel with source path/status, capture dates, versions and storage used, plus **Open Original**, **Preview Archived Copy**, **Version History**, **Compare**, **Locate Original**, **Save a Copy**, **Keep**, and **Exclude** as applicable. Collection-wide options on the right cover capture On/Off, location, storage limit and cleanup. Multi-selection supports deliberate bulk actions.

Remove a version, document history or all archived data with explicit scope and confirmation for irreversible deletion. Collection actions never delete source files. **Exclude this document** prevents future collection; one-time archive deletion is a separate choice.

Default to **Keep all**. Offer an optional user-set limit, but pause capture when full instead of silently deleting the first copy or kept milestones. Protected, oversized or unavailable documents need clear capture status. The reader stays usable.

Markdown archives include bounded local linked assets, relative paths and a manifest. Flag missing or excluded dependencies. Never fetch network resources to archive them; remote content is not guaranteed offline.

## Delivery and implementation

**First:** first-use choice and silent recent-document import after enablement; full-copy archive; the specified Cmd+K sections and col: scope; Cmd+Backspace tab return; correct original/archive routing; read-only previews; missing-source recovery with automatic hash search/manual location; app-owned pre-edit checkpoints; sidebar history; and the Manage Collection window.

**Next:** stable external-change capture, dependency-aware Markdown archives, and the two-reader comparison window with red/green content highlights and scrollbar markers for both PDFs and Markdown. These are planned parts of Collection, not optional replacements with a thumbnails-only diff. Flag incomplete asset capture from the first delivery; do not imply offline fidelity until supported.

**Later:** compression or block deltas only if measurements justify them. Every revision must remain reconstructable, verifiable and exportable. Full copies with hash deduplication come first; optional APFS clones can accelerate copying.

Keep source identity, immutable archives and session state separate. Use stable document IDs, file bookmarks/path aliases and an indexed manifest. Existing mutable read-only working copies are not version history. Read-only archive views never change source permissions.

No blocking startup scan, hashing or copying. Start the active document’s capture immediately after open, then run bounded recent-document backfill and indexing in the background. Automatic Locate searches are explicitly invoked, not ongoing whole-computer scans. Snapshot consistently and retry if the source changes during capture. Gate app-owned writes on the durable snapshot. Debounce relevant file watchers; unchanged files need cheap metadata checks. Coordinate windows to avoid duplicate capture. Keep storage private; preserve source encryption and avoid indexing decrypted text by default. Do not automatically OCR scans.

Acceptance checks must cover exact search section order and five-result limits; col: scope and open-document deduplication; two-press tab toggling/reopening; oldest-to-newest exact-hash recovery results; PDF/Markdown text, image and page differences with scrollbar markers; rename and same-path replacement; offline recovery; failed snapshots; multiple windows; disable/exclusion/deletion across relaunches; immutable previews and independent exports. Prove Collection-off performs no archive work and enabled background capture/import does not delay reading or run on the critical launch path.

The user should always know whether they are reading the original, a saved version or a comparison—and whether the latest revision has actually been protected.
