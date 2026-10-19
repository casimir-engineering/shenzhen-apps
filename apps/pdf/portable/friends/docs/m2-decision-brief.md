# M2 decision brief: online friends

For the lead. 2026-10-13, branch `friends/m1`, nothing committed. Sources: the stack spike (`m2-stack/`, ADR 0009),
the host spike (`m2-host/`, ADR 0010) and the NAT spike (`m2-nat/`; its ADR 0011 was never written). Both ADRs are
Proposed. Every measurement is from one Mac over loopback or its own en0 address, so none of it replaces the M0
real-network matrix.

## Recommendation in one paragraph

Accept ADR 0009 and ADR 0010 with the corrections below. One stack: libdatachannel 0.24.6 with libjuice 1.7.4,
usrsctp and Mbed TLS 3.6.7, static, data channels only, for friends, download links and own devices, with ADR 0001's
Noise stream unchanged on one reliable data channel. The host speaks protocol 2 on the same `/v1` WebSocket. It
holds signed, memory-only rendezvous records and forwards connection setup without ever saying whether a target
exists. coturn runs beside it at `max-bps=625000` with no server-wide cap. The helper, not libjuice, runs the
connection order. Close two gaps before calling the design complete. First, the stack has no TCP route: add our own
TCP simultaneous-open path that carries ADR 0001 directly. Second, write ADR 0011.

## What I checked

- **Host spike, rerun:** `npm test` gave 32 of 32 passing in 2.2 s, all on loopback. The evidence JSON matches the
  README: host byte sums 52,701,388 against coturn's 52,700,932 (456 bytes), a 625,065 B/s median at the cap, and the
  third allocation refused with 486.
- **NAT spike, rerun:** `birthday.py` reproduced the README table exactly. `tcp-simopen.py` connected 20 of 20 rounds
  on 127.0.0.1 and 20 of 20 on ::1 with one side 50 ms late (median 54.8 ms).
- **Stack spike, not rerun.** A rerun needs about nine source downloads, and this session had no permission from you
  to download anything. No raw results were kept either, unlike the host spike, so its numbers rest on the README. I
  read the code instead. The Makefile builds the session area's own `szfriends_noise_*.c`, the runner touches only
  loopback and en0, and the receiver checks the digest with `sodium_memcmp`. To rerun, follow `m2-stack/README.md`
  § Reproduce (about 4 minutes of builds).
- **Route rank, confirmed and wider than reported.** Four places compare the raw route number:
  - `SZFriendsRouteRacer.m`: `shouldStartAttempt` and `decisionForCompletedRoute`;
  - `RouteRank`, used by `SZFriendsSessionAWins`;
  - `CompareSightings` in `SZFriendsDiscoveryMerger.m`.

  `DialDelayForRoute` also gives Internet and relay the Bluetooth delay. Each of these would put Bluetooth (3) ahead
  of direct Internet (4).
- **Inconsistencies between the reports:**
  - libjuice 1.7.4 is pinned with two different hashes, because the spikes used two different archive URLs. When
    vendoring, pin libdatachannel's submodule commit `b89c792`.
  - `m2-stack/SOURCES.md` says the relay statistics read coturn's Prometheus metrics. ADR 0010 measured that those
    totals arrive only when an allocation ends, so they serve as a cross-check only. The SOURCES.md line needs fixing.
  - ADR 0009's list of TCP options omits the NAT spike's own-path option.
  - ADR 0009 also omits the NAT spike's role finding: the answerer must apply the offer before gathering, or every
    connection costs 450 to 500 ms.
- **Repository hygiene.** `tools/check-file-sizes.sh` now fails on `m2-host/src/m2.js` (586 lines), so either split
  it or exclude `spikes/` from the check. Every spike file is 120 columns or less.

## Stack and connection order (helper)

1. Start nearby discovery and the Internet attempt together. Rank routes LAN, peer-to-peer Wi-Fi, Internet,
   Bluetooth, relay, and keep the wire numbers unchanged.
2. **Signalling first, peer connection second.**
   - Friends: Noise IK message 1 carries the offer and both DTLS fingerprints; the responder applies it, then
     gathers. This also avoids the role-conflict delay.
   - Add by ID online: Noise NN. No peer connection until the person accepts.
   - Download links: no peer connection until the opener proves the link secret.
