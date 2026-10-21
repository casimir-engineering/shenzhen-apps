# ADR 0015: Friends on Windows, Linux, Android and iOS: a portable Rust core

Status: Proposed by lead, 2026-10-16, revised the same day after a critic's review (Windows and Linux builds,
pipe spoofing, packaging, firewalls, Intel Macs, backups, edge-case vectors); owner review pending. Plan:
[friends-portable-core.md](../../../docs/plans/friends-portable-core.md). Builds on every earlier record: the wire
formats of 0001, 0004 and 0009 to 0014 and the view contract (PROTOCOL.md) are what this core implements again.
Code: `portable/friends/core-rs/` (a Cargo workspace), vectors in `portable/friends/fixtures/vectors/`.

## Context

The owner wants Shenzhen Friends in Shenzhen 3D, and Shenzhen 3D ships everywhere: macOS (Electron shell, primary;
also a lightweight Tauri build), Windows (Tauri 2, WebView2), Linux (Tauri, WebKitGTK), Android 7+ and iOS/iPadOS
15+ (Tauri mobile), and the web as a PWA (3D's `docs/PLATFORMS.md`). Friends today is an Objective-C helper on
Foundation, Network.framework, CoreBluetooth and the Keychain, with AppKit and GTK views over a client protocol. The
brief left "Linux/Windows clients" for a later decision and kept every wire format free of Apple types for it. A
parallel change is building Shenzhen 3D's Mac integration: a React Friends UI that implements the view contract and
talks to the shared helper through Electron IPC (`window.shenzhenFriends`, 3D's `src/friends/bridge.ts`).

What must hold on every platform: one person reaches the same friends over the same protocols (a Windows PC must
talk to a Mac running ShenzhenPDF), nothing new on any app's launch path, no notifications outside the app, the
relay as a 5 Mbit/s last resort after direct, peer-to-peer and Bluetooth routes, and the same review bar the helper
met (vectors, fuzzing, an independent security review).

## Decision

**1. One Rust core implements the helper's protocols and the view contract again, for every platform but macOS.**
`portable/friends/core-rs` holds crates that mirror the helper's areas: `szfriends-wire` (frames, handshake
payloads, preamble, stream framing, route rank), `szfriends-crypto` (Noise, comparison codes, presence tags, CPace and
join tags, invite proofs), `szfriends-identity` (keys, certificate, signature domains, the secret item, Friends IDs,
key-store rules), `szfriends-contract` (PROTOCOL.md framing, ids, socket paths), then `szfriends-core` growing the
session, store, presentation, IPC, nearby, online and device areas, and `szfriends-helper`, the desktop binary.
Snapshots and intents are PROTOCOL.md's JSON exactly, checked against `fixtures/snapshots`, `fixtures/replies` and
`intents.jsonl`, so the React UI that renders the Mac helper's snapshots renders this core's unchanged.

WHY Rust rather than porting the Objective-C: Foundation, Network.framework, CoreBluetooth, the Keychain and GCD are
the helper's skeleton, and none of them exists on Windows, Linux or Android. WHY not C: Tauri hosts Rust natively on
all five targets, the crypto, SQLite and WebRTC crates (or bindings) exist for each, and memory safety matters in
code that parses strangers' bytes before Noise authenticates them. WHY Rust on iOS too, where the Objective-C would
compile: the helper is built as a separate macOS process (socket server, lock, spawn, handover, IOKit sleep and
wake), so running it inside an iOS app means restructuring it anyway, and one in-process core for both phones keeps
one lifecycle, one file-staging path and one test matrix; the iOS-only parts (Network.framework, CoreBluetooth,
the Keychain) are thin Swift bridges in the plugin either way.

**2. macOS keeps the Objective-C helper; nothing Rust runs as a helper on a Mac.** One identity and one history per
Mac user, shared by ShenzhenPDF, Shenzhen Files and Shenzhen 3D, owned by one helper (ADR 0002). Shenzhen 3D's
Electron app embeds that helper (the parallel change). Its lightweight Tauri build embeds it too and connects as an
ordinary client through `tauri-plugin-szfriends` in client mode (decision 4). `szfriends-core::paths` returns no
state directory on macOS, so a mistaken build cannot create a second identity there.

*Intel Macs get Friends: the Objective-C helper is built universal.* Shenzhen 3D ships one universal Mac app (Apple
silicon and Intel), so an arm64-only helper would leave Intel Macs without Friends. The helper's only obstacle was
ADR 0009's note that the vendored libsodium configuration is arm64-only. A probe on this change built the helper's
session, identity and discovery sources and libsodium for x86_64 (a portable libsodium configuration without x86
intrinsics), ran the vector exporter under Rosetta, and it reproduced every committed vector file byte for byte;
ADR 0009 already built the WebRTC stack for x86_64 (about 1.7 MB more than arm64). So the helper gains an x86_64
slice, built in wave 2: libsodium's x86_64 configuration (`deps.mk`) is the arm64 one without ARM crypto, plus the
x86 intrinsic headers and CPUID detection configure finds, but not the x86_64 assembly, which is not vendored; the
slices are joined with `lipo` (`make friends-helper-universal`), and `make friends-universal-check` runs the x86_64
slice's libsodium, session, link-signalling, vector and online-stack checks under Rosetta. AES-256-GCM, which seals
download links, needs AES-NI, PCLMUL and AVX: every Intel Mac macOS 12 supports has them, and Rosetta reports AVX
only with `ROSETTA_ADVERTISE_AVX=1`, which that check sets. Comparing the x86_64 objects byte for byte with
configure's awaits the verified libsodium release tree. A release that ships an arm64-only helper instead reports
Friends unavailable on Intel (`status` says so; the UI shows nothing of Friends, as on the web), never a helper
that cannot start. ShenzhenPDF itself stays arm64 only.

**3. Process model per platform.**

| Platform | Where the core runs | Talks to the UI over |
|---|---|---|
| macOS | the Objective-C helper | Unix socket, PROTOCOL.md (Electron: N-API link; Tauri: the plugin's client mode) |
| Windows | `szfriends-helper.exe`, one per user, embedded in each app | named pipe, PROTOCOL.md framing |
| Linux | `szfriends-helper`, one per user, embedded in each app | Unix socket, PROTOCOL.md § Transport unchanged |
| Android | in the app's process, its own threads | in-process channel carrying the same JSON frames |
| iOS, iPadOS | in the app's process, its own threads | in-process channel carrying the same JSON frames |
| Web, PWA | nowhere: no Friends | (the bridge is absent, so the UI shows nothing of Friends) |

Desktops get a helper process for the reasons ADR 0002 gave on the Mac, which hold there too: one identity and
store per person shared by every app that hosts Friends (a Linux ShenzhenPDF or Files later), single instance by
lock, transfers that survive a crashed or reloaded webview, and handover to the newest build. The Rust helper keeps
the lifecycle of PROTOCOL.md § Lifecycle: connect-or-spawn after the first paint, exit 10 seconds after its last
client, 30 seconds when no client ever came, handover by protocol version then build number. Phones cannot share a
process or files between apps and suspend background processes, so the core runs inside the app; the JSON frames
are the same, carried by a channel instead of a socket, so the plugin and the UI do not know the difference.

On a phone each app that hosts Friends has its own state directory and so its own device keys: Shenzhen 3D and a
later ShenzhenPDF for iOS on one iPhone are two of the person's devices, joined like any new computer (ADR 0013).
An iOS App Group could later let two apps from one team share a store; not now.

**4. Tauri integration: `tauri-plugin-szfriends`, in `portable/friends/tauri/`.** A plugin (Rust, plus a small
guest script) that registers commands and events and exposes `window.shenzhenFriends` with exactly the
`FriendsBridge` interface the Electron preload exposes (join, status, subscribe, send, setEnabled, image, animal,
animals, pathsForFiles, classify, stage, token, openFile, showFile, openSettings, openURL), so the React UI has one
code path. Two modes behind it: *client* (desktop: connect-or-spawn the embedded helper, speak PROTOCOL.md over the
socket or pipe; on a Mac, the Objective-C helper) and *embedded* (mobile: start the core in-process). The plugin's
`init` registers commands and nothing else; the core or the connection starts on the UI's first `join()`, which the
UI sends after its first paint. The React views stay in each app (3D's `src/friends/`) until a second web host
appears, when they move to `portable/friends/web/`. The plugin lives beside `mac/` and `gtk/`, not in the core
workspace, so the core builds and tests without Tauri.

- *Only the main window may call Friends.* The plugin's permissions are granted in one capability file whose
  `windows` is `["main"]` and which lists no `remote` URLs, so another window, an iframe or a remote page cannot
  invoke a Friends command; a test calls `plugin:szfriends|send` from a second window and from a remote URL and
  expects refusals (wave 3).
- *Dropped files.* Electron's `pathsForFiles` reads a dropped `File`'s path; WebView2 and WebKitGTK `File` objects
  carry none. On desktops the plugin keeps the paths from the window's native drop event (`DragDropEvent::Drop`)
  when the host app has native drops on (Tauri's `dragDropEnabled`, which on Windows also turns off HTML drop
  events in the page: the app's choice, never the plugin's), and `pathsForFiles` answers from the latest native drop
  only when the names and sizes match the `File`s; otherwise it answers with no paths and the UI stages the bytes
  (`stage`), as on phones. Paths never come from the page itself. Attach uses the plugin's file dialog, which
  returns paths.

**5. Cryptography.** Noise: `snow` 0.10 with its default ChaCha20-Poly1305 and BLAKE2b and our own X25519 resolver
(`CheckedX25519`) that refuses an all-zero result, as the helper does; plus the helper's rules around it (keys must
fit the pattern, a failed handshake is dead, 65,519-byte frames, rekey per direction). `snow`'s "std" feature is off
because in 0.10 it pulls in `ring`. snow is the independent implementation ADR 0001 already uses as its second vector
source, so agreement with the helper's own C on Friends' real handshakes is a true cross-check. CPace:
`curve25519-dalek` 4 ristretto255 and `sha2`, matching libsodium's `crypto_scalarmult_ristretto255` exactly (top
scalar bit cleared, identity results refused) and draft-13 Appendix B.3. Signatures: `ed25519-dalek` 2 with
`verify_strict` plus a canonical-key check, matching libsodium's refusals of small-order and non-canonical keys.
Where Ed25519 and X25519 implementations are known to differ, the helper's own verdicts are exported and the Rust
core must agree on each (`objc-edge-cases.json`): small-order keys and R (all eight torsion points, both signs) with
the verification equation made to hold, S + L, mixed-order keys with 8 dividing h (libsodium accepts) and not
(refuses), mixed-order R, and every non-canonical key encoding y = p + k; for X25519, libsodium's low-order list with
and without the top bit (refused) and points off the prime-order subgroup (same bytes).
Presence tags and join tags: keyed BLAKE2b-256 (`blake2`). Invite proofs: HMAC-SHA-256 (`hmac`). One
curve25519-dalek for all of it.

**6. Golden vectors from the helper's own code.** `core-rs/tools/objc-vectors` is a small Objective-C program linked
against the helper's production sources (session, identity, discovery's pure files, vendored libsodium). It exports
deterministic vectors (every frame type, the decoder's accept and refuse decisions, handshake payloads, Friends'
three handshakes with the real prologue and payloads, transport frames across a rekey in each direction, comparison
codes, presence tags, the session race, identities, every signature domain, REQUEST_BY_ID, the invite proof, Friends
ID normalisation and draws, CPace and the join tags) into `fixtures/vectors/`. `make friends-vectors-check` (part of
`friends-suite`, no Rust needed) fails when the helper's behaviour no longer matches the committed files, and when a
committed `objc-*.json` is no longer exported (a stale file would keep feeding the Rust suites); `make
friends-core-rs-check` runs the Rust suites against them. A wire change therefore cannot land on one side alone.

