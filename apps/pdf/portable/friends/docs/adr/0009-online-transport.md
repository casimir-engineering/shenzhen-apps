# ADR 0009: Online transport stack

Status: Accepted by lead, 2026-10-13, with the corrections listed at the end (lead decisions 1 and 4 to 10 in
[m2-decision-brief.md](../m2-decision-brief.md)). Interface: `friends/service/online/SZFriendsOnlineTransport.h`.
Brief: § Decisions (Relay, Route order), § Session protocol, § Online friends (M2), Native transport; release gates
M2 and Packaging. Plans: [friends-links.md](../../../docs/plans/friends-links.md) (Helper stack, Browser transfer),
[friends-multi-device.md](../../../docs/plans/friends-multi-device.md) (Transport). Areas: a new online transport area
in the helper; session (the byte stream it carries); deps (vendoring and notices); host (ADR 0010, which issues the
STUN and TURN endpoints and credentials this stack uses); NAT techniques (ADR 0011). Evidence: archived spike
evidence of the M2 stack spike (its README has every number below, its SOURCES.md every download), summarised in the
decision brief.

## Context

Online friends, download links and own-device sync all need one Internet transport in the helper. The owner fixed
the order: "direct connection then p2p then bluetooth then server", "peer to peer, hole-punching, anything before
relay", the relay "only in last resort for online friends if everything fails, bandwidth cap it at 5mbps", and a
download link "p2p's the doc to your browser". A browser can only speak WebRTC: ICE, DTLS 1.2 and SCTP data channels.
So the helper needs a WebRTC stack whatever it uses between helpers, and one stack for both keeps one code path,
one set of candidates and one review.

Constraints from the helper: it links only system libraries and static libsodium and cJSON (no OpenSSL, no Homebrew
dylibs), targets macOS 12, ships arm64 today, is distributed under GPL-3.0 with the app, and ADR 0001 requires the
same Noise session on every transport. The brief names libdatachannel as the candidate, "subject to license,
binary-size, ICE-backend and security review", and requires every direct technique (IPv6, port mapping, hole
punching, hard-NAT probing, TCP) before the relay.

## Decision

**Use libdatachannel with libjuice, usrsctp and Mbed TLS, statically linked, data channels only, for helper to
helper, helper to browser and device to device.** Pinned versions, as the spike built them: libdatachannel 0.24.6,
libjuice 1.7.4 and usrsctp fec583d (libdatachannel's submodules), plog 94899e0 (header-only, its logger), Mbed TLS
3.6.7 (3.6 LTS; libdatachannel 0.24 requires Mbed TLS 3). Built with `NO_MEDIA`, `NO_WEBSOCKET`, `NO_EXAMPLES`,
`NO_TESTS`, hidden visibility and `-O2`, Mbed TLS in its default configuration plus `MBEDTLS_SSL_DTLS_SRTP`, which
libdatachannel's Mbed TLS code needs even without media. The sources are vendored under `ext/` like libsodium,
pinned by SHA-256, with libjuice and usrsctp taken at libdatachannel's submodule commits (libjuice `b89c792`: the
spikes fetched libjuice 1.7.4 from two different archive URLs with two different hashes). `friends/deps/` builds them
by compiling the sources directly, in `deps.mk` style as for libsodium, with no CMake build dependency, and keeps the
archives byte-for-byte reproducible. arm64 only for now, like the rest of the app.

**ADR 0001 runs unchanged above the data channel.** One reliable, ordered data channel per session carries the
ADR 0001 byte stream as is: the preamble, then 16-bit length-prefixed Noise messages, one or more per data channel
message. An adapter turns the channel into an `SZFriendsByteStream` (`service/session/SZFriendsSession.h`), so
the session layer, its limits, rekeying, chunking and resume are the same as on LAN, peer-to-peer Wi-Fi and
Bluetooth. DTLS stays underneath and authenticates nothing that matters: friends are authenticated by Noise. Online
sessions carry route class 4 (`SZFriendsRouteMethodInternet`) when direct and 5 (`SZFriendsRouteMethodRelay`) when
relayed. The owner's order puts a direct Internet connection above Bluetooth, but the route racer compares the
numbers (`SZFriendsRouteRacer.m`: `route < current`), which would rank Bluetooth (3) above it; the numbers are wire
values and never change, so M2 gives every comparing site an explicit rank (LAN, peer-to-peer Wi-Fi, Internet,
Bluetooth, relay) and Internet its own dial delay (ADR 0011 § Route rank).

