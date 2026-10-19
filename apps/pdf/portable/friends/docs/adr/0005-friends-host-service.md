# ADR 0005: Friends host service

Status: Accepted by lead; owner review pending. Date: 2026-10-12.
Brief: § Friends host, release gate "Host". Areas: host (owner of `portable/server/friends/` and
`friends/service/host/`).

## Context

Every install with Friends on checks in at launch, which reserves its Friends ID and delivers host-list
updates; the admin wants user counts and adoption. The host is trusted with neither content nor routing,
keeps as little as possible, and runs beside unrelated services on the owner's small Hong Kong server.
M2 adds rendezvous and TURN.

## Decision

**Runtime.** Node.js with `ws`, `node:sqlite` (`DatabaseSync`, WAL, busy timeout) and `node:crypto`
Ed25519; no other runtime dependency, lockfile committed, `npm ci --omit=dev`. The floor is 22.16, the
first 22.x with `node:sqlite` unflagged and its `timeout` option; the image pins the current LTS line
(24.x) by digest and the tests run in that image. `node:sqlite` is not yet stable (experimental through
the 22 line, release candidate since 25.7), so the version is pinned and upgraded deliberately.

**Wire.** `wss://friends.meerkat.orgabots.com/v1`, JSON text frames of at most 64 KiB (`maxPayload`),
binary values in base64url, every message with `type` and `v`. The exact schema lives in the host
service's docs and shares a protocol-version constant with the helper.

**Check-in.**

1. On connect the host sends `challenge`: 32 random bytes, its host id, server time.
2. The helper sends `checkin`: Ed25519 identity key, Friends ID and whether it believes it is reserved,
   app and protocol versions, host-list version held, and a signature over a fixed-order, length-prefixed
   encoding of `"SZFriends checkin v1"`, host id, challenge and every field, so no JSON canonicalisation is
   needed. Naming the host id stops one host replaying a client's signature to another.
3. The host verifies and replies `welcome`: reservation result (`reserved`, `taken`, or `unavailable` while
   the main host is unreachable); the ID on record if this key already holds one, which a reinstall that
   kept its key adopts; `update_required` if the protocol is too old for online features; and a newer
   signed host list if there is one.
4. On `taken` the helper draws another ID and sends `reserve` on the same connection until one is reserved
   (at most 20 tries per connection), then shows the rename notice.
5. The connection stays open while the helper runs: a ping every 25 s keeps NAT mappings and the 120 s
   proxy timeout alive; reconnects use full-jitter backoff from 1 s to 5 min, and start at once after a
   network change. One live connection per identity: a newer authenticated one closes the older.
6. Delete identity first sends a signed `release` (best effort), which deletes the row and frees the ID.

**ID reservation.** The main host (priority 1 among rendezvous hosts in the current list) is the only
allocator. `ids` has `friends_id` PRIMARY KEY and `identity_pk` UNIQUE; a reservation is one `BEGIN
IMMEDIATE` transaction whose insert either succeeds or names the existing holder, so the first reservation
wins and a key holds one ID. The host checks syntax only (two or three lowercase words of 3 to 8 letters,
joined by hyphens), not the word list, so a new list version needs no host change. Replicas forward
reservations to the main host and answer `unavailable` when they cannot reach it; they never allocate. If
the table were lost, every reserved client re-claims its own ID at its next check-in, so IDs survive.

**Signed host list.**

- Envelope `{"payload": "<base64url of UTF-8 JSON>", "sigs": [{"key": "primary", "sig": "..."}]}`. Each
  signature is Ed25519 over `"SZFriends host list v1\n" || payload bytes`; clients parse exactly the bytes
  that were signed.
- Payload: `version` (integer, only increases), `issued_at`, `new_id_words` (2 or 3, ADR 0006) and `hosts`:
  id, role (`rendezvous`, `relay`, `both`), URL, TURN URIs (M2), region, priority, host public key.
- The helper pins two public keys, primary and backup; one valid signature from either suffices. It accepts
  only a higher version than it holds (an equal version with different bytes is rejected), caches the
  newest in `hosts.json`, and falls back to the bootstrap list in its bundle, which is also a floor: a cache
  older than the bundled list is replaced. Lists do not expire, so withholding updates cannot strand clients.
- A release that drops a compromised key also discards cached lists signed by it and restarts from its
  bundled list.