3. **Direct phase,** on the helper's own timer, because libjuice only gives up after 39.55 s:
   - global IPv6;
   - server-reflexive candidates from the host's STUN on port 3478;
   - a router port mapping for the fixed local port, injected as a candidate (shown to work);
   - for a per-destination NAT detected through port 3479, up to about 25 predicted ports (libjuice takes at most
     30 remote candidates);
   - in parallel, our own TCP simultaneous open carrying Noise.

   Filter `utun`/VPN host candidates. Download links get only global IPv6, srflx and relay candidates.
4. **Relay:** ask for TURN credentials, then open a new peer connection. TURN can't be added to a live agent and
   there is no ICE restart. ADR 0001 resumes the transfer from the verified offset. Measured: 3.7 to 4.2 Mbit/s of
   payload under the 5 Mbit/s cap.
5. **Leave the relay:** keep trying direct routes after any network change and periodically; libjuice also improves
   the pair by itself. While connected, its consent checks every 4 to 6 s keep NAT mappings alive (median NAT
   timeouts are 35 to 65 s), so no extra keepalive is needed. Energy still needs measuring.

Configuration: `rtcSetThreadPoolSize(1)`, records of 64 KiB or less on the wire. Cost: about 1.6 MB per architecture
(the arm64 helper doubles), libc++ linked for the first time, and about 107,000 lines of pre-authentication parsing
plus Mbed TLS, which an independent review with fuzzers must cover.

## Host changes (ADR 0010; meerkat only with the owner's approval)

- **Protocol 2 messages:**
  - `rdv_publish`/lookup: 512-byte sealed blobs, and random bytes for unknown keys;
  - `sig_open`/`sig_msg`/`sig_close`: 4 KiB payloads, sids live 120 s with 64 messages per direction;
  - guests on `/v1?guest=1` for links, with link registration;
  - TURN REST credentials: 300 s, issued only after both ends have spoken, 2 allocations per username, and at most
    4 unused credentials and live allocations at once per identity and per guest address.
