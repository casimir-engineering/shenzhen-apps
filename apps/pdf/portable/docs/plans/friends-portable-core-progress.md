# Shenzhen Friends on every platform: progress log

What each wave of the [portable core plan](friends-portable-core.md) built, how it was checked and what it left,
newest last within each wave. The plan holds the waves themselves and their *Done when*.

## Wave 2: Sessions, store, and the hard builds first

*Sessions and store, done on 2026-10-17.* `szfriends-core::session` is the secure channel as a sans-IO state
machine and the chunk flow; `szfriends-core::store` the store. Checked by: `objc-session.json`, six sessions
between two real `SZFriendsSecureChannel` objects (XX request with codes, XX browsing, the IK callback carrying a
file across rekeys, NN Add by ID, two quiet refusals), which the Rust channel replays as either side byte for
byte, with every received byte also flipped in turn; `objc-store.json`, whose schemas (fresh, and the v1 fixture
migrated) the Rust store reproduces as SQLite prints them, with the fixture's data and search, folding, both
state machines over every state and event, and sanitised names; and `make friends-core-rs-interop-check`, the
Rust core against `tools/objc-session-peer` (the helper's own channel, chunk flow, identity, store, transfers and
Network.framework stream) on loopback, each in both directions: XX requests with matching codes, NN Add by ID
answered over IK with the token, 200 MiB with digest checks (about 2 s each way), 200 MiB resumed after a cut
with both sides rekeying every 16 MiB in step, a transfer moved to a faster route after its old session closed as
superseded, and 28 sessions per dialing side with one byte flipped in the preamble, the handshake, HELLO or a
message (55 of 56 refused with an error, one whose flipped length prefix promised bytes that never came waited
until closed; none delivered a tampered frame). Fuzzing, `make friends-core-rs-fuzz` with ten minutes per target,
1 h 0 min in all: 733 M executions of the frame decoder, 730 M of handshake payloads, 63 M of the stream reader,
5 M of a responder channel, 125 M of the chunk flow and 63 M of the JSON line reader, with no crash and no failed
invariant. The suites pass on macOS, in the Windows 11 VM (89 tests each for aarch64 and x86_64 MSVC) and in the
Ubuntu ARM64 VM (90 tests), the twelve helper-interop tests skipping in the VMs, which have no helper;
`friends-core-rs-cross-check` passes for every target, with the bundled SQLite compiled per target.

