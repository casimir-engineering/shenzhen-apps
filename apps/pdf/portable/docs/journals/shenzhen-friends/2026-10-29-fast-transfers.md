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
| AES-256-GCM lanes (`Noise_IK_25519_AESGCM_BLAKE2b`) where both have hardware AES | Later (WP6, capability bit 1) | 10× less CPU per byte; second suite to review |
| AEGIS-128L | Not adopted | not a Noise cipher, no vectors |
| Batches: staging, transactions and one F_FULLFSYNC per batch; offers and replies back to back | Adopted (§ 9.3) | 300 small files from 8.5 to 14.3 s to under 1.5 s |
| One ACK frame for many files | Not adopted | an ACK is a 38-byte message, already pipelined |
| zstd per block when a sample saves 10 % | Adopted on Bluetooth lanes only (capability bit 2) | STEP and text compress severalfold; on the relay it would reveal compressibility |
| Skipping files the receiver already has (same friend or own devices) | Adopted (WP1) | instant for a re-sent file; limited so a friend learns only that the person kept what they sent |
| Reusing matching blocks of an earlier version from the same friend | Later (WP6) | big for iterated CAD files; needs a local leaf index |
| Content-defined chunking | Not adopted | finds shifted edits but breaks the fixed map and tree |
| Sending the whole file to each of a person's devices | Not adopted as such | multiplies the sender's upload |
| Multi-source pulls: the person's devices fetch blocks from each other and from the friend | Later (WP6) | each block crosses the sender's link about once |
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
