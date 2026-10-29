# Shenzhen Friends

Private document sharing and messaging between people who add each other, built as one contained module.
ShenzhenPDF hosts it with the AppKit views; Shenzhen Files (the GTK4 port of GNOME Files) hosts it with the GTK views
and its own adapter, and the two share one helper, one identity and one history per Mac user. The product and its
rules are specified in
[the implementation brief](../docs/plans/shenzhen-friends.md); the contract between the helper and the apps is
[PROTOCOL.md](PROTOCOL.md); how the service works and why is in the [ADRs](docs/adr/README.md).

## Four layers

| Layer | What it is | May depend on | Lives in |
|---|---|---|---|
| Service | The helper process: identity, store, nearby transports, sessions, host connection, file previews, presentation state | System frameworks only (Foundation, Network, CoreBluetooth, Security, LocalAuthentication, IOKit for sleep and wake, SQLite, ImageIO, CoreGraphics, QuickLookThumbnailing, UniformTypeIdentifiers), vendored libsodium and cJSON | `service/`, `avatars/` |
| Client protocol | Versioned newline-JSON over a local socket, and the C client library that speaks it | libc and vendored cJSON | `PROTOCOL.md`, `client/` |
| Views | The title-bar button, the dropdown and its views, drop targets, the Settings section | The client library, the animal set, and AppKit (`mac/`) or GTK 4, libadwaita and json-glib (`gtk/`) | `mac/`, `gtk/` |
| Host adapter | What only the app knows: button placement, `#` items, open and import, assistant, global search, appearance | Views and the app | outside this directory: `portable/mac/friends/` for ShenzhenPDF, a patch in the Shenzhen Files repository for Files |

- **Logic lives in the service.** The helper publishes display-ready snapshots: rows already sorted, labels such
  as "Yesterday" or "Over Bluetooth, about 6 min", countdown text, badge counts, which buttons show. Views render
  snapshots and send intents. The GTK views reimplement drawing, nothing else; the AppKit views in `mac/` are the
  reference for every page's behaviour and copy.
- **Every user-facing string comes from one catalog in the service** (`service/presentation/`), with three
  exceptions that exist because no helper is running to supply them or because only the host knows the words:
  the client library's connection-state lines, the host adapter's Settings checkbox and disclosure, and the
  host's `#` picker row for when nothing matches ("No matching documents").
- **Write for the person reading the text, not about the mechanism.** "Sends when Mei is nearby with ShenzhenPDF,
  Shenzhen Files or Shenzhen 3D open", never "Queued (no route)". Before adding a string, name who reads it and what
  they are wondering right there, check it answers that and is true from their side, and say nothing when nothing needs
  saying. A string about the other computer names every app through `{apps}`, because any one open there runs Friends.

## Areas: what each owns, builds on, and tests

Each area has one owner during the build wave. Edit only files you own; ask the owner for changes elsewhere,
and change a public header only by agreement with the areas that include it, keeping it compiling on its own.
Areas depend on one another only through the public headers below, so every area can start now: write against
the header, and test with fakes of the headers you include (the store with an in-memory fake, the session with
fake streams, discovery with scripted adapters, the views with the fake helper).

Each area's makefile, at the path given, appends its suite to `FRIENDS_TEST_TARGETS` and defines it; tests live
beside the code in a `tests/` directory of the area (`service/store/tests/SZFriendsStoreTests.m`).

