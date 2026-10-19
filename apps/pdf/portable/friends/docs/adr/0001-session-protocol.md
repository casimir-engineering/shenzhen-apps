# ADR 0001: Session protocol

Status: Accepted by lead; owner review pending. Date: 2026-10-12.
Brief: § Session protocol, § Outbox and delivery, § Transfers. Areas: session (owner), identity, store.

## Context

Every route is a reliable, ordered byte stream: TCP on LAN and peer-to-peer Wi-Fi, an L2CAP channel on
Bluetooth, a WebRTC data channel in M2. Friends needs mutual authentication by identity key, forward
secrecy, nothing revealed to strangers who probe a listener, and one implementation for every route.
There is no mailbox, so both peers are online during delivery and a ratchet buys nothing (brief).

## Decision

**Noise, one suite, three patterns.** Noise revision 34 with `25519_ChaChaPoly_BLAKE2b`:

- `XX` for first contact (friend requests, public entries during visibility).
- `IK` for known friends. The responder rejects an unknown or blocked initiator static before it replies.
- `NN` only for Add by ID nearby (ADR 0004).

No PSK modifiers, no `XXfallback`, no other patterns. A failed IK is not retried as XX: identity keys
never change, so a failing IK means the other side is not that friend.

**Implementation: our own state machine over libsodium 1.0.22** (vendored in `ext/libsodium` by
`friends/deps`), not noise-c. C, in `friends/service/session/`, about 600 lines: CipherState,
SymmetricState and HandshakeState exactly as the spec writes them, for the three patterns only. Primitives:
`crypto_scalarmult` (X25519; an all-zero result is a failure), `crypto_aead_chacha20poly1305_ietf` (nonce =
4 zero bytes then the 64-bit little-endian counter, spec § 12.3), `crypto_generichash` BLAKE2b-512 with
HMAC and HKDF built per spec § 4.3 (BLOCKLEN 128), `randombytes_buf`, `sodium_memzero`, `sodium_memcmp`.

**Keys.** An identity is an Ed25519 signing key (the identity key: friends are stored by it, the host
check-in signs with it) plus an X25519 Noise static key, generated together, stored in one key-store item,
both immutable. libsodium's documentation recommends distinct keys for signing and key exchange, so we do
not convert one into the other. The handshake payload that reveals a static key (XX messages 2 and 3, IK
message 1) carries `cert = ed25519_pk || Sig(ed25519_sk, "SZFriends static v1" || x25519_pk)`; the receiver
verifies it and identifies the peer by `ed25519_pk`. Friends rows keep both keys; IK dials the stored static.

**Mandatory Noise test vectors.** The session suite must reproduce, byte for byte, every message
ciphertext and the final handshake hash of every `Noise_{NN,XX,IK}_25519_ChaChaPoly_BLAKE2b` vector in:

- cacophony, `vectors/cacophony.txt`, github.com/haskell-cryptography/cacophony: The Unlicense (public
  domain dedication; verified from its LICENSE file). Primary source.
- snow, `tests/vectors/snow.txt`, github.com/mcginty/snow: `Apache-2.0 OR MIT` (its Cargo.toml). A second,
  independent implementation.

