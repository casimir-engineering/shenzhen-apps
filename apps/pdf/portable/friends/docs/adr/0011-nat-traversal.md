# ADR 0011: NAT traversal

Status: Accepted by lead, 2026-10-13. Timers marked provisional are set by the M0 real-network matrix.
Brief: § Decisions (Relay, Route order), § Online friends (M2), release gates M2. Decision brief:
[m2-decision-brief.md](../m2-decision-brief.md) (lead decisions 3 to 5 and 7 to 9). Builds on ADR 0009 (the stack)
and ADR 0010 (the host's STUN, signalling and relay). Areas: NAT techniques (`friends/service/online/nat/`,
`ext/miniupnpc/`), route order and racing (`friends/service/online/order/`, `friends/service/discovery/`), helper
transport (`friends/service/online/transport/`). Interface: `friends/service/online/SZFriendsOnlineTransport.h`.
Evidence: archived spike evidence of the M2 NAT spike (its README, `birthday.py`, `tcp-simopen.py`,
`juice-probe.c`, `probe-gateway.py`), summarised in the decision brief.

## Context

The owner fixed the order: "direct connection then p2p then bluetooth then server", "Use peer to peer,
hole-punching, anything before relay", and the relay "only in last resort for online friends if everything fails,
bandwidth cap it at 5mbps". ADR 0009 chose libdatachannel with libjuice and left three things to this record: the
direct phase's timer (libjuice itself only gives up after 39.55 s), the techniques libjuice cannot do itself (router
port mapping, hard-NAT probing, any TCP between two helpers), and the policy for VPNs and keepalive.

What the NAT spike found, on one Mac on a mainland home network over loopback, its own interfaces and its gateway:

- The network has a global IPv6 address (240e::/20) on the interface and no NAT66; whether the ISP gateway's IPv6
  firewall admits unsolicited inbound packets cannot be seen from inside.
- The gateway answers NAT-PMP and PCP with "port unreachable", over IPv4 and IPv6. UPnP is unsettled: a unicast
  search was refused and the multicast search, which reaches every device on the LAN, was not sent.
- A TUN proxy (`utun4`) held the default routes for all of IPv4 and 2000::/3. libjuice offered its addresses as
  host candidates, and its STUN and checks would have left through the proxy.
- libjuice accepts at most 30 remote candidates per agent and checks trickled ones at once. A connection made through
  an injected port-mapped candidate alone, and an agent bound to a port a side channel had just closed (20 of 20
  rounds). An answerer that gathers before applying the offer costs 450 to 500 ms per connection (role conflict).
- libjuice's ICE-TCP is active only, so two helpers never form a TCP pair. macOS completes a TCP simultaneous open
  (crossing SYNs, no listener) over IPv4 and IPv6, 50 of 50 rounds, including with one side 5 or 50 ms late.
- Hard-NAT probing, modelled: with 256 ports open on the hard side, 1,148 random probes from the easy side reach
  99% (11.5 s at 100 probes a second); with both sides hard, 1,024 probes each reach about 0.0003.

## Decision

**Signalling first.** Nearby discovery and the Internet attempt start together (brief § Route order). No peer
connection exists before authenticated signalling, acceptance or proof of the link secret (lead decision 6; the
gating rule is spelled out in `SZFriendsOnlineTransport.h`). The offer and the offerer's DTLS fingerprint travel in
Noise IK message 1; the answerer applies the offer before it gathers, then answers in IK message 2 with its own
fingerprint. Each side also sends its NAT class (below) with its description.

**Route rank.** LAN, peer-to-peer Wi-Fi, Internet, Bluetooth, relay: the owner's order. The wire numbers (route
class 4 Internet, 5 relay) never change, so every site that compares routes uses an explicit rank instead of the
number: `shouldStartAttempt` and `decisionForCompletedRoute` in `SZFriendsRouteRacer.m`, `RouteRank` behind
`SZFriendsSessionAWins`, and `CompareSightings` in `SZFriendsDiscoveryMerger.m`. Internet gets its own dial delay
instead of Bluetooth's (`DialDelayForRoute`). Within the Internet class the first path to go live carries the
session; a later direct path of the same class does not replace it, but any direct path replaces the relay.

**Peer-to-peer Wi-Fi keeps the device online.** A transfer never costs a device its Internet connection, a
computer's above all (a phone has cellular, but its Wi-Fi Internet is kept too). Peer-to-peer Wi-Fi is dialed only
where the platform keeps its Wi-Fi network connection up beside the direct link: one check per helper,
`p2p_wifi_usable` (`szfriends-core::nearby::p2p_wifi`) and `SZFriendsPeerToPeerWiFiUsable`, which the racers apply
before dialing. Apple's AWDL qualifies and is the only implementation. A future Wi-Fi Direct route qualifies only
where the hardware reports station and P2P at once (Windows: the WiFiDirect APIs on a driver with that concurrency;
Linux: `iw list` combinations allowing managed plus P2P-client or P2P-GO; Android: `WifiP2pManager` with documented
STA + P2P concurrency), never a hotspot or anything that drops the station link. Unsure means skip: the racer moves
on to the next route in the order above.