- Publishing: the admin signs on their own Mac and copies the envelope to the main host, which verifies it
  with the same pinned keys, stores it, and pushes `host_list` to every open connection and to replicas,
  which verify and push in turn. Connected users switch within seconds, others at their next launch.

**The signing key never reaches a server.** The CLI in `portable/server/friends/tools/` generates keys and
signs lists on the admin's Mac. The primary private key is passphrase-encrypted PKCS#8 kept outside the
repository, with an offline copy; the backup key is generated separately and stored offline on another
medium. Servers, repository and app hold public keys only. The CLI refuses a private-key path inside the
repository or the deploy directory. Tests generate throwaway keys, and a release check fails if the helper
pins one.

**Replicas.** Same service, role from configuration. Hosts link over WebSocket, authenticated by challenge
signatures with the host keys in the current signed list; anything not in the list is refused. Replicas
forward reservations and check-in summaries (identity key, day, versions) to the main host, queueing while it
is down; the main host counts unique users across hosts by identity. M2 adds rendezvous forwarding and the
shared relay credential secret.

**Statistics and retention (main host).**

- `identities`: identity key, Friends ID, first and last check-in dates (day precision), latest app and
  list versions. Deleted 12 months after the last check-in, which releases the ID.
- `daily_active`: (day, identity hash), kept 31 days, so 1-, 7- and 30-day uniques are exact.
- `daily_stats`: uniques, all-time identities, reserved IDs, reservations, collisions, renames, peak and
  average connections, per day. Kept indefinitely; nothing in it identifies anyone.
- `connection_samples`: open connections per host per minute, kept 30 days.
- `host_lists`: published envelopes.

Adoption per list version (users, and share of users active in the last 30 days and of users connected now)
and app versions are computed from `identities` and the live connection map.

**Privacy.** No IP address in the database or any log. The ingress server block sets `access_log off` and
`error_log` at `crit`. The service reads the client address only into an in-memory rate limiter (counters
per address, forgotten after 10 minutes) and logs no addresses, identity keys or IDs, only a random
per-connection id. M1 routes no contact through the host, so there is no record of who contacts whom.
Clients send nothing beyond the check-in fields.

**Admin dashboard, localhost only.** The same process serves read-only, server-rendered HTML with no
external assets on a Unix socket in the stack's `run/` directory, never on a TCP port or the shared Docker
network. The admin reaches it by SSH local forwarding to that socket, with HTTP basic auth from the stack's
environment file as a second check.