**The helper, not libjuice, runs the connection order.**

1. Signalling first: the offer and the offerer's fingerprint travel in the authenticated signalling (Noise IK
   message 1 for friends), and the answerer applies the offer before it gathers; an answerer that gathers first
   costs 450 to 500 ms per connection while libjuice resolves a role conflict (NAT spike). Then gather host and
   server-reflexive candidates (one STUN server per peer connection, from the signed host list; ADR 0010's second
   STUN port tells the helper whether its NAT maps per destination). IPv6 is gathered by default and libjuice
   preferred a global IPv6 pair in the spike.
2. Add the candidates libjuice cannot gather itself by sending them through signalling: a router port mapping from
   PCP or NAT-PMP (our own small client) or UPnP (miniupnpc 2.3.3, vendored and fuzzed; ADR 0011) for the fixed
   local port the peer connection binds (`portRangeBegin = portRangeEnd`), and, for a NAT that maps per destination,
   predicted ports of the other side. The spike connected through an injected mapping with no other candidate, and
   through the one live port among 20 and 40 predicted ones.
3. Run the direct phase on the helper's own timer (ADR 0011: provisionally 5 s of plain checks, plus up to 12 s
   of hard-NAT probing when exactly one side's NAT maps per destination), beside our own TCP simultaneous-open path:
   libjuice itself only declares failure after 39.55 s.
4. Then, and only then, ask the host for TURN credentials (ADR 0010) and start a second peer connection with relay
   candidates only. TURN servers cannot be added to a running libjuice agent and there is no ICE restart, so the
   relay is always a new peer connection, a new DTLS handshake and a new Noise session; ADR 0001 already moves
   transfers between sessions by resuming from the recipient's verified offset. The direct connection keeps
   checking until libjuice gives up, and later direct attempts run while relayed; whichever goes live first on a
   better class wins the session race.
5. Leave the relay as the session race says. libjuice also does part of this by itself: under libdatachannel's
   relay-only policy it still pairs its own host and srflx candidates and learns peer-reflexive ones, so a relayed
   connection can settle on a shorter path (seen in the spike).

**Configuration.** `rtcSetThreadPoolSize(1)` before the first connection (the default is one thread per core, 18 on
the spike's Mac). Default MTU (1,280 bytes). The ADR 0001 window of 8 MiB maps to the data channel's buffered amount
with a low-water callback. Data-channel messages stay at or under 64 KiB on the wire, toward browsers and helpers
alike (`SZFriendsOnlineMessageMax`).

**Who may reach the stack.** ICE (libjuice), DTLS (Mbed TLS) and SCTP (usrsctp) all parse a remote party's bytes
before Noise authenticates anyone, so the helper creates a peer connection only once the other side is known. This
rule is mandatory (lead decision 6), and `SZFriendsOnlineTransport.h` spells it out per role, including the one
case where a connection exists first: an offerer dialling a friend creates its offer for IK message 1, sealed to
that friend's key, and applies nothing remote until IK message 2 has authenticated the responder.

- For friends and own devices, only after the Noise exchange that ADR 0010 carries in the signalling payloads has
  authenticated the peer's identity key. Both DTLS certificate fingerprints travel inside that authenticated
  exchange, so a host that swaps them is caught instead of becoming a DTLS man in the middle (who would still see
  only Noise ciphertext).
- For download links, only after the opener has proved the link secret through signalling sealed under a key
  derived from it (ADR 0010, Download links), which also carries the fingerprints.
- For a first contact (Add by ID online, where the signalling exchange is NN and authenticates nobody), only once
  the person has accepted the request, so sending requests never reaches the stack.
- Host candidates are filtered: never VPN (`utun`) or other tunnel interfaces, while traffic follows the system's
  default route, VPN or not (lead decision 9; ADR 0011 § VPN and tunnels); for download links, only global IPv6
  host addresses beside server-reflexive and relay candidates, never private or link-local ones, because
  libdatachannel does not hide local addresses behind mDNS names as browsers do and anyone holding a link would
  otherwise learn them.

**Licences.** libdatachannel and libjuice are MPL-2.0 without the "Incompatible With Secondary Licenses" notice, so
MPL-2.0 § 3.3 lets them be part of the GPL-3.0 app while their files stay under MPL-2.0; publishing the vendored
sources with the app's source meets MPL's source requirement. usrsctp is BSD-3-Clause (one file BSD-2-Clause, no
advertising clause), plog MIT, Mbed TLS Apache-2.0 OR GPL-2.0-or-later, taken under Apache-2.0, which GPL-3.0
accepts. All five notices go into `friends/ACKNOWLEDGEMENTS.txt`, `NOTICE.md` and the helper's `Licenses/` folder,
and the M2 Release gate lists them.

## Gaps this record does not close

- **No TCP route through this stack.** libjuice's ICE-TCP is active-only (two helpers never form a TCP pair;
  measured) and libjuice cannot use TURN over TCP or TLS (libdatachannel refuses it with libjuice). The direct TCP
  route is therefore our own: (d) a TCP simultaneous-open path that carries the ADR 0001 stream directly, built now
  (lead decision 4; ADR 0011). A helper on a network that blocks UDP still has no relay through this stack, even
  after ADR 0010 adds TURN over TLS: only browsers could use that. Options for relay over TCP or TLS, to decide once
  the M0 reachability numbers show how often UDP is blocked from the networks that matter: (a) add TURN over TCP and
  TLS to libjuice upstream (MPL-2.0, maintained by libdatachannel's author, who already has TCP code in libjuice for
  ICE-TCP); (b) the libnice backend (GLib, LGPL-2.1, megabytes); (c) a last fallback outside WebRTC, Noise
  ciphertext relayed over the helper's existing WebSocket on 443, which would need the owner's agreement because it
  is a second relay.