- **Replicas:** the M2 messages travel over host links, and the main host passes them on between replicas.
- **coturn:** a second container with host networking. The service generates its config: peers only on relay
  addresses (its own and the other relay hosts'), every other address denied, never a range starting at `::`, and no
  logs. An allocation or refresh holds at most 600 s, and the host ends each relayed session
  `FRIENDS_TURN_MAX_SESSION_S` (default 3,600 s) after its credential was issued, through coturn's CLI.
- **Ports to open:** 3478/udp and tcp, 3479/udp from Node, and 49160 to 49415/udp.
- **Statistics:** a statsdb sink on loopback, a `relay_daily` table and a dashboard relay section, plus the
  `FRIENDS_RELAY` and `FRIENDS_M2` switches.

## NAT techniques: status

- **IPv6:** a global 240e::/20 address on the owner's network, and libjuice prefers it. Gap: whether ISP gateways'
  firewalls admit inbound packets.
- **Port mapping:** an injected candidate connects; the owner's gateway has no NAT-PMP or PCP. Gaps: UPnP (the
  multicast search wasn't sent) and the clients themselves.
- **Hole punching:** srflx to srflx on loopback. Gaps: real NATs, CGNAT, cross-border.
- **Port prediction:** about 25 predicted candidates fit in libjuice. Gap: real sequential NATs.
- **Birthday probing:** modelled only. With 256 ports on the hard side, 1,148 probes reach 99% in about 6 to 12 s.
  Gaps: a separate prober, and whether the NAT mapping survives the handover to libjuice.
- **TCP:** simultaneous open connected 50 of 50 times on macOS; libjuice's ICE-TCP can't pair two helpers. Gaps: our
  own path isn't built, and nothing has been tried through a NAT.
- **Relay:** cap, quota, deny lists, credentials and statistics measured on coturn 4.18.0. Gap: no TCP or TLS relay
  for helpers.

Socket handover from a side-channel prober to libjuice worked 20 of 20 times on loopback. Probing when both sides are
hard is not worth it (P ≈ 0.0003 at 1,024 probes each).

## Risks

- Nothing has been measured on a real NAT, on CGNAT, from mainland China or across the border. Mainland inbound loss
  peaks for hours daily, and Google STUN is blocked there.
- **UDP-blocked networks:** a helper has no relay over TCP or TLS (libjuice can't use TURN over TCP or TLS), so it is
  unreachable unless the TCP direct path works.
- **VPN/TUN proxies,** common in the mainland and present on the owner's Mac: STUN and checks leave through the
  tunnel, and libdatachannel can't bind to an interface. Whether binding to en0's address avoids the tunnel is
  untested.
- **No server-wide relay cap** (owner's decision): 256 sessions × 5 Mbit/s exceeds meerkat's link and transfer
  allowance. The only guard is bytes per day on the dashboard. coturn also bursts to 2× the cap across second
  boundaries.
- **What the host sees:** in memory, which keys a helper looks up and opens setups to (ADR 0005's accepted
  exposure), and client addresses passing through the statsdb parser.
- **Multi-device isn't designed into ADR 0010:** an open reaches one connection per rendezvous key. One person with
  several devices needs records per device key and opens that fan out (first answer wins).
- **Links:** WebCrypto has no streaming SHA-256 (511 MB RSS for 200 MiB), libdatachannel doesn't hide local
  addresses behind mDNS, and link bindings are lost on a host restart.
- **Maintenance:** usrsctp upstream is dormant (we depend on libdatachannel's fork); Mbed TLS 3.6's end of support is
  unchecked; miniupnpc parses LAN XML and has a CVE history.

## Decisions for the lead

1. Accept ADR 0009's stack and its size cost. Ship arm64 only for now (x86_64 needs a second libsodium setup).
2. Accept ADR 0010, including sealing records under the presence secret, and confirm its limits.
3. Write ADR 0011 from the NAT README. Scope: technique order and timers, the TCP path, the port-mapping clients,
   the hard-NAT budget, VPN policy and keepalive.
4. TCP: build our own simultaneous-open path now. Decide relay over TCP (libjuice upstream, the libnice backend, or
   WebSocket through the host) after the M0 numbers.
5. Give route racing an explicit rank at all four sites, and give Internet its own dial delay.
6. Make the pre-authentication gating rule (signalling step 2 above) mandatory.
7. Build approach: CMake as a build dependency, or direct compilation in `deps.mk` style.
8. Port mapping: vendor miniupnpc 2.3.3 and fuzz it; write our own small PCP and NAT-PMP client rather than use the
   2014 `pcp` library.
9. A provisional direct-phase timeout for tests: about 5 s of plain checks plus up to 12 s of hard-NAT probing.
   The M0 matrix sets the real value.
10. Links plan amendments: a JavaScript or per-chunk hash, records of 64 KiB or less, no private candidates, guest
    payloads sealed under the link secret, link bindings persisted by hash.
11. Keep the multi-device fan-out possible in the protocol 2 wire format now.

**For the owner:**
- coturn on meerkat and the ports above;
- whether online routes may bypass a VPN/TUN that holds the default route;
- a multicast SSDP search on the home LAN to settle UPnP;
- any second relay over WebSocket;
- TURN over TLS on 5349 or 443 if the M0 numbers need it.

## Implementation plan

**Freeze first** (lead, with the session owner):
- the signalling payloads: IK and NN under a signalling prologue, and the sealed record format;
- protocol 2 schemas, moved from `HOST-PROTOCOL-M2.md` into `server/friends/HOST-PROTOCOL.md`;
- `SZFriendsOnlineTransport.h`;
- the snapshot fields for Online and relay states in `PROTOCOL.md`.

The lead keeps build wiring (`*.mk`), `PROTOCOL.md` and the ADR index. Each area owns only the files listed.

1. **Stack vendoring.** Owns `ext/{libdatachannel,libjuice,usrsctp,plog,mbedtls}/`, `friends/deps/datachannel.mk`,
   `friends/deps/tests/` and `ACKNOWLEDGEMENTS.txt`. Done when the archives are reproducible, target macOS 12 and
   ship with their licence notices.
2. **Helper transport.** Owns `friends/service/online/transport/` (new): the peer connection, the data-channel byte
   stream, the candidate filter and the relay connection. Done when Noise runs over loopback and the relay opens as
   a new connection.
3. **NAT techniques.** Owns `friends/service/online/nat/` (new) and `ext/miniupnpc/`: PCP and NAT-PMP, UPnP, the
   two-port STUN classifier, the port predictor, TCP simultaneous open, and fuzzers. Done when each technique has a
   unit test and a loopback test.
4. **Rendezvous client.** Owns `friends/service/host/SZFriendsHostRendezvous*.m`, `SZFriendsHostSignaling*.m`,
   `SZFriendsHostCodec.m` and `friends/service/session/SZFriendsSignaling*.m`. Done when publish, lookup, open and
   credentials work against the local host.
5. **Route order and racing.** Owns `friends/service/discovery/SZFriendsRouteRacer.m`, `SZFriendsDiscoveryMerger.m`,
   their tests, and `friends/service/online/order/` (new): the phases, the timer, leaving the relay and the
   technique log. Done when the race uses the explicit rank and the relay is never used while another route works.
6. **Host rendezvous and STUN.** Owns `server/friends/src/{protocol,client-session,host,host-links,replica-link,
   config}.js`, the new `rendezvous.js`, `signaling.js` and `stun.js`, and their tests. Done when the spike's 32
   tests are ported and replicas relay to each other.
7. **coturn and relay statistics.** Owns `server/friends/src/{coturn-config,relay-events,relay-stats,db,stats,
   dashboard-page,dashboard-charts}.js` and `deploy/`. Done when the cap and the statistics hold on a local coturn;
   meerkat only after the owner approves.
8. **UI states.** Owns `friends/service/presentation/`, `friends/mac/`, `friends/gtk/` and `fixtures/snapshots/`.
   Done when Online, Connecting, the relay icon and unreachable show correctly and the UX critic has reviewed them.
9. **Tests and e2e.** Owns `friends/tests/e2e/SZFriendsE2EOnline*.m`, `SZFriendsE2ETurn.{h,m}` and a pinned coturn
   test-tool build. Done when the scenarios below pass.

The e2e runs two real helpers over loopback through the local Node host and a local coturn built from pinned source;
when either is missing, the scenario skips and says so. It covers:
- a direct connection and a 200 MiB transfer;
- a scripted direct failure, then the relay at the cap (no more than 625,000 B/s);
- moving from relay to direct mid-transfer, with resume;
- Add by ID online;
- non-answers that can't be told apart;
- `kill -9` while relayed;
- a link to the node-datachannel browser stand-in, direct and relayed.

As in the spike, the peers bind to 127.0.0.1 and coturn relays from en0's address.

Waves, within the brief's limit of four agents:
- A: areas 1, 6 and 7, plus the freeze.
- B: areas 2, 3, 4 and 5.
- C: areas 8 and 9, plus the independent security review (pre-authentication surface, guests, credentials, the
  statsdb port).

Area 8 starts only after the current uncommitted edits to `mac/` and `presentation/` land. M2 itself is still
gated by the brief's order: mentions, previews and the Shenzhen Files host come first. Its release also needs the
M0 real-network matrix with a hardware operator.

## Lead decisions (2026-10-13)

1. ADR 0009 accepted: libdatachannel + libjuice + usrsctp + Mbed TLS 3.6, static, data channels only; arm64 only
   for now, like the rest of the app. Built from `friends/deps` in deps.mk style (direct compilation, no CMake build
   dependency), sources vendored under `ext/` pinned by hash (libjuice at libdatachannel's submodule commit).
2. ADR 0010 accepted, with records sealed under the presence secret and a protocol 2 wire format that already
   allows multi-device fan-out (records per device key; an open may reach several connections, first answer wins).
3. ADR 0011 is written from the NAT spike before any NAT code lands.
4. TCP: our own simultaneous-open path carrying ADR 0001 is built now. Relay over TCP/TLS is decided after the M0
   real-network numbers.
5. Routes are ranked explicitly everywhere (LAN, peer-to-peer Wi-Fi, Internet, Bluetooth, relay; owner's order),
   wire numbers unchanged; Internet gets its own dial delay.
6. Pre-authentication gating is mandatory: no peer connection before authenticated signalling (friends), acceptance
   (Add by ID online) or proof of the link secret (links).
7. Port mapping: our own small PCP and NAT-PMP client; miniupnpc 2.3.3 vendored and fuzzed for UPnP.
8. Provisional direct-phase budget for tests: 5 s of plain checks plus up to 12 s of hard-NAT probing.
9. VPN/TUN: online routes follow the system's default route (no bypass); utun/VPN host candidates are never sent.
   Revisit with M0 data.
10. Links plan amendments (per-chunk hashes in JavaScript, 64 KiB records, no private candidates, guest payloads
    sealed under the link secret, link bindings persisted by hash) go into friends-links.md.
11. The owner asked for the relay on the Hong Kong host: coturn and its ports (3478 udp/tcp, 3479 udp, 49160-49415
    udp) are deployed on meerkat once the local tests pass, recorded in the server notes.
12. Hole punching is the heart of the direct phase, as in Keet/Hyperswarm (HyperDHT): host-coordinated simultaneous
    punching, NAT type classification from two server ports, sequential port prediction, bounded random-port
    probing for randomizing NATs, TCP simultaneous open, IPv6 and router port mapping, all before the relay; the
    relay is left as soon as a punched path connects. Wave 7b-C adds a userspace NAT emulator to the test suite
    (endpoint-independent, address-dependent, port-dependent, sequential and random mappings, symmetric firewalls)
    and measures punching success per pair of NAT types; real routers and cross-border links stay in the M0 matrix.