**Deployment** (only with the owner's approval; no other service changes):

- Its own Compose stack on the server's shared `edge` network with no published ports: non-root user,
  read-only root filesystem, a data volume for SQLite, the `run/` directory for the dashboard socket, a
  256 MB memory limit (the server is small and shared), `restart: unless-stopped`.
- One new server block for `friends.meerkat.orgabots.com` in the existing nginx ingress (wildcard DNS and
  certificate already cover it): WebSocket upgrade headers, `proxy_read_timeout 120s`, `resolver
  127.0.0.11` with a variable `proxy_pass` so a recreated container does not return 502, only `/v1`
  proxied. `nginx -t` before every reload; reload the ingress after recreating the container.
- No new public ports in M1. TURN needs its own UDP and TCP ports and arrives with M2, approved separately.
- The server's nightly backup covers only its installer's stacks. Losing this database loses statistics
  history, not IDs; adding the volume to a backup is the owner's call.

## Alternatives considered

- **Go or Rust**: one binary, but a second toolchain; Node keeps the dependency list to `ws`.
- **Postgres**: a second container on a small shared server for a handful of tables.
- **Dashboard on a loopback-published TCP port**: the listener would also face the shared Docker network.
- **Certificate pinning in the helper**: breaks on routine renewal; the signed list already protects routing.
- **Expiring host lists**: an attacker who blocks updates could strand every client at expiry.

## Consequences

- A compromised host sees identity keys, IDs, versions and when installs are open, and can deny service;
  it cannot read or forge messages or redirect clients. A TLS-intercepting network sees the same metadata but,
  once replies are signed by host keys from the list (Review amendments, 2), cannot rewrite reservation results.
- A compromised replica holds its host key and the replica secret, so it can answer its own clients falsely; it
  cannot release or reassign anyone else's ID at the main host, which acts only on the client's own signature
  (Review amendments, 1).
- Losing the identity secret (Review amendments, 3) orphans every stored row: it is backed up offline with the
  list keys, and a host started with another secret refuses to run on the old database.
- With the main host down, new IDs stay unreserved; Nearby is unaffected.
- `node:sqlite` is pinned and upgraded only with the suite green.

## Verification (host harness in local containers, never production)

- Main and replica hosts: check-in; rejected signatures (wrong key, wrong host id, reused challenge); one
  ID raced through both hosts is granted once; collision renames; `unavailable` with the main host down; a
  reinstall adopting its recorded ID; release.
- Host list: newer accepted and pushed within seconds; older, equal-but-different and badly signed lists
  rejected; backup key accepted; bootstrap floor; lists from a dropped key discarded.
- A scripted population of launches, windows, quits, crashes and two hosts gives exact unique and current
  counts and adoption percentages.
- Privacy: after the scripted run no IPv4 or IPv6 address appears in the database, service logs or ingress
  logs, and another container on the network cannot reach the dashboard.
- Retention with an injected clock: identities removed at 12 months, daily rows at 31 days.

## Corrections

Recorded on 2026-10-12 after the M1 build wave, where the host area's implementation and its deployment files
(`portable/server/friends/`, `HOST-PROTOCOL.md`, `deploy/`) settled details this record had differently.

- **Memory limit and dashboard socket.** The stack runs with `mem_limit: 128m`, not 256 MB, and the dashboard
  socket is `/data/dashboard.sock` in the data volume (`./data` on the server), not a separate `run/` directory:
  the root filesystem is read-only and `/data` is the container's only writable path.
- **Node image.** The image is `node:22-alpine`, pinned by digest at deploy time (DEPLOY.md), not the 24.x LTS
  line. The 22.16 floor is unchanged, and the Dockerfile's test stage runs the suite in that same image.
- **Identities are stored by identity hash.** No database holds an identity key. Every table names an identity
  by SHA-256 of `"SZFriends identity hash v1" || identity key`, including `identities`, which also holds the
  reserved Friends ID (UNIQUE), and `daily_active`; replicas forward the hash, never the key.
- **Host links need two proofs.** A replica's `host_hello` carries an Ed25519 signature by the host key the
  current list names for it (domain `"SZFriends host link v1"`) and an HMAC-SHA256 of the same bytes with the
  shared `FRIENDS_REPLICA_SECRET`; the main host refuses the link unless both verify. The secret never travels.
- **Release is idempotent and deletes by key.** `release` deletes the row of the identity whose signature it
  verified, found by the hash of its key; the claimed Friends ID is informational, so a helper whose store lost
  track of a rename can still release, and releasing an identity the host does not hold succeeds.

## Review amendments

Recorded on 2026-10-12 from the independent security review of the host service and the helper's host client.
Each amends the decision above and names the finding it answers; `portable/server/friends/HOST-PROTOCOL.md` holds
the exact messages and signed bytes.

1. **Replicas keep the ID table.** The main host copies its (identity hash, Friends ID) table to every replica: the
   whole table, in pages, when a replica links, then every grant, release and change as it happens. A replica
   promoted to main host therefore allocates from the same table instead of an empty one, which would have handed
   any known ID to its first claimant; one that never finished a copy answers `unavailable` to reservations unless
   the admin explicitly allows it (`deploy/DEPLOY.md`). Forwarded reservations and releases carry the client's own
   signed check-in or release, bound to the replica's challenge and host id, and the main host verifies it before
   acting, so a replica cannot release or reserve an ID for an identity that did not ask (findings: replica
   promotion, replica-forwarded release and reserve).
2. **Replies are signed by the host.** Every reply the helper acts on (`welcome`, with its reservation result,
   `update_required` and any newer list; `reserve_result`; `released`) carries the host's Ed25519 signature, under
   its own domain, over the connection's challenge and a digest of the reply's fields. The helper verifies it
   against the public key the signed host list names for that host and treats a missing or bad signature as
   `unavailable`, so WebPKI alone no longer decides the person's ID. It also checks an ID the host hands back
   against the word list and the two-to-three-word syntax, keeps its backoff until a reservation succeeds, and caps
   the IDs it draws per launch (findings: host authentication, Friends ID from the host).
3. **Identity hashes are keyed; daily activity is salted per day.** Tables name an identity by an HMAC-SHA256 of its
   key under a fleet identity secret (`FRIENDS_IDENTITY_SECRET`, the same on every host, backed up offline with
   the list keys), not by an unkeyed hash anyone holding the public key could compute. Which identities were
   active is kept only for the current day, under a salt deleted with that day's rows at rollover, so the database
   holds first and last check-in days and daily counts, never a per-person calendar (finding: stored data
   privacy). This replaces the `daily_active` table above and the Corrections' unkeyed SHA-256.

Recorded on 2026-10-13 from the wave-3 security re-check. `portable/server/friends/HOST-PROTOCOL.md` holds the exact
messages and signed bytes, `deploy/DEPLOY.md` the settings, and `test/vectors/host-list-v1.json` the vectors both
sides check.

4. **ID attestations.** With every answer that says "reserved" (`welcome` and `reserve_result`), the host signs, with
   its host key, under the domain `"SZFriends id attestation v1"`, the length-prefixed host id, Friends ID, identity
   key and UTC day. The helper verifies it like any signed reply, keeps the newest (mode 0600, beside the list cache)
   and presents it when it answers an Add by ID nearby (ADR 0004, Review amendments, 9). A requester accepts one only
   from a rendezvous host in its current signed list, signed by that host's key, for the identity key and Friends ID
   in question, dated at most 30 days back and one day ahead; days are UTC so a helper anywhere can check them. The
   host service and the helper implement the check separately and agree on the shared vectors (finding: Add by ID
   request token, host attestation).
5. **Host links authenticate every message.** After the link handshake, both hosts derive a link key, HMAC-SHA256
   under the replica secret of the two host ids, the main host's challenge and the replica's nonce, so every link has
   its own. Each message then travels as `{type: "link", seq, body, mac}`, where `mac` is HMAC-SHA256 under the link
   key of the length-prefixed direction, sequence number and body; each direction counts from 1 and the receiver
   accepts only the next number, and any failure drops the link. Before this, only the handshake was authenticated:
   whoever could intercept TLS between the hosts could relay it and then inject reservation answers, which the
   replica signs for its helpers, or ID-table rows a promoted replica would allocate from (finding: host links trust
   TLS after the handshake).
6. **What a compromised replica can still do is bounded.** It can mint identity keys and sign check-ins for them, so
   the new IDs the main host grants it are capped per replica per day (`FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY`, taken
   before an allocation and refunded when nothing new was granted; a key that already holds an ID always gets it
   back), and refusals are logged (`forward_refused`). Its check-in summaries count only for identities whose own
   signed check-in it forwarded within the last 31 days, so it cannot keep other people's rows alive past expiry or
   inflate the counts. It can still squat free IDs up to its daily cap, which the admin sees in the log and the
   dashboard; removing the replica from the next signed list ends it (finding: compromised replica).

## Several devices (protocol 3)

Recorded on 2026-10-14 for [friends-multi-device.md](../../../docs/plans/friends-multi-device.md) § Host and
[ADR 0012](0012-device-chain.md); the contract is `HOST-PROTOCOL.md` § Devices.

- **An identity here is a person.** A protocol 3 helper checks in with its own device key, names its person's root
  key and brings the person's device chain unless it is the root itself. The host reads the chain as the helper does
  (`src/device-chain.js`, checked against chains the helper's own code built) and accepts the device only when the
  chain verifies from the root and authorizes it. The Friends ID, its attestation, the unique-user counts and the
  rendezvous key belong to the root; the connection (one per device, so a person's devices never replace each other),
  the budgets and the record signatures to the device. Protocol 1 and 2 helpers are their own roots, unchanged.
- **Revocations are remembered, nothing else.** The host keeps, per person, the keyed hash of each revoked device and
  the hash of the link that revoked it, so a revoked device cannot come back with a chain from before its revocation
  (close 4002), and disconnects a device when a chain revoking it arrives. It keeps no chain and no device name; it
  reads those names while verifying, which is the one place it sees a name at all.
- **Statistics count people and devices apart:** unique people and devices per day, devices per person over 30 days,
  joins (devices first seen under a person whose first device they are not) and revocations per day.
- **Join requests** travel as a new kind of open to every connected device of a Friends ID's holder
  (`HOST-PROTOCOL-ONLINE.md` § Connection setup), in memory only and capped per device and per person.
- **Sizes.** A check-in may carry a chain of up to 64,000 bytes, so the first message on a helper connection may be
  96 KiB (every other stays at 8 KiB, fragments included) and host links, which forward check-ins, allow 192 KiB. The
  memory budget in `deploy/docker-compose.yml` still holds: 200 connections not yet checked in at 137 KiB each.