| Area | Owns | Public interface | Builds on | Makefile → suite |
|---|---|---|---|---|
| protocol | `client/` (library and the fake helper in `client/fake/`), `service/presentation/` | `client/szfriends_client.h`, `service/presentation/SZFriendsPresentation.h`, `service/presentation/SZFriendsMentions.h` (the mention form, which the helper and the store use too) | PROTOCOL.md, `fixtures/`, cJSON; presentation: avatars and discovery headers (shared value types) | `client/client.mk` → `friends-client-check`; `service/presentation/presentation.mk` → `friends-presentation-check` |
| helper | `service/helper/`: helper main, lifecycle, IPC server, helper bundle `Info.plist`, the helper bundle build; `tests/e2e/`, the two-helper harness | `service/helper/SZFriendsHelper.h` | every service header, the client library (socket path, directory check, framing), libsodium | `service/helper/helper.mk` → `friends-helper-check`; `service/helper/universal.mk` → `friends-helper-universal`, `friends-universal-check` (Intel Macs, not in `friends-suite`); `tests/e2e/e2e.mk` → `friends-e2e-check`, `friends-e2e-devices-check`; `tests/e2e/oneid.mk` → `friends-one-identity-check` (not in `friends-suite`) |
| store | `service/store/` apart from previews | `SZFriendsStore.h`, `SZFriendsOutbox.h`, `SZFriendsTransfers.h`, `SZFriendsStoreDevices.h` (device chains, schema v8), `SZFriendsStoreSync.h` (sync's log and merge state, schema v9; helper-only) | avatars and identity headers (certificate checks for static-key changes; its suite links the identity objects), the mention form (search indexes mentions as their labels), libsodium (BLAKE2b digests), `-lsqlite3` | `service/store/store.mk` → `friends-store-check` |
| thumbnails | `service/thumbnails/`: the C99 QOI codec and PNG writer, the QuickLook renderer, the maker, the fuzz harnesses and corpus; and `service/store/SZFriendsTransferThumbnails.{h,m}` (ADR 0008) | `service/thumbnails/SZFriendsThumbnails.h`, `szfriends_qoi.h`, `szfriends_image.h`, `service/store/SZFriendsTransferThumbnails.h` | the store and session headers, QuickLookThumbnailing, CoreGraphics, UniformTypeIdentifiers | `service/thumbnails/thumbnails.mk` → `friends-thumbnails-check`; also `friends-thumbnails-fuzz` and `friends-thumbnails-fuzz-seeds` |
| sync | `service/sync/`: events, merge rules, capture, the exchange between our own devices and file copies (ADR 0014); the helper's `nearby/SZFriendsNearbyService+Sync.m` and `+FriendDevices.m` | `service/sync/SZFriendsSync.h` (helper-only) | store (`SZFriendsStoreSync.h`), identity and chain headers, libsodium; its suite links the store's and identity's objects and runs three stores in temporary directories | `service/sync/sync.mk` → `friends-sync-check` |
| transfer | `service/transfer/`: fast transfers' pure parts (ADR 0018): block geometry, the BLAKE3 tree over `ext/blake3`, block sets and ranges, the sidecar formats, the SYNC and AGAIN block messages and the minor-4 frames | `service/transfer/SZFriendsTransferBlocks.h` (helper-only) | the session header, libsodium, BLAKE3 (`friends/deps`) | `service/transfer/transfer.mk`; checked by `friends-vectors-check` against `fixtures/vectors/transfer/` |
| identity | `service/identity/`, including the word list file, the device chain (ADR 0012), and CPace and the join exchange (ADR 0013) | `service/identity/SZFriendsIdentity.h`, `service/identity/SZFriendsDeviceChain.h`, `SZFriendsCPace.h` and `SZFriendsJoin.h` (helper-only) | libsodium, Security | `service/identity/identity.mk` → `friends-identity-check` |
| session | `service/session/`: the C Noise state machine, the codec, the channel, Noise vectors with provenance; the online signalling payloads (`SZFriendsSignaling*`: IK and NN over the host, sealed rendezvous records, link openings) | `service/session/SZFriendsSession.h`, `service/session/SZFriendsSignaling.h` | identity and discovery headers, `service/online/SZFriendsOnlineTransport.h` (signalling), libsodium | `service/session/session.mk` → `friends-session-check`, which also runs the signalling suite (`tests/signaling/`) |
| discovery | `service/discovery/`: merger, tags, racer, Network.framework and CoreBluetooth adapters | `service/discovery/SZFriendsDiscovery.h` | session header (`SZFriendsByteStream`), libsodium | `service/discovery/discovery.mk` → `friends-discovery-check` |
| host | `service/host/` and `../server/friends/` (Node.js service, signing CLI, deploy files, host protocol document) | `service/host/SZFriendsHostConnection.h`, `service/host/SZFriendsHostRendezvous.h` (protocol 2: rendezvous records, connection setup, relay credentials) | identity header, libsodium | `service/host/host.mk` → `friends-host-check`, and `friends-host-server-check` running the Node suite in `../server/friends/` |
| avatars | `avatars/`: SVG sources, generated PDFs, `animals/manifest.json`, the PDF script, the picture pipeline | `avatars/SZFriendsAvatars.h` | Foundation, ImageIO | `avatars/avatars.mk` → `friends-avatars-check` |
| views | `mac/` | `SZFriendsHost.h`, `SZFriendsHelperLink.h`, `SZFriendsDropdownController.h`, `SZFriendsSettingsSection.h` | the client library, the avatars header, AppKit; never `service/` | `mac/views.mk` → `friends-views-check` |
| gtk views | `gtk/` | `gtk/szfriends_gtk.h`, `gtk/szfriends_gtk_host.h` | the client library, the animal set's data, GTK 4.22, libadwaita 1.9, json-glib; never `service/` or `mac/` | `gtk/gtk.mk` → `friends-gtk-check` (the core), `friends-gtk-list-check`, `friends-gtk-conversation-check`, `friends-gtk-details-check` (the pages); also `friends-gtk-lib` for Shenzhen Files |
| host adapter | ShenzhenPDF's adapter, outside this directory (below); Shenzhen Files' adapter lives in its own repository | implements `mac/SZFriendsHost.h` (Files: `gtk/szfriends_gtk_host.h`) | the views headers, the reader | see below |
| online transport | `service/online/transport/`: the peer connection, the data-channel byte stream, the candidate filter, the relay connection (ADR 0009) | `service/online/SZFriendsOnlineTransport.h` (frozen, changed only by the lead with the areas that include it), `service/online/transport/SZFriendsOnlineDataChannelTransport.h` | the stack through `deps/datachannel.mk` (`FRIENDS_DATACHANNEL_CFLAGS`, `FRIENDS_DATACHANNEL_LIBS`), session and discovery headers; its suite links the session and identity objects and libsodium | `service/online/transport/online.mk` → `friends-online-check`; the relay scenario needs a pinned coturn named by `FRIENDS_TEST_COTURN` and skips without it |
| NAT techniques | `service/online/nat/`: PCP and NAT-PMP, UPnP through miniupnpc (`../../ext/miniupnpc/`), the two-port STUN classifier, port prediction, hard-NAT probing, TCP simultaneous open, the fuzz harnesses and corpus (ADR 0011) | `service/online/nat/SZFriendsNAT.h` and one header per technique (`SZFriendsNAT*.h`, listed in `nat.mk`) | the online transport's headers, session and discovery headers, miniupnpc; its suite links libjuice, the session and identity objects and libsodium | `service/online/nat/nat.mk` → `friends-nat-check` (also replays the fuzz corpus); `friends-nat-fuzz` runs the fuzzers, and `friends-nat-gateway-probe` is by hand only |
| route order | `service/online/order/`: the phases and timers of an Internet attempt, leaving the relay, the technique log (ADR 0011) | `service/online/order/SZFriendsOnlineOrder.h` | the online transport, NAT, discovery and session headers; Foundation only | `service/online/order/order.mk` → `friends-order-check` |
| online driver | `service/online/driver/`: joins the rendezvous client, signalling, the route order, the transport and the NAT techniques inside the helper | `service/online/driver/SZFriendsOnlineDriver.h` (helper-only) | the headers of the areas it joins: host (`SZFriendsHostRendezvous.h`), signalling, route order, transport, NAT techniques | `service/online/driver/driver.mk` → `friends-driver-check` |
| links | `service/links/`: friend links' invites and download links: holding the file, registering with the host, serving the link pages and apps, receiving one in an app; with `service/store/SZFriendsStoreLinks.{h,m}` (schema v7), the helper's `SZFriendsHelperLinks.{h,m}`, `SZFriendsIntentRouter+Links.m` and `nearby/SZFriendsNearbyService+Invites.m` | `service/links/SZFriendsLinks.h`, `SZFriendsLinkWire.h`, `service/store/SZFriendsStoreLinks.h` (helper-only) | store, transfers, identity, thumbnails, the host's online side, the online driver's transport and STUN | `service/links/links.mk` → `friends-links-check`: unit tests, the link pages' own JavaScript against the helper's crypto (Node), and an e2e through the local host and coturn |
| contracts (lead) | `README.md`, `PROTOCOL.md`, `friends.mk`, `fixtures/`, `tests/` apart from `tests/e2e/`, `deps/`, `docs/adr/` | | | `friends-containment-check`, `friends-protocol-check`, `friends-deps-check`; `friends-miniupnpc-check` (in `friends.mk`) tests the local patch to miniupnpc |

Notes per area:

- **protocol.** The fake helper is a small C executable that listens on the socket for a temporary
  `SZFRIENDS_STATE_DIR`, answers `hello` with `fixtures/frames/welcome.json`, each `subscribe` and
  `open_conversation` with the matching `fixtures/snapshots/` file, and each intent with `fixtures/replies/` or
  an empty result. The AppKit and GTK views' tests and the host adapter's use it. A scripting call (a reply, a
  hold, a new view) applies to every client frame written after it returns, however the frames arrive, so a test
  that holds replies between two intents can rely on the second being held. Presentation tests compare the builder's
  output with `fixtures/snapshots/` as parsed JSON, not bytes (dictionaries have no key order), with the
  fixture clock below. Frames are not NUL-terminated: parse each line with `cJSON_ParseWithLength`. The nesting
  limit is compiled into `cJSON.o`, so ask for a lower one in `deps/deps.mk` rather than in your own flags.
  A team-signed host calls `szfriends_set_signing_policy()` once at launch, before spawning or connecting, with
  its own Team ID and a Security.framework verifier: the library then ignores `SZFRIENDS_STATE_DIR` and trusts only
  a helper whose audit token meets the team requirement the helper applies to its clients (ADR 0002 § Peer checks).
  The library stays libc only; its tests inject the verifier. Hosts show `szfriends_client_state_text()`, which
  names the app when the person has to update it.
- **helper.** It builds the helper bundle under `$(FRIENDS_BUILD)/`; `portable/Makefile`'s app recipe embeds
  and signs it in ShenzhenPDF.app (§ Building and testing). Call `szfriends_socket_path()` and
  `szfriends_socket_directory_check()`; never reimplement them. The helper writes `<state>/helper.log` itself
  once it holds the lock, rotated at 1 MiB.
- **store.** Search indexes each message as a reader sees it: every mention as its "@Name" label, never the Friends
  ID and key in its link, with match ranges given back in the stored text (ADR 0003, Corrections). Rows folded before
  that are refolded once when the store opens.
- **thumbnails.** C is allowed in `service/thumbnails/` for the codec and image code (ADR 0008), compiled C99 and libc
  only, so bytes a friend sends are decoded by code this repository owns and fuzzes, and a later Linux helper reuses it
  with its own renderer. `friends-thumbnails-check` replays the whole fuzz corpus under the sanitizers;
  `friends-thumbnails-fuzz` runs `FRIENDS_FUZZ_SECONDS` per target (default 600) and keeps what it finds in
  `service/thumbnails/fuzz/corpus/`.
- **session.** C is allowed in `service/` where an ADR says so (ADR 0001's Noise state machine); compile it
  with `$(FRIENDS_SODIUM_CFLAGS)` and `-std=c99`. The suite fails when it loads zero Noise vectors. Responder
  channels refuse quietly: any refusal before their first reply closes `SZFriendsRefusalDelay` after the deciding
  bytes, whatever the reason (ADR 0001, Review amendments).
- **discovery.** No suite creates a Bluetooth manager. The only real browsers and listeners are loopback-only
  Network.framework adapters on `lo0` with a random test service type: discovery's own test (two adapters, which
  skips rather than fails when mDNS does not answer) and `friends-e2e-check`'s helpers. Nothing is browsed or
  advertised on another interface and nothing prompts. The production adapters on real interfaces and Bluetooth
  run on the hardware matrix (`service/discovery/hardware-matrix.md`). The adapters enforce admission limits
  (`SZFriendsAdmissionLimits`) through the streams they hand out, before any handshake work.
- **host.** The Node suite needs Node.js 22.16 or later on PATH and fails, rather than skips, without it. It runs
  the host service on loopback only; nothing in any suite contacts friends.meerkat.orgabots.com. Deploy only
  with the owner's approval.
- **online areas** (transport, NAT techniques, route order, driver). Nothing online may run at the helper's start:
  the stack is set up on the first online attempt, so launch stays as fast as before. Their suites stay on loopback
  and this Mac's own addresses (a local coturn relays from en0's address), never a public STUN, TURN or Friends host,
  and run their parsers under AddressSanitizer and UndefinedBehaviorSanitizer. miniupnpc reads what a router (or
  anything posing as one on the LAN) sends before anyone is authenticated, so it is fuzzed, UPnP talks only to the
  default gateway's own address, and its one local change is recorded in `../../ext/miniupnpc/VENDORED.md`.
