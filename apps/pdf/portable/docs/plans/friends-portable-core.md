# Shenzhen Friends on every platform: the portable core

Status: waves 1 to 6 built and checked, wave 7 (release readiness) under way; what each wave built, how it was
checked and what it left is in the [progress log](friends-portable-core-progress.md), newest last. Owner: lead
integrator. Decision: [ADR 0015](../../friends/docs/adr/0015-portable-core.md). Code: `portable/friends/core-rs/`.
First host: Shenzhen 3D (`/Users/raph/Projects/3D-viewer`, `docs/PLATFORMS.md`), whose Mac app is integrating the
Objective-C helper in a parallel change; this plan brings Friends to its Windows, Linux, Android and iOS builds, and
keeps the door open for a Linux or Windows ShenzhenPDF and Shenzhen Files.

## What a person gets on each platform

| Platform | Friends in | Nearby routes | Online | Runs when |
|---|---|---|---|---|
| macOS | Electron and Tauri, shared helper | LAN, peer-to-peer Wi-Fi, Bluetooth | yes | an app with Friends is open |
| Windows 10+ | Tauri build, Rust helper | LAN, outbound first | yes | an app with Friends is open |
| Linux | Tauri build, Rust helper | LAN, Bluetooth (BlueZ) | yes | an app with Friends is open |
| Android 10+ | Tauri app, in-process | LAN, Bluetooth | yes | foreground |
| Android 7 to 9 | Tauri app, in-process | LAN (Bluetooth finds, does not carry) | yes | foreground |
| iOS, iPadOS 15+ | Tauri app, in-process | LAN, Wi-Fi peer to peer with Apple devices, Bluetooth | yes | foreground |
| Web, PWA | not offered | | | |

Online means friends over the Internet in the owner's order: a direct connection first, the relay (5 Mbit/s) last.
Everything else Friends does (requests, Add by ID, links, mentions, previews, devices, sync) is the same everywhere,
because the snapshots and intents are PROTOCOL.md's. Intel Macs depend on the universal helper of wave 2; until
it ships, the bridge there reports Friends unavailable (ADR 0015 § 2). A Windows PC without an inbound firewall
rule reaches nearby friends by dialling them (ADR 0015 § 15).

## Crate layout

```
portable/friends/core-rs/
  Cargo.toml              workspace; one curve25519-dalek, snow without ring
  .cargo/config.toml      Windows MSVC: the C runtime linked statically
  core-rs.mk              friends-vectors-check, friends-vectors-export, friends-core-rs-check,
                          friends-core-rs-cross-check, friends-core-rs-vm-check, friends-core-rs-interop-check,
                          friends-core-rs-fuzz, friends-datachannel-rs-check, friends-core-rs-online-check,
                          friends-core-rs-nat-check
  crates/
    szfriends-wire        frames, field rules, handshake payloads, preamble, stream framing, route rank   (wave 1)
    szfriends-crypto      Noise on snow + CheckedX25519, codes, presence tags, CPace, join tags, invites (wave 1)
    szfriends-identity    keys, certificate, domains, secret item, Friends IDs, key-store rules          (wave 1)
    szfriends-contract    PROTOCOL.md framing, ids, socket paths, Windows pipe rules; fixtures         (wave 1)
    szfriends-core        state and helper-copy paths (wave 1); session, store (wave 2); presentation, ipc, ...
    szfriends-helper      the Windows and Linux helper binary (version line in wave 1)
    szfriends-vectors     test-only loader for fixtures/vectors
    szfriends-interop     test-only: Rust and Objective-C peers on loopback, the proxy, the scenarios    (wave 2)
    szfriends-datachannel-sys   ext/'s libdatachannel stack built with cc, a safe interface (wave 2 spike)
    szfriends-online      host client, signalling, rendezvous, the online order, NAT techniques, links  (wave 5)
  fuzz/                   cargo-fuzz targets, seeded with the helper's frame corpus                      (wave 2)
  tools/objc-vectors/     the Objective-C exporter, linked against the helper's production sources
  tools/objc-session-peer/  the helper's session, store and transfers as the interop suites' other peer
  tools/objc-dc-peer/     the helper's online transport as the far end of the datachannel interop test
  tools/nat-peer/         the Rust core as either side of the NAT emulator's punching matrix                 (wave 5)
  tools/datachannel-sizes.sh   what the stack adds per target
  tools/embedded-size/, embedded-size.sh   the whole core as phones link it, measured against the budget
  tools/zig-cc.sh         a Linux C compiler for the cross-check's bundled SQLite
  tools/run-device-tests.sh, run-vm-tests.sh   the suites in the iOS simulator, on Android, in the VMs
portable/friends/fixtures/vectors/   objc-*.json, exported; never edited by hand
portable/friends/tauri/              tauri-plugin-szfriends and its guest script (wave 3)
```

