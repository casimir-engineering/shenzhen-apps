# Independent critique — whole-reader workspace rethink

25 September 2026. **Evaluation reset. No inherited grades.** The user rejected the previous result as badly organized and buggy. Component screenshots and passing layout assertions did not establish a usable whole interface. This pass starts with interactive full-reader tasks, not a target score. No production changes or native app launch/capture are authorized here.

Reviewed current sidebar/workspace mode identities and persistence, group interaction contract, toolbar Find/Regex state, Collection/History behavior, and the prior proposal. The proposed 96 pt vertical icon+text rail beside one 212 pt contextual panel is a candidate, not an accepted solution.

## Highest risks to resolve first

**Major — scope can remain confusing despite cleaner columns.** Groups manages the workspace; Chapters/Find/History/Comments belong to the current document. Collection opens a separate companion. Visually separate those scopes and name the document in its panel. Collection must behave as a launcher, not falsely appear to select a persistent reader panel. Distinguish global Cmd+K search from current-document Find and group-name filtering.

**Major — height is being purchased with document width.** Rail+panel costs 308 pt,68 pt more than the old 240 pt default. At 1024 pt it leaves 716 pt before minimap, scrollbar and gutters; at 800 pt only 492 pt. Compare with the compact chooser at identical window, page, zoom and minimap state. Show the consequence for the page, not just a cleaner sidebar. Closing the panel must produce a useful reading state with an obvious way back. If the rail remains 96 pt wide, label that cost honestly.

**Major — a four-group fixture can hide the 72-tab problem.** Render all 72 actual fixture entries, distributed unequally across four groups, including a group with many tabs, a hidden active group, duplicate filenames and long names. Do not substitute six pretty rows or silently discard overflow. Expansion browses; only explicit activation opens. Group-name search remains group-name-only under the established user instruction; document discovery belongs to the global opener unless explicitly redesigned.

**Major — identity can become inconsistent across document, tab and revision.** The selected task, browsed group, active tab, current document and viewed version are different states. Test them together. Older-version viewing must visibly identify its date/read-only state; Return to Latest, Find and export must target the intended revision. A selected History row must not silently stand in for “the revision currently displayed.”

## Interactive failure checklist

Run at **1024×700** and **800×500** (or the actual supported compact minimum, explicitly reported), in light and dark. Use the entire reader at 100% browser scale, including top toolbar/tab strip, rail, panel, page, minimap and bottom status. Each task needs an observed state transition, not only a screenshot.

| Task | Fail the candidate if… |
|---|---|
| Start reading, open/close each task panel, reopen it | Controls move unpredictably; content is covered; zoom/page position resets; closing is mistaken for clearing a query; reopening loses context. |
| Locate and activate document 71 among 72, then return to previous document | Overflow hides access, duplicates cannot be distinguished, active tab vanishes without a reachable locator, or history/group browsing must be destroyed to switch. |
| Expand/collapse a different group, including a hidden one | Displayed document or selected tab changes. Opening a group is not the same action as disclosure. |
| Hide the active group; keep reading; reveal it again | Tabs close, current document changes, active identity disappears, or reveal loses group state. |
| Filter group names; try a member filename; clear | Scope changes silently, a filename produces unexplained results, clearing loses expansion/scroll, or no-results strands the user. |
| Cmd+K global discovery versus Cmd+F/Find | They target the wrong scope or occupy indistinguishable fields. A document's search must not become a workspace search. |
| Find phrase, next/previous, toggle Regex, invalid regex, no matches | Query/options/count/results/page highlight disagree; regex is buried elsewhere; invalid input appears as successful stale results; next/previous jumps into another document. |
| Switch PDF→Markdown→PDF with different queries/options | Query, regex state, outline collapse or search location leak between tabs; format-specific Comments changes the meaning of a selected mode. |
| Browse/open older History revision, Find within it, Save Copy, Return Latest | Header/status/history/export identify different revisions; original becomes writable accidentally; return loses the latest reading position or opens another logical document. |
| Open Collection from reader; inspect a saved document; return | A companion launcher looks like a current-document mode, closing Collection closes the reader, or browsing Collection silently navigates the reader. |
| Keyboard-only: rail→panel→page, arrows, Return, Escape, Cmd+F/K/G | Disclosure activates; focused row differs from activated row; Escape loses work unpredictably; typing in a control triggers type-anywhere Find; focus is stranded in hidden content. |
| Resize during Find/History, close/reopen panel, simulate restored session | Essential controls clip; nested scrolling prevents reaching actions; rail selection and panel disagree; width/mode/query/expansion/scroll state restore to the wrong scope. |

