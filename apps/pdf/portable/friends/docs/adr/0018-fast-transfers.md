# ADR 0018: Fast transfers

Status: Proposed. Date: 2026-10-29.
Builds on ADR 0001 (sessions, files, resume, the session race), ADR 0003 (durable progress), ADR 0004 (nearby routes),
ADR 0009 to 0011 (online, relay, NAT traversal), ADR 0014 (sync copies), ADR 0015 (the portable core) and ADR 0016
(AGAIN). Areas: session (session minor 4, frames 28 to 31, fields 37 to 46, capability bits), store (sidecar files, no
schema change), the transfer engine in both helpers (Objective-C `service/transfer/`, new; Rust
`szfriends-core/src/transfer/`, new), discovery and online adapters (lanes), presentation (two strings). Client
contract: PROTOCOL.md § Fast transfers. Measurements, every idea weighed and the work packages: the journal,
`portable/docs/journals/shenzhen-friends/2026-10-29-fast-transfers.md`.

## Context

The owner wants transfers over Bluetooth, direct Wi-Fi and the local network to run as fast as the route allows, on
several streams and several routes at once, with every chunk checked by a hash, every transfer resumable, Bluetooth
helping a slow network without ever stalling a transfer when it drops, and released apps (ShenzhenPDF and Shenzhen
Files 26.10.29-1, Shenzhen 3D 0.2.4) still interoperating, with today's encryption and privacy unchanged.

Measured on 2026-10-29 (M5 Max, loopback, the interop crate's Rust peer and the helper's own Objective-C session,
store and transfer code, release builds, routes emulated by a shaping proxy; the journal has every number):

| | Today | What limits it |
|---|---|---|
| 2 GiB on loopback | 131 MB/s Rust to Rust, 156 to 166 MB/s with the Objective-C helper on one side | one session, one serial queue per side; the Rust core's ChaCha20-Poly1305 at 225 MB/s per core |
| 1 GbE emulated (2 ms RTT), 100 MiB | 80 to 96 MB/s, 68 to 82 % of the link | same, plus durable progress every 4 MiB |
| Direct Wi-Fi (300 Mbit/s), internet (50 Mbit/s, 40 ms), relay (5 Mbit/s), Bluetooth (1.4 Mbit/s) | 89 to 99 % of the emulated rate | nothing in emulation; real loss and radio limits are untested |
| 300 files of 10 KiB | 8.5 to 14.3 s, 28 to 48 ms per file | a full-file copy and an F_FULLFSYNC per staged file, transactions and fsyncs per file on both sides |
| Preparing a 2 GiB file to send | 2.6 s Rust (copy, fsync, hash), 1.5 s Objective-C (clone, hash) | a copy instead of a clone; one serial BLAKE2b pass |
| CPU for 2 GiB | 2.4 CPU-s/GB sending and 3.7 receiving (Objective-C); about 4 per side (Rust) | per-chunk allocations, the store queue's row lookups, ciphers |
| Route cut mid-transfer | noticed in 0.4 to 0.5 s; 4.4 MB sent again | resume only from the contiguous durable prefix |
| Route goes silent mid-transfer | not noticed in 45 s, on Wi-Fi or Bluetooth | no keepalive or silence detection: PING exists but nothing sends it |

Reading the code adds: chunks are 60 KiB (4 KiB on Bluetooth) by the initiator's route class; there is no round trip
per chunk but the 8 MiB (256 KiB) window opens only on PROGRESS, which reports bytes made durable (F_FULLFSYNC, 4.9 ms
per 4 MiB batch here), so flow control waits on the disk; one route at a time, and Bluetooth carries traffic only
while no Wi-Fi or Internet route works; resume rests on a contiguous prefix and a whole-file BLAKE2b, so a mismatch
restarts from zero and the sender re-hashes the whole snapshot before its first resume in each helper run; online data
channels hold at most 1 MiB buffered, about 1 MiB per round trip; on the Rust side the release profile's
`opt-level = "s"` leaves the cipher at a quarter of its speed (0.93 GB/s with opt-level 3 and the NEON backend), and
the AES backends are not compiled in.

## Decision

### 1. Negotiation: session minor 4 and a capability bit, old peers unchanged

