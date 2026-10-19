# Deploying the Friends host

For the admin. The host runs on meerkat (`dmit-meerkat`, Hong Kong) as its own Compose stack in
`/opt/stacks/friends`, on the shared `edge` network, behind the existing nginx ingress. It changes nothing else on
the server: one new stack directory and one new server block. Online Friends (step 12) adds a relay container and a
few UDP ports, only once the owner approves it.

**Deploy only with the owner's approval.** The server also runs unrelated services; do not restart, edit or
upgrade any of them. Nothing in the repository's test suites contacts this host.

## What you need

- On your Mac: this repository, Node.js 22.16 or later, and two places for private keys outside any repository
  (the primary on an encrypted disk with an offline copy; the backup on another medium, kept offline).
- On the server: SSH as root, Docker with Compose, and the ingress stack in `/opt/stacks/ingress`.

All CLI commands below run from `portable/server/friends` on your Mac. The CLI refuses to write a private key
inside a git repository or inside this package.

## 1. List-signing keys (once, on your Mac)

```sh
node tools/friends-hostlist.js keygen --out ~/FriendsKeys/primary.pem       # asks for a passphrase twice
node tools/friends-hostlist.js keygen --out /Volumes/Offline/backup.pem     # a different passphrase
```

Each writes the private key (passphrase-encrypted, mode 0600) and `<path>.pub`, the public half in base64url.
The private keys never go to a server.

The app pins both public keys. Replace the TEST keys the helper ships today, and re-sign its bundled list (step 3
makes the payload; use the same one):

```sh
node tools/friends-hostlist.js pinned-file --primary-pub "$(cat ~/FriendsKeys/primary.pem.pub)" \
  --backup-pub "$(cat /Volumes/Offline/backup.pem.pub)" \
  --out ../../friends/service/host/resources/pinned-keys.json
node tools/friends-hostlist.js sign --primary ~/FriendsKeys/primary.pem --payload hosts-v1.json \
  --out ../../friends/service/host/resources/bootstrap-hosts.json
make -C ../.. friends-host-release-check    # must pass before any release
```

## 2. The host key and secrets (on the server)

```sh
mkdir -p /opt/stacks/friends/data /opt/stacks/friends/src
chown 10001:10001 /opt/stacks/friends/data && chmod 700 /opt/stacks/friends/data
```

The host key signs this host's answers to apps (they check it against the public key in the signed list, so a
network that intercepts TLS cannot rename anyone) and identifies it on links between hosts. Generate it on your Mac
into a scratch directory outside the repository, then copy it to the server's data directory:

```sh
node tools/friends-hostlist.js keygen --out /tmp/friends-host/main-hk.pem --host-key   # prints its public key
scp /tmp/friends-host/main-hk.pem root@191.222.216.16:/opt/stacks/friends/data/host-key.pem
ssh root@191.222.216.16 'chown 10001:10001 /opt/stacks/friends/data/host-key.pem && chmod 600 /opt/stacks/friends/data/host-key.pem'
rm -rf /tmp/friends-host
```

Write `/opt/stacks/friends/.env` (mode 600), with fresh secrets (`openssl rand -base64 32`):

```sh
FRIENDS_HOST_ID=main-hk
FRIENDS_PINNED_KEYS=<primary.pem.pub>,<backup.pem.pub>
FRIENDS_HOST_LIST_FILE=/data/host-list.json
FRIENDS_HOST_KEY_FILE=/data/host-key.pem
FRIENDS_IDENTITY_SECRET=<openssl rand -base64 32>
FRIENDS_REPLICA_SECRET=<openssl rand -base64 32>
FRIENDS_DASHBOARD_PASSWORD=<openssl rand -base64 24>
FRIENDS_STATS_TZ=Asia/Hong_Kong
FRIENDS_TRUSTED_PROXY=<the ingress's address on edge, step 5>
FRIENDS_NODE_IMAGE=<node:22-alpine@sha256:..., step 4>
```

**Back up `FRIENDS_IDENTITY_SECRET` offline, beside the list-signing keys.** The database names every identity by an
HMAC with it, so a host that loses it loses every reserved ID exactly as if it lost the database, and every host in
the list must use the same value. The service refuses to start with a secret other than the one its database was
written with.