*The rest of wave 2, done on 2026-10-17.* The data-channel stack is merged from its spike branch; a `DataChannel`
now keeps its connection's handle, and no handle is released on the stack's own threads (a channel the remote
opens after its receiver was dropped goes to a reaper thread; `tests/lifetimes.rs`). The interop suite sends on a
closed session in a scenario of its own, which both peers refuse alike, and the tampering scenario counts a
refused send followed by the close as the refusal it is: `make friends-core-rs-interop-check` passed 10 runs of
10. The whole embedded core (`tools/embedded-size.sh`) is 4.50 MB on Android arm64 (2.08 MB deflated) and 2.59 MB
on iOS arm64, against 5 MB and 3 MB (ADR 0015 § 12); the stack's C and C++ build at `-O2` like the helper's, and
Windows MSVC builds link the C runtime statically. The universal helper: `make friends-helper-universal` joins an
arm64 and an x86_64 build (5.3 and 5.6 MB), and `make friends-universal-check` runs the x86_64 libsodium,
session, link-signalling, vector and online-stack suites under Rosetta. libsodium's x86_64 configuration uses the
x86 intrinsics and CPUID but not the unvendored assembly; AES-256-GCM needs AVX, which Rosetta reports only with
`ROSETTA_ADVERTISE_AVX=1`. The Android 16 emulator refuses hard links, so the file key store and received files
claim the name and rename over it there. The suites pass on the emulator and in the iOS 26.5 simulator (107 tests
each), the FTS5 trigram index included (bundled SQLite on Android, the system's on iOS), in the Windows 11 VM
(105 tests each for aarch64 and x86_64 MSVC, without the two Unix-only key-store tests) and in the Ubuntu ARM64
VM (107 tests). The Windows pipe rules wave 3's helper uses now also refuse AppContainer and lower-integrity
peers both ways, and a server that is not the lock's holder (ADR 0015 § 8).

## Wave 3: Presentation, IPC, desktop helper, and the phones' foundations

*The desktops, done on 2026-10-17.* Part A (presentation and intents, every snapshot fixture rebuilt) and part B
(the helper's lifecycle, socket and pipe, key stores and events, the pipe plan's cross-account cases) merged;
part C joined them: `szfriends-helper` serves the Friends service (identity and store, the views, the intents
through the core's parser, IK sessions between friends with the outbox's states and files with resume), and
`portable/friends/tauri` is `tauri-plugin-szfriends`, the Electron bridge's methods and rules in client mode
(the Rust helper on Windows and Linux, the Objective-C helper on a Mac, a team-signed app checking the helper's
signature) and embedded mode (in-process, the same frames). Until nearby discovery (wave 4) the Rust helper has
routes only in test homes (`$SZFRIENDS_TEST_LOOPBACK`, 127.0.0.1), and requests, Add by ID, links, devices and
search answer `unavailable`. PROTOCOL.md gained the other systems' rows. Shenzhen 3D's Tauri shell carries the
plugin behind a `friends` feature with a capability for the main window only. Checked: the workspace suites on
macOS, in the Windows 11 VM (219 tests each for aarch64 and x86_64 MSVC) and the Ubuntu VM (228), the service end
to end; the plugin's tests (validation over every intent example, routing, helper files, the link against the
helper's protocol server) and its guest script; the Tauri smoke, the real app with two real helpers in
temporary homes, a message both ways, a file accepted and opened in the viewer, a dropped file staged and
received whole, and a second window refused, in the Windows 11 VM (WebView2) and the Ubuntu VM (WebKitGTK) with
the Rust helper and on macOS with the Objective-C helper (naming, Nearby and a request accepted first); NSIS and
MSI with the helper and the animal set, a silent NSIS install over a running older helper that hands over to the
new build, deb, rpm and an AppImage whose helper runs from the per-user copy, outlives the app and exits on its
own; `cargo check` of the shell with and without Friends for macOS (both), Windows (both, in the VM), Linux
(aarch64, in the VM), Android's four ABIs and iOS; Shenzhen 3D's Electron and browser startup unchanged.
Left in wave 3: the phones (key stores, staged and received files, backups, the emulator and simulator runs;
their builds offer no Friends until then), the restored-store test and Start again, the remote-page check at
run time (the capability names no remote URL), the size check, and Linux x86_64 (no x86_64 WebKitGTK toolchain).

*The phones, wave 7 (2026-10-17, branch `friends/core-rs-phones`; Shenzhen 3D `friends-phones`).* The plugin's
embedded mode runs in Shenzhen 3D's Android and iOS builds (`tauri/src/phone/`, `tauri/android/`, `tauri/ios/`):
the Android Keystore-sealed key file in the no-backup directory and the iOS Keychain item (this device only), the
iOS state directory excluded from backups at every start (`dataExtractionRules` and backup rules on Android too),
a restored store without its key served as § 17's Start again, a 20-second grace period in the background before
the service pauses and its resume in the foreground, staged outgoing files and private received files with Open
and Share… (`files.share`; Save… or Share… on Android), the nearby permissions asked on `activate` with the
usage descriptions, a privacy manifest. Checked in an Android 16 arm64 emulator and the iOS 26.5 simulator: the
app and `loopback-peer` on the Mac exchange a message and a file each way (Shenzhen 3D's `phones-exchange.mjs`),
the page cannot call the platform halves, the Friends ID survives restarts, a store restored without its key
shows Start again and Start again makes a new ID, Save… writes the received file whole through the document
picker. Found on the way: Apple's system SQLite will not open a cleanly closed WAL store read-only
(`Store::identity_of` now falls back to read-write). Size: what Friends adds to Shenzhen 3D's arm64 library is
over the 5 MB budget: 5.28 MB with Friends' crates at opt-level "z" ("s" for the ciphers) and thin LTO (x86_64
6.59 MB before those settings); the core's own 4.50 MB is measured with `panic = "abort"`, which the app does
not use. Left: a real phone, Android 11 and earlier, iPad,
the iOS share sheet's choices, `bmgr` (the local transport refused the debug app's backup), and the size.

