# Shenzhen Friends host protocol, version 2: online Friends

The part of the host protocol that version 2 adds: rendezvous records, connection setup between apps, download
links, relay credentials and the STUN and TURN addresses. Everything in [HOST-PROTOCOL.md](HOST-PROTOCOL.md) stays as
it is and applies here too (transport, encoding, close codes). The decision behind it is
[ADR 0010](../../friends/docs/adr/0010-host-rendezvous-relay.md); this service's side is `src/online*.js`,
`src/rendezvous.js`, `src/signaling.js`, `src/stun.js` and `src/relay*.js`. When code and this document disagree, one
of them is a bug: fix whichever is wrong in the same change.

- [Who may send these messages](#who-may-send-these-messages)
- [Rendezvous records](#rendezvous-records)
- [Connection setup](#connection-setup)
- [Download links](#download-links)
- [Relay credentials](#relay-credentials)
- [STUN and TURN addresses](#stun-and-turn-addresses)
- [Between hosts](#between-hosts)
- [Signatures](#signatures)
- [Limits](#limits)
- [What the host keeps](#what-the-host-keeps)

## Who may send these messages

A helper that declares `protocol: 2` (or more) in its check-in may send the messages below once it has checked in,
on the same `/v1` connection. Its `welcome` then carries one more field, outside `host_sig`:

```schema welcome (protocol 2 and later)
online: bool                  # true when this host takes online Friends messages (FRIENDS_M2=on)
```

A helper sends nothing below while `online` is false. Anything else that sends one (a protocol 1 helper, a helper
before its check-in, any helper while `online` is false) is closed with 1008 `bad_request`, as for any unknown type.
Protocol 1 welcomes are unchanged.

These messages have their own budget, 200 per 10 s per connection, all of them together; check-in, `reserve` and
`release` keep their 20 per 10 s, so a burst of candidates never holds up an ID.

## Rendezvous records

A helper publishes one record per device key over that device's own checked-in connection, once in every period
(below): lookups show a record only during the period after the one it was published in. Each record carries a newly
sealed blob.

```schema rdv_publish
seq: integer                  # 0..2^53-1, larger than the previous record's (a millisecond clock will do)
expires: integer              # Unix seconds; after now and at most 900 s from now (host clock)
sealed: base64url(512)        # exactly 512 bytes, opaque to the host
sig: base64url(64)            # Ed25519 by the key that checked in, § Signatures
```

```schema rdv_published
seq: integer|null
accepted: bool
reason: enum(expiry,stale,rate_limited)|null   # stale: not newer than the record held, or sealed the same as it
shown_from: integer|null      # Unix seconds (host clock): the period in which lookups show this record; null if refused
```

A record that does not parse, has a sealed blob of another size or whose signature does not verify closes the
connection (1008, `bad_request` or `bad_signature`). Records are filed under the person's rendezvous key,
`rdv_key = SHA-256("SZFriends rendezvous key v1" || identity key)`, which every friend computes from the identity key
it already holds, one record per device key under it (§ Several devices). The host computes `rdv_key` from the root key
the device checked in for (HOST-PROTOCOL.md § Devices), which before protocol 3 is the checked-in key itself. A record
replaces only the same device's record. It lives in memory only, on every host in the list, and goes when it expires,
when the connection that published it closes, or when the link to the host it names goes down.

```schema rdv_lookup
req: integer
keys: array                   # 1 to 32 rdv keys, base64url(32) each
```

```schema rdv_records
req: integer
records: array|null           # one base64url(512) per key, in order; null when refused
reason: enum(rate_limited)|null
```

**Periods.** Lookups change only at the boundaries of 60-second periods of host time (Unix seconds divisible by 60;
the `challenge` carries the host's time). During a period every key gets exactly 512 bytes, the same on every host
and for the whole period:

- the sealed blob of the newest record published under that key during the previous period that was still live when
  this period began;
- otherwise filler: HMAC-SHA256 output keyed from `FRIENDS_IDENTITY_SECRET`, which depends only on the key and the
  period, so it too is the same on every host, after a restart, and for the whole period.

Without the presence secret a blob and filler cannot be told apart, and both change at every boundary, so looking a
key up again tells a stranger nothing. Coming online, going offline and records expiring show only at a boundary.
To stay visible a helper publishes once in every period, early enough for the record to arrive before the period
ends (a random moment in its first half will do; `shown_from` says which period it is for). A helper that misses a
period looks, for the next one, like nobody. Routing (`sig_open`) uses live records at once and tells the caller
nothing. The sealed blob's format (sealed under a key derived from the presence secret, signed inside by the device
key, freshly sealed each time) is the session area's.

**A limit across hosts.** Because filler is the same everywhere, two hosts answer differently for a key in the same
period only when one holds a live record the other does not. That happens while a link between hosts is down (each
side drops the other's records at once, so the next boundary shows filler on one host and the blob on the other),
and when a host's clock is more than about 30 s off, so that a record published early or late in a period lands in
a different period there. Someone who looks the same key up on two hosts at those times can tell that it has a live
record. Hosts keep their clocks synchronised (NTP) to narrow the second case; the first is not closed in protocol 2.

## Connection setup

```
caller helper                 host(s)                      target helper(s)
  | -- sig_open {req,to,payload} -->|                             |
  | <-- sig_opened {req,sid} -------|   at once, whatever exists  |
  |                                 | -- sig_incoming {sid,via,payload} -->   each target that is connected
  | -- sig_msg {sid,payload} ------>| -- sig_msg ---------------->|
  | <-- sig_msg {sid,payload} ------| <-- sig_msg {sid,payload} --|   a target answers, or stays silent
  | -- relay_credentials {req,sid} >|                             |   only once both sides have spoken
  | -- sig_close {sid} ------------>| -- sig_closed {sid} ------->|
```

```schema sig_open
req: integer
to: object                    # exactly one of:
to.rdv_key?: base64url(32)    #   a friend: every device of theirs that is connected; the first to answer wins
to.friends_id?: string        #   Add by ID online: the holder of a reserved ID
to.link_id?: base64url(16)    #   the helper serving a download link (the app opening a link)
to.join?: string              #   protocol 3: a join request to the holder of a Friends ID: every device of theirs
payload: base64url            # 1 to 4,096 bytes, opaque
```

```schema sig_opened
req: integer
sid: base64url(16)            # names this setup on every host
owner_online?: bool           # only for to.link_id
link_ended?: enum(revoked,expired)   # only for to.link_id: nobody holds the link and its tombstone says why; the
                              # sid then exists nowhere and nothing more comes (§ Download links, Tombstones)
```

```schema sig_refused
req: integer
reason: enum(rate_limited)    # this caller's own budgets, or 16 open sids on this connection
```

```schema sig_incoming
sid: base64url(16)
via: enum(rdv,id,link,join)   # how the caller named this helper
link_id: base64url(16)|null   # with via "link"
payload: base64url
```

```schema sig_msg
sid: base64url(16)
payload: base64url            # 1 to 4,096 bytes
```

```schema sig_close
sid: base64url(16)
```

```schema sig_closed
sid: base64url(16)
reason: enum(closed,gone,expired,limit,unknown,answered_elsewhere)
```

`sig_incoming` never says who is calling: the payload does, to the target alone (Noise IK for friends, NN for Add by
ID, both under signalling prologues the session area fixes), so the host sees neither identities nor candidates.

**What a caller can learn.** Nothing about a target that has not answered:

- `sig_opened` comes before any lookup and looks the same for a friend, a stranger, an ID nobody holds and an
  offline helper.
- A target refuses by staying silent. If it closes the sid, or disconnects, without having sent a `sig_msg`, its
  end simply becomes nobody: the caller keeps the sid until it expires, exactly as with no target at all.
- An end that has spoken ends the sid for both when it closes (`closed`) or disconnects (`gone`).
- A sid lives 120 s, then every end still on it gets `sig_closed` `expired`. Each direction carries at most 64
  `sig_msg`; the 65th ends the sid for both (`limit`). A `sig_msg` for a sid the connection is not part of gets
  `sig_closed` `unknown`; `relay_credentials` for one closes the connection (1008).
- Opens over a device's incoming budgets are dropped, and the callers cannot tell (§ Limits). One caller may
  deliver 10 a minute to one device, and one network (an IPv4 address or an IPv6 /56) 20; a device takes 60 a minute
  from callers it has not answered lately, and 30 more from callers whose opens it answered in the last 7 days, so a
  flood from strangers cannot keep out the people it talks to.

**Several devices** (ADR 0010's model). A person's devices each publish their own record, signed by that device's
key, all under the person's one `rdv_key`; each replaces only its own. An open to `to.rdv_key` reaches every
connected device that holds a live record under it, wherever it is: the caller's `sig_msg` go to all of them until
one answers; the first `sig_msg` from a target makes it the far end, and every other device gets `sig_closed`
`answered_elsewhere`. Only targets are told; the caller sees one sid and one answer, as with one device. A lookup of
the key shows the newest record published under it in the previous period. So a friend needs only the person's
identity key, which it already pins, to reach every device. Check-in proves a device belongs to the person (its
device chain, HOST-PROTOCOL.md § Devices) and the host files the device's record under the person's key, which is
the root key: the identity key friends pinned.

**Add by ID online.** `to.friends_id` is resolved with the host's copy of the ID table to the person holding it,
then to their devices' records, as an open by key reaches them. A helper that has published no record is unreachable
by ID, as it is by key.

**Join requests** (protocol 3). A new computer asking to join a person's profile sends `sig_open` with `to.join`, the
Friends ID the person typed. It reaches every device of the ID's holder that has a live record, wherever it is
connected, with `via: "join"`; the payload (the join request: the new device's keys, name, system and consent, as the
join area defines it) is opaque to the host, which keeps it only in the sid. The device the person approves on answers
with `sig_msg`, and the sid then carries the connection setup and the code exchange like any other; the others are
let go (`answered_elsewhere`), and a device that denies stays silent. A sid lives 120 s, so a new device still waiting
for an answer opens again (every 100 s will do), and devices recognise the request by its contents. Each device may
send 40 join requests an hour; a person receives at most 60 an hour from everyone together, and the rest reach
nobody, which the sender cannot tell from an ID nobody holds. Statistics count a join request as an open by ID.

Only download links say whether anyone is there (`owner_online`): whoever holds a link is told "waiting for the
sender's Mac" anyway.

## Download links

```schema link_register
link_id: base64url(16)        # random, chosen by the sender's helper
expires: integer              # Unix seconds, at most 31 days ahead
```

```schema link_registered
link_id: string
ok: bool
reason?: enum(taken,too_many)
```

```schema link_unregister
link_id: base64url(16)
```

```schema link_unregistered
link_id: string
```

The first identity to register a link id keeps it until it expires or that identity unregisters it, across
restarts: hosts keep who holds each live link by keyed hashes of the link id and the identity. The helper registers
each of its live links again on every connection; while it is not connected its links are offline. At most 50 live
links per identity.

**Tombstones.** Why a link stopped working, kept 31 days so that whoever opens it is told at once instead of
waiting. The sender's helper keeps, for each link it revoked or that expired, only `hash` = SHA-256(`SZFriends link
tombstone v1` ‖ the link id's 16 bytes), and sends them when the link ends (on Revoke, before `link_unregister`) and
again on every connection:

```schema link_tombstones
tombstones: array             # 1 to 64 of:
tombstones[].hash: base64url(32)
tombstones[].reason: enum(revoked,expired)
tombstones[].until: integer   # Unix seconds (host clock); after now and at most 31 days from now
```

Nothing answers it; anything out of bounds closes the connection (1008 `bad_request`). The host files each under
`tomb_key` = HMAC-SHA256(`FRIENDS_IDENTITY_SECRET`, `SZFriends link tombstone key v1` ‖ hash), with the sender's
identity hash, in the database, at most 500 per identity (those ending soonest go first). A tombstone ends the
sender's own binding of that link if it still has one (a link revoked while the host could not be told), and only
the link's holder replaces a tombstone someone else left; a tombstone never hides a link someone holds. A binding that
expires here leaves an `expired` tombstone of its own (the host computes `tomb_key` from the link id at
`link_register`). An open of a link (`link_open` or `sig_open` with `to.link_id`) that nobody holds and whose
tombstone is here is answered at once with `sig_opened` carrying `link_ended` and `owner_online` false, and no sid is
made; a guest's connection then closes (1000).

**Guests.** A browser opening a download link connects to `wss://<host>/v1?guest=1` (refused with HTTP 404 while
online Friends is off). It receives the usual `challenge`, ignores it, and must send within the check-in deadline:

```schema link_open
req: integer
link_id: base64url(16)
payload: base64url            # 1 to 4,096 bytes, opaque: sealed under a key derived from the link secret
```

and gets `sig_opened` with `owner_online`. After that it may send only `sig_msg`, `sig_close` and
`relay_credentials` for that one sid; anything else closes it (1008). When the sid ends, the host closes the guest
connection (1000). While the sender's helper is offline, the sid of a link someone registered waits up to 30 minutes
and is delivered as soon as that helper registers the link again; the 120 s lifetime starts then. A link nobody
holds gets the 120 s lifetime at once, and `owner_online` false, as for an offline sender, unless its tombstone says
why it ended (above). Guests count by address,
an IPv4 address or an IPv6 /56: 10 connections a minute, 4 open at once, of which 2 may wait for an offline sender
(a third open from that address gets the 120 s lifetime).

**The pages.** The browser gets there from the page the link opens, which this service serves at `/d` (and `/f` for
friend links), with its stylesheet and one script under `/links/` and the download page's service worker at
`/d/sw.js` (`src/link-pages.js`). Each response carries a Content-Security-Policy that allows only this host and its
WebSocket, `frame-ancestors 'none'` and `Referrer-Policy: no-referrer`; no cookies. The download page gets the
`stun:` URIs of `FRIENDS_TURN_URIS` written into it, never the `turn:` ones, which come only with credentials. What
the page and the sender's helper put in the opaque payloads, and on the data channel, is
[PROTOCOL.md § Links](../../friends/PROTOCOL.md#links), Browser downloads.

## Relay credentials

```schema relay_credentials
req: integer
sid: base64url(16)            # a sid this connection is part of
```

```schema relay_credentials_result
req: integer
username: string              # "<expires>:<attempt id>", the attempt id 16 random bytes in base64url
credential: string            # base64(HMAC-SHA1(FRIENDS_TURN_SECRET, username)): the TURN REST API scheme
expires: integer              # Unix seconds, 300 s from now
ice_servers?: array           # guests only: TURN URIs (FRIENDS_TURN_URIS); helpers use the signed host list
```

```schema relay_refused
req: integer
reason: enum(not_answered,rate_limited,no_relay)   # no_relay: this host runs no relay (FRIENDS_RELAY=off)
```

Credentials are given only for a sid on which both ends have spoken, at most 2 per end per sid, and at most 30 an
hour per identity. A guest has no identity: its credentials count against 60 an hour per link and 10 an hour per
address (an IPv4 address or an IPv6 /56). Each username allows at most 2 allocations at once. The username names an
attempt, never a person.

**How much of the relay one holds.** What is held counts each credential still unused and within its 300 s, and
each allocation coturn reports alive for a credential. A request is refused with `rate_limited` while any of these
is full, until something it counts ends:

- an identity, and a guest address, holds at most 4;
- a network, an IPv4 /24 or an IPv6 /56, holds at most 12, helpers and guests together: identities cost nothing to
  make, so the per-identity limit alone would let one machine fill the relay;
- the relay as a whole holds at most one per relay port (`FRIENDS_TURN_PORTS`, 256 unless the admin sets otherwise),
  and the last quarter of those (at least 4) is kept for pairs of friends: a credential comes from it only when the
  answering end had answered the caller in the last 7 days (the same memory as the opens' reserve, § Limits), and
  one pair holds at most 4 of it. On the answering end's host the caller's identity is not known, so there a pair is
  that end and the caller's host.

So people who fill the relay from many networks still leave room for friends who talk often. The host learns of
allocations from coturn's statistics, in memory only, and refuses a credential it could not keep count of.

**How long a relayed session lasts.** `expires` bounds when an allocation may start; coturn does not check it again
when the allocation is refreshed. An allocation, and each refresh, holds for at most 600 s. Whatever the refreshes,
the host ends every relayed session `FRIENDS_TURN_MAX_SESSION_S` after its credential was issued (an hour unless the
admin sets otherwise): the app sees its relayed connection drop and, if it still needs the relay, opens a new sid and
asks for a new credential, and the transfer resumes from where it stopped (ADR 0001). A download link's page and an
app opening one do the same: they open the link again and carry on from the first chunk not yet written
(PROTOCOL.md § Links, Browser downloads).

**What the relay reaches.** Only relays: its own addresses and those of the other relay hosts in the list. A
permission or channel for any other address is refused (403). So an app on a relay connection gathers, sends and
accepts relay candidates only, and the two ends of a relayed connection each use a relay, possibly on different
hosts.

## STUN and TURN addresses

They come from the signed host list, which is what makes them trustworthy: a relay host's entry has role `both` (or
`relay`) and `turn_uris` (already in version 1, strings of at most 512 characters):

```json
"turn_uris": ["stun:friends.meerkat.orgabots.com:3478", "stun:friends.meerkat.orgabots.com:3479",
              "turn:friends.meerkat.orgabots.com:3478?transport=udp",
              "turn:friends.meerkat.orgabots.com:3478?transport=tcp"]
```

Port 3478 is coturn, answering STUN Binding and TURN; port 3479 is the host's own STUN responder
(`FRIENDS_STUN_PORTS`), which answers well-formed Binding requests only, with XOR-MAPPED-ADDRESS and FINGERPRINT,
within a small budget per source. A helper sends Binding requests from one socket to both ports: one mapped port means
an endpoint-independent NAT; two different ones mean a NAT that maps each destination anew, where port prediction is
worth trying before the relay.

## Between hosts

Inside the authenticated host-link envelope ([HOST-PROTOCOL.md § Host links](HOST-PROTOCOL.md#host-links)). Every
message carries `origin`, the host it was produced on, and, unless it is for every host, `dest`. Links run between
each replica and the main host only, so the main host passes on what one replica sends for another; it drops
anything from a replica whose `origin` is not that replica.

| Message | Meaning |
|---|---|
| `rdv_record {identity_key, root_key?, host_id, seq, expires, sealed, sig}` | A record published on `host_id`, which must be `origin`. The receiver verifies the signature itself; `root_key`, present when the device is not its own root, is the person whose key the record is filed under, which `origin` checked at check-in |
| `rdv_withdraw {rdv_key, device_key, seq}` | That device's record is gone; removed only if it is still the one with `seq` (both keys hex) |
| `link_bind {link_hash, identity_hash, host_id, expires}` | A link served on `host_id`; the first holder of a link wins on every host |
| `link_unbind {link_hash, removed}` | The link went offline there; `removed` when its holder unregistered it |
| `link_tomb {tomb_key, identity_hash, reason, until}` | A tombstone left there (§ Download links); helpers resend theirs anyway |
| `sig_route {op: open, sid, via, link_id, identity_hash, known, payload}` | Deliver an open to the device `identity_hash` names, connected to `dest`; `known`: it answered this caller in the last 7 days, so the open may use its reserve |
| `sig_route {op: msg, sid, payload}` | A `sig_msg` from the end on `origin` |
| `sig_route {op: detach, sid}` | Every target on `origin` left without speaking |
| `sig_route {op: close, sid, reason}` | The end on `origin`, having spoken, closed or left |
| `sig_route {op: drop, sid}` | The caller's host chose a device on another host; let every target here go |
| `host_gone {host}` | From the main host: the link to that replica went down |

`link_hash` is HMAC-SHA256 with `FRIENDS_IDENTITY_SECRET` of `"SZFriends link id hash v1" || link id`;
`identity_hash` is as in version 1. When a link comes up, a replica sends its own records and links, and the main host
sends those of every other host. When it goes down, the other side drops at once everything that came over it, and
sids with an end there end (`gone`) or lose that end (one that never spoke).

## Signatures

One more signed message, in the version 1 convention (`UTF-8(domain) || length-prefixed fields`):

| Purpose | Domain | Fields, in order |
|---|---|---|
| Rendezvous record | `SZFriends rendezvous record v1` | host id, rdv key (32 bytes), seq (decimal), expires (decimal), SHA-256 of `sealed` (32 bytes) |

The host id makes a record good only on the host the helper is connected to; a host cannot place records for
helpers on other hosts.

## Limits

| Limit | Value |
|---|---|
| Record lifetime | at most 900 s |
| Lookup periods | 60 s of host time; a record shows in the period after the one it was published in |
| Record publishes | 10 a minute per identity |
| Lookups | 32 keys per message; 256 keys per 5 minutes per identity, across reconnects |
| Opens | 30 a minute per identity; by Friends ID, 5 an hour per identity; join requests, 40 an hour per device and 60 an hour toward one person |
| Open sids | 16 per connection |
| Opens delivered to one device | 10 a minute per caller identity; 20 a minute per caller address (IPv4 address or IPv6 /56); 60 a minute in all, and 30 more for callers it answered in the last 7 days; more are dropped silently |
| Sid lifetime | 120 s; a download link's sid waits up to 30 min for its sender first |
| Messages per sid | 64 each way |
| Payload | 4,096 bytes before base64url |
| Online messages | 200 per 10 s per connection |
| Relay credentials | 2 per end per sid; 30 an hour per identity; for guests 60 an hour per link and 10 an hour per address; valid 300 s to start an allocation; at most 4 unused credentials and live allocations at once per identity and per guest address, 12 per IPv4 /24 or IPv6 /56, one per relay port in all, of which a quarter is kept for friends, 4 a pair |
| Relayed sessions | 600 s per allocation or refresh; ended `FRIENDS_TURN_MAX_SESSION_S` (default 3,600 s) after the credential was issued; peers: relay addresses only |
| Links | 50 live per identity, at most 31 days ahead; 500 opens per link per statistics day |
| Tombstones | 64 per message; 500 kept per identity, each at most 31 days |
| Guests | per address (IPv4 address or IPv6 /56): 10 connections a minute, 4 open at once, 2 waiting for an offline sender; 200 per host |

## What the host keeps

In memory only: records (rdv key, device key, identity hash, host id, sealed blob, expiry), what lookups show this
period, where each link is served now, open sids (their ends and counters, at most 30 minutes), budgets keyed by
identity hash, link hash, address key or a keyed hash of a (target, caller) pair, and, for 7 days, a keyed hash of
each (device, caller) pair whose open the device answered, so that the caller can use the device's reserve; for each
live relayed session, coturn's number for it and when it must end. The key for those hashes is drawn when the
process starts; all of it goes when the process stops.

The 7-day pairs are a deliberate trade-off, accepted for protocol 2. They are what lets a device keep room for the
people it talks to while strangers flood it with opens. What they cost: anyone who can read the running process's
memory, and who already holds two identity keys, can tell whether one of those identities answered the other in the
last 7 days. Nothing else can: the key is never written down, so the hashes mean nothing outside the process or after
a restart, and no pair travels between hosts (only `known`). The alternative, which keeps no pairs, has callers
present a pass derived from the presence secret in `sig_open`, checked against a hash the device puts in its record;
it needs changes to the app's signalling and is left for a later version.

In the database: who holds each live link (link hash, identity hash, expiry, tombstone key), deleted when the link
expires or is unregistered; link tombstones (tombstone key, identity hash, revoked or expired, until), at most 31
days; one row of relay counters per host per statistics day (`relay_daily`). Never, in the database or a
log: who opened a sid to whom, a payload, a candidate, an address, a link id or secret, a file name. Logs get event
names and counts as in version 1.
