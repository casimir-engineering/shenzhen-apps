# Shenzhen Friends — implementation brief

Status: planned; implementation has not started. Owner: lead integrator.
Written 2026-10-12; revised the same day after a codebase review that added
milestones, a decision table, and defaults for the process, storage and protocol
layers grounded in existing seams, then again with the owner's decisions on
reception, relay, hosting, placement, drag and drop, automatic acceptance, the
removal of Inbox, and containment for a later Shenzhen Files port. Mockups:
[Shenzhen Friends mockups](https://claude.ai/artifact/1wVnpqnbLBEvrbg4Bv2w3z)
(private to the owner). Translation shipped separately in `9bfd15162`
([journal](../journals/translation/local-ai-choice.md)) and is no longer part of
this brief.

## Decisions

| Topic | Status | Position |
|---|---|---|
| Reception | Decided | Friends is on by default and starts at every launch; the reader spawns the helper without blocking (§ Product contract) |
| Friends ID | Decided | Two-word ID generated offline at first launch, usable nearby at once, reserved at first host contact; a collision renames the newcomer (§ Friends ID) |
| Hosting | Decided | Admin's Hong Kong server, contacted at each launch by every install with Friends on; signed host list for replicas and replacements; admin statistics (§ Friends host) |
| Relay | Decided | Online friends only, true last resort: used only after every nearby route and every direct technique (IPv6, router port mapping, UDP hole punching, hard-NAT probing, TCP) has failed; 5 Mbit/s per relayed session; no server-wide cap |
| Placement | Decided | Friends button in the title bar between Groups and Search; the list, conversations, friend details and profile all live in its dropdown, with a back arrow at the top left and the name centered; nothing docks into the window |
| Inbox | Removed | The Friends list, sorted by latest interaction, is the inbox; requests and offers are rows in it |
| Drag and drop | Decided | Drop files or tabs on the Friends button or on a friend to send them |
| Automatic acceptance | Decided | Per friend, off by default; files from that friend download without asking |
| File types | Decided | Any file can be sent; each app opens what it supports and offers Show in Finder for the rest |
| Containment | Decided | Service, client protocol, views and host adapter are separate so Shenzhen Files (GTK4) adds only views and an adapter (§ Containment and porting) |
| Shared identity | Decided | One Friends identity per Mac user, shared by ShenzhenPDF and Shenzhen Files |
| Pictures | Decided | The default picture is a cartoon animal (geese, doves, bears and more) picked at random; anyone can choose another animal or their own photo |
| AI and chats | Decided | The assistant reads Friends chats only under a grant the person gave: an `@` chip or `/` for one request, or All Friends chats for 1 hour or until midnight, shown as a bar with Stop now and held in memory only; enforced in the tool layer at every call, never automatic (§ AI boundaries) |
| Session protocol | Proposed, security ADR confirms | Noise handshake over every transport; no Double Ratchet while there is no mailbox |
| Nearby transport | Decided; spike measures | LAN, peer-to-peer Wi-Fi and Bluetooth discover in parallel; Bluetooth carries data only when no Wi-Fi route works |
| Route order | Decided | Every method is tried in parallel; data, and file transfers above all, take the best route that works, in this order: (1) direct on the same network (LAN), (2) peer to peer: Wi-Fi between the two Macs, then a direct Internet connection (IPv6, port mapping, hole punching), (3) Bluetooth, (4) the relay server. A transfer moves up to a better route the moment one connects |
| Message store | Proposed | System SQLite (WAL, FTS5) in the helper; single writer |
| Assistant sending | Decided | The assistant prepares a message only for a friend the person's request names with an `@` chip (or, for `/`, the open conversation's friend); nothing leaves until the person presses Send on a card showing the exact text; enforced in code, labelled "Via the assistant" ([plan](ai-agent-capabilities.md)) |
| Markdown messages | Decided | Messages render as Markdown at chat scale with the reader's engine through the host; remote images load only on click |
| Mentions | Decided | `@` in a Friends message names a friend; the mention opens that friend's chat. A mention of someone you aren't friends with shows the name the sender wrote, never the ID, and clicking it adds them as Add by ID would (§ Interface, Mentions) |
| File previews | Decided | Every file offer shows a thumbnail before it is accepted, for any format the sender's Mac can preview; the sender's helper makes it, the recipient only decodes a small fixed-format image (§ Transfers) |
| Links | Planned | Friend links and download links open a page that offers ShenzhenPDF or Shenzhen Files; download links also stream the file peer to peer to any browser while the sender's Mac is on ([plan](friends-links.md)) |
| Compression | Deferred | Raw bytes until a benchmark on real documents justifies a codec |
| Multi-device | Planned | One profile on several computers: join with your ID and a code, local-first sync, device list with Revoke, a You conversation ([plan](friends-multi-device.md)) |
| Shenzhen Files | Built, unreleased | Friends icon in the sidebar's title bar, right of the window buttons and just before the separator with the main view (start of the main title bar when the sidebar is hidden); one helper and one profile shared with ShenzhenPDF (§ Containment and porting) |
| Groups | Out of scope | One-to-one conversations only |

## Project-manager prompt

Implement Shenzhen Friends in ShenzhenPDF: private document sharing and messaging
alongside the reader and Collection. Prioritize responsiveness, straightforward
organization and reliable transfers. Match the existing compact native interface.
Build it as a contained feature that ShenzhenPDF hosts first and Shenzhen Files
can host later without rework: respect the module boundaries in § Containment and
porting, which a test enforces.

Work in the milestones below. M1 (nearby Friends and the host check-in) must be
complete, reviewed and releasable before online transport starts. The Friends host
runs on the admin's Hong Kong server, which also runs unrelated services: deploy
only with the admin's approval and never change those services. Do not promise
worldwide delivery; publish the tested support matrix. Reception from launch is
the one sanctioned exception to "nothing new on the launch path": keep it to a
non-blocking helper spawn and prove launch timings unchanged. Preserve the
updater; extend signing to the new helper without changing the existing
pipeline's behavior. Maintain an implementation
journal under `docs/journals/shenzhen-friends/` and commit each meaningful, tested
change. Do not interrupt the user's running app: verify with headless suites, the
two-helper harness and offscreen probes under the repository rules.

## Milestones

**M0 — Gates.** Spikes and decisions only; no product UI.

- ADRs: session protocol and library (security owner); helper lifecycle and IPC
  (lead); store schema and migrations (lead); nearby transport (transport owner);
  host API, host-list format and signing, statistics schema and retention (lead).
- Host reachability spike: from mainland China and from outside it, measure a
  WebSocket over TLS on 443 to the Hong Kong server, and STUN and TURN over UDP,
  TCP and TLS. Record what fails and how long it takes to fail.
- NAT traversal spike: between pairs of real networks (home broadband, mobile
  4G/5G with carrier-grade NAT, office, hotel or café Wi-Fi), in mainland China and
  outside it, record IPv6 availability and which direct technique connects each
  pair: IPv6, port mapping, hole punching, hard-NAT probing, TCP. Set the direct
  timeout before the relay and the keepalive interval from these numbers.
- Two-Mac spike, all three methods: Bonjour and TCP over a shared LAN; over
  peer-to-peer Wi-Fi with no shared network; Bluetooth LE advertising, scanning and
  L2CAP channels with Wi-Fi off on one Mac. Measure time to first discovery per
  method with all three running together, throughput per route, peer-to-peer Wi-Fi
  throughput with Bluetooth scanning on and off (they share the radio), reconnection
  after sleep/wake, and helper energy with scanning and advertising. Confirm the
  presence tag fits what CoreBluetooth advertises (local name and service UUIDs
  only), or fall back to reading it from a characteristic. Record which executable
  macOS names in the Local Network and Bluetooth prompts when the helper asks.
