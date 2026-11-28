# ADR 0022: Direct Wi-Fi only off Wi-Fi

Status: Accepted (the owner's rule, 2026-11-27). Date: 2026-11-27.
Amends ADR 0011 § Route rank (the peer-to-peer Wi-Fi rule), ADR 0018 § 9.7 (the AWDL lane beside a LAN below
25 MB/s), ADR 0019 § 1, § 3 and § 7 (when a boost happens, who is asked, Android's stay-on-Wi-Fi path) and ADR 0021
§ 2 (when AWDL is on). Areas: session (capability bit 6), BOOST (Abilities bit 4), the transfer core's scheduler and
boost, the racer, both helpers' services, the Mac helper's network adapter and AWDL policy, the phones' plugin
(Kotlin and Swift), the question's words on phones.

## Context

The owner, 2026-11-27: "use wifi direct only if the conditions are matched, which means both devices are not on a
wifi, or for 3D if the device is a phone that could have internet access through cellular." He also wants transfers
to fill the Wi-Fi or cable as LocalSend does (40 MB/s on his Wi-Fi).

The code did the opposite in three places:

- **AWDL on mid-transfer.** A Mac on Wi-Fi turned AWDL on when a file arrived below 25 MB/s for 3 s, and the sender's
  scheduler asked for a direct Wi-Fi lane while its LAN lanes measured below 25 MB/s (ADR 0018 § 9.7, ADR 0021 § 2).
  AWDL shares the radio: on the owner's MacBook Pro it took 21 to 33 % of the airtime in 66 to 80 ms stalls every
  524 ms (ADR 0021), and a recorded Mac-to-Mac run had 38 % TCP retransmissions. On a Wi-Fi where the transfer
  naturally sits near 25 MB/s, this made it start fast and then drop: the slowdown turned AWDL on, and AWDL slowed
  the Wi-Fi further. The transfer bench's emulation of those stalls on a 40 MB/s, 6 ms Wi-Fi link moves 32 to 33 MB/s
  against 37 to 38 MB/s without them.
- **"Peer-to-peer only while the device keeps its internet"** (ADR 0011, `p2p_wifi.rs`): staying on the Wi-Fi beside
  the direct link was the condition for using it, so an Android phone on Wi-Fi with station and Wi-Fi Direct at once
  used Wi-Fi Direct beside its Wi-Fi, and a Mac with a cable left its Wi-Fi silently for a boost.
- **"Not on the same network"** (ADR 0019 § 1) let two devices on two different Wi-Fi networks boost.

## Decision

**1. The rule.** Direct Wi-Fi (AWDL between Apple devices, the Wi-Fi Direct boost) is used only when each of the two
devices is:

- on no Wi-Fi network (an Ethernet cable, or no network at all), or
- a phone running Shenzhen 3D that is online over mobile data; such a phone may leave its Wi-Fi for the link.

Both must hold; each device judges its own side (`WifiStanding`, `szfriends-core::nearby::p2p_wifi`;
`SZFriendsBoostConnectivity.allowsDirectWiFi`). A Wi-Fi network counts whether or not it reaches the Internet (the
rule is about the radio); AWDL itself and a boost's own link do not. Staying on the Wi-Fi network beside the link is
never a reason: that is the shared radio the rule avoids. A computer's mobile data (a USB modem) does not count; only a
phone's does.

**2. Each side tells the other.**

- **Sessions and lanes: handshake capability bit 6** (`CAPABILITY_DIRECT_WIFI_ALLOWED`,
  `SZFriendsCapabilityDirectWiFiAllowed`). Unlike bits 0 to 5 it says how the device is now, so every handshake reads
  it afresh (the Rust helper asks the platform; the Mac helper's AWDL policy sets `SZFriendsSetDirectWiFiAllowedHere`).
  A session or lane on the peer-to-peer Wi-Fi route closes as soon as it is up unless both handshakes set it
  (`direct_wifi_refuses`, `-linkWentLive:`). Any minor: it is about the route, not frames.
- **Boosts: BOOST's Abilities bit 4** (`boost_ability::DIRECT_WIFI_ALLOWED`, `SZFriendsBoostDirectWiFiAllowed`), set
  from the device's connectivity when the boost starts, so a Bluetooth session opened long before still decides on
  the present. A boost goes ahead only when both PROPOSE/READY set it; otherwise the side that sees it ends the boost
  with Reason unsupported. A boost's lane is judged by the boost, not by bit 6 (the joining side is on the link).
- **Compatibility.** Helpers before this rule never set either bit, so they never get direct Wi-Fi with a new helper:
  no AWDL session or lane, no boost. Both bits were unused, and unknown bits were already ignored, so old helpers read
  new frames and handshakes as before. No new frame, field or session minor.

**3. AWDL on a Mac.** On exactly while this Mac is on no Wi-Fi network (the network adapter's path monitor:
`SZFriendsNetworkAdapterOnWiFi`); joining a Wi-Fi network turns it off at once, and what still runs on awdl closes
(a boost's lane apart). Both 25 MB/s triggers are gone (the receiver's and the scheduler's,
`SZFriendsDirectWiFiHelpsBelow` / `DIRECT_WIFI_HELPS_BELOW`). The scheduler asks for a direct Wi-Fi lane only while the
rule allows it for the group (`Config::direct_wifi`, kept up to date) and the group has no LAN lane; direct Wi-Fi is
never added beside a LAN for speed. ADR 0021's 20 s give-up, the hour without asking and the 10 % judgement stay.

**4. iPhones.** The plugin's `NetworkDiscovery` includes peer-to-peer Wi-Fi in its listeners and browser only while
the phone is on no Wi-Fi network or on mobile data (its path monitor), and makes them again when that changes; the
Rust helper's racer dials awdl sightings only while the platform says the same, and closes what runs there once it
does not.

**5. The boost (ADR 0019).** Proposed only from a device the rule allows; the friend's READY says the same or it is
declined. A device that would leave its Wi-Fi network for the link (now only a phone on mobile data that does not stay
on its Wi-Fi beside the group) is always asked first: no device leaves its network silently. Its question says it
stays online: "Go faster? Mei isn’t on your Wi-Fi, so this is going over Bluetooth (about 12 min). Leave your Wi-Fi
for about 1 min to connect to Mei directly. Your phone stays online over mobile data and rejoins it by itself when
it’s done." (`transfer.boost.ask.mobile`, phones only; an iPhone adds "Then choose Join.", as iOS asks again). A Mac
boosts only while it is on no Wi-Fi network, so it is never asked and never leaves a network; it still comes back off
the link at the end. Android's "keeps its Wi-Fi" learning stays only so that a phone that does stay on its Wi-Fi is
not told it leaves it.

## Alternatives considered

- **Keep the 25 MB/s triggers and only fix the measurement.** Rejected: on one access point a second lane over AWDL can
  only take airtime from the first, and the owner's rule forbids it whatever it measures.
- **A new frame for the Wi-Fi state, sent when it changes.** Rejected: more protocol, and a device that changes network
  closes its AWDL sockets anyway; the handshake bit is fresh for every session and lane, and BOOST already carries
  Abilities.
- **Leave the question out for phones on mobile data** (ADR 0019's "stays online another way: not asked"). Rejected:
  the owner asked for no silent network switching.

## Consequences

- A Mac on Wi-Fi never wakes AWDL for Friends; transfers on one Wi-Fi run on the LAN alone, without the stalls.
- Two Macs (or a Mac and an iPhone) both off Wi-Fi still find each other over AWDL; with a helper from before the rule
  (Friends protocol 1, ADR 0024) they use another route.
- Boosts happen only between devices off Wi-Fi or phones on mobile data; a computer on Wi-Fi and a phone on another
  Wi-Fi stay on Bluetooth (or the Internet).
- Two capability bits used, one string added on phones; nothing for the host or the relay.

## Verification

- Unit: the rule (`nearby/p2p_wifi.rs`), the racer (`tests/nearby_discovery.rs`), the scheduler's lane asks
  (`scheduler_tests.rs`), the boost's decisions and negotiation (`transfer/boost/tests.rs`,
  `SZFriendsDirectWiFiBoostTests.m`), the scheduler scenarios (`fixtures/scheduler/scenarios.json`, key `direct_wifi`).
- Helpers: two Rust helpers boosting in test homes, a phone on Wi-Fi with mobile data and a host off Wi-Fi
  (`szfriends-helper/tests/direct_wifi_boost.rs`).
- Still to do on hardware: a Mac on Wi-Fi with its Friends helper on this build shows no `AWDL Active Time` and no
  524 ms ping stalls during a LAN transfer; two Macs on Ethernet with Wi-Fi off meet over AWDL.