- **Hard-NAT probing at scale.** libjuice has one UDP socket per agent, takes at most 30 remote candidates and paces
  checks 50 ms apart, so about 25 predicted ports fit beside the usual candidates, but a birthday search over
  hundreds of local ports cannot run inside it. ADR 0011 decides a separate prober that finds the working port pair
  and hands the port to a new peer connection through a fixed port range; whether a real NAT keeps the mapping
  across that handover is a release gate.
- **Port mapping protocols** are outside the stack (step 2); ADR 0011 chooses them.

## Alternatives considered

- **Raw UDP with our own ICE (ICE-lite is not enough).** ICE-lite only answers checks, so two helpers cannot both
  be lite; we would write full ICE, plus reliability and congestion control over UDP, and the browser path would
  still need DTLS and SCTP, which nobody should write again. Two stacks instead of one; the only gain is control of
  candidates, which step 2 and a separate prober already give.
- **Network.framework with our own STUN.** macOS only, while the wire formats must stay portable for Linux, Windows
  and mobile; no ICE, no TCP simultaneous open, no way to share one punched port between a QUIC listener and a
  connection, and no browser interoperability at all. It stays the nearby transport (ADR 0004).
- **libwebrtc.** Complete (passive ICE-TCP, TURN over TCP and TLS), but tens of megabytes, built with Chromium's
  toolchain (gn, depot_tools), its own BoringSSL and a C++ API that changes with every release. Rejected on size and
  build.
- **libdatachannel with the libnice backend.** Fills both TCP gaps, at the cost of GLib and libnice (LGPL-2.1 and
  MPL) and megabytes. Kept as option (b) above.
- **libdatachannel with OpenSSL or GnuTLS.** OpenSSL is what the helper must not carry; GnuTLS brings Nettle and GMP.
  Mbed TLS is the smallest of the three and built cleanly.

## Consequences

- **Size.** The stack adds 1,601,600 bytes to an arm64 helper linked with `-Wl,-x` and 2,119,296 without it (the
  helper does not pass `-x` today); x86_64 adds 1,733,144 and 2,241,824. By library: libdatachannel 555 KB, Mbed TLS
  504 KB, usrsctp 323 KB, libjuice 113 KB. The helper (1,586,128 bytes) roughly doubles.
- **Dependencies.** The helper links `/usr/lib/libc++.1.dylib`, a system library, for the first time. It gains
  about 18,900 lines of C++ source (libdatachannel, media included), 10,150 of C (libjuice), 77,800 of C (usrsctp)
  and Mbed TLS, all reachable
  before Noise authenticates, hence the rule on who may reach the stack. libjuice and usrsctp have fuzzers in their
  trees; the independent review covers this surface and runs them.
- **Speed.** Several hundred Mbit/s on loopback (494 to 841 Mbit/s for 200 MiB with Noise, 543 to 622 through an
  uncapped relay), far above any Internet path; most CPU is kernel time per 1,280-byte datagram, and Noise is about
  a tenth of it. Through coturn at `max-bps=625000`, SCTP delivered 3.7 to 4.2 Mbit/s of payload: coturn drops above
  the cap, and SCTP backs off.
