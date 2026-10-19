# AI reader preview

- Chat history now has folders, timestamps and short generated titles. Right-click
  to rename a chat or move it; removing a folder keeps its conversations.
- History search shows highlighted message excerpts. Search inside a chat is
  separate. Chat actions align with the reader toolbar, Hide comes first, and
  Chats shows its selected state. Empty chats no longer show a blank dark block.
- Generated chapters use plain, more descriptive titles. A successful final
  tool action no longer becomes an Error solely because the step limit was reached.

- Ask questions about open documents; click cited sources to open the page and highlight the passage.
- Browse saved chats in the left sidebar; read and continue a chat in a resizable panel beside the document, with search, Undo and Redo.
- Preview pages, organize groups, control the reader, and manage supported PDF comments.
- Request a separate PDF export, OCR copy or translated copy; stop work and undo eligible changes.
- Complete the four-step first-run setup; new installations default chat and summaries on.
- Cloud requests wait until setup is complete and OpenRouter is connected.

---

## For readers

The first normal launch opens a four-step setup after the reader is ready:
**Full Disk Access**, **Collection**, **OpenRouter**, then **Default reader**.
Full Disk Access is optional; you can continue and macOS will prompt if a later
open needs it. Collection offers an adjustable dynamic limit of 50–80% (default 80%) of free
space plus existing Collection storage, a fixed limit, or Unlimited. Move
location verifies the transfer and removes the old stored files. Editable
Collection documents can move between folders on the same disk; cross-disk moves
are refused when editable documents exist, protecting in-progress saves. Startup
Keychain reads cannot show password prompts. OpenRouter connects in
the browser or through an API key field revealed on request; keys stay in
Keychain. Open the model picker to load and search the catalog of models that
support tool calls. The final step lets you search file types and independently
set ShenzhenPDF as their default reader. Setup explains that document text is
sent to OpenRouter for summaries and missing chapters and that usage spends
account credits. It has no Accessibility step. **Done** returns to the reader;
Settings does not appear on each startup.

New installations default document chat and automatic analysis to on, and
existing saved preferences are preserved. This does not start cloud work before
the wizard is complete and an OpenRouter account is connected. You can change
these preferences later under **Settings → Settings & AI… → AI settings**. Select a model
from the catalog; availability can change and is checked with OpenRouter.
Press **⌘K**, then Return with an empty search field to open
chat; choose **New chat** for a separate conversation. Return sends a message, Shift-Return adds a line. With a nonempty search
query, Return continues to open the selected search result; use the explicit
Ask action to start a new chat with that query as a draft, then press Return to send. The chat can be stopped with
**Stop** or closed with Escape. Saved conversations are available from **Chats**;
deleting chats removes their transcripts and saved page previews from this Mac.
The Chats icon opens history in the existing left sidebar. Selecting a conversation
opens a resizable chat panel beside it, with the document on the right. Hide the
panel without losing its draft; search saved titles and both speakers' messages.
The panel width is saved in YAML. Undo and Redo are available for supported
assistant edits; native menu actions explicitly report when Undo is unavailable.
Activity shows when the model is thinking, which tool is working, when a reply
is ready, and actionable failures. User messages remain in the saved history. Muted blue user messages and neutral
assistant messages distinguish the two speakers in both themes. Replies are
brief by default and follow the user’s requested scope and wording.
The authorization-send path no longer loses the user message when its composer
clears, which previously could stop the first tool call with a false save conflict.

Answers can cite exact retrieved passages and show relevant page previews.
Selecting a text-search citation opens that document and page with the passage
highlighted; page-only links support visual sources. Source revision and layout
checks reject stale links, and opening a citation keeps chat available. The assistant can
organize tab groups, change supported reader controls, read and edit PDF
comments, close/reopen tabs, safely rename eligible files, find and open
Collection documents, and perform supported document jobs. It asks tools for
evidence as needed rather than sending every open document with each question.

**Stop cancels future work.** If a requested change already completed, it stays
in effect until undone. **Undo action** reverses the latest assistant change
when its result still matches the receipt. If the user or another process has
changed that state or file, Undo refuses rather than replacing the newer work.
Redo reapplies supported actions if the relevant state still matches. Journals are session-local; transcripts remain saved across launches.