*The desktops' review fixes, 2026-10-17.* friends/m1 merged (Shenzhen 3D named through `{apps}`, computer-neutral
copy; the Rust catalog follows and its parity test lists every difference). Dropped files on the desktops go from
their paths: the plugin hears the system's report of each drop (WebView2's files handed over with
`postMessageWithAdditionalObjects`, WebKitGTK's `drag-data-received`, the drag pasteboard) and the page asks by
name and size (`drop_paths`); only phones stage bytes, up to 250 MB a file, refused before reading. Windows paths
a page names are drive-letter paths only (no share, so no NTLM sign-in to a server a page chooses). Linux's Show
in Files calls `FileManager1.ShowItems` over the helper's D-Bus client. The plugin reads no
`$SZFRIENDS_STATE_DIR` (a test home comes through `Config::state_dir`, honoured in debug builds and with
`test-homes`), and a spawned helper is told only of a test home. The helper words times in the computer's time
zone and reads a client's executable for a handover check in 64 KiB chunks, once per file and mtime. Test homes
no longer stay behind (194 left in the Windows guest's `%TEMP%` were removed): peers and services close their
stores first, `Scratch` waits for its helpers, removal is retried, and the VM runs keep temporary homes in their
own directory and fail on one left; `SZFRIENDS_REQUIRE_SYSTEM_TESTS=1` in the Linux run makes `linux_system`'s
skips failures, and all six of its tests run there. `friends-protocol-check` skips `fixtures/vectors/`, and the
containment scan skips Cargo's output. Shenzhen 3D gained File ▸ Copy Download Link in its Tauri menu and a Mac
Tauri package with the Objective-C helper in `Contents/Helpers` and its keys in the app's `Info.plist`. Checked:
the workspace on macOS (219 tests), in the Windows 11 VM (223 each for aarch64 and x86_64 MSVC, no home left), the
Ubuntu VM and the iOS 26.5 simulator (219); the cross-check; the interop check; `friends-tests` with coturn; the
plugin's tests and guest script; Shenzhen 3D's vitest, Electron and Electron Friends smoke; the Tauri smoke in the
Ubuntu VM and, from the package, on macOS.

## Wave 4: Nearby, permissions, firewalls

*Nearby on the desktops, and the phones' side, 2026-10-17 (friends/core-rs).* `szfriends-core::nearby` ports ADR
0004's pure parts (TXT, presence and callback tags with their four slots, the merger, the racer, visibility,
admission, the listen decision of § 15, Android's resolve queue, the Bluetooth presence value, checked against
`objc-bluetooth.json`); the store gained requests, their events and lifetimes, and Add by ID. The helper's `nearby/`
adapters: LAN over mdns-sd (Linux) or Windows' DNS-SD API with listeners only where the firewall already admits them
(rules scoped to a service, a package or a user do not count), outbound first, and the Nearby line; Bluetooth over
BlueZ (`bluetooth` feature, off by default), a phone's radio, or none on Windows, with `nearby.bluetooth` announced
only where there is one; sessions over TCP or platform streams. `service/nearby/` runs hidden listeners per window,
visibility, friend requests both ways, Add by ID with callbacks (an unattested answer becomes a request the asker
accepts), stranger limits and admission. The plugin's Kotlin (`NsdManager`, one resolve at a time before 14; BLE with
L2CAP from Android 10) and Swift (`NWListener`, `NWBrowser`, `NWConnection` with peer-to-peer Wi-Fi; CoreBluetooth)
are installed into the core by `src/nearby.rs`; they ask for Bluetooth only when the core powers it up, on
`activate`, and Nearby on a phone names Settings. Test homes get test networks only: a directory of entries on
127.0.0.1, the system's DNS-SD on loopback with a test type, and a test air for Bluetooth. Checked: the workspace on
macOS (305 tests), the vectors and the cross-check; Rust and Objective-C helpers finding, asking, declining and
messaging each other, Add by ID both ways and files (`objc_nearby`, 6, beside `objc_interop`'s 14); a Rust helper
inside the Windows 11 VM and the Ubuntu VM against the Mac's Objective-C helper through `szfriends-testnet`'s bridge
(`vm_nearby`, 6 each), a PC whose firewall admits nothing reaching the Mac by its own dial with its 275 inbound rules
unchanged; mdns-sd on Linux in a network namespace; Windows' DNS-SD API on the VM's network; two helpers with
Bluetooth alone over the test air; the `bluetooth` feature built and tested in the Ubuntu VM (its hardware test
ignored); the suites in the Ubuntu VM (321 tests) and the Windows 11 VM (308 for each of aarch64 and x86_64 MSVC, no
home left behind); the plugin checked for Android and iOS, its Kotlin compiled against Tauri's Android library and
its Swift type-checked against Tauri's iOS API. Left: host check-in (wave 5), so Add by ID answers stay unattested
and a PC that cannot listen completes Add by ID only once online; Bluetooth on radios (the hardware matrix) and
against the Objective-C helper's radio, which has no test air; Android and iPhone on one network with the others,
which needs the phones' in-process service and a phone build of the app; firewalld's `public` zone in the Ubuntu VM
(a blocked listener was simulated instead); a transfer across a suspended and resumed VM.

## Wave 5: Online

Checked (macOS, loopback): `friends-core-rs-online-check`, where the Rust core and the helper's own check-in
client and online driver (`tools/objc-session-peer` in its online mode) reach each other through the local Node
host and coturn at `max-bps=625000`, each side offering, direct (about 600 Mbit/s) and relayed (3.3 to 4 Mbit/s),
a message each way and a file in an ADR 0001 session; two Rust cores the same way; a link the Rust core serves,
downloaded by the helper's opener directly and through the relay; and two Rust helpers' services, friends with no
other route, exchanging messages and a file directly and relayed. `friends-core-rs-nat-check`: the punching
matrix's 28 pairs with `tools/nat-peer` as the offerer, then as the answerer (port prediction, birthday probing
and the relay where each pair requires them). The link page in Chromium downloaded a 3 MiB file from the Rust core
(`examples/link_page`), its SHA-256 matching. Open items: the Rust host client speaks `ws://` on loopback only, so
a person's own home stays offline until it speaks `wss://` with the pinned host keys; PCP, NAT-PMP and UPnP
mappings and TCP simultaneous open are not built yet (the loopback suites never ask a router); `to.join`
forwarding and Add by ID over the host (NN) are not wired; the helper serves no download links yet (making one,
tombstones, end reasons); host candidates on VPN and tunnel interfaces are not filtered; in one matrix run of four
(a slow one) the Rust offerer behind a sequential symmetric NAT asked for the relay but had no stream in time; the
VM, simulator and emulator runs of this wave's suites are still to do (the cross-check passes).

