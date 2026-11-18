# ADR 0021: Peer-to-peer Wi-Fi on demand

Status: Proposed (lead decision 2026-11-18; owner review pending). Date: 2026-11-18.
Amends ADR 0004 § Decision (the network adapter browses and listens with peer-to-peer Wi-Fi all the time) and ADR 0018
§ 6 and § 9.7 (the AWDL lane beside a LAN below 25 MB/s, which never opened). Keeps ADR 0011 § Route rank and the
session race as they are. Areas: the Mac helper's network adapter (`service/discovery/SZFriendsNetworkAdapter*`), the
merger's sightings, lane dialing (`+Blocks`, `+Dial`) and the policy (`+PeerToPeer`). The Rust helper and the phones
are unchanged.

## Context

**The lane never opened.** One Bonjour entry seen on Wi-Fi and on awdl was one sighting whose route was the best of
its interfaces (the LAN). When the scheduler asked for a direct Wi-Fi lane (ADR 0018 § 9.7, LAN below 25 MB/s), the
helper looked for a sighting whose route was peer-to-peer Wi-Fi, found none, and logged "the friend is not sighted on
that route (sighted: LAN, Bluetooth)" on every ask, since 26.10.31-1. A LAN dial also included peer-to-peer Wi-Fi, so
Network.framework set up an AWDL data path for it (wifip2pd: `AWDLDatapathInitiator …_szfriends._tcp`) even though the
connection ran on Wi-Fi.

**AWDL costs everyone's Wi-Fi.** Measured on the owner's MacBook Pro (Mac17,7, 802.11be, channel 40 at 160 MHz) on
2026-11-18 while its Friends helper ran:

- Pinging the access point every 10 ms: a 66 to 80 ms stall every 524 ms (512 TU, AWDL's period), so 11 % of
  probes took over 20 ms, p99 72 ms, against a 4 ms median.
- The kernel's own count (`LQM-WiFi: AWDL Active Time`): 21 to 22 % of the radio's time on AWDL, schedule "Infra
  Priority", kept up by Bonjour (`BonJourTrig 1`, no real-time app, no AirDrop, no AWDL socket).
- wifip2pd's log over the 30.6 h it kept: Friends' advertise was registered on AWDL 100 % of the time and its browse
  98 %; everything else together (AirDrop advertise, companion-link, rdlink, asquic browses) under 1.2 %. Friends was
  the only long-lived AWDL client on that Mac.
- A browse that starts adds a burst: one more peer-to-peer browse and advertise raised AWDL time from 21 to 33 % and
  the delayed pings from 11 to 22 % for about 40 s, then it fell back to 21 % while the browse stayed. Friends restarts
  its browse on every Bluetooth sighting of a friend and every window.
- A Mac-to-Mac LAN transfer ran at about 107 KB/s with 38 % TCP retransmissions on one steady connection the same day.

What could not be shown there: the same Mac with AWDL idle. The owner's helper keeps AWDL up and was not stopped, so
the "off" side of the comparison does not exist on that Mac, and two test helpers on one Mac reach each other over
loopback, so their "LAN" transfer never touches the radio. The case against keeping AWDL up rests on the stall
pattern being AWDL's (its period, the kernel's count), on Friends being its only standing client, and on Apple's
design (AWDL is awake while any peer-to-peer Bonjour service or socket exists). Whether it alone explains the 38 %
retransmissions is not proven.

## Decision

**1. One sighting per entry, with every route it was seen on.** The browser reports a Bonjour entry once, as before,
but the sighting lists every route class of its interfaces (`SZFriendsSighting.routes`, best first; `interfaces` for
the log). Nearby, the merger, the backoffs and the session race see one device whose best route is `route`, so the
route order and the race are exactly ADR 0011's. A lane the scheduler asks for on another listed route is dialed
there: a direct Wi-Fi lane is pinned to the awdl interface the entry was seen on (`nw_parameters_require_interface`,
peer-to-peer included); a LAN dial leaves peer-to-peer Wi-Fi out, so it never sets up an AWDL data path.

*Why not a sighting per interface:* the merger would then hold two entries per device; public entries group by entry,
so a visible stranger would show twice, and every dial site that takes "the first sighting" would need to learn which
to skip. The lane is the only user of the second route.

**2. AWDL off unless something needs it.** The network adapter's browser and listeners include peer-to-peer Wi-Fi only
while the helper's policy says so (`SZFriendsNetworkAdapterSetPeerToPeer`); turning it on or off makes them again
(the hidden entry moves to a fresh listener and name within its window, the old one accepting for its overlap). It is
on while any of these holds:

- this Mac is on no network (the path monitor sees no usable interface but awdl or llw): AWDL is then the only Wi-Fi
  route, and costs no network anything;