Only the matching entries are copied into the session fixtures, with upstream URL, commit hash and license
beside them (snow's MIT notice included). The format is the Noise wiki's "Test vectors" JSON. Loading zero
vectors fails the suite, so a broken filter cannot pass silently.

**Wire format.**

- Stream: each Noise message is preceded by a 16-bit big-endian length (spec § 13). 65,535 bytes per
  message is the hard limit on every route. Length 0, any decryption failure or any parse failure closes
  the session; there is no resynchronisation.
- Preamble: before message 1 the initiator sends 4 bytes `'S' 'Z' major pattern` (major = 1). An unknown
  major or pattern closes the connection. Prologue = `"SZFriends session\0" || preamble`, so a tampered
  preamble fails the handshake instead of downgrading it.
- Handshake payloads carry only: the cert, the supported minor-version range, capability bits, the
  initiator's route class, and on a public entry's XX message 2 the public profile. IK message 1 can be
  replayed (spec § 7.7, destination property 2), so nothing acts on handshake payloads: a responder treats
  a session as live only after the initiator's first transport frame.
- Transport plaintext: `type:u8`, then fields `tag:u8 len:u16be value`. Senders use only types the peer's
  minor version knows, so an unknown type is an error: close with an error frame. Unknown tag: ignore.
  Duplicate tag, or a field over its per-type limit: close. Plaintext is at most 65,519 bytes (65,535 minus
  the 16-byte tag); per-type limits (text 32 KiB, own picture 48 KiB) live in the codec header. Families:
  HELLO, MSG, ACK, REQUEST / ACCEPT / DECLINE, OFFER / OFFER_REPLY / CANCEL, CHUNK, PROGRESS, DONE,
  PROFILE, PRESENCE_SECRET, CODE_COMMIT / CODE_NONCE / CODE_REVEAL, REKEY, PING, CLOSE, and for Add by ID
  over NN, REQUEST_BY_ID / RECEIVED (ADR 0004). Type and tag numbers are in
  `friends/service/session/SZFriendsSession.h`.

**Rekey.** Per direction, the sender sends REKEY and then calls `Rekey()` (spec § 11.3) on its sending
CipherState after 1 GiB or 15 minutes since that direction's last rekey; the receiver calls `Rekey()` right
after decrypting REKEY. The stream is ordered, so both switch at the same message. A session older than 24
hours is closed and redialed for a fresh Diffie-Hellman. Nonces never wrap: reaching 2^64-1 closes.

**Comparison codes.** A short code taken directly from the handshake hash can be ground: a man in the
middle runs two handshakes and tries ephemeral keys until both 6-digit codes match, about 2^20 X25519
operations, under a second. Codes therefore use commit-then-reveal over the session's handshake hash `h`
(Vaudenay's SAS protocol; the shape of Bluetooth numeric comparison): the responder sends CODE_COMMIT =
`BLAKE2b-256("SZFriends code commit v1" || h || nR)`, the initiator sends CODE_NONCE `nA`, the responder sends
CODE_REVEAL `nR`, the initiator checks the commitment. Nonces are 32 random bytes. Code = first 8 bytes of
`BLAKE2b-256("SZFriends code v1" || h || nA || nR)` as a big-endian integer mod 1,000,000, shown as 6
digits. A man in the middle then wins with probability 10^-6 per attempt, and a failed attempt shows as
codes that differ. The exchange runs once, in the session that creates the friendship (the XX request
session, or the IK callback after Add by ID); both sides store the code so it can be compared later. A
scanned QR carries the identity key and is verified without a code.

**Messages.** `msg_id` is 16 random bytes chosen by the sender and reused on every retry. The recipient
inserts under `UNIQUE(sender identity, msg_id)` and sends ACK only after that transaction is durable (ADR
0003); a duplicate is acknowledged again, never inserted twice. The sender marks Delivered only on ACK.
Display order is sender timestamp, clamped to the receive time so a fast clock cannot pin messages to the
bottom, then `msg_id`. Requests, acceptances and offers are outbox items with IDs too. An ACCEPT for an offer
that is no longer offered (accepted, declined, cancelled, expired) is ignored.

**Files.** OFFER carries `offer_id` (16 random bytes), name, type, size and the BLAKE2b-256 of the content.
No CHUNK moves before acceptance; an unsolicited CHUNK closes the session. CHUNK = `offer_id`, `offset:u64`,
data, all inside the AEAD. Data per chunk: 60 KiB on LAN and peer-to-peer Wi-Fi, 4 KiB on Bluetooth (the
spike tunes both). Control and message frames jump queued chunks, so a message never waits behind a file.
The sender keeps a bounded window of unacknowledged bytes (8 MiB on Wi-Fi, 256 KiB on Bluetooth);
PROGRESS(`offer_id`, durable bytes) advances it and is sent only for bytes written and fsynced.

**Resume and route migration: one mechanism.** On every new session the recipient sends PROGRESS for each
unfinished inbound transfer. The sender continues from that offset only if the offer is its own, to this
recipient, still accepted, and its bound source still hashes to the offered digest. After DONE the recipient
checks the whole-file digest (re-hashing the partial file once after a restart), publishes, then acknowledges;
a mismatch deletes the file and fails the transfer. When a faster route's session goes live, the old session
closes and the new one resumes the same way. Sessions themselves never migrate.

**Session race.** One session per friend. The initiator's route class travels in the handshake payload, so
both sides judge with the same facts: the faster class wins (LAN, then peer-to-peer Wi-Fi, then Bluetooth);
within a class, the session initiated by the lower `ed25519_pk` (bytewise) wins. The loser closes after
its in-flight ACKs.

## Alternatives considered

- **noise-c** (rweather/noise-c, MIT; the ESPHome-maintained fork esphome/noise-c, MIT). Complete and
  tested, but it brings its own crypto backends, every pattern, PSK, hybrid and NewHope code and run-time
  protocol-name parsing: a review surface many times the code we need. Upstream shows no releases; the
  fork exists to build for microcontrollers and exercises `NNpsk0_25519_ChaChaPoly_SHA256`. Neither gives
  our suite special attention, so we would own its maintenance either way.
- **snow** (Rust): adds a Rust toolchain to a C and Objective-C build. **CryptoKit**: Swift only, no BLAKE2b.
- **TLS 1.3 with pinned raw keys**: no anonymous NN, no IK-style hiding of who may connect, awkward over
  L2CAP streams, different per toolkit for the GTK port.
- **Double Ratchet**: reopened only with a mailbox, using a maintained library (brief).

## Consequences

- We own about 600 lines of security-critical C; the vectors and the independent review are the price.
- An identity is two keys; the identity area stores both in one item and signs host challenges with Ed25519.
- The wire format has no Apple types, so later Linux and Windows clients can speak it.
- A single text message is capped at 32 KiB; longer text is refused by the composer, not split.
- The 10^-6 bound on comparison codes holds per attempt, and a failed attempt shows as codes that differ only if
  every attempt reaches a person: an initiator can learn the responder's code and close before any application
  frame. The helper therefore runs the exchange only for a request the person can see (Review amendments, 1).
- IK and NN message 1 can be replayed (spec § 7.7), so a captured message 1 still costs the responder a lookup;
  the replay cache and the admission limits bound that cost, and nothing acts before HELLO.
- Every early refusal closes after the same delay, so each probe of a hidden listener costs a stranger that delay
  and tells them nothing about whose listener it is.

## Verification

- The vector suite above, plus golden vectors for preamble, cert, code derivation and Rekey, cross-checked
  once by the reviewer against an independent Noise implementation.
- Fake streams with fault injection: truncation, every-byte corruption of a recorded session, disconnect
  mid-chunk, delay, duplicate delivery. Fuzz the frame, field and payload decoders (libFuzzer, corpus kept).
- The Security and Delivery rows of the M1 release gates.

## What the independent security review must cover

The reviewer is not the author. Findings block release until fixed or explicitly accepted by the owner.

1. The state machine against Noise rev 34: every token, `Split()`, empty-key paths, nonces, all-zero DH.
2. The static-key cert and identity binding; a known Friends ID arriving with a new key is a stranger.
3. The code commitment: binding to `h`, message order, nonce size, reduction bias, no code shown early.
4. Work done before authentication: allocation and CPU per connection, listener rate limits, NN floods.
5. Frame and field parsing limits, unknown-type handling, fuzzing results.
6. Replay: IK message 1, ACK / ACCEPT / PROGRESS reused across sessions, dedupe keys.
7. Transfers: unsolicited chunks, offset and length checks, window bounds, digest before publish, resume binding.
8. Key handling: zeroisation, no key material in logs or snapshots, randomness source.
9. Presence tags and NN uniform replies (ADR 0004): linkability and timing.
10. Downgrade: preamble and prologue binding, minor-version negotiation.

## Corrections

Recorded on 2026-10-12 after the M1 build wave, where the session area fixed details this record left open. The
header `friends/service/session/SZFriendsSession.h` holds the numbers.

- **Route class is required for XX and IK.** The initiator's route class is an `SZFriendsRouteMethod` value, 1
  (LAN) to 5 (relay). A channel refuses to start an XX or IK attempt without one, and a responder refuses an
  initiator that declares none, so the session race only ever compares real classes. NN carries none.
- **Handshake payload tags.** The payload fields use the transport frames' tag-length-value encoding with tags
  24 (lowest minor, u16be), 25 (highest minor, u16be), 26 (capability bits, u32be; none defined in M1, unknown
  bits ignored) and 27 (route class, u8). They appear only in handshake payloads, never in a transport frame.
- **CLOSE reasons.** CLOSE carries a reason byte, for logs on both sides: 0 normal, 1 protocol error, 2 superseded
  (lost the session race), 3 expired (24 hours, redial), 4 shutting down (helper exit, handover, Friends turned
  off), 5 comparison-code commitment failed. The values are wire values and are never renumbered.
- **Handshake timeout.** A handshake that has not gone live 10 seconds after it started closes, so a silent or
  trickling peer cannot hold a listener's connection (review item 4, work before authentication).
- **REQUEST_BY_ID signature.** The requester signs with its Ed25519 identity key, domain `"SZFriends request v1"`,
  over `h || Token || CallbackSecret || StaticKey || FriendsID`: the NN handshake hash (64 bytes), the request
  token (16), the callback secret (32), its X25519 static key (32) and the UTF-8 Friends ID. Binding `h` makes the
  request verify only inside the session it was made for, so it cannot be relayed or replayed into another, and
  signing the fields means none can be swapped. The responder sends RECEIVED before verifying or looking
  anything up (ADR 0004).
- **File acknowledgements.** The recipient acknowledges a finished file, after DONE and the whole-file digest, with
  an ACK carrying the transfer's id, the same id as its OFFER. Expected ACKs that share an id are matched oldest
  first, and only within the session that sent the frames they acknowledge, so an ACK never settles an item another
  session or another friend sent.
- **Crossed requests.** When two people send each other a request before either answers, each side takes the
  other's request as the acceptance of its own: both become friends at once, and the request session runs the
  comparison-code exchange as for any first contact.
- **Attestation field** (recorded 2026-10-13, wave-3 re-check). Handshake payloads that carry a certificate (IK
  messages 1 and 2, XX messages 2 and 3) and PROFILE may carry tag 28, the sender's host-issued Friends ID
  attestation, 1 to 512 bytes and opaque to the session; NN never carries it, because it names the identity. The
  channel exposes it unverified (`remoteAttestation`) beside the verified 96-byte certificate (`remoteCertificate`);
  the helper checks it against the pinned host keys and the certificate's identity key before believing the ID
  (ADR 0004, Review amendments, 9). A responder's admission hooks also learn when a complete message 1 has arrived
  and when the initiator is known (`SZFriendsByteStream`), which the adapters use to hold places only briefly
  (ADR 0004, Review amendments, 10).
- **THUMBNAIL, session minor 1** (recorded 2026-10-13, wave 6a; ADR 0008). Frame type 23 carries a file offer's
  preview: ID (the offer's), Width (tag 30, u16be), Height (tag 31, u16be) and Data (23 to 64,000 bytes of QOI,
  `SZFriendsFrameThumbnailMax`). It is the first frame of minor 1, so `SZFriendsSessionMinor` is 1 and the handshake's
  minor range is 0 to 1; a helper sends THUMBNAIL only to a peer whose range reaches 1, because an older one closes the
  session on an unknown type and the sender would resend on every reconnect. It travels in the chunk queue, so messages
  overtake it, and is sent only after its OFFER was written or acknowledged and only while the offer is queued or
  offered. The recipient acknowledges every THUMBNAIL that passes the codec, kept or refused, so acknowledgements that
  share an offer id stay matched oldest first (File acknowledgements, above).
- **CHAIN, session minor 2** (recorded 2026-10-14; ADR 0012). Frame type 24 carries one field, Chain (tag 33, 3 to
  64,000 bytes, `SZFriendsFrameChainMax`): the sender's encoded device chain, opaque to the session and verified by the
  identity area. `SZFriendsSessionMinor` is 2 and the handshake's range 0 to 2; a helper sends CHAIN once per live XX
  or IK session with a friend whose range reaches 2, never in NN. It travels in the control queue.
- **Frame fuzzing is in place** (recorded 2026-10-13). The fuzzing Verification asks for runs the session frame and
  field parser, THUMBNAIL included, under libFuzzer (`friends-thumbnails-fuzz`, harnesses in
  `service/thumbnails/fuzz/`); its corpus is kept there and every entry is replayed under the sanitizers by
  `friends-thumbnails-check`, so a crash a fuzz run once found stays found.

## Review amendments

Recorded on 2026-10-12 from the independent security review of the M1 build, which found the Noise state machine,
nonces, Split, Rekey, frame parsing and chunk bounds sound and the gaps in what the helper must enforce around
them. Each amends the decision above and names the finding it answers; the headers named hold the numbers.

1. **Codes only after a visible request.** The responder starts the comparison-code exchange only once the
   REQUEST frame has been durably recorded as an incoming request the person can see, and never replaces a
   stored code silently: a new session from the same key is a new visible event. XX admissions on a public entry
   are rate-limited per listener and per remote address. Without this an attacker who copies someone's public
   profile could open about 10^6 invisible XX sessions during their five visible minutes until both codes match
   (finding: comparison-code grinding).
2. **Nothing acts before HELLO.** The key policy that decides on IK message 1, XX message 3 and NN message 1 is
   pure: it writes nothing to the store, records no nearby fact, consumes no token and marks nothing seen, and may
   only count toward a rate limit. Store writes start at the session's establishment, after the initiator's
   HELLO, which cannot be replayed (`SZFriendsRemoteKeyPolicy` in `SZFriendsSession.h`; finding: work before
   authentication).
3. **Replay.** A responder records the initiator's ephemeral key from IK and NN message 1 once message 1 has
   decrypted, before its payload and the key policy, and refuses a message 1 whose key it already holds within the
   replay window (`SZFriendsReplayCache`), so a captured message 1 reaches the key policy once (finding: IK replay).
   Junk and IK sealed to another listener never enter the shared cache, so they cannot evict a friend's message 1
   to replay it (finding: replay cache eviction flood).
4. **Admission.** Listeners admit a pattern before any Diffie-Hellman, against per-minute rates for XX and NN
   (NN 60 a minute, ADR 0004) and a cap on sessions with people who are not friends; a handshake not live after
   `SZFriendsHandshakeTimeout` closes. Sessions with strangers close after an idle minute without an application
   frame, and an NN session shortly after its RECEIVED, identically for every device
   (`service/helper/nearby/SZFriendsNearbyAdmission.h`; findings: work before authentication, no idle limit).
5. **Refusals look alike.** Any refusal before the responder's first reply (decryption failure, bad certificate,
   key policy, admission limit, replay, unknown preamble) reads nothing more and closes exactly
   `SZFriendsRefusalDelay` after the deciding bytes arrived, whatever the reason. The reasons cost different
   work, and the review measured an 85 µs gap that let anyone holding a person's static key pick out their hidden
   listener (finding: refusal timing).
6. **One identity key per conversation.** A conversation is bound to the identity key that created it; a
   different identity key is always a new conversation, and the store refuses to re-bind one. A changed static
   key is accepted only when certified by the same Ed25519 identity key, and only after the person reviews it
   (`accept_key_change`); a known Friends ID arriving with a new identity key is a stranger (finding: key binding).
7. **Signature domains.** The domains in use are prefix-free and the identity area refuses an empty domain or one
   that is a prefix of another (`SZFriendsIdentity.h`). The next signature format frames the domain explicitly (a
   length byte or a terminator) so this no longer rests on a list (finding: domain separation).

Recorded on 2026-10-13 from the wave-4 security re-check and the assistant work.

8. **Handshake messages a responder reads are bounded.** A responder refuses any handshake message longer than
   1,024 bytes (`SZFriendsResponderHandshakeMax`) on its length prefix, before buffering its body and before any
   Diffie-Hellman, with the same refusal delay as every other refusal. The longest honest one, IK message 1 with a
   certificate, a token and a 512-byte attestation, is 750 bytes. Message 1 could be 65,535 bytes, and only the
   listener it is sealed to decrypts and hashes the payload, so a padded message 1 made that listener measurably
   slower through the helper's shared queue: 214 µs against 92 µs in the re-check's probe, a larger gap than
   amendment 5 closed (finding: session refusal timing through the shared queue).
9. **ViaAssistant.** MSG and OFFER may carry tag 29, one byte, 1 when the sender's assistant sent the message or
   file for them (PROTOCOL.md `via_assistant`), so the recipient's app can say so. Absent means the person sent it;
   any value but 0 or 1 fails the frame, and an older peer ignores the unknown tag and shows nothing.
