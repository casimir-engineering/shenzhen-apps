# Shenzhen Friends host

The service every ShenzhenPDF with Friends on checks in to while it is open: it reserves Friends IDs, hands out the
signed host list and pushes new versions, forwards between replicas, and keeps the admin statistics. With online
Friends switched on it also lets apps find each other over the Internet, passes their connection setup along, answers
STUN, and configures and counts the relay (coturn) they use when nothing else works. It also serves the pages that
friend links and download links open. It never sees messages or documents, and keeps no names: the only names it
reads are those of a person's computers, in the device chain a device checks in with, which it verifies and forgets.
Why it is built this way:
[ADR 0005](../../friends/docs/adr/0005-friends-host-service.md) and, for online Friends,
[ADR 0010](../../friends/docs/adr/0010-host-rendezvous-relay.md). The wire contract:
[HOST-PROTOCOL.md](HOST-PROTOCOL.md) and [HOST-PROTOCOL-ONLINE.md](HOST-PROTOCOL-ONLINE.md). Running it on the server:
[deploy/DEPLOY.md](deploy/DEPLOY.md).

## Layout

| Path | What |
|---|---|
| `src/main.js` | Entry point: configuration from the environment, then the host until SIGTERM |
| `src/host.js` | The WebSocket endpoint, the current list and the role it implies, live connections, timers |
| `src/admission.js`, `src/address.js`, `src/ratelimit.js` | Which connections are accepted: per-address limits keyed by IPv4 address or IPv6 /64, the trusted ingress |
| `src/client-session.js` | One helper connection: challenge, check-in, reservations, release, signed replies |
| `src/attestation.js` | ID attestations: the signed statement of who holds an ID, and the check a requester runs |
| `src/host-links.js`, `src/replica-link.js`, `src/link-auth.js` | The main host's and a replica's sides of a link between hosts, and the key exchange and message authentication on it |
| `src/forward-proof.js`, `src/id-sync.js` | The helper signatures a replica forwards, and the ID table copied to replicas |
| `src/hostlist.js` | Signed host list verification and signing (shared with the CLI) |
| `src/online.js`, `src/online-*.js`, `src/rendezvous.js`, `src/signaling.js` | Online Friends: rendezvous records, connection setup (several devices included) and how many opens reach each device, download links and guests, relay credentials, passing all of it between hosts; `online-protocol.js` holds its constants and limits |
| `src/config-online.js` | The online Friends and relay settings and their two switches |
| `src/stun.js`, `src/relay.js`, `src/coturn-config.js`, `src/relay-events.js`, `src/relay-limit.js` | The STUN responder, coturn's generated configuration, the port that receives coturn's statistics, and the limit on how long a relayed session lasts |
| `src/relay-stats.js`, `src/relay-summary.js`, `src/online-store.js` | Relay counters per host per day, the dashboard's relay numbers, and what online Friends writes to SQLite |
| `src/records.js`, `src/db.js` | Everything written to SQLite, the schema and its migrations |
| `src/device-chain.js`, `src/blake2b.js`, `src/devices.js`, `src/device-records.js` | Several devices per person (protocol 3): reading a device chain as the helper does, which person a checking-in device speaks for, and the devices and revocations kept for that |
| `src/stats.js` | The statistics the dashboard and `/stats.json` show |
| `src/dashboard*.js` | The admin dashboard on a Unix socket, with its people and devices and relay sections and test credential |
| `src/link-pages.js`, `src/config-links.js`, `src/pages/` | The pages friend links and download links open (`/f`, `/d`): HTML, CSS, one script joined from `pages/script/` in order, and the download page's service worker; where they send people for the apps |
| `tools/friends-hostlist.js` | Signing CLI for the admin's Mac: keys, signing, verifying, the release check |
| `test/` | `node:test` suites on loopback; `test/vectors/` holds the interop vectors the helper's tests share, and device chains the helper built (`make-chain-vectors.m` writes them); `test/online-*` are online Friends' |
| `deploy/` | Dockerfile, Compose file, nginx server block, DEPLOY.md |

## Testing

```sh
make -C portable friends-host-server-check   # npm ci from the lockfile, then npm test
make -C portable friends-host-check          # the helper's client, against this service on 127.0.0.1
```

