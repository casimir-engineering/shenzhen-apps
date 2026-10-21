# Document assistant (macOS)

The document assistant answers questions about PDFs, Markdown and other open
documents, with citations that open retrieved pages and highlight cited text through document search. It can show page
previews, organize open tabs, adjust reader controls, edit PDF comments, and run
some document jobs. It is optional and uses an OpenRouter model you connect.
This guide describes the current macOS implementation; Linux and Windows do not
provide this chat interface.

## First setup and account

On the first normal launch, a four-step setup appears after the reader is
ready. It does not appear on every launch after you finish. The steps are:

1. **Full Disk Access.** Open macOS System Settings to grant access to protected
   folders such as Mail and Safari downloads. You can continue without it;
   macOS will ask for access if a later open needs it. ShenzhenPDF may need to
   be reopened after granting access. Setup does not add an Accessibility step.
2. **Collection.** Choose whether to keep local copies and history, set its
   location, and choose storage management. Dynamic uses a selectable 50–80% (80% by default) of free disk
   space plus the space already used by Collection, adjusting as disk use
   changes. Move location transfers and verifies Collection files, then removes
   the old stored data; small routing records keep existing tabs working. If editable
   Collection documents exist, moving to a different disk is refused to protect
   in-progress saves; moving to another folder on the same disk is supported.
   Static sets a fixed limit; Unlimited is also available. Cleanup
   applies to stored history, never to originals.
3. **OpenRouter.** Connect in your browser, or reveal the API-key field when
   you choose to use a key. Keys are stored in this Mac's Keychain. Open the
   model picker to load its searchable catalog; it includes models that support
   tool calls. Models marked **Images** also accept page images for inspecting drawings, tables and scans. The default model ID is `deepseek/deepseek-v4.1-flash`, subject
   to current catalog availability.
4. **Default reader.** Search supported file types and set ShenzhenPDF as the
   default independently for each type you choose.

The AI step explains that document text is sent to OpenRouter for background
summaries and missing chapters, and that this uses account credits. New
installations default document chat and automatic analysis to on; saved choices
from existing installations are preserved. Defaults do not permit cloud work
until setup is complete and an OpenRouter account is connected. **Done** returns
you to the reader and does not make Settings appear at every startup. You can
change chat and automatic analysis later under **Settings → Settings & AI… → AI settings**.
Startup and background Keychain access are non-interactive: a locked or denied
credential does not trigger a Keychain password prompt. Credentials remain in
Keychain. If macOS blocks a saved key, chat shows **Authorize & send…** beside
the retained draft. Only clicking that button can show a system authorization
prompt; cancelling keeps the message. You can also reconnect in AI settings.

Turning chat off cancels an active chat request; turning automatic analysis off
stops analysis work.

Model settings, setup progress and chat transcripts are stored locally under
`~/Library/Application Support/ShenzhenPDF/`; the credential itself is not
written there. ShenzhenPDF validates the selected model through OpenRouter and
shows the catalog's document-tool support status. Availability may change, so
the current catalog and connection status are authoritative.

## Ask and manage chats

Press **⌘K**, then press **Return** while the search field is empty to open
chat. It returns to the current conversation; use **New chat** to start another. Type a question and press **Return** to send; **Shift-Return** inserts a
line break. With text in the search field, Return keeps its usual search-result
behavior. Use the explicit **Ask** action to start a new chat with that query as a draft, then press Return to send.
The **Chats** icon in the reader's left navigation opens saved conversations in
that sidebar. Selecting one opens a separate, resizable chat panel beside it;
the document stays visible on the right. **⌘K**, then Return with an empty
search, opens the same panel. **Hide chat panel**, or Escape from the composer,
hides it without ending the conversation or discarding its draft. Chat width is
remembered in the window's YAML sidebar state. At narrow widths, navigation and
the map temporarily yield space to the reader; their preferences are retained.

The sidebar searches saved chats by title or user/assistant message text. Message
matches include a highlighted excerpt. The separate **Search this chat** field
filters and highlights messages within the open conversation, including older
messages. Clearing it restores the transcript; the two searches are independent.

History rows show a concise title and the last conversation timestamp. A short
background model request suggests a title after the first successful reply;
this does not delay the answer. Right-click to **Rename chat** or **Move to folder**.
**General** is the default folder. Drag a chat onto any folder, including a collapsed folder or General, to move it. **New folder** creates a collapsible folder and immediately selects its name for inline editing. Rename edits the row in place without an animated dialog; Return commits and Escape cancels. Right-click a folder to rename it or
remove it while keeping its chats in General. Folder membership, collapsed state
and custom titles persist; a later model title or conversation save cannot
replace your chosen name. Folder/title operations never resend a conversation. You can also ask the assistant to organize all chats: it can list saved chats, create folders, move chats and rename them in a reversible batch. Manual edits made afterwards are protected from Undo.

