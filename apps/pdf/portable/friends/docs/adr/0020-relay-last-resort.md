# ADR 0020: The relay, last resort only

Status: Accepted (the owner's rule, release-blocking). Date: 2026-11-01.
Amends ADR 0011 § Leave the relay (the retry timers) and ADR 0018 § 6 and § 7 (the relay in a group). Builds on
ADR 0001 (the session race, resume), ADR 0004 (nearby routes) and ADR 0010 (the relay). Areas: the online order (both
helpers), the scheduler (both), the block exchange (both), nearby dialing (both), the transfer bench. Checked by
`make friends-relay-rule-check`, in every app's release suites.

## Context

The owner, 2026-10-31: "relay needs to be used in last resort and then keep being used only if the transfer started
like that but any newly available methods during the transfer should be used immediately". A release must not ship
while this is broken; a breach found later needs a fix release.

An audit of the released helpers (ShenzhenPDF and Shenzhen Files 26.10.31-1, Shenzhen 3D 0.2.5, helper 26103101)
against the rule found:

1. **Direct Internet was retried rarely while relayed.** After the relay carried a stream, the order tried a direct
   connection again 30 s later, then 60, 120, up to 300 s (ADR 0011): a peer-to-peer path that became possible
   mid-transfer waited up to five minutes.
2. **Nearby dialing backed off while relayed.** A friend's endpoints that failed while they were away (their LAN entry
   lingering, Bluetooth out of range) kept their backoffs (2 s doubling to 900 s per endpoint, 1 s doubling to 300 s
   per person), and nothing looked at them again while the relay session lived. Bluetooth scans report a device once
   per scan and restarted every 30 s, so a friend coming back into range was seen up to 30 s late. Lanes the scheduler
   asked for while relayed were asked again after 10 s.
3. **The relay finished what it held.** When a direct lane came up beside a relay session, the relay stopped getting
   new blocks but kept the ones it had: 0.26 to 1.4 MB more over the relay in the simulator's scenarios.
4. **A slow direct lane could give the file back to the relay.** The relay was allowed whenever no direct lane was
   *working*, and a Bluetooth lane holding blocks it is slow to finish counts as silent after 2 s without a write or a
   HAVE, though it still hears the peer. Once the relay's blocks moved to Bluetooth (3), that is what happened on the
   bench: 640 to 770 KB of a 1 MiB file went back over the relay beside working Bluetooth.
5. **A transfer offered while the relay carried the group started on the relay.** The leaves went on the group's
   first session (the relay) and no part could go on another lane before a HAVE: the direct lane held blocks it could
   not send, counted as silent after 1 to 2.5 s, and the relay sent the first blocks. On the bench, the relay beside
   a LAN lane that worked from the start, then cut and back, carried 525 to 591 KB of a 16 MiB file beside it (now
   33 KB, all after the LAN came back, and 0.2 KB of pings while it worked from the start).
6. **When Bluetooth went, the relay opened without trying direct first.** In Standby (Bluetooth carried the session),
   losing Bluetooth opened the relay at once, though the last direct try could be minutes old.

The first-part times on a new route were already good once the route was up (5 ms for a LAN session that won the
race, 40 ms for a direct Internet one, 90 to 130 ms for a lane): the breaches were in finding the route, in what the
relay kept and in what it took back.

## Decision

**1. Last resort.** The relay carries data only when no direct route works: the same network, direct Wi-Fi, a direct
Internet connection and Bluetooth have all failed or are unavailable. The online order opens it only after the direct
budget (ADR 0011) with no other route carrying the session; when the route carrying it (Bluetooth) goes, it tries
direct once more first and opens the relay only when that try fails.

**2. Started on the relay: every new route at once.** While the relay carries a session, direct routes keep being
tried, each at most a second apart:

- online: a new direct connection a second (±20 %) after each try ends, never backing off
  (`RELAYED_RETRY_GAP`, `SZFriendsOnlineRelayedRetryGap`); a try is its signalling and plain checks (at most 5 s
  once both descriptions are in);
- nearby: once a second the person's dial backoffs end, Bluetooth scans afresh and every candidate is looked at again
  (`RELAY_PROBE_SECONDS`, `SZFriendsRelayProbeInterval`); the network's browse reports a device that joins at once;
- lanes: Bluetooth and direct Wi-Fi are asked for every second (`REQUEST_WHILE_RELAYED`), and dialed again a second
  after a failed dial.

A route found that way is used at once: a session on it wins the session race and the transfer resumes on it (ADR 0001);
a lane on it takes every block, and the relay's blocks go back to be sent on it, its parts not yet written dropped. The
relay keeps its session for when every direct route is gone again.

**3. Started direct: the relay never beside a working direct route.** The relay takes blocks only while no direct lane
of the group reaches the peer. A direct lane reaches it while it is open and has heard from the peer within its
silence limit (2.5 s, 3.5 s on Bluetooth; both ends ping every second while a file moves): a lane that is only slow,
or busy with parts it no longer needs, still reaches. A transfer's leaves (HASHES) go on the group's best-ranked live
lane, and parts go there until the first HAVE, so a transfer offered beside the relay starts on the direct lane. When
every direct route is gone, the relay may carry the transfer (1), and (2) applies again.

**The bounds.** From the moment a route is connectable to its first byte of the transfer: a LAN that the friend's device
joins, under a second (its announcement, a dial at once, a handshake); Bluetooth back in range, about a second plus
its handshake (a fresh scan every second, a dial 0.5 s after the sighting); a lane up, its first part within 150 ms
(bench); a direct Internet path, the next try a second after the last ended, so about a second when the path opens
between tries and up to one try's plain checks (5 s) when it opens just after a try's checks gave up.

The never-slower rule (ADR 0018 § 7) still holds among the direct lanes; the relay does not count as a lane to compare
with while a direct one works.

## Consequences

- The host signals a new offer and answer about every 2 to 6 s per relayed friend while the relay carries their
  session, and STUN sees the same. Relayed sessions are rare and short-lived (an hour at most, ADR 0010).
- A Bluetooth scan restarts every second while the relay carries a session.
- A transfer the relay would have finished sooner beside slow Bluetooth now goes over Bluetooth: the owner's rule
  ranks the relay last.

## Verification

`make -C apps/pdf/portable friends-relay-rule-check` (in `friends-suite`, and in Shenzhen Files' and Shenzhen 3D's
release suites), about 45 s once built:

- the scheduler's scenario table (`friends/fixtures/scheduler/scenarios.json`, rows "relay rule: …", both schedulers;
  the Objective-C one through `friends-transfer-check`): a lane, LAN, direct Internet or Bluetooth, coming up beside
  the relay carries its first part within 50 to 200 ms and the relay writes at most one part after it
  (`max_relay_beside_direct_kib`); the relay idle beside a working LAN or Bluetooth; Bluetooth out of range, the relay
  takes over; the LAN cut, the relay alone, the LAN back;
- the online order (both; `friends-order-check` for the Objective-C one): 200 tries in a row while relayed, each at most
  1.2 s after the last ended; direct tried before the relay when Standby's route goes;
- the racer (both): backoffs of a relayed person end at each probe;
- the transfer bench (`BENCH_RELAY`), every pairing of the two helpers: the relay first, then a LAN or direct Internet
  session that wins the race, or a LAN, direct Wi-Fi or Bluetooth lane; the relay beside a LAN from the start, the LAN
  cut and back. It fails when the relay carried more than 512 KiB beside a working direct route (what was already in
  its socket; 33 to 263 KB measured), more than 64 KiB beside a LAN that worked from the start, or when a new route
  carried its first part more than a second after it came up.
