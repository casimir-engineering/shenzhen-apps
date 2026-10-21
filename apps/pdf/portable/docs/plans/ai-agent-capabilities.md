# Assistant capabilities: friends, web, subagents, Python, Markdown chat

Status: planned 2026-10-13; implementation follows Shenzhen Friends wave 4. Owner: lead integrator.
Builds on [ai-reader-architecture.md](ai-reader-architecture.md) (tool contract, privacy routing, undo) and
[shenzhen-friends.md](shenzhen-friends.md) (§ AI boundaries). Nothing here runs in the background or at launch:
every capability acts only inside a request the person typed.

## Decisions

| Topic | Decision |
|---|---|
| Reading chats | Only under a grant the person gave: an `@` chip or `/` for one request, or All Friends chats for 1 hour or until midnight (a bar in AI chat with Stop now, memory only). Checked in the tool layer at every call ([shenzhen-friends.md](shenzhen-friends.md) § AI boundaries) |
| Sending to friends | The assistant may prepare a message, and documents the person attached, for a friend the person named with an `@` chip in that request; it leaves only when the person presses Send on a card showing the exact text. Enforced in the tool layer, not the prompt |
| Web | `web_search` and `open_page` tools; queries and fetched pages leave the Mac; on by default once AI is connected, with a Settings switch |
| Subagents | One tool runs up to 4 read-only subagents in parallel, one level deep, within a step and token budget |
| Python | A sandboxed interpreter with no network, no access to the person's files, strict time, memory and output limits |
| Markdown chat | Friend messages and AI chat render with the reader's Markdown engine at chat scale: tables, code, math and diagrams like documents; remote images load only on click |

## 1. Sending to friends on request

- **Scope is the permission.** `friends_send_message` exists in a request only when the person's own message
  carries one or more `@` chips naming friends; the tool accepts only those friends. No chip, no tool. The chip
  also grants reading that friend's chat, as today. The scope ends with the request. A time grant for all chats
  (§ Reading chats under a time grant) names no friend, so it lets the assistant read but never write to anyone.
- **What can be sent.** Text (up to the protocol's 32 KiB) and documents the person attached to that request with
  `#` or by dropping; the tool cannot attach anything else. At most 3 sends per request. Text that could hide words
  from the person is refused before the card: zero-width and format characters, direction overrides, tag
  characters, variation selectors outside real emoji sequences, private-use and unassigned code points, blank
  fillers, the braille blank, a repeated combining mark or more than four on one letter, a combining mark of another
  script than its letter's (its Script_Extensions, else its Script, must share one with the letter's, unless it
  belongs to no script, like U+0338), a non-joiner anywhere it changes nothing (it counts only between an
  Arabic-script letter that joins on both sides and one that joins, or after an Indic virama before a consonant of
  its block; Unicode 18.0 tables generated for both implementations); the text is composed to NFC, compatibility
  forms like ﬁ and µ are folded, and spaces at line ends are removed. One shared file of test vectors holds the send
  check and both cards to the same rule. The script rule closes every mark measured drawing nothing on its own
  (pixel scans of 2,317 combining marks, every one not already refused as invisible, on 38 bases in AppKit and
  Pango: U+3099 and U+309A on Hangul, Bassa Vah tones on Cyrillic, Greek and Arabic); it also refuses rarer
  cross-script uses that do draw, such as θ̂ or ◌́.
  Accepted residuals: a variation base can carry one hidden choice (none, U+FE0E or U+FE0F); characters from
  different scripts that look alike (Latin K and Greek Κ) pass; two different marks drawn in the same place can hide
  one under the other (91 of 481,992 sampled two-mark stacks the rule accepts, such as U+0335 after U+1AB0 on ب, or
  half marks); a code point no installed font draws shows on AppKit cards as the one LastResort box, visible but not
  identifiable (GTK writes the code point in its box); and Foundation composes some Tulu-Tigalari vowel sequences
  (U+113C2, U+113C5) in a different order for decomposed input, so the same message typed two ways can show two
  spellings, both visible. Any refused character still on a card shows as its code point (‹U+200B›), and `/`
  drafts have them removed.