**7. Store and keys.** The store is SQLite through `rusqlite`, the same schema, migrations and pragmas as ADR 0003
(the store areas share SQL fixtures), FTS5 with the trigram tokenizer: bundled SQLite on Windows, Linux and Android
(no usable system library on Android's NDK; a predictable FTS5 elsewhere), the system library on iOS. WHY the
system library on iOS: the Mac helper uses the system SQLite too (`-lsqlite3`), and iOS 15 carries the same SQLite
line as macOS 12 (3.36 and later, trigram since 3.34), so search behaves alike on both Apple systems and iOS saves
about 1.1 MB. Evidence: a probe linked against the iOS simulator SDK's SQLite (iOS 15 deployment target) created an
FTS5 trigram table and matched a Latin substring and a Chinese one in the simulator. The store's open checks for
FTS5 with the trigram tokenizer and creates its trigram table at open, as the helper does (ADR 0003, Corrections), so
its schema is the helper's statement for statement; a library without them leaves the store unavailable rather than
without search, and the bundled library is the fallback. The store wave's FTS5 test runs on every
platform, the iOS simulator included (`run-device-tests.sh ios-sim`). The identity
is the same 133-byte secret item in one key-store entry, behind the `KeyStore` trait whose rules are the helper's
(an existing but unreadable secret is unavailable and never replaced; create, then read back):

- Windows: a DPAPI-protected (CurrentUser) file under `%LOCALAPPDATA%\Shenzhen Friends\keys`; not Credential
  Manager, whose entries roam with roaming profiles.
- Linux: a Secret Service (D-Bus) item; where none runs, a 0600 file under the state directory, and the store
  records which, so a Secret Service missing later reads as unavailable rather than as "no identity".
- Android: a file in app-private storage, sealed with AES-256-GCM by an Android Keystore key (not exportable, not
  backed up).
- iOS and iPadOS: a Keychain generic password, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync.

State directories: `$XDG_DATA_HOME/shenzhen-friends` (or `~/.local/share/shenzhen-friends`), `%LOCALAPPDATA%\Shenzhen
Friends`, and the app's private directory on phones (`szfriends-core::paths`). Tests use the memory store and the
file store only; no suite touches a real keychain, credential store or Keystore. Phones' key stores and the rule
for a store restored without its key are decision 17.

**8. Desktop IPC.** Linux follows PROTOCOL.md § Transport as written (socket path rule, 0700 directory, `SO_PEERCRED`
uid check, `flock`). Windows uses a named pipe, and because the pipe namespace is shared by every account on the
machine, creating a pipe first proves nothing: another account, or a sandboxed process, could create the name
before the helper and wait for clients. So (`szfriends-contract::pipe`):

- *A lock file decides the single instance*, not pipe creation: `%LOCALAPPDATA%\Shenzhen Friends\ipc\helper.lock`,
  held with `LockFileEx` for the helper's lifetime; only the user can write there. The holder writes its process id
  at the start of the file and locks a byte past it, so clients can read who holds the lock.
- *The pipe's name is unguessable and written down.* The lock holder creates
  `\\.\pipe\szfriends-<user SID>-<16 hex of the state dir>-<32 random hex>` with `FILE_FLAG_FIRST_PIPE_INSTANCE`,
  `PIPE_REJECT_REMOTE_CLIENTS`, a DACL granting only the user's SID and an explicit owner (that SID), then writes the
  name to `ipc\helper.pipe` (replaced atomically). Clients read the name there and accept it only in exactly that
  form for their own SID and state directory.
- *The client checks the server before sending a byte*: `GetNamedPipeServerProcessId` must be the lock's holder,
  read after the pipe connected, so a name left behind by a helper that has exited or handed over is not trusted;
  that process's token user SID and the pipe's owner SID (`GetSecurityInfo`) must both be the client's own user;
  anything unreadable is a refusal. It opens the pipe with `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`, so no
  server can act as the client. The helper checks each client's token user the same way
  (`GetNamedPipeClientProcessId`).
- *Neither side trusts a weaker process of the same user*: the other end's token must not be an AppContainer's
  (`TokenIsAppContainer`), and its integrity level (`TokenIntegrityLevel`) must be at least the checker's own. A
  sandboxed or low-integrity process running as the user could otherwise squat the name or drive the helper. So the
  helper, the apps and `--handover` (§ 14) all run unelevated, as per-user installs already do; an app started
  elevated finds Friends unavailable rather than trust, or be trusted by, a helper at a lower level.

The decisions are pure functions with unit tests now (SID form, name round trip, a squatter's process or owner
refused, unreadable facts refused, AppContainer and lower-integrity peers refused both ways, a server that is not
the lock's holder refused, the holder's line in the lock); the Win32 calls that gather the facts come with the
helper in wave 3, in a platform crate (these crates forbid `unsafe`). Wave 3's test plan, in the Windows 11 VM: a
second local account creates the advertised name first and the client refuses it without sending; a pipe created
by the same user but another process with a different owner is refused; a second helper that cannot take the lock
exits without creating a pipe; the advertised file pointing at another user's pipe is refused; a remote client is
rejected by the pipe; a low-integrity process and an AppContainer process of the same user are refused as server
and as client; a pipe still advertised after its helper exited is refused. Framing, handshake and frames are
PROTOCOL.md's unchanged; PROTOCOL.md gains a Windows row in wave 3.

**9. Transports and route order.** The order is the owner's everywhere: direct on the same network, then peer to
peer (a direct Wi-Fi link, then a direct Internet connection), then Bluetooth, then the relay capped at 5 Mbit/s,
judged by `szfriends-wire::route::rank`, which agrees with the helper's rank (vector-checked).

- *Online*: libdatachannel with libjuice, usrsctp and Mbed TLS, the exact pinned sources ADR 0009 vetted (`ext/`),
  compiled by a `szfriends-datachannel-sys` crate with `cc` from the same source lists `deps/datachannel.mk` uses,
  for every target. WHY: interoperability with the Objective-C helper is mandatory and is then the same ICE agent,
  DTLS and SCTP on both ends; the helper's connection order (signalling first, injected port-mapping and predicted
  candidates, its own direct-phase timer, the relay as a second peer connection) carries over as is; one stack to
  review. Rejected: webrtc-rs (several times the size, an API being rewritten), str0m (sans-I/O and small, but no
  TURN client and a second ICE agent to validate against libjuice; kept as the fallback if a target cannot build
  the C++). TURN credentials, rendezvous and host protocol 3 as ADR 0010 says; the relay cap is the host's coturn
  `max-bps`, so it holds whatever the client.