## Before the next review

Supply a working prototype that implements these transitions with visible fixture state. Unsupported native/file operations must be clearly disclosed; placeholder buttons cannot earn task-success credit. Add a compact chooser in Tweak as a real comparable layout, not a cosmetically inferior strawman. Keep task order, content and window size identical when comparing.

Record failed tasks and their corrections. A short screen sequence showing invocation, intermediate state and result is stronger than an attractive end frame. If child browser access remains unavailable, root must provide exact interactions and observed results alongside full-reader captures; the review will attribute them accurately.

For subsequent native work, preserve stable mode IDs and YAML ownership: workspace mode/width/visibility and group query/expansion/scroll; per-document chapter collapse and per-tab Find query/Regex. No new launch-path work or hidden-panel reload loop. A browser prototype can demonstrate the contract but cannot prove native focus, persistence, renderer behavior or companion-process lifecycle.

**No grade yet.** First establish that the full workflows are coherent and the 72-tab compact layout is usable. Any later beauty and usability grades must remain separate and state which interactions were actually exercised.

## First interactive prototype source review

25 September 2026. Reviewed the initial `reader-workspace.html` implementation (SHA-256 `74efb48331f6dc1f71c1cd02043c0fe10e346fd333920b3ad0741466912584f7`) and root's actual full-reader `evidence/reader-1024.png`. This is a browser proposal, not a production redesign. The 1024 px image makes Workspace versus Document scope easier to see, and the page remains readable. **No score:** the following workflow failures must be resolved before that static improvement can establish a usable design.

### Major / blocks meaningful workflow evaluation

1. **Document switching loses state and leaks other state.** `setDoc()` resets page, query and filter on every activation, while Regex and kept-version IDs remain global. Repro: document A at page 7 with a Regex query → B → A. Expected: A returns to its own location/query/options; B never inherits A's Keep state. Use document-keyed fixture state, and preserve a separate latest/older return location. A prototype can demonstrate this without native files.
2. **Displayed content does not identify the chosen document.** `paper()` always produces the Hardware/Interface specification content, even when document 71 or a Markdown file is selected. The tab and panel title change, but the page does not belong to them. Give fixture documents recognizable names/content; synthetic is fine, misleading identity is not. Include duplicate names with disambiguators.
3. **Global/Collection search invents hits and targets the wrong document.** Any nonempty Cmd+K query adds an Interface-specification text hit; clicking it places the query in the currently active document. Collection title hits invent highlighted text containing the query. Test a nonsense query and a title-only query. Generate rows from finite fixture text with document/revision/page IDs, or explicitly disable unsupported results. Never use false matches to make search look functional.
4. **Hidden active group remains in the tab strip.** Rendering unconditionally emits the current document's group strip, ignoring its hidden flag. Hide the active group and inspect the strip: its tabs should disappear while the current document keeps a separate visible reading identity. Explicit activation of a document in a hidden group must follow the chosen reveal semantics consistently.
5. **Find is incomplete and contradictory.** Regex toggling refreshes rows but not the count. Enter/Shift+Enter/Cmd+G result stepping is absent. Invalid Regex is simultaneously presented as an error and zero matches, replacing the preceding valid results without an explicit policy. Result page clicks do not select/scroll to an identified matching passage. Implement one query/options/result model and actual next/previous routes; show error state separately from a valid zero count.
6. **Zoom lies after the next interaction.** Changing zoom only changes paper max-width, without scaling text; the next `renderDocument()` discards that styling while the select still says 125%. Keep zoom in state, render it consistently, and ensure 100%/125% change a fixed document rather than simply reflowing a narrower HTML article. Label any remaining renderer limitations.
7. **Compact-height evaluation is not possible with a fixed 594 px shell.** The titlebar adds 48 px before wrapper margins, so an 800×500 or 560×380 browser cannot show the claimed compact reader. Make reader height respond to the tested viewport, then verify task lists, rail, status and dialogs remain reachable. Width-only responsive rules are insufficient.
8. **Modal keyboard ownership is missing.** Dialogs neither inert the background nor trap focus or restore the invoker; a dialog without an input does not receive focus. Tab can operate the obscured reader; closing loses the initiating control. This affects Cmd+K, Tools, chooser and simulated Collection, so it must work before keyboard workflow approval.