**The direct phase, on the helper's own timer.** The timer starts on each side when both descriptions are
applied: on the offerer when it applies the authenticated answer, on the answerer when it sends its answer. The
offerer's timer rules; the answerer never starts the relay or probing itself, it follows the offerer's signalling.

1. **Plain checks, 0 to 5 s (provisional).** Everything below at once, in one direct connection:
   - **IPv6:** global IPv6 host candidates, always gathered (libjuice prefers a global IPv6 pair).
   - **Private host addresses** (friends only, never first contacts or links): the same network seen online, and
     two peers behind one public address without relying on the NAT's hairpinning.
   - **Hole punching:** server-reflexive candidates from the host's STUN on 3478 (one STUN server per peer
     connection, from the signed host list; never a third-party server, which mainland networks often block). Both
     sides check at once because each trickles its candidates through signalling as they are found.
   - **Router port mapping** for the connection's fixed local port, injected as a local candidate (below).
   - **TCP simultaneous open**, our own path (below).
2. **Hard NATs, up to 12 s more (provisional), only when exactly one side's NAT maps per destination.** Port
   prediction and probing start together:
   - **Prediction:** up to 25 predicted ports of the hard side, within libjuice's 30 remote candidates, added to the
     running direct connection.
   - **Probing (the birthday technique):** a separate prober, because libjuice has one socket per agent; on success
     its port pair moves into a new probe handover connection (below).

   When both sides map per destination, nothing is probed: about 0.0003 at 1,024 probes each is not worth the
   packets. When neither does, or either side's class is unknown, the plain checks were all there was.
3. **Relay, last resort.** When the budget above has run out with no direct path: at 5 s, or at 17 s with a hard
   side. The offerer asks the host for TURN credentials (ADR 0010) and opens a relay connection, a new peer
   connection with relay candidates only; the answerer, on the relay offer, asks for its own credentials and answers
   with one. The direct connection keeps checking until libjuice gives up, the TCP path until its own budget ends,
   and whichever direct path goes live first replaces the relay in the session race.
4. **Leave the relay.** While relayed, run the plain checks again in a new direct connection after every network
   change and periodically: 30 s after the relay connects, then doubling to at most every 5 minutes, with 20%
   jitter (provisional). Probing runs again only if a side's NAT class changed. libjuice also settles a relayed
   connection on a shorter pair by itself when one answers (seen in the stack spike); the transport reports it as a
   route change.

These timers are provisional values for tests (lead decision 8). The M0 matrix measures what each technique needs
on real networks, in mainland China and outside it, and this record takes its numbers.

**NAT class.** A two-port STUN classifier, outside the peer connection, sends Binding requests from one socket to
the host's 3478 (coturn) and 3479 (the Node service; ADR 0010). One mapped port for both means the NAT maps
independently of the destination; two mean it maps per destination, and their difference gives prediction its step
and direction. The class is kept per network (the default route's interface and gateway) and measured again after a
network change. No answer from 3479 leaves the class unknown.

**Port prediction.** The hard side reports the server-reflexive port of its connection's socket and its class's
step; the easy side adds up to 25 candidates continuing from that port in that step (fewer if other remote
candidates already take the cap of 30), with technique PredictedPort, so the route report names it.

**Probing budget.** Only one side probes: the hard side opens 256 UDP sockets and sends one probe from each to the
easy side's server-reflexive address, which opens 256 mappings; the easy side sends probes from one socket to
random ports of the hard side's public address at 100 a second (provisional), at most 1,148 (99% for 256 ports).
So at most 1,404 packets of under 100 bytes per attempt, and at most one probing run per peer per 10 minutes and
one at a time per helper. Probes are STUN Binding requests carrying short-term credentials from the authenticated
signalling of this attempt; an answer counts only if its integrity checks, so a stray packet cannot win the
handover. Probes go only to the public address the authenticated peer reported, and only when the peer presented
it in this attempt's signalling (the hard side aims at exactly the endpoint the easy side presented, the easy side at
random ports of the address the hard side presented), never to a private, loopback, link-local or multicast address
or to a host's own address, so the prober cannot be aimed at a third party. On a
hit, both sides close every prober socket and open a probe handover connection bound to exactly the winning port,
with the other side's winning address as its only remote candidate (the handover worked 20 of 20 rounds on
loopback; whether a NAT keeps the mapping across it is a release gate).