Document jobs create separate outputs under `Assistant Exports` in the
application-support directory; originals remain unchanged. PDF export converts
an open supported text document to PDF or makes a PDF copy. OCR and translation
run locally and require their tools to be installed already. Protected PDFs
must first be copied without a password. Scanned documents need OCR before
translation or text-based answers can work. Stop cancels a running job. Undo
closes its generated tab and deletes the output only while that exact output is
unchanged.

Automatic analysis sends a bounded sample for a short summary, up to six tags, keywords and
suggested chapters after a successful document open when its setting is on;
authored bookmarks/headings take precedence. The analysis is cached by
content, layout, model, language and prompt version. Unchanged cached analysis is reused. A session is
limited to 20 uncached analysis requests, each sampling no more than 30 pages
or 64,000 characters. Collection historical previews and editable copies of
older revisions are excluded; only the current/latest source is analyzed.
Analysis skips locked files, files over 256 MiB, and documents with no
extractable text.

When a compatible latest revision changes, the assistant can update its prior
summary using that summary plus a bounded exact text delta (up to 32,000 changed
UTF-16 code units), rather than sending the full excerpt again. If page
coverage, outline, layout or change size is incompatible, it uses the bounded
excerpt path instead.

## For AI agents

The in-reader assistant is an OpenRouter chat client with a fixed tool schema.
Model-facing tools use opaque IDs, and document text is untrusted evidence. The
assistant can page through the current workspace without opening document
files, then retrieve cached analysis and chapters with `document_metadata`;
read at most 20 pages per call;
search a bounded set of open documents; inspect full-page images or normalized cropped regions using `render_page` with an image-capable model; navigate to
revision-checked evidence; organize groups; inspect and alter supported reader
state; read/edit comments; list/open Collection documents; close/reopen tabs;
rename eligible files; update saved generated chapter/summary/tag/language metadata with Undo/Redo; discover and operate native app menus and visible controls; and run explicitly requested `document_job` operations
(`ocr`, `translate`, `export-pdf`). Typed document tools use discovered document IDs. Native commands retain ordinary app dialogs and macOS permissions; secure/credential fields are excluded. There is no shell or web-browsing tool.

Document reads are bounded to files in the active reader workspace, with
Collection documents accessible only through Collection discovery/open tools.
Cross-document search checks at most 100 pages per document and 16 documents,
and returns at most 50 matches. Search output reports per-document continuation
and partial coverage. Page text reads return at most 20 pages per request.
Responses, messages and tool rounds also have limits; when they are reached,
the assistant reports that the user should narrow the request or start a new
chat. It does not claim that a partial search covered the entire workspace.

The `document_metadata` tool returns cached summary/tag/keyword/chapter metadata
and can list Collection revision IDs, dates, file sizes and diff status without
reading archived document bytes. Supplying a `revisionID` explicitly requests
a lazy text diff against the preceding revision. The diff uses saved text
indexes only; it measures neither image changes nor full-file byte changes. It
compares at most 30 pages and 128,000 combined text characters, with a 4 MiB
limit per index, and labels coverage partial. Missing, encrypted or oversized
indexes report an unavailable status and reason. A first revision and an
identical revision also have explicit statuses.

Mutating tools return action receipts and validate current document revisions
or workspace state before committing. Undo checks the recorded post-action
state. Document jobs write into an app-owned output directory and use exclusive
file creation so an existing path is never replaced. Job Undo removes only a
file that still matches the generated receipt. File rename and comment edits
have explicit writable-file and size limits. Encrypted PDF jobs, arbitrary
deletion, read-only original rename without Save As, and tools not
listed in discovery remain unavailable.

Each provider request asks for OpenRouter no-data-collection and zero-data-
retention routing. If a selected provider cannot honor those parameters, the
request fails without a weaker-privacy retry. This is a routing request, not an
independent guarantee about all intermediaries. Chat may use account credits or
incur provider charges; pricing depends on the selected model and account, and
the reader does not estimate or cap that spend. Interactive chat sends only
the context retrieved for the user's request. Automatic analysis defaults on
for new installations, but cloud requests require completed setup and a
connected OpenRouter account. Existing saved preferences are preserved.

See the [document assistant guide](../document-assistant.md) for setup and
operational detail, and [AI control and Markdown authoring](../agent-interface.md)
for the separate headless CLI/MCP interface. See the [revision analysis validation](../journals/ai-reader/revision-analysis-validation.md)
for the bounded text-delta and history-index implementation details.