Session minor 4 adds frames 28 to 31 (`SZFriendsSessionMinor` and `szfriends_wire::SESSION_MINOR` become 4, the
handshake range 0 to 4). The handshake's capability bits (field 26, u32be, none defined until now) gain:

- bit 0 `fast transfers`: this side runs this record's transfers;
- bit 1 `AES lanes` (reserved for § 9.2; not sent until that package lands);
- bit 2 `compressed parts` (§ 9.4).

A session uses anything below only when its negotiated minor is 4 or more **and** both sides set bit 0. Otherwise
everything stays exactly as ADR 0001 has it: OFFER with the BLAKE2b digest, CHUNK in order, PROGRESS, DONE, ACK, one
session per friend, the session race. A released app never receives a frame, field or connection it does not know,
because each is sent only after its peer's handshake said it understands it. The capability bit is a switch: a build
can carry minor 4 with the feature off (settings key `transfers.fast`, default on once § Verification's matrix passes;
`SZFRIENDS_TEST_FAST_TRANSFERS=0` in test homes), which gives a release a way back without a protocol change.

The choice is per transfer, too: the sender adds the tree to OFFER (§ 2) only on a session that negotiated it, and
the receiver answers OFFER_REPLY with Blocks (field 43, u8 1) to take it by blocks; without that field the sender
uses CHUNK as today. A transfer started one way finishes that way; one started by CHUNK switches to blocks on a later
fast session only from its contiguous prefix (the prefix becomes the first blocks).

### 2. Blocks and a hash tree announced in the offer

A file is cut into **blocks** of 2^shift bytes, the last one shorter: shift 20 (1 MiB) up to 64 GiB, then the smallest
shift up to 24 (16 MiB) that keeps 65,536 blocks or fewer. A file over 1 TiB goes by CHUNK. Blocks are the unit of
verification, resume, scheduling and acknowledgement; parts (§ 3) are how a block crosses a lane.

The tree uses BLAKE3 in its plain hashing mode, with fixed 18-byte prefixes that keep leaves, nodes and the root apart:

    leaf(i)  = BLAKE3("SZFriends leaf v1\0" || u64be(i) || block i)
    node     = BLAKE3("SZFriends node v1\0" || left || right)        a lone last node moves up unchanged
    root     = BLAKE3("SZFriends root v1\0" || u64be(size) || u8(shift) || top node)

The index in each leaf stops blocks being swapped, and size and shift in the root stop truncation or extension being
passed off as the same file. Leaves are independent, so both sides hash on every core. OFFER gains TreeRoot (field 37,
32 bytes) and BlockShift (field 38, u8). The Digest field (BLAKE2b-256 of the whole file) stays in every OFFER and
stays the file's identity everywhere (store, sync, AGAIN, the publish check): nothing that keys on it changes.

After acceptance the sender sends the leaves in HASHES frames (type 28: ID, Index field 39 u32be of the first leaf,
Hashes field 40, 32 to 64,000 bytes, a multiple of 32) in the bulk queue, before any part. The receiver checks the
complete list against TreeRoot before it accepts a single part, stores it, and from then on checks every block against
its leaf the moment the block is complete. A block that fails is wanted again (§ 4), alone; the file does not restart.
2 MiB of leaves at most (65,536 × 32 bytes) per transfer.

BLAKE3 because its SIMD code (NEON, SSE4.1, AVX2, AVX-512) is maintained upstream for C and Rust under CC0 or Apache
2.0, it is the hash the owner named, and a tree of independent leaves needs only its one-shot API in both stacks. The
construction is ours so that both stacks need nothing beyond that API: the C reference library (vendored in
`ext/blake3` by `friends/deps`, pinned) for the Objective-C helper and the `blake3` crate (pinned, pure Rust plus its
SIMD) for the core. WP1 measures it against libsodium's BLAKE2b (1.5 GB/s per core here) on the slowest supported phone
before the vectors freeze; if it is not at least 1.5 times faster per core there, the leaf function becomes BLAKE2b-256
with the same prefixes and nothing else in this record changes.

### 3. Frames of minor 4

