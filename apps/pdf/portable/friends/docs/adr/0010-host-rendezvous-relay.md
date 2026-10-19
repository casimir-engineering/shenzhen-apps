# ADR 0010: Host rendezvous, connection setup and relay

Status: Accepted by lead, 2026-10-13, with the corrections listed at the end (lead decisions 2, 6, 8, 10 and 11 in
[m2-decision-brief.md](../m2-decision-brief.md)).
Brief: § Decisions (Relay, Route order, Hosting), § Friends host, § Online friends (M2), release gates M2.
Plans: [friends-links.md](../../../docs/plans/friends-links.md),
[friends-multi-device.md](../../../docs/plans/friends-multi-device.md).
Areas: host (owner of `portable/server/friends/`). Evidence: archived spike evidence of the M2 host spike (its
README, 32 tests, relay evidence run and deployment plan), summarised in the decision brief. Protocol: the protocol 2
section of `portable/server/friends/HOST-PROTOCOL.md`, which the host area moves there from the spike's draft.

## Context

M2 connects friends over the Internet. The owner's order is fixed: "direct connection then p2p then bluetooth then
server", "peer to peer, hole-punching, anything before relay", and the relay "only in last resort for online friends
if everything fails, bandwidth cap it at 5mbps". Download links reuse the same stack to stream a file from the
sender's Mac to a browser ("p2p's the doc to your browser"), and own-device sync reuses it again.

So the host must let two helpers, or a browser and a helper, find each other and exchange connection setup; answer
STUN so they learn their public addresses; and, only when nothing else works, relay at 5 Mbit/s per session with
no server-wide cap, counting what it relays for the admin. It must do this on the existing Node service (ADR 0005)
and on meerkat, a small shared server in Hong Kong, while keeping the promises ADR 0005 made: no addresses, keys or
IDs in any database or log, no record of who contacts whom, and nothing a stranger can use to tell whether someone
is online.

## Decision

**One protocol version up, same connection.** Host protocol 2 adds messages to the helper's existing WebSocket
(`/v1`); nothing version 1 signs changes and protocol 1 helpers keep working without online friends. M2 messages get
their own rate budget so a burst of ICE candidates cannot starve check-in.

**Rendezvous records.** Each protocol 2 helper publishes one record over its checked-in connection: keyed by
`SHA-256("SZFriends rendezvous key v1" || identity key)`, signed by the identity key over the host id it is
connected to, a sequence number and an expiry at most 15 minutes ahead, and holding one 512-byte sealed blob of its
standing candidates that only friends can open (sealed under a key derived from the presence secret ADR 0004 already
gives every friend). Records live in memory on every host in the list, never in a database. A lookup answers 512
bytes for every key asked, the record's blob or fresh random bytes, so it tells a stranger nothing; friends learn
what presence tags already tell them nearby, which also gives the Online state.

**Connection setup is forwarded, never looked up.** `sig_open` names a target (a friend's rendezvous key, a Friends
ID for Add by ID online, or a download link id) and carries an opaque payload of at most 4 KiB; the host answers at
once with a sid, whatever exists, and delivers the payload to the target's connection on whichever host it is on.
Payloads then flow both ways (`sig_msg`) until the sid closes or expires after 120 s, at most 64 per direction. The
rules that keep presence
private: a target refuses by staying silent; a target that closes or disconnects without having spoken becomes
nobody and the caller's sid simply expires, exactly as with no target; only an end that has spoken can end a sid for
the other. The host never names the caller to the target: the payload does (Noise IK message 1 for friends, NN for
Add by ID, both under signalling prologues the session area fixes), so the host sees neither identities nor ICE
candidates.

**Several devices per person.** The protocol 2 wire format already allows the multi-device plan's fan-out, so it
needs no new version later: a record names the device key that signed it (in M2, the identity key itself), and the
host keeps one record per device key under the person's rendezvous key, replacing only that device's. An open to a
rendezvous key may reach every connection holding a record under it; the first target to speak owns the sid, the
others' copies end for them alone, and the caller sees one sid and one answer, as with one device. Lookups stay one
fixed-size answer per key; which device's blob it carries when there are several is fixed with multi-device.

**Download links.** The sender's helper registers each live link id (first registration wins, 50 per identity). A
browser connects to the same endpoint as a guest (`/v1?guest=1`, no check-in), opens exactly one link, and talks to
the sender's helper through one sid; while the sender is offline the sid waits up to 30 minutes and is delivered when
the helper comes back. Guest payloads are sealed under a key derived from the link secret, which also stops a host
from swapping DTLS fingerprints (adopted into the links plan, `friends-links.md`). The host keeps link bindings
across a restart, stored by hash: the SHA-256 of the link id with the keyed identity hash, host id and expiry, never
the link id itself; a presented link id is hashed to find its binding.

