# Friends portable core (Rust)

The Friends protocols and view contract implemented again in Rust, for Shenzhen 3D's Windows, Linux, Android and iOS
builds and any later host off the Mac. [ADR 0015](../docs/adr/0015-portable-core.md) is the decision;
[friends-portable-core.md](../../docs/plans/friends-portable-core.md) the plan and its waves. On a Mac, Friends stays
the Objective-C helper in `../service/`.

- `szfriends-wire`: frames and field rules, handshake payloads, preamble and prologue, the length-prefixed stream,
  route rank and the session race. Mirrors `service/session/SZFriendsFrame*.m`, `SZFriendsHandshakePayload.m`.
- `szfriends-crypto`: Noise (snow with a checked X25519), comparison codes, presence tags, CPace and join tags,
  invite proofs. Mirrors `szfriends_noise_*.c`, `SZFriendsSecureChannel+Code.m`, `SZFriendsPresence.m`,
  `SZFriendsCPace.m`, `SZFriendsJoinWire.m`.
- `szfriends-identity`: identity keys, certificate, signature domains, the 133-byte secret item, key-store rules,
  Friends IDs, REQUEST_BY_ID. Mirrors `service/identity/` and `SZFriendsRequestByID.m`. And (wave 6) the device chain
  (`chain/`: links, canonical order, the rules, merges, builders; ADR 0012) and joining (`join/`: the request, codes,
  the approver's rows and limits, the CPace run, the welcome; ADR 0013).
- `szfriends-contract`: PROTOCOL.md framing, ids and socket paths. Mirrors `client/szfriends_framing.c` and
  `szfriends_paths.c`.
- `szfriends-core`: state paths (wave 1); the session area (wave 2): the sans-IO secure channel with the helper's
  payload rules, key-policy and admission hooks, replay cache, quiet refusals, handshake bound, timers and comparison
  codes, and the chunk flow. Mirrors `service/session/SZFriendsSecureChannel*.m`, `SZFriendsReplayCache.m`,
  `SZFriendsChunkFlow.m`. And the store (wave 2): rusqlite with the helper's schema v1 to v9 byte for byte, its
  migrations, pragmas and backups, the trigram search index, people and history, the outbox, and transfers with
  staging, durable progress, digest checks, publishing and crash recovery; it records the identity key it was made
  for. Mirrors `service/store/`. Wave 6 adds the store's device chains and sync tables (`store/devices.rs`,
  `store/sync_*.rs`) and `sync/`: signed events, capture, the merge rules, tombstones, what a removed computer still
  counts for, secrets after a removal, file copies and the SYNC exchange (ADR 0014; `service/sync/`). Later areas
  arrive wave by wave, each mirroring its `service/` area.
- `szfriends-helper`: the Windows and Linux helper (`service/helper/`): single instance by lock, the PROTOCOL.md
  server over a Unix socket (peer uid checked both ways) or a named pipe (ADR 0015 § 8's checks), exit after the last
  client, handover by build, the versioned per-user copy and `--handover` (§ 14), the Secret Service (with a 0600
  file where none runs) and DPAPI key stores, sleep, wake and network events (§ 16), and the client an app's bridge
  uses. `service/` is the Friends service behind the server: identity and store, the views built by
  `szfriends-core`'s presentation, the intents read by its parser, and IK sessions between friends carrying messages
  and files through the outbox. `nearby/` finds people nearby (ADR 0004): the LAN adapter over mdns-sd (Linux),
  Windows' DNS-SD API with listeners only where the firewall admits them, or a phone's own DNS-SD; the Bluetooth
  adapter over BlueZ (`bluetooth` feature, on in the desktop helper, with libdbus built from source), a phone's radio,
  or none (Windows); and test networks for test homes only (`$SZFRIENDS_TEST_LOOPBACK`, a directory of entries on
  127.0.0.1; `$SZFRIENDS_TEST_SERVICE_TYPE`, the system's DNS-SD on loopback; `$SZFRIENDS_TEST_BLUETOOTH`, a test air
  of files and loopback channels).
  `service/nearby/` runs ADR 0004's merger, racer, hidden listeners, visibility, friend requests, Add by ID with
  its callbacks, and admission. Online runs only in test homes whose `$SZFRIENDS_TEST_HOST_LIST` and
  `$SZFRIENDS_TEST_HOST_KEYS` name loopback hosts (`service/online.rs`). A friend is reached direct, then
  peer-to-peer, then over Bluetooth, then through the server. Nothing starts before `activate` or, once the person
  was asked, launch. Your computers, the join rows and the join view come from the chain, sync and the join state
  (`service/devices.rs`); a new computer joins over nearby NN sessions (`service/nearby/join.rs`) or through the host
  (`join_online.rs`), and our devices find each other by their own tags and sync over IK, nearby or online
  (`service/nearby/own.rs`); Delete history reaches them too. Friends get our chain on every session and theirs is
  kept (`service/nearby/chain.rs`, a chain before a first request included), so a friend's other computers are found
  by their own tags and reached nearby and online (`friend_devices.rs`), and a computer we removed while it was away
  is told so when it comes back (`removed.rs`). Online, every computer checks in for the person (the root key and the
  chain), so the person's records are filed under the root and the host turns away a removed computer, which then
  knows it was removed. Links (`links` while online is set up): Add from a mention or a friend link, whose request
  carries the link's invite and is accepted at once by its maker (`service/friend_links.rs`), download links made and
  served (`service/links.rs`), and download links received through a guest connection of their own to the host, as
  the link page opens them (`service/link_open/`, `service/link_receive.rs`). Search answers `unavailable`.
  `tests/service.rs` runs two services end to end, `tests/nearby.rs` and `tests/bluetooth.rs` two services finding and
  asking each other, `tests/devices.rs` a computer joining another's profile and syncing with it (a friend and their
  messages included), `tests/online.rs` two services through the local host (two computers of one profile too, and
  links between them), `tests/friend_devices.rs` a friend reaching a person's second computer and a removed computer
  told so;
  `examples/befriend` makes two test homes friends. `tests/vm/` holds the pipe test plan's cross-account cases
  (`windows-pipe-plan.sh`) and the 6 MB size check (`helper-size.sh`).