### Medium / resolve within the same focused prototype pass

- **Browsing causes unrelated resets.** Every group disclosure/hide and page action replaces rail, pane and document HTML. This discards focused controls, group-list scroll and input selection, and can disturb document scroll. Expand a group after scrolling deep into General, then hide a different group: preserve the active document, reading location and browse position. Update the relevant surface or restore explicitly keyed state.
- **Older-version return is indirect.** Architecture promises Return to Latest outside History. The visible version badge merely reopens History. Provide the explicit return action with the saved latest reading location. When the original is missing, comparison must not label a saved copy “Latest · original.”
- **Comparison controls imply unsupported behavior.** Linked scrolling is a checked checkbox with no handler; both sides are in one shared scroll surface, and “1 change · text and images” is canned. Either implement the demonstrated toggle/change navigation or label/disable those controls as illustrative. Compare Previous and save/export placeholders need explicit target document/revision in their feedback.
- **Restoration is partial but presented as persistence.** Widget state saves layout/mode/doc/page/version/pane/missing, omitting query/Regex, group expansion/hidden state, scroll, map and Keep state. Add deterministic fixture restoration for the behaviors being demonstrated, or explicitly exclude restoration from the prototype's claims. Do not infer native YAML correctness from it.

Root should verify the corrected transitions in full-window evidence: A→B→A; hide active group; General expansion at a deep scroll position; nonsense global search; Regex count/error/next; zoom followed by page change; older→Latest with History closed; keyboard dialog open/close; and actual compact-height layouts. Native file operations can remain disclosed placeholders; these navigation/state failures cannot be waved away as unavailable engine work.

## Second source pass — substantial corrections, remaining material issues

The revised source now has document-keyed query/Regex/page/Keep/zoom memories, document-specific page titles, hidden active-group removal, persistent scaled zoom, finite global/Collection search matching, modal background inertness/focus trapping/invoker restoration, an explicit Return to Latest control, two comparison scroll surfaces with a working linking handler, and truthful missing-original comparison labels. Group panel scroll is keyed by scope. These close most first-pass findings **at source level**; native behavior is not implied.

Root provides deliberate window-height fixtures: an 800×500 page with a 418 px shell and a 560×380 page with a 296 px shell. This is a valid controlled compact-window demonstration, not automatic browser-height adaptation. Final compact captures still need inspection. The inspected 1024 px History and comparison frames show explicit revision status and two comparison panes. The Find frame lacks all icons, unlike the others; root must refresh it or verify that icon-only controls survive the live transition.

**Remaining material workflow failures found in this pass:**

1. **Search hits and displayed text still use different data.** Cmd+K `sensor` offers an Interface-specification text result, but Find's separate three-sentence corpus contains no `sensor`. The click opens Find with zero results and does not force the promised page 1 if that document remembers another page. Saved text advertises page 3 but `archiveOpen` goes to page 1 without the hit query. Use one finite document/revision/page corpus for searching, showing results and rendering the matching page, with an explicit hit payload.
2. **Reading return points are incomplete.** Latest page 7 → earlier version → page 13 → Return to Latest stays on page 13. Canvas scroll is also global: `renderDocument()` preserves the previous document's scrollTop, so another document can inherit its vertical offset. Remember location by document/revision; preserve the latest return point independently from older-version browsing.
3. **Minimap state becomes false after an unrelated render.** Enter a no-match query; input updates markers correctly. Close the pane or change page: `render()` marks pages 1/4/7 solely because the query is nonempty. Regex toggling also leaves old markers. Derive count, result rows, markers and invalid-pattern state from one result computation on every update.
4. **A dynamically opened archive cannot restore its identity.** Opening Bench measurements appends document index 72, but the fixture document inventory is not persisted. Reload reconstructs only the initial 72 entries and clamps active 72 to 0, with saved missing/query/version state potentially retained. Persist stable document identity/open additions or reconstruct the referenced archive before applying restored state.