- **avatars.** Set 1 must keep the circle colors the fixtures use (listed in `SZFriendsAvatars.h`), because an
  animal avatar's `color` is its manifest color.
- **views.** Every Friends surface carries an identifier starting with `szfriends.` (the title button, the
  dropdown's content view, its inline confirmation, the Settings section, and the window and content view of
  every alert and panel Friends opens), so the host's assistant can skip them: ShenzhenPDF's `app_controls`
  never lists or presses a control under such a mark (`mac/SZFriendsHost.h`, brief § AI boundaries). A new
  surface outside these views needs its own mark; `friends-views-check` fails on any control not under one.
  While a conversation's width changes, the views keep each bubble's last rendering and render once the width settles
  (`mac/SZFriendsHost.h`, Render passes).
- **Invisible characters.** The views' literal text (`mac/SZFriendsLiteralText.m`) and the host adapter's send check
  and AI chat card mark the same characters, and every implementation runs the shared cases in
  `fixtures/text/invisible-cases.json`; a GTK view that shows literal text must run them too. Their Unicode tables are
  generated, never written by hand, from eight files of one Unicode version, given in this order:
  `emoji-variation-sequences.txt`, `emoji-data.txt`, `DerivedJoiningType.txt`, `IndicSyllabicCategory.txt`,
  `Blocks.txt`, `Scripts.txt`, `ScriptExtensions.txt`, `PropertyValueAliases.txt`. The last three give the script
  rule: a combining mark counts only on a letter of a script it is used with (Script_Extensions, else Script), or
  when it belongs to no script. `mac/tools/generate-emoji-tables.py` writes `mac/SZFriendsEmojiTables.m` and
  `portable/mac/friends/generate-emoji-tables.sh` writes `SPDFMacFriendsEmojiTables.h`; each script's header gives
  its usage, and each refuses files of different versions. `gtk/szfriends_gtk_mention_card_tables.c` copies the
  first's tables, and its suite fails on any difference.
