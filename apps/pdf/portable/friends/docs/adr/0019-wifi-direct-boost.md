# ADR 0019: Wi-Fi Direct boost

Status: Proposed. Date: 2026-10-29.
Builds on ADR 0004 (nearby routes), ADR 0011 § Route rank (the peer-to-peer Wi-Fi rule, amended here), ADR 0015 § 9
(phones' discovery), ADR 0017 (what the person sees) and ADR 0018 (lanes, the scheduler, capability bits). Areas:
session (frame 32, fields 48 to 53, capability bit 5), the transfer core (`szfriends-core/src/transfer/boost.rs`), both
helpers' services, the phones' plugin (Kotlin and Swift), the Mac helper's Wi-Fi (CoreWLAN), presentation (the
question and the notes), the views (two actions). Journal: `portable/docs/journals/shenzhen-friends/2026-10-29-fast-transfers.md`,
§ Wi-Fi Direct boost.

## Context

The owner, 2026-10-29: when two devices found each other by Bluetooth only, and are verified not to be on the same
network, Wi-Fi Direct could be negotiated; a computer or phone already on a Wi-Fi network would ask "do you want to
disconnect internet wifi to go faster using wifi-direct?" and reconnect that Wi-Fi at the end.

Until now the rule was absolute (ADR 0011 § Route rank, ADR 0015 § 9, ADR 0018 § 6): direct Wi-Fi is used only where
the device stays on its Wi-Fi network at the same time, so a transfer never costs a device its Internet connection. In
practice that is AWDL between Macs and iPhones; everything else skips direct Wi-Fi. This record keeps that rule as the
default and adds one exception: **a device may leave its Wi-Fi network for a direct link only after its person said so
on that device, for that transfer, and it rejoins its network by itself when the transfer ends.** Without that
answer, nothing changes. A device that keeps its Wi-Fi while on the link (Android hardware that runs station and
Wi-Fi Direct at once) or that has another way online (a cable, mobile data) is not asked. Multi-band concurrent Wi-Fi
(one radio on two bands) was weighed by the owner and rejected; it is not used.

What it is worth: Bluetooth moves 0.15 to 0.2 MB/s between a phone and a computer (1.4 Mbit/s raw, ADR 0018's
measurements), so 100 MiB takes about 10 minutes; a Wi-Fi Direct link moves 10 to 40 MB/s, the same file in under 30 s
once the link is up (10 to 15 s).

What the platforms allow (checked against their current documentation, 2026-10; what the real-device script must
still confirm is marked):

| Platform | Host a link others join | Join a link | Leaves its own Wi-Fi? | Asks the person itself? |
|---|---|---|---|---|
| Android 10+ | `WifiP2pManager.createGroup` with `WifiP2pConfig.Builder` (our name and passphrase; the group owner is 192.168.49.1, legacy clients join it as a WPA2 network) | As a Wi-Fi Direct client, `WifiP2pManager.connect` with the same builder | Not where the hardware runs station and P2P at once (most phones; `WifiManager.isStaApConcurrencySupported` and the P2P state say so), else yes | No: needs `NEARBY_WIFI_DEVICES` (13+) or fine location (10 to 12), which the app asks for with Bluetooth's |
| Windows 10+ | `WiFiDirectAdvertisementPublisher` with `LegacySettings` | The WLAN API (`WlanConnect`) | Hosting no; joining yes | No |
| macOS | No API | CoreWLAN `CWInterface.associate(to:password:)` after a scan for the name | Yes | Joining shows no prompt; the scan needs Location Services for the helper (one system prompt, once) or names come back empty. Whether the network is added to Known Networks: to confirm |
| iOS | No API | `NEHotspotConfiguration` (`joinOnce`), Hotspot Configuration entitlement | Yes | Yes, every time: "“Shenzhen 3D” Wants to Join Wi-Fi Network …" with Join and Cancel |
| Linux | wpa_supplicant P2P or a NetworkManager hotspot | NetworkManager | Depends on `iw list` | No |

Two of these never meet the trigger: **Windows has no Bluetooth route** (no LE L2CAP channels for apps, ADR 0015 §
9), so two devices can never have met there by Bluetooth alone; and **Mac with Mac, iPhone with iPhone, Mac with
iPhone** already have AWDL, which needs no disconnect. So the pairs that matter are an Android phone with a Mac, an
iPhone or another Android phone, and the phone hosts.

## Decision

### 1. When

All of these, judged by the side that sends the file (it measures the rate):

- **Bluetooth alone.** Every live session of the friend's group runs over Bluetooth.
- **Not on the same network.** The friend's device was not seen on the local network in the 10 s since the group went
  to Bluetooth alone, or it was and 3 lane dials there failed. Seen on the network, the ordinary LAN route gets its
  chances first (`not_on_same_network`).
- **Worth it.** The rest of the transfer would take at least 20 s longer over Bluetooth (at its measured rate, or 150
  kB/s until measured) than over a direct link counted at 8 MB/s plus 15 s of setup (`worth_it`). With 150 kB/s that
  means about 6 MiB or more left; a few-megabyte file never triggers it.
