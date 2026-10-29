# Shenzhen Friends architecture decisions

Decisions the M1 build implements. The brief, `portable/docs/plans/shenzhen-friends.md`, says what Friends
does; these records fix how, and why the alternatives lost. Client IPC messages are specified in
`portable/friends/PROTOCOL.md`, not here.

0001 to 0006 are **Accepted by lead; owner review pending**; 0007 is **Accepted by lead**; 0008 is **Proposed** until
the lead accepts it on commit; 0009 to 0011 (M2, online friends) are **Accepted by lead** on 2026-10-13, with the
lead's corrections from `portable/friends/docs/m2-decision-brief.md` in an "Accepted with corrections" section at
the end of 0009 and 0010; 0012 (one profile on several devices) and 0013 (joining a profile) are **Proposed** until
the lead accepts them.

- [0001 Session protocol](0001-session-protocol.md): Noise XX / IK / NN over libsodium, frames, delivery,
  transfers, independent review scope.
- [0002 Helper lifecycle and IPC](0002-helper-lifecycle-ipc.md): one helper per Mac user; spawn, single
  instance, socket, peer checks, exit, version handover, launch-path proof.
- [0003 Store schema and migrations](0003-store-schema-migrations.md): system SQLite, schema, search,
  migrations, crash recovery, what lives where.
- [0004 Nearby transport and presence](0004-nearby-transport-presence.md): Network.framework and Bluetooth
  adapters, merger, presence tags, visibility, Add by ID nearby, permissions at launch.
- [0005 Friends host service](0005-friends-host-service.md): Node.js host; check-in, ID reservation, signed
  host list, replicas, statistics, dashboard, deployment, signing key custody.
- [0006 Friends ID word list](0006-friends-id-word-list.md): EFF-derived 2,048 words, license and
  attribution, curation rules, versioning, three-word threshold.
- [0007 Mentions](0007-mentions.md): the mention link in message text, written by the sending helper from the
  composer's chips, checked on arrival, resolved per reader; Add from a mention bound to the mentioned key.
- [0008 File previews before acceptance](0008-previews.md): rendered on the sender behind a replaceable renderer, QOI
  on the wire in the THUMBNAIL frame, checked and redrawn as PNG by the recipient's helper, replaced once the file's
  digest checks, deleted with the offer.
- [0009 Online transport stack](0009-online-transport.md): libdatachannel with libjuice, usrsctp and Mbed TLS,
  static, data channels only, ADR 0001 unchanged on one data channel; the helper runs the connection order; who may
  reach the stack before authentication. Interface: `friends/service/online/SZFriendsOnlineTransport.h`.
- [0010 Host rendezvous, connection setup and relay](0010-host-rendezvous-relay.md): host protocol 2 on the same
  WebSocket; sealed, memory-only rendezvous records; forwarded setup that never says whether a target exists;
  guests for download links; STUN on two ports; coturn at 5 Mbit/s per session, last resort; relay statistics.
- [0011 NAT traversal](0011-nat-traversal.md): signalling first, then IPv6, hole punching, port mapping and our own
  TCP simultaneous open at once for a provisional 5 s, hard-NAT prediction and probing for up to 12 s more, then the
  relay; leaving the relay; PCP and NAT-PMP client, miniupnpc; VPN policy; keepalive; the technique log.
- [0012 Device chain](0012-device-chain.md): one person on several computers; the first device's key stays the root,
  each device has its own keys, and a signed, hash-linked set of genesis, add, revoke and rename links says which
  speak for the root; merges by union, revocation wins; the CHAIN frame of session minor 2 on every session with a
  friend; schema v8. Interfaces: `friends/service/identity/SZFriendsDeviceChain.h`,
  `friends/service/store/SZFriendsStoreDevices.h`.
- [0013 Joining a profile](0013-joining.md): a new computer asks by Friends ID, one of the person's computers approves
  and shows an 8-digit code, and CPace over the session proves both ends before the add link is signed; requests and
  codes live in memory only. Interfaces: `friends/service/identity/SZFriendsJoin.h`, `SZFriendsCPace.h`.