*Nearby and online together, 2026-10-17 (`friends/core-rs-dc` merged into `friends/core-rs`).* The helper's
service keeps nearby's sessions, race and dialing, and makes every stream online opens one more session in them
(`service/online.rs`, a `LinkStream` over the data channel): the friends-only responder, IK on the side that
offered. One order holds across both, `szfriends-wire::route::rank`: direct on the same network, peer to peer
(direct Wi-Fi, then a direct Internet connection), Bluetooth, the relay. Nearby dials a friend only on a route
better than the session carrying them; online is asked only while that session ranks after a direct Internet
connection, and the session race keeps the better of the two. The test homes' presence secret is the store's
one. `tests/route_order.rs` (in `friends-core-rs-online-check`) shows it end to end: online direct first, then a
shared test network takes over; the relay first, then Bluetooth takes over; online direct first, and Bluetooth
in range changes nothing. Checked: the workspace on macOS (337 tests), the online check with the local host and
coturn, the interop check five times (its 20 tests each time), the cross-check; the suites in the Ubuntu
VM (354) and the Windows 11 VM (341 for x86_64 MSVC); Shenzhen 3D's Tauri smoke in both VMs and its Electron
Friends smoke. Left: on Windows on Arm (aarch64 MSVC) `szfriends-online`'s `driver_loopback` passes, then its
process crashes on exit (0xc0000005) in 8 runs of 10, while the native stack's threads are still running;
calling libdatachannel's `rtcCleanup` first hung on macOS, so that is not the fix. Shenzhen 3D's
`scripts/friends/tauri-vm.sh` must copy `ext/` (libdatachannel, libjuice, usrsctp, plog, mbedtls) into the guest
now that the helper builds the online stack, and its `tauri-smoke.mjs` peer must send `activate`, as an app's
panel does, since a helper starts nearby only then.