| Type | Name | Fields | Direction |
|---|---|---|---|
| 28 | HASHES | ID, Index (39), Hashes (40) | sender to receiver, after acceptance |
| 29 | WANT | ID, Ranges (41) | receiver to sender: these blocks are missing, send them |
| 30 | PART | ID, Offset (8, u64be file offset), Data (9, 1 to 61,440 bytes); Codec (44, u8) and Length (45, u32be) when compressed | sender to receiver |
| 31 | HAVE | ID, Ranges (41): blocks complete, checked and written; Durable (42): blocks made durable | receiver to sender |

Ranges are pairs of u32be (first block, count), ascending, not overlapping, at most 8,000 pairs (64,000 bytes) per
field; HAVE ranges are what changed since the last HAVE, so HAVEs on different lanes simply add up. A PART lies inside
one block, and that block must be wanted and not yet complete; anything else is the unsolicited chunk of ADR 0001 and
closes the session, except a part for a block that completed meanwhile or a transfer that just ended, which is late
and dropped (a block sent on two lanes, § 6). In fast mode DONE is not sent: the receiver knows when every block is
durable, runs the publish check (§ 5) and sends the ACK of ADR 0001 with the transfer's id, as today.

Per transfer at most 64 blocks, and at most 64 MiB, may be wanted, partly received and not complete at once; a sender
that goes past it is closed. That bounds what a peer can make a receiver hold whether it buffers blocks in memory
(desktops) or writes parts at their offsets and reads the block back to check it (phones).

### 4. Resume: a block map that survives restarts, sleep and route changes

The receiver keeps, beside `received/.partial/<id>`, a sidecar `<id>.map`: magic and version, shift, block count,
TreeRoot, the checked leaves and a bitmap of durable blocks. A durability batch (every 8 MiB or 1 s of received
blocks) writes the blocks (`pwrite`), orders them before the map (`F_BARRIERFSYNC` on macOS and iOS, `fsync` elsewhere),
writes the changed bitmap bytes, then makes both durable with one `F_FULLFSYNC` (`fsync` elsewhere). The row's
`verified_bytes` keeps meaning the contiguous durable prefix and is committed as today, so an older helper that meets
the same partial file after a downgrade resumes from that prefix and loses only the blocks beyond it. After an unclean
exit the receiver re-checks every block the map claims before trusting it (2 GiB re-hashes in well under a second on
all cores), so the ordering above is about saving work, not about correctness.

On every new session or lane group with the sender, and whenever it wants something again, the receiver sends WANT
with exactly the missing ranges. This replaces the resume PROGRESS for fast transfers and is the same mechanism after
a restart, after sleep, after a route change and after a failed block: the sender serves what is asked. It is not
required to re-hash its snapshot first any more; instead it checks each block against its own leaf as it reads it to
send (a changed snapshot fails at the first changed block, never after sending it), and fails the transfer as today
when one does not match.

The sender keeps its leaves in `outgoing/<id>.tree` beside the snapshot. **No schema change**, deliberately: a
released helper's recovery sweep deletes every file in `received/.partial/` and `outgoing/` that no row names, so if an
older app's helper runs in between, it deletes both sidecars while it truncates the partial to its prefix, and the new
helper finds no map that could claim blocks the older one threw away. It then rebuilds the map from `verified_bytes`,
asks for the leaves again (HASHES is re-sent at the start of every group for a transfer in fast mode) and, as a
sender, recomputes its tree from the snapshot. The new helpers' sweeps keep a sidecar whose partial or snapshot a row
names and delete the rest.

**The same for the other copies.** Messages, PROFILE and CHAIN fit in one frame and are idempotent by id, so their
retry is already their resume; SYNC events resume by version vectors (ADR 0014). File copies between one person's
devices (SYNC messages 4 to 6, WANT/PART/NONE) and Get again (AGAIN messages 1 to 3) gain two messages each, carried
inside their own fields so neither frame changes: WANT BLOCKS (id, shift, Ranges) and BLOCKS FOLLOW (id, TreeRoot,
shift), numbered 7 and 8 in SYNC and 4 and 5 in AGAIN. After BLOCKS FOLLOW the serving side sends HASHES and PARTs on
the session as for an offer and the copy uses the same map; WANT BLOCKS names only the missing blocks, so a copy cut
off at 90 % resumes at 90 % on any route. They are sent only on sessions that negotiated fast transfers: a released
helper ignores an unknown AGAIN message but treats an unknown SYNC message as malformed, so neither ever sees one. A
file sent before this record has no tree: the side that serves it computes one, and since the requester then has only
that side's word for the leaves, the BLAKE2b content check at publish (§ 5) remains what proves the file.

