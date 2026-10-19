# Shenzhen Friends client protocol, version 1.0

The contract between the Friends helper and every app that shows Friends: ShenzhenPDF's AppKit views and Shenzhen
Files' GTK4 views. It is complete enough that the helper, the C client library, the AppKit views and the GTK views
can be built without talking to one another. When code and this document disagree, one of
them is a bug; decide which and fix it in the same change.

- [Principles](#principles)
- [Transport](#transport)
- [Framing](#framing)
- [Lifecycle](#lifecycle)
- [Handshake](#handshake)
- [Capabilities](#capabilities)
- [Intents](#intents)
- [Replies and errors](#replies-and-errors)
- [Snapshots](#snapshots)
- [Views](#views)
- [Shared objects](#shared-objects)
- [Mentions](#mentions)
- [Thumbnails](#thumbnails)
- [Links](#links)
- [Devices](#devices)
- [Static strings](#static-strings)
- [Limits](#limits)
- [Schemas](#schemas)
- [Changing this protocol](#changing-this-protocol)

## Principles

- **The helper decides; views render.** Snapshots are display-ready: rows already sorted, labels such as
  "Yesterday" or "Over Bluetooth, about 6 min", countdown text, badge counts and which buttons show. A view
  never sorts, counts, formats a time or a size, or decides whether a button appears. The only formatting a
  view does is filling the placeholders § Static strings names: `{name}` and `{count}` in the four drag strings,
  `{host}` and `{shown}` in the link warning.
- **Every user-facing string comes from the helper's catalog**, written for the person reading it, about what happens to
  their message: "Sends when Mei is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open", never "Queued (no
  route)". Three exceptions exist because no helper is there to supply them: the client library's connection-state
  lines, the host adapter's Settings checkbox and disclosure (shown while Friends is off), and the host's `#` picker
  placeholder, which names what that host offers.
- **Strings are plain text.** Names, messages and file names come from other people. Views never interpret any
  string as markup (Pango markup, HTML, attributed-string formats). The only formatting is the rich-text
  segment array (§ Shared objects). Text may contain line breaks; render them as line breaks. One exception: a
  message's `text` marked `text_format` `markdown` is the Markdown its sender typed, and the host renders it with
  its own Markdown renderer at chat scale, or shows it as plain text when it has none (§ Views, `conversation`).
- **Unknown is ignored, never fatal.** Receivers ignore unknown fields, unknown event types and unknown action
  names (a view hides an action it does not know). The helper answers an unknown intent with `unknown_intent`.
- **Intents never queue in the client.** An intent sent while disconnected fails at once with `not_ready`; the
  helper owns every queue, so nothing is sent later behind the person's back. An intent still waiting for its
  reply when the connection drops gets `connection_lost` from the client library (§ Replies and errors).

## Transport

**State directory.** All Friends state for a Mac user lives in one directory shared by every app that hosts
Friends: `~/Library/Application Support/Shenzhen Friends/`, or `$SZFRIENDS_STATE_DIR` when that is set to an
absolute path (tests, probes, the two-helper harness). Builds signed with a team ignore the variable, the helper and
the apps alike (ADR 0002, Review amendments). The helper creates the directory with mode 0700.

**Canonical form.** Helper and clients canonicalize the state directory the same way before deriving anything
from it: resolve the deepest existing ancestor with `realpath()` and append the components that do not exist
yet. A client that starts before the helper has created the directory still agrees with it (`/var` is a symlink
to `/private/var`, `/tmp` to `/private/tmp`).

**Socket.** One Unix stream socket, in a directory with mode 0700 owned by the user:

| Form | Path | When |
|---|---|---|
| Primary | `<canonical state dir>/ipc/helper.sock` | the path is at most 103 bytes |
| Fallback | `<user temp dir>/szfriends-<16 hex>/helper.sock` | the primary path is longer |

`sockaddr_un.sun_path` holds 104 bytes on macOS including the terminating NUL, so a path longer than 103 bytes
cannot be bound or connected. Deep `SZFRIENDS_STATE_DIR` paths in tests exceed it; the fallback keeps them short.

- `<user temp dir>` is `confstr(_CS_DARWIN_USER_TEMP_DIR)` on macOS, used exactly as returned (it is per-user
  and already 0700). On Linux it is `$XDG_RUNTIME_DIR`, or `/tmp` when unset.
- `<16 hex>` is the 64-bit FNV-1a hash of the canonical state directory's bytes (no terminating NUL), lowercase,
  zero-padded. FNV-1a 64: offset basis `0xcbf29ce484222325`, prime `0x100000001b3`, XOR then multiply per byte.
  The hash only names a directory; it is not a security boundary.
- Test vectors: `""` → `cbf29ce484222325`; `"a"` → `af63dc4c8601ec8c`;
  `"/Users/raph/Library/Application Support/Shenzhen Friends"` → `b481e2f85812919d`.
- `szfriends_socket_path()` in `client/szfriends_client.h` computes both forms; the helper calls the same
  function, so the two can never disagree.

**Directory safety.** Before binding, the helper creates the socket directory 0700 and refuses (logs, exits) if
it is a symlink, is owned by another uid, or grants any group or world permission. The client applies the same
check before connecting and reports `SZFRIENDS_ERR_UNSAFE_DIRECTORY` instead of connecting. Both sides call
`szfriends_socket_directory_check()` from the client library, so the rule exists once.

**Peer checks, both ways.** On accept the helper reads the peer's uid with `getpeereid()` (`SO_PEERCRED` on
Linux) and closes the connection without a word unless it equals its own; signed builds also check the peer's
code signature through its audit token. On connect the client checks the helper's uid the same way and refuses
another user's helper (`SZFRIENDS_ERR_PEER_UID`). A team-signed app also reads the helper's audit token
(`LOCAL_PEERTOKEN`) and sends nothing to a helper its team did not sign (`SZFRIENDS_ERR_PEER_SIGNATURE`): the app
supplies its Team ID and a code-signature check through `szfriends_set_signing_policy()`, and the library applies
the requirement the helper applies to its clients.

**Single instance.** The helper takes an exclusive non-blocking `flock` on `<state dir>/helper.lock` before it
binds. A second helper fails to take it and exits with status 0. Only the lock holder may remove a stale socket
file before binding.

**Other systems.** The same framing, handshake and frames run everywhere; only the state directory and the way
in differ (ADR 0015 § 3, § 8). Phones run the core inside the app and carry the frames over an in-memory channel.

| System | State directory | Way in |
|---|---|---|
| macOS | `~/Library/Application Support/Shenzhen Friends/` | the Unix socket above |
| Linux | `$XDG_DATA_HOME/shenzhen-friends` (or `~/.local/share/…`) | the Unix socket above (`SO_PEERCRED`) |
| Windows | `%LOCALAPPDATA%\Shenzhen Friends` | a named pipe, below |

On Windows the single instance is a byte lock (`LockFileEx`) on `<state dir>\ipc\helper.lock`, whose holder
writes its process id at the start of the file. The holder creates the pipe
`\\.\pipe\szfriends-<user SID>-<16 hex of the state dir>-<32 random hex>` with `FILE_FLAG_FIRST_PIPE_INSTANCE`,
`PIPE_REJECT_REMOTE_CLIENTS`, a DACL granting only the user and the user as owner, and writes its name to
`<state dir>\ipc\helper.pipe`. A client accepts that name only in exactly this form for its own SID and state
directory, connects with `SECURITY_IDENTIFICATION`, and before sending a byte checks that the server process is the
lock's holder, runs as the same user and at least the client's integrity level, is not an AppContainer, and owns
the pipe; the helper checks each client the same way. A name left behind by a helper that has gone is refused, and
the client then starts its own helper. `szfriends-contract::pipe` and `szfriends-helper-sys` hold the rules.

## Framing

- Each frame is one JSON object (RFC 8259, UTF-8) followed by one line feed (`0x0A`). Encoders never
  pretty-print, so a frame never contains a raw line feed; line feeds inside strings are escaped as `\n`.
- A frame is at most **8,388,608 bytes** (8 MiB), not counting the line feed. A receiver stops buffering as soon
  as a pending line exceeds the cap. The helper then sends `goodbye` with reason `protocol_error` and code
  `frame_too_large` and closes; the client library closes and reconnects. Senders never produce such a frame:
  the library refuses to send it (`SZFRIENDS_ERR_FRAME_TOO_LARGE`).
- Empty lines are skipped. Whitespace around the object, including a carriage return, is tolerated.
- Every frame has a string `type`. Client frames: `hello` and the intents. Helper frames: `welcome`, `reply`,
  `snapshot`, `goodbye`.
- Every client frame has an `id`: 1 to 32 printable ASCII characters, unique on the connection while its reply
  is outstanding. The library uses a decimal counter.
- A line that is not a JSON object, or a client frame without a usable `type` or `id`, is a protocol error: the
  helper sends `goodbye` (`protocol_error`, code `bad_frame`) and closes. A well-formed frame with a bad field is
  not; it gets a `reply` with `invalid_field` and the connection stays open.
- Opaque ids issued by the helper (conversation, item, transfer, subscription, nearby, scope ids) are 1 to 64
  characters from `[A-Za-z0-9_-]`. Clients never parse or construct them.
- Times that are not labels are RFC 3339 UTC strings ending in `Z` (`2026-10-12T06:51:10Z`). File sizes are
  JSON integers below 2^53.

## Lifecycle

- **Spawn.** While Friends is enabled in an app, the app calls `szfriends_spawn_helper()` once from a background
  queue at launch, never waiting for it: it tries the socket and spawns the embedded helper only when nothing
  answers (ADR 0002's connect-or-spawn). The app then connects from its main loop. If that connection fails
  because nothing listens, the client library spawns again and retries with jittered backoff (first retry 50 ms,
  doubling, capped at 2 s). Any number of windows and apps may spawn at once; the lock makes it safe.
- **Prompts.** Starting Nearby can show the Local Network and Bluetooth permission prompts, which must never
  appear at launch for someone who has not opened Friends. The helper starts Nearby only after a client sends
  `activate`, which views send whenever the person opens the dropdown. Once the store records that permission
  was requested, the helper starts Nearby at launch too, which no longer prompts. Bluetooth also starts at launch
  when macOS already reports it allowed, which can be read without prompting (ADR 0004).
- **Exit.** The helper exits 10 seconds after its last client disconnects, so tab detach and multi-window
  restore (one process per window) do not bounce it, and 30 seconds after it started if no client ever connected
  (the app that spawned it died first). A client that sends `disable` and is the last client with Friends on
  makes the helper persist pending work and exit at once. The helper never outlives its apps.
- **Handover.** Each app embeds its own helper; the first app to start runs its copy, and an app whose helper is the
  same build uses the running one. A newer app that finds an older helper running asks it to step aside (§ Handshake,
  `embedded_helper`): the old helper stops accepting
  clients, waits until no chunk is in flight and no store transaction is open (at most 5 seconds; running
  transfers pause and resume from the verified byte count), sends `goodbye` with reason `handover` and its
  successor's version to every client, releases the lock and exits.
  - A client whose embedded helper's build number is at least the successor's spawns its helper immediately.
  - Any other client waits up to 10 seconds for the successor to appear, then spawns its own, so Friends keeps
    working if the newer app quit meanwhile. The newest helper wins whenever its app is running, so this
    converges.
- **Reconnect.** After any disconnect the client library reconnects by itself and reports `READY` again.
  Subscriptions never survive a reconnect: subscription ids from the previous connection are void, and the host
  (the Objective-C link does this for the AppKit views) subscribes again.

## Handshake

The first client frame must be `hello`; any other frame first is answered with a `reply` error
`hello_required`, then `goodbye` with reason `protocol_error` (its `error.code` `hello_required`), and the
connection is closed. The helper answers `hello` with `welcome`, or with a `reply` error `protocol_unsupported`
followed by `goodbye` with reason `protocol_error` (its `error.code` `protocol_unsupported`) and close. A handover
scheduled by that hello is announced in the reply's `details.handover` and does not change the goodbye's reason:
the goodbye says why this connection ends, and `handover` is kept for the helper stepping aside for every client.
Full examples: `fixtures/frames/reply-protocol-unsupported.json`, `fixtures/frames/goodbye-protocol-unsupported.json`.

```json
{"type":"hello","id":"1","protocol":{"major":1,"minor":0,"min_major":1},
 "client":{"app_id":"com.intuition.shenzhenpdf","app_name":"ShenzhenPDF","app_version":"26.10.12",
           "toolkit":"appkit","reveal_in":"Finder","pid":4242},
 "embedded_helper":{"version":"26.10.12-1","build_number":26101201,"protocol":{"major":1,"minor":0}},
 "capabilities":["attach.items","drop.files","drop.tabs","search.export"],
 "open_formats":["pdf","epub","xps","cbz","md","markdown"],"locale":"en-GB"}
```

| Field | Meaning |
|---|---|
| `protocol` | Highest version the client speaks, and `min_major`, the lowest major it still accepts (one major back) |
| `client.app_name` | How strings name the app: "the next time ShenzhenPDF reaches the Friends server" |
| `client.toolkit` | `appkit` or `gtk4` |
| `client.reveal_in` | The file manager's name, for "Show in Finder" |
| `embedded_helper` | The helper inside this app's bundle, or `null` (a test client); drives handover |
| `capabilities` | What this client can show or do (§ Capabilities) |
| `open_formats` | Lowercase file extensions this app opens in place: received files in them offer Open; others offer Show in Finder. At most 512, each at most 128 characters |
| `locale` | BCP 47; M1 ships English, so the helper accepts any value and answers in English |

Full examples: `fixtures/frames/hello.json`, `fixtures/frames/welcome.json`.

**Version negotiation.** A version is `major.minor`. Within a major, minors only add: optional fields, intents,
views, actions, capability strings. Each side speaks its own major and the one before it (`min_major` =
major − 1 once there is a major 2). The helper picks the highest major both accept, then the lower of the two
minors for that major, and announces it in `welcome.protocol`. From then on each side uses only what the
negotiated version defines. No common major: `protocol_unsupported` with `details.helper_major` and
`details.helper_min_major`.

**Handover request.** When `embedded_helper` is newer than the running helper (compared by protocol major,
then minor, then `build_number`), the running helper schedules a handover and says so in `welcome.handover`
(`scheduled`), or in the `protocol_unsupported` error's `details.handover`. This works even when negotiation
fails, because `hello`, `welcome`, `reply` and `goodbye` keep their shape in every version: a client can always
ask an older helper to step aside.

**Frozen frames.** These fields never change meaning or type in any version: `hello.type`, `hello.id`,
`hello.protocol`, `hello.client`, `hello.embedded_helper`; `welcome.type`, `welcome.re`, `welcome.protocol`,
`welcome.helper`, `welcome.handover`; `reply.type`, `reply.re`, `reply.ok`, `reply.error.code`;
`goodbye.type`, `goodbye.reason`, `goodbye.successor`.

## Capabilities

Lowercase dotted strings. Unknown ones are ignored on both sides.

| Client capability | Effect |
|---|---|
| `attach.items` | The host offers `#` items; the composer hint includes "# Attach" |
| `drop.files` | The host accepts dropped files; the hint includes "or drop files"; rows carry `drop_label` |
| `drop.tabs` | The host has its own draggable items (reader tabs); informational |
| `assistant.drafts` | The host has `/` drafts; the hint includes "/ Ask the assistant" (Assistant track) |
| `assistant.chats` | The host's AI chat may open scoped chat access; without it `assistant_*` intents fail with `not_allowed` |
| `search.export` | The host shows Friends results in its global search (Cmd+K) |
| `files.share` | A phone: `show_file` hands a received file to the system's share sheet, labelled "Share…", and offers no folder to show (the details' `received.action` is null) |
| `mentions` | The host's views show mentions (§ Mentions): `@` in the composer, whose hint then includes "@ Mention", with `mentionable` on list rows and the composer's `mention_note`, and mentions in messages as links. Without it every mention arrives as plain text |

| Helper capability | Meaning |
|---|---|
| `nearby.network` | LAN and peer-to-peer Wi-Fi discovery is built in |
| `nearby.bluetooth` | Bluetooth discovery is built in |
| `host.checkin` | The helper checks in with the Friends host |
| `assistant.scopes` | `assistant_*` intents are implemented (Assistant track). Without it they fail with `unknown_intent` |
| `messages.status` | The `message_status` view is implemented (§ Views): a host can follow messages it sent without opening their conversation |
| `messages.cancel` | `cancel_message` is implemented (§ Intents): a host may offer Cancel on a message it sent while that message has not left this Mac. Without it the intent fails with `unknown_intent` |
| `mentions` | `send_message.mentions` and `add_from_mention` are implemented (§ Mentions). Without it a host offers no `@`: an older helper would ignore `mentions` and send each U+FFFC as it is, and answers `add_from_mention` with `unknown_intent` |
| `links` | Friend links and download links (§ Links): `open_link`, `add_from_link`, `receive_link`, `make_download_link`, `reset_friend_link` and `revoke_link`, and the profile's `links`. Without it they fail with `unknown_intent` and hosts offer no link items |
| `devices` | One profile on several computers (§ Devices, § Joining): the profile's `devices`, the list's `state`, `removed`, `join_requests` and rows' `kind`, the name prompt's `join_label`, the `join` view, the You conversation, files on another computer, and the intents `revoke_device`, `rename_device`, `fetch_from_device` and the five join intents. Without it those fields are absent, the intents fail with `unknown_intent`, and hosts show none of it |
| `online` | Online friends (M2): the helper reaches friends over the Internet, and its words say so (§ Shared objects, Route, online). Absent in M1: no snapshot shows an Online or Connecting state or Internet wording |

An M1 helper announces `nearby.network`, `nearby.bluetooth`, `host.checkin`, `messages.status`, `messages.cancel` and
`mentions` (`fixtures/frames/welcome.json`).

## Intents

Every intent is a client frame with `type`, `id` and the fields below, and receives exactly one `reply`. When the
connection drops before that reply arrives, the client library delivers it itself, after reporting the state
change, with the client-side code `connection_lost` (§ Replies and errors), so every reply handler still runs
exactly once. Snapshots that reflect an intent's effect are sent before its reply, so a view that clears the
composer on the reply already shows the sent message. Field types are in § Schemas; this table says what each does.

| Intent | Fields | Effect |
|---|---|---|
| `ping` | — | Liveness check; empty result |
| `activate` | — | The person opened Friends, or pressed Allow or Try Again: start Nearby (may prompt for permission the first time), restart a failing method, and read an identity that was unavailable again |
| `subscribe` | `view`, `params?` | Start receiving a view's snapshots; result `subscription`. Views: `badge`, `list`, `nearby`, `details` (`params.conversation_id`), `profile`, `settings`, `message_status` (`params.message_ids`), `join` (§ Joining) |
| `unsubscribe` | `subscription` | Stop |
| `set_filter` | `subscription`, `query` | Filter a `list` or `nearby` subscription by names and IDs; `""` clears. U+2011 in the query matches `-` |
| `open_conversation` | `conversation_id`, `message_id?` | Subscribe to a conversation; marks it read while subscribed. With `message_id` the window includes that message and `highlight_item_id` names it. Hold only while on screen |
| `load_earlier` | `subscription` | Grow a conversation subscription's window by 200 items |
| `send_message` | `conversation_id`, `text`, `client_token`, `attachments?`, `via_assistant?`, `mentions?` | Send text, with optional attachments (one offer each) and the friends its `@` chips name (§ Mentions) |
| `send_files` | `conversation_id`, `files`, `client_token`, `via_assistant?` | Offer files at once, one offer per file (drops on a row or the message list) |
| `cancel_transfer` | `transfer_id` | Withdraw an unaccepted offer, or stop a running transfer, either direction. Cannot retract what already arrived |
| `accept_offer` | `transfer_id` | Accept an incoming file; download starts |
| `decline_offer` | `transfer_id` | Decline an incoming file |
| `retry_item` | `item_id` | Try a failed message or transfer again |
| `cancel_message` | `message_id` | Withdraw an outgoing message that has not left this Mac (`queued` or `connecting`): it is never sent, and its conversation item says Cancelled. Fails with `stale` once it is `sending` or later (below) |
| `accept_request` | `conversation_id` | Accept a friend request |
| `decline_request` | `conversation_id` | Decline it; the person can ask again later |
| `cancel_request` | `conversation_id` | Withdraw a request this person sent |
| `send_request` | `nearby_id` | Send a friend request to someone visible in Nearby |
| `add_by_id` | `friends_id` | Send a friend request by Friends ID; result `message` says what happens next. The helper reads U+2011 as `-`, so an ID pasted from any text Friends showed works |
| `add_from_mention` | `friends_id`, `identity_key`, `name` | Add by ID for someone a mention named, which only the mention's key may answer (§ Mentions); the fields are a card action's, sent as they are; result as `add_by_id` |
| `open_link` | `payload` | A link the person opened in this app from its web page (§ Links): result `card`, shown before anything happens |
| `add_from_link` | `payload` | The friend link card's Add: a request carrying the link's invite token, which the inviter's Mac accepts automatically while the link is valid; result as `add_by_id` |
| `receive_link` | `payload` | The download link card's Download: fetch that one file from the sender's Mac into the received folder; result `conversation_id` and `message` |
| `make_download_link` | `file`, `expires_days` | A download link for one file, valid 1, 7 or 30 days; result `url`, `link_id` and `message` |
| `reset_friend_link` | — | Stops the friend link working and makes a new one, which the profile's `links` then shows |
| `revoke_link` | `link_id` | Ends one download link at once |
| `join_profile` | `friends_id` | This computer asks to join the profile holding that ID (§ Joining) |
| `enter_join_code` | `code` | The 8-digit code another computer of the profile shows (§ Joining) |
| `cancel_join` | — | Stop asking to join (§ Joining) |
| `approve_join` | `join_id` | Approve a computer asking to join this profile; a code shows on its row (§ Joining) |
| `deny_join` | `join_id` | Turn it away, or withdraw a code shown (§ Joining) |
| `revoke_device` | `device_id` | Remove another computer from this profile, after the action's confirmation (§ Devices) |
| `rename_device` | `name` | The name this computer has in Your computers on every computer of the profile (§ Devices) |
| `fetch_from_device` | `transfer_id` | Copy here a file another of the person's computers holds (Get, § Devices) |
| `block` | `conversation_id` | Block: they cannot reconnect, send requests or offer files; turns off automatic acceptance |
| `unblock` | `conversation_id` | Undo a block |
| `remove_friend` | `conversation_id` | Remove; the conversation stays and either side may send a new request |
| `mark_verified` | `conversation_id` | The person confirmed the comparison codes match |
| `accept_key_change` | `conversation_id` | Continue with a friend's new key after review; the friend becomes unverified |
| `set_name` | `name` | The name friends see; `""` clears it (friends then see the Friends ID) |
| `set_picture` | `picture` | An animal (`kind` `animal`, `set`, `index`) or a photo (`kind` `image`, `data_base64` or `path`, optional `crop`) |
| `set_auto_accept` | `conversation_id`, `enabled` | Accept files from this friend automatically |
| `dismiss_banner` | `kind` | The person read the list's one-time notice (`id_changed`); it does not come back |
| `start_visibility` | — | Visible to people nearby for 5 minutes; result `deadline`. Repeating does not extend a running deadline |
| `stop_visibility` | — | Stop being visible now |
| `search_messages` | `query`, `conversation_id?`, `limit?` | Local search of messages and transfer records: conversation search, and Cmd+K without `conversation_id`. No network |
| `assistant_open_scope` | `scope` | Open scoped chat access for one assistant request: `scope.kind` `conversations` with `scope.conversation_ids`, or `all` |
| `assistant_search` | `scope_id`, `query`, `limit?` | Search within the scope; bounded excerpts |
| `assistant_read` | `scope_id`, `message_id`, `before?`, `after?` | Messages around one message within the scope |
| `assistant_close_scope` | `scope_id` | End the scope (also ends with the connection or after 10 minutes) |
| `delete_history` | `conversation_id?` | Delete one conversation's history, or all history without it, on every device of the profile (sync carries the deletion; ADR 0014). Keeps friends and received files |
| `reset_friends` | `confirm` | `confirm` must be `"reset"`. New identity and ID; deletes friends, history and pictures; keeps received files |
| `disable` | — | This app turned Friends off; the helper exits at once if no other app with Friends on is connected |

**Client-side actions, not intents.** Copying an ID uses the ID string in the snapshot. Navigating back is the
view stack's own business. Opening, importing and revealing a received file go through the host adapter with the
`path` in the snapshot. Opening system settings maps `settings_target` to a platform URL in the view. Enabling
Friends is the app's own setting (ShenzhenPDF's `friends.enabled`): the app spawns the helper and connects, and
there is no `enable` intent because an app with Friends off has no connection to send one on.

**Files.** `send_files.files[]` and `send_message.attachments[]` are file objects:

```json
{"path":"/Users/raph/Documents/Supplier contract v3.pdf","display_name":"Supplier contract v3.pdf",
 "revision":{"source":"com.intuition.shenzhenpdf","document_id":"d_7f3a","revision_id":"r_0412",
             "label":"version saved today, 14:02","sha256":"<64 hex>","size":2516582}}
```

On receipt the helper binds each file to an immutable snapshot at once (an APFS clone, or a copy). With a
`revision`, the snapshot's size and SHA-256 must match it, or the intent fails with `source_changed` and nothing
is sent: a newer source is never substituted. `revision` is optional or `null` for plain files, whose bytes at
that moment are what the person meant. Folders fail with `folder_not_supported`; views refuse them while
dragging, before any intent. All files of one intent are checked before any is offered: one bad file sends none.

**Idempotency.** `client_token` (16 to 64 characters, random per press of Send) makes `send_message` and
`send_files` safe to retry after a reconnect: the helper returns the earlier result instead of sending twice.

**Via the assistant.** `via_assistant` `true` on `send_message` or `send_files` says the host's assistant wrote it
for the person, who then sent it: in ShenzhenPDF, a message the assistant prepared in AI chat for a friend the person
named with an `@` chip, or for a `/` command in a conversation, sent with Send on the assistant's card or proposal.
The assistant never sends by itself; every such message waits for that Send. It is absent or `false` for everything
the person writes themselves, including a proposal they moved into the composer with Edit. Only a client that
declared `assistant.chats` or `assistant.drafts` may set it; any other gets `not_allowed`. The flag travels with the
message and each offer (the session frames' ViaAssistant field, ADR 0001), both helpers store it, and the
conversation item on each side carries `assistant_label` (§ Views, `conversation`), so both people see it came via
the assistant. The helper checks nothing else about the assistant: which friends a request may send to, what it may
attach, how many sends it makes and that each waits for the person's Send are the host's tool layer's rules
([ai-agent-capabilities.md](../docs/plans/ai-agent-capabilities.md) § 1), because only the host knows what the
person asked for. Retrying with the same `client_token` returns the earlier result whatever `via_assistant` says.

**Cancelling a message.** `cancel_message` takes the `message_id` `send_message` returned, which is also the message
item's `item_id`. While the message is `queued` or `connecting` and was never written to a connection, nothing of it
has reached the friend: the helper removes it from what it will send, so the friend never receives it, and keeps it
in the history with `status` `cancelled`. From `sending` on it may already be on the friend's Mac, and it cannot be
taken back: the reply is `stale` with `details.state` `sending` or `delivered` and a `message` saying so ("Mei
already has it, so it can’t be cancelled."), and the item keeps its status. The same holds for a
message written to a connection that dropped before the friend's Mac acknowledged it: it is `queued` again, but that
Mac may have stored it, so the reply is `stale` with `details.state` `sent` ("Mei may already have it, so it
can’t be cancelled.") and the item no longer carries Cancel. A message already cancelled answers `ok` again, so retrying
after `connection_lost` is safe. Files sent with the message are offers of their own, each withdrawn with
`cancel_transfer`. The conversation's queued and connecting messages carry Cancel as an action until then (§ Views,
`conversation`), and a host surface such as ShenzhenPDF's AI chat card offers it too when the helper announces
`messages.cancel`.

**Assistant commands (`/`).** Nothing on the wire is specific to them; a host that offers them declares
`assistant.drafts`. In a conversation, the host passes the person's `/` command to its own assistant, which may read
that one conversation through an assistant scope (below). A command never sends by itself. It either prepares a
draft, which fills the composer and goes, if the person presses Send, as an ordinary `send_message` without
`via_assistant`; or, when the command asks to send, it proposes a message, shown above the composer exactly as it
will be delivered, with the file names visible, Send and Edit. Send sends exactly that text and those files with
`send_message` (or `send_files`) and `via_assistant` `true`; Edit moves them into the composer as a draft. Progress
and Cancel stay in the host. The host always sends to the open conversation's `conversation_id`, whatever the
assistant's output says, and attaches only files the person chose with `#` or by dropping.

**Assistant scopes.** The host's AI tool layer opens a scope only for a request that explicitly brought chats in
(`@Mei`, `@All Friends chats`, or `/` inside a conversation) and passes the `scope_id` to the tools of that one
request. Every `assistant_search` and `assistant_read` is limited to the scope's conversations; a request
without a scope has no Friends tools at all. Results are bounded excerpts with sender, time and a message
reference, never whole histories. Only clients that declared `assistant.chats` may open scopes.

## Replies and errors

```json
{"type":"reply","re":"7","ok":true,"result":{"subscription":"s_3"}}
{"type":"reply","re":"8","ok":false,"error":{"code":"folder_not_supported",
 "message":"Folders can’t be sent yet.","retryable":false,"details":{"path":"/Users/raph/Site visit"}}}
```

`re` is the intent's `id`. `result` is present when `ok` is true (an empty object when there is nothing to
return); `error` when it is false. `error.message` is display-ready text for the person, or `null` when the view
has nothing useful to say (protocol errors). `details` carries machine-readable context.

| Code | When | Retryable |
|---|---|---|
| `bad_frame` | Not a JSON object, or no usable `type`/`id` (sent in `goodbye`; connection closes) | no |
| `frame_too_large` | Over 8 MiB (sent in `goodbye`; connection closes) | no |
| `hello_required` | Any frame before `hello` | no |
| `protocol_unsupported` | No common major | no |
| `unknown_intent` | Intent not defined in the negotiated version, or in a family whose helper capability is absent | no |
| `invalid_field` | Missing or malformed field; `details.field` names it | no |
| `not_found` | Unknown conversation, transfer, item, subscription, nearby or scope id | no |
| `not_allowed` | Not possible in the current state (accepting a settled offer, sending to a blocked person) | no |
| `rate_limited` | Too many requests or offers; `details.retry_after_seconds` | yes |
| `too_many_subscriptions` | Over the per-connection limit | no |
| `identity_unavailable` | The identity key cannot be read; only `reset_friends` and reads work | no |
| `name_invalid` | Empty after trimming where a name is required, too long, or control characters | no |
| `id_invalid` | Not a Friends ID (a word is not in the list) | no |
| `id_is_yours` | `add_by_id` with this person's own ID | no |
| `already_friends` | Request to an existing friend | no |
| `blocked` | The other person is blocked by this person | no |
| `not_friends` | Messages or files to someone who is not a friend | no |
| `file_missing` | A path does not exist or cannot be read; `details.path` | no |
| `folder_not_supported` | A path is a folder; `details.path` | no |
| `too_many_files` | Over the per-intent limit | no |
| `source_changed` | A bound revision no longer matches its file; `details.path` | no |
| `disk_full` | Not enough space to snapshot or receive | yes |
| `picture_invalid` | Not a decodable image, or over the limits | no |
| `scope_invalid` | Unknown, expired or closed assistant scope, or a message outside it | no |
| `stale` | Acting on an offer, request or message that changed meanwhile; the next snapshot shows its state. For `cancel_message`, `details.state` says where the message already is (`sending`, `delivered`) or may be (`sent`) | no |
| `mention_mismatch` | `add_from_mention` for an ID this person's own data gives to another key: one of their friends holds it, or the Friends host vouched for someone else (§ Mentions) | no |
| `link_offline` | `receive_link`: the Mac the file comes from is not connected to the Friends host now, or did not answer (§ Links) | yes |
| `link_changed` | `receive_link`: the sender's file changed after the link was made, so the link no longer delivers it | no |
| `link_failed` | `receive_link`: no connection opened, or what arrived did not match the file; nothing was kept | yes |
| `too_many_links` | `make_download_link` while 50 download links are live, the Friends host's limit | no |
| `internal` | A helper bug; logged with detail, shown as a generic failure. `reset_friends` that could not remove the stored identity sends `details.reason` `identity_not_removed`: nothing was changed, and the message says so | yes |
| `not_ready` | Client-side only: the client is not connected, nothing was sent | yes |
| `connection_lost` | Client-side only: the connection dropped while the intent waited for its reply | yes |

**Client-side codes.** The helper never sends `not_ready` or `connection_lost`. `not_ready` is the send call's
own failure (`SZFRIENDS_ERR_NOT_READY`); `connection_lost` arrives as a `reply` frame the client library makes
for each intent still waiting when the connection drops, with `message` `null`, `retryable` `true` and empty
`details` (`fixtures/frames/reply-connection-lost.json`). Views show the host's connection line rather than a
message of their own (§ Principles). The two differ in what the person may assume. After `not_ready` nothing
happened. After `connection_lost` the intent may or may not have taken effect: `send_message` and `send_files`
are safe to send again with the same `client_token` (§ Intents, idempotency), and for anything else the snapshots
after the reconnect show what happened.

**Goodbye.** The helper sends `goodbye` before closing a connection on purpose: `handover` (with `successor`),
`shutdown` (logout, system shutdown, signal), `protocol_error` (with `error`: `bad_frame`, `frame_too_large`,
`hello_required` or `protocol_unsupported`), `reset` (Reset Friends; reconnect and subscribe again),
`too_many_clients`. A connection that closes without `goodbye` is a crash; reconnect.

## Snapshots

```json
{"type":"snapshot","subscription":"s_3","view":"list","rev":42,"data":{ "...": "..." }}
```

- After a successful `subscribe` or `open_conversation`, the helper sends the first snapshot before the reply,
  then a new full snapshot whenever the view's data changes. `rev` starts at 1 and increases by one per snapshot
  on that subscription. Snapshots are always complete; there are no diffs, so a view replaces what it shows.
- The helper sends nothing when the data did not change, at most 10 snapshots per second per subscription, and
  transfer progress at most 4 times per second. While visible, `nearby` updates every second for the countdown;
  time labels refresh at midnight and when a label's wording changes ("Today" becomes "Yesterday").
- Every documented field is always present. A field that does not apply is `null`, never absent, so views can
  rely on the shape; fields added in later minors may be absent when talking to an older helper, and the fields
  § Mentions ties to the `mentions` capability are absent for a client that did not declare it.
- Conversation snapshots hold a window of the newest 200 items, oldest first; `has_earlier` says more exist.

## Views

Each view's exact fields are in § Schemas. This section says what they mean and how views use them. The golden
fixtures in `fixtures/snapshots/` show every view in the mockup states; those named `online-*` show them as a
helper that announces `online` sends them (§ Shared objects, Route, online).

### `badge`

The count on the Friends button: rows waiting for an answer (incoming requests, incoming offers, key changes),
identical in every window because the helper owns it. `label` is `""` at zero, `"99+"` above 99.
`accessibility_label` reads "Friends" at zero, "Friends, 2 waiting for you" otherwise.

### `list`

The Friends tab: everyone in one list sorted by latest interaction of any kind (message, file, request,
acceptance). There is no separate inbox; requests and offers are rows.

- `rows[].waiting` is set when the row waits for this person's answer; views show `waiting.label` in place of the
  route icon and emphasise the subtitle. `subtitle` says what is waiting ("Wants to be friends", "Answered your
  request for tulip‑canyon" for an Add by ID answer no host confirmed, "Sent you Site photos.pdf") or previews the
  last message or transfer. A preview with a status leads with it ("Sends when Priya is nearby · Supplier contract
  v3.pdf", "Accepted automatically · Enclosure assembly guide.pdf"), so truncating a narrow row cuts the file name,
  never whether it went; views truncate at the end.
- `rows[].id_confirmed` is true when the Friends host confirmed that this person holds the Friends ID (ADR 0005,
  attestation): several people may answer one Add by ID, and only the holder's answer carries it. Views mark the
  row (a small check beside the title) with `id_confirmed_label` as its tooltip and accessible name; it is `null`
  when `id_confirmed` is false. It says nothing about who is at the keyboard; comparing codes does.
- `rows[].route` drives the small route icon (by `method`, else `kind`; § Shared objects, Route) and its tooltip
  (`label`). It describes the connection, not the friendship: a request found nearby has a live session and shows
  it. Kind `none` means there is nothing to show (a request by ID that has never connected) and draws no icon.
  `unread` shows the row marker. `blocked` rows stay in the list so they can be unblocked.
- `rows[].style` is how the row is drawn: `normal`, or `muted` for someone the person blocked (a faded avatar and
  the title in secondary text, still a full row that opens the conversation). The helper decides the look so views
  never infer it from other fields; a view draws a style it does not know as `normal`.
- `rows[].drop_label` ("Send to Mei") is what the row says while files are dragged over it; `null` means the row
  refuses drops (requests, blocked people). A row that refuses says why in `rows[].drop_refusal` while files are
  dragged over it ("Lena isn’t your friend yet", "You blocked Jonas"); it is `null` on rows that accept drops, and
  on every row when the client did not declare `drop.files`.
- `rows[].actions` are buttons on the row itself, so a friend request can be answered from the list: Accept,
  Decline and Block on an incoming request, and none on any other row (an empty array). Views draw them as round
  icon buttons by `icon` (`accept` a check, `decline` a cross, `block` a circle with a slash) in place of the
  time, the waiting label and the route icon, with `label` ("Accept Lena Weber’s request") as each button's
  tooltip and accessible name; a view hides an action or icon it does not know. Pressing one sends its intent
  with the row's `conversation_id`; the rest of the row still opens the conversation. Accepting from the list
  leaves the person unverified until codes are compared in their details.
- An action with `arm` needs a second click, so a stray click cannot block someone: the first click turns the
  button into a pill showing `arm.label` ("Block?") in the destructive color, with `arm.accessibility_label` as
  its tooltip and accessible name, and sends nothing; a second click within `arm.seconds` sends the intent. The
  pill turns back into the icon when that time passes, on Escape (which then closes nothing else), or when the
  pointer leaves the row. Block carries `arm` wherever it appears in the dropdown, on these row buttons and on
  every action button (§ Shared objects, Action), so it behaves the same everywhere.
- `banner` is a notice at the top of the list only, never elsewhere: the one-time "Your ID changed to
  walnut-garden because walnut-valley was taken." (its action sends `dismiss_banner`), an unreadable identity with
  its reset action, or `update_required`: online Friends needs a newer app, or another app on this Mac
  already updated the Friends data and this helper cannot read it (ADR 0003); the text says which.
- `name_prompt` appears until a name is chosen: an inline field at the top of the list that never blocks it. With
  the helper capability `devices` its `join_label` offers joining an existing profile instead (§ Joining).
- With the helper capability `devices`: `state` (`normal`, or `device_removed` with `removed`, § Devices),
  `join_requests` above the rows (§ Joining), and each row's `kind`, `you` for the You conversation (§ Devices).
- `empty` replaces the rows when there are none, or when a filter matches none.
- `rows[].mentionable` (clients that declared `mentions`) says whether the `@` picker offers this person: a friend
  with a Friends ID. The picker is a second `list` subscription filtered with `set_filter` as the person types.
- `footer` is the name friends see (`name` `null` until chosen, then `name_placeholder` shows), the ID line with
  Copy, `id_note` while the ID is not reserved yet ("Your ID works nearby now…", brief § Friends ID; `null` once
  reserved), and Add by ID, which opens the profile view. Copy copies `friends_id`, never `id_label`.

### `nearby`

The Nearby tab: the visibility action, then people as each method reports them.

- `visibility.state` is `hidden` (the action makes the person visible for 5 minutes), `visible` (countdown in
  `remaining_label` with Stop) or `unavailable` (no method can advertise). Expiry, sleep and disabling never
  extend the deadline.
- `methods[]` has one entry per discovery method, `network` (LAN and peer-to-peer Wi-Fi) and `bluetooth`, each
  with its own state. Each unavailable method is distinguished: Local Network access denied, Wi-Fi off,
  Bluetooth access denied, Bluetooth off, failing, and (state `unavailable`, its own label) no Bluetooth on this
  computer. While the identity is unavailable (the list's `identity_unavailable` banner) nothing runs: both methods
  are `not_asked` and say they start once Friends is reset, visibility is `unavailable` and says the same, and there
  is no `alert` or `note`, because nothing was refused.
- Buttons that start or retry Nearby send `activate` (§ Intents), the same intent a view sends when Friends opens:
  Allow on the card shown while nothing has asked for access yet, and Try Again beside a method that is failing.
- `alert` is the one prominent card, used when the method most people rely on is unavailable (Local Network
  denied, Wi-Fi off, or the network failing); with Wi-Fi and Bluetooth both off it names both. `note` is one quiet
  line when a method is unavailable but others work: "Bluetooth is off. People nearby without Wi-Fi won’t appear."
  Under a card it says what Bluetooth is doing ("Still looking over Bluetooth.") or what is wrong with it. Never
  both for the same method.
- `status` is the small "Still looking" indicator beside the people header, shown only while people are listed;
  an empty pane says whether it is looking itself, so the two never show together.
- `people[]` are friends nearby (with `conversation_id`; clicking opens the conversation) and strangers who are
  visible (with `nearby_id` and a Request action). One row per person, however many methods see them.
- `empty` replaces the people when there are none, and says why: `searching` (nothing works yet, or a method
  started working less than 8 seconds ago: a first result takes that long), `nobody` visible, `unavailable` (no
  method works, never shown as an empty successful search), or `no_match` for a filter. Its `body` is `null` while
  a card is up, because the card already says what to do; the helper rebuilds the snapshot when `searching` turns
  into `nobody`.

### `conversation`

One friend's history and composer, or the request card for a pending request.

- `header` is the centered name and route line; clicking it opens `details` when `details_available`. Views draw
  `header.route`'s icon before `subtitle` and its `label` as the line's tooltip. For a blocked person the line says
  "Blocked" and the route is kind `none`, so no icon stands before it. `accessibility_label` says the name, the
  line and, when it opens details, "show details" ("Mei Lin, nearby, over Bluetooth, show details").
- `back` is the back arrow's badge: rows waiting elsewhere, not counting this one. Every view below the list
  (conversation, request, `details`, `profile`) carries it, counted the same way, so the count on the arrow always
  matches what waits in the list.
- `items[]` run oldest to newest: `day` separators, `message`, `transfer` (one per file, with its whole life:
  offered, receiving, received, declined, cancelled, failed) and `event` ("You are now friends").
- `has_earlier` says older history exists. Views then show a control above the oldest item labelled with the
  static string `load_earlier`, and may also load when the person scrolls to the top; either sends `load_earlier`.
- A failed item's `status.label` or `status_label` says why from the person's side ("Not delivered. Stopped trying
  after 30 days.", "Not sent because you removed Priya"), and it carries Try again (`retry_item`) only when trying
  again can work: not for a file that is no longer available or that the other Mac could not accept, and not while
  sending to that person is impossible (blocked, no longer friends, or a key change still to review).
- A message's `time_label` is `null` when it came less than 5 minutes after the message before it, so a burst
  reads as one exchange; the first message under each day separator always has one, transfers and events always
  have theirs, and every item's `accessibility_label` says its time. Views leave the time line out, not blank.
- Outgoing messages carry `status` (`queued`, `connecting`, `sending`, `delivered`, `failed`, `cancelled`) with a
  label written for the person: "Delivered" means it reached their Mac, not that it was read; "Cancelled" means the
  person withdrew it before it left (`cancel_message`), so the friend never gets it. While a message is `queued` or
  `connecting` its `actions` hold Cancel (`cancel_message`); from `sending` on they do not, because it may already be
  on the friend's Mac.
- A message's `text` is exactly what its sender typed, and `text_format` says how to show it: `markdown` (every
  message in this version) is Markdown source, which the host renders with its own Markdown renderer at chat scale
  (the views ask the host; ShenzhenPDF uses the reader's engine). A host without a renderer shows `text` as plain
  text or draws `segments`, the same text with its links found; a view shows a format it does not know as plain
  text. Rendering never fetches anything by itself: a remote image shows a placeholder naming its host until the
  person asks to load it, a link shows its destination before it opens, raw HTML shows as text and never runs, and
  tables, math and diagrams keep their time and size limits, so a hostile message cannot stall the view.
- A message's mentions show resolved for the reader (§ Mentions): `text` links each to `szfriends:mention?ref=<n>`,
  `mentions[n]` (present only when one shows as a link) says who it is and what a click does, and the segment with
  `mention` `n` carries its label for a host without a renderer. `text` is otherwise exactly what the sender typed.
- `assistant_label` is set on a message or transfer that came via the assistant (`via_assistant`, § Intents): "Via
  the assistant" on what this person sent, "Via Kenji’s assistant" on what the friend sent. It is `null` on
  everything else. Views show it as a quiet line beside the item's status; `accessibility_label` already says it.
- Transfers carry `status_label`, optional `route_note` ("Over Bluetooth, about 6 min" when the route is slow, so
  the person can accept now or wait), `progress` while moving, and `actions` (Accept, Decline, Cancel, Open, Show
  in Finder, Try again). Open appears only for formats in the client's `open_formats`.
- A transfer's `thumbnail` is the file's preview, which views show in place of its type icon, on both sides and
  before the file is accepted (§ Thumbnails). `null` means there is none, and views draw the type's icon themselves
  from `file.type_identifier`, or from `file.extension` when a toolkit has no use for the identifier.
- `highlight_item_id` names the message to scroll to and highlight after a search or a citation.
- A file another of the person's computers holds is a transfer in state `on_device` with Get, then `fetching`
  (§ Devices). The conversation `you` is the person's own (§ Devices, You).
- `request` replaces history and composer while a request is pending: the comparison code both screens show,
  with Accept, Decline and Block (incoming, Block destructive and armed), or Cancel request (outgoing).
  `comparison_code` is `null` when no session has derived one yet; `code_prompt` then says when it will be
  possible. An answer to this person's own Add by ID that the Friends host could not confirm comes as an incoming
  request too, because anyone nearby who heard the request could have sent it: its title and footnote say so, and
  the person accepts it, compares codes or declines it like any request. Until then that person is not a friend and
  cannot find this Mac in later presence windows (ADR 0004, Review amendments).
- `composer`: `visible` false hides it (pending requests); `enabled` false disables it with `note` saying why; `note`
  also says when queued messages will go ("Messages and files send when Priya is nearby with ShenzhenPDF, Shenzhen Files
  or Shenzhen 3D open."). It names every app that runs Friends, not the app showing it, because a message goes out while
  Friends runs on a computer of each person, and any of these apps open on a computer runs it, so every app shows the
  same sentence. Every string that names the apps does so through the catalog's one list. The same sentence is the
  static string `queued_note`. `mention_note` (clients that declared `mentions`) is the line under the `@` picker,
  `null` while the composer is disabled.

### `details`

A friend's details, opened from the conversation header: ID with Copy, verification (comparison codes),
**Accept files from Mei automatically**, received files, Delete chat history, Remove and Block.
`verification.comparison_code` is shown only while a live session has one; `key_change` appears when the friend
presented a new key, which is never accepted silently. `auto_accept.available` is false for blocked people. Delete
chat history comes first in `actions`, for anyone whose details show: `delete_history` with the details'
`conversation_id`, behind a `confirm` that says what goes (the messages and file history with that person, from this
Mac, and anything still waiting to go to them) and what stays (the person as friend or blocked, their own copy, files
received, and, for a client with `assistant.chats`, AI chat answers that quoted the chat), as Settings' Delete
history says for every chat. Delete chat history and Remove friend carry a `confirm` and every Block an `arm`, all
drawn destructive. `id_confirmed` and `id_confirmed_label` mean what they mean on a
list row; views show the label under the ID line.

### `profile`

The page behind Add by ID: the name field, the picture (the animal set and **Use your own picture…**), the
Friends ID with Copy, its reservation state written for the person, and the field to add someone by ID.
`picture.animal_set` and `picture.selected_index` tell the view which bundled set to offer and which animal is
selected; the view draws the set from its own copy. `id.qr_label` and `id.qr_payload` are `null` in M1, and views
show no QR and no QR button while they are: nothing on a Mac or a phone can open the code yet, so it would invite
a scan that does nothing. When a handler exists, `id.qr_payload` will be
`szfriends:add?id=<friends id>&key=<base64url identity key>`, and a scanned QR carries the key and is verified.
With the helper capability `links`, `links` lists the person's friend link and download links (§ Links); with
`devices`, `devices` lists the person's computers (§ Devices).

### `settings`

The Friends section of the host's Settings while Friends is on: name, ID, received files folder, automatic
acceptance summary and its per-friend switches, Delete history and Reset Friends with their confirmations. The
**Enable Shenzhen Friends** checkbox and the disclosure text belong to the host adapter, because they show while
Friends is off and no helper runs.

- `nearby`, when the helper adds it, says whether Nearby has the access and radios it needs (`note`) and carries the
  one button that fixes it when it has not: `activate` labelled Allow while nothing has asked for access yet (the
  system asks the first time), `open_settings` to the Privacy pane of the method that was refused, or to the Wi-Fi or
  Bluetooth settings while a radio is off, and `activate` labelled Try Again while a method is failing. `null` action
  when nothing needs doing. A view that does not know `nearby` shows nothing for it.

### `message_status`

Where a few of this person's outgoing messages stand, for a host surface outside Friends: ShenzhenPDF's AI chat keeps
a card for each message the person sent from it, which says "Sent to Mei" once Friends reports it delivered. Hosts
subscribe only when the welcome lists the helper capability `messages.status`. `params.message_ids` names 1 to 16
messages by the `message_id` `send_message` returned (more, none, or anything but strings fail with
`invalid_field`). `data.messages[]` holds, in that order, those that are this person's outgoing messages with a
delivery status, each with its `message_id` and the same `status` its conversation item carries, `cancelled`
included. An id that names anything else (a message the friend sent, a file, a message whose history was deleted,
nothing) has no row rather than failing, so subscribing again after a reconnect always works. Unlike
`open_conversation`, it marks nothing read and does not count as the conversation being on screen: following a send
from AI chat must not mark the friend's replies read before the person has looked at them.

### `join`

The new computer's side of joining a person's existing profile, with the helper capability `devices`: § Joining.

## Shared objects

- **Avatar.** `kind` `animal` (`set`, `index` into the bundled animal set), `image` (`path` to the helper's
  re-encoded photo, named by its content hash) or `placeholder`. Every avatar carries `initials` and `color`
  (`#rrggbb`, sRGB, readable under white initials) so a view can draw a placeholder when it lacks the animal
  (an index newer than its set) or the image file. For an animal, `color` is that animal's circle color from
  the set's manifest, so the placeholder resembles it; otherwise it is a stable palette color for the person.
  The helper writes each photo as a 256 px JPEG of at most 48 KiB, directly inside `pictures/` in its state
  directory. A view reads an `image` `path` only when it names a file directly inside that `pictures/` (no
  subfolder, no `.` or `..`, no doubled slash), judged by the path alone; `pictures/` is the helper's own
  directory, found as the state directory is, and only the photo itself is opened without following a link. The
  view opens it with `O_NOFOLLOW | O_NONBLOCK`, reads it only if it is a regular file of at most 256 KiB, decodes
  it only if it is a JPEG or PNG declaring 1 to 1024 px a side and decoding to exactly that size, and does all of
  this off the main thread, drawing the placeholder meanwhile and whenever the file fails a check. A damaged or
  planted entry in the helper's state (a link, a FIFO, a huge image) so never makes a view follow it elsewhere,
  block, or decode something enormous while the dropdown opens.
- **Route.** `kind` `local`, `online` (M2), `connecting` (M2), `offline` or `none`; `method` `lan`, `p2p_wifi`,
  `bluetooth`, `internet`, `relay` or `null`; `label` for the tooltip, `null` for `none`. Views draw one icon per
  `method` (waves for `lan`, two laptops under an arching wave for `p2p_wifi`, the Bluetooth rune, a globe for
  `internet`, a server for `relay`), by `kind` when `method` is `null` or unknown to them (`local` the waves, `online`
  the globe), the globe in the offline colour for `connecting`, a hollow dot crossed out for `offline` and nothing for
  `none` or a kind they do not know, with `label` as its tooltip; both views draw the same shapes.
- **Route, online (M2).** Only a helper that announces `online` says anything about the Internet; an M1 helper's
  words say nearby, whatever happens. With `online`:
  - a session over the Internet is kind `online`, never `local`: method `internet` reads "Online, direct", `relay`
    "Online, through the Friends relay" (the last resort, capped at 5 Mbit/s);
  - while no session is up and an attempt to reach the friend runs (direct, then the relay), kind `connecting` with
    method `null` reads "Connecting to Mei…", but only within 45 s after something new was queued for them or their
    conversation was opened (an offer still unanswered after that does not keep it up); a nearby session that is up
    keeps its own route meanwhile;
  - when the friend answered but every way failed, the relay included, kind `offline` reads "Couldn’t connect just
    now", the composer's `note` says "Couldn’t connect to Mei just now. Friends keeps trying, and sends what’s
    waiting as soon as it can.", and things waiting to go keep their status; it stays through the retries that follow,
    so the words do not change with each one, until a session opens, something new is queued for them, their
    conversation is opened or the network changes;
  - otherwise kind `offline` reads "Not connected right now", and waiting words say "online or nearby" ("Sends when
    Mei is online or nearby", the composer's note and `queued_note`);
  - while kind is `connecting`, a queued message's `status` is `connecting` ("Connecting to Mei…") and a queued file's
    `status_label` says the same; both keep Cancel;
  - a transfer through the relay carries `route_note` with an estimate that never assumes more than the relay's cap,
    and assumes 4 Mbit/s until a rate is measured ("Through the Friends relay, about 3 min").
- **Action.** A button: `action` names the intent to send with the object's id (`accept_offer` with the item's
  `transfer_id`, `block` with the view's `conversation_id`, `dismiss_banner` with the banner's `kind`,
  `cancel_message` with a message item's `item_id` as `message_id`, `fetch_from_device` with the item's
  `transfer_id`, `add_from_mention` with the action's own `friends_id`, `identity_key` and `name`, and likewise
  `revoke_device` with its `device_id`, `approve_join` and `deny_join` with its `join_id`, `join_profile` with its
  `friends_id`) or a client-side action (`open_file`,
  `show_file` with `path`; `open_settings` with `settings_target`). `label` and `style` (`primary`, `secondary`,
  `link`, `destructive`) are display-ready; `note` is an optional explanation shown under the button. When
  `confirm` is present the view asks with that dialog first and sends the intent only on its confirm button;
  `reset_friends` is then sent with `confirm` `"reset"`. `confirm.destructive` draws the confirm button in the
  destructive color. When `arm` is present the button behaves like a row button with
  `arm` (§ Views, `list`): the first click shows `arm.label` in the destructive color and sends nothing, a second
  click within `arm.seconds` sends. Block always carries `arm`; Remove friend, Delete history (a friend's details
  and Settings) and Reset Friends carry `confirm`.
- **Friends IDs in text.** Display strings (`title`, `id_label`, banners, notes, messages in replies) join an ID's
  words with U+2011, a hyphen that never breaks a line, so a two-word ID is never split into what reads as two
  things. Fields named `friends_id` carry the ASCII form for Copy and intents. Anything that reads an ID a person
  typed or pasted (`add_by_id`, `set_filter`) treats U+2011 as `-`.
- **Rich text.** An array of segments: `text`, with optional `url` (a link the person can open; Friends never
  fetches link previews), `emphasis`, `match` (search) and `mention` (§ Mentions). Views concatenate segments in
  order.
- **Back.** `badge_count`, `badge_label` and `accessibility_label` for the back arrow.

## Mentions

`@` in a friend's composer names one of the person's friends inside the message. Whoever reads the message sees each
mention resolved against their own Friends list, so a sender cannot make a stranger look like a friend. The mentioned
person is not told; the conversation stays between its two people. The decision and its alternatives are ADR 0007.

**On the wire.** A mention is part of the message text, a Markdown link with Friends' own scheme:

```text
[@Mei Lin](szfriends:mention?id=jasmine-street&key=C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E)
```

The link text is `@` and the name the sender sees for that person (their name, or else their Friends ID with U+2011
between its words), at most 64 characters (Unicode scalar values) on one line, with exactly these backslash-escaped:
`` \ ` * _ [ ] < > ! & ~ | $ ^ = ``. The destination carries the Friends ID, two or three words of the list, and the
identity key, 32 bytes in base64url without padding (43 characters, its one canonical spelling). Only that exact form is
a mention, so the store, search and the session frame keep one plain string.

**Composing.** Views never write IDs or keys. `send_message` carries `mentions`, one object per `@` chip in order, each
naming a friend by `conversation_id`, and its `text` holds U+FFFC (OBJECT REPLACEMENT CHARACTER, which AppKit and GTK
text views already put where an inline chip sits) once per mention, in the same order. The helper writes the n-th
friend's mention in place of the n-th U+FFFC, after turning any Friends link the person typed into plain text, so the
only mentions a message carries are the ones its helper wrote.

- The number of U+FFFC must equal the number of mentions, at most 20; otherwise `invalid_field` with `details.field`
  `mentions`. Without `mentions`, U+FFFC in `text` stays as typed.
- Each must name a friend with a Friends ID: `not_found` for an unknown `conversation_id`, `not_allowed` for anyone
  else, each with `details.field` `mentions[n]`. Rows with `mentionable` true are exactly these people.
- The 32,768-byte text limit applies to the text the helper writes.

**Arriving.** The receiving helper checks every mention before it stores the message: an ID whose words are in the
list, a 32-byte key in its canonical spelling, a name of at most 64 characters on one line, at most 20 mentions.
Anything else that links to `szfriends:` (a malformed or 21st mention, another Friends link, an autolink, a reference
definition, a wikilink, an inline HTML tag such as an anchor, however its attribute values are quoted), with the scheme
spelled any way a renderer reads it (a backslash before `:`, character references such as `&#58;`), is stored as the
plain text it showed, so it never reaches a view as a link.

**Resolving.** Snapshots show each mention for the person reading it:

| The mention's key is | Shows (`kind`) | A click |
|---|---|---|
| a friend's | `@` and the reader's own name for that friend (`friend`) | opens their conversation: `conversation_id` |
| the reader's own | `@` and the reader's own name, highlighted (`you`) | nothing |
| anyone else's | `@` and the name the sender wrote, never the ID (`stranger`) | opens `card` |
| anyone else's, under a friend's or the reader's own ID | plain text, not a link (forged) | — |

A stranger's `card` shows the name, "Friends ID brave‑otter", and what the reader can do from there: **Add** for
someone with nothing between them, or someone removed (`add_from_mention` with the action's own `friends_id`,
`identity_key` and `name`); "Request sent" while a request of the reader's waits; Accept, Decline and Block (with the
card's `conversation_id`; Block armed) when they asked the reader; "Blocked", and nothing to press, for someone the
reader blocked; and, again with nothing to press, that the link no longer matches when the Friends host vouched that
the ID now belongs to another key. Its `tooltip` says the same in a few words before the click.

In a message item, `text` carries each mention that shows as a link as `[@Label](szfriends:mention?ref=n)`, and each
other one as the literal text `@Name`. `mentions[n]` describes the link whose destination is `mentions[n].url`, and
the segment holding its label carries `mention` `n`. Views match a click by comparing the link's destination with
`url`, never by parsing it, and open no other `szfriends:` link. A mention inside a code span or block shows there as
its link's source, which names nobody's ID or key.

**Clients without mentions.** A client that did not declare `mentions` gets every mention as literal text with the
same resolved name, and no `mentions`, segment `mention`, row `mentionable` or composer `mention_note`.

**Elsewhere.** List previews and search excerpts show each mention as `@Name`, resolved the same way. Search reads each
mention as the name its sender wrote, never its ID, key or scheme, so nothing is found through them and every result
has a match the excerpt can show; a friend the reader calls by another name is found by the sender's name for them.

**Adding from a mention.** `add_from_mention` sends a friend request exactly as `add_by_id` does, nearby and (with
`online`) online, bound to the key in the mention: only that identity key may answer it, and any other answer is
refused before a session starts, whoever holds the ID. The request's row is named with the mention's name until the
person's own profile arrives, and their answer then waits for acceptance like any answer to Add by ID. When the
person's own data already gives the ID to another key (one of their friends holds it, or the Friends host vouched for
someone else), nothing is sent and the reply is `mention_mismatch`, whose message says the link no longer matches that
person. A mention of the person themselves answers `id_is_yours`; of a friend, `already_friends`; of someone blocked,
`blocked`; of someone whose request waits for the person's answer, `stale` (the card offers Accept instead); asking
again while a request is waiting answers as the first time did.

## Thumbnails

Every file offer shows a preview before it is accepted, for any format the sender's Mac can preview: the first page
of a PDF or document, the picture itself, a frame of a video (brief § Transfers, Thumbnails before acceptance).

- **What views get.** A transfer item's `thumbnail` holds `path`, a PNG the helper wrote into its own cache; `width`
  and `height` in pixels, at most 192 on the longer side, so a view can lay the item out before loading it; and
  `source`: `sender` for the picture the sender's Mac made, `local` for one made on this Mac from the file itself.
  Views load only `path`, never decode anything a friend sent, and treat a file they cannot read as no preview.
  Both apps draw a preview at the same size: at most 64 points on its longer side and never more than one point per
  pixel, so a small picture is not enlarged and a 192-pixel one stays sharp at 2x and 3x. A view loads `path` only
  when it lies directly in `thumbnails/` in the helper's state directory, and only as a regular file (no link
  followed) holding a PNG of exactly `width` by `height`; anything else shows the type icon, as no preview does.
- **Where it comes from.** The sender's helper renders each attachment with the system thumbnailer (QuickLook on
  macOS), off its own queue, within 2 seconds, without delaying the offer: no picture by then means none. It encodes
  the picture as QOI, at most 192 pixels on the longer side and 64,000 bytes, smaller sizes tried until it fits, and
  sends it in a THUMBNAIL session frame after the OFFER, behind queued messages, until the friend's Mac acknowledges it
  (`service/session/SZFriendsSession.h`; session minor 1, so a helper that predates it is never sent one). The sender
  shows the same picture on its own item, with `source` `local`.
- **What the recipient keeps.** At most one picture per offer from that friend, while the file has not arrived
  (waiting for an answer, or receiving). The declared size and the image header are checked before anything is
  allocated; the image is decoded by the helper's own bounds-checked decoder and written out as a PNG the helper
  encodes itself. A picture for an offer that is not waiting, a second one, or one that fails a check is refused and
  changes nothing.
- **After the file arrives.** The sender's picture is the sender's word for what the file looks like, not proof:
  once the file arrives and its digest checks, a picture made on this Mac from the real file replaces it (`source`
  `local`), or, when this Mac cannot preview the format, nothing does and the type icon shows.
- **When it goes.** Declining, cancelling, or an offer that fails before anyone accepted it deletes its picture on
  that Mac; Delete history and Reset Friends delete pictures with their transfers.

## Links

Friend links and download links ([friends-links.md](../docs/plans/friends-links.md)) reach an app from the link's
web page, whose buttons open `shenzhenpdf://friends/link#<payload>` or `shenzhenfiles://friends/link#<payload>`.
Everything here exists only while the welcome lists the helper capability `links`: without it hosts show no link
items, and `open_link` fails with `unknown_intent`, whose `message` the link page shows.

**The app's URL.** The host checks it before anything else and drops it, with nothing sent, unless all of this holds:
at most 512 bytes; its own scheme, host `friends`, path `/link`, no user, password, port or query, and a fragment
that is the whole payload. The payload is `f.` (a friend link) or `d.` (a download link) followed by unpadded
base64url (RFC 4648 § 5) that decodes canonically (no `=`, no length of 1 mod 4, unused trailing bits zero) to:

| Kind | Bytes |
|---|---|
| `d.` | version `0x01`, the link id (16), the link secret (32): exactly 49 bytes |
| `f.` | version `0x01`, the identity key (32), the invite token (16), the Friends ID's length (1, 3 to 64) and the ID (lowercase ASCII words joined by `-`), the name's length (1, 0 to 160) and the name (UTF-8, no control characters): nothing after it |

The page's own link is `https://<link origin>/f#<base64url>` or `/d#<base64url>`: the app payload is its path's letter,
a dot and its fragment. Hosts pass the payload as they received it in `open_link`, and the helper parses it again;
a host never acts on a link without the helper's card, and the card's buttons are the only way it acts.

**The card.** `open_link` answers with `card`: what the link is, written for the person, and its actions (`Add` for a
friend link, `Download` for a download link), each a § Shared objects action with the link's `payload` as its own
field, sent as it is. The views show it as the dropdown's link page (AppKit and GTK alike): `title`, `subtitle`,
`note` and the avatar, then the actions; a failed `open_link` shows its error's `message` there instead (a link that
expired, was revoked or was reset is `not_found`; a payload the helper cannot parse is `invalid_field`). The card
never shows anything the link's own bytes do not say, except what this Mac knows (that the person is already a
friend).

**Copying a download link.** Hosts offer Copy Download Link on one document (ShenzhenPDF: File ▸ Share, the tab's
menu and the drop panel's **Copy link instead**; Shenzhen Files: the file's context menu) with the expiry choice of
1, 7 or 30 days, 7 first. Their words are the host's own, because a host shows its menus while no helper runs. The
host sends `make_download_link` with the file object (§ Intents, Files: bound to the same immutable snapshot, an APFS
clone or the recorded size, date and SHA-256) and puts `url` on the pasteboard when the reply arrives, then shows
`message`, which says until when and on what condition the link works.

**Your links.** The profile's `links` (§ Schemas, `snapshot.profile`) is present while the helper announces `links`:
the friend link with Copy (client-side, `url`) and its `reset` action (`reset_friend_link`, with `confirm`, which
stops the old link working), then every live download link with its file's name, the downloads so far, when it
expires, and its `revoke` action (`revoke_link` with the action's own `link_id`).

**The helper** (`service/links/`, `SZFriendsLinks.h`). It announces `links` while it checks in with a Friends host,
whose web origin the links name: the signed list's `links` entry, else the main host's own. A download link holds its
file at once: an APFS clone in the state directory, or, where no clone can be made, the original's size, dates, inode
and SHA-256, served only while they still hold (the SHA-256 decides when only the change time moved). It sends
`link_register` for every live link on each host connection, `link_unregister` on Revoke, and forgets a link when it
expires (the clone goes with it). What it keeps of a link that ended is a tombstone for 31 days: the link id's hash
(`SZFriendsLinkTombstoneHash`, SHA-256 of `SZFriends link tombstone v1 ‖ id`) and why, revoked or expired, at most
500 (settings key `link_tombstones`); it sends them in `link_tombstones` when the link ends (on Revoke before
`link_unregister`) and on every host connection, and the host answers an open of such a link at once with
`link_ended` (HOST-PROTOCOL-ONLINE.md § Download links), so `/d` and `receive_link` say "revoked" or "expired" instead
of waiting. An open via a link id it does not hold gets no answer at all; a link it holds but
that expired gets `end` `expired` in reply to the hello; after the proof, a source that changed gets `end` `changed`
before any connection exists, and an `E` record `changed` instead of `F` if the bytes it read do not hash to the
link's SHA-256. The metadata JSON also carries `from`: `identity_key`, `friends_id`, `blake2b` (the file's BLAKE2b-256,
base64url) and `sig`, the sender's Ed25519 signature (domain `SZFriends link sender v1`) over the link id, the SHA-256,
the BLAKE2b, the size (8 bytes) and the file's name, the Friends ID and the sender's name, each length-prefixed (4
bytes, UTF-8). Pages ignore it. `receive_link` runs the page's exchange from the app's own helper, through its own host
connection (`sig_open` with `to.link_id`; the Rust helper opens a guest connection of its own, as the page does), with
the same attempts and timers; it needs `from` to verify, and files the
file as an accepted incoming transfer in that person's conversation (a row of their own if they have none, which offers
Add on their files until they are friends), checked against the BLAKE2b as any transfer is, then records the event
"Sent you Site photos.pdf through a link". It replies once the metadata arrived, or with `link_offline` when the
sender's Mac is not connected (it does not wait for it), `not_found` (revoked or expired), `link_changed` or
`link_failed`; a download whose connection drops mid-file carries on (below, Browser downloads) into the same
transfer, as a transfer resumes (ADR 0001), giving up only after 3 drops in a row that brought nothing new. A friend
link's `add_from_link` is `add_from_mention` for the link's key and ID, with the link's invite:
its REQUEST_BY_ID carries InviteProof (session field 32, HMAC-SHA-256 keyed with the invite token over
`SZFriends invite v1 ‖ h`), and the holder accepts a request whose proof matches a live invite at once ("Added through
your link"; the requester's history says "Added through Mei’s link"), at most 20 in any 24 hours through the standing
link (`SZFriendsInviteAcceptsPerDay`); past that the request waits for the person like any other. Requests by Friends
ID travel between Macs that are nearby and, once the helper reaches friends online, through the host as well
(`SZFriendsOnlineDriver.h`, Add by ID online: Noise NN carries REQUEST_BY_ID and RECEIVED, and no peer connection
exists until the holder's IK callback, which presents the request's token; a request from a mention or a friend link
admits only the key it carries, so that key's acceptance makes a friend at once, with no host attestation needed, while
any other Add by ID's acceptance without one becomes a request the person accepts). Reset revokes the standing invite
and makes a new one; one-time invites (30 days, used once) exist in the store, with no intent yet.

**The pages** (the host-pages area: `server/friends/src/pages/`, served by the Friends host at `/f` and `/d`). `/f`
reads its fragment as an `f.` payload and shows "Mei invited you to Shenzhen Friends" with **Open in ShenzhenPDF**,
**Open in Shenzhen Files** and **Open in Shenzhen 3D**, plain links to `<scheme>://friends/link#f.<fragment>` with the
schemes `shenzhenpdf`, `shenzhenfiles` and `shenzhen3d`; the app chosen last leads the next time (the browser's local
storage, key `szfriends-app`; no cookies). A browser cannot tell whether an app took the link, so 1.5 seconds after an
Open button the page says that app may not be on this Mac (or computer) yet, above a Get link for each app. On
Windows and Linux it offers **Open in Shenzhen 3D** alone, the only app with Friends there; elsewhere, phones included
(Shenzhen 3D's phone builds reach friends only nearby and open no links), it says where Friends works and shows no
Open button. `/d` reads a `d.` payload, connects as a guest at once and says "Waiting for the sender" until the sender
answers, then shows the file's name, size and thumbnail with **Download** and the same Open buttons. Both pages parse the payload as strictly as the helper, and say the link is incomplete
otherwise. Neither sends the fragment anywhere: `/d` gives the host only the link id. A `d.` payload is exactly 49 bytes
everywhere (the page, the helper and every app's URL check; `service/links/tests/download-payloads.json`) and carries no
name: the sender's name travels only inside the sealed metadata, so `/d` says "the sender" while it waits and
names the sender once the metadata arrives. Names and file names from the sender lose the invisible format characters
the helper strips (`SZFriendsIsStrippedCharacter`: U+061C, U+200B, U+200E–200F, U+202A–202E, U+2060, U+2066–2069,
U+FEFF, U+FFF9–FFFB) before the page shows them or offers the file's name to the browser, so `Invoice ` + U+202E +
`fdp.exe`, which would display as `Invoice exe.pdf`, shows and saves as the `.exe` it is.

**Browser downloads.** What `/d` and the sender's helper say to each other through the host (HOST-PROTOCOL-ONLINE.md
§ Download links). Integers are big-endian; `S` is the link secret, `id` the link id. Keys are HKDF-SHA-256 of `S`,
32 bytes:

| Key | Salt | Info | For |
|---|---|---|---|
| setup | `id` | `SZFriends link setup v1` | AES-256-GCM: setup payloads before the challenge |
| proof | `id` | `SZFriends link proof v1` | HMAC-SHA-256: the proof |
| session | `n_o ‖ n_s` | `SZFriends link session v1` | AES-256-GCM: setup payloads after the challenge |
| content(a) | `n_o ‖ n_s` | `SZFriends link content v1 ‖ a` | AES-256-GCM: records on attempt `a` (one byte) |

A setup payload (the `payload` of `link_open` and of each `sig_msg`, at most 4,096 bytes) is a random 12-byte nonce,
then AES-256-GCM of one JSON object with associated data `SZFriends link setup v1 ‖ sealer ‖ id`, the sealer one
byte: `O` (0x4F) the page, `S` (0x53) the sender. Whatever does not open, or opens to something unexpected, is
ignored without an answer. `n_o` and `n_s` are 16 random bytes each, base64url in the JSON.

| Step | From | Key | JSON |
|---|---|---|---|
| 1 | page, in `link_open` | setup | `{"t":"hello","v":1,"n":n_o}` |
| 2 | sender | setup | `{"t":"challenge","n":n_s,"o":n_o}`, or `{"t":"end","reason":…}` |
| 3 | page | session | `{"t":"proof","mac":…}`: HMAC(proof, `SZFriends link proof v1 ‖ id ‖ n_s ‖ n_o`) |
| 4 | page | session | `{"t":"offer","a":1,"relay":false,"sdp":…}` |
| 5 | page | session | `{"t":"cand","a":1,"c":[[candidate,mid],…]}`, finally `{"t":"cand","a":1,"end":true}` |
| 6 | sender | session | `{"t":"answer","a":1,"sdp":…}` and its own `cand` messages; `end` at any time |

- The sender stays silent to a hello that does not open, creates no peer connection until a proof verifies (compared
  in constant time), and closes the sid on a wrong one.
- `end` reasons are `revoked`, `expired`, `changed` (a source without a clone changed after linking) and
  `unavailable` (anything else, and any reason the page does not know). A sender that still remembers a revoked or
  expired link answers `end` rather than staying silent; for one it no longer holds, its tombstone makes the host
  answer `link_open` with `sig_opened` carrying `link_ended` (`revoked` or `expired`) and no sid, and the page says so
  at once. Only a link nobody ever ended this way leaves the page to say, after the host's 2 minutes, that the link
  isn't working.
- The page offers and creates the one data channel, `szf-link`, ordered and reliable. Attempt 1 uses only the STUN
  servers the page was served with. If its channel has not opened within 12 s, the page asks the host for
  `relay_credentials` and makes attempt 2 with `"relay":true` and relay candidates only; the sender drops attempt 1,
  takes its own relay credentials and opens a new peer connection with relay candidates only (the relay reaches only
  relays). Without a channel 25 s later the page gives up.
- Once the channel is open the page closes the sid, which ends its guest connection; the peer connection stays.

Records travel one per data-channel message, at most 65,536 bytes: a type byte, then AES-256-GCM under content(a)
with the nonce `type ‖ 00 00 00 ‖ index` (index 64 bits) and associated data `SZFriends link record v1`.

| Type | From | Index | Plaintext |
|---|---|---|---|
| `M` 0x4D | sender, when the channel opens | 0 | the JSON's length (4), the metadata JSON, a PNG or nothing |
| `C` 0x43 | sender | 0, 1, … | exactly 65,280 bytes of the file |
| `F` 0x46 | sender | the last chunk's | the rest, 0 to 65,280 bytes; an empty file is one empty `F` |
| `E` 0x45 | sender, instead of its next record | 0 | `{"reason":…}`, as for `end` |
| `Q` 0x51 | page | 0, 1, … (its own count) | `start`, `credit`, `cancel` or `done` (below) |

- The metadata JSON: `name` (1 to 255 characters), `size` (0 to 2^53 − 1), `sha256` (the file's, base64url), and
  optionally `type` and `sender` (the sender's name). The page's `Q` records are `{"t":"start","upto":64}` (with
  `"from":k` when a download carries on from chunk `k`, below),
  `{"t":"credit","upto":n}`, `{"t":"cancel"}` and `{"t":"done","ok":true}`. Chunk `i` starts at byte
  `i × 65,280`; a file has max(1, ⌈size / 65,280⌉) chunks.
- Chunks go only after `start`, and only while their index is below the latest `upto`. The page grants 64 ahead and
  moves `upto` every 16 chunks it has written, so a slow disk never fills its memory.
- The page hashes each chunk as it arrives and writes the `F` chunk only once the whole file's SHA-256 matches. A
  record that does not open, a short `C` or sizes that do not add up fail the download, and nothing partial is kept.
  `done` tells the sender a download completed, for its count.
- A download whose connection drops before `F` (the channel closes, the peer connection fails or stays disconnected
  8 s, or nothing arrives for 30 s while the sender has credit; the relay ends every session after an hour) carries
  on in the same page: it opens the link again from step 1 with a new `n_o`, so a new session and content key, checks
  that the new `M` names the same size and SHA-256, and sends `{"t":"start","from":k,"upto":k+64}` where `k` is the
  first chunk it has not written. Its hash and its sink carry over, so files of any size finish, through the relay
  too. The sender hashes bytes `0` to `k × 65,280` again before sending chunk `k`, so `F` still goes only for the file
  the link was made for; a `from` that is not a chunk of the file ends the channel. After 3 reconnections in a row
  that brought no new chunk the page gives up ("lost"), and nothing partial is kept. Try again starts afresh.

## Devices

One person's Friends on several computers ([friends-multi-device.md](../docs/plans/friends-multi-device.md); how the
helpers agree on who belongs is [ADR 0012](docs/adr/0012-device-chain.md), how they stay in sync
[ADR 0014](docs/adr/0014-sync.md)). Everything in this section and in § Joining exists only while the welcome lists
the helper capability `devices`: the fields marked so in § Schemas are absent without it, and the intents fail with
`unknown_intent`. The views' words say "computer", never anything about how computers belong to a profile; every
string is display-ready, from the catalog (`service/presentation/SZFriendsCatalogDevices.m`).

**Your computers.** The profile's `devices` (`fixtures/snapshots/devices-profile.json`) lists every computer that
uses this profile, this one first, then the others by when they joined; removed ones are gone from it. `title` is the
section heading ("Your computers"), `note` says how to add one ("To add a computer, open Friends on it and choose Use
my existing profile."), and `rows` are `type.device_row`:

| Field of `type.device_row` | Type | What the view does with it |
|---|---|---|
| `device_id` | string | Opaque id (§ Framing), stable for the computer; sent back in `revoke_device` |
| `name` | string | The computer's name, as it named itself: "Raph’s Mac mini" |
| `system` | string | Its system: "macOS 26.1", "Linux" |
| `last_connected` | string | "This computer" on this computer's row; "Now" while connected; "5 min ago" within the hour; then the list's time words ("14:32", "Yesterday", "3 Oct"); "Not connected to this computer yet" for one this computer has never reached |
| `detail` | string | The line under the name: `system` and `last_connected` joined, "macOS 15.7 · Now" |
| `this_computer` | bool | The row of the computer showing it |
| `state` | enum | `connected` (this computer, or a session with it is live), `not_connected`, `never_connected`; views may draw a dot by it |
| `accessibility_label` | string | The row read aloud: "Raph’s Mac mini, macOS 15.7, connected now" |
| `rename` | object or null | This computer's row only: a field (`label` "Rename", `placeholder`, `button_label`, `max_bytes` 64) that sends `rename_device` |
| `remove` | action or null | `revoke_device` with its `device_id` and `confirm`; null on this computer's row, which leaves the profile only through Reset Friends |

**Removing a computer.** The view asks with the action's `confirm` first and sends `revoke_device` with `device_id`
only on its confirm button. The confirmation says what happens: "Remove Raph’s Mac mini?", "Raph’s Mac mini stops
getting your messages and files. Your friends stop accepting messages from it as soon as one of your computers
connects to them. Chats already on it stay there. To use Friends on it again, start over there, then add it to your
profile again.", button "Remove". The reply comes once the removal is stored here, and the row is gone from the next
snapshot; the removal reaches the person's other computers and their friends the next time each connects. Errors:
`not_found` ("That computer was already removed.") for an unknown or already removed `device_id`, `not_allowed` for
this computer's own id or when this computer has itself been removed.

**Renaming this computer.** `rename_device` with `name`: 1 to 64 bytes of UTF-8 after trimming, no control
characters; the person's other computers show the new name once they connect. Errors: `name_invalid` ("Type a name
for this computer.", or "That name is too long or has a line break. Try a shorter one."), `not_allowed` when this
computer has been removed.

**This computer was removed.** When another of the person's computers removed this one, the list's `state` is
`device_removed` and `removed` (`type.device_removed`, `fixtures/snapshots/devices-list-removed.json`) says what
happened and what the person can do: "This computer was removed from your profile", "Another of your computers
removed it, so it no longer sends or receives messages. Your chats here stay readable. To use Friends here again,
start over, then choose Use my existing profile.", and its `action`, `reset_friends` with a `confirm` ("Start over on
this computer?"). The views show it above the rows, which stay and open their conversations for reading, and show no
Add by ID, no Nearby tab and no join rows; conversations come with the composer hidden (`visible` false), rows refuse
drops ("This computer can’t send anymore"). Intents that would send or change anything fail with `not_allowed`
("This computer was removed from your profile, so it can’t send anything."). Otherwise `state` is `normal` and
`removed` null. A computer removed while it was away learns it as soon as one of the person's other computers is
nearby (they look for it, and answer it only with the device chain that removed it) or the host turns its check-in
away.

**You.** A conversation with yourself (`conversation_id` `you`), whose messages and files reach every computer of the
profile (`fixtures/snapshots/devices-list.json`, `devices-conversation-you.json`). Its list row has `kind` `you` (every
other row `person`), the person's own avatar, title "You", the last item as its subtitle or "Send yourself messages and
files" while it is empty, route kind `none`, and `drop_label` "Send to all your computers". The row shows while the
profile has two or more computers, or once You holds anything. Its conversation has header "You" with subtitle "On all
your computers" and `details_available` false, no `request`, and a composer whose placeholder is "Message yourself" and
whose `note` is null unless something here has not reached every computer yet: "What you send here reaches your other
computers when ShenzhenPDF, Shenzhen Files or Shenzhen 3D is open on them." `send_message` and `send_files` to `you`
work as to a friend. A message's `status` is `queued` "Waiting for your other computers" until every computer has it,
then `delivered` "On all your computers"; a file is `queued` ("Copies to your other computers when they connect"),
`sending` ("Copying to your other computers · 40%") or `delivered` ("On all your computers"). Files in You copy to every
computer whatever their size.

**Files another computer holds.** A file one of the person's other computers received is in the history here at once;
files up to 25 MB copy here by themselves, and a larger one waits on the computer that has it: its transfer item has
`state` `on_device`, `status_label` "On Raph’s Mac mini" and the action `fetch_from_device` ("Get", primary), sent with
the item's `transfer_id` (`fixtures/snapshots/devices-conversation-mei-files.json`). After Get, `state` is `fetching`:
with `progress` and "Copying from Raph’s Mac mini · 25%" while it copies, or `progress` null and "Copies when Studio
workstation is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open" ("online or nearby" with the helper
capability `online`) while that computer is not connected; Cancel (`cancel_transfer`) stops it and the item returns to
`on_device`. Once here it is `received` with its `path`, as any received file. Errors of `fetch_from_device`:
`not_found` ("This file isn’t on your other computers anymore."), `not_allowed` when it is already here, `disk_full`.

**Deleting history on several computers.** `delete_history` deletes on every computer of the profile (ADR 0014,
tombstones), so while the profile has two or more computers the words say so: Settings' `history.note` "Stored on all
your computers. Deleting it keeps your friends and the files you received.", its `confirm.body` "Your messages and
file history, with every friend and in You, are deleted from this computer, and from your other computers as soon as
they connect. …", and a friend's Delete chat history note "Clears this chat on all your computers. Mei stays your
friend." with a confirmation that begins the same way (`fixtures/snapshots/devices-settings.json`,
`devices-details-mei.json`). A profile on one computer keeps the one-computer words.

## Joining

A new computer joins its person's profile ([friends-multi-device.md](../docs/plans/friends-multi-device.md) §
Joining; [ADR 0013](docs/adr/0013-joining.md)): it asks by Friends ID, one of the person's computers approves and
shows an 8-digit code, and the code typed on the new computer proves to both that they reached each other. The
exchange between helpers is `service/identity/SZFriendsJoin.h`; this section is what the views see. Its fixtures are
`fixtures/snapshots/join-*.json`, `list-join-requests.json`, `badge-join-requests.json` and
`devices-list-new-computer.json`.

**On the new computer: the `join` view.** A fresh list's `name_prompt` carries `join_label` ("Use my existing
profile") while this computer could join (it has no friends yet); the views show it as a link under the name field,
and pressing it shows this view: `subscribe` with view `join` (no params).

| Field of `snapshot.join` | Type | What the view does with it |
|---|---|---|
| `state` | enum | `idle`, `waiting`, `checking`, `wrong_code`, `not_reached`, `denied`, `expired`, `too_many_attempts`, `joined`, or `unavailable` (this computer already has friends, so joining is not offered) |
| `title` | string | The heading |
| `message` | string or null | The line under it |
| `friends_id` | string or null | The ID asked for, ASCII, from `waiting` on |
| `id_field` | object or null | `idle`: a field with `placeholder` and a `button`, which sends `join_profile` with what was typed |
| `code_field` | object or null | `waiting` to `not_reached`: `length` (8), `placeholder`, `button` (sends `enter_join_code`) and `enabled` (false while `checking`) |
| `error` | string or null | Why the last code did not work: it did not match, or no computer of the profile answered |
| `actions` | array | § Shared objects actions: `cancel_join` (Cancel) while joining; `join_profile` with `friends_id` (Start again) and Cancel after Deny, an expired code or three wrong codes |

`join_profile` takes `friends_id` as `add_by_id` does (U+2011 read as `-`); errors `id_invalid`, `id_is_yours`, and
`not_allowed` when this computer already has friends or shares a profile. `enter_join_code` takes `code`, eight digits
with any spaces or dashes; `invalid_field` (field `code`) otherwise, `not_allowed` when no request is waiting.
`cancel_join` stops asking. Once `joined`, the computer has the profile's name, ID and picture; friends and chats
follow from the person's other computers.

**On the person's other computers: join rows.** The list carries `join_requests`, oldest first, above the rows, and
the badge counts each one (both ways of waiting count: for the person's Approve, and for the code to be typed):

| Field of `type.join_request` | Type | What the view does with it |
|---|---|---|
| `join_id` | string | Opaque; sent back in `approve_join` and `deny_join` |
| `state` | enum | `waiting` (Approve and Deny) or `approved` (the code shows) |
| `title` | string | "Raph’s MacBook Air wants to join your profile"; approved: "Type this code on Raph’s Mac mini" |
| `subtitle` | string | "macOS 26.1 · Approve only if you’re setting up that computer now"; approved: "macOS 15.7 · Waiting for the code" |
| `code` | string or null | Approved: the code in two groups, "4831 2207", drawn large and selectable |
| `code_accessibility_label` | string or null | The code digit by digit, "4 8 3 1, 2 2 0 7" |
| `code_note` | string or null | When the code stops working, and that it goes to nobody |
| `actions` | array | § Shared objects actions. Waiting: `approve_join` (primary) and `deny_join` with `arm`; approved: `deny_join` labelled Cancel |
| `accessibility_label` | string | The row read aloud |

A request is never approved by itself: only `approve_join` draws a code. `approve_join` and `deny_join` take
`join_id`; `not_found` once that request is gone (it expired, another of the person's computers added the computer,
or the new computer started again). `approve_join` on a row already approved succeeds and keeps the code it shows;
views disable Approve once pressed, until the snapshot shows the code. Deny is final for that request, and the same
computer's requests are turned away for 30 minutes. Cancel on an approved row withdraws the code the same way.

**Between the computers.** Nothing here is stored: a helper keeps requests and codes in memory, and a restart forgets
them (the new computer asks again).

- The request (keys, name, system, the ID typed, signed by the new computer's key) goes nearby over Noise NN as Add by
  ID does, to every device the new computer cannot recognise, and every device answers RECEIVED alike. Online it is
  the payload of an open to the Friends ID (`'J'`, 1, the request): the host hands it to each connected device of
  that profile, nobody answers, and it counts against the caller's join opens, 40 an hour as the host counts them,
  never against Add by ID's 5 opens by ID. Each repeat refreshes the row; the new computer repeats it once per
  presence window nearby and every 20 minutes online.
- A device shows at most 3 rows at once and 6 new rows an hour, one per requesting computer. At 3 rows the newest
  request takes the place of the waiting row repeated least recently (an approved row keeps its place), and taking a
  place is not a new row, so requests nobody wants never use up the hour; a row denied, or ended because another of
  the person's computers added that computer, gives its hour's slot back. A row ends 30
  minutes after the last copy of its request, as soon as the device chain carrying the new computer reaches this one,
  or with the profile (Reset Friends).
- Approve shows a fresh code for 5 minutes. Typing it starts one CPace run (draft-irtf-cfrg-cpace-13, ristretto255,
  SHA-512) per session from the new computer: nearby to every device again, online as an open carrying NN message 1
  (`'J'`, 2) that only a device holding an approval answers. The code is the password, the session's handshake hash
  the sid, and the request's keys are bound in, so whoever sits between the two computers learns nothing and gets
  one guess per run; each run costs one of three attempts, and the third failure ends the approval. A wrong code
  shows `wrong_code`; no answer within 10 s, `not_reached`.
- The approving computer then signs the add link, stores the chain, and sends the chain and the profile, in parts of
  900 bytes, on the same session. The new computer checks that the chain holds it and the computer that showed the
  code, then adopts both.
- On the wire: session frame JOIN (25) with one field, Join (34, 1 to 1,000 bytes), only in NN and in both directions
  (`service/session/SZFriendsSession.h`); online the same frames travel as Frame items, at most three to a payload.

```schema snapshot.join
data.state: enum(idle,waiting,checking,wrong_code,not_reached,denied,expired,too_many_attempts,joined,unavailable)
data.title: string
data.message: string|null
data.friends_id: string|null
data.id_field: @join_id_field|null
data.code_field: @join_code_field|null
data.error: string|null
data.actions: array
data.actions[]: @action
```

```schema type.join_id_field
placeholder: string
button: string               # sends join_profile with the typed ID as friends_id
```

```schema type.join_code_field
length: integer              # 8
placeholder: string
button: string               # sends enter_join_code with the typed code
enabled: bool                # false while a code is being checked
```

```schema type.join_request
join_id: string
state: enum(waiting,approved)
title: string
subtitle: string
code: string|null
code_accessibility_label: string|null
code_note: string|null
actions: array
actions[]: @action
accessibility_label: string
```

```schema intent.join_profile
friends_id: string
```

```schema intent.enter_join_code
code: string
```

```schema intent.cancel_join
type: enum(cancel_join)
```

```schema intent.approve_join
join_id: string
```

```schema intent.deny_join
join_id: string
```

## Static strings

`welcome.strings` holds the labels that do not depend on state, keyed as below, so the catalog stays in the
helper and GTK and AppKit show the same words. Views show nothing rather than invent text when a key is absent.
Views fill in only these: in the four drag strings, `{count}` with the number of files (`drop_send_many`) or of
files after the first (`drop_send_file_and_more`) and `{name}` with the first file's name, using the named forms
when they know every file's name and the counted forms otherwise; in `link_elsewhere`, `{host}` with where a link
really goes (its host, or the address of an email link) and `{shown}` with the site the link's words show. The link
menu of a friend's message shows `link_elsewhere` only when the two differ, then the real address, then
`link_open`, or `link_open_email` for an email link. `queued_note` is for a host's own surfaces, such as the Send
card in ShenzhenPDF's AI chat, which fill `{first}` with the friend's name; the conversation's `composer.note`
carries the same sentence filled in. A helper that announces `online` says "online or nearby" in it instead.
`show_all` labels the control under a message a view shows as plain text and cuts short to keep the conversation
quick to open; pressing it shows the rest of that message. `drop_folders_refused` and `drop_not_a_file` are what a
target that takes files says while a folder, or a symbolic link or special file (FIFO, socket, device), is dragged
over it: the helper sends only regular files, so views refuse the others there.

| Key | English |
|---|---|
| `button_label` | Friends |
| `tab_friends` | Friends |
| `tab_nearby` | Nearby |
| `search_placeholder` | Search names and IDs |
| `people_nearby` | People nearby |
| `back` | Back |
| `copy` | Copy |
| `copied` | Copied |
| `copy_your_id` | Copy your ID |
| `edit_name` | Change the name friends see |
| `conversation_search_placeholder` | Search this conversation |
| `attach_keys` | ↵ Attach · Esc Close |
| `attach_note` | Attaching sends nothing yet |
| `drop_hint` | Drop on a friend to send. Release on the Friends button to choose afterwards. |
| `drop_folders_refused` | Folders can’t be sent yet |
| `drop_not_a_file` | Links and special files can’t be sent. Drop the original file instead. |
| `drop_send_one` | Send 1 file to… |
| `drop_send_many` | Send {count} files to… |
| `drop_send_file` | Send {name} to… |
| `drop_send_file_and_more` | Send {name} and {count} more to… |
| `animals_title` | Choose an animal |
| `crop_title` | Crop your picture |
| `crop_use` | Use Picture |
| `cancel` | Cancel |
| `loading` | Loading… |
| `load_earlier` | Show earlier messages |
| `link_open` | Open in Browser |
| `link_open_email` | New Email |
| `link_elsewhere` | Goes to {host}, not {shown} |
| `queued_note` | Messages and files send when {first} is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open. |
| `show_all` | Show all |

## Limits

| Limit | Value | On excess |
|---|---|---|
| Frame | 8 MiB without the line feed | `goodbye` `frame_too_large`, close |
| Connections per helper | 64 | `goodbye` `too_many_clients` |
| Subscriptions per connection | 32 | `too_many_subscriptions` |
| Unanswered intents per connection | 64 | the helper stops reading until it has replied |
| Message text | 32,768 bytes UTF-8, so it fits one session frame (ADR 0001) | `invalid_field` |
| Files per `send_files`, attachments per message | 100, 20 | `too_many_files` |
| Name | 1 to 40 characters after trimming, no control characters | `name_invalid` |
| Filter and search query | 200 characters | `invalid_field` |
| `search_messages` limit | default 20, at most 50 | clamped |
| Picture input | 5 MiB decoded, 8192 px on the longer side | `picture_invalid` |
| Picture stored and sent | 256 × 256 px, at most 48 KiB (49,152 bytes), so it fits one session frame | re-encoded |
| Assistant scope | 64 conversations or all; 10 minutes | `scope_invalid` |
| Assistant results | 20 per search; excerpts 280 characters; reads 20 messages each side | clamped |
| Conversation window | 200 items, `load_earlier` adds 200 | — |
| `message_status` messages | 1 to 16 per subscription | `invalid_field` |
| Mentions per message | 20 | `invalid_field` when sending; plain text beyond them on arrival |
| Mention name | 64 characters (Unicode scalar values) | cut short when sending; plain text on arrival |
| File preview | 192 px on the longer side; 64,000 bytes of QOI between Macs; made within 2 s | smaller sizes tried; none after 2 s |
| Snapshot rate | 10 per second per subscription; progress 4 per second | coalesced |
| Visibility | 5 minutes from `start_visibility` | stops on both adapters at once |

## Schemas

The blocks below are machine-readable and are the field reference. `friends-protocol-check` parses them from
this file and validates every fixture against them, and fails when a schema has no fixture, so this document,
the fixtures and the views cannot drift apart silently.

Grammar, one rule per line, `#` starts a comment:

```text
path[?]: type[|type...] [when key=value[,value...]]
```

- `path` is dot-separated keys from the frame (or, in `type.*` blocks, from the typed object); `name[]` means
  every element of the array `name`.
- `?` after the path: the key may be absent. Without it the key must be present.
- Types: `string`, `integer`, `number`, `bool`, `object`, `array`, `null`, `any`, `enum(a,b,c)` (a string from
  the list), `@name` (an object matching block `type.name`). `|` joins alternatives; `null` must be listed for a
  value to be null.
- `when key=value` applies the rule only when `key`, a dotted path from the base object (no `[]`), holds one of
  the listed values; otherwise the rule is skipped and the key may be absent.
- Rules below a `null` value, or below an absent key that a `?` rule declares optional, are skipped: the parent's
  rule already decided whether that is allowed. `attachments?: array` with `attachments[]: @file` checks each
  attachment only when the list is present.

Block names: `frame.<type>` for frames, `snapshot.<view>` for a snapshot's view data, `intent.<type>` for
intents (beside the `frame.intent` envelope), `result.<intent>` for a reply's result, `type.<name>` for shared
objects. Fixture mapping: a snapshot uses `frame.snapshot` and `snapshot.<view>`; `hello`, `welcome`, `reply`
and `goodbye` use `frame.<type>`; each line of `fixtures/intents.jsonl` uses `frame.intent` and
`intent.<type>`; `fixtures/replies/<intent>.json` (successful replies) uses `frame.reply` and `result.<intent>`.
Failed replies are plain `reply` frames under `fixtures/frames/`.

### Frames

```schema frame.hello
type: enum(hello)
id: string
protocol.major: integer
protocol.minor: integer
protocol.min_major: integer
client.app_id: string
client.app_name: string
client.app_version: string
client.toolkit: enum(appkit,gtk4)
client.reveal_in: string
client.pid: integer
embedded_helper: object|null
embedded_helper.version: string
embedded_helper.build_number: integer
embedded_helper.protocol.major: integer
embedded_helper.protocol.minor: integer
capabilities: array
capabilities[]: string
open_formats: array
open_formats[]: string
locale: string
```

```schema frame.welcome
type: enum(welcome)
re: string
protocol.major: integer
protocol.minor: integer
helper.version: string
helper.build_number: integer
helper.protocol.major: integer
helper.protocol.minor: integer
helper.pid: integer
handover: enum(none,scheduled)
capabilities: array
capabilities[]: string
limits.max_frame_bytes: integer
limits.max_message_bytes: integer
limits.max_files_per_send: integer
limits.max_subscriptions: integer
strings: object
strings.button_label: string
strings.tab_friends: string
strings.tab_nearby: string
strings.search_placeholder: string
strings.people_nearby: string
strings.back: string
strings.copy: string
strings.copied: string
strings.copy_your_id: string
strings.edit_name: string
strings.conversation_search_placeholder: string
strings.attach_keys: string
strings.attach_note: string
strings.drop_hint: string
strings.drop_folders_refused: string
strings.drop_not_a_file: string
strings.drop_send_one: string
strings.drop_send_many: string
strings.drop_send_file: string
strings.drop_send_file_and_more: string
strings.animals_title: string
strings.crop_title: string
strings.crop_use: string
strings.cancel: string
strings.loading: string
strings.load_earlier: string
strings.link_open: string
strings.link_open_email: string
strings.link_elsewhere: string
strings.queued_note: string
strings.show_all: string
```

```schema frame.reply
type: enum(reply)
re: string|null              # null only when the frame being answered had no usable id
ok: bool
result: object when ok=true
error: @error when ok=false
```

```schema frame.snapshot
type: enum(snapshot)
subscription: string
view: enum(badge,list,nearby,conversation,details,profile,settings,message_status,join)
rev: integer
data: object
```

```schema frame.goodbye
type: enum(goodbye)
reason: enum(handover,shutdown,protocol_error,reset,too_many_clients)
message: string|null
successor: object when reason=handover
successor: null when reason=shutdown,protocol_error,reset,too_many_clients
successor.version: string
successor.build_number: integer
error: @error when reason=protocol_error
error: null when reason=handover,shutdown,reset,too_many_clients
```

```schema frame.intent
type: string
id: string
```

### Shared objects

```schema type.error
code: enum(bad_frame,frame_too_large,hello_required,protocol_unsupported,unknown_intent,invalid_field,not_found,not_allowed,rate_limited,too_many_subscriptions,identity_unavailable,name_invalid,id_invalid,id_is_yours,already_friends,blocked,not_friends,file_missing,folder_not_supported,too_many_files,source_changed,disk_full,picture_invalid,scope_invalid,stale,mention_mismatch,link_offline,link_changed,link_failed,too_many_links,internal,not_ready,connection_lost)
message: string|null
retryable: bool
details: object
```

```schema type.avatar
kind: enum(animal,image,placeholder)
initials: string
color: string
set: integer when kind=animal
index: integer when kind=animal
path: string when kind=image
```

```schema type.route
kind: enum(local,online,connecting,offline,none)
method: enum(lan,p2p_wifi,bluetooth,internet,relay)|null
label: string|null
```

```schema type.action
action: enum(accept_request,decline_request,cancel_request,block,unblock,remove_friend,send_request,add_from_mention,accept_offer,decline_offer,cancel_transfer,cancel_message,retry_item,mark_verified,accept_key_change,dismiss_banner,start_visibility,stop_visibility,activate,reset_friends,delete_history,open_file,show_file,open_settings,add_from_link,receive_link,reset_friend_link,revoke_link,revoke_device,fetch_from_device,join_profile,cancel_join,approve_join,deny_join)
label: string
style: enum(primary,secondary,link,destructive)
note?: string|null
confirm?: @confirm|null      # ask first; reset_friends and remove_friend always carry one
arm?: @arm|null              # ask for a second click first; block always carries one
path: string when action=open_file,show_file
settings_target: enum(local_network_privacy,bluetooth_privacy,bluetooth,wifi) when action=open_settings
friends_id: string when action=add_from_mention,join_profile   # the intent's fields, sent as they are
identity_key: string when action=add_from_mention
name: string when action=add_from_mention
payload: string when action=add_from_link,receive_link   # the link's payload, sent as it is (§ Links)
link_id: string when action=revoke_link
device_id: string when action=revoke_device     # § Devices
join_id: string when action=approve_join,deny_join   # § Joining
```

```schema type.segment
text: string
url?: string
emphasis?: bool
match?: bool
mention?: integer            # index into the message item's `mentions` (§ Mentions)
```

```schema type.back
badge_count: integer
badge_label: string
accessibility_label: string
```

```schema type.footer
avatar: @avatar
name: string|null
name_placeholder: string
id_label: string
id_note: string|null         # while the ID is unreserved; null on a phone without online, which never confirms it
friends_id: string
add_label: string
```

```schema type.empty
kind?: enum(searching,nobody,unavailable,no_match)
title: string
body: string|null
```

```schema type.confirm
title: string
body: string
confirm_label: string
cancel_label: string
destructive: bool            # draw the confirm button in the destructive color
```

### Views

```schema snapshot.badge
data.count: integer
data.label: string
data.accessibility_label: string
```

```schema snapshot.list
data.query: string
data.banner: @banner|null
data.name_prompt: @name_prompt|null
data.rows: array
data.rows[]: @list_row
data.empty: @empty|null
data.footer: @footer
data.state?: enum(normal,device_removed)   # present while the helper announces `devices` (§ Devices)
data.removed?: @device_removed|null        # set exactly while state is device_removed
data.join_requests?: array                 # present while the helper announces `devices` (§ Joining)
data.join_requests[]: @join_request
```

```schema type.device_removed
title: string
body: string
action: @action               # reset_friends, with its confirm
```

```schema type.banner
kind: enum(id_changed,identity_unavailable,update_required)
text: string
action: @action|null
```

```schema type.name_prompt
title: string
placeholder: string
note: string
join_label?: string|null     # opens the `join` view; present while the helper announces `devices`
```

```schema type.list_row
conversation_id: string
avatar: @avatar
title: string
subtitle: string
time_label: string
route: @route
unread: bool
waiting: @waiting|null
blocked: bool
id_confirmed: bool           # the Friends host confirmed this person holds the Friends ID
id_confirmed_label: string|null  # tooltip and accessible name of the mark; null unless id_confirmed
style: enum(normal,muted)
drop_label: string|null
drop_refusal: string|null    # why the row refuses dragged files; null when it accepts them
accessibility_label: string
actions: array
actions[]: @row_action
mentionable?: bool           # clients that declared mentions: the @ picker offers this person
kind?: enum(person,you)      # present while the helper announces `devices`; `you` is the You row
```

```schema type.row_action
action: enum(accept_request,decline_request,block)
icon: enum(accept,decline,block)
label: string                # tooltip and accessible name; the button shows only its icon
arm: @arm|null               # ask for a second click first
```

```schema type.arm
label: string                # what the armed pill shows: "Block?"
accessibility_label: string  # the armed pill's tooltip and accessible name
seconds: integer             # how long the pill waits for the second click
```

```schema type.waiting
kind: enum(request,offer,key_change)
label: string
```

```schema snapshot.nearby
data.query: string
data.visibility: @visibility
data.methods: array
data.methods[]: @method_state
data.alert: @alert|null
data.note: @note|null
data.status: @status|null
data.people: array
data.people[]: @nearby_person
data.empty: @empty|null
data.footer: @footer
```

```schema type.visibility
state: enum(hidden,visible,unavailable)
title: string|null
body: string|null
remaining_label: string|null
remaining_accessibility_label: string|null
deadline: string|null        # informational; views show remaining_label
action: @action|null
```

```schema type.method_state
method: enum(network,bluetooth)
state: enum(not_asked,starting,working,denied,radio_off,unavailable)
label: string
```

```schema type.alert
title: string
body: string
action: @action|null
```

```schema type.note
text: string
action: @action|null
```

```schema type.status
kind: enum(searching)
label: string
```

```schema type.nearby_person
nearby_id: string|null
conversation_id: string|null
avatar: @avatar
title: string
subtitle: string
status_label: string|null
action: @action|null
accessibility_label: string
```

```schema snapshot.conversation
data.conversation_id: string
data.header: @header
data.back: @back
data.search_placeholder: string
data.has_earlier: bool
data.items: array
data.items[]: @item
data.highlight_item_id: string|null
data.request: @request_card|null
data.composer: @composer
```

```schema type.header
title: string
subtitle: string|null
route: @route
avatar: @avatar
details_available: bool
accessibility_label: string
```

```schema type.item
kind: enum(day,message,transfer,event)
item_id: string
label: string when kind=day
time_label: string|null when kind=message   # null within 5 minutes of the message before it
time_label: string when kind=transfer,event
direction: enum(in,out) when kind=message,transfer
text: string when kind=message,event
text_format: enum(markdown) when kind=message   # how the host shows `text`; unknown values show as plain text
segments: array when kind=message
segments[]: @segment when kind=message
status: @message_status|null when kind=message
assistant_label: string|null when kind=message,transfer   # set when the assistant sent it (via_assistant)
transfer_id: string when kind=transfer
file: @file_info when kind=transfer
meta_label: string when kind=transfer
state: enum(queued,offered,waiting_for_you,sending,receiving,delivered,received,declined,cancelled,failed,on_device,fetching) when kind=transfer
status_label: string when kind=transfer
route_note: string|null when kind=transfer
progress: @progress|null when kind=transfer
thumbnail: @thumbnail|null when kind=transfer   # the file's preview (§ Thumbnails); null: draw the type's icon
actions: array when kind=message,transfer
actions[]: @action when kind=message,transfer
mentions?: array when kind=message   # present when a mention shows as a link (§ Mentions)
mentions[]: @mention when kind=message
highlighted: bool
accessibility_label: string
```

```schema type.mention
url: string                  # the link's destination in `text`; views compare it, never parse it
kind: enum(friend,you,stranger)
label: string                # "@Mei Lin", what the link shows
tooltip: string|null
conversation_id: string|null # a friend's conversation, which a click opens
card: @mention_card|null     # what a click on a stranger shows
```

```schema type.mention_card
title: string                # the name the sender wrote
id_label: string             # "Friends ID brave‑otter"
status_label: string|null    # "Request sent", "Blocked", or why the link no longer matches
conversation_id: string|null # the person's row, for accept_request, decline_request and block
actions: array
actions[]: @action
```

```schema type.message_status
state: enum(queued,connecting,sending,delivered,failed,cancelled)
label: string
```

```schema type.file_info
name: string
kind_label: string
size_label: string
size_bytes: integer
path: string|null            # set once the file is on this Mac (received, verified)
type_identifier: string|null # the uniform type identifier its name's extension names, for the type's icon
extension: string|null       # lowercase, without the dot
```

```schema type.thumbnail
path: string                 # a PNG in the helper's cache; the only thing views load
width: integer               # pixels, 1 to 192
height: integer
source: enum(sender,local)   # the sender's picture, or one made on this Mac from the file
```

```schema type.progress
fraction: number
determinate: bool
accessibility_label: string
```

```schema type.request_card
direction: enum(incoming,outgoing)
avatar: @avatar
title: string
subtitle: string
code_prompt: string|null
comparison_code: string|null
comparison_code_accessibility_label: string|null
actions: array
actions[]: @action
footnote: string|null
```

```schema type.composer
visible: bool
enabled: bool
placeholder: string
hint: array
hint[]: @segment
send_label: string
note: string|null
accepts_drops: bool
max_text_bytes: integer
mention_note?: string|null   # clients that declared mentions: the line under the @ picker
```

```schema snapshot.details
data.conversation_id: string
data.title: string
data.back: @back
data.avatar: @avatar
data.route: @route
data.friends_id: string|null
data.id_label: string|null
data.id_confirmed: bool
data.id_confirmed_label: string|null
data.copy_id_accessibility_label: string|null
data.verification: @verification
data.auto_accept: @auto_accept
data.received: @received|null
data.key_change: @key_change|null
data.actions: array
data.actions[]: @action
```

```schema type.verification
state: enum(verified,unverified)
label: string
body: string|null
comparison_code: string|null
action: @action|null
```

```schema type.auto_accept
available: bool
enabled: bool
title: string
body: string
```

```schema type.received
label: string
count: integer
action: @action|null
```

```schema type.key_change
title: string
body: string
actions: array
actions[]: @action
```

```schema snapshot.profile
data.title: string
data.back: @back
data.name.label: string
data.name.value: string|null
data.name.placeholder: string
data.name.max_length: integer
data.picture.avatar: @avatar
data.picture.choose_label: string
data.picture.own_picture_label: string
data.picture.animal_set: integer
data.picture.selected_index: integer|null
data.id.label: string
data.id.friends_id: string
data.id.state: enum(unreserved,reserved,changed,unavailable)
data.id.note: string
data.id.copy_label: string
data.id.qr_label: string|null     # null in M1: nothing reads the QR yet
data.id.qr_payload: string|null
data.add.label: string
data.add.placeholder: string
data.add.button_label: string
data.add.hint: string
data.links?: object|null          # present while the helper announces `links` (§ Links)
data.links.title: string          # "Your links"
data.links.friend.label: string
data.links.friend.url: string     # Copy puts this on the pasteboard
data.links.friend.note: string
data.links.friend.copy_label: string
data.links.friend.reset: @action  # reset_friend_link, with confirm
data.links.downloads_label: string
data.links.downloads_empty: string|null   # while there is no download link
data.links.downloads: array
data.links.downloads[].link_id: string
data.links.downloads[].file_name: string
data.links.downloads[].downloads_label: string   # "3 downloads"
data.links.downloads[].expires_label: string     # "Expires in 6 days"
data.links.downloads[].revoke: @action           # revoke_link with the action's own link_id
data.devices?: object|null        # present while the helper announces `devices` (§ Devices)
data.devices.title: string        # "Your computers"
data.devices.note: string         # how to add another computer
data.devices.rows: array          # this computer first, then the others by when they joined
data.devices.rows[]: @device_row
```

```schema type.device_row
device_id: string
name: string                 # "Raph’s Mac mini"
system: string               # "macOS 26.1", "Linux"
last_connected: string       # "This computer", "Now", "5 min ago", "Yesterday", "3 Oct", or never
detail: string               # system and last_connected as one line: "macOS 15.7 · Now"
this_computer: bool
state: enum(connected,not_connected,never_connected)
accessibility_label: string
rename: @device_rename|null  # this computer's row only
remove: @action|null         # revoke_device with confirm; null on this computer's row
```

```schema type.device_rename
label: string
placeholder: string
button_label: string         # sends rename_device with the typed name
max_bytes: integer           # 64, UTF-8
```

```schema snapshot.settings
data.name.label: string
data.name.note: string
data.name.value: string|null
data.name.placeholder: string
data.id.label: string
data.id.note: string
data.id.friends_id: string
data.id.copy_label: string
data.received.label: string
data.received.note: string
data.received.action: @action
data.auto_accept.label: string
data.auto_accept.note: string
data.auto_accept.action_label: string
data.auto_accept.friends: array
data.auto_accept.friends[].conversation_id: string
data.auto_accept.friends[].title: string
data.auto_accept.friends[].avatar: @avatar
data.auto_accept.friends[].enabled: bool
data.history.label: string
data.history.note: string
data.history.action_label: string
data.history.confirm: @confirm
data.reset.label: string
data.reset.note: string
data.reset.action_label: string
data.reset.confirm: @confirm
data.nearby?: object|null         # the helper's Nearby line; absent from a helper without one
data.nearby.label: string         # "Nearby"
data.nearby.note: string
data.nearby.action: @action|null  # activate (Allow, Try Again) or open_settings
```

```schema snapshot.message_status
data.messages: array
data.messages[].message_id: string
data.messages[].status: @message_status
```

### Intents

```schema type.file
path: string
display_name?: string
revision?: @revision|null
```

```schema type.revision
source: string
document_id: string
revision_id: string
label?: string|null
sha256?: string|null
size: integer
```

```schema intent.ping
type: enum(ping)
```

```schema intent.activate
type: enum(activate)
```

```schema intent.subscribe
view: enum(badge,list,nearby,details,profile,settings,message_status,join)
params?: object|null
params.conversation_id?: string
params.message_ids?: array
params.message_ids[]: string
```

```schema intent.unsubscribe
subscription: string
```

```schema intent.set_filter
subscription: string
query: string
```

```schema intent.open_conversation
conversation_id: string
message_id?: string|null
```

```schema intent.load_earlier
subscription: string
```

```schema intent.send_message
conversation_id: string
text: string
client_token: string
attachments?: array
attachments[]: @file
via_assistant?: bool         # the host's assistant sends it for the person (§ Intents)
mentions?: array             # one per U+FFFC in text, in order (§ Mentions)
mentions[].conversation_id: string
```

```schema intent.send_files
conversation_id: string
files: array
files[]: @file
client_token: string
via_assistant?: bool
```

```schema intent.cancel_transfer
transfer_id: string
```

```schema intent.accept_offer
transfer_id: string
```

```schema intent.decline_offer
transfer_id: string
```

```schema intent.retry_item
item_id: string
```

```schema intent.cancel_message
message_id: string
```

```schema intent.accept_request
conversation_id: string
```

```schema intent.decline_request
conversation_id: string
```

```schema intent.cancel_request
conversation_id: string
```

```schema intent.send_request
nearby_id: string
```

```schema intent.add_by_id
friends_id: string
```

```schema intent.add_from_mention
friends_id: string
identity_key: string
name: string
```

```schema intent.block
conversation_id: string
```

```schema intent.unblock
conversation_id: string
```

```schema intent.remove_friend
conversation_id: string
```

```schema intent.mark_verified
conversation_id: string
```

```schema intent.accept_key_change
conversation_id: string
```

```schema intent.set_name
name: string
```

```schema intent.set_picture
picture.kind: enum(animal,image)
picture.set: integer when picture.kind=animal
picture.index: integer when picture.kind=animal
picture.data_base64?: string
picture.path?: string
picture.crop?: object|null
picture.crop.x: integer
picture.crop.y: integer
picture.crop.side: integer
```

```schema intent.set_auto_accept
conversation_id: string
enabled: bool
```

```schema intent.dismiss_banner
kind: enum(id_changed)
```

```schema intent.start_visibility
type: enum(start_visibility)
```

```schema intent.stop_visibility
type: enum(stop_visibility)
```

```schema intent.search_messages
query: string
conversation_id?: string|null
limit?: integer
```

```schema intent.assistant_open_scope
scope.kind: enum(conversations,all)
scope.conversation_ids: array when scope.kind=conversations
scope.conversation_ids[]: string when scope.kind=conversations
```

```schema intent.assistant_search
scope_id: string
query: string
limit?: integer
```

```schema intent.assistant_read
scope_id: string
message_id: string
before?: integer
after?: integer
```

```schema intent.assistant_close_scope
scope_id: string
```

```schema intent.delete_history
conversation_id?: string|null
```

```schema intent.reset_friends
confirm: enum(reset)
```

```schema intent.open_link
payload: string               # f. or d. and the base64url payload, as the app's URL carried it (§ Links)
```

```schema intent.add_from_link
payload: string
```

```schema intent.receive_link
payload: string
```

```schema intent.make_download_link
file: @file
expires_days: integer          # 1, 7 or 30
```

```schema intent.reset_friend_link
type: enum(reset_friend_link)
```

```schema intent.revoke_link
link_id: string
```

```schema intent.revoke_device
device_id: string
```

```schema intent.rename_device
name: string                 # this computer's new name
```

```schema intent.fetch_from_device
transfer_id: string
```

```schema intent.disable
type: enum(disable)
```

`intents.jsonl` holds one example of every intent, including all three forms of `set_picture`; `hello` has its
own fixture (`fixtures/frames/hello.json`).

Fixtures are strict where receivers are lenient: on the wire unknown fields are ignored, but a fixture field that
no rule here declares fails `friends-protocol-check`, so nothing reaches the views without being documented.

### Results

```schema result.subscribe
result.subscription: string
```

```schema result.open_conversation
result.subscription: string
result.conversation_id: string
```

```schema result.send_message
result.message_id: string
result.transfer_ids: array
result.transfer_ids[]: string
```

```schema result.send_files
result.transfer_ids: array
result.transfer_ids[]: string
```

```schema result.add_by_id
result.conversation_id: string
result.message: string
```

```schema result.add_from_mention
result.conversation_id: string
result.message: string
```

```schema result.open_link
result.card.kind: enum(friend,download)
result.card.title: string             # "Add Mei?", or the file's name
result.card.subtitle: string|null     # "Friends ID brave‑otter", or its size and who sends it
result.card.note: string|null
result.card.avatar: @avatar|null
result.card.actions: array
result.card.actions[]: @action
```

```schema result.add_from_link
result.conversation_id: string
result.message: string
```

```schema result.receive_link
result.conversation_id: string
result.message: string
```

```schema result.make_download_link
result.url: string
result.link_id: string
result.message: string
```

```schema result.start_visibility
result.deadline: string
```

```schema result.search_messages
result.results: array
result.results[].conversation_id: string
result.results[].message_id: string
result.results[].conversation_title: string
result.results[].avatar: @avatar
result.results[].sender_label: string
result.results[].time_label: string
result.results[].excerpt: array
result.results[].excerpt[]: @segment
result.more: bool
result.empty_label: string|null
```

```schema result.assistant_open_scope
result.scope_id: string
result.expires_at: string
result.conversation_count: integer
```

```schema result.assistant_search
result.results: array
result.results[].conversation_id: string
result.results[].conversation_title: string
result.results[].message_id: string
result.results[].sender_label: string
result.results[].sent_at: string
result.results[].excerpt: string
result.truncated: bool
```

```schema result.assistant_read
result.conversation_id: string
result.conversation_title: string
result.messages: array
result.messages[].message_id: string
result.messages[].sender_label: string
result.messages[].sent_at: string
result.messages[].text: string
result.truncated: bool
```

## Changing this protocol

Until the first release ships, version 1.0 is still being written: no released app speaks it, so additions land in
1.0 itself, with their schema and fixture, without a minor bump. From the first release on, these rules apply:

- **Adding** an optional field, an intent, a view, an action, an error code or a capability is a minor change:
  bump `SZFRIENDS_PROTOCOL_MINOR` in `client/szfriends_client.h`, document it here with its schema and a
  fixture, and make the helper send it only to clients that negotiated that minor.
- **Removing or changing** the meaning or type of anything is a major change. The helper keeps speaking the
  previous major for one major version, so an older app keeps working beside a newer one.
- Never change the frozen frames (§ Handshake).
- Every change updates the golden fixtures in the same commit; `make -C portable friends-tests` must pass.