- **Both helpers set capability bit 5,** this device can host or join (§ 7), and nobody said Not now to this
  transfer.

### 2. Negotiation

One more frame on the group's existing encrypted session, the Bluetooth one: **BOOST** (type 32, session minor 4, sent
only when both handshakes set capability bit 5 on a fast session; `FrameType::Boost`). Fields: ID (the transfer's
16-byte id), Step (48, u8), Abilities (49, u8), Network (50, 1 to 32 bytes), Passphrase (51, 8 to 63 bytes), Address
(52, 4 or 16 bytes), Port (53, u16), Reason (23).

| Step | Who | Carries |
|---|---|---|
| 1 PROPOSE | the side that saw § 1 | its Abilities: can host, can join, hosting keeps its Wi-Fi, joining keeps its Wi-Fi |
| 2 READY | each side, once its person agreed or nobody needed asking | its Abilities |
| 3 HOST | the host, once both sent READY and its link is up | Network, Passphrase, Address, Port |
| 4 END | either side | Reason: done, slower, failed, transfer ended, quitting |
| 5 DECLINE | either side, instead of READY | Reason: not now, unsupported, failed |

**Who hosts:** of the pairings that work, the one that takes fewer devices off their Wi-Fi; on a tie, the side whose
identity key sorts first (`role`); both sides compute the same answer from the two Abilities. No pairing (two devices
that only join) means DECLINE with Reason unsupported. Proposals that cross count as each other's answer.

**The link:** the host makes a new network name and passphrase for every boost: "DIRECT-" and ten random letters and
digits (Android requires the prefix; nothing in it names Friends or anyone), and 20 random letters and digits (about
119 bits). They travel only in HOST, inside the Noise session; they are never logged, stored or shown. The joining side
accepts a HOST only after both sides sent READY, only with a name starting "DIRECT-", and only with a private IPv4
address or an IPv6 link-local or unique local one.

**Binding to the same identity:** the joining side, once on the link, dials an ordinary lane (ADR 0018 § 6) to Address
and Port with route class peer-to-peer Wi-Fi: a Noise IK session to the friend's verified static key whose Lane token
comes from the first session's handshake hash. The host admits it into that group only; anything else on that port
is refused as any lane is. So the link reaches the same identity or carries nothing.

### 3. The question

Asked only on a device that would lose its Internet connection: on Wi-Fi, with no cable and no mobile data
(`Cost::LeavesInternet`). A device that keeps its Wi-Fi on the link is not asked. A device that leaves its Wi-Fi but stays
online another way is not asked; its transfer's note says so ("…Your phone stays online over mobile data meanwhile.").

It appears on the transfer's row in the conversation (PROTOCOL.md § Fast transfers), as its note and two buttons:

> Go faster? Mei isn’t on your Wi-Fi, so this is going over Bluetooth (about 12 min). Leave “HomeWiFi” for about 1 min
> to connect to Mei directly. Your Mac rejoins it by itself when it’s done.
>
> **Go faster** · Not now

The network's name appears when this device knows it ("your Wi-Fi" otherwise); it is shown on this device only. On an
iPhone the note ends "Then choose Join.", because iOS asks again with its own prompt. **Not now** is final for that
transfer: neither side proposes again for it, and the other side's question goes too. A question still open when the
transfer ends goes with it. "Always for Mei" is not offered yet: it needs a place to undo it (a switch in Mei's
details beside "Accept files automatically"), which is a separate change.

### 4. Coming back

Before a device leaves its network it writes `direct-wifi.json` in the helper's state directory: the network to come
back to (a platform reference, or none when it was on no Wi-Fi), its name for the person, the link joined and when. It
rejoins that network as soon as the boost ends for any reason: the transfer finished, failed or was cancelled, the
lane closed or measured slower (§ 5), the link never came up within 45 s, the session ended, the peer sent END, or the
app quits. If the helper crashed or was killed, the next launch finds the record and rejoins before anything else.
Rejoining is tried 3 times, 3 s apart; then the device checks that it is online again (the platform's own path
monitor, no traffic of ours) every 2 s for up to 20 s. Back online, the record is deleted. Otherwise the record is
deleted too (the person decides from then on, and a later launch must not fight them) and the transfer's note says:
"Your Mac didn’t get back on “HomeWiFi” by itself. Choose it in the Wi-Fi menu." (on a phone: "…in Wi-Fi settings.").
The host takes its link down at the same moments.

### 5. Speed: one more lane

The direct link is one more lane of the group (ADR 0018 § 6, route class peer-to-peer Wi-Fi), so the scheduler gives it
blocks by its measured rate beside Bluetooth, with the same silent-lane and endgame rules. On a device where direct
Wi-Fi would cost the Internet connection the scheduler closes such lanes (`direct_wifi_keeps_internet`); during a
consented boost it keeps that one (`allow_direct_wifi`). **Never slower than without it:** 6 s after the lane went up,
if it measures no faster than the Bluetooth lane, the boost ends and the device comes back; Bluetooth carries on alone
as before. The estimate behind § 1 assumes 8 MB/s, well under what Wi-Fi Direct does, so the question never promises
more than happens.

