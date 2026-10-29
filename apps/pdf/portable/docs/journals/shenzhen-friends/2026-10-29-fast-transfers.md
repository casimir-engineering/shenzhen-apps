# Shenzhen Friends: fast transfers, phase 1 — 2026-10-29

The owner asked for transfers over Bluetooth, direct Wi-Fi and the local network to run as fast as possible: several
streams, a hash on every chunk, every transfer resumable, several routes at once when useful, Bluetooth helping a slow
network without ever stalling a transfer when it drops, released apps still interoperating, encryption and privacy
unchanged. Phase 1 is measuring and design only; no product code changed.

Deliverables: [ADR 0018 Fast transfers](../../../friends/docs/adr/0018-fast-transfers.md) (the decision),
[PROTOCOL.md § Fast transfers](../../../friends/PROTOCOL.md#fast-transfers) (what apps see), and this journal (the
numbers, every idea weighed, the work packages).

## How it was measured

- **Machine.** Apple M5 Max, 18 cores, 64 GB, macOS 26 (Darwin 25.5), internal SSD. Everything on loopback, in
  temporary homes, with test identities derived from fixed seeds. No app or helper of the owner's was launched or
  touched, nothing reached the network, no production host was used.
- **Peers.** The interop crate's two session peers, as `make friends-core-rs-interop-check` uses them: the Rust core
  (`szfriends-interop`'s `RustPeer`: core session, chunk flow and store) and the helper's own Objective-C session,
  store and transfer code (`tools/objc-session-peer`, built by `make friends-session-peer`, `-O2` like the helper).
  Rust in the workspace's release profile (`opt-level = "s"`, thin LTO), as shipped on desktops. Both sides do
  everything a helper does for a file: stage a snapshot, hash it, offer, accept automatically, write, make progress
  durable, check the digest, publish, acknowledge.
- **Routes.** A shaping proxy between dialer and listener: a token-bucket rate per direction and a one-way delay,
  plus a cut (both sockets shut once N bytes passed) or silence (the proxy stops reading and writing, sockets left
  open, as a route that goes out of range looks to TCP). Profiles, chosen as plausible, not measured on hardware:

  | Route | Rate | RTT | Route class declared (sets chunk and window) |
  |---|---|---|---|
  | direct | loopback, no proxy | — | LAN |
  | loopback | proxy without limits | — | LAN |
  | LAN | 940 Mbit/s (1 GbE) | 2 ms | LAN |
  | direct Wi-Fi | 300 Mbit/s | 4 ms | peer-to-peer Wi-Fi |
  | internet | 50 Mbit/s | 40 ms | internet |
  | relay | 5 Mbit/s (the relay's cap) | 80 ms | relay |
  | Bluetooth | 1.4 Mbit/s (175 KB/s, LE 2M PHY in practice) | 30 ms | Bluetooth (4 KiB chunks, 256 KiB window) |

  No packet loss is emulated (loopback TCP never loses), so the internet figures are an upper bound.
- **Harness.** A test file in `szfriends-interop` (`tests/zz_fast_transfer_baseline.rs`) and a `route` option on the
  Rust peer's `dial` command (so the Rust side can declare Bluetooth, internet or relay); the Rust side always dials, so
  the declared class is the emulated route's. Both stayed uncommitted, as phase 1 commits documents only; WP5 turns them
  into `make friends-transfer-bench`. CPU is `ps` user plus system time of each process over the transfer; the Rust
  figure includes the proxy's threads except in the "direct" rows.

## Results

Times run from `send_files` to the receiver's published file; MB/s is 10^6 bytes per second; the percentage is of the
emulated rate.

| Case | Rust to Rust | Rust to Objective-C | Objective-C to Rust |
|---|---|---|---|
| Loopback, no proxy, 2 GiB | 16.37 s, 131.2 MB/s | 13.77 s, 156.0 MB/s | 13.18 s, 162.9 MB/s |
| Loopback, no proxy, 100 MiB | 0.78 s, 134.6 MB/s | 0.71 s, 147.4 MB/s | 0.72 s, 146.5 MB/s |
| Loopback, 1 MiB | 0.05 s, 20.3 MB/s | 0.19 s, 5.5 MB/s | 0.06 s, 17.9 MB/s |
| Loopback via proxy, 2 GiB | 15.62 s, 137.5 MB/s | 16.88 s, 127.2 MB/s | 13.63 s, 157.5 MB/s |
| Loopback, 300 × 10 KiB | 13.31 s, 0.2 MB/s | 14.33 s, 0.2 MB/s | 8.50 s, 0.4 MB/s |
| LAN, 1 MiB | 0.06 s, 16.8 MB/s (14 %) | 0.06 s, 16.9 MB/s (14 %) | 0.06 s, 16.3 MB/s (14 %) |
| LAN, 100 MiB | 1.31 s, 80.3 MB/s (68 %) | 1.30 s, 81.0 MB/s (69 %) | 1.09 s, 95.8 MB/s (82 %) |
| LAN, 300 × 10 KiB | 14.17 s | 13.01 s | 8.54 s |
| Direct Wi-Fi, 1 MiB | 0.08 s, 13.0 MB/s (35 %) | 0.21 s, 4.9 MB/s (13 %) | 0.09 s, 11.8 MB/s (31 %) |
| Direct Wi-Fi, 100 MiB | 3.15 s, 33.3 MB/s (89 %) | 3.14 s, 33.4 MB/s (89 %) | 3.01 s, 34.8 MB/s (93 %) |
| Internet, 1 MiB | 0.29 s, 3.7 MB/s (59 %) | 0.29 s, 3.6 MB/s (58 %) | 0.30 s, 3.5 MB/s (57 %) |
| Internet, 100 MiB | 17.21 s, 6.1 MB/s (97 %) | 17.20 s, 6.1 MB/s (98 %) | 17.07 s, 6.1 MB/s (98 %) |
| Internet, 300 × 10 KiB | 14.37 s | 8.75 s | 8.74 s |
| Relay, 1 MiB | 1.88 s (89 %) | 1.87 s (90 %) | 1.87 s (90 %) |
| Relay, 20 MiB | 33.83 s (99 %) | 33.83 s (99 %) | 33.81 s (99 %) |
| Bluetooth, 1 MiB | 6.30 s (95 %) | 6.18 s (97 %) | 6.18 s (97 %) |
| Bluetooth, 4 MiB | 24.39 s (98 %) | 24.39 s (98 %) | 24.39 s (98 %) |
| Bluetooth, 20 × 10 KiB | 1.33 s (88 %) | 1.32 s (89 %) | 1.32 s (89 %) |

100 MiB over the relay would take about 170 s and over Bluetooth about 10 min at these rates; the shorter runs already
show 99 % and 98 % efficiency, so they were not run. 2 GiB ran on loopback only.

**Preparing and CPU.**

| Case | Preparing (`send_files` until the offers are queued) | CPU, Rust process | CPU, Objective-C peer |
|---|---|---|---|
| 2 GiB, Rust to Rust | 2.60 s | 17.38 s (both sides) | — |
| 2 GiB, Rust to Objective-C | 2.55 s | 9.29 s (sending) | 7.93 s (receiving) |
| 2 GiB, Objective-C to Rust | 1.52 s | 8.10 s (receiving) | 5.25 s (sending) |
| 300 × 10 KiB, Rust to Rust | 8.72 s | 0.92 s | — |
| 300 × 10 KiB, Rust to Objective-C | 8.66 s | 0.51 s | 2.74 s |
| 300 × 10 KiB, Objective-C to Rust | 6.82 s | 0.48 s | 2.48 s |

Per GB: the Objective-C helper spends 2.4 CPU-s sending and 3.7 receiving; the Rust core about 4 per side.

**A route that goes away at 50 MiB of 100 MiB (LAN) or 2 MiB of 4 MiB (Bluetooth).**

| | Rust to Rust | Rust to Objective-C | Objective-C to Rust |
|---|---|---|---|
| Cut: noticed by the sender after | 0.50 s | 0.52 s | 0.42 s |
| Cut: resumed at (bytes on the wire at the cut 52.44 MB) | 48.05 MB | 47.74 MB | 47.98 MB |
| Cut: sent twice | 4.4 MB | 4.7 MB | 4.5 MB |
| Cut: from redial to resuming | 1 ms | 1 ms | 1 ms |
| Silence on LAN: noticed after | not within 45 s | not within 45 s | not within 45 s |
| Silence on Bluetooth: noticed after | not within 45 s | not within 45 s | not within 45 s |

In the silence cases the harness dialed a second route after 45 s; the transfer then resumed from the receiver's
durable count (52.35 MB, 2.07 MB) at once. Without that second route nothing would have moved until the operating
system declared the TCP connection dead (minutes of retransmission timeouts) or a better-ranked route's session won
the race; a route of the same or a worse rank never replaces it.

**Building blocks** (single core, this machine):

| | Throughput |
|---|---|
| libsodium 1.0.22 ChaCha20-Poly1305 (the helper's cipher), 4 KiB to 1 MiB messages | 0.77 to 0.80 GB/s |
| libsodium AES-256-GCM | 7.7 to 9.0 GB/s |
| libsodium AEGIS-128L / AEGIS-256 | 21 / 12.3 GB/s |
| libsodium BLAKE2b-256 (the content digest) | 1.5 GB/s |
| libsodium SHA-256 | 0.56 GB/s |
| RustCrypto `chacha20poly1305` 0.10.1, 60 KiB: `opt-level = "s"` (release today), 3, 3 with `chacha20_force_neon` | 0.225, 0.66, 0.93 GB/s |
| RustCrypto `aes-gcm` 0.10.3: `opt-level = "s"`, 3, 3 with `aes_armv8` and `polyval_armv8` | 0.17, 0.21, 1.7 GB/s |
| `blake2` 0.10, BLAKE2b-256 | 1.5 GB/s |
| Loopback TCP, one connection, 4 KiB / 64 KiB / 1 MiB writes | 2.0 / 13.8 / 17.0 GB/s |
| F_FULLFSYNC after a 4 MiB write / fsync / F_BARRIERFSYNC; F_FULLFSYNC after 10 KiB | 4.9 / 1.1 / 1.5 ms; 3.6 ms |

LibreSSL's `openssl speed` gave nonsense for AES-GCM on this machine (194 GB/s), so the AEAD figures come from a small
C program against the helper's own `libsodium.a` and a Rust one against the crates in the workspace's lock file.
BLAKE3 was not measured: no copy is on this machine and phase 1 downloads nothing; WP1 measures it (ADR 0018 § 2).

**Profiles** (`sample`, 4 s into a 2 GiB transfer on loopback). The Objective-C receiver's busy time is the cipher
(ChaCha20 and Poly1305), the F_FULLFSYNC every 4 MiB and BLAKE2b, all on one queue; the Objective-C sender's is the
cipher. The Rust process's hottest frames are stripped release code in the cipher's address range, consistent with the
225 MB/s measured above: every pair with the Rust core is capped by its cipher build, not by the wire.

## Limits found

1. **Cipher speed on the Rust side.** ChaCha20-Poly1305 at 225 MB/s per core in the release profile caps Windows,
   Linux and phones (phones build with `opt-level = "z"`, not measured here); with opt-level 3 and the NEON backend it
   is 0.93 GB/s. The AES backends are not compiled in (`aes_armv8`, `polyval_armv8`).
2. **One session, one queue.** One session per friend (ADR 0001's race), one route at a time; on each side one serial
   queue decrypts, parses, writes through the store queue (`performOnWriter`, synchronous, with a transfer row lookup
   per 60 KiB chunk in `SZFriendsTransferReceiver appendChunk`) and hashes; the sender reads with `NSFileHandle`
   seek and read per chunk, a new `NSData` each time, on the same queue. One transfer uses about one core per side.
3. **Chunk size.** 60 KiB (61,440 bytes) on LAN, direct Wi-Fi, internet and relay; 4 KiB on Bluetooth, chosen by the
   initiator's route class (`SZFriendsChunkBytesForRoute`, `chunk_bytes_for_route`). Overhead is small (18 bytes of
   length and tag per chunk); what the size costs is a message, allocation and write completion per 60 KiB.
4. **Round trips per chunk.** None: the sender keeps a window of 8 MiB (256 KiB on Bluetooth) in flight. But the window
   opens only on PROGRESS, and PROGRESS reports bytes made durable: the receiver commits every 4 MiB or 1 s, plus a
   0.5 s flush timer when chunks pause (`SZFriendsDurableBatchBytes`, `SZFriendsProgressFlushDelay`). Flow control
   therefore waits on F_FULLFSYNC (4.9 ms per batch, about 2.5 s per 2 GiB, serial with the rest). On Bluetooth the
   256 KiB window against a 1 s commit caps the rate near 256 KiB/s whatever the radio does.
5. **Write budget.** At most 4 × the stream's preferred write size handed to the link (256 KiB on TCP, 16 KiB on L2CAP,
   `inFlightBudget`), so messages overtake files; fine, but each write is one Noise message and one completion.
6. **Disk work per file.** Rust stages by copying the whole file and `sync_all` (F_FULLFSYNC), then reads it again for
   the digest (2.6 s per 2 GiB); the Objective-C helper clones (`fclonefileat`) and reads once (1.5 s). The receiver
   reads the whole file back before publishing (BLAKE2b, 1.4 s per 2 GiB; the security review requires a read-back).
   Each file costs F_FULLFSYNCs and transactions on both sides: 28 to 48 ms per small file, so 300 files of 10 KiB take
   8.5 to 14.3 s and 0.2 to 0.4 MB/s. The Objective-C peer also spends about 9 ms of CPU per small file.
7. **Fixed cost per file.** A 1 MiB file takes 50 to 60 ms on loopback (190 to 210 ms in two of the Objective-C
   receiver's runs, cause not identified yet; WP5 traces it), so small files never reach the link's speed.
8. **Resume.** From the contiguous durable prefix only, so up to a batch plus the window is sent again (4.4 to 4.7 MB
   measured); the whole-file digest is the only check, so a mismatch fails the transfer and Try again restarts from zero;
   the sender re-hashes the whole snapshot once per helper run before its first resume (`snapshotMatches`).
9. **No liveness.** PING exists in every minor and is ignored on receipt, but nothing sends it. The Objective-C TCP
   adapter enables keepalive after 30 s idle, which does not apply while bytes are queued; the Rust peers have none. A
   silent route stalls a transfer until the kernel gives up or a better route wins the race (measured: nothing in 45 s).
10. **Bluetooth never helps.** It carries traffic only while no Wi-Fi or Internet route works (`szfriends_wire::route`),
    and a session on it is replaced by any better one, so it cannot add to a slow network.
11. **Online buffering.** A data channel holds at most 1 MiB buffered (`SZFriendsOnlineChannelHighWater`, Rust
    `HIGH_WATER`), about 1 MiB per round trip: 26 MB/s at 40 ms, 7 MB/s at 150 ms. SCTP's own buffers and congestion
    module are libdatachannel's defaults.
12. **Sync copies and Get again.** Their WANT/PART exchanges keep 16 parts of 48 KiB ahead (768 KiB per round trip) and
    resume from an offset, with the whole-file digest as the only check.

## Ideas considered

| Idea | Decision | Why |
|---|---|---|
| Feature negotiation: session minor 4 plus capability bit 0 in the existing handshake | Adopted (ADR § 1) | released apps see nothing new; the bit is a switch back without a protocol change |
| Blocks of 1 MiB (up to 16 MiB) under a hash tree announced in OFFER, each checked on arrival | Adopted (§ 2, § 3) | corruption costs a block; blocks are the unit of resume and scheduling |
| BLAKE3 for the tree | Adopted, gated by WP1's phone measurement; else BLAKE2b with the same construction | SIMD in C and Rust, independent leaves on all cores |
| BLAKE3's own tree (Bao) | Not adopted | the C library hides subtree hashing |
| A Merkle proof with every block | Not adopted | leaves up front cost 32 bytes per MiB once and keep PART simple |
| Durable block map in sidecar files, WANT with missing ranges, HAVE for checked and durable blocks | Adopted (§ 4) | survives restarts, sleep and route changes; older helpers delete the sidecars, which is the safe outcome |
| A schema v13 table for the map | Not adopted | additive, but released helpers would leave stale rows claiming truncated blocks |
| Same blocks for SYNC copies and Get again, new messages inside SYNC and AGAIN | Adopted (§ 4) | one resume mechanism everywhere; messages and PROFILE are single idempotent frames already |
| Flow control on checked blocks, durability separate | Adopted (§ 3, § 4) | the window no longer waits on F_FULLFSYNC |
| Lanes: more IK sessions bound to the first by a token from its handshake hash | Adopted (§ 6) | parallel streams and multi-route with the same authentication; no change to the race for released peers |
| Earliest-completion scheduling by measured rate and RTT, 2 × BDP in flight per lane | Adopted (§ 7) | weights by speed, keeps the last blocks off slow lanes |
| Reassigning a closed lane's blocks at once; treating a lane silent for max(3 RTT, 1 s) as lost; endgame duplicates | Adopted (§ 7) | losing Bluetooth costs about 2 s of its share, never a stall |
| PING after 1 s of sending nothing during a transfer; close after 8 s of hearing nothing (12 s on Bluetooth), also against released peers | Adopted (§ 7) | fixes the measured 45 s+ stall for every pair |
| Bluetooth as an extra lane when the network is below 4 MB/s | Adopted (§ 7) | helps where it can matter; sessions and messages keep the route order |
| Our own congestion control (BBR, LEDBAT) on top of TCP and SCTP | Not adopted | it would fight the transport's; LEDBAT noted for background transfers |
| QUIC or another UDP transport of our own | Not adopted | a second network stack and review; lanes give most of it |
| MPTCP | Not adopted | one IP stack only, partial on macOS, absent on Windows and Android apps |
| Several lanes on one route | Adopted only when the computer is the limit; never on relay or Bluetooth | fairness to the person's other traffic; data channels share one SCTP congestion controller anyway |
| More than one relay lane | Not adopted | would multiply relay load and change what it sees |
| `pread` into a buffer pool, `F_RDADVISE`, in-place encryption, `writev` of several messages | Adopted (§ 9.1) | CPU per GB |
| Memory-mapped reads | Not adopted | little gain over `pread` for sequential reads; SIGBUS on I/O errors |
| Cloning snapshots everywhere (`clonefile`, `FICLONE`, `copy_file_range`, ReFS block clone); no fsync of a private snapshot | Adopted (§ 9.1) | Rust copies and fsyncs 2 GiB today (2.6 s) |
| opt-level 3 and NEON / ARMv8 AES backends for the crypto crates | Adopted now (§ 9.2) | 4× the cipher on the Rust side, no protocol change |
| AES-256-GCM lanes (`Noise_IK_25519_AESGCM_BLAKE2b`) where both have hardware AES | Adopted (WP6, capability bit 1) | 2.6× the cipher on arm64 in Rust, 10× in libsodium; second suite to review |
| AEGIS-128L | Not adopted | not a Noise cipher, no vectors |
| Batches: staging, transactions and one F_FULLFSYNC per batch; offers and replies back to back | Adopted (§ 9.3) | 300 small files from 8.5 to 14.3 s to under 1.5 s |
| One ACK frame for many files | Not adopted | an ACK is a 38-byte message, already pipelined |
| zstd per block when a sample saves 10 % | Adopted on Bluetooth and relay lanes (capability bit 2, WP6), relay parts padded to 8 KiB | STEP 5.2× and text 2.4× faster on Bluetooth; the relay learns only rough compressibility |
| Skipping files the receiver already has (same friend or own devices) | Adopted (WP1) | instant for a re-sent file; limited so a friend learns only that the person kept what they sent |
| Reusing matching blocks of an earlier version from the same friend | Adopted (WP1 by name, WP6 by a local index of that friend's files) | big for iterated CAD files |
| Content-defined chunking | Not adopted | finds shifted edits but breaks the fixed map and tree |
| Sending the whole file to each of a person's devices | Not adopted as such | multiplies the sender's upload |
| Multi-source pulls: the person's devices fetch blocks from each other and from the friend | Adopted (WP6: the planner; wiring into the requesters left) | each block crosses the sender's link about once |
| Apple peer-to-peer Wi-Fi beside the LAN | Kept, AWDL lane beside LAN only below 25 MB/s (WP3 measures) | AWDL time-slices the same radio |
| Wi-Fi Aware (iPhone, Android) | Noted for later | a direct route between phones; out of scope here |
| Bluetooth: 16 KiB parts, 64 KiB write budget, Android high priority and 2M PHY, BlueZ the same | Adopted (§ 9.8) | 0.25 % overhead instead of 1 %, a quarter of the writes |
| Data channels 8 MiB buffered, usrsctp buffers raised, H-TCP where the NAT emulator shows a gain | Adopted, measured first (§ 9.9) | 1 MiB per round trip caps long paths |
| Forward error correction on internet paths | Not adopted | much code for what extra lanes mostly give |
| Preallocating the declared size | Adopted (§ 8) | locality, and a sparse partial cannot grow past what was accepted |
| "Finishing…" while a large file's final check runs | Adopted (PROTOCOL.md) | the person sees why it is not saved yet |

## Work packages

Five packages that separate agents can build at once, against ADR 0018 and the vectors WP1 writes first, plus a later
sixth. Each package keeps `make -C portable friends-suite`, `friends-core-rs-check` and
`friends-core-rs-interop-check` passing and, once WP5's bench exists, records before and after numbers here. Rules for
every agent: no launching, quitting or stopping the owner's apps or helper; test identities and loopback or local test
hosts only; no `pkill`, `killall`, `osascript`, `sudo`; no `rm -rf` and no `rm` with variables, `$(...)` or globs.

**WP1. Core chunking, hashing and resume (Rust core; vectors for both).**
- `szfriends-wire`: frame types 28 to 31, fields 37 to 46, capability bits 0 to 2, CLOSE reason 6, `SESSION_MINOR` 4,
  codecs and limits (ranges, leaf counts, part sizes) with fuzz targets.
- `szfriends-core/src/transfer/`: block geometry, the tree (BLAKE3 or the BLAKE2b fallback after measuring both on the
  slowest supported phone), range sets, the receiver's block assembly and checks, the two sidecar formats, durability
  batches, the publish read-back computing tree and BLAKE2b in one pass, unclean-exit re-check.
- `store/`: cloned snapshots without fsync, staging and publishing in batches, preallocation, recovery sweeps that keep
  named sidecars, skipping files already held (same friend or own devices).
- First deliverable, before any code: `friends/fixtures/vectors/transfer/` written from the ADR, which WP4's exporter
  must then reproduce byte for byte.
- Done when: vectors pass in Rust; a Rust-to-Rust 2 GiB transfer on one lane resumes after a cut with at most one block
  sent twice; a corrupted block is fetched again alone; 300 small files under 1.5 s on loopback.

**WP2. The multi-route scheduler (sans-IO, Rust core, with a simulator).**
- `szfriends-core/src/transfer/scheduler.rs`: per-lane rate and RTT estimators, earliest-completion assignment, the
  in-flight targets, closed and silent lanes, endgame duplicates, the Bluetooth rule, the § 3 limits; inputs (lane up,
  lane down, HAVE, write completed, bytes heard, timer) and outputs (send these parts on that lane, duplicate, close lane,
  want a lane on this route).
- A virtual-time simulator with lane profiles (rate, RTT, outages, silence, flapping) and property tests: no block lost,
  limits never exceeded, a silent lane never delays completion by more than its detection time.
- Hands the Objective-C port (WP4) a written pseudo-code and the simulator's scenario table as JSON, so both are judged
  by the same scenarios.

**WP3. Per-route transports and lanes (Rust helper and online).**
- Session area: the Lane payload field and token, the responder's checks, groups in the service's session table
  (lanes exempt from the race), PING liveness and silence rules on every session, released peers included.
- LAN and direct Wi-Fi lanes (TCP), the Bluetooth lane (BlueZ; phones through the plugin), test airs; online lanes as
  more data channels, 8 MiB buffering, usrsctp buffers and congestion module measured with the NAT emulator.
- Bluetooth part size, write budget, Android priority and PHY; `writev` batching; the crypto build flags (opt-level 3 and
  backends) checked by `tools/embedded-size.sh` against the phone budget.

**WP4. Objective-C helper parity.**
- `service/session/`: minor 4, frames and fields, the Lane field, CLOSE reason 6, PING liveness.
- `service/transfer/` (new): tree over BLAKE3 vendored by `friends/deps` (or BLAKE2b per WP1), block assembly, sidecars,
  the scheduler ported from WP2's pseudo-code and checked against its scenario table.
- `service/store/`: batches, preallocation, sweeps; `helper/nearby/`: one group of links per friend's device instead of
  one link; `discovery/`: Network.framework and CoreBluetooth lanes, AWDL lane rule; `online/`: more data channels and
  buffers.
- `tools/objc-vectors`: exports the transfer vectors (must equal WP1's); `tools/objc-session-peer`: lane and block
  commands for the interop crate.
- Bumps the helper build number (YYMMDDBB in `helper.mk`); adds the two catalog strings of PROTOCOL.md § Fast
  transfers (`estimate.network_and_bluetooth`, `transfer.finishing`), to the Rust presentation too.

**WP5. Interoperability and route-loss tests.**
- Make the phase 1 harness permanent: the shaping proxy (rate, delay, cut, silence, flapping, one direction or both)
  in `szfriends-interop`, the Rust peer's `route` option, `make friends-transfer-bench` writing JSON lines.
- Released peers: session peers built from tags `pdf/26.10.29-1` and `files/26.10.29-1` (Objective-C) and
  `3d/preview-0.2.4` (Rust), in their own worktrees, and the old-versus-new matrix of ADR 0018 § Verification for every
  platform pair the runners reach (Mac, the existing Windows and Linux runners via `tools/run-device-tests.sh`, phones).
- Route-loss scenarios of § Verification, written first against today's code so the silent-route stall is a failing
  test that WP3 and WP4 turn green.
- Hardware runs when the owner provides devices: two Macs over Wi-Fi, AWDL and Bluetooth; a Mac and a phone; raw L2CAP
  rate per pair for the Bluetooth target.

**WP6, after WP1 to WP5.** AES-GCM lanes (capability bit 1) if CPU still matters; block reuse from earlier versions;
multi-source pulls across the person's devices and the friend.

**Order.** WP1 writes the vectors and frame codecs first (day one); WP2 and WP5's harness start at once, independent of
it; WP3 and WP4 build against the ADR and the vectors in parallel; integration meets in WP5's matrix. Merges follow the
usual feature-branch-then-main flow, one package per branch.

## Open points for the owner

- BLAKE3 is a new dependency in both helpers (vendored C, pinned crate); WP1's measurement decides it against BLAKE2b.
- zstd for Bluetooth compression is a second new dependency; it can wait for WP6 if one dependency at a time is
  preferred.
- Hardware for the speed targets: which two Macs, which phones, and a network where a 1 GbE and a Wi-Fi run can be
  repeated.
- The default of `transfers.fast` in the first release that carries it: on, once the matrix passes, or off for one
  release with a test switch.

## WP3: the cipher build, liveness and disk work (Rust core and helper)

Measured on the same Mac with `make friends-transfer-bench` (WP5) and `examples/transport-speed` (szfriends-crypto),
while other packages built in parallel: load averages around 7, so single runs of the same case vary by up to 30 %;
CPU seconds per GB and the silence timings are steadier than MB/s.

**1. The ciphers at full speed** (ADR 0018 § 9.2). The release and phone profiles build the ciphers and hashes at
opt-level 3 (snow, szfriends-crypto and the generic RustCrypto crates too: a generic cipher's code is generated in
the crate that instantiates it, so the cipher crates alone gave 740 MB/s, and szfriends-crypto made the rest), and
arm64 builds pass `--cfg chacha20_force_neon`, `aes_armv8` and `polyval_armv8` from a `cfg(target_arch = "aarch64")`
section of `.cargo/config.toml` (Windows and Linux helpers: `setup-tauri-friends.mjs` passes that file) and
`phone.toml` (Android and iOS: `platform-build.mjs` passes it). A cfg section because cargo joins it with the
`CARGO_TARGET_<TRIPLE>_RUSTFLAGS` the Tauri CLI sets for Android (checked: chacha20's rustc line carries both).
Shenzhen 3D's `phones-profile.toml` follows. `tests/build_flags.rs` checks both files agree and the build had them.

| Session transport, one core, 60 KiB frames | Encrypt | Decrypt |
|---|---|---|
| Release profile before (opt-level "s") | 537 MB/s | 543 MB/s |
| opt-level 3 only, no NEON | 591 MB/s | 598 MB/s |
| Now (opt-level 3 and NEON), release and phone profiles alike | 883 MB/s | 923 MB/s |

The phase 1 figure of 225 MB/s came from the bare crate without LTO; through the session transport, with thin LTO,
the release build already gave 537. Android embedded size with online: 5.100 MB before, 5.118 MB after (+17 KB); main
was already 0.1 MB over ADR 0015's 5 MB budget, which this package does not fix. iOS 3.10 MB, nearby only 1.76 and
2.99 MB.

**2. Liveness** (ADR 0018 § 7). While a transfer runs on a session, the channel sends PING after a second without
sending, and closes the session (`SessionError::Silent`, no CLOSE) after 8 s without hearing a byte, 12 s when the
initiator declared Bluetooth; the helper redials and resumes as after a cut. Watching follows
`transfer_liveness()`: only while the peer owes something it sends anyway (PROGRESS for unconfirmed bytes, the rest
of a file whose chunks are arriving), so a released peer is judged by its own traffic, never during an offer's wait,
before a released sender's first chunk (it may hash first) or between DONE and ACK. A gap over 2 s between timer
runs is this side's own stall and restarts the count.

| Route silenced mid-transfer (the proxy stops forwarding, sockets open) | Before | Now |
|---|---|---|
| LAN, 100 MiB, Rust → Rust / Rust → Objective-C / Objective-C → Rust | not noticed in 45 s | 8.00 / 7.98 / 8.00 s |
| Bluetooth, 4 MiB, the same three pairs | not noticed in 45 s | 11.91 / 11.89 / 11.92 s |

Recovery (redial to moving again) follows within 0.03 to 0.08 s; 0.2 MB sent twice. In Objective-C → Rust the Rust
receiver notices a sender that never pings, which is the released-peer case. The Objective-C helper (WP4) still
needs the same rule for Objective-C → Objective-C.

**3. Disk work** (ADR 0018 § 9.1). Snapshots are cloned (`fclonefileat`, `FICLONE`; `copy_file_range` or a copy
otherwise) and not flushed, as the Objective-C helper already does; the sender opens a snapshot once and reads each
chunk at its offset into one buffer. `store/disk.rs` also has the two halves of a durability batch for WP1's block
map: `order_writes` (a plain `fsync` on Apple systems, `fdatasync` elsewhere) and `make_durable` (`F_FULLFSYNC`,
`fsync`), so a batch costs one full flush, not two. The CHUNK path keeps a full flush per 4 MiB batch, because
PROGRESS there means durable and released senders resume from it; the window stops waiting on the disk only on fast
sessions (WP1's HAVE).

| Rust sender | Before | Now |
|---|---|---|
| Preparing 2 GiB to send | 2.61 to 2.75 s | 1.58 to 1.63 s (the Objective-C helper: 1.50 to 1.54 s) |
| Preparing 300 × 10 KiB | 8.7 s | 3.9 to 7.4 s (per-file transactions remain: WP1's batches) |
| Loopback 2 GiB, Rust → Rust | 137.6 MB/s, 3.7 + 3.2 CPU-s/GB | 159.9 MB/s, 3.0 + 3.1 CPU-s/GB |
| LAN (1 GbE emulated) 2 GiB, Rust → Rust | 72.9 MB/s, 62 % | 76.4 MB/s, 65 % |

What remains per byte is one serial loop per side (decrypt, parse, write, PROGRESS); lanes (below) are what will put a
transfer on several cores.

**4. Lanes, first part** (ADR 0018 § 6). `session/lanes.rs`: a `LaneGroup` per first session with one device, without
IO. It gives an outbound lane its index and token, admits an inbound lane whose token names a free index (compared in
constant time against all fifteen), keeps the limits (4 lanes per route and 8 per group opened by this side; one
session of the group on the relay and on Bluetooth, the first included), ends with the first session, and names the
lane for control frames (route order, then lowest index). The scheduler's side of it: `LaneEvent::Up { lane, index,
route }` and `Down { lane }` in, `LaneRequest::Open { route }` and `Close { lane }` out; the driver dials, admits and
closes. Tokens are passed in (`transfer::lane_token`, WP1), so the group builds before WP1's wire work lands.

Not done in this package, in order: the Lane field in IK message 1 and the responder's check (CLOSE reason 6 after
the handshake, so a refusal stays quiet before it), on WP1's payload field; groups in the helper's session table
(lanes exempt from the race, control frames on the group's control lane); LAN and direct Wi-Fi lanes (a second TCP
connection to the endpoint the first session used), the test air's and BlueZ's L2CAP lane; online lanes as more data
channels with 8 MiB buffering and usrsctp's buffers raised (the bench's internet route is a TCP proxy, so this needs a
data-channel run with delay first); the AWDL rule and Bluetooth's 16 KiB parts. Each lane runs its own cipher state,
so with lanes the cipher figures above become per lane, not per transfer.

## WP1: negotiation, blocks, the tree and resume in the Rust core (2026-10-29)

**BLAKE3 against BLAKE2b (ADR 0018 § 2), measured first.** One core, 1 MiB leaves with the tree's 26-byte prefix,
release builds, three interleaved runs each, on the M5 Max:

| | BLAKE3 (`blake3` 1.8.5, NEON) | BLAKE2b-256, `blake2` crate | BLAKE2b-256, libsodium (the helper's) | Ratio |
|---|---|---|---|---|
| arm64, native | 2.22 to 2.30 GiB/s | 1.45 to 1.49 GiB/s | 1.34 to 1.51 GiB/s | 1.53× (crate), 1.52 to 1.66× (libsodium) |
| x86_64, Rosetta 2 | 2.09 GiB/s | 1.05 GiB/s | 0.49 GiB/s | 2.0× (crate), 4.3× (libsodium) |

The opt-levels the core ships (`s` on desktops, `z` on phones) give the same arm64 numbers (2.27 and 2.30 GiB/s), since
BLAKE3's NEON code is C. x86_64 is emulated here: indicative only, and real AVX2 and AVX-512 machines are faster still
for BLAKE3. **Decision: BLAKE3 is adopted** (at least 1.5× on both architectures, as the rule asked); the arm64 margin
is thin, so the slowest supported phone is still to be measured with `core-rs/tools/tree-hash-bench.sh android
[serial]` when the owner's phone is connected, and the vectors stay as written unless that run falls under 1.5×.
Hashing a whole 1 GiB file (in the page cache) on every core with its BLAKE2b digest in the same pass: 0.93 s
(1.16 GB/s, 18 cores), bound by the one-thread BLAKE2b digest, not by the tree.

**What landed** (`portable/friends/core-rs`):

- `szfriends-wire`: session minor 4; frames HASHES, WANT, PART and HAVE (28 to 31); fields 37 to 46 with their limits
  (whole leaves, whole ranges, at most 2,000 leaves and 8,000 ranges per field, parts up to 61,440 bytes); capability
  bits 0 to 2; CLOSE reason 6; the Lane payload field; `ranges` (ascending, disjoint, non-empty).
- Negotiation in the channel: `fast_transfers()` when the negotiated minor is 4 or more and both handshakes set bit 0.
  The channel itself refuses to send a minor-4 frame to a peer without them and strips the tree's fields from an OFFER
  (so a released app never sees one even if a caller forgets), and closes on one received outside such a session. The
  helper sets the bit unless a test home sets `SZFRIENDS_TEST_FAST_TRANSFERS=0` (playing a released helper); the
  `transfers.fast` settings key is not wired yet.
- `szfriends-core/src/transfer/`: geometry (an empty file is one empty block, so every file has a tree), the tree with
  the read-back hashing tree and digest in one pass on every core, block sets, both sidecar formats, the receiver's
  assembly (nothing before checked leaves, at most 64 blocks and 64 MiB partly received, each block checked as it
  completes, a bad one dropped and wanted alone), the sender's side (serves WANTed blocks in order within a window,
  checks each block against its own leaf as it reads it), the frame helpers, and the SYNC 7/8 and AGAIN 4/5 messages
  and the lane token.
- `store/blocks.rs`: the map written at OFFER (so an acceptance after a restart still goes by blocks), blocks written
  at their offsets, durability batches every 8 MiB or second (blocks, then bitmap, then one full sync), the durable
  prefix kept in `verified_bytes` for older helpers, every block a map claims re-read and checked when a download
  reopens, a CHUNK prefix turned into blocks once the leaves arrive (and reported at once in a HAVE), the publish check
  (tree and digest in one pass through the descriptor that wrote the file), the sender's tree beside its snapshot,
  and recovery sweeps that keep the sidecars of open transfers and delete the rest.
- The Rust helper: OFFER carries the tree on a fast session; the receiver answers with Blocks; the sender sends the
  leaves and, at a first acceptance, every block; HAVE as blocks check and become durable; ACK after the publish check;
  WANT with exactly the missing blocks on every new session; a corrupt block wanted again alone; a changed snapshot
  fails the transfer before a byte of the changed block leaves. One session per friend: lanes are WP3, the scheduler
  WP2.
- Vectors, written from the ADR (`friends/fixtures/vectors/transfer/`): trees and leaves (and every node above them
  for up to 8 blocks) for 0, 1, 1 MiB − 1, 1 MiB, 1 MiB + 1, 3 MiB + 7 bytes at shifts 20 and 21 and 1 GiB at shifts
  20 and 21, of the file `byte(i) = i mod 251`; every minor-4 frame and the OFFER and OFFER_REPLY fields, refusals
  included; ranges; lane tokens; both sidecars; the SYNC and AGAIN messages. The small trees were checked against an
  independent pure-Python BLAKE3, and the lane tokens against Python's keyed BLAKE2b. `transfer_vectors.rs` fails when
  the files differ from what the core computes; WP4's exporter must write the same bytes.
- Tests: the codecs and assembly (unit), negotiation and stripping (`session_fast_transfers.rs`), the store by blocks
  with a crash, a block changed on disk, a corrupt block and the digest check (`store_blocks.rs`), and two whole
  helpers (`szfriends-interop/tests/fast_transfers.rs`): a 96 MiB file by blocks over the test air, the receiver
  restarted half-way and resuming from the blocks it kept; a new helper with one playing a released helper, files both
  ways with no tree sent. A `block_flow` fuzz target (one minute clean).

**Released apps.** Session code is unchanged since `pdf/26.10.29-1` and `files/26.10.29-1`, so the interop suites run
against the Objective-C session peer and helper built from this tree are the released behaviour: with them the Rust core
negotiates minor 3 and sends nothing new. `make friends-core-rs-interop-check` passed (38 tests: sessions, nearby,
Get again, routes against the Objective-C peer and helper). WP5's `make friends-transfer-interop` with this core: every
pair with a released peer (`pdf/26.10.29-1` Objective-C, `3d/preview-0.2.4` Rust) negotiates minor 3 and passes on all
five emulated routes, including resume after a cut; today's Rust with today's Rust negotiates minor 4; the 30 rows that
pair today's Rust or Objective-C with today's Objective-C fail only the matrix's expectation of minor 4, which WP4
brings. The Objective-C transcripts replay at the helper's own minor 3 until WP4 exports minor 4. (WP5's peers run the
CHUNK flow: blocks themselves are tested between whole Rust helpers, above.)

**Left for the next packages.**

- Get again and own-device copies by blocks: the messages, vectors and the store's map are ready; the flows in
  `sync/again_*.rs` and `sync/exchange.rs` (requesting WANT BLOCKS, serving BLOCKS FOLLOW, HASHES and PARTs for a
  file that is not an offer) are not built. They still resume from their contiguous prefix, as before.
- WP1's store items outside this pass: cloned snapshots without fsync, staging and publishing in batches,
  preallocation beyond the sparse `set_len`, skipping files already held; and the 300-small-files target.
- "Finishing…" (`transfer.finishing`) while the publish check runs; progress already counts checked blocks.
- WP4 must reproduce `fixtures/vectors/transfer/*.json` byte for byte (the exporter, then a parity check); then
  `objc_vectors.rs` and the transcript replay go back to requiring equal minors.
- Phone measurement of BLAKE3 (script above).

## WP2: the multi-route scheduler (Rust core)

**What landed.** `szfriends-core/src/transfer/scheduler.rs`: one `Scheduler` per lane group, sans-IO, for every
transfer this side sends to that device. In: `LaneEvent::Up`/`Down` from WP3's `LaneGroup`, WANT and HAVE ranges,
`written` (a write on a lane completed), `sent` (a block's last part written), `heard` (a byte from the peer),
`cpu_bound` (a lane's encrypting thread is the limit), `tick` at `next_timer()`. Out: `Action::Send { lane,
transfer, block }`, `Cancel` (another copy completed: drop its unwritten parts), `Lane(LaneRequest::Open/Close)`.
Blocks are WP1's `Geometry`; the driver reads each block through the same leaf check as `BlockServe::load_block` and
cuts it into the lane's parts. `transfer/sim.rs`: a virtual-time event simulator (lanes with rate, round trip, part
loss, silences, cuts noticed after a delay, lanes that come up only when asked for), lanes managed by the real
`LaneGroup`, and a mode that moves real bytes through WP1's tree and `BlockAssembly` with damaged blocks.
`friends/fixtures/scheduler/scenarios.json`: the scenario table with expectations, for WP4's port to meet as well.

**How it decides** (ADR 0018 § 7; what the ADR left open, decided here):

- Rate: BBR's delivery-rate sample per HAVE (bytes the lane delivered since the block was assigned, over the time since
  the lane's previous delivery, or since it went busy from idle), the largest in the last 10 s. Round trip: the smallest
  from a block's last part written to its HAVE in the last 10 s. Until measured, a route's typical figures (LAN 40 MB/s
  5 ms, direct Wi-Fi 20 MB/s 5 ms, Internet 4 MB/s 50 ms, relay 0.5 MB/s 100 ms, Bluetooth 0.15 MB/s 40 ms).
- "Expected to finish first": each lane's ETA is (in flight + block) / rate + round trip. The block goes to the lane
  with room and the lowest ETA. If a better lane exists but is full, the lane with room takes the block only when its
  ETA is no later than the time the other lanes would need to finish everything still unassigned, filled like water
  across them. So a slow lane adds its share while much is left and stops taking blocks as the end nears, with no
  special case for Bluetooth.
- In flight per lane: 2 × rate × round trip, at least two blocks, at most 32 MiB (8 MiB on phones). Per transfer, at
  most 64 open blocks and 64 MiB (§ 3). A block whose lane went away stays open, since the receiver may hold parts of it,
  and goes before any new block.
- Bluetooth carries blocks when it is the only working lane, or while the others together measure below 4 MB/s (the
  ADR says "another lane's"; the sum is what matters when there are several). The relay is used only when nothing
  else works, Bluetooth included, following the owner's route order (Bluetooth before the relay).
- Direct Wi-Fi: `Config::direct_wifi_keeps_internet` says whether this platform keeps its Wi-Fi network beside it
  (AWDL). Without that, direct Wi-Fi is never asked for, and a direct Wi-Fi lane that comes up anyway is closed unused.
  The first session is exempt, because the route racer already chose it.
- Lane requests: Bluetooth while the direct lanes measure below 4 MB/s and more than 4 s of work is left; direct Wi-Fi
  while the LAN lanes measure below 25 MB/s (only where it keeps the network); one more lane on a route when
  `cpu_bound` says so (never the relay or Bluetooth, at most 4 per route). The same request is not repeated within 10 s.
- A WANT for a block that is open means it failed its check: its copies are cancelled and it goes first.
- Endgame: when nothing is unassigned, a lane with room takes a second copy of the block that would otherwise finish
  last, when it would finish it sooner by more than its own round trip. Bluetooth never takes second copies unless it is
  the only lane. One second copy per block at most.

**Found by the simulator: a HAVE lost with a silent lane stalls the transfer.** The receiver sends a HAVE on the lane that
completed the block. If that lane then goes silent, the sender gives the block to another lane, and the receiver drops
the second copy as late. The block is never acknowledged, and the transfer waits until the group ends. Fix, added to ADR
0018 § 3: the first late part of a block on each lane is answered with a HAVE naming that block on that lane. This
makes no difference with one session per friend, which is what the Rust helper runs today. WP3, when it builds groups
in the helper's session table, and WP4 must both do it. The helper should send HAVE on the lane that completed the block (not the
control lane), so the HAVE follows its parts and the round trip measures that lane.

**Results** (deterministic; the whole table runs in 0.08 s in a release build, 1.3 s in debug). "Of the lanes' sum"
is over every lane in the scenario, including those the rules keep idle; "sent twice" counts bytes that reached the
receiver for something it already had; "idle at the end" is how long the fastest lane still up had nothing to do
before the last HAVE.

| Scenario | Lanes (Mbit/s) | Time | MB/s | Of the lanes' sum | Per route (MiB sent) | Sent twice | Fastest lane idle at the end |
|---|---|---|---|---|---|---|---|
| lan | lan 940 | 9.14 s | 117.5 | 100 % | lan 1024.0 | 0.0 MiB | 2 ms |
| lan and direct wifi | lan 940, direct-wifi 300 | 6.94 s | 154.8 | 100 % | lan 777.0, direct-wifi 247.0 | 0.0 MiB | 2 ms |
| lan, direct wifi and internet | lan 100, direct-wifi 300, internet 50 | 9.57 s | 56.1 | 100 % | lan 114.0, direct-wifi 342.1, internet 56.0 | 0.1 MiB | 1 ms |
| two lanes on the lan | lan 4000, lan 4000 | 1.08 s | 998.8 | 100 % | lan 512.0, lan 512.0 | 0.0 MiB | 1 ms |
| slow lan and bluetooth | lan 16, bluetooth 1.4 | 48.49 s | 2.2 | 99 % | lan 92.5, bluetooth 8.0 | 0.5 MiB | 5 ms |
| slow lan, bluetooth asked for | lan 16, bluetooth 1.4 | 48.76 s | 2.2 | 99 % | lan 93.0, bluetooth 7.0 | 0.0 MiB | 5 ms |
| slow lan, bluetooth lossy | lan 16, bluetooth 1.4 | 48.76 s | 2.2 | 99 % | lan 93.0, bluetooth 7.0 | 0.0 MiB | 5 ms |
| slow lan, bluetooth out of range half-way | lan 16, bluetooth 1.4 | 50.34 s | 2.1 | 96 % | lan 96.0, bluetooth 4.1 | 0.1 MiB | 5 ms |
| slow lan, bluetooth flapping | lan 16, bluetooth 1.4 | 52.43 s | 2.0 | 92 % | lan 100.0, bluetooth 3.0 | 2.7 MiB | 5 ms |
| fast lan, bluetooth unused | lan 940, bluetooth 1.4 | 2.29 s | 117.4 | 100 % | lan 256.0, bluetooth 0.0 | 0.0 MiB | 2 ms |
| bluetooth alone | bluetooth 1.4 | 24.00 s | 0.2 | 100 % | bluetooth 4.0 | 0.0 MiB | 30 ms |
| internet, relay unused | internet 50, relay 5 | 16.82 s | 6.2 | 91 % | internet 100.0, relay 0.0 | 0.0 MiB | 40 ms |
| relay alone | relay 5 | 26.92 s | 0.6 | 100 % | relay 16.0 | 0.0 MiB | 80 ms |
| relay, then the lan | relay 5, lan 940 | 4.27 s | 62.9 | 53 % | relay 2.5, lan 254.0 | 0.5 MiB | 2 ms |
| direct wifi without its own network stays unused | lan 100, direct-wifi 300 | 21.48 s | 12.5 | 25 % | lan 256.0, direct-wifi 0.0 | 0.0 MiB | 2 ms |
| direct wifi cut half-way | lan 940, direct-wifi 300 | 8.03 s | 133.8 | 86 % | lan 899.0, direct-wifi 125.1 | 0.1 MiB | 2 ms |
| direct wifi silent half-way | lan 940, direct-wifi 300 | 8.03 s | 133.8 | 86 % | lan 899.0, direct-wifi 125.1 | 0.1 MiB | 2 ms |
| lan flapping beside direct wifi | lan 940, direct-wifi 300 | 4.98 s | 107.7 | 70 % | lan 334.1, direct-wifi 178.0 | 0.1 MiB | 1 ms |
| phone, lan and direct wifi | lan 400, direct-wifi 200 | 7.18 s | 74.8 | 100 % | lan 342.0, direct-wifi 170.0 | 0.0 MiB | 6 ms |

What these show:

- **Throughput reaches the sum of the lanes.** LAN plus direct Wi-Fi gives 154.8 MB/s of 155.0 (100 %). Three routes
  give 56.1 of 56.25. Two 4 Gbit/s lanes give 998.8 MB/s. A slow 16 Mbit/s LAN with Bluetooth beside it gives 99 % of
  the two together, against 92 % for the LAN alone. A fast LAN leaves Bluetooth unused.
- **Bluetooth never stalls a transfer.** Lossy (5 % of parts cost a round trip each), out of range half-way, or
  flapping 2.5 s out of every 4 s: the transfer still finishes sooner than the LAN alone would (52.4 s), and the
  fastest lane is idle at most 5 ms at the end.
- **Losing a lane.** Direct Wi-Fi cut or silent half-way through 1 GiB: 8.03 s, against 6.94 s with both lanes
  throughout and 9.14 s on the LAN alone, with 0.1 MiB sent twice. Silence costs nothing over a cut here because the
  LAN is busy while it is being noticed.
- **The tail is short.** In every multi-lane scenario, the LAN flapping included, the fastest lane is idle only 1 to
  6 ms before completion: about its own round trip, waiting for the last HAVE. The last blocks never wait on Bluetooth
  or on a slower route.
- **The relay comes last.** Beside the Internet route it carries nothing. Alone it runs at its cap. When the LAN comes
  up 2 s in, the relay's last 2.5 MiB drain while the LAN takes everything new.

Properties, tested every run: 150 random scenarios (1 to 4 lanes of any route, rates from Bluetooth's to 900 Mbit/s,
round trips up to 80 ms, part loss up to 5 %, lanes cut, silent or flapping at random times; the first lane always
survives). In every one, every byte arrives, § 3 and the per-lane caps hold, and nothing hangs. A silent lane never
delays completion by more than its detection time compared with the same lane cut at the same moment (direct Wi-Fi,
Bluetooth and LAN, at 0.5, 2 and 4 s). With real bytes through WP1's `BlockAssembly`, a damaged block is wanted again
alone and the file that arrives is the file sent, with direct Wi-Fi cut and Bluetooth silent along the way.

**For WP4: the scheduler in pseudo-code** (the scenario table is the test; tuning may differ, frames may not):

```text
per lane: rate, rtt (route's typical until measured), in_flight, delivered, delivered_at, progress_at, heard_at,
          silent, holds (FIFO of placements)
per transfer: wanted (not in a HAVE), unassigned (wanted, no placement on a working lane), open (block -> placements)
eta(L, b)  = (L.in_flight + b) / L.rate + L.rtt
cap(L)     = clamp(2 * L.rate * L.rtt, 2 * block_size, 32 MiB or 8 MiB on phones); room if in_flight == 0 or +b <= cap
eligible   = working lanes (not silent, not closing, not unused direct Wi-Fi);
             drop the relay if any other is working; drop Bluetooth unless alone or the others sum < 4 MB/s
fill():
  while block = (an open unassigned block) or (lowest unassigned, if open < 64 blocks and 64 MiB):
    best = argmin eta over eligible; cand = argmin eta over eligible with room; none -> stop
    if cand != best and eta(cand) > finish_time(eligible - cand, all unassigned bytes): stop
    assign(block, cand): if cand idle then delivered_at = progress_at = now; record (delivered, delivered_at);
                         in_flight += b; Send
  if nothing unassigned anywhere: endgame: repeat
    for each open block with exactly one working placement P, for each helper lane H with room (Bluetooth only if alone):
      gain = expected(P) - (now + eta(H, b)); take the largest gain > max(H.rtt, 5 ms); assign a second copy
  ask for lanes (Bluetooth, direct Wi-Fi) as above, at most every 10 s per route
finish_time(lanes, R): smallest T with sum over lanes of max(0, rate * (T - rtt) - in_flight) >= R
expected(P): sent ? max(sent_at + rtt, now) : now + (unsent bytes on its lane up to P) / rate + rtt
HAVE(block): winner = placement written first (else assigned first); others Cancel; winner's lane:
             delivered += b; rate sample (delivered - P.delivered) / (now - P.delivered_at); rtt sample now - sent_at;
             delivered_at = progress_at = now; un-silence
written(L) / sent(L): progress_at = now if L has blocks; un-silence (its blocks are no longer unassigned)
Down(L): its placements removed; blocks without another working placement -> unassigned (still open); fill()
tick: L with blocks and no progress for max(3 rtt, 1 s; 2 s on Bluetooth) -> silent: its blocks unassigned, fill();
      silent L (not the first session) with nothing heard for 10 s -> Close
WANT(block) for an open block -> Cancel every copy, unassigned, goes first
```

**Not done, and why.** Multi-route runs in the real helpers need WP3's groups in the helper's session table, with
lanes on LAN, direct Wi-Fi and the test air. That has not landed: the Rust helper still runs one session per friend,
with WP1's `BlockServe` and its fixed 16 MiB window (2 MiB on Bluetooth). WP5's bench now moves files by blocks
(86549886), but over one session and one proxy per transfer. So there is no bench number for the scheduler over two
routes yet, and none of today's measured transfers changed. When WP3 lands groups, the driver is:

- one `Scheduler` per group;
- a per-lane part queue fed by `Send` (each block read and checked as `load_block` does), pumped while the lane's bulk
  queue is shallow, with `written` on each write completion and `sent` after a block's last part;
- `heard` on every received frame;
- `have` and `want` from the frames, whichever lane they arrive on;
- `tick` on the helper's timer;
- `Open` and `Close` through the group.

Then WP5's bench gains a two-route case, with two proxies (one per lane), and the scenarios above are measured for real.

## WP4, part 1: liveness, disk work and speed checks in the Objective-C helper (2026-10-29)

Measured on the same Mac with `make friends-transfer-bench` (WP5), before and after, one run each, with other
packages building alongside (load average 5 to 7): MB/s varies by up to 30 % from run to run, the silence timings and
CPU seconds per GB much less. The Rust peer is the same build in both runs.

**1. Liveness** (ADR 0018 § 7, as fe4e9e04 gave the Rust core). `SZFriendsSecureChannel+Liveness.m`: while a
transfer runs on a session the channel sends PING after a second without sending, and closes the session
(`SZFriendsSessionErrorSilent`, no CLOSE) after 8 s without hearing a byte, 12 s when the initiator declared
Bluetooth. `SZFriendsTransferLiveness` decides, as `transfer_liveness()` does: keepalive while any flow runs, watching
only while the peer owes PROGRESS for bytes sent or the rest of a file whose chunks are arriving, so a released peer is
judged by its own traffic. A gap of more than two keepalives between timer runs (a busy helper queue, sleep) restarts
the count. The nearby service and the interop peer call it whenever a flow changes; redial and resume are the ones a
cut already used.

| Route silenced mid-transfer (proxy stops forwarding, sockets open) | Before | Now |
|---|---|---|
| LAN, 100 MiB, Objective-C → Objective-C | not noticed in 20 s | 8.00 s, moving again 0.007 s later |
| LAN, Objective-C → Rust / Rust → Objective-C | 8.00 / 7.98 s (the Rust side noticed) | 8.00 / 7.96 s |
| Bluetooth, 4 MiB, Objective-C → Objective-C | not noticed in 20 s | 11.93 s |
| Bluetooth, Objective-C → Rust | 11.92 s | 11.92 s |

A cut on LAN (100 MiB, at half) is noticed at once in every pair and moves again within 12 ms, as before.

**2. Disk work** (ADR 0018 § 9.1, as 3fed69c6). Snapshots were already clones (`fclonefileat`), read once for their
digests and never flushed. What changed: a received batch made the partial file durable with F_FULLFSYNC and then
committed its count, whose WAL commit runs F_FULLFSYNC again; it now orders the file's writes with F_BARRIERFSYNC and
lets the commit's flush cover both (the partial file and the store share the state directory's volume), one full
flush per 4 MiB instead of two, with the same guarantee: the database never claims a byte the disk could lose.
`SZFriendsOrderWrites` and `SZFriendsMakeDurable` are the two halves the block map's batches will use. The sender opens
a snapshot once per transfer with read-ahead on and reads each chunk with one `pread`.

| Objective-C → Objective-C | Before | Now |
|---|---|---|
| 300 × 10 KiB, loopback / LAN | 5.99 / 6.37 s | 4.46 / 5.13 s |
| 2 GiB, loopback | 199.8 MB/s, 2.43 + 3.66 CPU-s/GB | 205.4 MB/s, 2.49 + 3.76 CPU-s/GB |
| 2 GiB, LAN (1 GbE emulated) | 70.5 MB/s, 60 %, receiver 5.90 CPU-s/GB | 79.6 MB/s, 68 %, receiver 4.46 CPU-s/GB |
| 2 GiB, LAN, Rust → Objective-C | 67.7 MB/s | 71.1 MB/s |

**3. Speed checks on the Mac side** (a scratch program against the helper's own objects, one core):

| | Throughput |
|---|---|
| libsodium ChaCha20-Poly1305 through `szfriends_cipher_encrypt`, 4 KiB / 16 KiB / 60 KiB messages | 0.78 / 0.77 / 0.77 GB/s |
| The same, encrypt then decrypt | 0.38 to 0.40 GB/s |
| libsodium BLAKE2b-256 | 1.57 GB/s |
| Two channels on one queue over memory streams, 1 GiB of 60 KiB CHUNKs (codec, queues, encryption, decryption) | 0.34 GB/s, 2.94 CPU-s/GB for both sides |

The cipher is 2.5 of those 2.94 CPU-s/GB: the channel's framing, copies and queues add 15 %, so batching several
Noise messages per write would save little CPU on this side, and it was not done. libsodium has no NEON ChaCha20, so
one Objective-C lane tops out near 0.77 GB/s encrypting; what puts a transfer on more cores is lanes (part 2) and,
later, AES-GCM lanes (WP6, 8.5 GB/s in phase 1). A `sample` of the receiving peer 6 s into a 2 GiB loopback transfer
agrees: of its busy time, ChaCha20 and Poly1305 take 47 %, the running BLAKE2b digest 24 %, `pwrite` 13 %, the
barrier flushes 10 % and copies 6 %; the store's per-chunk row check and the framing do not show. With blocks (part 2)
the running digest goes away (each block is checked against its BLAKE3 leaf, on any core, and the publish check reads
the file once).

## WP5: the bench, the interop matrix and the device script (2026-10-29)

Landed on main: 0350a20a (the harness), 04ac7e4e (the emulator carries its whole rate), 86549886 (the Rust peer by
blocks), e92e1ac1 (several routes at once). Helper numbers 26102903, 26102906 and 26102910 were raised only because the
check counts Friends test code; the helper itself did not change in this package. Everything here runs on demand; no
suite runs it, so `friends-suite`, `friends-core-rs-check` and `friends-core-rs-interop-check` stay as lean as they
were (the interop suites that use the proxy and the Rust peer still pass: `rust_loopback` 16, `objc_interop` 7).

**What there is.**

- **The route emulator** (`szfriends-interop/src/proxy.rs`). Per direction: rate, one-way delay, loss, silence and cut,
  plus the byte flips the tamper tests already used. Silence stops reading and delivering with both sockets open, as
  a route out of range looks to TCP; for good, for a while, one way, or flapping; and `cut_now` / `silence_now` lose
  a route at a moment the caller picks. Loss is modelled, not real (loopback TCP never loses; dummynet needs root):
  each direction keeps a Reno-like window over 1,448-byte segments, which gives TCP's throughput under loss (Mathis:
  117 KB/s at 150 ms and 1 %; a unit test holds the model within a third of it). CUBIC with SACK does better on real
  paths, so the lossy figures are a floor.
- **The emulator now carries its whole rate.** Pacing restarted from the moment its thread woke, so every oversleep
  (tens of microseconds on macOS against 139 µs per 16 KiB at 1 GbE) was lost: the emulated LAN carried 77 % of its
  rate. Phase 1's shaper had the same flaw, so **its LAN shares (68 to 82 %) and this package's first baseline read
  low**; a 5 ms bucket fixes it, and an ignored test (`cargo test -p szfriends-interop --lib -- --ignored`) checks
  LAN, direct Wi-Fi, internet and Bluetooth carry 95 to 105 % of their rates. The tables below are all after the fix.
- **Peers as processes.** `examples/session_peer.rs` runs the Rust peer behind the Objective-C peer's protocol, so each
  side's CPU is its own process's (phase 1's Rust figures included the proxy), the same file builds the released Rust
  core's peer, and it runs on a phone. Both peers' `dial` takes `route` (the class the initiator declares) and `host`,
  `listen` takes `any`, and `hello` says `session_minor`.
- **The Rust peer moves files by blocks** (`src/blocks.rs`) exactly as the Rust helper's `service/blocks.rs` wires the
  store (tree in OFFER, Blocks, HASHES, WANT on each new session, PART, HAVE, publish check, ACK), CHUNK otherwise;
  without it the bench could not see WP1. One difference: the peer runs the publish check inline, the helper (since
  c5e94d3a) on a thread. Its `established` event says `fast`.
- **`make -C apps/pdf/portable friends-transfer-bench`** (`examples/transfer_bench.rs`): the four pairings of today's
  Rust and Objective-C peers send 1 MiB, 100 MiB, 2 GiB and 300 × 10 KiB through loopback, LAN (940 Mbit/s, 2 ms),
  direct Wi-Fi (300 Mbit/s, 4 ms), internet (50 Mbit/s, 40 ms), internet_lossy (150 ms, 1 %), relay (5 Mbit/s, 80 ms)
  and Bluetooth (1.4 Mbit/s, 30 ms), then a cut and a silence half-way on LAN (100 MiB) and Bluetooth (4 MiB). A case
  a route would need more than 120 s for is listed as skipped (`BENCH_MAX_SECONDS`). It prints MB/s, share of the
  link, CPU s/GB per side, when the loss was noticed and the recovery (from the loss until the sender sends again on
  the route that came back; the harness redials when a side reports the session closed, or after 20 s). JSON lines go
  to `build/friends/core-rs/transfer-bench.jsonl`; `transfer_bench --table <file>` reprints them. `BENCH_PAIRS`,
  `BENCH_ROUTES`, `BENCH_SIZES`, `BENCH_LOSS`, `BENCH_MULTI` narrow it: `BENCH_ROUTES=loopback,lan BENCH_SIZES=2g
  BENCH_LOSS=none BENCH_MULTI=none` measures a change in a minute. Point `SZFRIENDS_RUST_PEER` and
  `SZFRIENDS_OBJC_PEER` at other builds to compare (the "before" column below is the peers at 0350a20a, built with
  `SZFRIENDS_MAC_TAG=0350a20a SZFRIENDS_RUST_TAG=0350a20a tools/released-peers.sh <dir>`).
- **Several routes at once** (`BENCH_MULTI`): LAN + direct Wi-Fi (1 GiB), a 10 Mbit/s LAN + Bluetooth (16 MiB), all
  three, and in each one route cut or silenced when the whole transfer is half done (direct Wi-Fi cut; the session's
  own LAN route silenced; Bluetooth cut or silenced beside the slow LAN; LAN cut among three). Each route is its own
  proxy; the first carries the session, the others are dialed as lanes of it. Reported: MB/s, share of what the routes
  carry together, share of the fastest alone, bytes per route, when the lost lane was noticed. **Not run yet:** the
  peers open no lanes, so each case says "skipped: these peers open no lanes yet". What a peer needs, once WP3's lanes
  are in the helper: `hello` answers `"lanes": true`, and `dial` with `"lane_of": <session>` opens a lane of that
  session on the given port and route class (an `established` event follows). WP5 wires that into the Rust peer as it
  did blocks, when WP3 lands; WP4 into the Objective-C peer.
- **`make -C apps/pdf/portable friends-transfer-interop`** (`examples/transfer_interop.rs`): `tools/released-peers.sh`
  builds the Objective-C session peer against the helper at `pdf/26.10.29-1` and the Rust peer at `3d/preview-0.2.4`
  (one commit, 52e08c73), in a worktree under `build/friends/core-rs/released/`, about 40 s once. Then every ordered
  pair with at least one of today's peers (12) on LAN, direct Wi-Fi, internet, relay and Bluetooth: a transfer (64,
  32, 8, 1, 0.5 MiB) and one cut at 50 % that must resume past zero (or, by blocks, send a one-block file's block
  again). A run checks the bytes, that both sides agree on the minor, and that it is the newest both speak (from
  `hello`; released peers speak 3). `INTEROP_EXPECT_FAST=1` also requires today's pairs to report `fast`;
  `INTEROP_SILENCE=1` adds a silent route that must be noticed within 8 s (12 s on Bluetooth).
- **`tools/transfer-devices.sh`** for real devices: `mac <ssh host> [address]` copies both peers to `~/szf-bench` on
  another Apple silicon Mac and runs the Objective-C one there over ssh (`BENCH_REMOTE_PEER=rust` for the Rust core);
  `android <phone address> [serial]` cross-builds the Rust peer with the NDK (it builds), pushes it to
  `/data/local/tmp/szf` and runs it with `adb shell -T`. This Mac dials the device (Wi-Fi or Ethernet address;
  `fe80::…%awdl0` with `BENCH_ROUTE_CLASS=p2p_wifi` for AWDL); each payload goes there and the device's copy comes
  back and is checked here, so nothing is prepared on the device. For the share of the link, measure one TCP connection
  with `iperf3` and pass `BENCH_LINK_BYTES_PER_SECOND`. Dry run on one Mac: `BENCH_REMOTE_LOOPBACK=1` (done: 1 MiB and
  300 × 10 KiB both ways). Not covered: Bluetooth between real devices (these peers speak TCP; it needs the helpers'
  lanes) and iPhones (no peer process). A Mac's firewall may ask once on the remote side.

**Numbers.** One M5 Max, release builds, while other packages built in parallel (load around 7): single runs of a
case vary by up to 30 % on loopback, less on emulated routes, which pace. Before: the peers at 0350a20a (no WP
package yet). After: main at 2950f2bc (WP1's blocks, WP3's ciphers, cloning and liveness, WP4 part 1's liveness).

| Case (each cell: before → after) | Rust → Rust | Rust → Objective-C | Objective-C → Rust | Objective-C → Objective-C |
|---|---|---|---|---|
| Loopback 2 GiB | 72 → 248 MB/s | 89 → 206 MB/s | 122 → 179 MB/s | 192 → 245 MB/s |
| CPU-s/GB, loopback 2 GiB (send + receive) | 4.5 + 4.2 → 3.4 + 3.4 | 5.1 + 4.6 → 3.5 + 3.6 | 2.5 + 3.9 → 2.5 + 3.3 | 2.5 + 3.6 → 2.4 + 3.6 |
| LAN 100 MiB | 63 MB/s, 53 % → 102, 87 % | 57, 49 % → 91, 78 % | 76, 65 % → 97, 82 % | 76, 65 % → 97, 82 % |
| LAN 2 GiB | 87 MB/s, 74 % → 106, 91 % | 83, 71 % → 94, 80 % | 90, 77 % → 101, 86 % | 101, 86 % → 101, 86 % |
| Direct Wi-Fi 2 GiB | 91 % → 97 % | 91 % → 92 % | 95 % → 93 % | 95 % → 91 % |
| Internet 100 MiB | 97 % → 99 % | 98 % → 98 % | 98 % → 98 % | 98 % → 98 % |
| LAN, 300 × 10 KiB | 13.6 → 15.4 s | 8.2 → 7.1 s | 8.8 → 8.5 s | 6.6 → 3.7 s |
| LAN cut at 50 %: noticed, moving again | 0.004 s, 0.01 s → the same | the same | the same | the same |
| LAN silent at 50 %: noticed | not in 20 s → **not in 20 s** | not in 20 s → 8.0 s | not in 20 s → 8.0 s | not in 20 s → 8.0 s |
| Bluetooth silent at 50 %: noticed | not in 20 s → **not in 20 s** | → 11.9 s | → 11.9 s | → 11.9 s |

The rest of the after run, all four pairs alike within a few percent: 1 MiB takes 50 to 90 ms on every fast route
(the fixed cost per file; the 190 to 210 ms phase 1 saw in two Objective-C receiver runs did not recur in about 40
runs here); internet 1 MiB 62 to 66 %; the lossy path 78 % of TCP's rate under loss for 1 MiB, 31 s for 300 small
files; relay 1 MiB 90 %, Bluetooth 1 MiB 97 %, 300 small files over Bluetooth 18.3 s (96 %); a cut on Bluetooth is
noticed in 5 ms and moving again in 0.06 s, but Rust → Rust by blocks resends up to a 1 MiB block on the slow route
(4 MiB took 30.3 s, 79 %, against 24.6 s, 98 %, by CHUNK). The first baseline, before the emulator fix and before any
package, is in `build/` only: its LAN shares (46 to 68 %) are the emulator's, not the peers'.

**Interop matrix**, run three times: on 0350a20a, on 2950f2bc (after WP1 and WP3) and on 792a6cb4 (after WP4 gave the
Objective-C helper minor 4): **120 of 120 runs pass each time.** Every pair with a released peer (`objc-26.10.29-1`,
`rust-0.2.4`) negotiates minor 3, moves the file intact on all five routes and resumes after the cut (41 to 50 %).
Today's pairs negotiate minor 4 on 792a6cb4; Rust ↔ Rust is fast (blocks) and resumes from its blocks (38 to 48 %; a
one-block file on the relay and Bluetooth sends its block again); pairs with today's Objective-C peer still move by
CHUNK, because the Objective-C session peer does not run blocks or report `fast` yet.

**Findings for the other packages.**

1. **A silent route is not noticed during a transfer by blocks (WP1, WP3).** `transfer_liveness` (the Rust helper's
   `service/sessions.rs`, and the Rust peer, which copies it) looks only at CHUNK senders and receivers, so a fast
   session carrying blocks never sets keepalive or watch: LAN and Bluetooth silenced half-way are not noticed in 20 s
   between today's Rust peers, while every CHUNK pair notices at 8.0 s and 11.9 s. The block sender (blocks sent and
   not in a HAVE) and receiver (blocks wanted, parts arriving) need the same rule.
2. **Bluetooth resume by blocks resends up to a block** (1 MiB, about 6 s at 175 KB/s). ADR 0018's part size for
   Bluetooth is 16 KiB but the block, the unit of resume, stays 1 MiB; a durable partial block, or smaller blocks on
   Bluetooth-only transfers, would keep the resend near CHUNK's (0.05 MB).
3. **WP4:** the Objective-C session peer needs blocks and `fast` in `established` (as `src/blocks.rs` does for Rust) for
   the bench and matrix to measure its block path; then run the matrix with `INTEROP_EXPECT_FAST=1`.
4. **300 small files** are still 3.7 to 15.4 s (target 1.5 s); Rust → Rust is the slowest pair (WP1's batches).

**Left.** The multi-route cases run once lanes land (WP3 for Rust, WP4 for the Objective-C helper) and the peers
take `lane_of`; then their numbers go here. Hardware runs with `tools/transfer-devices.sh` when the owner's second Mac
or phone is at hand; BLAKE3 on the phone with `tools/tree-hash-bench.sh android` the same day.

## WP3, second part: lanes in the Rust helper, driven by WP2's scheduler

On WP1's wire and store and WP2's scheduler (4548360c).

- **Handshake.** `HandshakeOptions::lane` puts the 16-byte token in IK message 1's encrypted payload (field 46, IK
  only, never beside an Add by ID token); the responder reads it before HELLO (`presented_lane`). Admission happens
  once the lane is live: the token must name a free index of a live fast group with the same identity and static key,
  or the lane closes with CLOSE 6 (`LaneRefused`). The side that dialed the first session opens odd indexes, the
  other even ones, so lanes both open at once never collide (a local rule; any free index is admitted).
  `tests/session_lanes.rs`: the token arrives encrypted, both sides derive the same fifteen, XX refuses one.
- **Groups in the session table** (`service/lanes.rs`). A first session that negotiated fast transfers forms a group
  when adopted. Lanes never race, carry no conversation of their own and never count against the person's backoff;
  every frame on a lane is handled as the first session's, except that a PART's HAVE goes back on the lane that
  carried it; the first session's end closes its lanes.
- **The scheduler drives it.** One `Scheduler` per group, made when the group first sends by blocks and kept until the
  group ends: it hears the group's lane events (seeded with the lanes live when it is made), WANT and HAVE, each write
  completed (`written`) and each byte heard (`heard`) on every lane, a block's last part handed out (`sent`), and
  `tick` on every pass. `Send` reads the block through the leaf check and cuts it into that lane's parts (16 KiB on
  Bluetooth, § 9.8); `Cancel` drops a block's unsent parts; `Lane(Open)` dials the friend's device where it is seen on
  that route (LAN, direct Wi-Fi, Bluetooth; online lanes are not built yet), `Lane(Close)` closes the lane. Parts go on
  lanes only after the receiver's first HAVE or WANT, since they could otherwise overtake HASHES. Direct Wi-Fi keeps
  the device on its network only on Apple systems, so elsewhere the scheduler never asks for it.
- **The late-part rule** (ADR 0018 § 3, from WP2's simulator): the receiver answers the first late part of a block on
  each lane with a HAVE naming that block, on that lane, so a block whose first HAVE was lost with a silent lane is
  still acknowledged.
- **One flush per durability batch** (also done by WP4's commit for the Rust helper's batch): `disk::order_writes`, then
  one `make_durable` (F_FULLFSYNC): about 6 ms per batch instead of 9.8, from the phase 1 primitives.
- **Emulated routes for whole helpers.** `SZFRIENDS_TEST_ROUTE_RATES` (`lan=1250000,bluetooth=175000`, test homes
  only) paces each link's writes at its route's rate, so two helpers on the loopback network and the test air are
  measured with several routes at once; `SZFRIENDS_TEST_LANES=0` turns lanes off.

| Two Rust helpers, `tests/fast_lanes.rs` | Network alone | With lanes |
|---|---|---|
| 12 MiB, LAN 1 MB/s, Bluetooth 1 MB/s | 13.3 to 13.4 s | 7.8 s with the scheduler (11.2 s with the first, fixed rule) |
| 32 MiB, LAN 10 Mbit/s, Bluetooth 175 KB/s (`lanes_bench`, ignored) | 28.8 s, 1.16 MB/s | 26.0 to 26.1 s, 1.29 MB/s: Bluetooth adds 68 to 75 % of its rate |

The target is 80 % of Bluetooth's rate. What is missing at 175 KB/s is the time before the scheduler asks for the lane
(its rule wants 4 s of work left and a measured rate), the lane's dial and handshake over the paced radio, and the last
blocks kept off it. One run in three of `lanes_bench` failed earlier, before any transfer, in befriending over the paced
routes (the comparison code never appeared); the transfers themselves did not fail.

**Liveness on block transfers** (found by WP5's bench: on a minor 4 transfer by blocks a silenced route went
unnoticed for 20 s, because `transfer_liveness` saw only CHUNK flows). The helper's sessions and lanes, and the interop
crate's Rust peer, now ping and watch while a file moves by blocks in the group: watching while a sent block awaits its
HAVE or a received file is not yet durable (both sides of a fast session ping, so watching is safe there). `make
friends-transfer-bench`, Rust to Rust by blocks (minor 4): LAN silenced noticed after 8.00 s, Bluetooth after 11.26 s,
moving again 0.01 and 0.06 s later, files intact. A lane silenced this way closes and the scheduler hands its blocks
to the others.

**Bluetooth resume costs a block.** Those runs sent 1.06 MB twice: after a cut or silence the receiver's WANT names
whole blocks, so the partly received 1 MiB block goes again, about 6 s of Bluetooth. Parts that arrived stay written
(the assembly keeps them) but nothing tells the sender which. Two ways, both protocol changes for the ADR rather than
this package: WANT naming part ranges within a block on Bluetooth lanes (16 KiB granularity, a new field), or a
smaller block shift for files sent over Bluetooth (§ 2 fixes shift 20 as the minimum, so the tree would change).
Proposed for WP6.

Found while wiring it: a scheduler made when the group was already live must be told which lanes are up (the group's
events had gone to an earlier scheduler), or the second file of a session is never scheduled.

Still open, for the next package: lanes in the interop crate's Rust peer (`hello` with `"lanes": true`, `dial` with
`lane_of`), which WP5's multi-route bench cases need and list as skipped until then; online lanes (more data channels
in one peer connection, one only on the relay) with 8 MiB buffering and usrsctp's buffers raised, measured first with
delay and loss; Bluetooth lanes on BlueZ and phones (the test air's code path, untested on radios); the AWDL rule on two
Macs (WP4); `cpu_bound`, which the helper never reports because it decrypts on one thread. `make
friends-core-rs-cross-check` fails on Windows targets since WP1 added BLAKE3 (its build script wants a C compiler for
the MSVC targets); WP3 did not change it.
## WP4, part 2: minor 4 and files by blocks in the Objective-C helper (2026-10-29)

**The wire** (pushed as 792a6cb4 with build 26102911). Session minor 4, frames 28 to 31, fields 37 to 46, capability
bits, CLOSE reason 6 and the Lane field, with the same gate as the Rust channel: minor-4 frames refused and the tree's
OFFER fields stripped toward any peer without bit 0, and a minor-4 frame received outside a fast session closes it.
`service/transfer/` holds the geometry, the BLAKE3 tree (C, vendored from the crate Cargo.lock pins), block sets,
ranges, sidecars and the SYNC and AGAIN messages. `tools/objc-vectors` writes `fixtures/vectors/transfer/*.json` from
this code in WP1's exact layout, and `friends-vectors-check` compares them byte for byte: **all five files match**.
The helper's own vectors moved to minor 4, so `objc_vectors.rs` and the transcript replay require equal minors again.

**Files by blocks.** `SZFriendsBlockExchange` (transfer area) is the Rust helper's `service/blocks.rs` for one
session: tree in OFFER, Blocks in OFFER_REPLY, HASHES then PARTs, HAVE as blocks check and become durable, ACK after
the publish check, WANT with exactly the missing blocks on every new session, a corrupt block wanted again alone, a
changed snapshot failing before a byte of the changed block leaves. The nearby service and the interop peer both
drive it. The store (`SZFriendsBlockDownloads.m`) keeps the map beside the staging file, preallocates the accepted
size, writes blocks at their offsets, makes them durable in batches (barrier, bitmap, one full flush, then the prefix
in `verified_bytes` for older helpers), re-checks every block a map claims when a download reopens, and publishes
after one read-back computing the tree on every core and the BLAKE2b digest beside it. Staging now hashes the leaves
on every core in the same pass as the digest and writes `outgoing/<id>.tree`, so an OFFER never waits for the tree.
The recovery sweep keeps the sidecars of open transfers, and no longer cuts a download by blocks back to its prefix.
Fast transfers are on unless the settings key `transfers.fast` holds 0 (read as the helper starts) or a test home sets
`SZFRIENDS_TEST_FAST_TRANSFERS=0`.

The late rule of ADR 0018 § 3: a PART for a block already complete, or for a file of that friend's that just ended
here, is dropped; a HAVE for one of our transfers that ended here is dropped; anything naming another transfer closes
the session as unsolicited.

Two faults found by the bench and fixed before landing: a session that ended dropped the partly received blocks of a
download a newer session had already taken over (the Bluetooth silence case stalled); each 60 KiB part was a copy of
its block into a freshly faulted allocation, as costly as encrypting it (parts are now views of the block).

| `make friends-transfer-bench`, by blocks now (one run, other agents' benches running alongside) | Before WP4 | Part 1 | Part 2 |
|---|---|---|---|
| LAN 1 GbE, 2 GiB, Objective-C → Objective-C | 70.5 MB/s, 60 % | 79.6 MB/s, 68 % | 98.4 MB/s, 84 % |
| LAN, 2 GiB, Objective-C → Rust / Rust → Objective-C | 77.2 / 67.7 MB/s | 75.4 / 71.1 MB/s | 106.3 / 99.3 MB/s (90 / 84 %) |
| Loopback, 2 GiB, Objective-C → Objective-C | 199.8 MB/s | 205.4 MB/s | 233.2 MB/s, 3.3 + 3.7 CPU-s/GB |
| Loopback, 2 GiB, Objective-C → Rust | 173.5 MB/s | 183.6 MB/s | 240.2 MB/s |
| LAN cut at half, Objective-C pairs: noticed / moving again | 0.4 to 0.5 s / 1 ms | | 0.003 to 0.005 s / 5 to 8 ms |
| LAN silenced, the three Objective-C pairs | not noticed (Obj-C → Obj-C) | 8.0 s | 8.03 to 8.05 s |
| Bluetooth silenced, Obj-C → Obj-C / Obj-C → Rust / Rust → Obj-C | not noticed / 11.9 / 11.9 s | | 11.6 / 7.3 / 12.0 s |
| Bluetooth 4 MiB cut at half, the three pairs | | | 30.3 s, 79 % of the emulated rate |

The window no longer waits on the disk (HAVE reports checked blocks; durability follows in batches), which is what
lifted LAN from 68 to 84–90 %. What still limits one session is one core per side (the cipher at 0.77 GB/s); lanes
put a transfer on more cores.

**Released apps.** `make friends-transfer-interop` (LAN and Bluetooth, a transfer and a cut at half each): every pair
with a released peer (`pdf/26.10.29-1` Objective-C, `3d/preview-0.2.4` Rust), both ways, negotiates minor 3 and
passes as before; today's Objective-C with today's Rust or Objective-C, both ways, negotiates minor 4 with fast
transfers (`INTEROP_EXPECT_FAST=1`) and passes, resuming by blocks after the cut. `make friends-e2e-check`, two real
helpers: every transfer scenario passes by blocks (kill -9 mid-transfer, Bluetooth then the network mid-file); the
one failure, "two apps, one helper", expects a list subtitle without the "Ben: " prefix that b383ffd2 added, and does
not involve transfers.

**Lanes, the responder's half.** Since the Rust helper now opens lanes (9a62d210), the Objective-C helper admits
them: a session whose IK message 1 carries a Lane token joins the group of the live fast session with the same device
whose handshake hash and a free index (1 to 15, every index compared in constant time) make that token, never races,
pings while it lives, and its frames count as the first session's; any other is closed with CLOSE `LaneRefused`. A
lane ends alone; the first session's end ends its lanes. Without this a Rust helper's lane would have entered the
session race against its own first session.

**A close that lost its CLOSE.** The interop suite's route migration (Objective-C sender, Rust receiver, the old route
throttled to 4 MiB/s) failed one run in two by blocks: after its CLOSE and FIN the network stream cancelled the
connection, the receiver's next HAVE was answered with a reset, and the reset made the throttling proxy drop what it
had not read yet, the CLOSE among it. The stream now reads and drops to the peer's FIN before it lets go (5 s at
most); 8 runs out of 8 pass. HAVEs make this likely; it was possible before with PROGRESS.

**Left for WP4.** Lanes from this side: groups opened here (the LAN, direct Wi-Fi and Bluetooth lanes, one
CBPeripheralManager per L2CAP channel) and the WP2 scheduler spreading blocks across them, mirroring WP3's helper side; Get again and own-device copies by blocks (messages ready, flows not); "Finishing…" while a large
file's check runs (the check runs synchronously on the store queue today); staging and publishing small files in
batches (300 × 10 KiB is unchanged by blocks).

## WP3, third part: lanes in the bench's Rust peer, and the silence and Bluetooth rules measured

- **The interop Rust peer opens and admits lanes** (`szfriends-interop/src/lanes.rs`), as the helper does: `hello`
  says `"lanes": true`, `dial` takes `"lane_of"`, and blocks are given to lanes by WP2's scheduler. WP5's
  multi-route cases now run Rust to Rust. The Objective-C session peer does not say `"lanes"` yet, so its pairs are
  still skipped.
- **A group outlives its first session** (ADR 0018 § 6): `LaneGroup::lane_down` ends a group only with its last live
  lane, and the peer moves the first session's conversation and files to the lowest live lane. The helper still ends
  its group with the first session and redials, as its session table expects; moving it there is open.
- **Silence by hearing.** In the bench a silenced Bluetooth lane went unnoticed by the scheduler for 11 s: the
  proxy (and a deep socket buffer on a real slow path) let the block's parts be "written" at once, so the measured
  round trip became the block's whole 6 s and `silent_after` (3 round trips) 18 s. Both ends ping every second
  while a file moves, so a lane holding blocks that hears nothing for 2.5 s (3.5 s on Bluetooth) is now silent. Also,
  a write counts as progress only while the lane carries parts, not for a PING.
- **Bluetooth beside a faster lane holds one block, not two**, when it needs over a second per block: the second
  one counted in its expected finish and cut it off the transfer early. WP2's scenario table still passes.

`make friends-transfer-bench` with `BENCH_MULTI`, Rust to Rust (load around 5 to 7 from other packages):

| Case | Time | Of what the routes carry together | Of the fastest alone | Per route (MB) |
|---|---|---|---|---|
| LAN 1 GbE + direct Wi-Fi 300 Mbit/s, 1 GiB | 7.9 to 8.2 s | 85 to 88 % | 1.15 | 818 + 257 |
| … direct Wi-Fi cut half-way | 9.0 s | 77 % | 1.01 | 946 + 130 |
| … the LAN (the session's own route) silenced half-way | 19.2 s | 36 % | 0.48 | 401 + 674 (finished on direct Wi-Fi) |
| 10 Mbit/s LAN + Bluetooth, 16 MiB | 13.0 s | 91 to 93 % | 1.03 to 1.06 | 15.7 + 2.1 |
| … Bluetooth cut half-way | 13.5 s | 87 % | 0.99 | 16.8 + 0.9 |
| … Bluetooth silenced half-way | 13.5 s (18.0 s before) | 87 % | 0.99 | 16.8 + 0.9 |
| LAN + direct Wi-Fi + Bluetooth, 1 GiB | 8.0 to 9.1 s | 76 to 87 % | 1.01 to 1.15 | Bluetooth unused at LAN rates |
| … the LAN cut half-way | 18.9 s | 37 % | 0.48 | finished on direct Wi-Fi |

The ADR's "no slower than LAN alone when Bluetooth drops" holds (0.99). Two helpers (`tests/fast_lanes.rs`, links
paced at their routes' rates): 12 MiB over LAN 1 MB/s with Bluetooth 1 MB/s, 13.4 s alone, 7.8 s with lanes; 32 MiB
over 10 Mbit/s LAN, Bluetooth adds 71 % of its 175 KB/s; 96 MiB, 76 %. The remaining gap to 80 % is block
granularity, not overhead: a 1 MiB block takes 6 s on Bluetooth, and the last blocks stay on the faster lane, so a
32 MiB file gives Bluetooth three or four blocks; the share grows with the file. The LAN alone reaches 93 % of its
emulated rate in the same runs, so against what each route delivers alone, Bluetooth adds about 82 %. Smaller blocks on
Bluetooth (the WP6 proposal above) would close it on short files too.

Online data-channel lanes and 8 MiB buffering are not done: they need a data-channel bench with delay first.

## Decision: pieces in WANT and HAVE (2026-10-29, before minor 4 shipped)

The coordinator decided, with the owner's go-ahead to change protocol 4 freely because no released app speaks it, to
bring Bluetooth resume and slow-lane scheduling below the 1 MiB block now rather than in WP6. ADR 0018 § 3 and § 7 have
the rule: **Pieces** (field 47, the Ranges format, counting 16 KiB pieces from the start of the file) in HAVE (pieces
arrived in blocks not yet complete; at least every 256 KiB of a lane's parts, after every PART on Bluetooth) and in
WANT (pieces still missing from partly received blocks; a WANT carries Ranges, Pieces or both). Blocks stay the unit
of the tree, of checking and of durability. Senders schedule 256 KiB slices.

For WP1 (vectors: a WANT with Pieces only, with both, a HAVE with Pieces and Ranges; the WANT rule "at least one of
Ranges and Pieces") and WP4 (a3ffa2ff7a362dcb5, the Objective-C helper: field 47 in both frames, the receiver's
piece HAVEs and WANT, the sender's slices): this section and the ADR are the spec; WP3 builds the Rust side next.

## WP4, part 3: lanes and the scheduler in the Objective-C helper (2026-10-29)

- **WP2's scheduler, ported** (`service/transfer/SZFriendsScheduler.m`, line by line from `scheduler.rs` with
  43062d06's hearing rule and one-block slow lanes) with its simulator (`tests/SZFriendsSchedulerSim.m`).
  `make friends-transfer-check` runs WP2's 19 scenarios from `fixtures/scheduler/scenarios.json`: all pass, with the
  same times and per-route bytes as the Rust table. One port detail: a timer due at exactly `progress_at +
  silent_after` could land a hair early in doubles and fire forever; `tick` adds a nanosecond.
- **Lane groups** (`SZFriendsLaneGroup.m`, as `session/lanes.rs`): odd or even indexes by who dialed, 4 per route and
  8 per group, one session at most on Bluetooth and the relay, tokens compared in constant time, and the group ends
  with its last live lane (the lowest live lane leads once the first session has gone).
- **The exchange spans the group.** `SZFriendsBlockExchange` now takes its lanes' sessions: the scheduler decides
  which lane carries each block, parts are cut per route (16 KiB on Bluetooth) and go out while that session's bulk
  queue is under 4 frames; a PART's HAVE goes back on its lane, and control frames (HASHES, WANT, ACK) go on the first
  session, or on the lane that took over from it. The secure channel reports writes (`onWritten`) and its bulk depth.
- **The nearby service opens lanes** when the scheduler asks: it dials the friend's device on the asked route with a
  reserved token (LAN; direct Wi-Fi only while it keeps the Mac's internet, which AWDL does; Bluetooth through the
  radio, whose every L2CAP channel already has its own CBPeripheralManager), ticks the scheduler every 0.25 s while it
  sends, and closes lanes the scheduler gives up. As in the Rust helper, its group still ends with the first session
  and the next session resumes by WANT.
- **The interop session peer** says `"lanes": true`, dials `"lane_of"`, admits lanes, and when the first session
  closes hands its conversation and files to the lowest live lane, as the Rust peer does. A store test covers the
  hand-over (the first session's route gone after 40 parts; the file finishes on the lane, intact and acknowledged).

`make friends-transfer-bench` with `BENCH_MULTI`, the three Objective-C pairs (one run, other packages' work
alongside; every file intact). Before the hand-over, the LAN-silenced case failed for all three ("not received within
156 s"); the Rust to Rust figures are WP3's above.

| Case | Obj-C → Obj-C | Obj-C → Rust | Rust → Obj-C | Per route (MB) |
|---|---|---|---|---|
| LAN 1 GbE + direct Wi-Fi 300 Mbit/s, 1 GiB | 8.7 s, 80 % | 7.9 s, 87 % | 8.7 s, 80 % | 817 + 258 |
| … direct Wi-Fi cut half-way | 9.9 s | 9.0 s | 10.0 s | 944 + 132 |
| … the LAN (the first session's route) silenced half-way | 20.2 s | 19.3 s | 20.9 s | 400 + 675, noticed at 8.0 s |
| 10 Mbit/s LAN + Bluetooth, 16 MiB | 13.9 s, 85 % | 13.5 s, 87 % | 13.4 s, 88 % | 17 + 2.1 |
| … Bluetooth cut half-way | 13.9 s | 13.5 s | 14.0 s | 17 + 0.9 |
| … Bluetooth silenced half-way | 14.1 s | 13.7 s | 14.0 s | 17 + 0.9 |
| LAN + direct Wi-Fi + Bluetooth, 1 GiB | 8.8 s, 78 % | 12.6 s, 55 % | 10.1 s, 68 % | Bluetooth unused at LAN rates |
| … the LAN cut half-way | 23.7 s | 33.7 s | 22.1 s | finished on direct Wi-Fi |

LAN plus direct Wi-Fi is 1.05 to 1.15 times the LAN alone, as Rust to Rust (1.15). Bluetooth dropping leaves the slow
LAN at 0.95 to 0.99 of its speed alone. The three-route rows vary most between runs (CPU at 8 to 9 s/GB on the
loaded machine); the LAN-silenced case is bound by the session's own 8 s silence limit, as in Rust.

**Pieces on the wire (after 08e49dc9).** Field 47 in WANT and HAVE, WANT valid with Ranges, Pieces or both and
refused with neither, the paired builders and the piece shift: `friends-vectors-check` matches WP1's new
`frames.json` cases byte for byte. Until the sender schedules slices, a WANT's missing pieces are served as their whole
blocks (the receiver drops what it already holds), and a HAVE's Pieces are accepted and not yet used.

**Bytes already here, as 0305ad64 (§ 9.5).** Accepting a file this Mac already received from the same friend (still
where it was saved, at its size, hashing to the offered digest) clones it into the staging file, durable, so the
reply's Offset is the whole file and the sender, released ones included, sends only DONE; never another friend's
file. A new version of a file the same friend sent before (the newest of that name received from them) takes every
block whose leaf matches at the same position once the leaves arrive, reported in a HAVE, so only changed and new
blocks cross. Store tests mirror WP1's (the held copy and none from another friend; a 6 MiB version with one block
changed and one added: two blocks wanted), and `the_same_file_again_rust_to_objc` joins the interop suite.

**"Finishing…" in the Mac helper, as 0c0855b7.** The check before a file received by blocks is saved now runs in three
steps: begun on the store's queue once every block is durable, the whole-file read on a utility queue, then saved (or
deleted and failed) back on the store's queue. Past a second, the row stays Receiving with a full bar and says
"Finishing…" (spoken "…, finishing"), from the catalog strings WP1 added. The map stays until the check completes,
so a helper that stops meanwhile checks again at its next start. A second check of the same file is refused while one
runs. When the session that received the file ended during the check, the ACK goes on the friend's live session.
The interop peer still checks in place.

**The helper's group outlives its first session.** When the conversation's first session closes while one of its
lanes lives, that lane takes the group (the exchange's control lane moves to it) and is adopted as the conversation's
session, which resumes what the first session carried, as a new session would. Without a live lane, or when the first
session lost the race, the lanes end with it as before. Exercised at the exchange level (the store test above) and
through the interop peer's bench runs. No two-helper harness drives Objective-C helpers over lanes yet: the per-route
rate emulation (`SZFRIENDS_TEST_ROUTE_RATES`) is the Rust helper's only.

**The Mac helper answers copies by blocks (AGAIN 4, SYNC 7), and the Rust helper asks for them by default.** A
friend's Get again (AGAIN 4 WANT BLOCKS) gets the same checks as a WANT: one file at a time, a file this Mac sent them,
unchanged. Another of our devices (SYNC 7) gets a file this device holds. The answer is BLOCKS FOLLOW (AGAIN 5 or SYNC
8) with the file's tree at the asked shift, kept per file while it is unchanged. Then come the leaves, and the blocks
asked for as 48 KiB PARTs: each block is read from the file and checked against its leaf, sent while the session's
bulk queue holds fewer than four frames, within 8 MiB not yet in a HAVE. A block that no longer matches answers NONE.
The Rust helper's `copies_by_blocks` is now on unless a test home sets `SZFRIENDS_TEST_COPIES_BY_BLOCKS=0`. The Mac
helper still asks for its own copies by offset, which every helper serves. The tree is hashed on the helper's queue
the first time a file is asked for, as in Rust.

**Copies resume across a restart on the Mac too (as 58cd7d62).** The store's sweep at start keeps `again-<id>` and
`sync-<id>` in `received/.partial` (and any `.map` beside them) while they changed within 30 days, so a copy resumes
from what arrived; an older one goes. A copy given up for good (the friend says the file is gone, or it does not
check) goes at once with its record.

**The Mac helper asks for its own copies by blocks.** On a session with fast transfers, Get again and own-device
copies go by blocks (AGAIN 4, SYNC 7), through `SZFriendsBlockCopy`, a port of `block_copy.rs`. It keeps a map beside
the partial copy, so the next session, or the next start, asks only for the blocks still missing. It takes the whole
blocks of a prefix an earlier copy by offset left, checks each block against its leaf, and checks the whole file
against the BLAKE2b digest before it counts. With a peer without fast transfers (minor 3), copies still go by offset.
In the interop suites against the Rust helper, a probe (since removed) saw the Mac finish both kinds of copy by blocks:
Get again from a Rust friend, and files from a Rust computer of the same profile. The e2e suites (two Mac helpers)
pass with both sides by blocks.

**Pieces and slices in the Mac helper (as ac8317b0).** The Mac sets capability bit 3, so pieces go between it and any
helper that sets it too.
- As receiver: the assembly reports the 16 KiB pieces that arrived whole in blocks not yet complete, in a HAVE on the
  lane that carried them, at least every 256 KiB of parts and after every part on Bluetooth. Partly received blocks
  stay when a session ends. The next WANT names the missing blocks and, inside partly received blocks, the missing
  pieces. To a peer without the bit, those blocks are wanted whole.
- As sender (`SZFriendsSliceSend`, a port of `slices.rs`): the scheduler works in 256 KiB slices. Each block is read and
  checked against its leaf once, then kept (16 at most) for its other slices. A piece acknowledged in a HAVE is never
  sent again.
- WP3's unit cases are ported to the store suite. The two-exchange cut test also runs with pieces on.

**The helper's takeover carries the files' ACKs.** When a lane takes over from the first session, the ACKs of files
sent by blocks that the first session awaited move to the lane, as in Rust. Before this, the friend's ACK arriving on
the lane was dropped and the file stayed "Sending".

Four times as many scheduling units exposed two linear scans in the scheduler port. Picking the next unit walked
every unassigned one looking for an open one, and the unassigned bytes were summed one unit at a time. Together they
took the Mac sender to 16 CPU-s/GB and 60 MB/s. Both now cost what Rust's do, and WP2's table is unchanged, row for row.

`make friends-transfer-bench`, multi-route, pieces on between all three pairs (one run; then 8 more of the two cut
cases):

| Case | Obj-C → Obj-C | Obj-C → Rust | Rust → Obj-C |
|---|---|---|---|
| LAN + direct Wi-Fi, 1 GiB | 105.2 MB/s | 118.3 MB/s | 107.6 MB/s |
| … direct Wi-Fi cut half-way | 73.7 MB/s; 108–110 MB/s in 8 repeats | 107.6 MB/s | failed once (below); 101–110 MB/s in 12 repeats |
| … the LAN silenced half-way | 20.7 s | 19.5 s | 21.4 s |
| 10 Mbit/s LAN + Bluetooth, 16 MiB | 93 % | 95 % | 93 % |
| … Bluetooth cut / silenced half-way | 89 / 90 % | 92 / 92 % | 89 / 89 % |
| LAN + direct Wi-Fi + Bluetooth, 1 GiB | 124.0 MB/s | 136.2 MB/s | 121.5 MB/s |
| … the LAN cut half-way | 19.6 s | 18.8 s | 20.4 s |

Open: one Rust → Objective-C run of the direct-Wi-Fi cut case stalled ("not received within 156 s"). The cut came late
in that run, 7.1 s into a 10 s transfer. The next 12 runs of that case, and 8 more of the three-route cut, passed.
The bench keeps no peer output, so the cause is not known yet. The suspect is the receiver's limit of 64 partly
received blocks: with slices, blocks stay partial longer, and a PART refused at that limit ends the session.

**The Mac's Get again slot, and repeated asks (after 41b62049).** Two Mac-side faults explain the Get again refusals
WP1 saw when the Rust helper pulled small own-device copies from the Mac friend. First, a file served by blocks never
released the friend's one-file-at-a-time slot, so for 60 s any other file was answered "not now"; the slot is now free
once every block is acknowledged, or when the serve ends. Second, a second WANT BLOCKS for a file already being served
replaced that serve, dropping blocks asked for earlier; it now adds to the serve and sends the tree again, as Rust's
servers do since 41b62049. With the Rust helper's `FRIEND_HELPS_FROM` at 0 (it was 8 MiB), the Objective-C Get again
suite fails one case without these fixes and passes all seven with them. All interop suites pass.

**Left for WP4:** the Mac as a requester pulling from several holders (c41d58e8); the stall above; WP6's work. Not tried on two real Macs: the direct Wi-Fi and Bluetooth lanes
are exercised through the bench's emulated routes and the helper's fake channels only.

## WP1, part 2: copies, small files, the check before saving, Finishing and the switch (2026-10-29)

**Numbers** (this Mac, release builds of the bench's Rust peers, `make friends-transfer-bench`):

| | Before | After |
|---|---|---|
| 300 files of 10 KiB, loopback | 12.7 s | 0.46 s (0.50 s after WP2's scheduler landed) |
| 300 files of 10 KiB, emulated LAN | 13.1 s | 0.47 s (0.65 s after WP2's scheduler landed) |
| Staging those 300 files | 6.9 s | 0.10 s |
| Check before saving 1 GiB received by blocks | 0.93 s | 0.12 s |

**What landed:**

- **Store batches** (§ 9.3): a friend's session handles what arrived in one store transaction per pass, savepoint per
  write, one flush per batch; the bytes already read from the links join it; files sent together are staged
  together. A file's name is claimed in the batch's commit before it takes it, then the files move, then one more
  commit records them received; only then are they acknowledged. Joining, own-device sync and strangers keep one
  transaction per write (sync's history deletion runs VACUUM, which no transaction may hold; inside a batch it runs
  right after the commit). Gathering every kind of input into a batch, not only link bytes, stalled the bench peer's
  rekey scenario now and then under load; gathering link bytes only did not, in 8 parallel runs.
- **The digest no longer bounds the check**: it is streamed on its own thread as blocks arrive in order (blocks that
  completed early are read back when the gap fills); only the tree is read back before saving, on every core. Staging
  hashes the tree and the digest in one read, and keeps the tree.
- **Files and blocks already here** (§ 9.5): an offer whose bytes this computer holds from the same friend is filled
  locally at acceptance and answered at its full size, so any sender, released ones included (tested against the
  Objective-C session peer), sends only DONE. A new version of a file the same friend sent takes the blocks whose
  leaves match at the same position.
- **"Finishing…"**: the check runs off the helper's thread; past a second the row says "Finishing…" with a full bar
  (`transfer.finishing`, spoken "…, finishing"), in both catalogs. The apps show `status_label` as the helper writes
  it, so ShenzhenPDF, Shenzhen Files and Shenzhen 3D need no change.
- **`transfers.fast`**: on unless the settings key holds 0, read as the helper starts. None of the apps has an advanced
  Friends settings area, so no toggle.
- **Get again and own-device copies by blocks** (§ 4): AGAIN 4/5 and SYNC 7/8 in the requester, the sync exchange and
  the server; a copy cut off asks the next session for what is missing, and the BLAKE2b digest is checked before the
  file counts. Served whenever a fast session asks; **asked for only behind `SZFRIENDS_TEST_COPIES_BY_BLOCKS=1`**,
  because today's Objective-C helper (minor 4, bit 0) does not answer AGAIN 4 or SYNC 7 yet: with the switch on, the
  interop suites' Get again and own-device cases against it failed. Once WP4 builds them, the default turns on (one
  line in `service/mod.rs`).
- **Pieces** (field 47) on the wire with their vectors; WANT needs Ranges or Pieces.
- **Windows MSVC cross-check**: blake3 compiles assembly and NEON C there, which a Mac cannot; the check now builds
  it with szfriends-core's `blake3-pure` feature, as it links SQLite instead of building it. Release builds leave it
  off. What pure would cost, per core: Arm64 1.34 GB/s instead of 2.49 (below BLAKE2b's 1.66), x86_64 under Rosetta
  2.19 instead of 2.25 and no AVX-512. The Windows VM build (`apps/3d/scripts/friends/tauri-vm.sh`) was not run: the
  "Windows 11" VM is suspended and the script resumes nothing; it compiles BLAKE3's C with MSVC as it does SQLite's.

**Left:** turn on copies by blocks once WP4 answers them; the phone measurement of BLAKE3; a Windows VM run of the
helper build; a resume-after-restart test of copies by blocks across a helper restart (the recovery sweep deletes
`again-*` and `sync-*` partials at start, as before, so their resume holds within a run).

**WP1, copies across a restart.** The Rust store's recovery sweep keeps `again-<id>` and `sync-<id>` staging files and
their maps (they were deleted at every start), so a Get again or own-device copy resumes from what arrived after a
restart; one untouched for 30 days goes, and a copy goes at once when the friend says the file is gone. The
Objective-C helper's sweep needs the same rule once its copies go by blocks (WP4).

## WP3, fourth part: pieces built, and the helper's lane taking over

**Pieces (ADR 0018 § 3), Rust side.** Field 47 in the codec (a WANT with neither Ranges nor Pieces is refused, as
WP1's vector `want_without_ranges` expects); the receiver's assembly reports pieces that arrived and pieces missing;
partly received blocks stay in memory across sessions (no longer dropped when a group ends); HAVE Pieces at least
every 256 KiB of parts, after every part on Bluetooth; WANT names missing blocks and, in partly received blocks,
missing pieces, in one frame. The sender (`transfer/slices.rs`, helper and bench peer) schedules 256 KiB slices,
reads and checks each 1 MiB block once (kept for its other slices), and never sends an acknowledged piece again.

**Capability bit 3, `pieces`** (added to the ADR): Pieces go only to a peer that sets it; to one that does not (the
Objective-C helper until WP4 builds pieces), partly received blocks are wanted whole and the sender schedules whole
blocks, since that peer acknowledges whole blocks only (with slices, a lane holding two slices of a block would wait
for a HAVE that never came: found by the interop suite).

**The helper's lane takes over.** When the first session's route is cut or goes silent while lanes live, the lowest
live lane carries the conversation, its files by blocks and the ACKs they await; what was written on the first session
and not acknowledged goes again on it. A superseded first session still ends its group. Test homes gain
`SZFRIENDS_TEST_ROUTE_SILENCE` (a file naming routes whose links write nothing, as out of range) and
`tests/fast_lanes.rs` silences the network 3 s into 16 MiB: the session closes after 8 s of silence, the Bluetooth
lane takes over, and the file arrives in 17.0 s with no redial.

| Rust to Rust | Before pieces | With pieces |
|---|---|---|
| Bluetooth cut half-way, 4 MiB: sent twice | 1.06 MB | 0 |
| Bluetooth silenced half-way: sent twice | 1.06 MB | 591 bytes |
| LAN cut at 50 MiB of 100: sent twice | 205 KB | 0 |
| 10 Mbit/s LAN + Bluetooth, 16 MiB (bench, of the two routes together) | 91 to 93 % | 96 % |
| … Bluetooth cut or silenced half-way (of LAN alone) | 0.99 | 1.05 |
| Two helpers, 32 MiB, LAN 10 Mbit/s + Bluetooth 175 KB/s: Bluetooth's share of its rate | 71 % | 87 % (target 80 %) |
| Two helpers, 12 MiB, LAN 1 MB/s + Bluetooth 1 MB/s | 7.8 s | 7.2 s |

LAN + direct Wi-Fi at 1 GiB is unchanged (8.2 s); sending CPU rose from about 3.5 to 4.3 to 4.7 CPU-s/GB with four
times as many scheduling units and a HAVE per 256 KiB.

For WP4: the Objective-C helper has field 47 on the wire (2919fcb8); it should also set capability bit 3 once its
receiver sends piece HAVEs and WANTs and its sender honours them: until it does, the Rust side talks to it in whole
blocks (correct, just without piece-level resume). WP1's vectors for Pieces landed with its part 2, and the Rust codec
here is theirs.

## WP3, fifth part: data channels on a delayed, lossy path, measured before adopting 8 MiB

ADR 0018 § 9.9 said "adopted, measured first". The measurement: `szfriends-datachannel-sys/tests/path_bench.rs`
(ignored; `cargo test --release -p szfriends-datachannel-sys --test path_bench -- --ignored --nocapture`), two peers
in one process whose UDP passes a shaper: one-way delay, random loss, a 100 Mbit/s (12.5 MB/s) bottleneck with a
drop-tail queue of 100 ms, as a home router has. `set_sctp_settings` (new, over `rtcSetSctpSettings`) sets usrsctp's
buffers and congestion control; the channel's own buffering is the bench's high-water mark. 32 MiB per run:

| Path | 1 MiB buffers, 1 MiB buffered (today) | 8 MiB and 8 MiB | 8 MiB, H-TCP |
|---|---|---|---|
| 80 ms round trip, no loss | 8.7 MB/s (70 %) | 4.8 MB/s (38 %) | 8.1 MB/s (65 %) |
| 80 ms, 1 % loss | 0.17 MB/s | 0.17 MB/s | 0.06 MB/s |
| 300 ms, no loss | 2.0 MB/s (16 %) | 0.16 MB/s | 0.14 MB/s |

**Not adopted.** Larger buffers let usrsctp's window overshoot the bottleneck's queue, and its recovery from the burst
of losses that follows is slow enough to lose far more than the larger window gains; H-TCP does not fix it. At 1 %
loss every setting sits at what the Mathis bound gives 1,200-byte packets at 80 ms (about 0.18 MB/s). Today's 1 MiB
stays. What would help long paths is pacing in the sender (usrsctp has none) or a second direct route as a lane;
neither is in this package.

**Online lanes are not built either.** More data channels in one peer connection share one SCTP association, so one
congestion window and one path (ADR 0018 § 6 says as much): they would add cores, not bandwidth, and the Rust helper
decrypts on one thread, so it would gain nothing. They remain the ADR's rule for when a helper reports `cpu_bound`.

## WP6: AES-GCM lanes, batched ciphers, compressed parts, a block index and pulls from several holders (2026-10-29)

Protocol 4 has not shipped, so these are additions to it, each behind a handshake capability bit or entirely local.
Measured on the same M5 Max, release builds, with other packages building alongside (load 11 to 21): wall-clock
figures move by 30 % or more from run to run; the in-process channel figures and the bytes on the route much less.

**1. AES-256-GCM lanes (capability bit 1, ADR 0018 § 9.2).** A side sets bit 1 when its processor has hardware AES
(ARMv8 AES and PMULL, or AES-NI and PCLMULQDQ). When both first handshakes set it, every lane of that group runs
`Noise_IK_25519_AESGCM_BLAKE2b`; the first session stays ChaChaPoly, so released apps see nothing new. The initiator
names the cipher in the preamble, bit 7 of the pattern byte (`SZ 01 81`, IK only), so the responder knows the protocol
name before message 1, and the prologue binds it (a flipped bit fails the handshake: tested both ways). A responder
without bit 1 refuses that preamble before any Diffie-Hellman; an AES-GCM session without a Lane token is refused; a
lane is admitted only into a group whose first session agreed to bit 1 (helper and interop peer).
`SZFRIENDS_TEST_AES_LANES=0` plays a side without it.

Why it pays here: profiling the Rust peers on loopback (`sample`, symbols on) showed the session cipher as about 70 %
of the sender's busy time, and within it Poly1305 runs its portable code on arm64 (the `poly1305` crate has no NEON
backend), so ChaCha20-Poly1305 tops out at 0.75 GB/s while AES-GCM uses the ARMv8 AES and PMULL instructions:

| One core, 60 KiB frames (`examples/transport-speed`) | Seal | Open |
|---|---|---|
| ChaCha20-Poly1305 | 745 MB/s | 683 MB/s |
| AES-256-GCM | 1,925 MB/s | 1,948 MB/s |

**2. Batched sealing and opening.** `Transport` now counts its own nonces over snow's stateless transport, so a batch
of messages is sealed or opened on up to four cores with exactly the nonces one at a time would use
(`encrypt_many`, `decrypt_many`; a batch stops after a REKEY, whose successors need the new key, and at the first
failure, whose nonce stays unused). The channel seals the bulk frames that fit its in-flight budget together and hands
them to the link as one write (while writes are on the link, bulk frames wait until two fit); on receipt it opens every
complete message a read delivered together. Link reads grew from 64 to 256 KiB so a read holds several messages.
`ChannelConfig::crypto_batches` turns it off. One session through the channel, in one process (`examples/
channel_speed`, both ends on one thread, best of five, CPU time of the process):

| 1 GiB of 60 KiB PARTs | One at a time | Batches |
|---|---|---|
| ChaCha20-Poly1305 | 349 MB/s, 2.86 CPU-s/GB | 470 MB/s, 3.47 CPU-s/GB |
| AES-256-GCM | 448 MB/s, 1.81 CPU-s/GB | 1,031 MB/s, 1.58 CPU-s/GB |

Kept: AES-GCM with batches moves 2.3 times what ChaChaPoly one at a time moved through the same channel, on less
CPU. With ChaChaPoly batches cost a fifth more CPU for a third more speed: kept too, since a first session is never
AES and the extra CPU is spent only while a transfer is limited by this computer.

Through `make friends-transfer-bench` (Rust to Rust, 2 GiB, four interleaved rounds of main at 16b2f89b, WP6 with
`SZFRIENDS_TEST_AES_LANES=0`, and WP6; `loopback+loopback` is a new multi case, the session and one lane both on
loopback), the machine was too loaded to tell them apart (load 16 to 25 from other packages' builds): the same build
ranged 59 to 200 MB/s between rounds. Best rounds: one session 200 (main), 179 (WP6 without AES lanes), 137 MB/s
(WP6); session and lane 170, 216 and 182 MB/s, the lane AES-GCM in every WP6 round. So the gain is shown by the
channel measurement above, not yet end to end; the case should be run again on an idle machine
(`BENCH_ROUTES=loopback BENCH_SIZES=2g BENCH_LOSS=none BENCH_MULTI=loopback+loopback`, and the same with
`SZFRIENDS_TEST_AES_LANES=0`). In the peers both lanes share one thread, so the end-to-end gain is bounded by the
leaf checks, the digest and the disk on that thread, which batches do not touch.

**3. Compressed parts (capability bits 2 and 4, ADR 0018 § 9.4).** zstd 1.5.7 (the `zstd` crate, C, level 1, no
legacy formats or dictionary builder; Codec 1, bit 2) on Bluetooth and relay lanes, and LZ4's block format
(`lz4_flex`, pure Rust, safe code only; Codec 2, bit 4) on Bluetooth lanes, for Android (below). A pair uses zstd when
both read it, else LZ4. Per block a 64 KiB sample decides (at least 10 % saved),
so photos, video and archives cost one sample; each part is then compressed on its own and goes plain when it would not
shrink. On the relay every compressed part is padded to a multiple of 8 KiB with a zstd skippable frame, so the relay
sees one of seven sizes per 60 KiB part, not exact ratios (ADR § 8 says what it can still tell). The receiver expands a
part only in a codec its session negotiated (that codec's bit on both sides), into at most Length bytes (zstd's
window at most 128 KiB), and refuses it
unless it expands to exactly Length; anything else closes the session as a malformed part.

Ratios on typical files (one core, `zstd` level 1 against the pure-Rust `ruzstd` the C library won over; speeds of
the full-speed build, while the size-optimised build that ships compresses STEP at 246 to 322 MB/s and Markdown at 122
to 153 MB/s, and expands them at 861 and 646 MB/s, still hundreds of times the Bluetooth and relay rates):

| File | Size | 16 KiB parts (Bluetooth) | 60 KiB parts (relay) | ruzstd, 16 KiB |
|---|---|---|---|---|
| STEP assembly | 5.4 MB | 17 % of the bytes, 730 MB/s | 15 %, 950 MB/s | 26 %, 160 MB/s |
| Markdown | 70 KB | 45 % | 43 % | 51 % |
| PDF (drawings) | 1.3 MB | 64 % | 65 % | 65 % |
| PDF (report with photos) | 1.1 MB | 90 % | 91 % | 91 % |
| JPEG, PNG | 3.9, 1.0 MB | 99 to 100 % (sent plain after the sample) | | |

`make friends-transfer-bench` with `BENCH_CORPUS` (new: a directory of real files instead of pseudo-random bytes),
Rust to Rust, `SZFRIENDS_TEST_COMPRESSED_PARTS=0` for before:

| Case | Before | After | On the route |
|---|---|---|---|
| Bluetooth (1.4 Mbit/s), 4 MiB of STEP | 24.1 s | 4.7 s (5.2×) | 4.21 → 0.80 MB |
| Bluetooth, 4 MiB of Markdown | 24.2 s | 10.1 s (2.4×) | 4.21 → 1.74 MB |
| Bluetooth, 4 MiB of PDFs | 24.1 s | 21.1 s (1.14×) | 4.21 → 3.67 MB |
| Bluetooth, 4 MiB of photos | 24.2 s | 24.2 s | unchanged |
| Relay (5 Mbit/s), 16 MiB mix (photos, Markdown, PDFs, STEP) | 27.1 s | 19.4 s (1.4×) | 16.8 → 12.0 MB (11.4 unpadded) |

The same with LZ4 (`SZFRIENDS_TEST_ZSTD=0`, a pair with an Android phone): Bluetooth 4 MiB of STEP 8.6 s (2.8×, 1.49 MB
on the route), Markdown 14.3 s (1.7×), PDFs 21.3 s (1.14×), photos 24.1 s; the relay plain (27.1 s). LZ4 ratios on
the files above: STEP 33 % of the bytes in 16 KiB parts, Markdown 58 to 65 %, PDFs 66 and 92 %, at 800 MB/s and more.

**4. A block index (ADR 0018 § 9.5).** WP1 (0305ad64) takes unchanged blocks from the newest file of the same name
the same friend sent. WP6 adds `store/block_index.rs`: one small file per file received by blocks or sent to a friend
(`blocks-index/<friend prefix>-<transfer>.leaves`: where the file is, its shift and leaves), the newest 1,024 files and
64 MiB at most, 0600, never sent. The prefix is 8 bytes of BLAKE2b over the conversation id, so a lookup reads only
that friend's entries and the directory names nobody. After WP1's same-name pass, the blocks still missing whose leaf
any of that friend's indexed files holds at the same position are read there and taken through `block_part`, so each
is checked against the new leaf and reported in the next HAVE. Files this person sent that friend count too (the file
they chose, from the row's `source_path`), for a model sent, edited by the friend and sent back. An entry whose file
is gone is dropped; a block changed since fails its leaf and is asked for. The scheduler now also stops the rest of a
copy when a HAVE names a block none of whose copies was sent whole (it came from elsewhere): before, the first window
of a reused block still went out on its lane.

**5. Pulls from several holders (ADR 0018 § 9.6).** `transfer/pull.rs`: the receiver drives WP2's scheduler with
each device that holds the file (the same root in BLOCKS FOLLOW) as a lane. A block the scheduler gives a holder is
asked of it (one WANT BLOCKS per holder per round); a block that completes is credited to the holder whose part
completed it (`sent` then `have`, which measures its rate); a copy the scheduler cancels becomes a HAVE to that holder,
so it drops what it has not sent; a holder whose session ends or falls silent gives its blocks back; the endgame asks a
second holder only when it would finish sooner. The scheduler's lane requests do not apply to holders. Simulated
(virtual time; each holder serves what it is asked, in order, at its rate, after its delay each way):

| Holders | Time | Against |
|---|---|---|
| 256 MiB from three LAN holders at 40, 20 and 10 MB/s | 4.15 s (143, 75 and 38 blocks) | 3.83 s at their sum, 6.71 s from the fastest alone |
| 256 MiB from two at 40 MB/s, one gone after 1 s | 6.44 s | 6.71 s from one alone |
| 32 MiB from a Mac at 2 MB/s and a phone on Bluetooth | 16.9 s (Bluetooth took one block) | 16.8 s from the Mac alone |

**Size on phones, and why Android compresses with LZ4** (`tools/embedded-size.sh`, Android arm64 with online, main at
d2b92b6b, after 06e8c112 brought it to 4.90 MB): with zstd, 5.08 MB, over ADR 0015's 5 MB; zstd's decoder alone (no
compressing on Android), 4.98 MB; LZ4 in place of zstd on Android, **4.95 MB** (+54 KB for all of WP6: AES-GCM lanes,
batches, the index, the pull planner and LZ4; deflated 2.59 → 2.62 MB, nearby only 3.15 → 3.21 MB). Per byte of
library LZ4 gives the most: about half zstd's gain, in both directions, against zstd's decoder for 21 KB more and a
gain only when the phone receives. So Android sets bit 4 alone; desktops and iPhones (iOS with online 3.32 MB) read
and write both. zstd is built with its size-optimised options (`thin`: -Oz and the small decoders; 0.35 MB without).
Leaving zstd's unused block compressors out through phone.toml's CFLAGS saved only 38 KB and would reach every C
library a phone build compiles, so it was not kept. Shenzhen 3D's own `phones-size.sh` check, still over before this
package, is 54 KB further from its budget.

**For WP4 (Objective-C) to mirror** (the Rust core is the reference; frames and bits must match, tuning may differ):

1. Capability bits: bit 1 when `crypto_aead_aes256gcm_is_available()`, bits 2 and 4 with fast transfers; a test home's
   `SZFRIENDS_TEST_AES_LANES=0` and `SZFRIENDS_TEST_COMPRESSED_PARTS=0` clear them (the session peer too, so the bench
   measures before and after). Until then a Rust peer simply never uses either with the Mac helper.
2. `Noise_IK_25519_AESGCM_BLAKE2b` in `szfriends_noise`: AES-256-GCM with the 96-bit nonce 4 zero bytes then the
   counter big-endian (libsodium's `crypto_aead_aes256gcm_*`, the precomputed-key form for speed), REKEY as the Noise
   spec has it (encrypt 32 zero bytes at nonce 2^64-1, keep the first 32). The preamble: pattern byte 0x81 is IK with
   AES-GCM; 0x80, 0x82 and 0x83 are refused; a responder without bit 1 refuses 0x81 at the preamble (before any DH, as
   XX on a hidden listener); an AES-GCM session without a Lane token is refused; lanes are dialed with 0x81 when the
   group's first session negotiated bit 1 on both sides, and an AES-GCM lane is admitted only into such a group. The
   exporter writes `fixtures/vectors/transfer-more/aes_lane.json` (the IK vector's keys and payloads with the 0x81
   preamble); `friends-vectors-check` then compares it byte for byte.
3. Batches (local tuning, not wire): sealing the bulk frames that fit the in-flight budget, and opening the messages one
   read delivered, together with explicit nonces (`dispatch_apply`), stopping a batch at a REKEY.
4. Compressed parts: zstd 1.5.7 vendored by `friends/deps` (lib/common, compress, decompress; no legacy), and LZ4's
   block format from Apple's own libcompression (`COMPRESSION_LZ4_RAW`), so bits 2 and 4. The codec: zstd when both
   set bit 2, else LZ4 when both set bit 4; LZ4 on Bluetooth lanes only, unpadded. Sender, on a Bluetooth or relay
   lane of a session with zstd: per block, level 1 on its first 64 KiB; when that is at most 90 %,
   each part compressed alone and sent with Codec 1 and Length when smaller; on the relay, padded with a skippable
   frame (magic 0x184D2A50 little-endian, then the filler's length as u32 little-endian) to the next multiple of 8,192
   bytes, and sent plain when that is not smaller. Receiver: a part with Codec or Length in a codec the session did not
   negotiate (its bit on both sides), Codec other than 1 or 2, Length missing, 0 or over 61,440, or Data that does not expand to exactly Length (decoder window
   at most 2^17) closes the session as an unsolicited part. The helper's tests read
   `fixtures/vectors/transfer-more/compressed_parts.json` (each case: an encoded PART and what it expands to, or
   "refused"); it is not exported, since zstd's bytes depend on its version.
5. The block index is local, so its format is the Mac helper's own; the rules are the ones above: per friend, files
   received by blocks and files sent to them, bounded, checked through the ordinary part path, never sent.
6. The scheduler: a HAVE for a block none of whose copies was sent whole cancels every copy, the winner's too.
7. Pulls from several holders, when the Mac helper's copies by blocks ask more than one session.

**Left.** Wiring `transfer/pull.rs` into the requesters: WP1's Get again and own-device copies (5854050c) ask one
session per copy; asking every session that holds the same root (the friend's devices, the person's own) needs their
requesters to keep several sessions per copy, with `Pull` saying which blocks each is asked for. That touches the
flows WP1 is still changing, so it is left to WP1 with the planner and its tests in place. Real devices: none of this
was run on radios or two machines; `tools/transfer-devices.sh` runs the same peers there.

## WP1 with WP6's planner: copies from every holder at once (2026-10-29)

The Rust helper's Get again and own-device copies now pull one file from every live fast session that holds it
(`service/pulls.rs` driving `transfer::pull`): the person's other devices by SYNC 7/8 and the friend who sent it by
AGAIN 4/5 (for copies between own devices only from 8 MiB: small files gain nothing from a second holder, and the
interop suites showed the Objective-C friend answering a later Get again "not now" when its budget had gone to such
asks). Holders serve a copy by blocks only after checking their bytes against the digest, so a stale version answers
NONE and is left out. Copies stay block-level (WANT BLOCKS carries no pieces); a holder that leaves gives its blocks
back to the others, and the copy resumes from its map after a cut or a restart.

Measured with `tests/pulls.rs` (three Rust helpers in one process on loopback, release dependencies, debug test
code), 256 MiB, two runs each:

| Case | Seconds | Blocks served |
|---|---|---|
| Two holders (own device, friend) | 1.18 to 1.30 | 100 to 150 each |
| The own device's copy stale | 1.39 to 1.51 | friend 256, own device left out |
| The own device gone at 25 % | 1.41 to 1.52 | friend about 240 after the drop |

On loopback every holder shares this Mac's cores, so two holders gain only about 15 % over one; the gain the
planner's simulation predicts (WP6: 4.15 s for three LAN holders against 6.71 s from the fastest alone) needs holders
on separate devices and routes. `make friends-core-rs-interop-check` passes with the Objective-C helper asking and
serving copies by blocks (WP4).

**Order of pulls.** A Get again the person asked for starts before copies between own devices waiting in line, and
pre-empts a copy that runs by itself (the copy keeps what arrived and resumes after); a copy the person asked for
with Get is not pre-empted.

**For WP4: the Objective-C helper refuses a later Get again after small own-device asks.** When the Rust helper asked
the Objective-C friend for small files (180 KB) by AGAIN 4 as an extra holder of copies between the person's own
devices, the friend answered the person's own Get again of a file a few seconds later with NONE "not now"
(`objc_again`'s `a_friends_file_comes_back_from_either_computer_then_from_an_objc_friend`, 4 of 4 runs), apparently
counting those asks against its one-file-at-a-time or checks-an-hour budget even after every block was acknowledged
by HAVE. The Rust pull therefore asks the friend for own-device copies only from 8 MiB (`FRIEND_HELPS_FROM` in
`service/pulls.rs`). Once the Mac side releases its budget when a copy's blocks are all acknowledged (or does not count
asks for files the person's own devices also hold), the threshold can drop to 0.

## Wi-Fi Direct boost (ADR 0019, 2026-10-29)

**The owner's change of rule.** When two devices found each other by Bluetooth only, and are verified not to be on
the same network, a Wi-Fi Direct link may be negotiated; a device already on a Wi-Fi network asks before it leaves it,
and reconnects it at the end. Until now direct Wi-Fi was never allowed to cost a device its Internet connection. Now
it may, only after the person said Go faster on that device, for that transfer, and the device rejoins its network by
itself; without that answer the old rule holds. Multi-band concurrent Wi-Fi was rejected by the owner and is not used.
ADR 0011, 0015, 0018, PROTOCOL.md and the code comments say so now.

**What landed.**

- `szfriends-wire`: BOOST (frame 32), fields 48 to 53 (Step, Abilities, Network, Passphrase, Address, Port), capability
  bit 5; the channel sends and accepts BOOST only on a fast session where both set it. Vectors `boost_*` in
  `fixtures/vectors/transfer/frames.json`, written by the Rust core and reproduced byte for byte by the Objective-C
  exporter (`friends-vectors-check`).
- `szfriends-core/src/transfer/boost.rs`: when (Bluetooth alone for 10 s with the device nowhere on the network, or 3
  lane dials there failed; at least 20 s saved at the measured Bluetooth rate against 8 MB/s plus 15 s of setup), who
  hosts (fewer devices off their Wi-Fi, then key order), who is asked (only a device whose Wi-Fi is its only way
  online), the negotiation (PROPOSE, READY, HOST, END, DECLINE), never slower (6 s after the lane is up it must beat
  Bluetooth), and Rejoin (the record written before leaving, 3 tries 3 s apart, an online check every 2 s for 20 s,
  the person told otherwise; a crash record brings the device back at the next launch).
- Rust helper (`service/boost.rs`, `nearby/direct_wifi.rs`): watches groups, carries BOOST, hosts behind a listener of
  its own on the link, joins and dials the link's lane as an ordinary lane of the group (the token binds it to the
  Bluetooth session), keeps it in the scheduler only while the boost lasts (`allow_direct_wifi`), and the way back.
- Phones: Android 13 and later hosts and joins (`DirectWifi.kt`, `NEARBY_WIFI_DEVICES` asked with Bluetooth's);
  iPhone joins (`DirectWifi.swift`, `NEHotspotConfiguration`), gated on the Hotspot Configuration entitlement.
- Mac (Objective-C helper): the same decisions and negotiation (`SZFriendsDirectWiFiBoost`), the coordinator, CoreWLAN
  joining (`SZFriendsCoreWLANWiFi`, Location Services for names, asked after Go faster), the lane dialed to the host's
  address through Network.framework, presentation and intents. Never created in a test home.
- Client protocol: `boost_transfer` and `skip_boost`, client capability `transfers.boost` (AppKit views, Shenzhen 3D's
  panel, the C client, the Tauri validator); the question is the transfer's note with Go faster and Not now.

**The words** (a Mac on its only Wi-Fi, a phone sending 100 MB over Bluetooth):

> Go faster? Mei isn’t on your Wi-Fi, so this is going over Bluetooth (about 12 min). Leave “HomeWiFi” for about 30 s
> to connect to Mei directly. Your computer rejoins it by itself when it’s done.
>
> **Go faster** · Not now

Then "Connecting directly to Mei…", "Going directly over Wi-Fi. Your computer rejoins “HomeWiFi” when it’s done.",
"Rejoining “HomeWiFi”…", and only if it did not: "Your computer didn’t get back on “HomeWiFi” by itself. Choose it in the
Wi-Fi menu." A phone on mobile data is not asked: "Going directly over Wi-Fi. Your phone stays online over mobile data
meanwhile, and rejoins your Wi-Fi when it’s done." An iPhone's question ends "Then choose Join." (iOS asks again).
"Always for Mei" is not offered: it needs a switch in Mei's details to undo it, a separate change.

**What was exercised, and how.**

| Where | Real or mocked | Result |
|---|---|---|
| Rust core | unit tests (26) | decisions, roles, cost, links, frames, negotiation incl. crossing proposals and a hostile HOST, Rejoin incl. crash recovery |
| Two Rust helpers, test Bluetooth air at 150 kB/s, a pretend radio on loopback (`tests/direct_wifi_boost.rs`) | real sessions, lanes and scheduler; mocked radio | 10 MiB: proposed after 10 s on Bluetooth, asked on the side that would lose its only Wi-Fi only, Go faster, lane up about 3 s later, file whole about 15 s after the offer (about 70 s over Bluetooth alone); back on "HomeWiFi" and record deleted; Not now final; a crash record brings the device back at launch |
| Objective-C helper (`friends-transfer-check`) | mocked Wi-Fi; CoreWLAN never linked into the test | the same decisions and vectors byte for byte, the negotiation, Rejoin, the coordinator joining, dialing, ending and coming back, a crash record at launch, Not now |
| Headless Android 16 emulator (API 36), a probe app making DirectWifi.kt's calls | real API | `createGroup` with our name and passphrase formed `DIRECT-…` at 192.168.49.1 on `p2p-wlan0-0`, 2437 MHz like the station; a listener bound there; the emulator's Wi-Fi stayed validated throughout and after `removeGroup`; `isStaApConcurrencySupported` false, hence the learned flag |
| Android joining | not exercised | one emulator cannot join its own group, and two emulators share no radio |
| DirectWifi.kt in the app | compiled | in the app's Gradle project (`compileDebugKotlin`); the app itself was not built or run |
| iOS | type-checked | the plugin's Rust and Swift for `aarch64-apple-ios`; not run (the entitlement is the owner's step) |
| Mac CoreWLAN | built and linked only | never run: no test touches this Mac's Wi-Fi |
| Windows | nothing to exercise | no Bluetooth route on Windows, so the trigger cannot fire there; the VM was not used |

**Owner actions.**

- iPhone: add the Hotspot Configuration capability to Shenzhen 3D's identifier and profile, then add
  `com.apple.developer.networking.HotspotConfiguration` to `shenzhen-3d_iOS.entitlements` and `SZFriendsDirectWifiJoin`
  (true) to the app's Info.plist in the same change. Until then iPhones never take part.
- Android phones that granted Bluetooth before this release are asked for "Nearby devices" again only when Friends
  asks for Bluetooth again; until then they take no part.

**Real-device script** (the owner's Android phone and a Mac; then an iPhone once entitled; nothing here runs from an
agent):

```sh
# 1. Builds: Shenzhen 3D debug on the phone (Android 13 or later), ShenzhenPDF from this commit on the Mac.
# 2. Put them on different networks: the Mac on its usual Wi-Fi; the phone's Wi-Fi off, mobile data on. Bluetooth on.
#    Friends open on both; they show each other "Nearby, over Bluetooth".
# 3. Logs:
log stream --style compact --predicate 'process == "Shenzhen Friends"' | grep -i "direct Wi-Fi"   # Mac
adb logcat | grep -i "direct Wi-Fi"                                                               # phone
# 4. Send a 100 MB file from the phone to the Mac. After about 10 s the Mac's row asks "Go faster? …".
#    Choose Go faster. The first time, macOS asks for Location Services for Shenzhen Friends: Allow.
#    Expect "the lane is up" in both logs, the row "Going directly over Wi-Fi…", and the file in well under a minute.
# 5. After it arrives: the Mac is back on its network and online.
networksetup -getairportnetwork en0
#    Check System Settings > Wi-Fi > Known Networks for a "DIRECT-…" entry (whether CoreWLAN kept the link) and note it.
# 6. Crash: start another 100 MB transfer, choose Go faster, and while the row says "Going directly…" force-quit
#    "Shenzhen Friends" in Activity Monitor. Open ShenzhenPDF again: the Mac rejoins its network within seconds and
#    ~/Library/Application\ Support/Shenzhen\ Friends/direct-wifi.json is gone.
# 7. Not now: another transfer, choose Not now: it carries on over Bluetooth and is not asked again.
# 8. Other way round: send 100 MB from the Mac to the phone; same question on the Mac.
# 9. Two Android phones on different networks: neither is asked if both keep their Wi-Fi; the file goes direct.
# 10. iPhone (once entitled): from the Android phone to the iPhone; the iPhone asks, then iOS asks to join.
```

**Left.** "Always for Mei" with its switch in a friend's details; Linux hosting through NetworkManager; joining tried
on two real Android phones and with an iPhone; Known Networks after a Mac's join; a release that carries ADR 0019 on
both helpers (capability bit 5 is off until a helper has a Wi-Fi to use, so mixed pairs never see BOOST).

## Never slower with Bluetooth than without (2026-10-29)

The owner's rule, about the slow network with Bluetooth: "Is it slower than without bluetooth? Then don't do it." A
transfer with an extra lane must never end later than on its best lane alone: in steady state, with the extra lane
going out of range or silent at any moment, flapping, or too slow to matter, and at the end of the transfer.

**Why the table could not see it.** In both simulators a write completed only as its part crossed the route, so a
lane that went out of range stopped writing at once and its block looked late. Real paths do not: the socket's
buffer (and the bench's proxy) takes a 256 KiB slice at once, so the slice looks all written and its HAVE due within a
round trip. If that lane then went quiet, the endgame's estimate said the slice was about to land, so the LAN, with
nothing else to send, waited until the silence was noticed (2 to 3.5 s on Bluetooth). Both simulators now model the
sender's socket buffer (`buffer_kib` on a lane: a write completes when its part is in the buffer) and schedule 256 KiB
slices as the helpers do (`unit_kib`). With them, the old scheduler loses up to 26 % with Bluetooth flapping, and
15 % with Bluetooth going out of range in the last quarter of the transfer; with whole blocks and no buffers, which is
all the table had, it never lost.

**What changed** (`transfer/scheduler.rs` and `SZFriendsScheduler.m`, line for line):

- **The fastest lane never waits on another.** In the endgame (nothing unassigned) the fastest lane takes a second copy
  of a slice another lane holds whatever it expects to gain: it has nothing else to send, so the copy costs no time,
  and the transfer ends no later than the fastest lane alone could end it. The first copy to complete wins; pieces
  already acknowledged are not sent again. Other lanes keep the old rule (a copy only when it gains more than a round
  trip).
- **A lane under 3 % of the fastest carries nothing** (`HELPS_FROM_SHARE`). Bluetooth at 1 % of the LAN gets one slice
  to measure itself and then nothing; at 5 % it adds 2 %.
- **A lane slower than the fastest holds at most what the fastest sends in a second** (one slice at least), so what a
  lost lane leaves to send again is small. Bluetooth already held one slice beside a slow LAN; this bounds faster
  extra lanes too.

Not done, and why:

- *Give the extra lane the slices the LAN would reach last.* With the first rule, where the extra lane's slices lie
  no longer changes when the transfer ends: the LAN copies whatever is still out once it runs out of work. Keeping the
  order keeps the receiver's writes and its partly received blocks together.
- *Copy an extra lane's slices onto the LAN as soon as it goes quiet, before the silence timeout.* Before the end the
  LAN is busy with slices it would send anyway, so an early copy only reorders its work and wastes Bluetooth's if the
  lane comes back (flapping). At the end the first rule copies at once, which is the moment that matters.
- *A CPU rule.* Bluetooth only takes slices beside lanes measuring under 4 MB/s in all, and the relay only when
  nothing else works, so the lanes that compress (zstd level 1, hundreds of MB/s) never sit beside a lane the CPU
  limits: at Bluetooth's 175 KB/s, compressing costs well under 1 % of one core. The bench measures no difference in
  the sender's CPU per GB with Bluetooth or without (5.4 to 7.2 s/GB either way, the resolution of `ps` over a 13 s
  run). Nothing reports `cpu_bound` today; if a phone driver ever does, that is where such a rule would go.

**The table** (`friends/fixtures/scheduler/scenarios.json`): a new expectation, `max_of_alone`, runs each lane of the
scenario alone (up from the start, with its silences, flapping or cut) and requires the transfer to end no later than
the best of them; every multi-lane row now has it except the two where a rule keeps the faster route unused on
purpose (direct Wi-Fi without its own network, the relay coming first). New rows mirror the bench: 16 MiB over a
10 Mbit/s LAN beside Bluetooth, with slices and socket buffers (LAN 128 KiB, Bluetooth 256 KiB). Both simulators give
the same table, row for row. "Of the LAN alone" is time alone over time with Bluetooth: 1.000 or more is never slower.

| Scenario (16 MiB, 10 Mbit/s LAN) | Before | After |
|---|---|---|
| Bluetooth 1.4 Mbit/s throughout | 1.103 | 1.103 |
| … out of range at 10 % / 50 % / 90 % | 1.000 / 1.067 / 1.103 | 1.000 / 1.067 / 1.103 |
| … flapping (out 1.9 s of every 2.4 s) | **0.744** | 1.016 |
| … flapping fast (out 0.5 s of every 1 s) | 1.032 | 1.032 |
| … at 5 % of the LAN, out of range at 90 % | **0.854** | 1.016 |
| … at 1 % / 5 % / 20 % of the LAN | 1.000 / 1.032 / 1.164 | 1.000 / 1.032 / 1.164 |
| … connected and silent from the start | 1.000 | 1.000 |

The older rows are unchanged but for "two lanes on the lan", which now sends 0.4 MiB twice (the endgame's copies)
in the same 1.08 s. A property test (`sim.rs`, `bluetooth_never_makes_a_transfer_slower_than_the_lan_alone`) puts
Bluetooth at 1, 5, 14 and 20 % of the LAN going out of range, cut, or flapping (periods of 1 to 4 s) at every quarter
second of the transfer, with whole blocks and with slices: the transfer never ends later than on the LAN alone. The old
scheduler fails it at 0.25 s.

**On the bench** (`make friends-transfer-bench` with the new `BENCH_MULTI` cases: `slowlan` alone, then Bluetooth
beside it; 16 MiB over 10 Mbit/s with Bluetooth's 175 KB/s; three runs of each, before and after interleaved). Each
figure is the median of the LAN alone's time over the case's time, worst run in brackets:

| Case | Rust → Rust | Rust → Objective-C | Objective-C → Rust |
|---|---|---|---|
| Bluetooth throughout | 1.102 (1.100) | 1.101 (1.097) | 1.103 (1.102) |
| … out of range at 10 % of the bytes | 1.009 (1.006) | 1.008 (1.000) | 1.007 (1.006) |
| … at 50 % | 1.057 (1.055) | 1.057 (1.051) | 1.059 (1.051) |
| … at 90 % | 1.100 (1.096) | 1.096 (1.091) | 1.099 (1.095) |
| … flapping, up 0.6 s and out 1.8 s | 1.016 (1.014) | 1.020 (1.013) | 1.019 (0.999) |
| … flapping, up 0.5 s and out 1.9 s | 1.014 (1.014) | 1.015 (1.015) | 1.003 (1.001) |
| … connected and silent from the start | 1.000 (0.998) | 0.999 (0.998) | 1.001 (0.998) |
| Bluetooth at 1 % of the LAN | 0.999 (0.997) | 0.997 (0.995) | 1.000 (0.992) |
| … at 5 % | 1.022 (1.018) | 1.022 (1.020) | 1.021 (1.019) |
| … at 5 %, out of range at 90 % | 1.020 (1.019) | 1.022 (1.020) | 1.019 (1.019) |
| … at 20 % | 1.163 (1.162) | 1.164 (1.156) | 1.163 (1.163) |

The LAN alone takes 13.48 s Rust to Rust (99.6 % of its 1.25 MB/s), 13.50 s from Objective-C. Every case is within
1 % of the LAN alone or faster; the worst single run is 0.992 (0.1 s in 13.5 s: Bluetooth at 1 % of the LAN, whose
one slice to measure itself the LAN sends again at the end). The old scheduler gives the same medians on the bench,
within 0.01: these runs did not land in the windows the simulator finds (silences start at a count of bytes, flapping
at the lane's connection, and the proxy buffers less than the 256 KiB modelled). So the bench confirms nothing got
slower, and the simulator's sweep shows the windows closed.

**Found on the way, for WP4 and whoever owns the Objective-C receiver: Rust → Objective-C sends 0.5 MB twice in
about half the runs, Bluetooth or not.** In those runs the LAN carries 17,303,203 bytes instead of 16,794,831 for the
same 16 MiB (two slices' worth again), and the transfer takes 13.92 s instead of 13.52 s, 3 % slower. It happens with
the LAN alone too, before and after this change, and never Rust to Rust or Objective-C to Rust. It looks like the
Objective-C receiver wanting slices again that were already in flight (a second WANT, or pieces not acknowledged). The
"0.95 to 0.99 of the LAN alone" recorded earlier for Bluetooth dropping is this resend plus a comparison with the
LAN's nominal rate; measured like for like (runs with the resend against the LAN alone with it), Bluetooth dropping
leaves Rust → Objective-C at 1.000 to 1.096. Not chased here: the Objective-C helper's exchange is another agent's
area today (the rare stall and copies from several holders).

Checks: `cargo test -p szfriends-core` (the scheduler's units, the table, the sweep, 150 random scenarios),
`make friends-transfer-check` (the same table through the Objective-C port, identical row for row),
`make friends-store-check`, and `szfriends-interop`'s `fast_lanes` and `fast_transfers`.

## The You row while a copy goes by blocks (Rust helper)

After 18e999d8 fixed the Mac's You row staying at "Copying to your other computers · 0%", the Rust helper turned out
worse off: it never filled the You row's facts at all (`you_copying`, `you_items_everywhere`), so a You file said
"Copies to your other computers when they connect" before, during and after the copy, and the sync exchange marked a
file served by blocks as copying at 0 % and never cleared it (nothing read it yet). `szfriends-interop`'s new
`you_copies` test reproduced it (the row never left "queued") and now passes.

- `service/serving.rs`: a file served by blocks to another of our computers shows on the You row with how much that
  computer acknowledged, until every block is acknowledged (the requester's last HAVE), the serve fails (NONE), the
  session ends, or the serve goes quiet: 2 s with nothing asked left (a computer resuming asks only for the blocks it
  misses, so its last HAVE need not cover the file) or 30 s waiting on a HAVE (the other computer stopped or took
  the rest from another holder). Streamed copies keep the exchange's own `serving()`.
- `items_on_every_device` (core), as the Mac's `itemsOnEveryDeviceInConversation:`: the row says "On all your
  computers" once every other computer holds the item and, for a file, its bytes.
- Cancel (Get, Get again) now stops the running pull when nobody waits on the file any more, and its holders hear a
  HAVE of every block, so their rows clear at once.

**For WP4 (Objective-C):** `endServe` runs only when `allAcknowledged`. A requester that resumed (asked for its
missing blocks only) and whose last HAVE covers only those leaves the Mac serve, and its "Copying… 0%", in place
until the session ends. A Rust requester pulling from several holders sends a HAVE of every block at the end, so it
clears the Mac row; a resumed single-holder copy, or the Mac's own requester, may not. The Mac's `servingFraction`
also stays at 0 for copies by blocks (the Rust row now rises with the acknowledged blocks).