- **gtk views.** C11 in GLib style, rendering the same snapshots as `mac/` and sending intents only through the client
  library (`gtk/README.md` lists the files and how to add a page). The core is the link, the snapshot structs, the
  button, the dropdown shell, drops and avatars; each group of pages has its own files and suite:
  - the list and Nearby: `szfriends_gtk_list_*`, `szfriends_gtk_row*`, `szfriends_gtk_nearby_page.c`,
    `szfriends_gtk_glyphs.{c,h}` (`friends-gtk-list-check`);
  - the conversation: `szfriends_gtk_conversation*`, `szfriends_gtk_message*.c`, `szfriends_gtk_transfer.c`,
    `szfriends_gtk_composer*`, `szfriends_gtk_mention_card.c` (`friends-gtk-conversation-check`);
  - details, profile and Settings: `szfriends_gtk_details_*`, `szfriends_gtk_profile_page.c`,
    `szfriends_gtk_crop.{c,h}`, `szfriends_gtk_qr.{c,h}`, `szfriends_gtk_settings_section.c`
    (`friends-gtk-details-check`).

  Every string from a snapshot is set as plain text:
  set `use-markup` to FALSE on `AdwPreferencesRow` and `AdwActionRow` titles and subtitles, and never put a name in an
  `AdwStatusPage` description, which is markup. `friends-gtk-lib` builds `libszfriends_gtk.a` (the views, the client
  library and cJSON) for Shenzhen Files, which builds it from a pinned commit, never from a working copy others use.
- **host adapter.** ShenzhenPDF code, so it uses the reader's own prefix and may include reader headers; it
  includes Friends headers as `"mac/SZFriendsHost.h"` with `-Ifriends`. Its sources live in
  `portable/mac/friends/` (`SPDFMacFriends*.{h,mm}`), not `portable/mac/` itself, so only the Friends block of
  `portable/Makefile` compiles them with the Friends include path. Its suite is `mac-friends-host-adapter-tests`
  in `portable/mac/friends/friends-host-adapter.mk`, which `portable/Makefile` includes: run it with
  `make -C portable mac-friends-host-adapter-tests`, and `friends-tests` runs it too; it includes
  `mac-friends-app-controls-tests`, `mac-friends-promise-tests` and `mac-friends-release-verify-tests`. Tests use a
  temporary `SPDF_STATE_DIR` and `SZFRIENDS_STATE_DIR`, and fakes of the views and the spawn. The reader keeps a
  per-user `tab-drag.key` (0600) in its own state directory to sign the tabs it drags, so tests set
  `SPDF_STATE_DIR`.
- **Keyboard and menu (ShenzhenPDF).** While Friends is attached the reader adds View ▸ Friends
  (`mac/friends/SPDFMacFriendsMenu.{h,mm}`, `SPDFMacFriendsMenuIntegration.mm`): Open Friends ⌘J (it reads Close
  Friends while the dropdown is open), Add by ID…, Make Myself Visible and Friends Settings…,
  removed again when Friends detaches or is turned off. ⌘J was free in the reader's menus, so nothing else moved;
  it is an ordinary menu key equivalent, so it also closes the dropdown while its search field has focus. Cmd+K lists
  the items like any menu item, plus keywords (`spdf_palette_menu_command_keywords` in `mac/SPDFMacPaletteResults.mm`:
  "chat", "nearby" and "add by id" find Open Friends). The button's tooltip gets " · ⌘J" from the host, which puts it
  back each time the views reset it from the helper's `button_label`. The F1 sheet and `readme.md` list ⌘J. The
  Windows and Linux readers have no Friends yet, so they have no Ctrl+J and nothing changed there. The probe
  `make -C portable -f Makefile -f mac/tests/friends-shortcut-probe.mk mac-friends-shortcut-probe` drives all of it
  with key events on the real reader, menu and views against the in-process fake helper.
