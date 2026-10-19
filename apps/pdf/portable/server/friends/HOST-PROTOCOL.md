# Shenzhen Friends host protocol

The contract between the Friends helper and the Friends host service, and between hosts. The decision behind it
is [ADR 0005](../../friends/docs/adr/0005-friends-host-service.md); the helper's side is
`portable/friends/service/host/SZFriendsHostConnection.h`; this service's side is `src/`. When code and this
document disagree, one of them is a bug: fix whichever is wrong in the same change.

This document is version 1, which every version keeps. Version 2 adds online Friends (rendezvous, connection setup,
download links, relay credentials, STUN and TURN): [HOST-PROTOCOL-ONLINE.md](HOST-PROTOCOL-ONLINE.md). Version 3 lets
one person check in from several devices ([§ Devices](#devices)).

- [Versioning](#versioning)
- [Transport](#transport)
- [Check-in](#check-in)
- [Devices](#devices)
- [Messages from helpers](#messages-from-helpers)
- [Messages from the host](#messages-from-the-host)
- [Signatures](#signatures)
- [Reservation results](#reservation-results)
- [ID attestations](#id-attestations)
- [Errors, close codes and limits](#errors-close-codes-and-limits)
- [The signed host list](#the-signed-host-list)
- [Host links](#host-links)
- [Changing this protocol](#changing-this-protocol)

## Versioning

| Name | Value | Declared in |
|---|---|---|
| Protocol version | `3` on the host, which also serves `1` and `2`; `3` in the helper, which sends the messages of version 2 only once a welcome says `online` | `HOST_PROTOCOL_VERSION` (`src/protocol.js`), `SZFriendsHostProtocolVersion` (helper) |
| URL path | `/v1` | `WS_PATH`; the production URL is `wss://friends.meerkat.orgabots.com/v1` |
| Message version `v` | `1` | `WIRE_VERSION`; every message carries it |

From protocol 3 the host's `challenge` says its protocol (`protocol`). The helper checks in with protocol 3 where it
says 3 or more, and with protocol 2 on a host whose challenge says none (one from before protocol 3, which would
refuse protocol 3's signature): there every device checks in as its own person, as before. **Every host in the list
must run protocol 3 before an app with several computers per profile ships**: on an older host a computer that
joined a profile reserves nothing, its ID is not the person's there, and friends do not reach it online.

The helper sends its protocol version in every check-in. The host answers `update_required: true` when that
version is below its configured minimum (`FRIENDS_MIN_PROTOCOL`, default 1): online Friends needs a newer app,
while reading and Nearby keep working. The check-in is still counted and the ID still reserved. A helper that
declares 2 or more may also send the messages of [HOST-PROTOCOL-ONLINE.md](HOST-PROTOCOL-ONLINE.md), and its
`welcome` says whether this host takes them (`online`); everything below is the same for both versions.

## Transport

- One WebSocket over TLS on port 443, through the server's nginx ingress, which proxies only `/v1`.
- JSON text frames. A helper sends at most 8 KiB per message, fragments included; only its check-in, the first
  message, may be up to 96 KiB, because from protocol 3 it may carry a device chain (§ Devices). The host sends at
  most 64 KiB (a signed list is the largest). Over the limit the host closes with 1009. A binary frame or anything
  that is not a JSON object with a string `type` and an integer `v` closes the connection.
- Binary values (keys, challenges, signatures, hashes) are base64url without padding, in canonical form: the URL
  alphabet only, unused trailing bits zero. Both sides refuse anything else, so two strings never name one key.
- Receivers ignore fields they do not know. Hosts ignore unknown message types on host links; on helper
  connections an unknown type closes the connection, because helpers and hosts move to a new type together.
- The host pings every 25 s and drops a connection that has not answered the previous ping. The helper pings every
  25 s too and treats a pong missing for 15 s as a closed connection. Pings keep NAT mappings and the ingress's
  120 s idle timeout alive.
- One live connection per identity on each host: a newer authenticated connection closes the older one (code
  4000).

## Check-in

```
helper                                   host
  |  <-- challenge {host_id, nonce, time} --|   on connect
  |  --- checkin {..., sig} -------------->  |   within 10 s, or the host closes
  |  <-- welcome {reservation, ..., attestation, host_sig}
  |  --- reserve {friends_id} ------------>  |   only after "taken" or "invalid", or later after "unavailable"
  |  <-- reserve_result {..., attestation, host_sig}
  |  <-- host_list {host_list} -------------|   whenever a newer list is published
  |  --- release {..., sig} -------------->  |   Reset Friends; also accepted instead of a check-in
  |  <-- released {released, host_sig} -----|   then the host closes (4001)
```

`welcome`, `reserve_result` and `released` carry `host_sig`, the host's signature over this connection's challenge
and the reply (§ Signatures), made with the host key the signed list gives that host. The helper checks it against
the list entry's `public_key`; an answer that does not verify counts as `unavailable` (and `released` as `false`),
so a TLS-intercepting proxy can neither rename anyone nor fake a release. The helper also takes a reserved
`friends_id` only when it is two or three words of its word list in canonical form, and, in a `reserve_result`,
only when it is the ID just asked for; a `welcome` may name another ID when this key already holds one on record.

The helper connects to the highest-priority rendezvous host in its signed list, trying every URL of every
rendezvous host in priority order, and signs only for a host whose challenge names the `host_id` the list gives
that URL. After every host fails, or a connection drops, it waits `1 + jitter × (min(300, 2^attempt) − 1)` seconds
(1 s to 5 min) and starts over, at once after a network change. `attempt` returns to 0 only when a reservation
succeeds (or a new list or network change starts over), so a host that welcomes and then refuses every ID is
retried less and less often. A launch draws at most 40 fresh IDs in all.

## Devices

From protocol 3 one person may use Friends on several computers
([friends-multi-device.md](../../docs/plans/friends-multi-device.md);
[ADR 0012](../../friends/docs/adr/0012-device-chain.md)). A person is their **root key**, the identity key of their
first device; every other device has its own Ed25519 **device key**, and the person's **device chain** says which
device keys the root has added and which were revoked. A protocol 3 check-in is made by the device with its own key
(`identity_key`), names the person (`root_key`), and brings the chain (`chain`); the root itself may leave it out, and
the helper's first device brings it once the person has other devices, so every host learns of the ones removed.
Everything else follows from that:

| Belongs to the person (root key) | Belongs to the device (device key) |
|---|---|
| The Friends ID, its reservation and its attestation (`identity_key` in the attestation is the root key) | The connection: one live connection per device, so a person's devices never replace each other |
| The statistics' people (unique users), app and list versions | The statistics' devices, joins and revocations |
| The rendezvous key their records are filed under (HOST-PROTOCOL-ONLINE.md) | Each record's signature, the message and open budgets, download links |

The host reads the chain exactly as the helper does (`src/device-chain.js`, checked against
`test/vectors/device-chain-v1.json`, which the helper's own code wrote): the format, every signature and consent (with
libsodium's refusals: a public key or signature point of small order, a key that is not canonical), the structure,
and the rules that decide which devices count. It accepts the check-in only when the chain verifies from
`root_key` and authorizes `identity_key`; a device the chain revokes gets `device_revoked` and close 4002, anything
else `bad_chain` and 1008. A device with no chain must be its own root. Device names and systems in the chain are
checked for length and UTF-8 only, so the host never refuses a chain a helper accepts.

The host keeps nothing of the chain but its **revocations**: for each revoked device, a keyed hash of the device key
and the hash of the link that revoked it, under the person, on every host that saw it, for a year after the last
chain that carried it. A device with such a row is refused (4002) unless the chain it brings holds that link and still
authorizes it (the rules voided that revocation, and the row goes). So a revoked device cannot check in with a chain
from before its revocation once any of the person's devices has checked in with a newer one there, and a device that
is connected when a chain revoking it arrives is disconnected (4002). A helper that declares protocol 1 or 2 is its
own root: it checks in as before and is refused only when a chain revoked its key. What the host cannot know: a
revocation no device has yet brought to that host.

The Friends ID is the person's, so the root's `release` (Reset Friends on the first device) frees it only while the
chain the connection checked in with lists no other authorized device: otherwise the host answers `released: false`
and the ID stays with the person's other devices. The helper does not even send it then.

## Messages from helpers

```schema checkin
identity_key: base64url(32)   # Ed25519 identity public key; from protocol 3 the device key
friends_id: string            # the ID to reserve, or the one the store believes reserved (max 64 characters)
reserved: bool                # whether the store believes it is reserved
app_version: string           # [A-Za-z0-9][A-Za-z0-9.+_-]{0,47}, e.g. 26.10.12-1
protocol: integer             # 1..1000
list_version: integer         # the host-list version the helper holds, 0 if none
root_key?: base64url(32)      # protocol 3 and later, required: the person's root key (identity_key on the first device)
chain?: base64url             # protocol 3 and later: the person's device chain, 3 to 64,000 bytes; required unless
                              # root_key is identity_key (§ Devices)
sig: base64url(64)            # § Signatures
```

```schema reserve
friends_id: string            # a fresh draw after "taken" or "invalid"
```

```schema release
identity_key: base64url(32)
friends_id: string            # informational; may be empty. The host finds the row by key.
sig: base64url(64)            # § Signatures, over this connection's challenge
```

A connection that has checked in may release only the identity that checked in.

## Messages from the host

```schema challenge
host_id: string               # this host's id in the signed list
nonce: base64url(32)          # fresh random bytes for this connection
time: string                  # RFC 3339, informational
protocol: integer             # from protocol 3: the host's protocol version; absent on older hosts
```

```schema welcome
reservation: enum(reserved,taken,invalid,unavailable)
friends_id: string|null       # the ID now reserved for this key; null unless reserved
update_required: bool
host_list: object|null        # a newer signed list (§ The signed host list) when the helper holds an older one
attestation: object|null      # with "reserved" only (§ ID attestations); not covered by host_sig
host_sig: base64url(64)       # § Signatures, host reply
```

```schema reserve_result
reservation: enum(reserved,taken,invalid,unavailable)
friends_id: string|null
attestation: object|null      # with "reserved" only (§ ID attestations)
host_sig: base64url(64)
```

```schema host_list
host_list: object             # the envelope; the helper verifies it like any other copy
```

```schema released
released: bool                # true: the host no longer holds this identity or its ID; false: the allocator
                              # could not be reached (a replica whose main host is down)
host_sig: base64url(64)
```

```schema error
code: enum(bad_request,bad_signature,checkin_timeout,not_checked_in,too_many_reservations,rate_limited,internal,
           bad_chain,device_revoked)
message: string               # for logs; never shown to people
```

## Signatures

Every signature is Ed25519 over `UTF-8(domain) || message`, the identity area's convention
(`SZFriendsIdentity -signatureForMessage:domain:`), with a domain per purpose so a signature made for one never
verifies as another. `message` is a fixed sequence of fields, each a 4-byte big-endian length followed by the
field's bytes, so no JSON canonicalisation is needed and no field can run into the next.

| Purpose | Domain | Fields, in order |
|---|---|---|
| Check-in | `SZFriends checkin v1` | host id, challenge (32 bytes), identity key (32 bytes), Friends ID, `1` or `0` for `reserved`, app version, protocol (decimal), list version (decimal); from protocol 3 also the root key (32 bytes) and the SHA-256 of the chain (32 bytes, or empty without one) |
| Release | `SZFriends release v1` | host id, challenge, identity key, Friends ID |
| Host link | `SZFriends host link v2` | main host id, challenge, replica host id, replica nonce, replica key share |
| Host link welcome | `SZFriends host link welcome v2` | main host id, replica host id, challenge, replica nonce, replica key share, main host key share |
| Host reply | `SZFriends host reply v1` | challenge, SHA-256 of the reply body (both 32 bytes) |
| ID attestation | `SZFriends id attestation v1` | host id, Friends ID, identity key (32 bytes), day (`YYYY-MM-DD`) |
| Host list | `SZFriends host list v1\n` | the payload bytes, as one unprefixed run |

A host reply's body is itself length-prefixed fields, so the digest names them unambiguously. `requested` is the
`friends_id` of the check-in or `reserve` being answered, so one answer never verifies as another's; absent values
are the empty string:

| Reply | Body fields, in order |
|---|---|
| `welcome` | `welcome`, requested, reservation, friends_id, `1` or `0` for update_required, the host list's `payload` string |
| `reserve_result` | `reserve_result`, requested, reservation, friends_id |
| `released` | `released`, `1` or `0` |

Messages on a host link are authenticated with HMAC-SHA256 rather than signatures (§ Host links). The link key is
HKDF-SHA256 (RFC 5869, 32 bytes) with the X25519 shared secret of the two key shares as input keying material,
`FRIENDS_REPLICA_SECRET` as salt, and as info `SZFriends host link key v2` followed by the length-prefixed main host
id, replica host id, challenge, replica nonce, replica key share and main host key share. A share whose shared secret
is all zeros is refused. Each message's `mac` is the HMAC with that key of the length-prefixed direction
(`main to replica` or `replica to main`), sequence number (decimal) and body.

Strings are UTF-8. Naming the host id stops one host from replaying a helper's signature to another; the
challenge stops replays to the same host. `test/vectors/host-list-v1.json` holds worked examples (TEST keys from
public seeds) that both this service's tests and the helper's tests check byte for byte.

## Reservation results

The main host (§ Host links) decides in one `BEGIN IMMEDIATE` transaction:

| Result | Meaning | The helper |
|---|---|---|
| `reserved` | `friends_id` is this key's. If the key already held an ID, that ID, whatever was asked: a reinstall that kept its key adopts it | Records it. After a collision on this connection it shows the rename notice, naming the first ID it claimed |
| `taken` | Another key holds it; first reservation wins | Draws a fresh ID (three words after three collisions in a row, ADR 0006) and sends `reserve` |
| `invalid` | Not two or three lowercase words of 3 to 8 letters joined by hyphens. The host checks syntax only, never the word list | As `taken` |
| `unavailable` | Nothing was allocated: a replica could not reach the main host in time, this client address has had its three new IDs for the day, the replica the request came through has had its new IDs for the day, or the main host's ID table never finished copying from the previous main host (§ Host links). The helper also treats an answer it cannot verify this way | Keeps the ID unreserved, stays connected, asks again after 1 min doubling to 15 min |

## ID attestations

Anyone nearby who hears an Add by ID can answer it, and nothing offline ties a Friends ID to a key (ADR 0004). The
host can: with every `welcome` and `reserve_result` that says `reserved`, it signs who holds the ID.

```schema attestation
host_id: string               # the host that signed: the one this connection reached (a replica signs as itself)
friends_id: string            # the ID reserved
identity_key: base64url(32)   # the key it is reserved for: this connection's
day: string                   # YYYY-MM-DD in UTC, the day the host signed it
sig: base64url(64)            # Ed25519 by the host key the signed list gives host_id, § Signatures
```

The helper checks it as below for its own key and the ID just reserved, keeps the newest (in `host-attestation.json`
beside the cached list), and can show it when it answers an Add by ID, so the requester can tell the ID's holder
from anyone else. Every check-in brings a fresh one. A requester believes an attestation, in this order, when
`host_id` is a rendezvous host (role `rendezvous` or `both`) in its own verified list, `sig` verifies with that
entry's `public_key`, `friends_id` and `identity_key` are the ones claimed, and `day` is at most 30 days before its
own UTC date and at most one day after it. `SZFriendsHostAttestationCheck` (helper) and `checkAttestation`
(`src/attestation.js`) give the same verdicts on the shared vectors (`test/vectors/host-list-v1.json`,
`attestations`).

What an attestation does not prove: an ID freed (Reset Friends, or its holder stopped checking in) and given to someone
else stays attestable by its previous holder until that holder's last attestation lapses, at most 30 days later; and a
listed host that is compromised can attest anything until a list without it is published.

## Errors, close codes and limits

| Close code | When |
|---|---|
| 1000 | Normal |
| 1001 | The host is shutting down |
| 1008 | A malformed message, an unknown type, a bad signature, or no check-in within 10 s |
| 1013 | Rate limited, too many reservations on one connection, or an internal error: try later |
| 4000 | Replaced by a newer connection for the same identity |
| 4001 | After `released` |
| 4002 | This device was revoked from its person's devices (`device_revoked`, § Devices) |

The helper backs off after every close except its own release, after which it stays stopped, and 4002, after which
it shows that the computer was removed from the profile and stops until the person sets Friends up again.

| Limit | Value | Configured by |
|---|---|---|
| Message size | 8 KiB from a helper, fragments included, except its check-in: 96 KiB; 192 KiB on host links; 64 KiB from the host | fixed |
| Check-in deadline | 10 s after the challenge | `FRIENDS_CHECKIN_TIMEOUT_MS` |
| Reservations | 20 per connection | fixed (ADR 0005) |
| New IDs | 3 per client address per day (statistics day); a key that already holds an ID always gets it back | `FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY` |
| New IDs through a replica | 200 per replica per day, on the main host, besides the replica's own per-address limit | `FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY` |
| Messages | 20 per 10 s per helper connection; host links exempt; online Friends messages have their own 200 per 10 s (HOST-PROTOCOL-ONLINE.md) | `FRIENDS_RATE_MESSAGES_PER_10S` |
| New connections | 30 per minute per client address, refused with HTTP 429 before the upgrade | `FRIENDS_RATE_CONNECTIONS_PER_MINUTE` |
| Open connections per address | 6, refused with HTTP 429 | `FRIENDS_MAX_CONNECTIONS_PER_ADDRESS` |
| Connections not yet checked in | 200 per host, refused with HTTP 503; they never take a checked-in slot | `FRIENDS_MAX_UNAUTHENTICATED` |
| Checked-in connections and host links | 5,000 per host, refused with HTTP 503 | `FRIENDS_MAX_CONNECTIONS` |

A client address is its IPv4 address or its IPv6 /64 (whoever has one address in a /64 usually has them all); an
IPv4-mapped IPv6 address counts as its IPv4 address. The limits count by a keyed hash of that prefix, with a key
drawn when the process starts, held only in memory: connection rates for 10 minutes after last use, open
connections while they are open, new IDs until the day ends. Behind the ingress the address comes from
`X-Real-IP`, believed only when the TCP peer is an address in `FRIENDS_TRUSTED_PROXY` (the ingress); from any other
peer the header is ignored and the event `proxy_untrusted` is logged at most once a minute. Many people behind one
NAT share one address's limits.

## The signed host list

```json
{"payload": "<base64url of UTF-8 JSON>", "sigs": [{"key": "primary", "sig": "<base64url(64)>"}]}
```

- 1 to 4 signatures; the list is valid when at least one verifies with a pinned key (the helper pins a primary and
  a backup; each host is configured with the same keys in `FRIENDS_PINNED_KEYS`). `key` is a label only.
- Clients parse exactly the payload bytes that were signed; nobody re-serialises before verifying.
- The whole envelope is at most 64 KiB.

```schema host-list-payload
version: integer              # 1 or more, only ever increases
issued_at: string             # RFC 3339 UTC, YYYY-MM-DDTHH:MM:SS[.fff]Z
new_id_words: integer         # 2 or 3 (ADR 0006 § Three-word threshold)
hosts: array                  # 1 to 32
hosts[].id: string            # [a-z0-9][a-z0-9-]{0,31}, unique; the host id signatures name
hosts[].role: enum(rendezvous,relay,both)
hosts[].urls: array           # 1 to 8; wss://, or ws:// only to 127.0.0.1, [::1] or localhost
hosts[].turn_uris?: array     # M2; strings of at most 512 characters
hosts[].region: string        # 1 to 64 characters
hosts[].priority: integer     # 1..1000; lower is preferred
hosts[].public_key: base64url(32)  # the host's Ed25519 key, for host links
```

Hosts are ordered by priority, then id. The **main host** is the rendezvous host (role `rendezvous` or `both`)
with the lowest priority; a list in which two rendezvous hosts share that priority is invalid, because two
allocators could grant one ID twice.

Freshness is the receiver's rule, not the parser's: a helper accepts only a higher version than it holds, rejects an
equal version with a different payload, caches the newest in `hosts.json`, and treats its bundled list as a floor.
A host accepts a list from the admin (dashboard `POST /lists`), from the main host (on a replica), or from
`FRIENDS_HOST_LIST_FILE` at start, only when it verifies and is newer, then pushes it to every checked-in helper
holding an older version and to its replicas.

## Host links

Every host runs the same service; its role follows from the current list and its own `FRIENDS_HOST_ID`. A replica
connects to the main host's first URL with `?link=1` added (rotating through its URLs on failure), which gives the
connection the host-link message limit and allows nothing but `host_hello` as its first message; a helper
connection may not send `host_hello`. After the main host's `challenge` the replica sends:

```schema host_hello
host_id: string               # the replica's id, which must be in the main host's current list
sig: base64url(64)            # Ed25519 by the host key that list names for the replica, domain "SZFriends host link v2"
mac: base64url(32)            # HMAC-SHA256 of the same signed bytes with FRIENDS_REPLICA_SECRET
identity_check: base64url(32) # HMAC-SHA256 with FRIENDS_IDENTITY_SECRET of "SZFriends identity secret check v1" || challenge
nonce: base64url(32)          # fresh random bytes the main host must sign
key_share: base64url(32)      # a fresh X25519 public key, for this link only; covered by sig and mac
```

All three checks must pass; no secret travels. The main host answers

```schema host_welcome
host_id: string
host_list: object             # its current list
key_share: base64url(32)      # a fresh X25519 public key, for this link only
sig: base64url(64)            # Ed25519 by the host key the list names for the main host, domain "SZFriends host link welcome v2"
```

and the replica believes nothing from the link (no ID table, no answer) until `sig` verifies. That ends the handshake.
Both hosts then derive the link key from the two key shares (§ Signatures) and forget the private halves. Every
message after the handshake, in both directions, travels in an envelope authenticated with that key:

```schema link
seq: integer                  # 1 for each side's first message after the handshake, then one more per message
body: string                  # the message itself, as JSON text
mac: base64url(32)            # HMAC-SHA256 with the link key over direction, seq and body
```

The receiver accepts only the next `seq` from the other side with a `mac` that verifies, then reads `body`; anything
else, including a message outside an envelope, drops the link, and the replica reconnects.

What this protects against: only the two ends of a link can compute its key, because only they ever held the private
halves of its key shares. Each share is signed with its host's key from the list, and the welcome's signature covers
both, so a share swapped in transit breaks a signature and the link is refused. Someone who can intercept TLS between the
hosts and relay the handshake therefore can neither inject, rewrite, replay, reorder nor reflect a message, even when
they also hold `FRIENDS_REPLICA_SECRET`, as every replica does. It does not hide link messages, which TLS protects
from onlookers, and it does not limit what a host does on its own link (below). Then:

| Replica sends | Main host answers | Purpose |
|---|---|---|
| `fwd_reserve {req, friends_id, after_collision, allow_new, proof}` | `fwd_reserve_result {req, reservation, friends_id, granted}` | Reservation by the only allocator; `after_collision` counts renames, `allow_new` false means the helper's address has had its new IDs today, `granted` says a new ID was given. The main host grants each replica at most `FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY` new IDs a day |
| `fwd_release {req, proof}` | `fwd_release_result {req, released}` | Reset Friends through a replica |
| `fwd_summaries {items: [{seq, identity_hash, device_hash, day, app_version, list_version, protocol}]}` | `ack {through}` | Check-in summaries, at most 200 per batch, kept in the replica's database until acknowledged; counted only for identities whose `proof` this replica forwarded in the last 31 days |
| `report {minute, day, connections, list_versions}` | none | Connections and their list versions, once a minute |
| | `host_list {host_list}` | A newly published list, which the replica verifies and pushes on |
| | `id_sync_begin {}`, `id_sync_page {rows}`, `id_sync_end {}` | The whole ID table, on every link-up, in pages of at most 400 rows `[identity_hash, friends_id, first_day, last_day]` |
| | `id_set {identity_hash, friends_id, first_day, last_day}`, `id_unset {identity_hash}` | Every grant and release afterwards, and each ID holder's new last check-in day |

`proof` is the helper's own signed message as the replica received it, with the replica's challenge: for a
reservation `{host_id, challenge, identity_key, friends_id, reserved, app_version, protocol, list_version, root_key?,
chain?, sig}` (the check-in; later `reserve` messages on the connection reuse it), for a release
`{host_id, challenge, identity_key, friends_id, sig}`. The main host checks that `host_id` is the linked replica's
and that the helper's signature verifies for it, reads the device chain itself (§ Devices) and computes the person's
identity hash from the root key, and otherwise answers `unavailable` or `released: false`. In a summary,
`identity_hash` names the person and `device_hash` (the same keyed hash of the device key; absent from replicas
before protocol 3, meaning the same as `identity_hash`) the device. A compromised replica can therefore act only
for helpers that really signed to it, and never release an ID its owner did not give up.

What a compromised replica (its host key and both secrets) can still do is bounded. It can make up identity keys and
sign check-ins for them, so the main host grants it at most `FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY` new IDs a day (default
200; counted in memory per statistics day), and the main host's dashboard says when a replica reached that. A replica's
summaries count only for identities whose own signed check-in it forwarded (`proof` in `fwd_reserve`), remembered by
identity hash, replica and day for 31 days, so it cannot keep other people's rows alive or count made-up names. A
replica sends a check-in's summary after forwarding its reservation, so with the link up every summary has its proof;
check-ins of people new to that replica during a main-host outage are not counted.

`identity_hash` is HMAC-SHA256 with `FRIENDS_IDENTITY_SECRET` of `"SZFriends identity hash v1" || identity key`,
the only name for an identity in any database. Every host uses the same secret, so the main host counts unique
users across hosts with it; it is keyed because every friend knows a person's public key. A replica answers
`unavailable` when a forwarded request gets no answer within 5 s (`FRIENDS_FORWARD_TIMEOUT_MS`) or the link is
down; it never allocates. Summaries count for the day the replica saw them (statistics days use
`FRIENDS_STATS_TZ`, which must be the same on every host), unless older than 30 days.

**The ID table on replicas.** Each replica keeps the main host's (identity hash, Friends ID, first and last
check-in day) rows, so it can become the main host without handing anyone's ID to the first claimant. Its state is
on its dashboard: `synced` once a full copy has arrived, `unsynced` before. A host made main host allocates only
when its table is the reference (it was main host before, or started as the first main host on an empty
database) or a synced copy; otherwise it answers `unavailable` to every reservation until the admin sets
`FRIENDS_ALLOW_UNSYNCED_MAIN=1` (DEPLOY.md, "Replacing the main host"). Only a main host that may allocate sends its
table, so an unsynced one never overwrites a good copy.

## Changing this protocol

- Adding an optional field, a new message from the host, or a new host-link message: same version. Receivers
  ignore what they do not know.
- Host links have no version of their own: the envelope above, and later the key shares, made earlier hosts unable
  to link with later ones, so every host in a list is updated together (DEPLOY.md).
- Anything that changes what is signed, removes or retypes a field, or needs the helper to send a new message type:
  bump the protocol version on both sides in one change, keep `/v1` serving the old version for at least one app
  release, and raise `FRIENDS_MIN_PROTOCOL` only when the dashboard's app versions show the old one has gone.
- Regenerate the vectors with `node test/vectors/make-vectors.js --write` only for a deliberate change; both
  suites then prove the new bytes.