Collection working copies can be renamed directly by the assistant. The action
preserves the document’s original source reference, group and version history.
Undo restores both the previous filename and Collection title, and refuses to
overwrite a subsequent rename or edit.

AI language is selectable from a searchable list in both setup and AI settings.
It controls default chat replies and generated summaries, tags and chapter titles;
a language explicitly requested in chat takes priority for replies. The saved
default remains unchanged. Language changes do not bulk-process the library.

One background request produces all document metadata together, including up to
six tags. File Properties shows the cached tags, summary and language. Existing
chapters are preserved, and older Collection revisions are not summarized.

### Visual document evidence

The assistant can now receive actual page pixels, rather than only displaying a
preview to the user. It can inspect a whole page and request a higher-detail
crop for drawing dimensions or small table cells. The model picker labels
image-capable models **Images**. Crops retain page/revision citations and appear
in the transcript. Image work is lazy, cancellable and bounded; saved PNG assets
are reused on chat resume without embedding base64 in stored transcripts.

`render_page` accepts `page`, optional `revision`, optional `maxDimension`
(256–2400, default 1600), and optional `region` with normalized top-left `x`, `y`,
`width`, `height`. Omit `region` for the entire page. The tool returns the exact
region, pixel dimensions and a clickable page citation. Rendering always uses
original colors independently of the reader theme. Four recent images and
9 MiB total PNG bytes can be included in one request; unavailable/omitted images
are identified explicitly. Text-only models are not silently replaced.

### Chat folders and drawing interpretation

- General is the default chat folder. Drag chats onto folders; rename chats and
  folders directly in the sidebar without an animated dialog.
- The assistant can list saved chats, create folders and organize conversations
  in atomic batches, with guarded Undo/Redo.
- Chat starts with the active document context instead of blindly browsing all
  workspace groups. Visual evidence retains a full-page overview alongside a
  detail crop. Provider reasoning state survives tool continuations without
  appearing in the transcript or being saved to disk.
- General evidence guidance checks the question’s purpose, source definitions,
  scope and conditions, distinguishing stated facts from calculations and assumptions.
  Model interpretation can still be wrong; no drawing-specific prompt rule is used.

### Citation navigation and evidence quality

- Document citations reach their page on the first click, including tabs whose
  saved viewport would otherwise be restored during opening.
- Page links wait for a loading document without overriding a later user action.
- The chat prompt asks for the evidence relevant to the user’s question, choosing
  text or page images as needed and reusing readable evidence. Citations validate
  retrieved provenance and revision, not the correctness of the model’s conclusion.

### Chat reliability and search

- Search within a chat scrolls to the matching passage and highlights it.
  Return moves to the next occurrence; Shift-Return goes to the previous one.
  Opening a message-content result from chat history reveals its passage too.
- Truncated model responses get one bounded retry with more output room.
  Incomplete tool actions are never executed, Stop remains available, and empty
  answers no longer appear as successful completions.
- Chat answers now default to 1–3 short sentences with citations. Detailed
  explanations, derivations and tables are provided when requested.
- Concise chat replies check source context, scope and conditions, choosing text
  or page images as needed. The assistant reuses evidence and copies source links.
- A citation with an invented text highlight falls back to its verified page,
  including in existing chats. Unverified document/page links remain blocked.

- Brief AI results appear in compact lavender cards with a large value and a
  contrasting **View evidence** button. Layout adapts to narrow panels; cards
  persist in chats and support text selection/search.
- AI: `present_answer` displays a final card from a short label, value and retrieved
  citation, without another answer-generation request.
- Reopened chats omit empty intermediate tool messages instead of showing blank
  Assistant bubbles. Saved answers and source previews remain available.

- Page reads return extracted text only. Full-page and crop images are requested
  explicitly through `render_page`; `current_view` is a separate optional tool.
  No automatic sparse-page preview is attached to text reads.
- Ask the assistant to look at your current document view. It can inspect the
  visible page area, selection and highlights without changing your position.
- AI: `current_view` returns on-demand viewport pixels, reading controls,
  visible page regions and exact source citations, including live Markdown
  layout identity. It captures document content only, not other applications.
- Chat restores the earlier general evidence prompt with only its brief
  answer-card hint added. `current_view` remains available through tool discovery,
  without extra system-prompt guidance. Model interpretation can still be wrong;
  source links remain essential.