*The wave 4–5 review fixes, 2026-10-17.* The crash at exit is gone: every handle of the data-channel stack is counted
until its delete returns, and `szfriends_datachannel_sys::shutdown` (run by `atexit`, before the C runtime destroys
the stack's globals) refuses new connections, waits for the count, joins the release thread and calls `rtcCleanup`;
`Online::stop` drops every connection on its thread and joins it. Before, `driver_loopback` crashed at exit 3 times
in 20 in the Ubuntu VM (a glibc invalid free, segmentation faults); after, 0 in 20 on macOS, in the Ubuntu VM and in
the Windows 11 VM for aarch64 and x86_64 MSVC. Also: the firewall's listen decision is read again before every
hidden listener and at every set-up (network changes, waking); a finished download link lets go of its setup,
connection and connection id, and candidates held for the relay are capped; on a Mac the Tauri plugin reads the drag
pasteboard only for a drag it saw over its own window (`drag_over`), and `stage` refuses an oversized body before
copying it; the link pages name the sender, not their Mac, and offer Shenzhen 3D on Windows, Linux, iPhone, iPad and
Android; the online responder admits IK only from the friend the signalling named, and people changes refresh whom
online may reach. The remaining online gaps are wired: `wss://` (TLS 1.2 on the stack's Mbed TLS, the server checked
against the system's CA files on Linux and Android and by the system's verifier on Windows and Apple systems), so a
person's own home checks in with the bundled list and shows the Friends ID the host reserved; download links made
and served by the Rust helper (`make_download_link`, `revoke_link`, tombstones, `end` `expired` and `changed`);
Add by ID over the host (NN, the token callback online); joining over `to.join`. Phones: Friends added 9.24 MB to
Shenzhen 3D's Android arm64 library with online (it was 5.28 MB before online came to the helper); the stack's C
and C++ at `-Os` on phones saves 0.1 MB, leaving online out of the phones (the helper's `online` feature, which the
Tauri plugin enables only through its own `online` feature) brings it to 6.26 MB, and declaring Friends' capability
statically in the app instead of `Manager::add_capability` (which links Tauri's capability parser, regex and URL
patterns) to 4.13 MB, within the 5 MB budget; that last step is Shenzhen 3D's. Checked: the workspace on macOS
(364 tests), in the Ubuntu VM (380) and the Windows 11 VM (367 for each of aarch64 and x86_64 MSVC, through
cmd.exe), in the iOS 26.5 simulator (363); the interop check (16 and 8), the online check with the local host and
coturn (7, then the helpers' suite with Add by ID, joining and a download link opened by the Objective-C helper's
opener, and the route order), the NAT matrix both ways, the vectors, the cross-check, the link pages' and host's
node tests, the Tauri plugin's. Left: `wss://` against the production host and the system verifiers on Windows and
Apple systems are untested here (loopback only; a test CA is checked by Mbed TLS); the helper announces `links`
only once friend links come over (`open_link`, `add_from_link`, `receive_link`, `reset_friend_link` still answer
`unavailable`), so apps do not offer Copy Download Link against it yet; Add by ID and joining over the host were
checked between Rust helpers only, not against the Objective-C helper; phones stay nearby only until online fits
their budget.

## Wave 6: Devices and sync

*Done on 2026-10-17 on loopback* (branch `friends/core-rs-sync`). `szfriends-identity` has the device chain
(ADR 0012) and joining (ADR 0013); `szfriends-core` the store's chains and sync tables and the sync engine
(ADR 0014): capture, the merge rules, tombstones, a removed computer's coverage and the purge of its late events
with the values they wrote worked out again, secrets after a removal, file copies (25 MB by themselves, larger on
Get) and the SYNC exchange. Checked by `objc-chain.json` (every chain decoded and rebuilt byte for byte, every
mutation refused with the helper's error, a whole join run with fixed scalars) and `objc-sync.json` (one store
state captured by both engines into the same eleven signed events and the same HELLO); by two Rust devices in
memory and over TCP; and by `make friends-core-rs-interop-check` (16 of 16): an Objective-C device and a Rust device,
the helper approving and the Rust core joining and the other way round, a friend and history synced both ways,
a chat erased on one and gone on the other, and the second computer removed, which learns it. The Rust helper's
Your computers, join rows and `join` view read the real chain, sync and join state, and their intents act on it;
it announces `devices` in test homes only, since nearby and online (waves 4 and 5) carry joining and sync in a
person's own home. `friends-core-rs-cross-check` passes for every target, and the new fuzz targets
(`device_chain`, `join_message`, `sync_message`) ran a minute each clean (27 M, 0.4 M and 5.3 M executions).
Left: the join and sync legs over those routes, a full hour of fuzzing, and the suites in the VMs and simulators.

*Joining and sync over the routes, 2026-10-17 (`friends/core-rs-sync` and `friends/core-rs-phones` merged into
`friends/core-rs`).* The helper announces `devices` in every home. A new computer joins over nearby
(`service/nearby/join.rs`): its request and each code go over NN sessions to every device it cannot recognise, as Add
by ID's do, once per presence window and once per code; every device answers a request alike (RECEIVED, unless it
ended that very request), only a device holding an approval answers a code with more, a code nobody answers within 10
seconds reads as not reached. Our devices find each other by tags from the own-devices secret in the first callback
slot (`service/nearby/own.rs`), and one that has not learned the secret probes with IK; the key policy admits our
devices with IK only; a non-first device advertises the friend tag of its own key; the session sends the chain first,
then the SYNC exchange, one per pair (the lower key's opening stays); changes are captured 0.3 seconds after any
change while such a session is live, and what another device changed brings the matcher, sessions and outbox up to
date. Online carries the same sessions with our other devices where the helper is online, the device whose key sorts
first asking. The phones' embedded mode serves this service, not the stub, beside nearby's platform halves (the
nearby Swift plugin under its own entry point, one Android library; Bluetooth and the local network asked once, when
the core first powers them up on `activate`). Checked: the workspace on macOS (356 tests), two services joining and
syncing over a test network with a wrong code first, a friend and their messages reaching the other computer
(`tests/devices.rs`), Rust helpers joining each other (`helpers_nearby`), the Objective-C helper and a Rust helper
each joining the other's profile over loopback Bonjour and syncing names both ways (`objc_nearby`, 8 of 8, beside
`objc_interop`'s 16), two computers joined nearby then restarted without a test network syncing through the local
host and coturn (`online`), the vectors, the cross-check, the plugin for Android and iOS (its Kotlin compiled offline
against Tauri's Android library, its Swift built by the iOS build), the suites in the Ubuntu VM (372) and the Windows
11 VM (359 for each of x86_64 and aarch64 MSVC, run through cmd.exe since the guest's PowerShell hangs; the sync
suite now removes its homes there, and the service suite no longer lets two tests share a test network, seen once in
the Ubuntu VM; `windows_pipe`'s squatter test timed out once while both VMs ran, then passed). Left: joining online
(`to.join` opens are not wired in the Rust driver), so a new computer joins only nearby; a Rust device checks in
under its own key, not for the person (HOST-PROTOCOL.md § Devices), so the Objective-C helper's other devices, which
look its records up under the root, do not reach it online, and a reach made before the other device checked in waits
out the driver's 30-second backoff; friends' chains (CHAIN between friends, `+Chain.m`) and friends' other devices
(`+FriendDevices.m`) are not kept, so a Rust friend does not reach a person's second computer; a removed computer is
told only on a live session (`+Removed.m`'s tags for removed devices are not ported); and erasing history through
sync (`delete_history` still answers `unavailable`).

*Links, Delete history and the phones' words, 2026-10-17 (`friends/core-rs`).* The Rust helper announces `links`
wherever online is set up and answers every link intent: `open_link`'s card, `add_from_mention` and `add_from_link`
(a request bound to the named key by its token, the link's invite proven on REQUEST_BY_ID nearby and online, accepted
at once by the link's maker, 20 a day through the standing link), `reset_friend_link`, Your links, and
`receive_link`, which opens the link as the page does, through a guest connection of its own to the host
(`/v1?guest=1`; the online crate is left as it is), direct then relayed, carrying on after a dropped connection, and
files the file with the person who signed it. A request bound to a key needs no host attestation on either helper
(the Mac helper's inbound rule follows), which is what let a Rust maker's acceptance make a friend on the Mac.
`delete_history` deletes on every computer of the profile through sync, or in the store alone on a computer of its
own. Words about a friend's device no longer say computer ("Delivered to Mei"), in both catalogs. A Mac reads a
drag's files only for the window its drop landed on, without the 30-second window. The Linux guest builds without
incremental state and from a vendored crate directory (`$SZFRIENDS_VM_VENDOR`); the Windows run uses cmd.exe only.
Checked: the workspace on macOS, two Rust helpers online (links and Delete history), and against the Objective-C
helper (`tests/objc_links.rs`, run by `friends-core-rs-online-check` with the links e2e helper, which allows
loopback): friend links and download links both ways, and the Mac helper's Add by ID reaching a Rust holder online,
which needs the Mac helper's nearby coordinator running (a test home gets a test service type for it). Left: the Rust
helper keeps no host attestation of its own Friends ID, so its answer to an unbound Add by ID still reaches a Mac as
a request to accept (the attestation arrives in the check-in welcome, which `szfriends-online`'s client does not yet
pass on).

*Online across implementations, 2026-10-17.* Every computer checks in for the person (HOST-PROTOCOL.md § Devices):
the root key and, once the profile has two computers, the chain, so the host files each computer's records under
the root and turns away a removed one; a chain that changes (a computer joined, renamed or removed, this one joined)
checks in again; only the first computer draws a new Friends ID after a collision; a computer the host turns away
(`device_revoked`, close 4002) knows it was removed and never checks in again. Friends' chains (`+Chain.m`): ours on
every session with a friend (once a request is accepted on it too) and before a first request or answer from a
computer that is not the first, theirs kept when it verifies from the root we pinned, an Add by ID answered by a
second computer moved to the person; the store finds a friend from any of their authorized computers. Friends'
other computers (`+FriendDevices.m`): matched by their own tags, dialed with IK to the static key the chain gives
them, admitted as that friend, reached online under the friend's root. Removed computers (`+Removed.m`): matched by
the tags they still advertise under every own-devices secret we held, dialed or let in by IK only to be sent the
chain, then closed. Bluetooth is on in the desktop helper (`bluetooth` among the default features, compiling
nothing off Linux), with libdbus built from libdbus-sys's own sources and linked statically, so a build needs no
libdbus headers; it builds without a warning in the Ubuntu VM. Phones: `tools/embedded-size` now links the helper's
service as the Tauri plugin's embedded mode runs it, and the workspace has a `phone` profile (opt-level z, fat LTO;
the data-channel stack's C and C++ at -Oz on phones). Measured with it: Android arm64 5.52 MB with online (2.74 MB
deflated) and 3.02 MB nearby only (1.62 MB deflated); iOS arm64 3.17 MB with online and 1.59 MB nearby only. With
the release profile the same builds were 6.54 MB (2.93 MB deflated), 3.73 MB, 4.71 MB and 2.64 MB. So iOS can ship
online within the 5 MB budget, and Android only within the 3 MB deflated one: its library stays 0.52 MB over 5 MB
(SQLite bundled, about 0.35 MB; libc++ linked statically for the stack, 0.45 MB; Mbed TLS 0.25 MB; usrsctp 0.23 MB),
so online stays behind the plugin's `online` feature for the owner to decide; an app turns it on with that feature
and the `phone` profile's settings in its own release profile. Desktop helper on Linux aarch64 (release profile,
stripped): 8.28 MB with online and Bluetooth, 6.90 MB with online only, 5.53 MB with Bluetooth only, 6.77 MB with
both under the `phone` profile: over ADR 0015 § 12's 6 MB since online came to the helper. Checked: the workspace
on macOS (373 tests), in the Ubuntu VM (389, from vendored crates) and the Windows 11 VM through cmd.exe (376 for
x86_64 MSVC, 372 for aarch64, whose `windows_pipe` squatter test timed out once and then passed 4 of 4), in an
iOS 26.5 simulator (372) and on an Android 16 emulator (372), each made for the run and deleted after; the interop
check (16 and 8); the online check with the local host and coturn (11, the four whole-helper scenarios with the
Objective-C helper among them; then the helpers' suite with a removed computer turned away by the host, and the
route order); `tests/friend_devices.rs` 12 times in a row; the cross-check, Linux with Bluetooth included; the
vectors; clippy. Left: the Objective-C helper reconsiders whom to reach (online friends, Add by ID online) only
with a nearby adapter, so its online tests give it a test Bonjour type nobody else uses; a computer that joined
does not yet release the Friends ID it reserved for itself before joining (`releasePreJoinIDThenStart`); a
friend's other computer is looked up online under the root, where only the newest record of the person shows.

## Wave 7: Release readiness

*Attestations, the pre-join release, locked app builds and the sizes, 2026-10-19 (`friends/core-rs`).* The Rust
helper keeps the host's attestation of its Friends ID: the check-in client takes it from the welcome and from
`reserve_result` (`szfriends-online::host::attestation`, checked against the host's own vectors in
`server/friends/test/vectors/host-list-v1.json`), keeps it only when it checks out for the person's key and the ID
reserved, and the helper stores it with the profile. An IK callback answering someone's Add by ID shows it beside the
certificate, nearby and online, so a plain Add by ID answered by a Rust helper reaches a Mac as a friend at once; an
answer to the Rust helper's own Add by ID that shows one for the ID asked for confirms the holder (a friend at once),
and one showing another key's attestation is refused. A computer that joins a profile releases the Friends ID it had
reserved for itself (`host::release`, the Mac helper's `releasePreJoinIDThenStart` and its sync state key): the first
connection after joining, and the first at each start while the release is owed, sends the signed release with the
computer's own key before checking in for the person; a confirmed release clears it. `tauri-plugin-szfriends`'s
`tools/host-build.sh` makes an app's Friends-build lock file from the pin (the app's versions kept, Friends' crates
added), checks it before a release and vendors the app's Friends build, the core's workspace and the plugin's own in
one `cargo vendor --locked` pass, each on a copy of the app's package with the patch in the copy's manifest, so no
lock file changes and none gains `[[patch.unused]]`; with a copy of Shenzhen 3D's `src-tauri` the lock added 54
packages and moved none, and `vendor` wrote 553 crates. Sizes: the data-channel stack's Mbed TLS keeps only what DTLS
and the host connection use (`mbedtls_trim.h`), its C carries no unwind tables and libdatachannel no logging, phones
leave out the hard-NAT prober, and `phone.toml` (which `.cargo/config.toml` repeats for the helper and the suites)
gives the bundled SQLite's flags. The embedded core with online: Android arm64 5.62 to 4.95 MB (2.48 MB deflated),
nearby only 2.82 MB; iOS arm64 2.97 and 1.62 MB, all within 5 MB. The Linux aarch64 helper (stripped, in the Ubuntu
VM): 7.62 MB as it ships (release profile, online and Bluetooth; 8.28 MB before), 6.11 MB under the `phone` profile,
6.24 MB with online only, 5.20 MB with online only under the `phone` profile: within 6 MB only that last way. Launch:
`mac-launch-performance-tests` (5 rounds, the empty launch measured again to 20) against 26.10.11-1 with the Mac under
load (load average 9 to 15): main-thread CPU before the first frame 1.027x with Friends on and 1.028x with Friends
off, no main-thread sample before the first frame in Friends code, Friends attach 1.7 ms after the first paint, the
helper started 79 ms into the launch and connected in every launch. Before the first paint Friends only reads its
setting and queues the helper's start on a background queue, and Friends off costs the same, so nothing was moved.
Checked: the workspace on macOS (392 tests), the interop check (16 and 8), the online check with the local host and
coturn (11, then `objc_links` 6 with plain Add by ID both ways, then the helpers' suite with the release reaching
the host, and the route order), `friends-datachannel-rs-check`, the cross-check, `friends-suite` with coturn, the
plugin's tests (33) and guest script (6); the suites in the Ubuntu VM (408, from vendored crates) and the Windows 11
VM (395 each for aarch64 and x86_64 MSVC; x86_64's `helper_process` and `windows_pipe` failed once while
`friends-suite` loaded the Mac, then passed alone). Left: the key policy cannot see an answer's attestation, so it
gives an Add by ID's third answer slot, the one kept for an attested holder, to nobody; the desktop helper is over
6 MB as it ships (the `phone` profile without Bluetooth fits); the phone suites were not run on an emulator or a
simulator this time; Shenzhen 3D adopting the Friends-build lock and `phone.toml` is Shenzhen 3D's change.