- Confirm FTS5 and the trigram tokenizer in the system SQLite on the macOS 12
  floor; otherwise vendor the amalgamation (Linux/Windows need it anyway).
- Name the hardware QA operator and secure two Macs before dates are assigned.
  These resources are not assumed to be available to coding agents.

**M1 — Nearby Friends and the Friends host.**

Identity and Friends ID, helper, store, picker (Friends / Nearby), 5-minute
visibility, Add by ID nearby, requests with comparison codes, block/remove,
name and photo, messages and links, `#` attachments, drag and drop, offers with
Accept/Decline, automatic acceptance per friend, resumable transfers, received files with
Collection open/import, conversation search and Cmd+K results, Settings
enable/disable, and the explicit delete actions. Routes: Local only, over LAN,
peer-to-peer Wi-Fi or Bluetooth. Host: check-in at launch, ID reservation, signed
host list, replica forwarding, and the admin dashboard for user counts and
host-list adoption. Nearby Friends works fully when the host is unreachable.

After M1, two independent tracks; either may go first.

- **M2 — Online friends:** Add by ID online, rendezvous over the host connection,
  direct Internet connections (IPv6, router port mapping, UDP hole punching,
  hard-NAT probing, TCP), last-resort relay, relay statistics, Online state,
  cross-border matrix.
- **Assistant:** `/` drafts in the friend composer, and asking the assistant about
  chats (§ AI boundaries).

**Next**, in order: (1) mentions (§ Interface, Mentions), file previews (§ Transfers) and the Shenzhen Files host
(GTK4 views and adapter, § Containment and porting), built together so both apps ship them; (2) M2, online friends,
whose Internet transport links and multi-device both need; (3) friend and download links
([plan](friends-links.md)); (4) multi-device ([plan](friends-multi-device.md)).

**Later**, each needing its own decision: sending folders, compression,
store-and-forward mailbox. Linux, Windows, Android and iOS clients are decided in
ADR 0015 ([plan](friends-portable-core.md)).
Retained specs are in § Deferred designs.

**Non-goals:** background login items, external notifications, read receipts,
cloud mailbox, group conversations.

## Product contract

- A **Friends** button sits in the title bar between Groups and Search. Its icon
  is two people, never a speech bubble, so it cannot be mistaken for AI chat. Its
  dropdown holds everything Friends shows, conversations included.
  Settings has **Enable Shenzhen Friends**, on by default; disabling it removes the
  button and stops everything below, including host contact.
- **Every install has an identity and a Friends ID.** At first launch the helper
  creates the identity key and a two-word ID offline, so the ID can be shared with
  nearby friends straight away. The first host contact reserves it; a collision
  gives the newcomer a new ID (§ Friends ID).
- **Reception starts at launch.** While Friends is enabled, the launching reader
  spawns the helper from a background queue immediately, without waiting for or
  delaying its first window. Readers do no Friends work on the main thread before
  first paint, then attach to the helper, so badges agree across windows. While
  disabled, nothing runs and nothing contacts the host. When the last reader exits,
  the helper persists pending work and exits. No login item.
- **The host is contacted at each launch** by every install with Friends on
  (§ Friends host). The helper stays connected while ShenzhenPDF is open.
- **Disclosure.** Settings, `readme.md`, `docs/features.md` and the release notes
  say so, written from the user's side and true for the milestone that ships. M1:
  "ShenzhenPDF connects to the Friends server whenever it is open and Friends is
  on. The server sees your network address, your Friends ID and when ShenzhenPDF is
  open. It never sees your name, messages or files." M2 adds that this lets friends reach you over the
  Internet. Recommended: show the Friends section of Settings once, to new and
  existing users, through the one-time revision the unified Settings onboarding
  already uses (`SPDFMacAISettingsIntegration.mm`), without re-running AI setup.
- One friend, one conversation, with a **Local**, **Online** or **Offline** state.
  These are routes, not separate contact lists. Local covers LAN, peer-to-peer Wi-Fi
  and Bluetooth; a person found by several methods is one row once their identity
  is verified. Losing the local route does not imply Online until an Internet
  connection succeeds. Conversations and transfers survive route changes.
- Public visibility is off by default. **Make myself visible for 5 minutes**
  enables public discovery, with a countdown and **Stop**. Expiry, sleep/wake and
  disabling never extend the deadline. Accepted friends reconnect privately without
  public visibility.
- Friend requests always need the recipient's acceptance. Block/remove works
  independently of visibility; blocked peers cannot reconnect or send offers.
- Users choose the name friends see and a picture, exchange messages and links,
  and send files. Messages are Markdown: tables, code, math and diagrams render at
  chat scale through the host's Markdown engine (plain text where a host has none);
  remote images show a placeholder until clicked. The name can be changed at any time from the Friends footer, the
  profile page or Settings; until one is chosen, friends see the Friends ID. Never
  fetch remote link previews.
- **Pictures.** Everyone starts with a cartoon animal picked at random from a
  bundled set: geese, doves, bears and others, all in one funny, friendly style.
  The profile page offers the whole set and **Use your own picture…** (choose a
  file or drop an image, then crop to the circle). An animal travels as its set
  version and number, so friends' apps draw it from their own copy; an unknown
  number falls back to a plain placeholder. Your own picture travels as a small
  re-encoded image.
- **Ask the assistant about chats, only when you ask.** In AI chat, `@` brings a
  friend's conversation, or **All Friends chats**, into that one request; `/`
  inside a conversation may read that conversation. All Friends chats can also be
  granted for **1 hour** or **Until tomorrow** (midnight), shown as a bar in AI
  chat with **Stop now**. Without one of these grants, the assistant cannot see
  Friends at all (§ AI boundaries).
- Messages from accepted friends appear without approval. Files need
  **Accept / Decline**, and no file bytes move before acceptance, unless the
  recipient turned on **Accept files from this friend automatically**. That switch
  is per friend, off by default, and turns itself off when the friend's key changes
  or the friend is blocked. Automatically accepted files get every check and limit
  a manual acceptance gets, are never opened automatically, and fall back to asking
  when disk space is short.
- Any file can be sent. Each app opens in place the formats it supports;
  ShenzhenPDF offers **Open** for documents it reads and **Show in Finder** for
  everything else. Folders are not sent in this version.
- **Drag and drop sends.** Dropping files or tabs on a friend sends them to that
  friend (§ Interface). Dropping on the Friends button opens the picker to choose
  who receives them.
- **No Inbox.** The Friends list, sorted by latest interaction, is the inbox.
  Requests and offers waiting for an answer are rows in it, and the Friends button
  carries a badge with their count. No banners, sounds, Dock badges, modal
  interruptions or automatic opening. Unread conversations carry a row marker.
- End-to-end encryption covers messages, documents, filenames, avatars and
  application metadata. Not hidden: network addresses, timing, sizes, the fact
  that a device is advertising, and, from the Friends host, when a Friends identity
  is online.

## Interface and interaction

Use the existing title-bar button, panel search field (`SPDFMacPanelSearchField`)
and row components. Preserve vector aspect ratios and sharp rendering. Every
visible button has one contiguous hit area; surrounding title-bar space stays
draggable.

**Placement.** The Friends button sits in the title bar between Groups and
Search. Its icon is two people; the AI chat icon is speech bubbles. Everything
Friends shows lives in one dropdown anchored below the button: the list,
conversations, friend details and the profile page. Nothing docks into the
window and nothing is added to the document toolbar or the left sidebar, so AI
chat and the map are unaffected.

**The dropdown.**