**TCP simultaneous open, our own path (lead decision 4).** It carries the ADR 0001 stream directly, with no DTLS:
Noise authenticates, as on the LAN. Each side binds one TCP socket to a fixed local port with address and port
reuse, learns that socket's mapped address from STUN over TCP to the host's 3478, and sends its global IPv6 address
and that mapped address as RFC 6544 candidates with `tcptype so`, with private addresses too for friends. Each side
then calls `connect()` from the same local port to each remote endpoint, again after a refusal or a 1 s silence
(through a NAT the first SYN is usually dropped, the case the spike measured with one side late), until the direct
phase's budget ends. The first connected socket becomes a stream; the offerer sends the ADR 0001 preamble. Its
first bytes are the Noise handshake, bounded as ADR 0001 bounds every responder. Relay over TCP or TLS is not
decided here: after the M0 numbers, between libjuice upstream, the libnice backend and a WebSocket relay through
the host (ADR 0009 § Gaps).

**Port mapping (lead decision 7).** Requested for the connection's local UDP port as soon as it is bound, only when
the default route's interface is a physical one (a mapping on the LAN gateway is useless while a VPN carries the
traffic):

- **PCP, then NAT-PMP: our own small client.** PCP (RFC 6887) MAP for UDP, suggested external port equal to the
  internal port, lifetime 7,200 s, to the default gateway over IPv4 and to the IPv6 default router (a firewall
  pinhole for the global IPv6 candidate). A version-0 "unsupported version" answer falls back to NAT-PMP (RFC 6886)
  over IPv4. Retransmits at 250, 500 and 1,000 ms and gives up after 2 s; "port unreachable" ends it at once (the
  owner's gateway). Answers are accepted only from the gateway's address and port 5351, with the request's nonce,
  and parsed strictly; the parser is fuzzed. The mapping is renewed at half its lifetime while the connection
  lives, deleted (lifetime 0) when it closes, and dropped after a network change or an epoch that went backwards.
  MAP only: no PEER, no third-party option, no ANNOUNCE beyond the epoch check.
- **UPnP IGD: miniupnpc 2.3.3, vendored and fuzzed.** Pinned by SHA-256
  `d52a0afa614ad6c088cc9ddff1ae7d29c8c595ac5fdd321170a05f41e634bd1a`, BSD-3-Clause, under `ext/miniupnpc/`. Run only
  when PCP and NAT-PMP have both failed: a multicast SSDP search on the default route's interface (1 s wait),
  `AddPortMapping` with a 7,200 s lease (or an infinite lease where the device accepts no other, deleted on close),
  and on IGD v2 an IPv6 pinhole for the global address; 3 s for the whole step. It parses XML from any device on the
  LAN and has had memory-safety CVEs, so its SSDP, description and SOAP parsing are fuzzed and it is updated
  promptly. Its mappings are described "Shenzhen Friends" so a later run can find and delete its own stale ones.

The mapped address and port go to the peer as a local candidate with technique PortMapping.

**VPN and tunnels (lead decision 9).** Online routes follow the system's default route, whichever interface holds
it: no `IP_BOUND_IF` to the physical interface, no bypass of a VPN or TUN proxy. The peer connection, the prober and
the TCP path bind only the unspecified address, never an interface or one of its addresses, so every packet takes
the route the system picks, and server-reflexive addresses are learnt through the default route. Host candidates
follow it too:

- **Never from these interfaces:** tunnels (`utun`, `ipsec`, `ppp`, `gif`, `stf`, `tun`, `tap`, `wg`), loopback,
  peer-to-peer Wi-Fi (`awdl`, `llw`), and virtual or overlay networks (`feth` for ZeroTier, `bridge` for Internet
  Sharing and virtual machines, `vmenet`, `anpi`), whose addresses would describe a private network to the peer.
  Never link-local either.
- **None of a family whose route a tunnel holds.** While such an interface holds the IPv4 or IPv6 route toward
  the Internet, no host candidate of that family is offered from any other interface. Otherwise en0's stable global
  IPv6 address, for example, would reach the peer around the tunnel the person chose, and give away their home
  network. The server-reflexive address, learnt through the tunnel, is then the only address of that family. A
  family with no route toward the Internet offers none either.
- **Read from the routing table, every time.** The routing table is asked, for two destinations per family, which
  interface a packet would leave through (RTM_GET, as `route -n get` asks; nothing is sent). One destination lies in
  each half of the address space, because a TUN proxy holds split default routes (0/1 and 128/1 on the owner's
  Mac) above a plain default route that still points at the LAN. If either answer is a tunnel, the family is
  treated as tunnelled. The transport reads the table for every gathered host candidate, and the TCP path for every
  gathering, so a VPN that comes up or goes down between attempts is followed.

The rules are `SZFriendsOnlineMayOfferHostCandidate` and the helpers beside it in the interface header. Behind a TUN
proxy, STUN and checks leave through it, so the server-reflexive address is the proxy's exit; when the proxy drops
UDP, the attempt falls to the relay, which is UDP too. Revisited with M0 data.

**Keepalive.** No extra UDP keepalive: while a connection is up, libjuice's consent checks every 4 to 6 s on the
selected pair keep its NAT mappings alive (median NAT UDP timeouts are 35 to 65 s), beside its STUN keepalive
every 15 s. The TCP path sets TCP keepalive after 60 s idle, probes every 10 s, 3 probes (provisional). Port
mappings are renewed at half their lifetime. The helper closes idle online sessions rather than keeping them open
(ADR 0009 § Energy); the energy cost of an open online session is measured before release.

**Technique log.** For every attempt the order component records, locally and for the support matrix: each side's
NAT class, which techniques were tried, which technique connected (the numbers in `SZFriendsOnlineTransport.h`),
the time from both descriptions to the first stream, and whether the relay was needed. No address, port, key, ID
or name.

## Alternatives considered

- **Leave the timing to libjuice.** Its checks give up after 39.55 s; the relay would come about 40 s after every
  failed attempt.
- **Everything at once, the relay included.** Fastest to connect, but the relay would carry sessions a direct path
  could have carried, against the owner's "only in last resort".
- **libjuice's ICE-TCP** cannot pair two helpers (active candidates only, measured). **libnice** gathers passive TCP
  candidates but never simultaneous-open ones, and brings GLib and megabytes. Our own path is a socket, STUN over
  TCP and ADR 0001 unchanged.
- **libnatpmp** speaks NAT-PMP only, so no PCP and no IPv6 pinholes. **miniupnp/pcp** (BSD-2-Clause) has not
  changed since 2014. MAP alone is small enough to own and fuzz.
- **Our own UPnP client:** SSDP, device descriptions and SOAP are a larger surface than PCP; miniupnpc is the
  maintained one, at the cost of fuzzing it.
- **Probing inside libjuice:** one socket per agent and 30 remote candidates cannot hold hundreds of ports.
- **Probing when both sides are hard:** about 0.0003 at 1,024 probes each, 0.06 at 16,384 each.
- **Binding to the physical interface to bypass a VPN** (`IP_BOUND_IF` picked en0's addresses in the spike): would
  send traffic around a tunnel the person chose, and in the mainland the tunnel may be the only working path. Not
  now; the M0 numbers may reopen it with the owner.
- **Public STUN servers beside the host's:** often unreachable from mainland China, and a second party learning
  who connects.

## Consequences

- With no direct path, the relay starts 5 s after the descriptions (17 s with one hard side), plus the time to
  get credentials and set up a new connection; nearby routes are unaffected, since they run in parallel.
- Hard-NAT probing costs at most 1,404 small packets per attempt and runs at most once per peer per 10 minutes.
- miniupnpc and our PCP/NAT-PMP parser read bytes from the LAN before anyone is authenticated: both are in the
  independent review with fuzzers, and miniupnpc must be updated promptly.
- A person behind a TUN proxy that drops UDP has no Internet route until the relay over TCP or TLS is decided, unless
  the TCP path gets through.
- An attempt is two connections at most at once besides the TCP path (direct, then relay or probe handover), and
  each relay or handover is a new DTLS handshake and a new ADR 0001 session; transfers resume from the verified
  offset.
- Router mappings are visible on the router while a connection lives, as for any app that maps ports.

## Verification

Done in the NAT spike (archived spike evidence): the gateway probe (NAT-PMP, PCP, unicast UPnP, read-only); libjuice
driven from outside (socket handover 20 of 20 rounds, a port-mapped candidate alone, the 30-candidate cap, the role
conflict); TCP simultaneous open on IPv4 and IPv6 with and without a late side; the probing model, closed form
against Monte Carlo within 1%.

Before the M2 release:

- Each technique with a unit test and a loopback test (NAT techniques area): the PCP and NAT-PMP client against a
  scripted gateway, miniupnpc against a scripted IGD, the classifier against a local two-port responder, prediction,
  the prober and its handover, the TCP path; the order's phases and timers with a scripted clock.
- Fuzzers for the PCP/NAT-PMP parser and miniupnpc's SSDP, XML and SOAP parsing, run under sanitizers in the
  independent review.
- The M0 real-network matrix: which technique connects across real NATs, CGNAT, mainland China and outside it;
  the direct-phase budgets; whether a NAT keeps a prober's mapping across the handover; TCP simultaneous open
  through NATs; port mapping on real routers, including the owner's multicast SSDP search at home (with the owner's
  approval first); keepalive intervals; behaviour behind a VPN or TUN proxy.
- The helper's idle CPU, wakeups and energy with online sessions open and closed.