**Shenzhen 3D's download link.** The friend and download pages offer "Get ShenzhenPDF" and "Get Shenzhen Files" with
no setting, but not "Get Shenzhen 3D": its releases are not public yet, so there is no address to send people to. Add
`FRIENDS_LINKS_3D_URL=<https address of the download page>` to `.env` once there is one, then recreate the container.
Until then the pages still offer "Open in Shenzhen 3D".

## 3. The first signed list (on your Mac)

`hosts-v1.json`, with the host key printed in step 2:

```json
{
  "version": 1,
  "new_id_words": 2,
  "hosts": [
    {"id": "main-hk", "role": "rendezvous", "urls": ["wss://friends.meerkat.orgabots.com/v1"],
     "region": "Hong Kong", "priority": 1, "public_key": "<main-hk public key>"}
  ]
}
```

```sh
node tools/friends-hostlist.js sign --primary ~/FriendsKeys/primary.pem --payload hosts-v1.json --out host-list.json
node tools/friends-hostlist.js verify --pinned-file ../../friends/service/host/resources/pinned-keys.json host-list.json
scp host-list.json root@191.222.216.16:/opt/stacks/friends/data/host-list.json
```

`sign` fills in `issued_at` and refuses a list the app would reject. Roles become `both` when TURN arrives (M2).

## 4. Build and start

From the repository root on your Mac:

```sh
git archive HEAD:portable/server/friends | ssh root@191.222.216.16 'tar -x -C /opt/stacks/friends/src'
ssh root@191.222.216.16 'cp /opt/stacks/friends/src/deploy/docker-compose.yml /opt/stacks/friends/'
```

**Pin the Node image.** On the server, look up the current `node:22-alpine` digest and set it in `.env` as
`FRIENDS_NODE_IMAGE=node:22-alpine@sha256:<digest>`, so a rebuild never picks up another Node silently. Compose
stops without it, and the build stops (`deploy/check-node-image.sh`) unless the value ends in a 64-digit digest:

```sh
docker buildx imagetools inspect node:22-alpine | grep Digest
```

Run the suite inside that image, then start:

```sh
cd /opt/stacks/friends
docker build -f src/deploy/Dockerfile --target test --build-arg NODE_IMAGE=node:22-alpine@sha256:<digest> src
docker compose up -d --build
docker compose logs friends     # {"event":"listening","port":8080,"role":"main","version":1}
```

## 5. The ingress

Append `src/deploy/nginx-friends.conf` to `/opt/stacks/ingress/data/nginx/custom/http.conf`, copying the
`listen` and `ssl_certificate` lines from the neighbouring blocks (the wildcard certificate covers the name).
Then, in the ingress container, `nginx -t` and, only if that passes, `nginx -s reload`. The block proxies `/v1`
and the link pages (`/f`, `/d`, `/d/sw.js`, `/links/links.css`, `/links/links.js`, each by its exact path, with the
service's own headers passed through) and answers 404 for anything else, keeps WebSocket connections open for 120 s
of silence (both sides ping every 25 s), writes no access or error lines (nginx puts the client's address into error
lines, even critical ones), and resolves the container by name at request time.

TLS handshakes that fail before the name is known are logged by the listener's default server, not by this block.
Check that block's `error_log` in `http.conf` (and the ingress's own defaults): if it logs at any level, those lines
carry client addresses. Changing it touches the ingress, so it is the owner's call.

**Which peer may name the client's address.** The service believes `X-Real-IP` only from `FRIENDS_TRUSTED_PROXY`, so
another container on `edge` cannot pick which rate limits it spends. Set it to the ingress container's address on
`edge`:

```sh
docker inspect -f '{{(index .NetworkSettings.Networks "edge").IPAddress}}' <the ingress container>
```

That address can change when the ingress container is recreated. The service then sees every app as coming from the
ingress, so they all share one address's limits, and logs `proxy_untrusted` once a minute: update
`FRIENDS_TRUSTED_PROXY` and `docker compose up -d`. Giving the ingress a fixed address on `edge` avoids this but
changes the ingress stack, which needs the owner's approval.

## 6. Check it

```sh
docker compose ps                                   # healthy
docker exec friends wget -q -O- http://127.0.0.1:8080/healthz
```