The chat toolbar offers **Hide chat panel** first, then **New chat**, **Undo**,
**Redo** and **AI settings**, aligned with the reader toolbar, with hover labels. Thinking, current-tool activity, pauses, errors,
and readiness for your reply appear above the transcript. Your latest question
stays visible there, and both user and assistant messages remain in the saved
conversation, oldest first with new replies at the bottom. Chats are saved on this Mac. The Chats view lets you reopen a
conversation or delete one or all conversations; deletion asks for confirmation
and removes transcripts and their saved page previews, not documents or
Collection history. Answers render Markdown and can include local page previews
and clickable citations. A citation is accepted only when it matches evidence
retrieved in that conversation and the document revision/layout remains valid.
Text-search citations open the source tab, go to its cited page, and highlight the
literal passage using the reader's normal search. The conversation stays open.
Page-only citations remain available for diagrams and other visual evidence.
Changed or unavailable sources produce an explanation instead of navigating to
an unverified passage. Source links contain opaque document IDs, not local paths.

The assistant can request `current_view` to see the visible document viewport,
including its zoom, scroll position, selection and highlights. This is captured
only when the tool is called; it does not move the document or capture other
applications. The response includes visible page regions and source links.

Page text reads return extracted text only; they do not automatically generate
or attach images. The assistant can explicitly request `render_page` for visual
evidence or `current_view` for the document viewport. Text extraction alone can
miss drawings, outlined letters and spatial relationships.

Brief results can appear as pastel answer cards: a small descriptive label, a
large number, range or short phrase, and **View evidence**. The button opens the
verified source through the same citation navigation. Card text is selectable,
searchable and saved with the conversation. The assistant uses ordinary prose
when essential qualifications need more space.

The in-reader `present_answer` tool accepts `label` (up to 80 characters), `value`
(up to 48 characters, including units), and an exact retrieved `citation` URL.
It must be called alone after evidence retrieval and ends the answer immediately,
without an extra model round. Unverified citations and oversized/multiline values
return a tool error. This is a chat presentation tool, not a CLI/MCP command.

For drawings, dimensions, scans and tables, the assistant can request the actual
page pixels with `render_page`, then zoom into a region for small details. The
image is both shown in chat and sent to the selected model. This needs a model
marked **Images** in the searchable model picker; ShenzhenPDF never silently
switches models. Existing saved previews are restored as image evidence when you
continue a chat, subject to the image budget. Missing or omitted pixels are
explicitly reported to the model instead of being presented as inspected evidence.

Use **Stop** to cancel the current model request or queued tool work. A change
that already completed remains in place; use **Undo action** to reverse the
latest assistant action when the result has not changed since. Undo never
overwrites intervening edits. Up to 32 workspace/reader actions and 8
file/document actions are retained for Undo. **Redo** reapplies a supported undone
action while its relevant state still matches. A new assistant edit clears the
Redo branch. From an empty composer, ⌘Z and ⌘⇧Z invoke these actions; text editing
keeps its normal text Undo. These journals last for the reader session, while
chat transcripts survive relaunch. A failed or stale Undo/Redo reports why it
could not safely apply. Native menu dispatch is not covered by this journal.

## What the assistant can access and change

`update_document_metadata` changes saved generated chapters, summary, keywords,
tags (up to six), or analysis language. It requires current cached metadata and a
source revision; page anchors must remain within the analyzed evidence. It does
not rewrite authored headings or PDF bookmarks. Explicit chat requests can
change generated chapter language without changing the global default. Metadata
edits support Undo/Redo and update the reader's generated chapter list. Generated
chapter rows use plain descriptive titles without decorative emoji. At the tool
step limit, the model gets one response without tools to summarize confirmed
results; if it cannot finish that response, the chat says Paused rather than
marking successfully saved changes as failed.

`app_controls` discovers native app menus and visible controls and can activate
a command or set an editable value. Use typed tools first for reversible edits.
Native commands can open ordinary confirmation, file, or permission dialogs;
the model must inspect the result, not assume a queued command completed. Secure
and credential fields are excluded. Generic native commands return
`undoable: false`; their own native Cancel/Undo behavior applies where available.
No other applications, shell execution, or web-browsing tool is provided.

The model receives opaque document IDs and titles from the current reader
workspace, then retrieves evidence as needed. Its tools can:

- page through groups and open tabs without reading their files, then request
  cached summaries, keywords, tags and chapters for a selected document;