- `szfriends-helper-sys`: the Win32 calls the helper needs (byte lock, named pipe, token facts, DPAPI, power and
  network notifications) behind a safe interface; empty elsewhere.
- `szfriends-datachannel-sys`: the helper's pinned WebRTC data-channel stack (libdatachannel, libjuice, usrsctp,
  Mbed TLS from `ext/`) built with `cc`, and a safe interface over it. Mirrors `deps/datachannel.mk` and
  `service/online/transport/`; its README records the wave 2 spike (targets, sizes).
- `szfriends-online` (wave 5): friends over the Internet. The host protocol 3 client (check-in for the person with
  their device chain, the signed host list,
  rendezvous records and lookups, signalling, relay credentials, link registrations) over a loopback-only `ws://`
  WebSocket; IK and NN signalling sessions, signal items and sealed rendezvous records; the online order with its
  direct phase and the relay as a second peer connection; STUN, the two-port classifier, port prediction and the
  birthday prober; the transport over `szfriends-datachannel-sys` under the helper's candidate, description and
  fingerprint rules; download links served to the link page in a browser. Mirrors `service/online/` and
  `service/links/`. `resources/` holds copies of `../service/host/resources/` (a test checks they are the same).
- `szfriends-vectors`: the test-only loader for `../fixtures/vectors/`.
- `szfriends-interop`: test-only. A Rust peer (the core on loopback TCP) and the Objective-C peer
  (`tools/objc-session-peer`, the helper's own session, store and transfer code) driven by the same JSON commands, a
  proxy that cuts routes and flips bytes, and the scenarios between any two peers: requests, Add by ID, files with
  resume and rekeys, tampering, and one person's two devices (approve, join with the code, sync both ways, an erased
  chat, a removal). Rust against Rust runs everywhere; Rust against the helper on a Mac. Nearby: Rust helpers and the
  Objective-C helper find, ask and message each other on test networks, and each joins the other's profile and syncs
  with it (`tests/objc_nearby.rs`, `src/nearby_devices.rs`), and through `szfriends-testnet`'s bridge with a Rust helper
  inside the Windows and Ubuntu VMs (`tools/run-vm-nearby.sh`, `tests/vm_nearby.rs`). Online, the local Node host and
  coturn (`src/host.rs`) and the online scenarios, whole helpers included: a Rust helper and the Objective-C helper
  with nothing nearby join each other's profile through the host and sync online, and add each other by ID through it
  (`src/online_devices.rs`, `tests/online_interop.rs`); `examples/link_page` serves a link for a browser.
- `tools/nat-peer/`: test-only. The Rust core as one side of the NAT emulator's punching matrix (`szfnat-rust-peer`).
- `../tauri/`: `tauri-plugin-szfriends` (its own workspace, so this one builds without Tauri): the Friends bridge for
  Tauri apps, in client mode on desktops and embedded mode on phones (ADR 0015 § 4).