### 5. Publishing

When every block is durable the receiver reads the file back through the descriptor that wrote it (as the security
review required) and computes the tree on all cores and the BLAKE2b content digest on one more, in the same pass, then
publishes only if the root and the offered Digest both match. Checking the Digest too means a sender cannot make a
file's recorded identity differ from its bytes. It costs about 1.4 s per 2 GiB, in parallel with the tree, and the
person sees "Finishing…" for files whose check takes longer than a second (PROTOCOL.md § Fast transfers).

### 6. Lanes: several streams, several routes, one group

A **lane** is one more Noise IK session with the same device of the same friend. Its handshake payload carries Lane
(field 46, 16 bytes) = keyed BLAKE2b-128 with the first session's handshake hash h as the key over
`"SZFriends lane v1" || u8 index`, index 1 to 15. The responder accepts it only when the initiator's static key passed
the ordinary key policy, a live session with that same identity negotiated fast transfers, and the token matches that
session's h with an index not in use; otherwise it closes with the new CLOSE reason 6 (`lane refused`, a log value).
A lane declares its own route class, so its part size and pacing are its route's. The first session and its lanes form
the friend's **group** with that device:

- Lanes never enter the session race and never supersede anything. A new IK session without Lane races as today, so
  after either side restarts the groups re-form from scratch.
- Either side may send any application frame on any live lane of the group. Each side sends messages and control
  frames on its best-ranked live lane (the owner's route order, then the lowest index) and spreads PARTs by the
  scheduler (§ 7). Causality keeps order where it matters: HASHES and PART follow the OFFER_REPLY that accepted, HAVE
  follows the PARTs, and ids already make duplicates harmless.
- When a lane closes, the group goes on with the rest; when the last closes, the group ends and resume (§ 4) takes over.
- Whoever has bytes to send opens lanes; each side opens at most 4 lanes per route and 8 per group, and a responder
  admits at most 15 per group. Lanes are counted in the listeners' admission limits like any authenticated session.

**Per route.** LAN and direct Wi-Fi: TCP connections to the friend's listener. Direct Wi-Fi keeps its rule: used only
where the device stays on its Wi-Fi network at the same time (AWDL on Macs and iPhones), so a transfer never costs a
device its Internet connection. Internet: more data channels in the same peer connection, opened in-band, so no new
signalling and nothing for the host (more TCP connections through a NAT would each need their own punching, which
would). Relay: one lane at most (a data channel in the existing peer connection), so the relay's 5 Mbit/s cap, its
cost and what it sees are unchanged.
Bluetooth: one L2CAP channel at most; more would share the same radio.

**How many on one route.** One per route to start. A second and later lane on the same route only when the first is
limited by this computer, not the path: its encrypting thread is busy all the time while the socket or channel has
room (LAN, direct Wi-Fi, 10 GbE, a fast Internet path). Never more than one on the relay or Bluetooth. Lanes each have
their own cipher state and thread, which is how one transfer uses several cores. Data channels in one peer connection
share one SCTP association and so one congestion controller: more of them add cores, not shares of the path.

### 7. Scheduling across lanes and the congestion-control choice

Each lane keeps a delivery rate (the largest bytes-per-second over HAVEs in the last 10 s), a round-trip time (the
smallest time from a block's last part to its HAVE in the last 10 s) and its bytes in flight (blocks assigned and not in
a HAVE). The next missing block goes to the lane expected to finish it first: (in flight + block) / rate, plus its
round-trip time. Faster lanes get proportionally more, a slow lane gets a block only when it would still beat the fast
one, and the last blocks never wait behind Bluetooth. Each lane keeps about twice its bandwidth-delay product in
flight: rate × round-trip time × 2, at least two blocks, at most 32 MiB (8 MiB on phones), within § 3's limit.

**Congestion control is the transport's.** Every lane rides something that already has it: TCP (CUBIC by default on
macOS, Linux, Windows, Android, iOS), SCTP in usrsctp, L2CAP credits. A second loop of our own on top would fight it;
what the application decides is only how much to keep in flight, sized from measured rate and delay as BBR estimates
them, so the pipe stays full without queueing seconds of data in which a message would wait and from which a lost
lane's blocks would have to be taken back. Parallel TCP lanes on one route take several shares of a shared
bottleneck, which is unfair to the person's own other traffic, so § 6 allows them only when this computer, not the
network, is the limit, and never on the relay.