- *LAN*: a TCP listener plus DNS-SD `_szfriends._tcp` with ADR 0004's TXT records. Linux and Windows: `mdns-sd`
  (pure Rust; on Linux it coexists with Avahi). Android: `NsdManager` through the plugin's Kotlin side (it handles
  the multicast lock and Android 12+ restrictions). Before Android 14 `NsdManager` resolves one service at a time (a
  second resolve fails with `FAILURE_ALREADY_ACTIVE`), so the plugin queues resolves one by one, newest sighting
  first, each with a timeout; on 14 and later it uses `registerServiceInfoCallback`. Windows uses the system DNS-SD
  API instead of mdns-sd (decision 15). iOS: `NWListener` and `NWBrowser` through the plugin's Swift side,
  with `includePeerToPeer`, which also gives the peer-to-peer Wi-Fi class to Macs and iPhones (AWDL); a raw multicast
  socket would need Apple's multicast entitlement. The listener's bytes go to the Rust core through the platform
  bridge.
- *Peer-to-peer Wi-Fi*: Apple platforms only (AWDL). Wi-Fi Direct and Wi-Fi Aware do not interoperate with it, so
  Windows, Linux and Android have no such class; their nearby routes are LAN and Bluetooth. Whatever the platform,
  peer-to-peer Wi-Fi is used only where the device stays on its Wi-Fi network at the same time, so a transfer never
  cuts its Internet connection; otherwise, or when unsure, the racer skips it for the next route (`P2pWifi`,
  `p2p_wifi_usable`; ADR 0011 § Route rank says what a Wi-Fi Direct implementation would have to check).