- [0014 Sync between one person's devices](0014-sync.md) (Proposed): every change an event signed by its device,
  captured by comparing the store with what was last recorded; merges by set, maximum, last writer and tombstones
  that win; anti-entropy over SYNC frames between our own devices found by tags only they match; friends reach any of
  our devices; files copy up to 25 MB by themselves. Interfaces: `friends/service/sync/SZFriendsSync.h`,
  `friends/service/store/SZFriendsStoreSync.h`.
- [0015 The portable core](0015-portable-core.md) (Proposed): Friends on Windows, Linux, Android and iOS as a Rust
  core implementing the same wire formats and the same view contract, a helper process on desktops and in-process on
  phones, macOS staying on this helper, the WebRTC stack shared with it, vectors exported from this helper's code.
  Code: `friends/core-rs/`; plan: `portable/docs/plans/friends-portable-core.md`.
- [0016 Getting a file again](0016-files-again.md) (Proposed): a computer that no longer has a file's bytes stops
  counting as one that holds them, Get then copies it from another of the person's computers, and when none has it
  the friend who sent it serves it again, unasked, over the AGAIN frame of session minor 3, only to the person it went
  to and only while the file is unchanged; schema v12.

Rules for these records:

- One decision per record: context, decision, alternatives considered, consequences, verification.
- A decision that changes gets a new record that supersedes the old one; the old record stays, with its
  status changed to "Superseded by NNNN". Records are not rewritten after acceptance except to fix errors.
- Numbers, limits and timeouts marked "the spike tunes" may change with measurements; record the measured
  value and its source in the journal (`portable/docs/journals/shenzhen-friends/`) and update the record.
- Each record is the decision; the matching public header under `portable/friends/` is its interface. When
  they disagree, fix whichever is wrong in the same change.

Corrections made on 2026-10-12, before the build wave, where a record contradicted PROTOCOL.md or another
record: 0001 lists the Add by ID frames from 0004 and points to the header holding type and tag numbers;
0002 names the socket directory `ipc/` as PROTOCOL.md does, leaves launch retries to the client library's
reconnection, and names the shared directory check; 0003 keeps received files on Delete history and Reset
Friends, as PROTOCOL.md and the Settings text promise, and lists `outgoing/`.

Corrections recorded after the M1 build wave, in a "Corrections" section at the end of each record, where the
implementation settled what a record left open or had differently: 0001 (route class required for XX and IK,
handshake payload tags 24 to 27, CLOSE reasons, the 10-second handshake timeout, the REQUEST_BY_ID signed bytes,
file acknowledgements matched oldest first per session, crossed requests as acceptance), 0003
(`UNIQUE(conversation_id, item_id)`, the FTS index created at open), 0004 (probing for a friend whose tags we cannot
match, removed and blocked keys refused at IK) and 0005 (memory limit and dashboard socket, the Node image,
identities stored by hash, host-link proofs, idempotent release).

Review amendments recorded after the independent security reviews of the M1 build, in a "Review amendments" section
at the end of 0001 (codes only after a visible request, nothing acting before HELLO, replay, admission, uniform
refusals, one identity key per conversation, signature domains), 0004 (answers to Add by ID, callback tags, listener
rotation, presence secret rotation, relayed tags, stranger pictures) and 0005 (the replicated ID table and forwarded
proofs, host-signed replies, keyed identity hashes and per-day salts). Each amends its record's decision and names
the finding it answers; the Consequences sections say what remains exposed.

Amendments recorded on 2026-10-13 from the wave-3 security re-check, in the same sections: 0001 (the attestation
field and the admission hooks, under Corrections), 0002 (apps check the helper's signature and ignore the state
override when signed), 0004 (the Bluetooth public entry on its own characteristic, the IK window for pending
requests and their expiry, attested answers to Add by ID, admission that keeps friends in) and 0005 (ID
attestations, message authentication on host links, the limits on a compromised replica).

Amendments recorded later on 2026-10-13 from the wave-4 security re-check and the assistant work: 0001 (handshake
messages a responder reads are bounded before any Diffie-Hellman; the ViaAssistant field), 0003 (schema v4) and
0004 (an unattested acceptance is a request, requests we sent lapse and requests by ID never open IK, Add by ID
trusts no claimed ID, and the per-address NN rate, attestation only on ACCEPT and the uniform judging of tokens).

Corrections recorded on 2026-10-13 from waves 6a and 6b, in the same sections: 0001 (the THUMBNAIL frame of session
minor 1, and the frame fuzzing now in place), 0003 (schema v6 for previews; search reading mentions as their labels)
and 0007 (search no longer holds mentions' IDs and keys).
- [0017 System notifications](0017-notifications.md) (Proposed): one notifier per device (the helper on a computer,
  the core in the app on a phone) decides each item once at commit; nothing for the focused conversation or the
  person's own other devices; clicks open `<scheme>://friends/conversation/<id>` in the app last used; the ask card on
  macOS and iOS, POST_NOTIFICATIONS with Bluetooth on Android, a foreground service for background reach; a JSON-lines
  sink in test homes.
- [0018 Fast transfers](0018-fast-transfers.md) (Proposed): session minor 4 and capability bit 0, negotiated in the
  handshake so released apps keep today's transfers; files in blocks under a BLAKE3 tree announced in the offer and
  checked on arrival; a block map in sidecar files that resumes exactly what is missing after restarts, sleep and route
  changes, for SYNC copies and Get again too; lanes (more IK sessions bound to the first) on several routes, scheduled
  by measured speed, with a lost or silent lane's blocks reassigned at once; PING liveness on every session; nothing
  new for the host or the relay. Measurements and work packages: the journal,
  `portable/docs/journals/shenzhen-friends/2026-10-29-fast-transfers.md`.
- [0019 Wi-Fi Direct boost](0019-wifi-direct-boost.md) (Proposed): when two devices met only by Bluetooth and are
  not on the same network, a large transfer may move over a Wi-Fi Direct link an Android phone hosts and a Mac, an
  iPhone or another phone joins; BOOST (frame 32, capability bit 5) on the Bluetooth session carries a random name and
  passphrase per boost, and the link's lane binds to that session; a device that would lose its only Internet asks
  first (Go faster, Not now), writes down its network and rejoins it at the end, after a crash at the next launch; the
  lane is dropped when it measures no faster than Bluetooth.
