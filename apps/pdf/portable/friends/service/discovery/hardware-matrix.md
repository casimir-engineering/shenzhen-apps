# Discovery: what only two real Macs can check

`friends-discovery-check` covers everything that runs without radios: tags, the merger, the racer, the
visibility deadline, the coordinator, the Bluetooth adapter's logic over a scripted radio, the stream
wrappers, and two Network.framework adapters on the loopback interface. It never creates a
`CBCentralManager` or `CBPeripheralManager` (that would ask for Bluetooth access) and never touches a
non-loopback interface (that would ask for Local Network access). So the rows below are unverified until a
person runs them on two Macs; per the brief, an unrun row blocks release and is never assumed to pass.

Set up: two Macs (A and B) with signed builds whose helper bundles carry `NSLocalNetworkUsageDescription`,
`NSBonjourServices` (`_szfriends._tcp`) and `NSBluetoothAlwaysUsageDescription`. A and B are friends unless a row
says otherwise. Record measured values (times, rates) in the Friends journal and update ADR 0004 where it says
"the spike tunes".

## Permissions and launch

1. Fresh user on A, Friends never opened: launch ShenzhenPDF. No Local Network or Bluetooth prompt appears;
   `SZFriendsCoreBluetoothManagersCreated()` and `SZFriendsNetworkObjectsCreated()` stay 0 in the helper log.
2. Open the dropdown for the first time: both prompts appear, attributed to the app the person expects
   (ADR 0002 attribution). Allow both: Nearby fills in.
3. Quit and relaunch: Nearby starts at launch with no prompt (nearbyPermissionsRequested, and
   `CBManager.authorization` reads allowed).
4. Deny Local Network on A: Nearby shows Local Network access denied (from DNS-SD PolicyDenied), never an empty
   search; Bluetooth still finds B in the same time as with Local Network allowed. Allow it again in System
   Settings: the network method recovers without relaunching.
5. Deny Bluetooth on A, relaunch: Bluetooth is reported denied at launch and no manager is created; Wi-Fi still
   finds B as fast as before.
6. Turn Bluetooth off on A: Nearby says Bluetooth is off, without a system power alert; Wi-Fi unaffected. Turn
   it on: scanning resumes by itself.

## Routes

7. Same Wi-Fi network: B appears over the LAN; the session runs on LAN (route icon and label match).
8. Wi-Fi plus Ethernet on one Mac: still one row, LAN.
9. Different networks (or none), Wi-Fi on: B is found over peer-to-peer Wi-Fi (`awdl0`/`llw0`), classified as
   peer-to-peer from the connection's interface.
10. Wi-Fi on but associated with no network, no Ethernet: the network method reports working, not Wi-Fi off
    (the adapter reads an up `awdl`/`llw` interface). Wi-Fi powered off with no Ethernet: Wi-Fi off.
11. Wi-Fi off on A: B is found over Bluetooth alone; messages and a file transfer work over L2CAP, labelled
    "Over Bluetooth"; the measured rate is recorded.
12. Start a transfer over Bluetooth, then turn Wi-Fi back on: the session moves to Wi-Fi as soon as it connects
    and the transfer continues from its verified byte count.
13. Both Macs dial at once on several routes: one session survives (SZFriendsSessionAWins), no frame is sent
    twice.

## Discovery and privacy

14. Time to first discovery per method with all methods running together, and with each other method denied or
    off: the numbers match (a denied method never delays the others).
15. One row per person: B seen over LAN, peer-to-peer Wi-Fi and Bluetooth at once is one row.
16. Brief losses (walk B to the edge of range and back within 30 s on Wi-Fi, 90 s on Bluetooth): the route icon
    does not flip.
17. A third Mac C, not a friend of either, runs a Bonjour browser and a BLE scanner for an hour while A and B are
    hidden friends: C sees only `_szfriends._tcp` entries with random instance names and 8-byte tags that change
    every 15 minutes, never names, IDs or a fixed identifier; A and B reconnect privately, also over Bluetooth
    alone with Wi-Fi off.
18. BLE advertisement contents captured with a sniffer or PacketLogger: only the Friends service UUID (plus the
    public UUID while visible), and no local name. Check whether macOS adds the Mac's name on its own when no
    local name is given; if it does, set a random per-window name.
19. Whether the presence tag fits in the advertised local name (ADR 0004): if it does, the characteristic read can
    be skipped; record the decision.
20. The presence characteristic read: connect, read, disconnect takes how long; the 30 s scan refresh and 5-minute
    presence cache keep friends alive without draining power (measure helper energy with discovery running).
21. Remove or block B on A: A rotates its secret; B no longer recognises A's tags; other friends still find A and
    receive the new secret at their next session. The rotation is also a new window on both adapters: a new
    listener port and a new hidden PSM (row 27).
## Visibility

22. Make A visible: B lists A over Wi-Fi and over Bluetooth (public UUID and public L2CAP channel), with name and
    picture, as one row. The public channel's PSM is read from its own characteristic, which carries no tag and no
    hidden PSM, and the public UUID appears only once that PSM is there. At the deadline both entries disappear
    together on B.
23. Sleep A for 10 minutes during visibility, wake: visibility is over before anything is advertised again.
24. Disable Friends during visibility and enable it after 2 minutes: the countdown resumes with the remaining time,
    never extended; after the deadline it does not resume.
25. Set A's clock back by 10 minutes during visibility: visibility still ends on time.

## Add by ID nearby

26. A sends a request by ID: B (holder) and C (non-holder) both answer; on B's Accept, B finds A's callback tag
    and calls back with IK; both show the comparison code. A's TXT `c` and characteristic always carry exactly
    4 callback slots, with or without pending requests; callback tags stop 6 hours after A's last broadcast, and
    A broadcasts again with a fresh callback secret each day the request stays pending.

## Windows and admission

27. Window boundary, watched from C for an hour: at each 15-minute boundary A's hidden Bonjour entry reappears
    under a new name on a new port, and its characteristic shows a new tag only beside a new hidden PSM (never
    the new tag beside the old PSM). With A visible across a boundary, the public characteristic changes to a new
    public PSM at the same moment, never the old one beside the new tag. The old port and PSMs stop accepting about
    30 s later. Record whether the BLE address changes when advertising restarts at the boundary, and what still
    links windows: the Bonjour SRV hostname and the IP address, which Network.framework does not randomise (ADR
    0004 Consequences).
28. Across a boundary: a session open over the old port or PSM keeps running after the old listener is cancelled
    or the old channel unpublished; a friend who resolved the old entry just before the boundary still connects
    within the overlap.
29. Admission on real links: from C, open 5 connections to A's hidden listener that never send a preamble, from
    one IPv4 address and then from several IPv6 addresses in one /64. A holds 4 from that address or /64 (32 per
    listener), a fifth closes C's oldest, and each is closed 2 s after accept for sending nothing; B still connects
    to A meanwhile, also while C keeps opening connections. A refused IK closes 1.5 s after message 1, whether
    sealed to A's static key or to another.