**STUN.** coturn answers STUN Binding on 3478 (UDP and TCP), next to TURN. A second STUN port, 3479/UDP, is answered
by the Node service itself (`dgram`, Binding only, per-source budget): a helper asking both ports from one socket
learns whether its NAT maps per destination, which decides whether port prediction is worth trying before the
relay. coturn cannot do this on a server with one public address: its alternate port answers only with a second IP
(measured). Both URIs go in the signed host list's existing `turn_uris`, so they cannot be redirected.

**TURN: coturn, last resort, 5 Mbit/s per session.** coturn (the official image, pinned by digest) runs as a second
service in the friends stack with host networking. Its configuration is generated by the Friends host from its own
settings, never edited by hand, and fixes what the brief decides:

- `max-bps=625000`: 5 Mbit/s per session in each direction (coturn counts bytes per second). No `bps-capacity`, no
  `total-quota`: no server-wide cap. The generator refuses any other value.
- Credentials only from the host, per attempt, in the TURN REST scheme (`use-auth-secret`, a secret shared with the
  service): username `<expiry>:<random attempt id>`, valid 300 s to start an allocation, issued only for a sid on
  which both ends have spoken, at most 2 per end per sid and 30 an hour per identity, at most 2 concurrent allocations
  per username (`user-quota=2`). An identity, and a guest address, holds at most 4 at once: its unused credentials
  still within their 300 s and the allocations coturn reports alive for its credentials; a further request is
  refused (`rate_limited`) until one ends.
- How long a relayed session lasts: an allocation, and each refresh, holds at most 600 s (`max-allocate-lifetime`). A
  refresh does not recheck the credential's expiry, so the host itself ends every relayed session
  `FRIENDS_TURN_MAX_SESSION_S` (default 3,600 s) after its credential was issued, through coturn's CLI; the app asks
  for a new credential if it still needs the relay, and the transfer resumes.
- Relays only to relays: every Friends relay path is relay to relay (an app on a relay connection sends and accepts
  relay candidates only), so peers are allowed only on the relay's own addresses and those of the other relay hosts
  the admin lists (`allowed-peer-ip`), and every other IPv4 and IPv6 address is denied. The private, loopback,
  link-local, shared, documentation and multicast ranges stay denied as well. Never a range starting at `::`: coturn
  reads an all-zero lower bound as no bound and then denies every IPv4 peer (measured).
- `no-tcp-relay` (TCP peers are not used), no TLS listeners in phase 1, no log at all (coturn writes client addresses
  into its lines): `no-stdout-log`, `log-file=/dev/null`. The CLI is on only for the session limit, listening only
  where the host reaches it, behind a password derived from the TURN secret.

The helper asks for credentials only after every local and direct technique has failed within the direct phase's
budget (ADR 0011: provisionally 5 s, or 17 s with hard-NAT probing), then gathers relay candidates only, and keeps
trying direct routes while relayed (brief). With the stack ADR 0009 accepts, the relay attempt is a new peer
connection; it may use the same sid while that lives, or a new one, which must be answered again before credentials
are issued.

**Statistics.** coturn's `redis-statsdb` publishes each allocation's start and end and its byte counts every 4,096
packets. The Friends service receives these itself, answering the few Redis commands coturn sends on a port
published only on the server's loopback, and keeps only the status word and counters: coturn's status lines also
carry the client address, which the parser never reads past. The attempt id in the username joins each allocation to
the sid it was issued for, so the host counts, per statistics day and per host: opens and answered sids by kind
(friends, Add by ID, links), credentials, relayed sessions, bytes each way, session time, peak aggregate rate,
sessions and minutes held at the cap, and the share of answered connections that needed the relay. One row per host
per day (`relay_daily`), kept like `daily_stats`; replicas send theirs in their minute report. coturn's Prometheus
totals stay on the server's loopback for the admin to cross-check by SSH. Clients send nothing extra.

**Replicas.** Records, link bindings and setup messages travel over the authenticated host links; the main host
passes on what one replica sends for another. A host accepts a record only for helpers connected to the host that
sent it, checks the identity signature itself, and drops a host's records when its link goes down. Every relay
host's coturn shares the TURN secret with the hosts that issue credentials for it, and nothing else.

## Alternatives considered

- **Lookups that return candidates in the clear**: a stranger who knows someone's key (from an attestation or a
  link) would learn their address and that they are online. The fixed-size sealed answer costs 512 bytes per key.
- **Rotating lookup tags derived from the presence secret**, like nearby: the owner publishes over its own
  checked-in connection, so the host can link the tag to the identity anyway; nothing gained over a stable key the
  host already cannot store.
- **Answering "not found" to opens**: simpler for the caller and a presence oracle for anyone with a key or an ID.
- **A TURN server written in Node**: one process fewer, but a protocol with a long security history to own, and
  coturn's bandwidth limiter, quotas and deny lists would all need rewriting.