- a transfer's group wants a direct Wi-Fi lane: on the sender, the scheduler asked for one (ADR 0018 § 9.7, unchanged:
  its LAN lanes below 25 MB/s, or none); on the receiver, the file arrived below 25 MB/s over 3 s with more than 4 s of
  it left. Both ends turn it on, so the receiver's entry appears on awdl and the sender dials the lane the moment it
  sees it;
- a direct Wi-Fi lane of a group that is moving a file is up.

It goes off 30 s after the last of these ended; sessions and lanes still on awdl are closed then (any socket there keeps
AWDL awake), and the race finds those friends on their other routes.

**3. Only while it measurably helps.** A group gives up on direct Wi-Fi for the rest of its transfer when no lane came
within 20 s of wanting one, when its lane ended, or when the sender finds that from 3 to 8 s after the lane went live
the friend acknowledged under 10 % more bytes per second than in the 5 s before it (AWDL time-slices the same radio,
so on one access point a second lane can only take airtime from the first). The sender then closes the lane. A friend
whose transfer got no lane within 20 s (an Android phone or a PC is never on AWDL; an older Mac never dials the lane)
is not asked again for an hour. Acknowledged bytes are the measure, never the scheduler's per-lane estimates, which are
peaks.

**4. The log says it all.** helper.log gains: `friend … sighted via LAN + PeerToPeerWiFi (en0 lo0, awdl0)` when a
friend's routes or interfaces change; `direct Wi-Fi wanted for …` with the reason; `direct Wi-Fi (AWDL) on: …` and
`off: …`; the lane lines say where the entry was seen and when a lane waits for the friend to show up there; the
lane's judgement (`helps` or `did not help`, with both rates); giving up and the hour without asking; sessions closed
when AWDL goes off; the Mac losing or regaining a network.

## Alternatives considered

- **Keep AWDL up and fix only the lane.** Rejected: the measured cost (a fifth of the radio, 72 ms stalls twice a
  second) is paid by every Wi-Fi packet on the Mac, all day, for a lane that ADR 0018 itself expects rarely to help.
- **AWDL never, except without a network.** Rejected: two Macs on a slow or crowded Wi-Fi do gain from a direct lane
  when their access point is the bottleneck (another channel, no AP hop), and two Macs on different networks next to
  each other would lose direct Wi-Fi altogether. The policy keeps both, for the length of a transfer.
- **Ask the friend to advertise on awdl in a frame.** Rejected: a protocol change, and both ends already see the same
  slow transfer, so each decides alone.
- **Pin the LAN dial to the Wi-Fi interface instead of leaving peer-to-peer out.** Rejected: Ethernet and loopback are
  the LAN too; leaving peer-to-peer out is the whole point and needs no interface choice.

## Consequences

- Two Macs on one network show each other on the LAN only; Nearby and the session race behave as before.
- Two Macs near each other with no shared network meet over Bluetooth or the Internet first; a transfer between them
  turns AWDL on at both ends and moves on a direct Wi-Fi lane (the race may then move the session there too, until
  AWDL goes off again after the transfer). A Mac on no network keeps AWDL on and is found over it as before.
- A slow transfer with a phone or PC costs at most 20 s of AWDL plus the 30 s tail, once an hour per friend.
- A friend's helper from before this change keeps AWDL up; it still sees a new Mac on the LAN, and over awdl while
  that Mac has it on.
- Turning AWDL on or off restarts the browser, which itself causes a short discovery burst; it happens at most twice
  per transfer that wanted direct Wi-Fi.

## Verification

- `make friends-discovery-check`, `friends-helper-check`, `friends-transfer-check`, `friends-e2e-check` (loopback
  helpers never include peer-to-peer and are unchanged).
- A throwaway two-helper run on one Mac with the real Network.framework adapter and a LAN held to 5 MB/s per stream
  (2026-11-18): both helpers turned AWDL on, saw each other on `lo0 en0 …, awdl0`, the sender dialed `lane 1` on
  PeerToPeerWiFi 4 s after asking, and the transfer's end line read `average 74.1 MB/s; by route: LAN 45.2 MB,
  PeerToPeerWiFi 754.8 MB` (800 MB); with the whole group held to 15 MB/s the lane was judged `helps: 4.8 MB/s before
  it, 14.3 MB/s with it`, and with it held to 3 MB/s, `did not help` and closed. wifip2pd registered the test type's
  AWDL browse and advertise only between the helpers' `on` and `off` lines, never at start.
- Still to do on two real Macs: AWDL idle (`ifconfig awdl0` inactive, no `AWDL Active Time` lines) once every Friends
  helper on the Mac runs this build, the access-point ping without the 524 ms stalls, and a LAN transfer's
  retransmissions with and without it.