**Compact geometry verification required:** Collection's 350 px minimum content layout exceeds the 296 px shell before its dialog header and padding; verify that Settings and bottom actions remain reachable rather than clipped. Also inspect an older version with History closed, where the narrow toolbar must fit both the dated state and Return to Latest. These are concrete unresolved fit risks pending root's browser evidence, not proven failures from source alone.

No score. Recheck these bounded transitions after correction; no new layout architecture is requested by this pass.

## Final proposal closeout

Reviewed the final targeted source snapshot (`bebb585e3f9435e424bd5faaf8259b54b54ef9990ee92bc69d0b9deb8386ba19`) and refreshed full-reader images: Find/History/Compare at 1024, Groups at 800×500, older-version reading at 560×380, and Collection Settings scrolled to its lower controls at 560×380. This closes the layout investigation as an **unscored, inspectable proposal**, not approval to claim all reader workflows implemented or validated.

**Verified corrections:** source now reconstructs the opened archive fixture before restoring the active document; saves/reapplies per-document canvas position; keeps revision return points separately; derives minimap hits from actual results; and distinguishes invalid Regex from zero matches. Root's live checks confirm `sensor` from Cmd+K opens document 0/page 1 with one Find result, a no-hit query stays unmarked after closing the pane, and Latest page 7 → older page 13 → Return to Latest returns to 7. Those interaction results are root-attributed; I independently read their source paths.

**Rendered fit and visibility:** the 800×500 Groups frame preserves a readable document alongside the General list. The 560×380 older-version frame shows the complete dated indicator and Return to Latest on a second toolbar line with History closed. The compact Collection frame shows Set/Open Location after scrolling, with Return to Reader still visible. Removing its oversized minimum content height resolved the identified clipping risk. The refreshed Find frame has its icons and icon-only controls; root reports 92 SVGs and zero unconverted placeholders after runtime initialization. The earlier iconless frame was premature evidence, not the final appearance.

**Remaining prototype limits, stated concretely:**

- Search is a small shared fixture, not a document index. In this snapshot an open-text row still labels page 1 even when another corpus sentence sends the click to page 4/7. The Collection-text row uses `data-archive-open="1"`, while its handler's query/highlight branch expects `"text"`; it opens the saved document but does not demonstrate retaining that hit's Find context. The paper renderer also does not yet show the exact second/third corpus passages. Do not present those routes as validated exact-hit navigation.
- Comparison demonstrates a synthetic text difference and linked scroll surfaces. It does not establish native page alignment, image comparison, large-document performance or renderer correctness. File recovery, export, OCR, translation and storage controls remain disclosed locations/placeholders rather than completed native operations.
- The 72-document fixture establishes list/overflow organization, not every real-session case. Duplicate-name disambiguation, long-title extremes, live keyboard/assistive-technology behavior and complete YAML restoration remain future native checks. The controlled height fixtures are not automatic browser-height adaptation.

The proposal is materially more inspectable than the earlier cropped-sidebar work: scope and document identity can be followed across the whole window, and the narrower layout exposes its width tradeoff. This is enough to present the organizational choice and its demonstrated interactions without another cosmetic review loop. It is not a shipped app redesign. The separately fixed native mode-availability bug and its build/signature verification must be reported separately from this browser UX proposal. No beauty or usability score is assigned.

### Final fixture-hit resolution

The three exact-hit mismatches above are resolved in source snapshot `bbb1ea68f64a5c7de287d13de683c2bba1de7fb97f3ea4234b39017599a700b9`: the global result label derives its page from the matching corpus entry; the saved-text route uses `data-archive-open="text"`; and the paper renders the corresponding corpus passage. Root's live browser check confirms `timing` labels and opens page 4 with its actual passage. I independently inspected `evidence/saved-text-hit-1024.png`: Bench measurements is on page 1, Find shows one `sensor` result, the passage is highlighted, and the status explicitly says saved copy / original missing. The inspected `evidence/reader-light-1024.png` also preserves the whole-reader scope hierarchy and visible controls in light appearance. Root reports no browser console errors.

This resolves the final search-fixture objections; the small shared corpus, synthetic comparison, disclosed native-operation placeholders and native accessibility/session-validation limits remain as stated. No additional design loop or score is warranted for this proposal closeout.