- **coturn in bridge networking with published ports**: 256 relay ports would mean 256 port mappings (and, with
  Docker's userland proxy, as many proxy processes) on a small server, and NAT between coturn and its peers.
- **Prometheus alone for statistics**: coturn adds an allocation's bytes to its counters only when the allocation
  ends, so live rates, bytes per day for long sessions and sessions held at the cap cannot come from it (source
  read, and measured). Username labels, which would separate sessions, leak memory with REST usernames (coturn's own
  warning).
- **A Redis container for statsdb**: a second process and store on a small server for a handful of write-only
  messages; the service answers them directly.
- **coturn log parsing**: its lines carry client addresses, and a pipe that stalls would block coturn.
- **TURN over TLS on 443 now**: needs an SNI-routing stream block in the shared ingress. Phase 2, if the M0
  reachability numbers show UDP and TCP 3478 failing from networks that matter; 5349/TCP with the wildcard
  certificate is the step before it.

## Consequences

- A host learns, in memory and while they happen, which rendezvous keys a helper looks up and which it opens sids
  to; it stores and logs none of it. That is the metadata ADR 0005 already accepts a compromised host would see.
- Friends whose presence secret is out of date cannot open a record until the next session updates them; they can
  still connect, because `sig_open` needs only the key.
- coturn sees client addresses, as any relay must; it writes none. The host process reads them only inside coturn's
  status lines, discards them in parsing, and never stores them.
- The relay's traffic counts against meerkat's transfer allowance with no cap but the per-session one; the
  dashboard's bytes per day is how the admin sees it.
- coturn allows a burst of up to twice the cap across a second boundary (its counter resets each calendar second)
  and drops, rather than queues, what is over it; sustained rates hold at the cap (measured). SCTP backs off against
  those drops: the transport spike measured 3.7 to 4.2 Mbit/s of payload through this configuration (ADR 0009), so a
  relayed transfer runs a little under the 5 Mbit/s it is allowed.
- A leaked credential can start a relay for 5 minutes and keep it at most `FRIENDS_TURN_MAX_SESSION_S` after it was
  issued: bounded by the attempt's two allocations, the cap and the issuer's share of 4.
- Every host in a list runs the same service version, as for host links today.
- The relay runs on the Hong Kong host at the owner's request: coturn and its ports (3478 UDP and TCP, 3479 UDP,
  49160 to 49415 UDP) are deployed on meerkat once the local tests pass, and recorded in the server notes (lead
  decision 11). Nothing is deployed before then.

## Verification

Done in the spike (loopback only, coturn 4.18.0 built from source in scratch; `README.md` there has the numbers):

- 32 `node:test` tests against the deployed service with the M2 module installed: records (signature, host binding,
  expiry, sequence, fixed-size lookups, budget, nothing in the database), setup between two fake helpers (forwarding
  both ways, the four indistinguishable non-answers, `gone` after an answer, Add by ID, per-target and per-sid
  limits), relay credentials (only after an answer, REST format and HMAC, limits), download links (guest flow,
  waiting for an offline sender, first registration wins, guest restrictions), two real hosts (main and replica)
  joined for records, setup, Add by ID and links across them, coturn configuration, the STUN responder, the
  statistics sink.
- The evidence run: credentials accepted, refused when wrong or expired (401), a live allocation refreshed after its
  credential and nonce expired; the third allocation on one username refused (486); private peers refused (403),
  public ones allowed; 625,000 B/s held per session in both directions when offered 1,250,000, and two sessions at
  once each at the cap; the host's byte sums equal to coturn's own totals to within 0.001%; coturn's Prometheus
  traffic totals still 0 while 50 MB were being relayed; nothing printed and no file written by coturn besides its
  pid file.

Before the M2 release, still to do: the M2 release gates (real networks, mainland China and outside it, CGNAT, blocked
UDP), the session area's definition of the signalling payloads and the sealed record, and an independent security
review of guests, credentials and the statistics port.

## Accepted with corrections

Accepted by the lead on 2026-10-13 from the M2 decision brief, which reran the spike's 32 tests (32 passing, all on
loopback) and checked its evidence file against its README. Corrections made in the text above on acceptance:

- **Records sealed under the presence secret** are confirmed, with the limits in the protocol 2 section (lead
  decision 2).
- **Several devices per person:** the wire format allows records per device key and opens that fan out, first
  answer wins (lead decision 2).
- **Gating:** no peer connection before authenticated signalling, acceptance or proof of the link secret (lead
  decision 6; `friends/service/online/SZFriendsOnlineTransport.h`).
- **Relay timing:** after ADR 0011's provisional direct-phase budget (lead decision 8).
- **Links:** guest payloads sealed under the link secret, and link bindings kept across restarts by hash (lead
  decision 10).
- **Deployment:** on meerkat once the local tests pass, recorded in the server notes (lead decision 11).