- *Bluetooth*: ADR 0004's service UUIDs, characteristic and an unencrypted L2CAP channel carrying Noise. iOS:
  CoreBluetooth, peripheral and central, L2CAP. Android 10+ (API 29): `BluetoothLeAdvertiser`, scanning and
  `listenUsingInsecureL2capChannel`; Android 7 to 9 have no L2CAP channels, so there Bluetooth only finds friends
  (presence) and a Wi-Fi or Internet route carries the session. Linux: BlueZ through `bluer` (advertising, GATT server,
  LE L2CAP sockets). Windows: no Bluetooth route (WinRT exposes no LE L2CAP channel), so the helper does not announce
  `nearby.bluetooth` there and the views already show nothing of it. `btleplug` is central-only and is not used.

**10. Phones: lifecycle, permissions, files.** Friends works while the app is in the foreground; when it goes to the
background the core finishes what it can in the platform's grace period (iOS background task, Android until the
process is cached), then closes sessions. Transfers resume from the recipient's verified offset when the app returns
(ADR 0001 resume), which is the same mechanism a route change uses. No background service, no push, no foreground-
service notification: the brief's "no external notifications" holds on phones too, and the badge is in the app.
Permissions are asked only when the person opens Friends (`activate`), never at launch: iOS Local Network
(`NSLocalNetworkUsageDescription`, `NSBonjourServices` = `_szfriends._tcp`) and Bluetooth
(`NSBluetoothAlwaysUsageDescription`); Android `BLUETOOTH_SCAN`/`ADVERTISE`/`CONNECT` (12+), and on 7 to 11
location for Bluetooth scanning, which the Nearby page explains when it is refused. Not `NEARBY_WIFI_DEVICES`: it
guards Wi-Fi Aware, Wi-Fi Direct and hotspots, none of which Friends uses, and `NsdManager` needs only install-time
permissions (`INTERNET`, `ACCESS_NETWORK_STATE`, `CHANGE_WIFI_MULTICAST_STATE`). Files: an
outgoing file is staged as a copy in the app's private storage (the bridge's `stage`), because a picked document is
only borrowed and resume needs its bytes; received files land in a private `Received files` directory and the UI
offers Open (in the app), Save to Files or Downloads (the system picker) and Share. No storage permission is ever
asked. Partial files are excluded from backups; staged copies are deleted after DONE or cancel. The state directory is
excluded from backups as a whole (decision 17).