- About 400 pt wide; its height fits the window, up to 640 pt.
- Views stack: the list, then a conversation, then that friend's details (or the
  list, then the profile page). Every view below the list has a **back arrow at
  the top left** that goes up one level, with the friend's name or the view's
  title centered in the header; Cmd+[ does the same. When rows are
  waiting elsewhere, the back arrow carries their count.
- It closes on Escape, on a click on the Friends button, or on a click in the
  window. It stays open while you work in another app, so files can be dragged
  in from Finder or Shenzhen Files (AppKit's semi-transient popover behaviour).
- Reopening returns to the view you left, with drafts and scroll position kept.
  The back arrow always leads to the list.

The list view:

1. Search field matching the other app panels.
2. **Friends / Nearby** tabs.
3. Scrollable rows; the footer shows the name friends see (click to edit in
   place), **Your ID** with Copy, and **Add by ID**, which opens the profile page
   with the ID, QR, photo and the add field.

Friends sorts by latest interaction of any kind: a message, a file, a request or
an acceptance. Rows show avatar, name, last message or transfer preview,
timestamp and a small route icon for how the friend is connected, one per method:
waves for your network, two devices joined by a wave for direct Wi-Fi, the
Bluetooth rune, a globe for online, a server for the relay, and a crossed-out
dot when they cannot be reached; its tooltip names the route. The conversation
header shows the same icon before its route line. A row waiting for an answer says
what is waiting ("Wants to be friends", "Sent you Site photos.pdf") with a marker;
opening it shows the request or offer in the conversation view with its
buttons. **Friend requests can be answered from the list directly**: the row
carries three icon buttons in place of its time, **Accept** (check), **Decline**
(cross) and **Block** (circle with a slash), each with a tooltip and an accessible
name that includes the person's name. Block needs a second click: the first turns
the button into a red "Block?" pill; a second click within 4 seconds blocks; the
pill reverts after that, on Escape, or when the pointer leaves the row. Accepting
from the list leaves the friend unverified until codes are compared in their
details. The badge on the Friends button counts rows waiting for an answer,
identical in every window because the helper owns the count. Search matches names
and IDs. Until a name is chosen, the top of the list shows an inline field to
choose it; it never blocks the list.

Nearby shows the visibility action, remaining time and discoverable people,
filled in as each method reports. Distinguish searching, nobody visible, and each
unavailable method: Local Network access denied, Wi-Fi off, Bluetooth access
denied, Bluetooth off. When one method is unavailable and others work, show one
quiet line saying who may be missed ("Bluetooth is off. People nearby without
Wi-Fi won't appear.") rather than an error. Never present a failure as an empty
successful search.

**Conversation view.** Selecting a friend replaces the list with the
conversation inside the dropdown. The header has the back arrow on the left and
the friend's name and route state centered; clicking the name opens the
friend's details: ID, verification (compare codes), **Accept files from this
friend automatically**, Block and Remove. Conversation search sits below the
header. Messages run oldest to newest, composer at the bottom. Search jumps to the
exact message with a highlight. Transfer events stay in the same history,
including accepted, declined, cancelled and failed. A pending request shows the
comparison code with Accept, Decline and Block.

**Drag and drop.**

- Sources: reader tabs (the file and exact revision on screen), files from Finder
  and from Shenzhen Files (file URLs on the pasteboard, including file promises).
  Test Shenzhen Files as a source explicitly: it is a GTK4 app and its drags reach
  AppKit through GTK's macOS backend.
- **On a friend row** in the picker, or on an open conversation's message list:
  sends at once, one offer per file, shown in the conversation with Cancel. Cancel
  withdraws an offer nobody accepted yet and stops a running transfer.
- **On the composer:** adds attachment chips; Send sends them with the message.
- **On the Friends button:** the dropdown opens on the list while dragging
  (spring-loaded, as Finder folders do), so the drop can land on a row. Released
  on the button itself, the dropdown stays open with "Send 2 files to…" at the top
  and sends to the friend clicked next; Escape cancels.
- While dragging, the target row highlights and says "Send to Mei". Folders are
  refused with "Folders can't be sent yet".

- **#** opens a searchable picker (`SPDFMacSearchablePicker`) of items the host
  supplies: in ShenzhenPDF, open and Collection documents. Selection inserts an
  attachment chip bound to an exact revision; it transmits nothing.
- **@** opens the same searchable picker over your friends. Choosing one inserts a mention chip ("@Mei") into the
  message; it transmits nothing by itself. The picker's footer says what the recipient gets, from the sender's side
  ("Leo can click the name to open their chat with Mei, or to add Mei if they aren't friends yet"). `@` is not
  offered inside a `/` command, where `@` would mean something else to the assistant.
- **/** asks the existing agent to prepare a draft: summary, search result, chosen
  pages or another supported output. Progress is cancellable and stays in the
  friend composer. The result fills the composer as text and attachment chips with
  recipient, filenames and page ranges visible. A command that asks to send ("send
  Mei a summary of pages 3–5") shows the message above the composer with Send and
  Edit; it leaves only when the person presses Send, labelled "Via the assistant".
  Agent output never adds recipients, and attachments come only from the person's
  own `#` chips or drops.

**Mentions.** A mention carries the person's Friends ID and identity key with the name the sender wrote. Whoever
reads the message sees it resolved against their own Friends list, so a sender can't make a stranger look like a
friend:

- **One of your friends** (matched by identity key): shows your name for them, not the sender's text; clicking
  opens your chat with them.
- **You**: shows your own name, highlighted; nothing to click.
- **Someone you aren't friends with**: shows the name the sender wrote, never the ID, styled as a mention. Clicking
  opens a small card with that name, "Friends ID brave-otter" and **Add**, which sends a friend request exactly as
  Add by ID does, nearby and online, bound to the key in the mention: if that ID now belongs to a different key, no
  request is sent and the card says the link no longer matches that person. A request already sent shows "Request
  sent"; a request from them shows Accept, Decline and Block as in the list; someone you blocked shows "Blocked",
  with no Add.
- **Forged**: a mention whose ID is one of your friends' but whose key is not theirs is shown as plain text, not a
  link.

List previews, search snippets and hosts without Markdown show "@Name". The helper checks every mention
when a message arrives (an ID from the word list, a 32-byte key, a name of at most 64 characters, at most 20
mentions per message) and drops malformed ones to plain text. The mentioned person is not told; conversations stay
one-to-one. The format lives in PROTOCOL.md; a Markdown link with a dedicated scheme keeps the message plain text
for the store and search.

- Return sends; Shift+Return inserts a line. Escape closes the innermost picker
  (`#`) first, then the dropdown; it never navigates back. Renaming is inline or an
  immediate anchored editor, without animation.
- Attachments show a thumbnail, filename, type, size and status, on both sides and before the file is accepted:
  the first page of a PDF or document, the picture itself, a frame of a video, whatever the sender's Mac can
  preview. A file it can't preview shows its type's icon, drawn locally. Accepted files offer **Open**.
  Progress is determinate when possible and always cancellable.
- Over Bluetooth, offers and transfers say so and show an estimate from the link's
  measured rate ("Over Bluetooth, about 6 min"), so the recipient can accept now or
  wait. Relayed connections do the same ("Through the Friends relay, about 3 min"),
  since the relay is capped. A transfer moves to a faster route as soon as one
  connects.
- Messages and transfer records are indexed locally. Cmd+K results include
  conversation, timestamp and matching context; opening one navigates to the
  highlighted message. Cmd+K asks the helper, which runs whenever Friends is on;
  search makes no network call, and the database stays private to the helper.
- Status and error text is written for the person reading it, about what happens
  to their message: "Sends when Mei is nearby with ShenzhenPDF or Shenzhen Files open", not
  "Queued (no route)". Delivered means it reached their Mac, not that it was read.

## Architecture

### Containment and porting

Friends is one feature in four layers. Only the last is specific to ShenzhenPDF.

| Layer | What it is | Depends on | Lives in |
|---|---|---|---|
| Service | The helper: identity, store, transports, sessions, host connection, presentation state | System frameworks only (Network, CoreBluetooth, Security, SQLite) | `portable/friends/service/` |
| Client protocol | Versioned newline-JSON messages over the local socket, and a C client library | libc | `portable/friends/client/` |
| Views | The dropdown and its views (list, conversation, composer, details, profile), drop targets, Settings section | The client library and AppKit (GTK4 later) | `portable/friends/mac/` |
| Host adapter | What only the app knows | Views and the app | `portable/mac/SPDFMacFriendsHost*.mm` |

- **Logic lives in the service, not the views.** The service publishes
  display-ready snapshots: rows already sorted, labels such as "Yesterday" or
  "Over Bluetooth, about 6 min", countdown text, badge counts, and which buttons a
  row shows. Views render snapshots and send intents (send, accept, block, set
  name, search). A second toolkit reimplements drawing only. User-facing strings
  live in one catalog in the service.
- **Nothing under `portable/friends/` includes a reader header** or uses an
  `SPDF` symbol; a source-contract test fails on any. Friends code uses the
  `SZFriends` / `szfriends_` prefix (Shenzhen Files already uses `SZF`).
- **The client protocol is the stable contract:** versioned, documented in
  `portable/friends/PROTOCOL.md`, covered by golden snapshot tests. The C client
  library owns framing (newline JSON with an 8 MB cap, like `SPDFCollectionPipe`),
  reconnection and version negotiation, so AppKit and GTK hosts share it.

**Host adapter contract.** Everything Friends needs from an app goes through one
small interface:

- where the Friends button goes (the dropdown carries everything else);
- items for `#`, each with an exact revision (ShenzhenPDF: open tabs and
  Collection);
- pasteboard types to accept beyond file URLs (ShenzhenPDF: its tab drag type);
- which formats it opens in place, and how it opens or imports a received file
  (ShenzhenPDF: Collection consent and capture);
- optionally, an assistant for `/` and for scoped questions about chats (hidden
  when absent; the protocol offers scoped search and read intents) and an export
  into its own
  global search (ShenzhenPDF: Cmd+K);
- appearance tokens, so the views match the host's chrome.

**Porting to Shenzhen Files.** Shenzhen Files is GNOME Files (Nautilus) ported to
macOS: GTK4 and C, built with meson from a patch against upstream. The port:

1. embeds the same signed helper in its bundle;
2. links the C client library;
3. adds GTK4 views drawn from the same snapshots (button in the header bar, the
   same views in a `GtkPopover`, `GtkDropTarget` for files) and its adapter: `#`
   lists the selected files and the current folder, received files open in Files,
   no `/`.

No service, protocol or storage change. ShenzhenPDF's Linux frontend can reuse
those GTK views later.

**One identity per Mac user.** Both apps share the Friends identity,
friends, history, name and automatic-acceptance choices, so nobody appears twice.
State lives in `~/Library/Application Support/Shenzhen Friends/` (override:
`SZFRIENDS_STATE_DIR`), not in either app's folder. Each app embeds the helper;
the first app to start runs its copy. A client that finds an older helper asks it
to exit when idle and starts its own; the protocol stays backward compatible
across one major version. Per-app settings only say whether that app shows
Friends; the helper runs while any app with Friends on is open. Before the port,
verify that both apps' helper copies (same identifier and team) read the Keychain
item without prompting.

### Processes and IPC

Reader windows are separate processes (`agent-handoff.md` § Windows are processes),
so networking cannot live in a reader.

- A **Shenzhen Friends** helper in `Contents/Helpers/`, built and signed like the
  Collection companion (`mac/companion/sources.mk`, its own `codesign` line before
  the outer bundle). The updater replaces it with the bundle. Release packaging
  tests assert it is present and signed.
- Single instance per Mac user: the helper takes an exclusive `flock` on
  `helper.lock` in the Friends state directory before binding; a duplicate spawn
  exits at once. Spawning is race-free from any number of windows and apps.
- Clients connect through the client library to a Unix socket in a 0700
  directory. The helper checks the peer uid and, in signed builds, the peer's code
  signature. `sun_path` is limited to 104 bytes: deep `SZFRIENDS_STATE_DIR` paths
  (tests) need a short fallback path keyed by a hash of the state directory.
- The helper exits a short grace period after the last client disconnects, so tab
  detach and multi-window restore do not bounce it.
- The helper alone owns networking, keys, timers and store writes. Clients render
  snapshots and events from it.

### Storage

- In the Friends state directory: `friends.sqlite` (WAL) holding friends,
  conversations, messages, outbox, transfers, the name, automatic-acceptance
  choices and the FTS index, plus avatars and received files. Versioned
  forward-only migrations; crash recovery by transaction. The helper is the only
  reader and writer; everything else asks it.
- macOS's system SQLite costs no binary size. FTS5's default tokenizer does not
  segment Chinese: use the trigram tokenizer, with a substring scan for one- and
  two-character queries (message volumes are small). Match existing Cmd+K
  semantics; test two-character Chinese queries such as 合同.
- ShenzhenPDF's `settings.yaml` holds only `friends.enabled`, so a disabled launch
  does nothing beyond reading a file it already reads. Whether Nearby permissions
  were requested lives in the Friends store. No secrets in YAML or logs.
- History is stored unencrypted in Application Support, like chats and Collection;
  FileVault is the at-rest protection. Do not add a database encryption layer.

### Identity and keys

- The helper generates an immutable Ed25519 identity key and a separate X25519
  Noise key at its first start, linked by a signed certificate (ADR 0001). Store
  friends by identity key, never by display name, Friends ID, IP or hardware
  address. A key change needs explicit
  review and is never accepted silently.
- Only the helper creates and reads the Keychain item, so its access control names
  the helper; apps never touch it. Reads are noninteractive, using the technique of
  `SPDFMacKeychainNoninteractive.h` reimplemented inside the Friends service.
- Ad-hoc rebuilds change the designated requirement and can lose Keychain access
  (`agent-handoff.md` § release pipeline). An unreadable key shows an "identity
  unavailable" state with an explicit reset; **never regenerate silently**, which
  every friend would see as a key change. Tests and probes use
  `SZFRIENDS_STATE_DIR` with a file key store and never touch the real Keychain.
- Losing the Mac loses the identity; friends re-add and re-verify. No key backup.

### Friends ID

- **Format:** two words from a versioned, licensed list of 2,048 simple English
  words, excluding offensive, violent, technical and easily confused terms. Two
  words give 4,194,304 IDs. Define a measured occupancy and retry threshold for
  issuing three-word IDs; existing two-word IDs stay valid.
- **Offline first:** the helper picks a random ID at first start and uses it at
  once for nearby adds. Until reserved, the footer says so from the user's side:
  "You can share this now. If someone already has it, you'll get a new one the
  first time ShenzhenPDF goes online."
- **Reservation:** the first check-in reserves the ID. The main host is the only
  allocator, in one transaction, and the first reservation wins; replicas forward
  reservations to it, so two hosts can never grant the same ID. While the main host
  is unreachable, the ID stays unreserved.
- **Collision:** the newcomer's client draws another ID and retries until one is
  reserved. Friends shows, inside the picker only: "Your ID changed to maple-harbor
  because maple-river was taken." Keys, friends and history are unchanged, because
  friends are stored by key. Someone holding the old ID needs the new one; a
  request sent to the old ID reaches its current owner as a stranger's request.
- **Not proof of identity:** an ID is a public handle. Adds by ID stay unverified
  until comparison codes match; a scanned QR carries the key and is verified. IDs
  can be enumerated, so lookups reveal nothing beyond what delivering a request
  needs: no presence, no profile.
- **Unreserved duplicates nearby:** two nearby devices may briefly hold the same
  unreserved ID. Both receive a request sent to it; the requester sees whoever
  accepts, with name and comparison code.

### Session protocol

Every route is a reliable byte stream: TCP on LAN and peer-to-peer Wi-Fi, an L2CAP
channel on Bluetooth, a WebRTC data channel on the Internet, TURN underneath when
relayed. Security lives above the stream, identical on every route:

- A **Noise** handshake authenticates both identity keys and gives each session
  forward secrecy: XX for first contact, IK for known friends. Unknown or blocked
  static keys are rejected before any application frame. Rekey on volume and time.
- Transport TLS/DTLS remains, but friend authentication no longer depends on binding
  certificate fingerprints into signaling; substituted negotiation data fails the
  Noise handshake. Rendezvous records are still signed to prevent misdirection.
- No Double Ratchet: without a mailbox, delivery requires both peers online, so the
  asynchronous problem a ratchet solves does not arise. A future mailbox reopens
  this ADR and uses a maintained ratchet library, never a new one.
- The security ADR names the implementation (candidates: noise-c, MIT; or a
  reviewed implementation over libsodium validated against published Noise test
  vectors), licensing, maintenance, replay and key-change handling, and the threat
  model. No invented primitives. The security reviewer is not the protocol author.
- Frames are versioned and length-prefixed with a hard size limit. Unknown frame
  types are rejected; unknown fields ignored. Message IDs are random 128-bit values
  from the sender; the recipient deduplicates by sender key and ID and acknowledges
  only after its transaction commits. Display order is sender timestamp, then ID.
- File chunks travel in the same session with authenticated offset and length.
  Resume restarts from the recipient's verified byte count, bound to offer ID,
  sender, recipient and content hash. The final digest must match the offer. The
  same mechanism moves a transfer between routes. Chunk size adapts to the route,
  since L2CAP has a far smaller useful payload than TCP.

### Nearby

**Adapters.** Two, started together on activation and after wake, each independent:

- **Network.framework:** one browser and listener with `includePeerToPeer`,
  covering LAN and peer-to-peer Wi-Fi (the link AirDrop uses: nearby Macs with no
  shared network, at Wi-Fi speed). Classify the route from each result's interface.
- **CoreBluetooth:** scanning filtered by service UUID with duplicates off,
  advertising, and L2CAP channels (`publishL2CAPChannel`, `openL2CAPChannel`) in the
  same helper. Multipeer Connectivity does not use Bluetooth on macOS, hence a
  separate adapter.

**Parallel discovery.**

- No method waits for another. One that is denied, off or failing never delays or
  hides the others' results; it reports its own state and starts by itself when
  its radio or permission becomes available.
- Each adapter reports sightings to one **discovery merger** in the helper: a pure
  component with no radios, tested with scripted adapters (simultaneous,
  out-of-order, flapping and expiring sightings).
- Sightings carry the presence tag, so a friend seen over Wi-Fi and Bluetooth is
  one candidate before any connection. A stranger appears in Nearby only after a
  handshake on some route has returned their key and profile, which keeps one row
  per person.
- Each method's sighting expires on its own timer; a row disappears only when all
  have expired. Brief losses do not flip the route icon.
- Bluetooth addresses and Bonjour instance names are never identity.

**Connecting and route choice.**

- A friend sighted on several methods is dialed on all of them at once, staggered
  slightly in favor of faster routes (LAN, then peer-to-peer Wi-Fi, then Bluetooth).
  The first completed handshake carries traffic at once; slower attempts continue
  only to find a faster route, then close.
- A Bluetooth sighting triggers immediate Wi-Fi attempts. Bluetooth carries
  messages and files only while no Wi-Fi route works, and the session moves to Wi-Fi
  as soon as one connects.
- One session per friend. When both sides dial at once, or on several routes, keep
  the session started by the lower identity key and close the other, so no frame is
  sent twice. Outbox deduplication covers the rest.
- With online friends (M2), the direct Internet attempt runs in parallel with
  nearby discovery; local routes win ties. The relay is the one exception: it
  starts only after every other route has failed.

**Private presence** (proposed default for the ADR): Bonjour TXT records and
Bluetooth advertisements carry a tag computed from a presence secret and the current
15-minute window. Friends receive the secret on acceptance, match tags locally,
then connect with IK. Strangers see unlinkable values. Rotate the secret on remove
or block. If the tag cannot travel in a Bluetooth advertisement, read it from a
characteristic after connecting (spike decides).

**Public visibility:** for those 5 minutes only, both adapters also advertise a
public entry that accepts XX and serves the chosen name and avatar, so people
nearby without shared Wi-Fi find you over Bluetooth. The deadline stops it on both
at once. Otherwise listeners answer only IK from a known, unblocked key and reveal
nothing else.

**Add by ID nearby** (proposed default for the ADR): the requester opens a Noise NN
session, encrypted but revealing no static key, to each nearby Friends device and
sends a signed request for that ID. Only a device holding the ID adds it to its Friends list as a request;
every device answers identically, so the requester learns nothing about who is
nearby. The requester sees "Request sent" and the outbox keeps retrying nearby
(and, with M2, online). On acceptance the recipient connects back with IK and both
sides see the comparison code. Rate-limit incoming requests per sender key.

**Verification:** nearby requests show a six-digit comparison code on both
screens, bound to the handshake and exchanged commit-then-reveal (ADR 0001) so a
man in the middle cannot steer both codes to match. Contacts stay **unverified** until a user confirms the
codes match. Acceptance alone does not prove real-world identity.

**Permissions:** `NSLocalNetworkUsageDescription`, `NSBonjourServices` and
`NSBluetoothAlwaysUsageDescription` in whichever bundle macOS attributes the
requests to (spike decides). Prompts appear only when the user first opens Friends,
never from launch activation. Until then, launch activation runs the host
connection only: Local Network access has no query API and browsing is what
prompts, so the Network.framework adapter starts at launch only once the settings
flag records that the user was asked. CoreBluetooth reports an undetermined
permission before a manager exists (creating one prompts), so that adapter is
skipped the same way.

### Friends host

The admin's Hong Kong server, reachable from mainland China and abroad (confirmed
by the M0 spike). Service code lives in `portable/server/friends/` with its own
tests and a protocol version shared with the app. It runs as its own container
stack behind the server's existing HTTPS ingress, touching no other service. TURN
needs public UDP and TCP ports of its own; it cannot sit behind an HTTP proxy.
There is no server-wide relay cap; the dashboard shows relay bytes per day.

**Check-in at launch.**

- When the helper starts, it opens one WebSocket over TLS on port 443 to the
  highest-priority reachable host in its list and keeps it open while ShenzhenPDF
  runs, reconnecting with jittered backoff. One connection per Mac however many
  reader windows are open; readers never contact the host. Nothing on a reader's
  main thread waits for it.
- The client signs a fresh server challenge with its identity key, so nobody can
  inflate counts or appear online as someone else.
- Check-in sends the identity public key, the Friends ID (to reserve it if not yet
  reserved), app and protocol versions, and the host-list version held. The host
  replies with the reservation result and a newer signed list if one exists. In M2
  the same connection delivers friend requests and incoming connection requests.
- The host can tell an outdated protocol version that online Friends needs an
  update; reading and nearby Friends keep working.
- When no host is reachable, Nearby is unaffected, no route claims Online, and the
  helper retries quietly.

**Signed host list.**

- JSON: a version that only increases, issue time, and entries (role: rendezvous,
  relay or both; URLs; TURN URIs; region; priority).
- Signed offline with an Ed25519 admin key that never lives on a host. The app pins
  two public keys, primary and backup, so a lost key is replaced by a release.
  The signing CLI lives in `portable/server/friends/tools/` and runs on the admin's
  machine.
- Clients reject unsigned, invalid or older lists, cache the newest in
  `friends/hosts.json`, and fall back to a bootstrap list in the app bundle. The
  signature, not the server, makes a list trustworthy, so any host or mirror can
  serve it.
- After the main host publishes a version, every host pushes a "new list" notice
  over open connections: connected users switch within seconds, everyone else at
  their next launch.

**Replicas and replacement.**

- Every host in the list runs the same service. An alternate replicates the main
  host or replaces it by taking priority 1 in the next list.
- Hosts forward rendezvous registrations to the other hosts in the current list,
  so a client on any host can be found from any other. ID reservations go to the
  main host, the only allocator. Relays share only the credential secret.
- Replicas report statistics to the main host, which deduplicates unique users
  across hosts by identity hash.
- A compromised host sees metadata and can deny service. It cannot read or forge
  messages (Noise authenticates friends end to end) or redirect clients (the list
  key is offline).

**Admin statistics.** A dashboard on the main host, behind admin authentication
and reachable only over SSH or the admin's VPN, never the public Internet:

- **Unique users:** distinct identities that checked in, per day, 7 days, 30 days
  and all time. Friends is on by default, so this approximates active installs.
- **IDs:** reserved IDs, collisions and renames per day, and occupancy of the
  two-word space against the three-word threshold.
- **Current users:** open connections now, per host and in total, with history.
- **Host-list adoption:** for each list version, users and the percentage of users
  active in the last 30 days whose latest check-in reported it; the same for users
  connected now.
- **Relay (M2):** relayed sessions now; sessions and bytes per day; average and peak
  rate; sessions held at the cap; the share of Internet connections that needed the
  relay; per relay host. Derived from signaling and credential requests on the host
  and coturn's metrics. Clients send no extra telemetry.
- **App versions** in use, from the same check-in, to decide when an old protocol
  can be retired.

**Stored on the host:** per identity, the identity public key and its reserved ID
(needed to deliver requests by ID), first and last check-in dates, latest
host-list and app versions; daily aggregates. No IP
addresses beyond short-lived rate-limit memory, no record of who contacts whom, no
per-pair traffic, in the database or the logs. Identity rows unseen for 12 months
are deleted, which also releases their ID; daily aggregates are kept.

### Online friends (M2)

- **Add by ID online:** the request runs in parallel with the nearby attempt. The
  host looks up the reserved ID and forwards the request, sealed to the recipient's
  identity key, over the recipient's open connection; nothing is stored, and the
  sender's outbox retries while the recipient is offline. The host could substitute
  a key here, which is why ID adds stay unverified until comparison codes match. A
  QR carries the key itself, so QR adds are verified and need no lookup.
- **Rendezvous** over the host connection: expiring records keyed by a hash of the
  identity key and signed by it, holding connection candidates only. Rate-limit
  lookups and requests; lookups expose no presence or profile. Requests to an
  offline person are not stored; the sender's outbox retries.
- **Connection order.** The relay is the true last resort; every other way is
  tried first, in parallel wherever possible:
  1. Nearby discovery and the Internet attempt start together; local routes win
     ties.
  2. **Direct over the Internet.** ICE gathers and checks every candidate below at
     once; no relay candidate exists in this phase.
     - **IPv6:** global addresses often connect directly with no NAT at all, and
       mainland mobile networks widely hand them out. Always gather them.
     - **Router port mapping:** ask the home router for a public port with PCP,
       NAT-PMP or UPnP IGD and offer it as a candidate; release it when the session
       ends.
     - **UDP hole punching:** server-reflexive candidates from STUN on the Friends
       hosts, with simultaneous checks from both sides coordinated over the host
       connection. Handle hairpinning when both peers share one public address.
     - **Hard NATs:** when a side's mapping changes per destination (symmetric or
       carrier-grade NAT), try port prediction and many-port probing (the
       birthday technique), bounded in packets and time, after the plain checks
       fail.
     - **TCP:** ICE-TCP candidates, including simultaneous open, for networks that
       block UDP.
     - Third-party public STUN servers are often unreachable from mainland China;
       never depend on them.
  3. **Relay, last resort:** only when no local route exists and every direct
     technique has failed within the timeout the spike sets. Then the helper
     requests short-lived relay credentials and connects with relay candidates
     only.
  4. **Leave the relay as soon as possible.** While relayed, keep trying local and
     direct routes: again after any network change, and periodically. Move off the
     relay the moment one connects, resuming any transfer.
  - Keep punched UDP mappings alive with keepalives at an interval the spike
    measures, so an idle direct path does not fall back to the relay.
  - Record which technique connected each session in a local log, for the spike
    and the support matrix.
- **Relay:** coturn with time-limited shared-secret credentials issued by the host
  per attempt. **5 Mbit/s per relayed session**, each direction (`max-bps=625000`;
  coturn counts bytes per second); no server-wide cap. Carries Noise ciphertext only
  and stores nothing. If the relay also fails, the friend shows as
  unreachable and the queue is kept. Never fall back to cleartext.
- **Native transport:** candidate libdatachannel, subject to license, binary-size,
  ICE-backend and security review. The ICE backend must support every technique
  above: its default, libjuice, is UDP-only, so ICE-TCP needs the libnice backend
  or a separate TCP path; the ADR decides. Port mapping candidates: miniupnpc and
  libnatpmp, or a PCP implementation. No browser engine. Wire formats stay
  portable for later Linux, Windows and mobile clients.
- **Cross-border:** test real peers in mainland China and outside it through the
  Hong Kong host; publish the tested support matrix with explicit failure states.

### Outbox and delivery

Queue on the sender: **Queued**, **Connecting**, **Sending**, **Delivered**,
**Failed**. Delivered requires the recipient's durable acknowledgement, not a
signaling or socket success. Requests, messages and offers share the outbox. Retries
are idempotent.

Removing or blocking someone tells them nothing. Items that stay unsent for 30
days, for that or any other reason, become **Failed** with "Not delivered in 30
days" and **Try again**, so nothing waits forever without saying so.

### Transfers

- On Send, bind each attachment to an immutable revision or verified snapshot; never
  substitute a newer source. Report a missing source or insufficient storage
  before offering.
- Offers carry encrypted name, format, size and content hash. Reject unsolicited
  chunks, stale acceptances, oversized metadata and offer floods before allocating
  large buffers.
- Stream accepted files to a private temporary file; publish into
  `friends/received/` only after digest verification. Sanitize filenames; prevent
  traversal, symlink escapes and overwrites. Set the quarantine attribute on
  received files. Never execute or render received content before acceptance.
- **Thumbnails before acceptance.** The sender's helper renders each attachment with the system thumbnailer
  (QuickLook on macOS) off the main thread, at most 2 s, and never delays the offer: no thumbnail by then means
  none. It is encoded in one small fixed format (QOI: a few hundred lines to decode, nothing like a general image
  library), at most 192 px on the longest side and 64 KB, smaller steps tried until it fits. It travels in its own
  encrypted frame after the offer, behind queued messages, and is stored with the offer so the outbox can deliver
  it later. The recipient's helper accepts at most one per pending offer from that friend, checks size and
  dimensions before allocating, decodes with its own bounds-checked decoder (fuzzed with sanitizers), and writes a
  PNG it encodes itself into its cache; views only ever load that local file. The thumbnail is the sender's
  picture of the file, not proof of its contents: once the file arrives and its digest checks, a thumbnail made
  locally from the real file replaces it. Thumbnails of declined, cancelled or expired offers are deleted.
- Pictures: animals are a set version and index, validated against the bundled
  set. Own pictures have strict size and dimension limits, are decoded by ImageIO
  in the helper and re-encoded to a fixed size. A picture grants no consent to
  documents.
- The animal set ships in the Friends module as vector sources (SVG, which GTK
  draws natively) plus generated PDF assets for AppKit, crisp at 1× and 2× from
  28 pt to 64 pt, each animal on its own colored circle so it reads in light and
  dark. A script regenerates the PDFs; the build never needs the converter.
- Open and import go through the host adapter; in ShenzhenPDF, the existing
  Collection consent and capture rules.
  Incoming files never overwrite a source.
- Cancel stops remaining work and removes incomplete files. It cannot retract what
  already arrived; do not label it Undo.
- Disable stops discovery, connections and host contact and hides the icon;
  identity, history and queued drafts remain. Deleting history and deleting identity are separate
  explicit actions.

### AI boundaries

Incoming messages and documents are untrusted input, never authority for AI
actions. OpenRouter processing is separate from the friend channel.

**Asking about chats: grants are the only way in.** The assistant reads a Friends
chat only under a grant the person gave. There are two kinds, and no other way to
grant: no setting, no tool, no app control and no text in a message or document
makes one.

- **For one request.** In AI chat, `@` opens a picker of friends plus **All
  Friends chats**; a friend becomes a chip on that one message ("What did @Mei say
  about delivery dates?"). In a friend conversation, `/` may read that
  conversation; other conversations still need an `@` chip. The grant ends with
  that request; follow-up messages need their own chip.
- **For a while, all chats.** Choosing **All Friends chats** asks for how long:
  **This request** (a chip, as above), **1 hour** or **Until tomorrow** (the next
  local midnight). The last two start a time grant: AI chat shows a bar, "The
  assistant can read all your Friends chats · 52 min left" (or "until midnight")
  with **Stop now**, and every AI chat request sent while it runs may read any
  chat. It ends at expiry, on Stop now, when Friends is turned off or reset or
  its helper stops running, and on quit. It lives in that window's memory only:
  nothing saves it, so no launch starts with one, and other windows do not have
  it. `/` in a friend's conversation never reads under it.
- **Enforced in the tool layer, not by the prompt.** The host's AI tool layer
  offers the Friends tools (search chats, read messages around a hit) only to a
  request with a grant, and every call is limited to the granted conversations;
  a request without one has no Friends tools at all, and a call is refused before
  it reaches the helper. A request made under a time grant carries that grant's
  token, and the token is checked at every tool call and every model turn: once
  the grant has ended, the tools are withdrawn, calls are refused, the helper
  scope is closed (a request with chips of its own falls back to those chats),
  and excerpts already read stop being sent. A grant given later has a new token,
  so it never reopens a request made under an earlier one.
- **A time-granted request is a request with Friends chats in every respect.** It
  carries a Friends chip, so web search and pages are not offered, Python output,
  helper tasks and excerpts are kept for the request only, a request that read
  messages may only read, and the assistant can prepare messages for no one
  (sending still needs a friend's own chip). Subagents never have Friends tools;
  they work inside their parent request and get nothing past its grant.
- Tools return bounded excerpts with sender, time and a message link, never whole
  histories. Answers cite messages; clicking a citation opens the dropdown at the
  highlighted message. Files received from friends are documents: the assistant
  reads them only like any other document, when the request reaches them.
- The composer says before sending that the chosen chats go to OpenRouter for
  this request, with the same no-training, zero-retention routing as other AI
  requests; the time grant's bar says the same on hover.
- Friend messages are quoted as data; text in them cannot call tools, widen the
  scope, start or extend a grant, or change settings.
- **Other paths, audited** (tests in `mac/friends/tests/SPDFMacFriendsGrantChecks.h`
  and `SPDFMacFriendsExposureChecks.h`):
  - Cmd+K: Friends results go to the palette only, for the person; "Ask AI about
    this…" passes the typed query, never the rows. A source check fails if any
    other code opens chat scopes, searches messages, starts a time grant or reads
    the palette's Friends rows.
  - `app_controls`: every Friends view, the `@` picker and the grant bar carry the
    `szfriends.` identifier prefix, so the assistant cannot list or press them;
    Friends rows in Cmd+K are labels, which it never lists.
  - Saved AI chats: excerpts read under any grant are replaced in the chat file by
    stubs holding message ids, never text; a later request rereads them only
    while its own grant covers them.
  - Received files: documents, read only like any other document when a request
    reaches them; not chats.
  - Drafts: AI chat drafts are the person's own text and keep no chips, so a
    restored draft grants nothing; Friends drafts stay in the Friends composer,
    which no AI tool reads.
  - Notifications: Friends has none outside its button and rows, which
    `app_controls` cannot see.
- No background AI on Friends: no automatic summaries, indexing to a provider or
  analysis of incoming content.

**Sending for the person.** The assistant can prepare a message, and documents the
person attached, only for friends the person named with an `@` chip in that request
(in AI chat) or for the open conversation's friend when a `/` command asks to send.
The tool layer enforces it: no chip, no send tool; at most 3 per request;
attachments only from the person's own chips. Nothing is sent until the person
presses Send on a card that shows exactly the characters Friends will deliver. Each
message shows in both chats with "Via the assistant" (carried as `via_assistant`).
Injected text in friend messages, documents or web pages can change wording but
never recipients, attachments or the limits. Details:
[ai-agent-capabilities.md](ai-agent-capabilities.md).

## Testing strategy

1. **Pure units**, headless in the house style: frame codec, word-list validation
   and ID generation,
   presence tags, discovery merger, route racing and session tie-break, filename
   sanitizer, offer validation, outbox state machine, host-list verification and
   rollback rejection, relay-phase decision.
2. **Fake streams** with fault injection (truncation, corruption, disconnect
   mid-chunk, delay) driving the session layer and transfers.
3. **Two-helper harness** (`make mac-friends-e2e-tests`): two real helpers with
   separate `SZFRIENDS_STATE_DIR` and file key stores over loopback, including Bonjour.
   Covers requests, messages, offers, resume after `kill -9` mid-transfer, restart,
   duplicates and two reader clients per helper. No Keychain, no external network.
   One Mac cannot discover itself over Bluetooth, so the harness substitutes a
   scripted Bluetooth adapter with a slow, small-payload stream; it still exercises
   parallel discovery, racing and moving a transfer between routes.
4. **Host harness:** the host service and coturn run locally in containers for
   helper tests: check-in, ID reservation including two Macs racing for one ID
   through different replicas, collision renames, list updates and rejected
   rollbacks, failover to an alternate, replica forwarding, statistics against a
   scripted population of
   launches, windows, quits and crashes, and (M2) the relay used only after
   scripted direct failures, with the cap measured on real coturn. Never the
   production host.
5. **UI against a fake helper** for dropdown, navigation and keyboard work in
   parallel.
   The fake replays recorded snapshots from the protocol's golden files, so the
   same fixtures will drive GTK views later.
6. **Containment:** a source-contract test fails if anything under
   `portable/friends/` includes a reader header or uses an `SPDF` symbol, and a
   protocol test checks every golden snapshot against `PROTOCOL.md`.
7. **Drag and drop:** headless pasteboard tests for file URLs, file promises and
   the reader's tab type on rows, the composer and the Friends button; folder
   refusal; spring-loading. Shenzhen Files and Finder as real sources run on the
   hardware matrix.
8. **Hardware matrix**, only for what needs it: peer-to-peer Wi-Fi, real Bluetooth,
   radio coexistence, permission prompts, sleep/wake, real NATs, cross-border,
   drags from Finder and Shenzhen Files.
   Unrun rows are release blockers, never assumed passes.

## Release gates

M1:

| Area | Required evidence |
|---|---|
| Launch | Disabled: zero helper, sockets, Bluetooth managers, timers, Keychain, database, index or host contact. Enabled (default): the reader's only launch work is a non-blocking spawn off the main thread; launch-to-first-window median and p95 with Friends on match Friends off within noise; one check-in per launch however many windows restore; no permission prompt at launch for someone who never opened Friends. Instrumented tests, not source assertions alone |
| Performance | Same-machine baseline vs candidate launch and document-open median and p95; no new synchronous reader work; helper idle CPU, wakeups, RSS and energy with all discovery running; bounded transfer memory |
| UI latency | Cached picker, selection and search respond without the network; first feedback within 100 ms on reference hardware; report dataset sizes and p95 |
| Discovery | All three methods start together; each denied or off method leaves the others' time to first result unchanged; one row per person across methods; visibility expiry stops every method; sleep/wake; two hidden friends reconnect privately, over Bluetooth alone with Wi-Fi off, while a third device nearby cannot identify or profile them |
| Routes | Two Macs on one Wi-Fi, Wi-Fi plus Ethernet, different networks (peer-to-peer Wi-Fi), Wi-Fi off on one Mac (Bluetooth only), Bluetooth off or denied, Local Network denied; route icon matches the working route |
| Delivery | Outbox states, duplicates, simultaneous dialing on several routes, two reader windows on one helper, crash/restart/resume, a transfer moving from Bluetooth to Wi-Fi mid-file, decline/cancel, source deleted or changed, low disk |
| Security | Key substitution and changes, blocked peers, stale tokens and acceptances, unsolicited chunks, offer floods, malformed or oversized metadata, replay, corrupted chunks, traversal, malformed avatars |
| Search | Messages and transfer records survive restart; exact highlighted Cmd+K destination; Chinese two-character queries; `#` binds a revision |
| Native UX | Friends button between Groups and Search; nothing added to the document toolbar or sidebar; back arrow at the top left of every view below the list goes up one level, name centered; the dropdown stays open during drags from other apps and reopens where it was left; it fits short windows; first-click full hit bounds, no drag-region overlap, keyboard and Escape, light/dark, narrow/wide, long names, 1×/2× icons; no external notifications |
| Drag and drop | Drops of tabs, Finder files and Shenzhen Files files on a row, a conversation, the composer and the Friends button do what § Interface says; spring-loading; folders refused; one offer per file; Cancel withdraws an unaccepted offer |
| File previews | Offers show thumbnails before acceptance for PDF, Markdown, Office, image, video and unknown files; oversized, malformed and unsolicited thumbnails are refused before allocation; the decoder survives a sanitizer fuzz run; the local thumbnail replaces the sent one after the digest checks; declined offers leave no thumbnail |
| Mentions | Friends, strangers, yourself and forged mentions render as § Interface says; Add from a mention is bound to the mentioned key; previews and search show "@Name" |
| Automatic acceptance | Off by default; per friend; turns off on key change and block; same checks and limits as manual acceptance; asks when disk space is short; never opens a file |
| Containment | No reader header or `SPDF` symbol under `portable/friends/`; golden snapshots match `PROTOCOL.md`; views hold no sorting, labelling or state logic beyond rendering |
| Friends ID | Offline ID usable nearby before any host contact; reservation at first check-in; concurrent reservations of one ID through different hosts grant it once; the newcomer is renamed and told, with friends and history intact; requests by ID nearby reveal nobody's presence |
| Host | Check-in from mainland China and outside it; list update, rollback and bad-signature rejection; failover when the main host is unreachable; unique and current counts correct across windows, quits, crashes and replicas; adoption percentages match a scripted population; dashboard unreachable from the public Internet; no IP addresses in the database or logs; Nearby unaffected with the host down |
| Packaging | Helper signed and notarized; Local Network and Bluetooth usage strings; updater replaces the helper; identity-unavailable state; updater and signing tests unchanged otherwise |
| Release | Protocol and security docs, journal, user features and AI controls documented separately; libsodium (ISC), cJSON (MIT) and EFF word list (CC BY) notices shipped with the app; meaningful tested commits |

M2 adds: distinct NATs, CGNAT, IPv4/IPv6, blocked UDP, restricted networks,
China↔China and China↔outside; each direct technique proven on at least one real
network pair where the simpler ones fail; the relay is never used while any local
or direct route works, and is used when they all fail; 5 Mbit/s measured per
relayed session; moving off the relay when a direct route appears, including after
a network change; relay statistics match coturn's
counters; rendezvous signature checks, expiry and rate limits; the published
support matrix. The Assistant track adds: `/` cancels, preserves scope, never
sends, and never adds recipients; a request without an `@` scope gets no Friends
tools (instrumented, not prompt-checked); scoped calls cannot read outside the
scope; injected instructions in friend messages call no tools.

Independent UX critic: rank actionable findings by impact; grade visual
consistency, hierarchy, density, clarity and accessibility. At most four iterations
toward at least 9/10. Grades cannot override failing functional, security or
performance tests.

## Agent allocation

Maximum four active agents, including the lead. Freeze IPC contracts, schemas and
the fake helper before parallel work. Each agent owns distinct file families; only
the lead edits shared coordinator declarations, registries and build wiring.

| Phase | Lead/integrator | Worker 1 | Worker 2 | Worker 3 |
|---|---|---|---|---|
| M0 Gates | Lifecycle/IPC, store and host ADRs; client protocol, snapshot schema and `PROTOCOL.md`; fake helper | macOS 12 SQLite check; store prototype | Session-protocol ADR; nearby and host reachability spikes with the hardware operator | UX spec and copy; licensed word list; picker against fake helper |
| M1 Build | Helper lifecycle, C client library, ShenzhenPDF host adapter, wiring, build and signing; host service, ID reservation, list signing and check-in | Identity, store, outbox, presentation snapshots, transfer staging and received files, automatic acceptance, search | Session layer, discovery merger, route racing, Network.framework and Bluetooth adapters | AppKit views, drag and drop, `#` picker, keyboard, accessibility; admin dashboard |
| M1 Verify | Audit and release notes | Independent security review | Performance, regression and two-Mac QA | Independent UX critic |
| Tracks | Integration; rendezvous and relay on the host | `/` drafts | Internet transport, direct and relay phases | Online-state UI; relay statistics; cross-border QA coordination |

Use the strongest agents for protocol and security decisions and independent
review; lower-cost agents for fixtures, index adapters, documentation and
mechanical tests once interfaces are stable. Do not duplicate network experiments
or run concurrent heavy builds. Do not mark Friends complete at a mockup or demo.

## Deferred designs

Kept so earlier decisions are not lost; each needs its own approval.

- **Compression:** benchmark Zstandard on the user's real document mix; most PDFs
  are already compressed. Compress before encryption, skip incompressible data,
  bound memory and output, reject bombs, never share a context across unrelated
  secrets and attacker-controlled data.
- **Mailbox:** host storage of ciphertext for offline delivery. Requires an
  asynchronous ratchet from a maintained library and storage on the host.

## Technical sources

- [Apple networking API guidance (TN3151)](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [Local network privacy (TN3179)](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Network framework](https://developer.apple.com/documentation/network) and [`includePeerToPeer`](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer)
- [MultipeerConnectivity platform transports](https://developer.apple.com/documentation/multipeerconnectivity)
- [CoreBluetooth](https://developer.apple.com/documentation/corebluetooth) and [L2CAP publishing](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/publishl2capchannel%28withencryption%3A%29)
- [Noise Protocol Framework](https://noiseprotocol.org/noise.html) and [noise-c](https://github.com/rweather/noise-c)
- [libsodium](https://doc.libsodium.org/)
- [SQLite FTS5, including the trigram tokenizer](https://www.sqlite.org/fts5.html)
- [WebRTC TURN rationale](https://webrtc.org/getting-started/turn-server) and [TURN standard](https://www.rfc-editor.org/rfc/rfc8656.html)
- [coturn](https://github.com/coturn/coturn) (`max-bps` is per session, in bytes per second)
- [How NAT traversal works](https://tailscale.com/blog/how-nat-traversal-works) (port mapping, hole punching, hard NATs) and [PCP, RFC 6887](https://www.rfc-editor.org/rfc/rfc6887.html)
- [libdatachannel](https://github.com/paullouisageneau/libdatachannel) and [C API/backend limitations](https://libdatachannel.org/pages/reference.html)
- Deferred: [Double Ratchet](https://signal.org/docs/specifications/doubleratchet/), [Zstandard](https://github.com/facebook/zstd)