From your Mac, a WebSocket to `wss://friends.meerkat.orgabots.com/v1` must answer with a `challenge` naming
`main-hk`; `https://friends.meerkat.orgabots.com/` must answer 404. Run the M0 reachability spike from mainland
China and from outside it before relying on it. `docker compose logs friends` must show no IP addresses, keys
or Friends IDs; only event names, random connection ids and counts. It must not show `proxy_untrusted` (step 5) or
`"host_key"` with `mismatch` (the list names another key for this host, so apps would believe none of its answers).

**Limits per address.** Each IPv4 address, or IPv6 /64, may open 30 connections a minute, hold 6 at once and get 3
new Friends IDs a day (HOST-PROTOCOL.md § Errors, close codes and limits). Many Macs behind one NAT (an office, a
school, a carrier-grade NAT) share those: the seventh Mac stays unconnected and Nearby keeps working, and new IDs
beyond the third wait for the next day. If the dashboard shows that happening to real users, raise
`FRIENDS_MAX_CONNECTIONS_PER_ADDRESS` or `FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY` in `.env`. The whole host accepts 1,200
connected apps (`FRIENDS_MAX_CONNECTIONS` in `docker-compose.yml`), sized to the stack's 160 MB memory limit; when
the dashboard's online peak nears it, raise both together.

## 7. The dashboard

It listens only on `/opt/stacks/friends/data/dashboard.sock`, never on a port. Forward it over SSH:

```sh
ssh -N -L 8377:/opt/stacks/friends/data/dashboard.sock root@191.222.216.16
```

Then open `http://localhost:8377/` and sign in as `admin` with `FRIENDS_DASHBOARD_PASSWORD`. `/stats.json` has
the same numbers. Another container on the `edge` network cannot reach it.

## 8. Publishing a new host list

Increase `version`, sign on your Mac, then publish through the forwarded socket:

```sh
node tools/friends-hostlist.js sign --primary ~/FriendsKeys/primary.pem --payload hosts-v2.json --out host-list-v2.json
curl -u admin --data-binary @host-list-v2.json http://localhost:8377/lists     # {"published":2}
```