- `fuzz/`: cargo-fuzz targets for every decoder a peer or a client feeds, its own workspace, seeded with the helper's
  frame corpus (`../service/thumbnails/fuzz/corpus/frame`, which `szfriends-wire`'s suite also replays).
- `tools/embedded-size/`: not shipped. The helper's service behind its protocol server, as the Tauri plugin's embedded
  mode runs it, behind one exported function, so `tools/embedded-size.sh` can measure all of it as a phone links it.
- `.cargo/config.toml`: Windows MSVC builds link the C runtime statically (`+crt-static`), so the helper needs no
  Visual C++ redistributable.

## Building and testing

From `portable/`:

- `make friends-core-rs-check`: `cargo test --workspace --locked` with the target directory in the build tree.
- `make friends-vectors-check`: rebuilds `tools/objc-vectors` from the helper's own sources and fails when the
  exported vectors differ from `../fixtures/vectors/`. Part of `friends-suite`; needs no Rust.
- `make friends-vectors-export`: writes the vectors after a deliberate change; commit them with the change, then run
  `friends-core-rs-check`.
- `make friends-core-rs-interop-check`: builds `tools/objc-session-peer` from the helper's service objects and runs
  the interop scenarios against it in both directions, 200 MiB transfers and the device scenarios included.
- `make friends-core-rs-fuzz`: every cargo-fuzz target for `FRIENDS_FUZZ_SECONDS` (default 600) on rustup's stable
  toolchain without a sanitizer (safe Rust: panics and failed invariants are the findings); corpus and crashes go to
  the build tree. Needs `cargo install cargo-fuzz`.
- `make friends-core-rs-cross-check`: `cargo check` of every crate and test for Windows (MSVC, GNU), Linux, Android's
  four ABIs and iOS, and of `szfriends-wire` and `szfriends-contract` for wasm32 (rustup's stable toolchain). The
  bundled SQLite is compiled for each target with the NDK's clang, `zig cc` (`tools/zig-cc.sh`) or MinGW; the MSVC
  targets check against a linked SQLite, since a Mac has no MSVC headers, and build the bundled one in the Windows VM.
- `make friends-core-rs-online-check`: the Rust core and the helper's check-in client and online driver through the
  local Node host (`../server/friends`, `npm ci` there first) and coturn (`FRIENDS_TEST_COTURN`) at `max-bps=625000`,
  direct and relayed, each side offering; two Rust cores; a Rust link downloaded by the helper's opener; then two Rust
  helpers' services. Loopback only.
- `make friends-core-rs-nat-check`: the NAT emulator's matrix with `tools/nat-peer` as the offerer, then the answerer.
- `make friends-datachannel-rs-check`: the datachannel crate's suite with a Rust peer talking to the helper's own
  online transport over 127.0.0.1, each side offering once (macOS).
- `tools/datachannel-sizes.sh [target ...]`: what the data-channel stack adds to a stripped release binary on each
  target, the VMs included.
- `tools/embedded-size.sh`: the service as a phone app ships it (`tools/embedded-size`, an Android `.so` and an iOS
  static library linked into a stub executable), with online and nearby only, built with the workspace's `phone`
  profile (opt-level z, fat LTO) and `phone.toml` (the bundled SQLite's flags, which an app passes for its phone
  builds; `.cargo/config.toml` gives the helper and the suites the same), against the 5 MB budget (3 MB deflated
  for Android). On phones the hard-NAT prober is left out (a friend behind a hard NAT is reached through the relay);
  everywhere the data-channel stack's Mbed TLS keeps only what DTLS and the host connection use
  (`szfriends-datachannel-sys/src/mbedtls_trim.h`), its C carries no unwind tables, and neither libdatachannel's
  logging nor Mbed TLS's and usrsctp's debug messages are compiled in (on phones not libjuice's either). Android
  libraries are linked with packed relocations (`phone.toml`).
- `tools/run-device-tests.sh ios-sim <UDID>` or `android [serial]`: the same suites in a booted iOS simulator or on an
  Android emulator or device.
- `tools/run-device-tests.sh windows-vm` or `linux-vm` (`make friends-core-rs-vm-check` runs both): the suites built
  and run inside the running Windows 11 and Ubuntu Parallels VMs, from a temporary copy that is removed afterwards.
  The script header lists what each guest needs.

Formatting is `cargo fmt` at 120 columns (`rustfmt.toml`); `cargo clippy --workspace --all-targets` stays clean.
No test reaches a real keychain, credential store, Keystore or any network beyond loopback.

## Firewalls on Linux

The helper never changes firewall settings (ADR 0015 § 15). With firewalld's `public` zone (Fedora Server, RHEL)
mDNS is admitted but the helper's listening ports are not: this computer finds people nearby and connects to them,
and nobody can connect to it. Between friends that is enough, since either side may dial. People nearby can see it
while it is visible but cannot send it a request; it can still send requests to them. Someone who wants to be
reachable on their own network can put that connection in a zone that admits TCP ports 1025 to 65535, as Fedora
Workstation's default zone does
(`nmcli connection modify <name> connection.zone FedoraWorkstation`). ufw (Ubuntu) is off by default; with it on,
the same holds, and `ufw allow proto tcp from <your network> to any port 1025:65535` admits people nearby.

## Rules

- A wire change lands in both implementations with regenerated vectors, or one of the two checks fails.
- No `unsafe` in these crates; platform bindings that need it live in their own crates with a narrow interface
  (today `szfriends-datachannel-sys` and `szfriends-helper-sys`; the test-only `tools/nat-peer` has one, adopting the
  emulator's descriptor 3).
- Debug output never prints keys, secrets or message contents: the types holding them implement `Debug` by hand.
- Files stay within 500 lines and 120 columns. Generated files are exempt, recorded here and in the plan's crate
  layout: `Cargo.lock` and `fuzz/Cargo.lock` (written by cargo) and every exported
  `../fixtures/vectors/objc-*.json` (written by the exporter, with hex values longer than a line; `objc-frames.json`,
  `objc-presence-race-code.json`, `objc-edge-cases.json`, `objc-session.json` and `objc-store.json` also exceed 500
  lines), and `crates/szfriends-online/resources/*.json` (copies of the helper's signed host list and pinned keys).