- **The person sends.** Every `friends_send_message` call becomes a card in AI chat ("Message for Mei") with the
  text as literal characters, exactly what Friends will deliver (no Markdown rendering, nothing hidden), the
  attachments, **Send** and **Discard**. Nothing is queued until Send. After Send the message appears in the Friends
  conversation like any other; while it is still queued and was never written to a connection, Cancel on the card
  or in the conversation withdraws it (helper capability `messages.cancel`); once written, it may already be on the
  friend's Mac, so Cancel is refused with that reason. The card says "Sent to Mei" once Friends reports delivery.
  Messages carry `via_assistant`, so both sides see "Via the assistant". Earlier designs let requests that read
  nothing untrusted send directly; review showed the open document's title, a friend's chosen name in a chip and
  hidden Markdown could all steer an unattended send, so every send is confirmed.
- **`/` in a conversation** never sends by itself: a command that asks to send shows the message above the
  composer with Send and Edit; a command that only prepares fills the composer as a draft. While a command is being
  typed, a line under the field says what the assistant reads and where it goes.
- **Injection.** Friend messages and documents in context can steer wording but never add recipients, attachments
  or sends beyond the limits; tests drive injected instructions through the real tool layer.

## Reading chats under a time grant

- **How it starts.** Only from AI chat's `@` picker: All Friends chats asks for how long, **This request** (the
  chip), **1 hour** or **Until tomorrow** (next local midnight). The last two start the grant
  (`SPDFMacFriendsChatGrant`), held in that window's memory only; a bar over the transcript says "The assistant can
  read all your Friends chats · 52 min left" with **Stop now** (`SPDFMacAIChatView.banner`). Nothing else starts
  one: the bar and the picker carry the `szfriends.` prefix, so `app_controls` cannot see or press them.
- **What it covers.** Every AI chat request sent while it runs gets a Friends chip carrying the grant's token
  (`SPDFMacFriendsGrantChip`), so `includesFriendsChats` is YES and every rule below for requests with Friends chats
  applies: no web tools, request-only Python, helper and Friends work, read-only once messages were read. `/` in a
  friend's conversation never reads under it.
- **How it ends.** Expiry, Stop now, Friends turned off or reset or its helper not running, and quit. The scope gate
  checks the token at every tool call and every model turn; once the grant has ended it withdraws the Friends tools,
  refuses calls ("The user's permission to read all their Friends chats has ended…"), closes the helper scope (a
  request with its own chips reopens for those chats) and stops sending excerpts already read. A later grant has a
  new token and never reopens an earlier request; a subagent's calls go through its parent's request, so they end
  with it.

## 2. Web search and pages

- `web_search(query, max_results ≤ 8)` uses OpenRouter's web search (no new account or key) and returns title,
  URL and snippet per result. `open_page(url, start?, page?, count?)` fetches one https page or PDF from this Mac,
  asking as Safari on a Mac does (Safari's user agent and Accept, the person's languages, gzip/deflate/br decoded with
  the limit on the decoded size): a page returns readable text, at most 200 KB, in parts; a PDF (by type or by its
  `%PDF-` bytes, up to 32 MB, 90 s) is saved in the app's temporary folder and read by the reader's engine a page
  range at a time, table rows kept, with an "Open in ShenzhenPDF" link by opaque id. At most 5 redirects. A page built
  by scripts says so and lists its PDF links. A sign-in page or 401 is reported, never worked around.
- **When a site refuses.** User agent "ShenzhenPDF" got 403 from bot filters (hirose.com, 21 October 2026); Safari's
  gets the page. If a site still refuses, the model gets the web_search excerpt for that address when a search found
  it, labelled as the engine's summary. OpenRouter's `openrouter:web_fetch` server tool exists (docs read 21 October
  2026) but its documentation does not say how fetched content reaches the caller, so it is not used.