The host verifies it with the pinned keys, stores it and pushes it to every connected app and replica: connected
users switch within seconds, everyone else at their next launch. An older or equal version is refused. To start
issuing three-word IDs (the dashboard's Friends IDs bar is full), publish a list with `"new_id_words": 3`.

If the primary key is lost, sign with the backup (`--primary /Volumes/Offline/backup.pem`) and ship an app release
that pins a new pair.

## 9. Updating the service

```sh
git archive HEAD:portable/server/friends | ssh root@191.222.216.16 'rm -rf /opt/stacks/friends/src/* && tar -x -C /opt/stacks/friends/src'
ssh root@191.222.216.16 'cd /opt/stacks/friends && docker compose up -d --build'
```

In the Shenzhen repository the service is `apps/pdf/portable/server/friends` and is deployed from a
`friends-server/<YY.M.D>-<N>` tag, by the deploy job or by hand from the repository root:
`git archive friends-server/<YY.M.D>-<N>:apps/pdf/portable/server/friends` in place of the first command's
`git archive HEAD:portable/server/friends`.

Then reload the ingress (`nginx -t && nginx -s reload` in its container): the variable `proxy_pass` re-resolves on
its own, but a reload clears any connection nginx still holds to the old container. Connected apps reconnect by
themselves within seconds.

**Before an app that uses several computers per profile ships, every host in the list must run protocol 3** (this
service from the version whose challenge carries `protocol: 3`; check with HOST-PROTOCOL.md § Versioning). On an older
host such an app falls back to protocol 2: it still checks in, but a computer that joined a profile is treated as a
person of its own there, holds no ID and is not reached online.

With replicas, update every host in the list the same day. Hosts running different versions of the service may not
be able to link (the way hosts authenticate their links changed in the version that added ID attestations and again
in the one that gave each link its own key; HOST-PROTOCOL.md § Host links). Until both ends match, a replica answers
`unavailable` to reservations and keeps its statistics queued.

The service migrates its database forward on start. One step cannot: a database from before identities were named
with `FRIENDS_IDENTITY_SECRET` (schema 1) that already holds identities is refused, because its rows cannot be
renamed and dropping them would free every ID. Keep the old version running and ask before going further.

## 10. Adding a replica

On the new server, the same stack with its own `FRIENDS_HOST_ID`, host key and `.env`, the same
`FRIENDS_PINNED_KEYS`, `FRIENDS_IDENTITY_SECRET`, `FRIENDS_REPLICA_SECRET` and `FRIENDS_STATS_TZ`, and its own
ingress block. Then publish a list that names it (role `rendezvous`, priority 2 or higher, its URL and its host
public key). The replica links to the main host, copies its Friends ID table and keeps the copy current, forwards
reservations and statistics to it with each app's own signature, and answers `unavailable` while it cannot reach it.
Its dashboard says whether its copy of the ID table is complete.

**What the main host takes from a replica.** A replica holds its host key and both shared secrets, so if one is
broken into, whoever holds it can make up identities and sign check-ins for them. The main host therefore grants at
most 200 new Friends IDs a day through each replica (`FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY` in the main host's
`.env`; apps that already hold an ID always get it back), and counts a replica's statistics only for people whose
own signed check-in that replica passed on in the last 31 days. One effect on the numbers: someone who uses a
replica for the first time while the main host is down is not counted for that day.

### Replicas that reach their limit

When a replica reaches its daily limit, the main host's dashboard says so at the top and the log has a
`replica_limit` line naming it. Apps that connect through it and have no reserved ID keep theirs unreserved until the
day ends (`FRIENDS_STATS_TZ` time); Nearby keeps working for them, and their apps ask again by themselves. The count
is kept in memory, so restarting the main host also starts it over.

- If that many new people really use the replica (a launch in its region, say), raise
  `FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY` in the main host's `.env` and run `docker compose up -d` there.
- If not, treat the replica as compromised: publish a list without it (step 8), which stops the main host from
  linking with it and apps from believing anything it signs, then give the remaining hosts a new
  `FRIENDS_REPLICA_SECRET` and restart them. `FRIENDS_IDENTITY_SECRET` cannot be changed without losing every
  reserved ID; whoever holds it can name the rows of a stolen database, so keep the databases from leaving the
  servers.

## 11. Replacing the main host

Make a host the main host only when its dashboard says it **holds a complete copy of the Friends ID table**: run it
as a replica first, wait for that line, then publish a list that gives it priority 1. It takes over the table and
hands out IDs at once; the old main host, if it comes back as a replica, takes the new main host's copy.

A host that never finished copying refuses to hand out IDs as the main host (apps get `unavailable` and keep their
IDs unreserved), and its dashboard says so. If the old main host is gone for good and no replica ever finished a
copy, you can still make it allocate by adding `FRIENDS_ALLOW_UNSYNCED_MAIN=1` to its `.env` and restarting it. Know
what that costs: until each person's app checks in again, anyone can claim their ID, and the real owner is then
renamed. Prefer bringing the old main host back, even briefly as a replica, so its table is copied.

## 12. Online Friends

Online Friends lets two apps that are not near each other connect over the Internet, directly whenever they can,
through the relay only when nothing else works, at 5 Mbit/s per session. It is off until you switch it on, and its
relay is a second switch, so you can run online Friends without a relay, or turn the relay off alone. Do this only
with the owner's approval; it opens UDP ports on the server. HOST-PROTOCOL-ONLINE.md is what apps send.

**Look first** (read-only, on the server): `ip -br addr` (is the public IPv4 on an interface? which global IPv6
addresses does it have?); `ss -lnup | grep -E ':(3478|3479)\b'` and `ss -lntp | grep -E ':(3478|5766|6390|9641)\b'`
(all must be free); the relay range 49160 to 49415/udp must be unused; `nft list ruleset`, `ufw status` or
`iptables -S INPUT` for a firewall; and `ss -lnup` in full, for the UDP services listening on the addresses you will
put in `FRIENDS_TURN_LISTEN_IPS` (see "What the relay reaches" below).

**Ports.** 3478/udp and 3478/tcp (coturn: STUN and TURN), 49160 to 49415/udp (coturn: relayed sessions), and
3479/udp (this service: the second STUN port). If the server filters INPUT, allow 3478/udp, 3478/tcp and
49160:49415/udp, which coturn opens on the server's own network. Docker publishes 3479/udp and the statistics port
6390/tcp itself; 6390 only on `127.0.0.1`. Inside Docker the statistics port could also be reached from the other
containers on `edge`, so the service accepts it only from the `edge` network's gateway, which is where the published
port connects from (`FRIENDS_TURN_EVENTS_FROM: gateway` in the Compose file), and drops any connection that has not
signed in within 5 seconds.

One port goes the other way: coturn's command port, 5766/tcp, on the `edge` network's gateway address
(`FRIENDS_TURN_CLI_IP: gateway` in the Compose file), through which the service ends relayed sessions that have run
for an hour (`FRIENDS_TURN_MAX_SESSION_S`). It is not public, and it takes a password derived from the TURN secret.
If the server filters INPUT, allow it from the `edge` network only: `docker network inspect edge` gives the subnet
and the bridge, then for example `ufw allow in on <bridge> from <edge subnet> to <gateway> port 5766 proto tcp`.
Without it the relay still works, but sessions are no longer ended at the hour, and the service logs
`"state":"end_failed"`. Nothing else opens, and the ingress does not change: browsers opening download links use
`/v1?guest=1`, which the existing block already passes.

**Secrets and settings.** Add to `.env`:

```sh
FRIENDS_M2=on
FRIENDS_RELAY=on
COMPOSE_PROFILES=relay
FRIENDS_TURN_SECRET=<openssl rand -base64 48 | tr -d '\n=' | tr '+/' '-_'>
FRIENDS_TURN_REALM=friends.meerkat.orgabots.com
FRIENDS_TURN_LISTEN_IPS=<the public IPv4>[,<the global IPv6>]
FRIENDS_TURN_EVENTS_PASSWORD=<openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_'>
FRIENDS_TURN_URIS=turn:friends.meerkat.orgabots.com:3478?transport=udp,turn:friends.meerkat.orgabots.com:3478?transport=tcp
FRIENDS_COTURN_IMAGE=coturn/coturn:4.18.0-r0@sha256:<digest>
```

If the public address sits behind the provider's NAT instead of on an interface, listen on the private address and
add `FRIENDS_TURN_EXTERNAL_IPS=<public>/<private>`.

**What the relay reaches.** Only relays. When two apps fall back to the relay, each one has its own relayed address
and they send to each other's, so the relay needs to reach only its own addresses (`FRIENDS_TURN_LISTEN_IPS` and the
public side of `FRIENDS_TURN_EXTERNAL_IPS`) and those of any other relay host in the list. Every other address,
IPv4 and IPv6, is refused, so nobody can use a credential to send traffic to the rest of the Internet from this
server's address. If another host in the list runs a relay too, name its public addresses here, and this host's on
that one:

```sh
FRIENDS_TURN_OTHER_RELAYS=<the other relay's public IPv4>[,<its global IPv6>]
```

The other side of this: an app holding a credential can send UDP to any port on the relay's own addresses, at
5 Mbit/s, and it arrives from the server's own address. coturn and the STUN port are made for that. Any other UDP
service listening on those addresses (`ss -lnup` in "Look first"), such as a VPN or a DNS server on `0.0.0.0`, must
not trust packets because they come from the server itself; if one does, bind it elsewhere before turning the relay
on. TCP is never relayed.

`FRIENDS_TURN_DENIED_PEERS` refuses further addresses or ranges, and is rarely needed now that everything but the
relays is refused. Never write a range that starts at `::`: coturn reads it as no lower bound and would refuse every
IPv4 peer. The service refuses to start with one. Pin coturn like Node: `docker buildx imagetools inspect
coturn/coturn:4.18.0-r0 | grep Digest`. The TURN secret needs no offline copy: a new one costs a restart, and
credentials issued in the last 5 minutes and not yet used stop working (apps ask again).

**Start.** `docker compose up -d --build`. The service writes coturn's configuration to `data/relay/turnserver.conf`
(mode 600) at every start, from these settings and nothing else: 5 Mbit/s per session (`max-bps=625000`) with no
server-wide cap, credentials only from this service, two allocations per credential, relaying only to relays (above),
each allocation held at most 600 s past its last refresh, the command port on the gateway address, and no log at all,
because coturn writes client addresses into its lines. Do not edit the file; it is replaced at the next start. The
`relay` container starts after `friends` is healthy. After changing any `FRIENDS_TURN_*` value, run
`docker compose up -d` and then `docker compose restart relay`, which reads the new file. Reload the ingress
afterwards, as in step 9.