**Losing a lane.** When a lane closes, every block assigned to it and not in a HAVE goes back to the front of the
missing set and is assigned at once to the remaining lanes; parts of it that did arrive stay where they are and the
block is simply completed by whichever copy finishes. **A silent lane** is one with blocks assigned that, for longer than
max(3 × its round-trip time, 1 s) (2 s on Bluetooth), has neither completed one nor had a write completion while bytes
were queued: its blocks are sent again on the other lanes at once, it gets nothing new, and it closes after 10 s
without a byte from the peer. So losing Bluetooth range costs at most about 2 s of Bluetooth's share and never stops
the transfer. **Endgame:** when nothing is left unassigned, blocks still in flight on a lane that would finish later than
another lane could are sent there too; the first complete copy wins and the other is dropped. The waste is bounded by
one lane's window.

**Liveness on every session, old peers included.** While a transfer runs on a session, each side sends PING (a frame
every minor knows and ignores) after 1 s without sending anything, so the other side always hears something. A
session that carries a transfer and has heard nothing for 8 s (12 s on Bluetooth) is closed locally, and the route
racer dials again. Against a released peer, which sends no PING, the same rule uses what it must send: a sender that
has received no PROGRESS for sent bytes for 8 s, or a receiver that has received no CHUNK for 8 s since its last
PROGRESS, closes and redials. This fixes the measured 45-second (and longer) stall for every pair, old or new.

**Bluetooth beside a slow network.** Bluetooth stays last in the route order for sessions and messages. In a group it
becomes a lane for PARTs when another lane's measured rate is below 4 MB/s, and keeps blocks only while the
scheduler expects it to finish them before the faster lane; it never carries the last blocks unless it is the only lane.

### 8. Security and privacy

- **The same sessions.** Every lane is a full Noise IK session to the friend's verified static key, through the same key
  policy, replay cache, refusal rules and admission as ADR 0001 and 0004; nothing outside a Noise session carries a
  byte. The lane token is derived from h, which only the two ends know, and is sent inside IK message 1's encrypted
  payload; a replayed message 1 is refused by the replay cache and could not complete the handshake anyway.
- **Nothing new to the relay or the host.** No new host messages; online lanes are data channels inside the existing
  DTLS association; at most one lane uses the relay; compressed parts never go through it (§ 9.4). The relay sees
  the same kind of encrypted traffic as today, and less of it when a direct lane carries a share; the only new pattern
  is the liveness PING (§ 7), at most one small message a second in a direction that is otherwise quiet during a
  transfer, the size of an ACK, while ICE already sends its own consent checks every few seconds.
  Someone on the local network can see more TCP connections between the same two devices, which reveals no more than
  that the two talk, already visible.
- **What a peer can make us store.** At most 2 MiB of leaves per transfer and only after acceptance; at most § 3's 64
  blocks in flight; parts only for wanted blocks; WANT only for offers this side made to that person, accepted, or for
  copies ADR 0014 and 0016 already allow; ranges and leaf counts checked against the block count before anything is
  allocated; the declared size is preallocated (`F_PREALLOCATE`, `fallocate`) after the disk-space check of today, so a
  sparse partial cannot grow past what was accepted; a compressed part must expand to exactly its Length, at most 61,440
  bytes.
- **Integrity.** Blocks are checked against an authenticated root on arrival and the whole file again before
  publishing (§ 5), so the guarantees of ADR 0001 hold and corruption costs one block, not the file.