Both need Node.js 22.16 or later on PATH and fail, rather than skip, without it. Tests start hosts on 127.0.0.1
with temporary data directories and throwaway keys; nothing contacts friends.meerkat.orgabots.com or any other
host. `cd portable/server/friends && npm test` runs this package's suite directly.

Two tests run the relay against a real coturn on loopback. One covers the host's credentials, two allocations per
credential, refused private peers, the 5 Mbit/s cap and the statistics. The other shows that a credential reaches only
relays, that each refresh holds an allocation for at most 600 s, and that the host ends the session at its limit
through coturn's CLI. They need a `turnserver` built in a scratch directory from the archives below, each checked
against its SHA-256 before it is unpacked, named by `FRIENDS_TEST_COTURN`; without it they skip and say so.
Nothing is installed: OpenSSL (`no-shared`), libevent (`--disable-shared`) and hiredis (`USE_SSL=0`, static) go into
a scratch prefix, and coturn's `./configure` sees only that prefix (`PKG_CONFIG_LIBDIR`). coturn's `./configure`
also needs a `pkg-config` program on `PATH` and stops with "pkg-config not found" without one: use the one already on
the Mac (`command -v pkg-config`, for example from Homebrew), and with a restricted `PATH` link just that program into
a scratch `bin/` on it; nothing else from it is used. The binary links only `libresolv` and `libSystem`.

| Archive | SHA-256 |
|---|---|
| https://github.com/coturn/coturn/archive/refs/tags/4.18.0.tar.gz | `28d55294ac596fbd129b293a85e7bb1c5dc4bd15b7fb55c500f355149e5f4e28` |
| https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz | `a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2` |
| https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/libevent-2.1.13-stable.tar.gz | `f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c` |
| https://github.com/redis/hiredis/archive/refs/tags/v1.4.1.tar.gz | `ca3180359a8b1275838a45415851f8cd5c411e27bdbf18f4823012e45507d2e4` |

```sh
FRIENDS_TEST_COTURN=<scratch>/coturn/bin/turnserver npm test
```

The download page's script runs in these suites as the browser runs it: against a JS stand-in for the sender's
helper over an in-memory peer connection always, and over real WebRTC when `FRIENDS_TEST_DATACHANNEL` names a
node-datachannel 0.33.4 package directory (the helper's own libdatachannel; npm integrity
`sha512-qiUrdh8vY9XhglEnx91HK0N2JEAAu8qTZl0fcR3yQd0fFrdO39NwDeJD/KpG+WKUb9/o4p2UwnP+/HftA/xMbQ==`, with
`@node-datachannel/darwin-arm64` 0.33.4,
`sha512-bkIA+IbModz/NUmbVYTSWj8dZvkiab+cU4zOa6rhfKsNcW3EkdD2/DDoJjUrRrw+LbEZ40V7NuAKUlMNFDXFsw==`), installed
into a scratch directory with `npm install --ignore-scripts`; with `FRIENDS_TEST_COTURN` too, one of them goes
through the relay only. Without it they skip and say so.

## Configuration

Environment variables, from the stack's `.env` in production:

| Variable | Default | Meaning |
|---|---|---|
| `FRIENDS_HOST_ID` | required | This host's id in the signed list, e.g. `main-hk` |
| `FRIENDS_PINNED_KEYS` | required | The host-list public keys, base64url, comma-separated: the same two the app pins |
| `FRIENDS_HOST_LIST_FILE` | none | A signed list to start from; needed on first start, later only when newer than the stored one |
| `FRIENDS_DATA_DIR` | `/data` | SQLite database and the dashboard socket |
| `FRIENDS_LISTEN_HOST`, `FRIENDS_LISTEN_PORT` | `0.0.0.0`, `8080` | The WebSocket endpoint, reached only through the ingress |
| `FRIENDS_TRUSTED_PROXY` | none | The ingress's address or CIDR block, comma-separated; `X-Real-IP` is believed only from these peers |
| `FRIENDS_HOST_KEY_FILE` | required | This host's Ed25519 key (unencrypted PKCS#8): signs its replies to helpers and its host links; must be the key the signed list gives this host |
| `FRIENDS_IDENTITY_SECRET` | required | At least 32 characters, the same on every host, backed up offline with the list keys: names identities in the database |
| `FRIENDS_REPLICA_SECRET` | none | Shared by all hosts, at least 32 characters; host links are refused without it |
| `FRIENDS_ALLOW_UNSYNCED_MAIN` | off | `1` lets a main host whose ID table never finished copying allocate anyway (DEPLOY.md) |
| `FRIENDS_DASHBOARD_PASSWORD` | none | Basic-auth password, at least 12 characters; without it the dashboard does not start |
| `FRIENDS_DASHBOARD_USER` | `admin` | Basic-auth user |
| `FRIENDS_DASHBOARD_SOCKET` | `$FRIENDS_DATA_DIR/dashboard.sock` | Where the dashboard listens (mode 0600) |
| `FRIENDS_STATS_TZ` | `Asia/Hong_Kong` | Day boundaries for statistics; the same on every host |
| `FRIENDS_MIN_PROTOCOL` | `1` | Older helpers are told online Friends needs an update |
| `FRIENDS_RATE_CONNECTIONS_PER_MINUTE`, `FRIENDS_MAX_CONNECTIONS_PER_ADDRESS`, `FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY` | 30, 6, 3 | Per client address (HOST-PROTOCOL.md § Errors, close codes and limits) |
| `FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY` | 200 | On the main host: new Friends IDs granted through each replica per day (DEPLOY.md, "Replicas that reach their limit") |
| `FRIENDS_RATE_MESSAGES_PER_10S`, `FRIENDS_MAX_UNAUTHENTICATED`, `FRIENDS_MAX_CONNECTIONS` | 20, 200, 5000 | Per connection, and per host |
| `FRIENDS_M2` | `off` | `on` lets apps with protocol 2 use online Friends here, and starts the STUN port |
| `FRIENDS_STUN_PORTS`, `FRIENDS_STUN_LISTEN` | `3479`, `0.0.0.0` | The STUN responder's UDP ports and addresses (with `FRIENDS_M2=on`) |
| `FRIENDS_TURN_URIS` | none | TURN URIs given to browsers opening download links, which have no signed list; its `stun:` URIs are also written into the download page |
| `FRIENDS_LINKS_PDF_URL`, `FRIENDS_LINKS_FILES_URL`, `FRIENDS_LINKS_3D_URL` | ShenzhenPDF's site, Shenzhen Files' latest release, none | Where the link pages send people without the apps (https only); no 3D URL, no "Get Shenzhen 3D" link |
| `FRIENDS_RELAY` | `off` | `on` (needs `FRIENDS_M2=on`) issues relay credentials, writes coturn's configuration and counts what it relays |
| `FRIENDS_TURN_SECRET` | required with the relay | At least 32 characters, shared with coturn through its generated configuration |
| `FRIENDS_TURN_REALM`, `FRIENDS_TURN_LISTEN_IPS`, `FRIENDS_TURN_EXTERNAL_IPS`, `FRIENDS_TURN_PORTS` | none, none, none, `49160-49415` | coturn's realm, public addresses (and `<public>/<private>` behind provider NAT) and relay ports |
| `FRIENDS_TURN_EVENTS_PASSWORD` | required with the relay | At least 24 base64url characters: coturn signs in with it to send its statistics |
| `FRIENDS_TURN_EVENTS_LISTEN`, `FRIENDS_TURN_EVENTS_PORT`, `FRIENDS_TURN_EVENTS_IP` | `127.0.0.1`, `6390`, `127.0.0.1` | Where this service receives coturn's statistics, and the address coturn sends them to |
| `FRIENDS_TURN_EVENTS_FROM` | loopback | Who may connect to the statistics port: addresses or CIDR blocks, or `gateway`, the container's default gateway, which is where Docker's published port connects from (the Compose file sets it). Anything else is dropped at once, and a connection that has not signed in within 5 s is dropped too |
| `FRIENDS_TURN_OTHER_RELAYS` | none | The public addresses of every other relay host in the list, comma-separated. The relay accepts as peers only its own addresses and these, because a relayed connection between apps on two relay hosts runs from one relay to the other |
| `FRIENDS_TURN_DENIED_PEERS` | none | More addresses or ranges (`<first>-<last>`, never from `::`) the relay must not reach. Every address but the relays' own is refused already, so this is rarely needed |
| `FRIENDS_TURN_MAX_SESSION_S` | `3600` | A relayed session ends this many seconds after its credential was issued, however the app refreshes it; `0` never ends one and runs coturn without its CLI |
| `FRIENDS_TURN_CLI_IP`, `FRIENDS_TURN_CLI_PORT` | `127.0.0.1`, `5766` | Where coturn's CLI listens, through which this service ends sessions at their limit: an address, or `gateway`, the container's default gateway, which is an address of the server (the Compose file sets it). Its password is derived from `FRIENDS_TURN_SECRET` |
| `FRIENDS_TURN_PROMETHEUS` | none | An address for coturn's Prometheus totals, for checking by SSH |
| `FRIENDS_TURN_CONF` | `$FRIENDS_DATA_DIR/relay/turnserver.conf` | Where coturn's configuration is written at every start (mode 0600) |