- search open documents and read bounded page text;
- inspect a full page or a cropped region as an image, show its preview in chat, and open a document at a cited page;
- create, rename, move, collapse, hide or expand tab groups;
- read the current reader state and change supported controls such as page,
  zoom, theme, sidebar, map, find query, text size and rotation;
- read, add, edit or delete comments in the currently displayed writable PDF;
- close and reopen tabs, rename a supported open file, and list/open documents
  in Collection;
- run a requested PDF export, OCR or translation job as a separate output, saved
  to Downloads and kept in Collection (see below).

Changes are scoped to the current reader and the tools listed above. Creating a
group, changing controls, navigation, comments, closing tabs, renaming, opening
Collection items and document jobs return action receipts for safe Undo. Group
or control Undo is refused if the relevant state has changed. File Undo checks
the resulting file identity/content before restoring or removing anything.

OCR, translation and export make a new PDF; the source stays unchanged. OCR and translation
need their local tools already installed. Assistant jobs do not install tools
or ask to install them, and protected PDFs must first be made into an
unprotected copy. Translation requires supported source and target language
codes and extractable text; scan-only PDFs need OCR first. Undo closes the
generated tab and removes the output only if it is still the exact generated
file.

## Where documents the assistant makes go

Every document the assistant makes goes to two places:

- **Downloads**, under a clear name: `Report (OCR).pdf`, `Report (French).pdf`,
  `Report (copy).pdf` for a PDF exported as a PDF, `Notes.pdf` for a Markdown
  export, or the name you asked for. A name already taken gets ` (2)`, ` (3)`…
  before its extension; a file already in Downloads is never replaced. The file
  is made elsewhere and appears in Downloads only when complete.
- **Collection**, captured at once with the reason **Made by the assistant**,
  the way files received through Friends are captured with **Received**. This
  follows Collection's own setting: when Collection is off, or not yet chosen,
  nothing is captured and no Collection is created.

This covers document jobs (OCR, translation, export), charts from Python that
you save with **Save** under the picture, and AI translations saved from the
translation panel as Markdown. The chat then shows **Saved to Downloads** with
**Open** and **Show in Finder**; a reopened chat keeps the line without the
buttons. If the file has since been moved or removed, either button says so.

Undo of a job removes the Downloads copy only while it is still the exact file
made. Its Collection history stays, as it does whenever an original is removed;
delete it from Collection if you do not want it. With `SPDF_STATE_DIR` set,
outputs go to a `Downloads` folder inside that state directory instead.

## Automatic summaries and Collection history

Choose **AI language** in setup or AI settings using the searchable dropdown.
English is the initial default; search languages by their English or native names.
The setting persists in `ai-settings.yaml` as `language`. Replies use it unless
you explicitly ask for another language in chat. That chat override does not
change the saved default for background analysis.

Each background treatment sends **one combined request** for the summary,
keywords, up to six distinct tags, and missing chapters, all in the selected
language. Tags and the summary are available under **File → Properties → AI
metadata** after analysis, and through the assistant's `document_metadata` tool.
Metadata is stored separately from the original document.

Automatic analysis is cached by source content, document layout, model, language
and prompt version. Changing language invalidates visible generated metadata and
reprocesses the current eligible document lazily. Other documents are processed
when consulted; there is no startup migration or bulk re-analysis. Returning to
an unchanged cached language reuses its metadata without another paid request.
For Collection documents it applies to the current/latest source only; an
immutable historical preview or an editable copy based on an older saved
revision does not receive a separate automatic summary. Authored bookmarks and
Markdown headings remain authoritative. Scans without extractable text are
reported as unavailable for analysis rather than given invented chapters.

The assistant's `document_metadata` tool can return Collection revision count,
date, file sizes and whether a text diff has been computed. Listing that history
reads Collection metadata only; it does not read or compare archived file
bytes. A caller can pass a specific `revisionID` to request a diff against the
preceding revision. That request lazily uses the saved text indexes. It reports
added and removed UTF-16 text units and marks the result partial. It does not
compare images or full file bytes. It checks at most 30 pages and 128,000
combined indexed text characters, with a 4 MiB read limit per index. Missing,
encrypted or oversized indexes return an explicit unavailable status and
reason; a first revision and identical revisions also have explicit statuses.

When a compatible latest-document revision changes, automatic analysis can
update its prior summary, keywords, tags and chapters using the previous analysis and
a bounded text delta, instead of resending the full excerpt. The delta is
limited to 32,000 changed UTF-16 code units. If page coverage, outline, layout
or change size is incompatible, analysis falls back to the normal bounded
excerpt. In either case, analysis remains limited to up to 30 pages and 64,000
characters. See [revision analysis validation](journals/ai-reader/revision-analysis-validation.md)
for the implementation record.