- **Optional host members.** Beyond the required ones, a host may implement these; `mac/SZFriendsHost.h` is the
  authoritative text for each, and a host without one gets the behaviour it describes:
  - on `SZFriendsHost`, `-friendsRenderMarkdown:width:appearance:` draws a friend's Markdown at chat scale, and
    `-friendsBeginMarkdownPass` / `-friendsEndMarkdownPass` bracket every layout of a conversation's messages so the
    host can share one time allowance across them (answering nil, plain text, once it is spent);
  - on `SZFriendsAssistant`, `commandNote` is the line under a `/` command saying what the assistant reads and where
    that goes, and `proposalEditLabel` and `proposalSendingStatus` are a proposal's Edit button and its in-progress
    words; without `proposalEditLabel` the views show every proposal as a draft;
  - `SZFriendsAssistantOutcomeProposed`, with the result's `send` block, is a `/` command's message waiting for the
    person's Send above the composer; the views call `send` only from that press, and Edit moves it into the composer;
  - Friends exports `SZFriendsShowLinkMenuInView()`, which a host calls from a click on a link it drew itself (a link
    in a table attachment) so that link opens only through the Friends link menu, as every other one does.

## Naming and containment

- Friends code uses the `SZFriends` prefix for Objective-C and `szfriends_` for C. (Shenzhen Files already
  uses `SZF`, so the longer prefix avoids collisions when both are linked into it.)