## What it stores

Per identity, named by an HMAC of its key with `FRIENDS_IDENTITY_SECRET` (never the key, and not a hash a friend who
knows the key could compute): its reserved Friends ID, first and last check-in days, latest app, protocol and host-list
versions. An identity is a person: with several devices, the root key's (HOST-PROTOCOL.md § Devices). Per device, named
the same way by its device key: the person it belongs to and its first and last check-in days, deleted with the person
or after 12 months unseen; and for each device a person's chain revoked, the hash of the revoking link, for a year after
the last chain that carried it. Never a device's name, system, key or chain. For the current day only, sets of salted
tokens that count unique people and devices exactly; the salt and the sets are deleted at the day's end, after the count
is kept, so no table says on which days a person was online beyond their first and last check-in. Per day, totals
(kept): uniques (people), devices, new identities, joins, revocations, reservations, collisions, renames, releases,
connections. Connection counts per host per minute (kept 30 days). Published host lists. On the main host, which replica
last passed on each identity's signed check-in and on which day, by identity hash (kept 31 days), so a replica's
statistics count only for people who really checked in through it. On replicas, a copy of the main host's ID table and
check-in summaries waiting for the main host. With online Friends: who holds each live download link, by keyed hashes of
the link and the identity, until the link expires or is unregistered; and one row of relay counters per host per
statistics day (connections opened and answered by kind, credentials, relayed sessions, bytes each way, session time,
peak rate, time at the cap), kept like the daily totals. Rendezvous records, connection setups and where each link is
served live in memory only, as do, for 7 days, keyed hashes of the pairs of identities where one answered the other's
open, so that a flood of opens from strangers cannot keep out the people someone talks to (HOST-PROTOCOL-ONLINE.md §
What the host keeps weighs this), and, for each live relayed session, coturn's number for it and when it must end;
payloads, candidates and addresses are never kept.

Identities unseen for 12 months are deleted, which releases their IDs; an ID whose identity never checked in on a
later day than the one it was reserved is freed after 30 days of absence. No IP address is stored or logged: limits
count by a keyed hash of the IPv4 address or IPv6 /64 (IPv6 /56 for online Friends' limits on guests and on opens
toward one person), in memory only (HOST-PROTOCOL.md § Errors, close codes and
limits), and log lines carry an event name, a random per-connection id and counts (`src/log.js` drops anything
else).

## Dependencies

| Package | Version | License | Source | Verification |
|---|---|---|---|---|
| ws | 8.22.0 | MIT | https://registry.npmjs.org/ws/-/ws-8.22.0.tgz (https://github.com/websockets/ws) | `package-lock.json` integrity `sha512-Ydggc987+RO0AnWtZ/7Wq9FtNvcrL1b/RO0ud9mWjUPgDrsAAwQSF51sm2hm1XofbU/4jkpGEsLFsZZxU+1DOg==`, which `npm ci` checks; registry signature verified with `npm audit signatures` on 2026-10-12 |

Everything else is Node.js itself: `node:sqlite` (`DatabaseSync`), `node:crypto` (Ed25519, SHA-256, HMAC),
`node:http`, `node:test`. `node:sqlite` is not yet stable in Node 22, so the image's Node version is pinned and
upgraded only with this suite green.