- **Skipping blocks the receiver has** (§ 9.5) only uses files the same friend sent this person, or the person's own
  devices' files, so a friend learns at most that the person still has what they sent.

### 9. Other ideas

Each with its cost and benefit; the journal keeps the full list, including those not adopted.

1. **Fewer copies and syscalls (adopted, WP1 and WP4).** Staging clones (`clonefile` on APFS, `FICLONE` or
   `copy_file_range` on Linux, block cloning on ReFS, a copy elsewhere) and does not fsync a private snapshot whose
   leaves are recorded (a torn snapshot fails its leaf check, § 4). Reads with `pread` into a pool of block buffers,
   `F_RDADVISE` or `posix_fadvise(SEQUENTIAL)`, no allocation per part; encryption in place; several Noise messages per
   `writev`. Memory-mapping was weighed: for sequential reads it saves little over `pread` and turns an I/O error on an
   external disk into SIGBUS, so it is not used.
2. **The fastest cipher on each platform.** (a) Adopted now (WP3): the release profiles compile the cipher and hash
   crates at opt-level 3 with their NEON and ARMv8 AES backends (`chacha20` 0.93 GB/s instead of 0.225, AES-256-GCM
   1.7 instead of 0.17, measured); phones keep `opt-level = "z"` for everything else, and `tools/embedded-size.sh`
   checks the result against ADR 0015's 5 MB before it lands. (b) Later (WP6, behind capability bit 1): a lane may run
   `Noise_IK_25519_AESGCM_BLAKE2b` when both sides report hardware AES (libsodium measured 8.5 GB/s against
   ChaCha20-Poly1305's 0.77 on the same core). Noise names that suite and cacophony has its vectors, but it is a
   second cipher in two stacks to review; first sessions stay `25519_ChaChaPoly_BLAKE2b`, so nothing changes for
   released apps. AEGIS-128L (21 GB/s) is not a Noise cipher and is not adopted.
3. **Batching (adopted).** Files sent together are staged together: one transaction, fsync per file and one
   F_FULLFSYNC for the batch (on Apple storage it flushes the whole drive cache, 3.6 ms each here), and the receiver
   publishes a batch the same way. Their OFFERs go back to back and a receiver accepting them answers them back to back,
   so 300 small files cost a few round trips, not 300. A file that fits one block is one block.
4. **Compressing only when it helps (adopted for Bluetooth lanes, capability bit 2).** Per block, zstd level 1 on a
   64 KiB sample; the block is sent compressed only when that saves at least 10 %, never for types already compressed
   (images, video, archives). STEP, OBJ and text compress severalfold and Bluetooth is where bytes cost most. Not on
   other routes for now: on the relay it would show the relay how compressible each block is, which it cannot see
   today; on fast routes it costs more CPU than it saves. Extending it is a later decision.
5. **Skipping blocks the receiver already has (adopted, WP1 for whole files, WP6 for blocks).** An OFFER whose Digest
   matches a file this computer received from the same friend, or that the person's own devices hold, is answered as
   accepted and filled locally; a new version of a file that friend sent before reuses the blocks whose leaves match at the same position.
   Fixed blocks only find edits that do not shift the file; content-defined chunking would find more, but it breaks the
   simple map and tree, and is not adopted.
6. **All of one person's devices at once (adopted in this form, WP6).** Sending the whole file to each device would
   multiply the sender's upload. Instead the device that accepted pulls the file, and the person's other devices pull
   blocks from both that device (SYNC, § 4) and the friend (AGAIN, which ADR 0016 already lets any of the person's
   devices ask), so each block crosses the sender's link about once and every device fills from every holder.
7. **Apple's peer-to-peer Wi-Fi (kept, tuned in WP3).** AWDL is already used where available. It shares the radio with
   the infrastructure network by time-slicing, so a lane on each rarely beats one: the scheduler measures, and an AWDL
   lane is opened beside a LAN lane only when the LAN lane is below 25 MB/s. Wi-Fi Aware on iPhone and Android is noted
   for later.
8. **Larger Bluetooth packets (adopted, WP3).** Parts of 16 KiB instead of 4 KiB chunks, a 64 KiB write budget,
   Android's high connection priority and LE 2M PHY requested while a transfer runs, BlueZ the same; CoreBluetooth picks
   its own connection interval. Overhead falls from about 1 % to 0.25 % and writes from 256 to 64 per MiB. The window no
   longer waits on the disk (§ 3), which matters more as radios get faster.
9. **Better loss recovery on Internet paths (adopted, WP3, measured first).** Data channels may hold 8 MiB buffered
   instead of 1 MiB, so one is no longer capped near 1 MiB per round trip (26 MB/s at 40 ms, 7 MB/s at 150 ms), with
   usrsctp's buffers raised to match and its H-TCP module chosen instead of the RFC 4960 default where the NAT
   emulator's loss profiles show a gain. Forward error correction is not adopted: a lot of code, and a second direct
   route (§ 7) is a better answer to a lossy one.

### 10. Rollout

- **Rust core** (`portable/friends/core-rs`): `szfriends-wire` (types 28 to 31, fields 37 to 46, capability bits,
  CLOSE reason 6, minor 4); `szfriends-core/src/transfer/` (blocks, tree, sidecars, the scheduler, sans-IO, with a
  simulator); `store/` (staging, batches, publish check); `szfriends-helper` (lanes on LAN, Bluetooth and test airs, the
  engine, liveness); `szfriends-online` (more data channels, buffer and SCTP settings). Shenzhen 3D on Windows, Linux,
  Android and iOS gets it through the core.
- **Objective-C helper** (`portable/friends/service`): the same in `session/` (frames, payload field, minor 4),
  `transfer/` (new: blocks, tree over vendored BLAKE3, sidecars, scheduler), `store/`, `helper/nearby/` (groups and
  lanes in place of one link per friend), `discovery/` (Network.framework and CoreBluetooth lanes), `online/` (data
  channels). The scheduler is local policy, not wire format: the two may differ in tuning, never in frames.
- **Shared test vectors** in `friends/fixtures/vectors/transfer/`: tree roots and leaves for sizes 0, 1, one block
  minus one, one block, one block plus one, 3 blocks plus 7 bytes and a 1 GiB pattern at shifts 20 and 21; every
  minor-4 frame and the OFFER and OFFER_REPLY fields; lane tokens from given h and index; both sidecar layouts; the
  new SYNC and AGAIN messages. Exported from the helper's code by `tools/objc-vectors` like every other vector, checked
  by `friends-vectors-check` and the Rust suites; WP1 writes them from this record first so both sides build against
  the same bytes.
- **Builds.** A new helper build number (YYMMDDBB) so handover puts the new helper in place on a Mac; the session
  protocol's minor 4; no client protocol change (PROTOCOL.md § Fast transfers adds words in existing fields only) and
  no major change anywhere. Both helpers ship
  in the same release train; until both have, a mixed pair simply negotiates the old path.
- **Friends host: nothing.** No host protocol change, no relay change, no new records. Online lanes use the peer
  connection the host already helped set up.

## Alternatives considered

- **Our own UDP transport (QUIC or similar) with our own congestion control.** The best tool for loss on long paths,
  but a large new stack on every platform beside the WebRTC one we already ship, and a new security review. Lanes over
  the existing transports get most of the gain.
- **MPTCP.** It does multi-path in the kernel, but only between interfaces of one IP stack (not Bluetooth or data
  channels), and support is partial on macOS, absent on Windows and on Android for apps.
- **Several sessions without groups.** Each would race and supersede the others under ADR 0001; changing the race for
  everyone would also change it for released peers.
- **Keeping one session and moving it to the best route faster.** Simpler, but cannot add Bluetooth to a slow network,
  use two cores, or keep a transfer going while one route dies.
- **A Merkle proof with every block** instead of HASHES up front. 352 bytes per MiB at 2,048 blocks, and every block
  carries its own proof check; the leaves up front cost 32 bytes per MiB once and keep PART simple.
- **BLAKE3's own tree mode (Bao).** Elegant for verified streaming, but the C library does not expose subtree hashing,
  so the Objective-C helper would depend on internals.
- **A store table for the block map (schema v13).** Additive, so released helpers would still open the store
  (min_reader_version stays 2), but they would ignore the table while truncating partials to their prefix, leaving rows
  that claim blocks no longer on disk. Sidecars are removed by those same helpers' recovery sweep instead.
- **An application-level congestion controller (BBR or LEDBAT of our own).** It would fight the transport's;
  LEDBAT-style yielding is worth revisiting for transfers the person marks as background.

## Consequences

- One session per friend becomes one group per friend's device for new pairs. The helper's link adoption and the
  Rust service's session table change shape (WP3, WP4); for released peers they behave exactly as today.
- Two new frame codecs, a tree, a block map, sidecars and a scheduler in two languages; the vectors and the interop
  matrix are what keep them equal.
- A new dependency: BLAKE3 in C and Rust (or none, if § 2's measurement falls back to BLAKE2b); zstd for § 9.4.
- Disk use is unchanged; memory is bounded by § 3 per transfer and § 7 per lane.
- Faster routes in parallel raise peak network use. Parallel lanes on one route are limited to when the computer is the
  bottleneck, and nothing changes on the relay.
- The new silence rule closes a session that is merely very slow to answer for 8 s during a transfer. Both sides send
  PING after 1 s of silence, so that only happens when the peer or the route is really gone.

## Verification

**Interoperability matrix.** For every pair of platforms (macOS Objective-C helper; Windows and Linux Rust helper;
Android and iOS core in the app), both directions, each side either released (ShenzhenPDF and Shenzhen Files
26.10.29-1 from tags `pdf/26.10.29-1` and `files/26.10.29-1`; Shenzhen 3D 0.2.4 from `3d/preview-0.2.4`) or new: the
ADR 0001 scenarios (200 MiB, resume after a cut, route migration, rekeys, tampering) and Get again and a sync copy must
pass. Released with new must negotiate minor 3 or below, receive no frame, field or connection it does not know (PING
it knows) and finish as today; new with new must negotiate fast transfers. The interop crate runs the released peers as session peers built from those
tags (`SZFSessionPeer-26.10.29-1`, a Rust peer at `3d/preview-0.2.4`).

**Route loss.** A shaping proxy in `szfriends-interop` (rate, delay, cut, silence, flapping) and the test Bluetooth air:
cut and silence at 10, 50 and 90 %, on the only lane and on one of several; the group's first session lost; flapping every 2 s;
Bluetooth silenced while it helps a slow LAN; both peers restarted mid-transfer; a peer stopped for 60 s as sleep does;
the disk filling; a snapshot changed under the sender; a corrupted block. Pass: blocks of a lost lane reassigned within
1 s of a close and within 3 s of silence (Bluetooth too), at most one window sent twice, the transfer never waits on a
dead lane, and released pairs recover within 8 s of silence.

**Speed targets** (release builds; emulated on one Mac, then on hardware: two Macs, a Mac and the Windows and Linux
devices, a phone):

| Route | Today | Target |
|---|---|---|
| Loopback, 2 GiB | 131 to 166 MB/s | 1.5 GB/s Rust with Rust and with the Objective-C helper (lanes on several cores) |
| LAN, 1 GbE | 68 to 82 % | 93 % of the link; 2.5 and 10 GbE at least 70 % |
| Direct Wi-Fi | 89 to 93 % emulated | 90 % of what one TCP connection gets between the same two devices |
| Internet, direct | 97 % at 40 ms without loss | 90 % at 40 ms; at 150 ms and 1 % loss at least twice today |
| Relay | 99 % of 5 Mbit/s | 95 %, and never more than one lane on it |
| Bluetooth | 98 % emulated | 90 % of the raw L2CAP rate measured on each device pair |
| LAN 10 Mbit/s plus Bluetooth | LAN alone | LAN plus at least 80 % of Bluetooth's rate; no slower than LAN alone when Bluetooth drops |
| 300 files of 10 KiB, LAN | 8.5 to 14.3 s | under 1.5 s |
| Preparing 2 GiB to send | 1.5 to 2.6 s | under 0.8 s |
| CPU, 2 GiB | 2.4 to 4.3 CPU-s/GB per side | under 1 CPU-s/GB per side |

The benchmark becomes `make friends-transfer-bench` (JSON lines; results recorded in the journal), run before and after
each work package.