**Check it.**

- `docker compose ps`: both containers up. `docker compose logs friends` shows `"event":"stun"` and
  `"event":"relay"` lines and, as always, no addresses.
- The dashboard's **Relay** section says "coturn is sending its statistics to this host". If not, the relay
  container is down or `FRIENDS_TURN_EVENTS_PASSWORD` changed without `docker compose restart relay`.
- From your Mac, STUN on both ports from one socket returns your public address, with the same port behind an
  ordinary home router. A 172.x address from 3479 means Docker's proxy carries that port and hides the client.
- `curl -u admin -X POST http://localhost:8377/relay-test` (through the forwarded socket, step 7) gives a 5-minute
  credential. With any TURN client (`turnutils_uclient` from the same coturn release, run on your Mac): the
  allocation is granted, a wrong password is refused (401), and a peer anywhere but the relay itself is refused
  (403), whether in 10.0.0.0/8 or a public address such as 1.1.1.1. Two allocations sending to each other's relayed
  addresses work (`turnutils_uclient -y`). A 60-second transfer between them runs at about 625,000 bytes a second,
  and the dashboard counts it as held at 5 Mbit/s.
- `docker compose logs friends | grep end_failed` shows nothing an hour after a relayed session began. If it shows
  lines, the service cannot reach coturn's command port (see "Ports").

**Tell the apps.** Publish a list (step 8) in which this host has role `both` and

```json
"turn_uris": ["stun:friends.meerkat.orgabots.com:3478", "stun:friends.meerkat.orgabots.com:3479",
              "turn:friends.meerkat.orgabots.com:3478?transport=udp",
              "turn:friends.meerkat.orgabots.com:3478?transport=tcp"]
```

Apps with online Friends then find STUN and TURN; older apps ignore them. A replica that relays too needs the same
`FRIENDS_TURN_SECRET` as the hosts that issue its credentials, and its own `FRIENDS_TURN_*` addresses; every relay
host then names the others in `FRIENDS_TURN_OTHER_RELAYS`.

**What to watch.** There is no server-wide relay cap, by decision: each session is held to 5 Mbit/s, and the
dashboard's relay data per day is what to compare with the server's monthly transfer allowance.

**Turning it off.** The relay only: set `FRIENDS_RELAY=off`, remove `relay` from `COMPOSE_PROFILES`, then
`docker compose up -d` and `docker compose stop relay`; apps are told the relay is unavailable and keep connecting
directly. Everything online: publish a list without `turn_uris`, set `FRIENDS_M2=off` as well, and
`docker compose up -d`; apps go back to Nearby, and check-in and Friends IDs are untouched.

## Data and backups

`/opt/stacks/friends/data` holds `friends.sqlite` (with its WAL files), the host key, the starting list and the
dashboard socket. **It is not in the server's nightly backup**, which covers only the installer's stacks; adding
it is the owner's call. Losing the database on the main host loses the Friends ID table: started again on an empty
database, the host hands out IDs as if nobody held one, so until each person's app checks in again someone else
could claim their ID. A replica holds a live copy of the table, which makes it the quickest way to recover (step 11);
a backup of `friends.sqlite` does too. Losing `FRIENDS_IDENTITY_SECRET` has the same effect as losing the database.

Besides the identities table, the main host's database remembers, for 31 days, which replica last passed on each
identity's check-in and on which day (by identity hash, never by key), so it can tell a replica's real statistics
from made-up ones. With online Friends, every host also keeps who holds each live download link (by keyed hashes of
the link and the identity, until the link expires) and one row of relay counters per host per day. Rendezvous
records and connection setups stay in memory: after a restart apps publish theirs again within seconds.

## Removing it

`docker compose --profile relay down` in `/opt/stacks/friends`, remove the server block from `http.conf`, `nginx -t`,
reload, and close the ports step 12 opened. Apps keep working nearby and retry quietly.
