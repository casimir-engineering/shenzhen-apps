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