### 6. Security and privacy

- Nothing about the link outside the Noise session: name and passphrase only in HOST, random per boost, never
  logged (the core's `Link` prints its name only), never stored; the group is taken down after the boost.
- The lane is a full IK session bound to the first session (§ 2); a stranger who joins the link meets a listener that
  admits nothing but lanes of live groups.
- Nothing new for the Friends host or the relay: no message, no field; no network names or places leave the device.
  The record of the network to rejoin stays in the state directory.
- What a friend could do: make the joining device join a network of their choosing, for at most 45 s plus the transfer,
  only after the person said Go faster for that friend's file. The joining side refuses names not starting "DIRECT-"
  and addresses outside private ranges, and leaves the link at the end. Other apps on the joining device use the link
  meanwhile; the phone hosts with no Internet sharing, so they simply find no Internet there.
- Location: the Mac needs Location Services to see networks by name (CoreWLAN); the helper asks for it the first time a
  boost needs it, after Go faster, with "Friends uses this only to find the Wi-Fi network a friend’s phone makes for a
  transfer. Your location is never stored or sent." Android's permission is the one Bluetooth already asks for.

### 7. Platforms

- **Android** (the core in Shenzhen 3D, through the plugin's Kotlin): hosts (`createGroup`, persistent mode off, any
  band) and joins Android hosts as a Wi-Fi Direct client. Abilities say whether each keeps its Wi-Fi from the
  hardware's concurrency. Connectivity from `ConnectivityManager` (Wi-Fi, mobile data, validated).
- **iPhone** (the core in Shenzhen 3D, through the plugin's Swift): joins with `NEHotspotConfiguration` (`joinOnce`)
  and comes back with `removeConfiguration(forSSID:)`, after which iOS rejoins its own network. Needs the Hotspot
  Configuration entitlement in the app's profile.
- **Mac** (the Objective-C helper): joins with CoreWLAN behind `SZFriendsWiFiJoining`, comes back by associating with
  the network it wrote down (the system's saved password), and checks with `nw_path_monitor`. Tests use a mock; no
  test ever touches the Mac's real Wi-Fi.
- **Windows, Linux:** not built. Windows cannot meet the trigger (no Bluetooth route); Linux could host through
  NetworkManager later. Both keep capability bit 5 clear, so nobody proposes to them.

### 8. Client protocol

Two intents, `boost_transfer` and `skip_boost` (field `transfer_id`), behind the client capability `transfers.boost`:
a view that declares it shows the two actions; the helper puts the question only in snapshots for such views, and
answers it from the first one that does. A device whose views do not declare it is never asked, so the old rule holds
there. No helper capability: a helper without the boost never sends the actions.

## Alternatives considered

- **Multi-band concurrent Wi-Fi** (station on one band, a link on the other, no disconnect): rejected by the owner.
- **Never leaving the network** (the rule until now): keeps phone-to-computer transfers at Bluetooth speed whenever the
  two are on different networks, which is what the owner asked to change.
- **Asking every time on every device:** a phone that keeps its Wi-Fi, or has mobile data, has nothing to lose; asking
  there would be noise.
- **Android `LocalOnlyHotspot` as the host:** the system picks name and passphrase (fine) but most phones drop their
  own Wi-Fi to run it, where a Wi-Fi Direct group runs beside it.
- **Wi-Fi Aware (NAN):** Android only among our platforms, and no interop with Apple's; noted for later between two
  Android phones.
- **The host carrying the joining side's Internet:** would make the boost invisible, but routes the person's traffic
  through a friend's phone.

## Consequences

- Phone-to-computer transfers on different networks can move at Wi-Fi speed, with a question on the device that would
  lose its Internet and an automatic way back.
- The old rule is now "never without the person's word": ADR 0011, 0015, 0018 and PROTOCOL.md say so.
- One more frame, six fields, one bit; two intents, one client capability; one small record on disk.
- On a Mac, Location Services the first time (system prompt), and possibly the link left in Known Networks (to confirm
  on hardware; the device script checks).

## Verification

- Unit: the decisions, the negotiation and Rejoin, crash recovery included (`transfer/boost/tests.rs`); frame vectors
  (`fixtures/vectors/transfer/frames.json`, `boost_*`); the Mac's coordinator against a mocked CoreWLAN.
- Helpers: two Rust helpers in test homes on the test Bluetooth air with a test direct-Wi-Fi radio (a loopback
  "link"): the boost is proposed, asked, the lane comes up and carries the file, the way back runs; Not now sticks.
- Real APIs: the Android emulator and the Windows VM where they reach (the journal says what ran).
- Real devices: the journal's script for the owner's phone and Macs.