- **Energy.** While a connection is up, libjuice sends a STUN keepalive every 15 s and a consent check every 4 to
  6 s; the helper closes idle online sessions rather than holding them open.
- **Maintenance.** libdatachannel and libjuice release about monthly (both on 2026-09-26). usrsctp is libdatachannel's
  fork; upstream usrsctp has not released since 2021. Mbed TLS 3.6 is an LTS branch; its end of support must be
  checked before release, and moving to Mbed TLS 4 waits for libdatachannel.
- **Links plan.** Browsers have no incremental SHA-256 in WebCrypto, so the plan's whole-file check would hold the
  file in memory (511 MB for 200 MiB in the stand-in); the links plan now hashes chunk by chunk in JavaScript (lead
  decision 10, `portable/docs/plans/friends-links.md`). node-datachannel's polyfill mangles TURN usernames with
  colons, which matters only to its own tests.
- **Session race.** The rank change touches four sites: `shouldStartAttempt` and `decisionForCompletedRoute` in
  `SZFriendsRouteRacer.m`, `RouteRank` behind `SZFriendsSessionAWins`, and `CompareSightings` in
  `SZFriendsDiscoveryMerger.m`; `DialDelayForRoute` also gives Internet and relay the Bluetooth delay. Until all of
  them change, an online route would lose to Bluetooth.
- **x86_64.** The stack builds for x86_64, but the vendored libsodium configuration is arm64-only; the helper ships
  arm64 only for now (lead decision 1), and a universal helper would need a second libsodium configuration.

## Verification

Done in the spike, on one Mac over loopback and its own en0 address (README.md has the numbers): both architectures
built from pinned sources with `minos 12.0` and only system dylibs; Noise XX from the session area's own C code over
the data channel with a 200 MiB transfer and digest check, direct (6 runs) and through coturn (3 runs uncapped, 2
capped); a download-link file into a browser stand-in, direct and through the capped relay; a connection made only
through an injected port-mapping candidate; predicted-port candidates up to libjuice's limit; ICE-TCP between two
helpers shown not to connect; ICE failure time measured.

Before the M2 release:

- Real network pairs in the M0 NAT spike, mainland China and outside it, through ADR 0010's STUN and coturn: which
  technique connects, the direct-phase timeout, the keepalive interval, port mapping on real routers, and whether a
  hard-NAT prober's port survives the handover.
- The decision on relay over TCP or TLS for UDP-blocked networks (Gaps, first item).
- Browsers: Chrome, Safari and Firefox on macOS, Safari on iPhone, Chrome on Windows and Android, against the helper:
  maximum message size, TURN credentials, throughput.
- Independent security review of the pre-authentication surface, with the stack's fuzzers run under sanitizers.
- The helper's idle CPU, wakeups and energy with online sessions open and closed (Performance gate).

## Accepted with corrections

Accepted by the lead on 2026-10-13 from the M2 decision brief, which reran nothing of this spike (its numbers rest on
its README) but read its code. Corrections made in the text above on acceptance:

- **Build:** direct compilation in `deps.mk` style, no CMake; sources vendored under `ext/` pinned by SHA-256, libjuice
  at libdatachannel's submodule commit `b89c792`; arm64 only for now (lead decision 1).
- **Connection order:** signalling first, and the answerer applies the offer before gathering (the NAT spike's role
  finding, missing from the proposal); the direct-phase timer is ADR 0011's provisional 5 s plus 12 s (lead
  decision 8).
- **TCP:** option (d), our own simultaneous-open path carrying ADR 0001, is built now; relay over TCP or TLS waits
  for the M0 numbers (lead decision 4).
- **Route rank:** explicit at all four comparing sites, and Internet gets its own dial delay (lead decision 5).
- **Who may reach the stack:** mandatory, with its interface in `SZFriendsOnlineTransport.h` (lead decision 6).
- **Port mapping:** our own PCP and NAT-PMP client, and miniupnpc 2.3.3 vendored and fuzzed (lead decision 7).
- **VPN:** traffic follows the default route; tunnel host candidates are never sent (lead decision 9).
- **Links:** the plan's amendments are in `friends-links.md` (lead decision 10).
- The spike's own `SOURCES.md` said the relay statistics read coturn's Prometheus metrics; ADR 0010 measured that
  those totals arrive only when an allocation ends, so they are a cross-check only.