Files stay within 500 lines and 120 columns. Generated files are exempt and listed here (and in the workspace
README): `Cargo.lock` and `fuzz/Cargo.lock` (written by cargo) and every `fixtures/vectors/objc-*.json` (written by
the exporter, with hex values longer than a line; `objc-frames.json`, `objc-presence-race-code.json`,
`objc-edge-cases.json`, `objc-session.json` and `objc-store.json` also exceed 500 lines), and
`crates/szfriends-online/resources/*.json` (copies of the helper's signed host list and pinned keys).

## Waves

Each wave ends with the Rust suites (on macOS, in the Windows 11 and Ubuntu VMs, and in the iOS simulator),
`friends-core-rs-cross-check`, `friends-vectors-check` and every existing Friends suite passing, a verifier pass,
and a commit. Nothing is pushed or released without the owner. Phone work is spread through waves 3 and 4 rather
than left to the end, so key stores, staging and permission flows are tested with the features that need them.
Section numbers (§) below are ADR 0015's decisions.

1. **Foundations** (done). Workspace and harness; wire codecs; identity, signatures, Friends IDs and key-store
   rules (a store without its key, or with another identity's key, is refused); Noise handshakes and transport with
   rekey; comparison codes; presence tags; CPace and join tags; invite proofs; contract framing, socket paths and the
   Windows pipe rules; helper copy paths; the Objective-C vector exporter with the Ed25519 and X25519 edge cases.
   *Done when*: the Rust codecs produce and accept exactly the helper's bytes for every frame type and every decoder
   case; Friends' XX, IK and NN handshakes, their transport frames and rekeys match byte for byte; cacophony's and
   snow's vectors pass; identities, all eight signature domains, REQUEST_BY_ID, CPace (draft B.3 and the join
   inputs) and Friends ID normalisation match; libsodium's accept or refuse on every Ed25519 and X25519 edge case
   matches; `friends-vectors-check` refuses a stale committed vector file; the suites pass on macOS, in the iOS
   simulator, in the Windows 11 VM (aarch64 and x86_64 MSVC) and in the Ubuntu ARM64 VM
   (`run-device-tests.sh windows-vm`, `linux-vm`); `friends-core-rs-cross-check` passes for Windows (MSVC and GNU),
   Linux (x86_64 and aarch64), four Android ABIs, iOS, and wasm32 (wire and contract). All of this passed on
   2026-10-16.
2. **Sessions, store, and the hard builds first.** The secure channel (preamble, per-message payload rules, key
   policy hooks, replay cache, refusal delay, handshake bound, admission, timers, comparison-code exchange), chunk
   flow (windows, PROGRESS, resume, migration), the store (rusqlite; ADR 0003 schema through the current version;
   outbox; the identity key recorded at creation), fuzzing of every decoder with the helper's corpus. Two spikes
   that could change the design, done first: *datachannel-sys*, the vendored libdatachannel, libjuice, usrsctp and
   Mbed TLS built with `cc` for `x86_64-pc-windows-msvc` (in the Windows VM), `aarch64-linux-android` and
   `aarch64-apple-ios`, a data channel between two Rust peers on loopback on each, and the stripped size per target
   (done 2026-10-16 for every target, with a Rust peer against the helper's transport in both directions; it adds
   1.45 to 2.17 MB, so str0m is not needed; results in the crate's README);
   *Intel Macs*, the helper built universal (libsodium's x86_64 configuration, `lipo`, the x86_64 suites run under
   Rosetta; done 2026-10-17, in the progress log). *Done when*: a Rust peer and an
   Objective-C peer (a small session-area harness) complete XX requests, IK and NN Add by ID in both directions on
   loopback, move 200 MiB with digest checks, resume after a cut and across a rekey, refuse a tampered byte
   anywhere; fuzzers run an hour clean; the store passes the helper's schema fixtures, and its FTS5 trigram test
   passes on macOS, Windows, Linux, the Android emulator and the iOS simulator (system SQLite there); the
   datachannel spike builds and connects on all three targets within the size estimate, or the str0m fallback is
   decided; the universal helper passes its suites on both architectures.
   Progress: the [progress log](friends-portable-core-progress.md), § Wave 2.

3. **Presentation, IPC, desktop helper, and the phones' foundations.** Snapshot builder and string catalog;
   intents; the helper process (Linux socket, Windows named pipe with the lock, the advertised name and the server
   and client checks of ADR 0015 § 8, connect-or-spawn, idle exit, handover); the per-user helper copy and
   `--handover` for installers and AppImages (§ 14); Secret Service and DPAPI key stores; on phones, the embedded
   mode, the Android Keystore and iOS Keychain stores, staged and received files, and the state directory excluded
   from backups (§ 17); `tauri-plugin-szfriends` with client and embedded modes, the `window.shenzhenFriends`
   bridge, Friends commands granted to the main window only, and dropped-file paths (§ 4); PROTOCOL.md gains the
   Windows row. *Done when*: every snapshot in `fixtures/snapshots` is reproduced as the same JSON value from the
   same store state; the React UI from Shenzhen 3D runs against the Rust helper in the Windows 11 and Ubuntu VMs,
   against the Objective-C helper from the Mac Tauri build, and in-process in the Android emulator and the iOS
   simulator; the pipe test plan of § 8 passes in the Windows VM (a squatting second account, a wrong owner, a
   second helper without the lock, a forged advertised name, a remote client); an NSIS update installs over a
   running helper without a restart prompt and an AppImage's helper survives the app quitting; a second window and
   a remote page cannot call Friends commands; the restored-store test of § 17 passes (`bmgr` on the emulator, the
   exclusion flag in the simulator) and the Start again view appears for a store without its key; key stores pass
   their rules with real stores on throwaway test accounts or simulators only; nothing runs before first paint
   (launch timing gate unchanged); binary size within budget.
   Progress: the [progress log](friends-portable-core-progress.md), § Wave 3.

4. **Nearby, permissions, firewalls.** LAN discovery and listeners (Windows DNS-SD API, mdns-sd on Linux,
   NsdManager on Android with its one-resolve queue, NWBrowser and NWListener on iOS with peer-to-peer), presence
   tags, the discovery merger, the route racer outbound first, hidden listeners and visibility; Bluetooth on iOS
   (CoreBluetooth), Android 10+ and Linux (BlueZ); permission flows and purpose strings on both phones (asked on
   `activate`, never at launch, the Nearby page explaining a refusal); the firewall rules of § 15 and the Nearby
   line on Windows; desktop power and network events (§ 16). *Done when*: a Mac on the Objective-C helper and each
   of Windows, Linux, an Android device and an iPhone find each other on one network and exchange messages and
   files; Bluetooth carries a session between a Mac and an iPhone, an Android 10+ phone and a Linux laptop
   (hardware matrix, like `discovery/hardware-matrix.md`); the firewall tests of § 15 pass in the VMs; a transfer
   resumes after each VM is suspended and resumed; no permission prompt appears before Friends is opened.
   Progress: the [progress log](friends-portable-core-progress.md), § Wave 4.

5. **Online.** `szfriends-datachannel-sys` for every target (from the wave 2 spike), rendezvous and host protocol 3,
   STUN, PCP and NAT-PMP, UPnP (miniupnpc), the direct phase, the relay as a second peer connection, route order.
   *Done when*: Rust and Objective-C helpers reach each other through the local Node host and coturn at
   `max-bps=625000`, direct and relayed, on loopback; the NAT emulator matrix passes with a Rust peer on either side;
   download links serve a browser from the Rust core.
   Progress: the [progress log](friends-portable-core-progress.md), § Wave 5.

6. **Devices and sync.** Device chain, joining (CPace over NN, the approver's code), sync events and anti-entropy.
   *Done when*: the end-to-end device scenarios pass with a Mac on the Objective-C helper and the Rust core as the
   other device, each side approving and joining.
   Progress: the [progress log](friends-portable-core-progress.md), § Wave 6.

7. **Release readiness.** Mobile lifecycle (foreground only, grace period, resume) on devices, size budgets
   enforced by a check, the independent security review of the Rust core and bridges, Android emulator and device
   runs, App Store and Play requirements (privacy manifests, store listings of the purpose strings). *Done when*:
   review findings are fixed or accepted by the owner; the 3D Android and iOS builds pass their device matrix with
   Friends on.

## Testing strategy

- **Shared vectors, exported from the helper.** `tools/objc-vectors` links the helper's own session, identity and
  discovery sources and libsodium, and writes `fixtures/vectors/objc-*.json`. Inputs are derived from labels, so the
  files are stable. `make friends-vectors-check` (in `friends-suite`, Objective-C only) regenerates them in the build
  tree and fails on any difference; `make friends-vectors-export` rewrites them; `make friends-core-rs-check` runs the
  Rust suites. Each later wave adds the vectors its area needs (session transcripts, snapshots, chain and sync
  encodings) to the same exporter.
- **Cross-implementation end to end, on loopback only.** The helper's e2e harness (`friends/tests/e2e`) gains a Rust
  peer: the same scenarios with one or both helpers replaced by `szfriends-helper`, through the local Node host
  (`portable/server/friends`) and a coturn built from pinned source (`FRIENDS_TEST_COTURN`), with the NAT emulator
  for the online matrix. Nothing reaches the production host.
- **Simulators and emulators.** `core-rs/tools/run-device-tests.sh` cross-compiles the test binaries and runs them
  inside an iOS simulator (`xcrun simctl spawn`; the simulator reads the tree in place) or on an Android emulator or
  device (`adb push` of the binaries and the fixtures, `SZFRIENDS_DIR` pointing at the copy). Tauri builds of
  Shenzhen 3D run the UI in both.
- **Windows and Linux.** `make friends-core-rs-cross-check` checks every crate and test for each target on the Mac.
  `run-device-tests.sh windows-vm` and `linux-vm` (`make friends-core-rs-vm-check`) copy the workspace into the
  running Parallels VMs (Windows 11 on Arm: aarch64 and x86_64 MSVC; Ubuntu 24.04 ARM64), build and test there, and
  remove the copy; later waves add the 3D Tauri app there. CI: the 3D repository's `build.yml` gains a Friends job
  per platform once the plugin exists.
- **Intel Macs.** `make friends-helper-universal` builds the helper for arm64 and x86_64 in build trees of their own
  and joins them; `make friends-universal-check` runs the x86_64 slice's libsodium, session, link-signalling,
  vector and online-stack suites under Rosetta and inspects both slices. Not part of `friends-suite` (it builds
  everything twice); run before a release that ships the universal helper.
- **Fuzzing.** `cargo fuzz` targets for the frame and field decoder, handshake payloads, the JSON line reader, and
  later the chain, join and sync decoders, seeded with the helper's libFuzzer corpus.
- **No real key stores in tests**: memory and file stores only, as on the Mac; the platform stores of wave 3 are
  exercised only in simulators, emulators and throwaway VM accounts.

## Decisions taken here (owner review pending)

- macOS stays on the Objective-C helper; the Rust core never runs as a Mac helper.
- Desktops run a helper process; phones run the core in-process.
- Windows IPC is a named pipe with a random advertised name, a user-only DACL and owner, a lock file for the single
  instance, and clients that check the server's user and the pipe's owner; Linux uses PROTOCOL.md's socket.
- Desktop apps spawn the helper from a versioned per-user copy; installers hand over through the protocol.
- No firewall prompts: Windows listens only when a rule or a disabled firewall admits it; routes work outbound
  first.
- Intel Macs get Friends through a universal Objective-C helper (wave 2).
- Friends state is excluded from phone backups; a store without its key, or with another identity's key, is a
  distinct state that only Start again resolves.
- Noise on `snow` with a checked X25519; CPace on curve25519-dalek; Ed25519 strict like libsodium.
- WebRTC on the same pinned libdatachannel stack as the helper, built with `cc`; str0m is the fallback.
- Peer-to-peer Wi-Fi only between Apple devices; no Bluetooth route on Windows; Bluetooth carries data on Android 10+.
- Phones: foreground only, no notifications of any kind, files staged as private copies, no storage permission.
- One identity per phone app (each is a device of the person's profile).
- The web build has no Friends.
- `friends-core-rs-check` joins `friends-suite` once release machines pin a Rust toolchain.

## Needs the owner

- The desktop helper is 7.62 MB on Linux aarch64 as it ships, over § 12's 6 MB: Bluetooth (BlueZ, tokio and a
  static libdbus) is about 1.4 MB of it and the `phone` profile's settings another 1.5 MB. Whether the helper drops
  Bluetooth, builds with those settings, or the budget moves is the owner's call.
- Phones can now ship online within 5 MB (Android 4.95 MB): whether Shenzhen 3D's phone builds turn on the plugin's
  `online` feature.
- The Windows 11 VM now has a user-level rustup (`%USERPROFILE%\.cargo`, stable 1.99.1, targets aarch64 and
  x86_64 MSVC; PATH unchanged), installed by this workflow from the official rustup-init. The Ubuntu VM has no
  Rust of its own: wave 1's run used the Shenzhen 3D build's toolchain under `/opt` read-only, as root
  (`SZFRIENDS_VM_AS_ROOT=1 SZFRIENDS_VM_TOOLCHAIN=…`); a user-level rustup there would let the suites run as the
  normal user. The Android AVDs `shenzhen_3d_test` and `agentmesh_api35` point at a missing android-35 system
  image; wave 2's emulator runs used a scratch AVD on the installed android-36 image, deleted afterwards.
- Comparing the x86_64 libsodium objects with configure's, as was done for arm64, needs the verified
  libsodium-1.0.22 release tree, which is not kept here: downloading it again is the owner's call.
  Wave 2 installed `cargo-fuzz` 0.13.2 on this Mac (`cargo install cargo-fuzz`, into `~/.cargo/bin`) for
  `friends-core-rs-fuzz`.
- Whether Shenzhen 3D's first release with Friends waits for the universal helper, or ships with Friends unavailable
  on Intel Macs.
- Whether long transfers on Android may use a foreground service, which Android requires to show a notification.
  The plan says no (transfers pause in the background and resume), in line with "no external notifications".
- When to pin a Rust toolchain on the release machines.