## Privacy, model use and limits

Each model request goes to OpenRouter over HTTPS and requests provider
no-data-collection and zero-data-retention routing. A model that cannot honor
those options may reject the request; ShenzhenPDF does not retry with weaker
privacy settings. These routing parameters are a request to OpenRouter, not a
claim that every network intermediary has independently verified retention
behavior. Only context needed for the current question is retrieved and sent;
automatic analysis sends its own bounded sample when separately enabled.
Document text and tool results are treated as untrusted evidence, not as
instructions. Filesystem paths are resolved locally and not included in the
model-facing tool fields.

OpenRouter account usage may incur charges or require credits, depending on the
selected model and account. ShenzhenPDF does not estimate or cap chat spending.
Automatic analysis is limited to 20 uncached requests per reader session;
cached hits do not use that allowance. It samples up to 30 pages and 64,000
characters per request, and only proposes chapters for documents without an
authored outline. Documents larger than 256 MiB, locked files and documents
without extractable text are not automatically analyzed. A changed file or
layout invalidates an in-flight result.

Chat has a 32,000-character message limit, a 160-message conversation limit,
up to 12 model/tool rounds per send, and a 400,000-byte serialized context
limit for text. Page images are requested lazily, up to four recent images and
9 MiB of PNG data per request (12 MiB after base64 encoding). Each full page or
crop has a default longest edge of 1600 pixels, configurable from 256 to 2400;
individual PNGs are capped at 8 MiB. An overview of the same page is retained alongside a detail crop, so repeated crops do not discard the drawing context. Older images can be requested again. Image
processing runs off the main thread, and no image work is added to launch or
document opening. Start a new chat or narrow the question when a limit is reached. Tool
requests are also bounded: workspace discovery returns 50 items by default
(up to 100) with independent continuation cursors for groups and documents;
page reads return at most 20 pages per call; a
cross-document search inspects at most 100 pages per document, up to 16 open
documents, and returns at most 50 matches. The result reports partial coverage
and documents/pages not reached. It does not silently stand for a full-library
search.

Other current boundaries:

- The assistant reads only documents open in this reader workspace, plus
  documents explicitly discovered and opened through Collection. These document-reading tools do not browse arbitrary folders. Native
  app commands can open normal reader dialogs, subject to macOS permissions.
  The assistant cannot browse the web, run shell commands, or access other apps.
- OCR and translation are local jobs, but the assistant does not install or
  configure their dependencies. Encrypted PDFs are not supported by assistant
  export/OCR/translation jobs.
- Safe rename supports regular writable files up to 32 MiB in their current
  folder. Collection working copies can also be renamed directly, with Undo;
  this preserves their original source reference and saved history. Read-only
  originals require the native Save As flow.
- Reversible PDF comment editing and page rotation are limited to supported
  writable PDFs up to 32 MiB. Other PDF edits are not exposed.
- There is no arbitrary original-file deletion tool. Undo is conditional on
  the result still matching the receipt; it is not a general rollback system.

See [AI control and Markdown authoring](agent-interface.md) for the separate
command-line/MCP interface. Its inspect/open commands are explicit integrations
and do not use the chat provider.

User messages have a muted blue background; assistant messages use a neutral
shade in both themes. Replies are brief by default and follow your requested
names, wording, scope and constraints.

## Evidence and concise answers

An explicit chat send supplies the active document's ID, title and page without
reading its file or scanning other documents. The assistant is instructed to
start there, choose text or rendered pages according to where the evidence lives,
and answer the user's actual question and purpose. It checks definitions, scope
and conditions, distinguishes source facts from calculations and assumptions,
and reuses readable evidence instead of repeatedly requesting it. Replies default
to 1–3 short cited sentences; a supported brief answer can use an answer card.

These instructions do not guarantee a correct interpretation. Models can still
misread an image or apply a related fact incorrectly. Citation validation checks
retrieved provenance and source revision, not whether the model's conclusion is
correct. See the [DeepSeek evaluation record](journals/ai-reader/deepseek-evidence-evaluation.md)
for observed limitations. Opaque provider reasoning blocks survive tool
continuations within a turn but are not displayed or saved in chat history.

The assistant's chat tools are `list_chats` (paged titles, folders and optional
message-search context) and `organize_chats` (up to 200 atomic operations).
`create_folder`, `move_chat`, `rename_chat` and `rename_folder` support creating
and populating a folder in one call. `organizationRevision` from `list_chats`
protects concurrent edits. A batch either commits completely or changes nothing.