**11. Multi-device parity.** The device chain, joining with CPace and sync (ADR 0012 to 0014) are implemented with
the same frames, signatures and vectors, so one profile can hold a Mac on the Objective-C helper, a Windows PC and a
phone on the Rust core. The end-to-end device scenarios run with mixed implementations before either side ships the
other's platform.

**12. Size and startup budgets.** Nothing runs before the app's first paint; the plugin's `init` only registers
commands. Budgets, measured per release build and enforced by a size check from the IPC wave: the desktop helper at
most 6 MB stripped per architecture; the embedded core at most 5 MB added per Android ABI (3 MB in a compressed
APK split) and per iOS architecture. The estimate: core and crypto about 0.6 MB, SQLite about 1.1 MB (none on iOS),
the WebRTC stack 1.6 MB (ADR 0009's measurement), runtime and JSON about 0.7 MB. The async runtime is `tokio` with
only the features used, because Tauri apps already link it. Measured after wave 2 (`core-rs/tools/embedded-size.sh`,
everything the core has so far linked as a phone app links it): 4.50 MB on Android arm64 (2.08 MB deflated), of
which the WebRTC stack is 2.30 MB (it carries the NDK's static C++ library there); 2.59 MB on iOS arm64 (system
SQLite). Android is within budget with 0.5 MB left for waves 3 to 6, so the size check of wave 3 tracks it per wave.
The stack's C and C++ build at `-O2`, like the helper's copy, which costs about 0.1 MB over `-Os`; that, and
SQLite's unused features, are the savings at hand. The Windows helper links the C runtime statically
(`+crt-static`, about 0.2 MB more) so it needs no Visual C++ redistributable.

**13. The web build has no Friends.** A page cannot listen, keep an identity key safely, or find anyone nearby, and
the helper's security rests on all three. `szfriends-wire` and `szfriends-contract` compile for
`wasm32-unknown-unknown`, checked by `friends-core-rs-cross-check`, so a later browser client (WebRTC to the host,
an identity in WebCrypto) can reuse them; crypto and identity would need a browser random source and key store,
which belong to that client's own decision. Download links already reach browsers through the links page
(friends-links.md), which is unchanged.

**14. Desktop packaging: the helper runs from a per-user copy.** An app never spawns the helper from its own
install: a Windows installer (NSIS or MSI) cannot replace an executable that is running, so an update would fail or
ask for a restart while any app's helper ran, and an AppImage's files live in a FUSE mount that disappears when the
app that mounted it quits, taking a helper spawned from it down. So before spawning, the app copies its embedded
helper to `<state dir>/helper/<version>-<build>-<16 hex of its SHA-256>/szfriends-helper[.exe]`
(`szfriends-core::paths::helper_copy_dir`): written to a temporary name, synced, renamed into place, checked
against the digest; an existing directory with that name is reused and never rewritten, so a running copy is never
touched. The lock holder removes copies older than its own version and build (`stale_helper_copies`), never newer
ones, which may belong to a helper about to take over; on Windows a copy still running cannot be deleted and is
tried again at the next start. A Windows installer and an AppImage's first start ask a running helper to step aside
through the ordinary handover (PROTOCOL.md § Lifecycle): they run the new helper with `--handover`, which connects
as a client whose `embedded_helper` is newer, waits for the old helper's `goodbye`, and exits. Nothing is ever
stopped by name or process id. Linux packages (deb, rpm) behave like the AppImage, which keeps one code path.

**15. Firewalls: nothing in Friends causes a firewall prompt, and routes work outbound first.**

- *Windows.* Defender Firewall prompts the first time a program listens on a network address; on a standard
  account the prompt needs an administrator, and dismissing it leaves block rules for that program's path (and
  every versioned copy would prompt again). So the helper listens for LAN connections only when the firewall
  already admits them: it reads the current profile with `INetFwPolicy2` (read-only, no elevation) and listens when
  that profile's firewall is off or an enabled inbound rule covers the helper's port. The per-user NSIS installer
  (Tauri's default) adds no rule. An administrator's per-machine install (MSI) adds one inbound TCP rule for a fixed
  port on the Private profile only, removed on uninstall. Discovery uses the Windows DNS-SD API
  (`DnsServiceBrowse`, `DnsServiceRegister`, Windows 10 1809 and later), served by the system's DNS client with its
  built-in mDNS rules, not mdns-sd's own UDP 5353 socket; the helper announces a port only while it listens.
  Only rules for any program or for the helper's own path count: a rule scoped to a service, an app package or one
  user admits nothing for the helper (Windows 11 ships enabled allow-all rules scoped to packages, which first made
  the decision wrongly "listen"). A rule's port ranges are honoured: the hidden listener's port moves within them.
  Windows' DNS-SD API does not browse on loopback, so its own test runs on the VM's virtual network, on request.
- *Linux.* The helper never changes firewall settings (firewalld and ufw need root). Fedora Workstation's default
  zone admits mDNS and ports 1025 to 65535; Fedora Server's and RHEL's `public` zone admit mDNS but not the
  listener's port; Ubuntu's ufw is off by default. A blocked listener is handled like Windows' missing one. What
  to tell someone on such a zone is in `core-rs/README.md` § Firewalls on Linux: nothing needs changing for friends
  to reach each other; a zone admitting high TCP ports (Fedora Workstation's) also lets people nearby connect.
- *Outbound first.* Every nearby route works in either direction: whichever side finds the other dials, and the
  session race (vector-checked) settles a crossing pair. A computer that cannot accept connections still reaches
  every friend that can; two such computers on one network reach each other through the online route, whose ICE
  host candidates work because each side's own outbound packets open its stateful firewall for the reply.
- *Nearby page.* When the Windows helper does not listen, the Nearby page shows one line under the visibility
  setting, for the person at that PC wondering whether something is wrong: "Windows Firewall blocks incoming
  connections, so this PC connects to friends nearby itself. You don't need to change anything." (string catalog
  key `nearby_inbound_blocked`). Linux shows nothing: the helper cannot tell a blocked port from an empty network.
- *Tests* (wave 4): unit tests of the listen decision from firewall facts (profile off, rule present, disabled,
  other profile, other port); in the Windows 11 VM with the firewall on and no rule, the helper runs without adding
  a firewall rule (`Get-NetFirewallRule` before and after) and a Mac on the Objective-C helper exchanges messages
  and a file with it through the PC's own dial; with the per-machine rule, the Mac dials the PC; in the Ubuntu VM
  with firewalld's `public` zone, the same exchange outbound first; a blocked Windows PC and a blocked Linux VM
  reach each other online through the local host.

**16. Desktop power and network events.** The Rust helper reacts to sleep, wake and network changes as the Mac
helper does with IOKit and `NWPathMonitor`: on Windows through `PowerRegisterSuspendResumeNotification` and
`NotifyUnicastIpAddressChange`/`NotifyIpInterfaceChange`, on Linux through logind's `PrepareForSleep` D-Bus signal
and rtnetlink address and link events (NetworkManager not required). Before sleep it pauses transfers at a verified
offset; on wake or a network change it re-announces, browses again, races routes again and resumes transfers.
Phones follow their app lifecycle instead (decision 10). Wave 4 checks it by suspending and resuming the VMs during
a transfer.

**17. Backups and a store without its key.** A Friends store must never be used with a key it was not made for,
and a backup is the usual way that happens: a phone restored from a backup gets the app's files back, while the
iOS Keychain item (`…ThisDeviceOnly`) and the Android Keystore key stay with the old device.

- *iOS:* the state directory sits in Application Support with `NSURLIsExcludedFromBackupKey`, set when it is created
  and checked at every start.
- *Android:* the state directory sits under `Context.getNoBackupFilesDir()`, which Auto Backup and device-to-device
  transfer skip; the Keystore key is not exportable.
- *Windows and Linux:* the state directory is under `%LOCALAPPDATA%` (never roamed) or `$XDG_DATA_HOME`; a DPAPI key
  file restored onto another account or PC cannot be decrypted, which the key-store rules already treat as
  unavailable, never as absent.
- *The rule* (`szfriends-identity::keystore`): the store records its identity's public key when it is created, and
  `IdentityManager::load_or_create` takes what the store records. A key without a store is ready (a new store is
  made for it); neither is a first start; a store whose key is missing is `KeyMissing` and a key of another identity
  is `StoreMismatch`. Neither creates or mixes anything; the views explain it and offer Start again, which removes
  the store and then the key and creates both afresh. Copy for the person on that device, who wonders what
  happened and what Start again will cost: "Friends can't continue from a backup on this device. Start again to set
  up Friends here: the restored conversations are removed, and your friends will need to accept you again." and
  the button "Start again". Tests: the manager's rules over the memory store now;
  in wave 3, a backup and restore with `bmgr` on the Android emulator brings no Friends file back, and an iOS
  simulator check reads the exclusion flag on the state directory.

## Alternatives considered

- **The Objective-C helper everywhere** (GNUstep, or cross-compiled Foundation): no Network.framework, CoreBluetooth
  or Keychain off Apple platforms; every adapter rewritten anyway, in a language without memory safety.
- **A C core** shared with the helper: the helper's C is only the Noise machine and codecs; the service is
  Objective-C. Rewriting it in C buys nothing over Rust and loses Tauri's native integration.
- **The in-process core on desktops too**: simpler, but two apps on one Windows or Linux account would run two
  identities against one state directory, or race for it; a crashed webview would drop transfers.
- **The Rust core on macOS too**, replacing the helper: a migration of every Mac user's identity and store for no
  user-visible gain; possible later once the Rust core has shipped and been reviewed, as its own decision.
- **The Objective-C helper in-process on iOS**: see decision 1; it would also be a third build of the helper's
  areas and vendored libraries (iOS device and simulator) beside the Mac's.
- **Kotlin and Swift cores per mobile platform**: three implementations of one protocol instead of two.
- **A Windows pipe with a fixed name and `FILE_FLAG_FIRST_PIPE_INSTANCE` as the single-instance check**: the name is
  guessable, so another account can create it first and receive the client's frames; decision 8.
- **Intel Macs without Friends**: simpler, but Shenzhen 3D's universal build would show Friends on one kind of Mac
  only, and the x86_64 build already reproduces the vectors.
- **A firewall rule from the per-user installer**: it needs elevation that per-user installs avoid, and a rule by
  program path breaks with each versioned helper copy.

## Consequences

- Two implementations of every wire format, kept together by the exported vectors; a change lands with its vectors
  regenerated, or `friends-vectors-check` fails on the helper side and `friends-core-rs-check` on the Rust side.
- The release machines need a pinned Rust toolchain before `friends-core-rs-check` joins `friends-suite`;
  until then it runs on its own target, and the Objective-C-only `friends-vectors-check` guards the helper side.
- Phones show fewer routes than Macs (no peer-to-peer Wi-Fi off Apple; no Bluetooth data before Android 10, none on
  Windows), and Friends reaches a phone only while its app is open. The views say so from the existing route and
  reachability strings; no new wording claims more.
- Each phone app is its own device of the person's profile.
- A Windows PC without an inbound firewall rule is reached only by its own dials: two such PCs on one network need
  the Internet (the online route) to find each other's session.
- Each helper version a person runs leaves one copy (about 6 MB) in the state directory until a newer helper
  prunes it.
- Intel Macs need a second libsodium configuration maintained beside the arm64 one, and the helper grows by its
  x86_64 slice.
- The Rust core is new security-critical code: it gets its own independent review covering the items of ADR 0001's
  list, the platform bridges and the key stores, before any platform ships it.

## Verification

- Wave 1 (this change): `friends-vectors-check` passes against the committed vectors and refuses a stale one;
  `friends-core-rs-check` runs the wire, crypto, identity and contract suites against them (the Ed25519 and X25519
  edge cases included) and against cacophony's and snow's Noise vectors; `friends-core-rs-cross-check` checks every
  crate and test for Windows (x86_64 and aarch64 MSVC, x86_64 GNU), Linux (x86_64, aarch64), Android (four ABIs),
  iOS and the iOS simulator, and wire and contract for wasm32; the suites pass in the iOS simulator (arm64), in the
  Windows 11 VM for aarch64 and x86_64 MSVC (38 tests each; the Unix-only file key store and Linux path tests are
  replaced by the Windows path test) and in the Ubuntu 24.04 ARM64 VM (39 tests), through
  `run-device-tests.sh windows-vm` and `linux-vm`; an x86_64 build of the vector exporter, run under Rosetta,
  reproduces every committed vector file.
- Wave 2, sessions and store (2026-10-17; the plan records the numbers): the helper's own sessions replayed through
  the Rust channel byte for byte from either side (`objc-session.json`), every received byte flipped; the store's
  schema, fresh and migrated from the v1 fixture, identical to the helper's as SQLite prints it (`objc-store.json`);
  the Rust core against the helper's own channel, store and transfers on loopback in both directions (requests, Add
  by ID, 200 MiB, resume after a cut across rekeys, route migration, tampering:
  `friends-core-rs-interop-check`); an hour of cargo-fuzz over every decoder, clean.
- Later waves, as the plan lists: online through the local Node host and coturn at 5 Mbit/s, direct and relayed;
  the NAT emulator matrix with Rust peers; mixed-implementation device scenarios; snapshot fixtures reproduced
  exactly; the React UI on Windows and Linux (Parallels VMs) and on the Android emulator and iOS simulator; fuzzing
  of the chain, join and sync decoders; size budgets; the independent review.