- **No local network.** `open_page` refuses loopback, link-local, private and carrier-grade NAT ranges, `.local`
  and `.internal` names, and any name that resolves to them (checked after every redirect); no cookies, no
  credentials, no referrer.
- **Untrusted.** Results and pages are quoted data; they cannot call tools or change scope. Answers cite URLs.
- **Which addresses open.** `open_page` opens only addresses the person typed, results of `web_search` (OpenRouter
  citations that carry the search engine's excerpt; others are dropped) and links on pages already opened; never an
  address that appears in other tool output (refusals, Python output, helper summaries), which the model could have
  written itself. At most 3 opens per site (`www.` folded, a redirect's landing counted) and 20 per request. A
  search step shows its query; its results are links, with `http` results listed after them as not secure pages.
- **Not with Friends chats.** In a request that includes Friends chats (an `@` chip, a friend conversation or `/`,
  or a time grant running when it was sent), the web tools are not offered, to the assistant or its helpers, so
  nothing from those chats can reach a search service or a site. The model is told why; a call it makes anyway is refused and saved without its arguments.
- **Visible and switchable.** Each search and page appears in the chat as a collapsible step; a page that did not
  open says what happened and what the assistant does next. AI Settings has "Let the assistant search the web" (on):
  search terms go to OpenRouter's search service, pages are read from this Mac.

## 3. Subagents

- `run_subagents(tasks[1…4])`: each task gets its own conversation with the same model, the person's question for
  context, and read-only tools only (document search and reads, web search and pages, Python). No sending, no
  edits, no app controls, no further subagents.
- Budgets: at most 2 `run_subagents` calls per request; 48 helper turns per request shared across runs, at most 12
  per helper; 12 tool calls per helper; 600,000 tokens per run split equally between its helpers; the whole tool
  times out with its partial results. Stop cancels every helper. Starting helpers never closes the main request's
  Friends scope or its read-only rule.
- The chat shows one progress row per subagent with its title and current step; results come back as short
  summaries the main assistant cites.
- The person calls a subagent's task a "part". While a run works the heading says "Working on 3 parts…", then
  "Working on 3 parts, 1 finished…"; each row ends Done, Ran out of steps, Ran out of time, Didn't finish or Stopped.
- When to split: the tool's description and one sentence the provider adds to the main prompt while the tool is
  offered (several documents to compare or check, more than about 20 pages to summarize, several separate
  questions, web research on several items; never one quick question). Until the request has split, a message with
  two or more files on its chips, or wording such as "compare" or "each document", adds a hint (pattern match, no
  model call). Without these the model (deepseek-v4.1-flash on OpenRouter) never called the tool: the main prompt
  never named it and steers toward reading the active document and stopping early.

## 4. Python sandbox

- `run_python(code, files?)` runs in a separate process: a small signed helper in `Contents/Helpers/` applies a
  sandbox profile before starting the interpreter. Profile: no network; read access only to the interpreter, its
  standard library and installed packages; read-write only in a fresh temporary work directory; no process
  creation; no Apple events.
- Limits: 30 s wall time, 20 s CPU, 512 MB memory (a watchdog kills on footprint), 64 KB of standard output,
  10 MB of output files. The work directory is deleted afterwards.
- Interpreter: a dedicated virtual environment under Application Support with Python and numpy, pandas and
  matplotlib, installed on first use after consent, like the OCR tools; never global, never inherited
  environment variables (`spdf_mac_tool_environment`).
- Inputs are files the assistant writes into the work directory (document excerpts, tables). Outputs return as
  text, tables and images shown in the chat; images can be saved (to Downloads and Collection, as every document the
  assistant makes: document-assistant.md) or inserted into a Markdown document.
- If the sandbox cannot be applied on this macOS version, the tool is unavailable and says so; it never runs
  unsandboxed.
- **Profile, as reviewed.** Deny by default; a named sysctl allowlist; no information about other processes, no
  IOKit properties, no `fsgetpath`, nothing under `/System/Volumes` except the system cryptexes; disk use counted
  by allocated blocks, including open files the walk can't reach. Shared-memory segments the run created are
  removed afterwards. **Stated residuals** on macOS 26, which no profile rule closes: the code can create System V
  message queues and semaphores that outlive the run (it cannot use or remove anyone's); it can learn which
  processes run and their code-signing identities through `csops`; it can read the computer's name, which
  `uname` and therefore `ctypes` and numpy need.
- In a request that includes Friends chats, code, output and charts are kept for that request only; charts are not
  shown, and the step says so.

## Kept for the request only

In a request that includes Friends chats (a time grant's requests too), everything the assistant's tools did with
them is kept for that request only: Friends excerpts, Python code and output, helper tasks and findings. The saved chat keeps a stub in their
place (each call's tool name and the document pages it cited), and the rows say "Not kept after this request,
because it included your Friends chats." Providers opt in through `-isRequestOnlyTool:context:`. The assistant's
own answer is saved as written, as before: Friends' Delete history says that answers quoting those messages stay
in Chats.

## 5. Markdown in chats

- **One renderer, chat scale.** Friend messages and AI replies render through the reader's Markdown engine with
  chat options: 13 pt text, 12 pt code, headings scaled down (H1 17 pt, H2 15 pt, H3 13 pt semibold), tables
  sized to the bubble with horizontal scrolling inside it, math at text size on the text baseline, diagrams laid
  out for the bubble width with labels never below 11 pt. Same capabilities as documents: tables, task lists,
  callouts, syntax highlighting, math, Mermaid and the other diagram types.
- **Friends.** Messages travel as plain text; the recipient's app renders them. The Friends views ask the host to
  render (`SZFriendsHost` gains a Markdown rendering method; Shenzhen Files may return plain text), so the
  module stays contained. The composer sends what the person typed.
- **Safety.** Remote images never load by themselves: a placeholder with the image's host and Load image. Links
  open through a menu that shows their destination first, with a warning when the words show another site. Raw
  HTML is not executed. Each render takes at most 0.4 s, parsing included: tables, code and diagrams are drawn while
  there is time and shown as text after a note, and past that the rest of the message is plain text. A Friends
  conversation shares 1 s across all its messages; later messages show as plain text, measured once and capped at
  4 KB with Show all. Tables stop at 500 rows or 10,000 cells. Laid-out blocks are reused for the same width and
  colours.

## Verification

Every item ships with tests that fail on the old code, then an independent security review and UX critique:

- Reading chats: no grant, no Friends tools; a time grant's requests read any chat and include Friends chats;
  expiry, Stop now and Friends turned off stop the next call mid-request and close the helper scope; a later grant
  never reopens an earlier request; `/` never reads under it; the picker asks how long before granting; the bar,
  the picker and Cmd+K's Friends rows are invisible to `app_controls`; a source audit keeps chat scopes, message
  search and grants to their one place each (`mac/friends/tests/SPDFMacFriendsGrantChecks.h`,
  `SPDFMacFriendsExposureChecks.h`).
- Sending: no chip, no tool; chips limit recipients; attachments only from the person's chips; at most 3 per
  request; nothing queued without Send; every character of the delivered text visible on the card; injected
  instructions in friend messages, documents and web pages cannot add recipients or attachments; `via_assistant`
  labels on both sides.
- Web: mocked transport; private-range and DNS-rebinding refusals after redirects; size and redirect limits;
  results treated as data; invented addresses echoed through other tools refused; no web tools in requests with
  Friends chats; the saved chat holds no request-only content.
- Subagents: read-only tool set enforced; no recursion; budgets, timeout and Stop.
- Python: escape attempts fail (network, reading `~/.ssh`, writing outside the work directory, fork, infinite
  loop, memory bomb, huge output); outputs returned; work directory removed.
- Markdown: chat-scale renders of every block type in light and dark at 1× and 2×, checked by eye; no remote
  fetch without a click; a hostile diagram stays within its deadline.