- **Nothing under `portable/friends/` includes a reader header or uses a reader symbol** (the `SPDF` prefix, the
  core's `spdf_` C functions). Friends cannot know which app hosts it.
- `service/` and `client/` never import AppKit, Cocoa or GTK. `client/` is C99 and libc only. `mac/` views never
  include `service/` headers: they reach the helper only through the client protocol. `service/` never includes
  `mac/`.
- `gtk/` views are C for GTK hosts on any platform: they never include `service/` or `mac/`, never use AppKit, Cocoa,
  UIKit, Foundation or Objective-C, and use Apple's ApplicationServices or Carbon only in `gtk/tests/`, where the probes
  keep GDK in the background. They reach the helper only through the client library, as the AppKit views do.
- Headers include one another by path relative to this directory (`#import "service/store/SZFriendsStore.h"`),
  compiled with `-Ifriends` from `portable/`.
- Every public header compiles on its own, with nothing else on the include path; the GTK views' headers with only
  `pkg-config --cflags gtk4 libadwaita-1 json-glib-1.0` added, as a GTK host compiles them.
- Only `service/store/` names SQLite's C library or the database file (ADR 0003): the store is the only reader
  and writer of the database, and everything else asks it. `tests/containment-check.sh` exempts one file still
  waiting on its owner, `friends.mk`, whose comment lists what the service areas link.
- `make -C portable friends-containment-check` enforces all of the above, and proves on planted violations that
  each rule still fires. Markdown is exempt so documents like this one can name the reader's files.

## Building and testing

Make runs with cwd `portable/`, so every path in a Friends makefile is relative to `portable/`.

- `portable/Makefile` reaches Friends in three places. Near the end it includes `friends/friends.mk` and
  `mac/friends/friends-host-adapter.mk` and defines `friends-tests: friends-suite mac-friends-host-adapter-tests`;
  the release script discovers suites by scanning `portable/Makefile` for `*-tests:` targets, so `friends-tests`
  is how every Friends suite runs before a release. After those includes, the Friends block (`MAC_FRIENDS_*`)
  compiles the host adapter, links it with the views, client library, cJSON and animal set into the reader
  (`MAC_FRIENDS_LINK`, `MAC_FRIENDS_FRAMEWORKS`), embeds the helper bundle in `Contents/Helpers/` and the animal
  set and acknowledgements in `Resources/Friends/` (`MAC_FRIENDS_EMBED`), and checks the result
  (`MAC_FRIENDS_BUNDLE_CHECK`, also `mac-friends-bundle-check`). The app recipe uses those variables and signs the
  helper on its own line before the outer bundle.
- `friends.mk` includes `deps/deps.mk` first (its variables are needed when other rules are read), then every
  area makefile it finds: `friends/*.mk`, `friends/*/*.mk`, `friends/*/*/*.mk`. The online areas sit one level
  deeper, so `friends.mk` names each on its own line, in this order: `service/online/transport/online.mk`,
  `service/online/nat/nat.mk`, `service/online/order/order.mk`, `service/online/driver/driver.mk`. A new online
  area asks the lead for its line. `friends-suite` fails when a suite is not named `friends-<area>-check`.
- Each area makefile:
  - appends its suite: `FRIENDS_TEST_TARGETS += friends-store-check`, a target named `friends-<area>-check`;
  - writes build outputs under `$(FRIENDS_BUILD)` (`build/friends/`) and creates directories with
    `@mkdir -p "$(@D)"` rather than a shared directory rule, so two areas never define the same recipe;
  - may use `$(FRIENDS_OBJC_FLAGS)` (Objective-C, ARC, `-Werror`, app target), `$(FRIENDS_C_FLAGS)` (C99,
    `-pedantic`), `$(FRIENDS_INCLUDES)`, and the deps variables `FRIENDS_SODIUM_CFLAGS`, `FRIENDS_SODIUM_LIB`,
    `FRIENDS_CJSON_CFLAGS`, `FRIENDS_CJSON_OBJ`, listing the libraries as prerequisites too;
  - appends new public headers to `FRIENDS_PUBLIC_HEADERS`, and its production objects (never tests) to
    `FRIENDS_SERVICE_OBJS` (with system libraries in `FRIENDS_SERVICE_LIBS`), `FRIENDS_CLIENT_OBJS` or
    `FRIENDS_VIEWS_OBJS` (the GTK views build their own archive, `friends-gtk-lib`);
  - names another area's outputs in a prerequisite list as `$$(FRIENDS_SERVICE_OBJS)`: `friends.mk` turns on
    second expansion because area makefiles are read in path order, so a plain `$(...)` there can be empty.
- Service code is Objective-C (`.m`, `-fobjc-arc`, Foundation and other system frameworks, never AppKit), plus
  C where an ADR calls for it. The client library is C99. The AppKit views are Objective-C; the GTK views are C11.
- `friends-gtk-check` needs `gtk4`, `libadwaita-1` and `json-glib-1.0` through pkg-config (Homebrew on macOS) and
  fails, rather than skips, without them, as a skipped suite proves nothing. It runs two binaries, built for the
  running macOS so linking Homebrew's libraries prints no warning per library. `SZFriendsGtkTests` needs no display:
  snapshots and frames parsed, the structs against PROTOCOL.md, intents, drops, the link against the fake helper.
  `SZFriendsGtkProbes` renders widgets offscreen into `$(BUILD)/friends/gtk/renders/`; it opens GDK's display, which
  on macOS needs a logged-in session, but never maps a window, and it links the quiet interposer
  (`gtk/tests/szfriends_gtk_quiet.c`), which keeps GDK from turning the probe into a foreground app: no Dock icon,
  no focus taken from whatever the person is using. Open a render with an image viewer to judge it; never show a
  window to look. The three page suites (`friends-gtk-list-check`, `friends-gtk-conversation-check`,
  `friends-gtk-details-check`) work the same way, each with a test binary that needs no display and a probe binary
  that drives its pages against the fake helper and renders them to `$(BUILD)/friends/gtk/list/renders/`,
  `conversation/renders/` or `details/renders/`, with its own copy of the quiet interposer.
- Tests are plain executables that print `<Name> passed` and exit 0. Judge them by exit code, never by grepping
  their output, and `rm -f` a test binary before trusting a rerun (make skips a rebuild when source and binary
  share an mtime second). Prefer compiling the test inside its phony target, as `tests/tests.mk` does.
- Tests use temporary `SZFRIENDS_STATE_DIR` (and `SPDF_STATE_DIR` for host-adapter tests) directories, a file
  key store, and loopback only. With `SZFRIENDS_STATE_DIR` set the helper defaults to the file key store, so a
  test cannot reach the real Keychain by forgetting to ask. Tests never contact friends.meerkat.orgabots.com or
  any other external service; the host harness runs the host service locally.
- `friends-e2e-check` (`tests/e2e/e2e.mk`, owned by the helper orchestration) runs two real helpers on separate
  state directories over loopback Bonjour and the scripted slow Bluetooth adapter, driven only through the client
  library; each scenario finishes within 60 s and leaves no process behind. Some scenarios add a peer under the
  test's control (`tests/e2e/SZFriendsE2ERogue.h`), so the runner links the service areas' objects, and the host
  scenario runs the local Node host service on 127.0.0.1 (it needs the `node_modules` that
  `friends-host-server-check` installs, and skips with a reason without Node.js 22.16). The helper honours its
  test-only variables only under `SZFRIENDS_STATE_DIR`: `SZFRIENDS_TEST_SERVICE_TYPE` (a loopback Bonjour test
  type, never the production one) and `SZFRIENDS_TEST_HOST_LIST` with `SZFRIENDS_TEST_HOST_KEYS` (check-in only
  when both name readable files and every host in the list is on loopback). The harness's own `SZFRIENDS_E2E_*`
  variables (`IDLE_TIMEOUT`, `FRIENDS_ID`, `HOST_SERVER_DIR` and the others in `tests/e2e/`) are read only by its
  test main (`tests/e2e/SZFriendsE2EHelperMain.m`), never by the shipped helper. A team-signed helper ignores every
  `SZFRIENDS_*` variable, and a team-signed app ignores `SZFRIENDS_STATE_DIR` (ADR 0002).
- Two scenarios run both apps on one Mac against one helper (`tests/e2e/SZFriendsE2EApps.h`), each app a process of
  its own in a test bundle that embeds its own helper with a build number: ShenzhenPDF's part drives the C client
  library as the AppKit views' link does (`szfriends_e2e_client_app.c`), Shenzhen Files' part drives the GTK views'
  link without a display (`szfriends_e2e_gtk_app.c`, never `gtk_init`). They share conversations, messages and read
  state, and the higher build number takes the helper over while equal numbers keep the running one. So
  `friends-e2e-check` needs GTK through pkg-config too; `e2e.mk` passes the two programs to the runner as
  `SZFRIENDS_E2E_CLIENT_APP` and `SZFRIENDS_E2E_GTK_APP`.
- `friends-e2e-devices-check` (`tests/e2e/SZFriendsE2EDevices.h`) runs one person's profile on two and three real
  helpers, with friends as more helpers: joining nearby and through the local host, sync across a partition with
  concurrent edits (the stores compared afterwards), removing a computer, deleting history, You and files held on
  another computer, and friends reaching any of the computers. A partition is a helper restarted on a Bonjour type of
  its own. Its helper is the online test main (`tests/e2e/SZFriendsE2EOnlineHelperMain.m`); the online scenario
  skips with a reason where the host service cannot run.
- `friends-one-identity-check` (`tests/e2e/SZFriendsE2EOneIdentity.h`, not in `friends-suite`: the repository's
  `make friends-one-identity-e2e` runs it with Shenzhen 3D's tree, and `make friends-tests` with it) puts the three
  apps on one home with nothing saying where Friends lives: ShenzhenPDF's AppKit views in process
  (`szfriends_e2e_appkit_app.m`), Shenzhen Files' GTK button and dropdown (`szfriends_e2e_gtk_views_app.c`) and
  Shenzhen 3D's packaged Electron shell with its React panel (`apps/3d/electron/friends-one-identity-app.mjs`), each
  embedding the test helper with a build number. It starts them in every order and with older and newer helpers, kills
  the helper under them, types into each app's own composer and reads the other two views, and checks one helper
  process, one Friends ID and one Friends home throughout; then two computers of one profile, nearby, online through
  the local host and coturn (`FRIENDS_TEST_COTURN`), and with one of them away. Nothing reaches the screen: the AppKit
  app is never a foreground app, the GTK app links the quiet interposer, and Electron runs as a background-only copy
  behind `apps/3d/electron/hidden-hook.cjs`.
- Never launch, quit or screenshot ShenzhenPDF, Shenzhen Files or Shenzhen 3D to verify Friends work; the owner's
  copies may be running. Verify with headless suites, the two-helper harness and offscreen probes.
- Every maintained source file stays at or under 500 lines (`tools/check-file-sizes.sh`), lines at or under 120
  columns, and comments say why.

Run everything with `make -C portable friends-tests`, or one area with its `friends-<area>-check` target.
The store's committed v1 database fixture (`service/store/tests/fixtures/store-v1.sql`), which the migration tests
open, is frozen now that schema v2 exists: `make -C portable friends-store-v1-fixture` refuses and says so, because a
shipped version's fixture never changes (ADR 0003).

## Fixtures

`fixtures/` holds golden frames for every view in the states the mockups show: a list with a pending request
carrying its own Accept, Decline and Block, an unread conversation, a pending offer, an automatically accepted file,
a file queued for an offline friend, a friend added by ID whose ID the Friends host confirmed, and a blocked person
drawn muted; a fresh list whose ID changed, with the name prompt and no friends yet; Nearby while visible with
Bluetooth off, and with Local Network denied; a conversation with a delivered and a receiving file; a request with
its comparison code and an armed Block; friend details with automatic acceptance on, Remove friend asking first and
an armed Block; the profile with an unreserved ID and no QR (M1); the Settings section. Behind the list's pending
offer and queued file are their conversations: Kenji, over Bluetooth, with earlier history to load; Priya, not
nearby, with an older message that stopped trying after 30 days, the assistant's message with the wrong page that
Raph cancelled before it left, and two queued messages four minutes apart, the second without a time of its own.
File previews (ADR 0008): Kenji's pending offer and Mei's drawing on its way carry the sender's picture, Mei's
delivered contract carries one made on Raph's Mac, and Priya's queued contract has none, so the type icon shows;
every transfer's `file` gives `type_identifier` and `extension` for that icon. Mentions:
`conversation-daniel-mentions.json` is built for a client that declares `mentions` and shows every way a mention
resolves: friends, the reader, a stranger to add, one who asked and one blocked, and a forgery shown as plain text.
It holds messages only, leaving Daniel's transfer out. Links (§ Links in `PROTOCOL.md`): `profile-links.json` is the
profile with Your links (the friend link, and two download links, one with a long file name), and the replies give
Leo Park's friend link card and a copied download link; the presentation suite rebuilds the profile and the card
from their facts, and the views' suites read them directly. Then one example of every intent in `intents.jsonl`,
successful replies, and the frames around them: an error reply, the reply the client library makes for an intent
outstanding when the connection drops (`connection_lost`), and the reply and goodbye for a hello with no common
major. Every view below the list carries the same waiting count on its back arrow as the list in that moment (two:
Lena's request and Kenji's offer). Mei's contract and its note came via the assistant, and so did Kenji's note, so
both sides of `assistant_label` show. Behind `message-status.json`, AI chat follows Priya's queued message and Mei's
delivered note, and the message Raph cancelled. Priya's queued messages carry Cancel. Display strings write IDs with
U+2011 between their words, and apostrophes as ’; `friends_id` fields keep the ASCII form, and messages keep what
their sender typed.

- `friends-protocol-check` validates every fixture against the `schema` blocks in `PROTOCOL.md`, fails on a
  fixture field the document does not declare, fails when a view, intent or result has no fixture, and checks
  that `client/szfriends_client.h`, `PROTOCOL.md` and the welcome fixture agree on the version and limits.
- The presentation layer's tests compare its output with these files, and the fake helper replays them for the
  AppKit and GTK views' tests and the host adapter's; the GTK suite also parses every snapshot into its structs and
  back.
- One profile on several computers (PROTOCOL.md § Devices, § Joining): `devices-*.json` show Your computers, a
  computer another one removed, a new computer's link to join, the You conversation, files another computer holds,
  and Delete history on several computers; `join-*.json`, `list-join-requests.json` and `badge-join-requests.json`
  the joining flow, and `intents.jsonl` one example of each of their intents. `friends-presentation-check` rebuilds
  the joining ones from their facts and holds every string of the `devices-*` ones to the catalog. Their names
  keep them out of the fake helper's `conversation-*` and `details-*` sets, whose ids must stay unique.
- `text/invisible-cases.json` holds the shared invisible-character cases every implementation runs (§ Areas,
  Invisible characters): each case says whether the send check refuses the text and which code points the cards mark.
- `friends-protocol-check` also checks that the tables written for people agree with the parts written for
  machines: § Static strings with the welcome fixture's strings, the error-code table with `type.error`, and each
  "Field of `<schema>`" table with its block; and that some fixture holds every shared object (`type.*`).
- Fixture times assume Monday 12 October 2026, 14:47:48 Hong Kong time (Asia/Hong_Kong, UTC+8), so the
  visibility deadline `06:52:00Z` leaves 4:12 and message times such as 14:32 match their `sent_at`. Names are
  invented, IDs are made of words in the v1 list (so Add by ID would take them), and keys and hashes are
  synthetic. Animal avatars use set 1, indexes 0, 1, 3, 4, 5, 7, 9, 10 and
  11, with the colors of `avatars/animals/manifest.json`, which the presentation tests load.
- The presentation builder reproduces every snapshot fixture from the facts in
  `service/presentation/tests/SZFriendsPresentationWorld.m`. Change a state by changing those facts and the
  fixture together; `friends-presentation-check` fails until they agree, and `friends-protocol-check` must stay
  green in the same change.

## Integration the lead owns

Done: the views, client library, cJSON and animal set are linked into ShenzhenPDF.app; the helper bundle is
embedded in `Contents/Helpers/` and signed on its own `codesign` line before the outer bundle; the host adapter
is part of the app's build and its suite runs with `friends-tests`; libsodium's (ISC) and cJSON's (MIT) license
texts and the EFF word list attribution (ADR 0006) ship as `Acknowledgements.txt` in the helper bundle and in the
app's `Resources/Friends/`, and in the repository's `NOTICE.md`.

Still open:

- Prove launch timings unchanged with Friends on and off (ADR 0002, the M1 launch gate), on a copy of the app.
- Developer ID signing, notarization and the Team ID check on the helper, with the release identity; and the app
  side of the same check: the views' transport (or the host adapter) calls `szfriends_set_signing_policy()` with
  the app's own Team ID and a Security.framework verifier before the launch spawn.
- When committing, stage `ext/libsodium/`, `ext/cjson/`, `ext/versions.txt` and `portable/friends/`
  explicitly.

## Friends off the Mac

Windows, Linux, Android and iOS run the same protocols from a Rust core in `core-rs/` (ADR 0015): a helper process
per person on desktops, in-process on phones, with the same snapshots and intents so one React UI (Shenzhen 3D's)
renders them. Golden vectors exported from this helper's own code (`core-rs/tools/objc-vectors`,
`fixtures/vectors/`) keep the two implementations byte-identical: `friends-vectors-check` runs in `friends-suite`,
`friends-core-rs-check` runs the Rust suites. A change to a wire format regenerates the vectors in the same commit.

## Hosting Friends in Shenzhen Files

Shenzhen Files is GNOME Files (Nautilus) ported to macOS: GTK4 and C, built with meson from a patch against
upstream, in its own repository (`docs/friends-integration.md` there is the plan of record). It hosts Friends with no
protocol or storage change:

1. It embeds the same helper in its bundle (`Contents/Helpers/Shenzhen Friends.app`), built from a shenzhen-pdf
   commit its `friends.lock` pins, with that commit's build number. Both apps share one Friends identity, friends
   list, history, name and automatic-acceptance choices per Mac user, in
   `~/Library/Application Support/Shenzhen Friends/`. The first app to start runs its helper; an app carrying the
   same build uses it, and one carrying a higher build asks it to hand over (PROTOCOL.md § Lifecycle). Build numbers
   change only at ShenzhenPDF releases, so a Files build pinned between releases ties with the last release and
   whichever app starts first keeps its helper. `friends-e2e-check` runs both apps on one helper, and the handover
   between them. Before release, verify both helper copies (same identifier and team) read the Keychain item without
   prompting.
2. It uses the GTK views (`gtk/szfriends_gtk.h`, built into `libszfriends_gtk.a` by `friends-gtk-lib`), whose link
   drives the C client library from the GLib main loop: the client's descriptor watched and re-armed on every state
   change, ticks on a timeout, subscriptions sent again after every READY. Signed with the team, Files sets the
   library's signing policy at launch, with a verifier on Security.framework, as ShenzhenPDF does.
3. The views draw the same snapshots as the AppKit ones: the button at the top right of the header bar, the views in a
   `GtkPopover` holding an `AdwNavigationView`, `GtkDropTarget` for files, json-glib to parse frames, the animal set's
   SVGs drawn directly. Strings are plain text, never Pango markup.
4. Its adapter (a patch in the Files repository) implements `gtk/szfriends_gtk_host.h` in C: `#` lists the selected
   files and the current folder, never a symbolic link (the helper sends only regular files, as drops refuse links),
   received files are shown selected in a Files window (`reveal_in` "Shenzhen Files", no formats opened in place), no
   `/`, and `toolkit` `gtk4` in the hello.
5. The catalog's `apps.with_friends` (`service/presentation/SZFriendsCatalog.m`) is "ShenzhenPDF, Shenzhen Files or
   Shenzhen 3D", and every catalog string that names the apps says `{apps}`. The note that says when queued messages
   go (`queued_note`, PROTOCOL.md § Views, `conversation`) names every app, because any of them open on each
   computer sends them; naming only the app showing the note would be untrue for a friend who has only another one
   open. ShenzhenPDF's Settings subtitle says the same.

ShenzhenPDF's GTK4 Linux frontend can reuse those views later.
