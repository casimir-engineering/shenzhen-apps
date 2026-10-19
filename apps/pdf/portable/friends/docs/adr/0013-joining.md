# ADR 0013: Joining a profile from a new computer

Status: Accepted (lead integrator, 2026-10-15). Date: 2026-10-14.
Plan: [friends-multi-device.md](../../../docs/plans/friends-multi-device.md) § Joining. Builds on ADR 0012 (the device
chain), ADR 0004 (Add by ID's NN sessions) and ADR 0010 (opens by Friends ID). Areas: identity (CPace and the
exchange: `service/identity/SZFriendsCPace.h`, `SZFriendsJoin.h`), session (the JOIN frame), online driver (opens by
ID carrying a join payload), helper (`nearby/SZFriendsNearbyService+Join*.m`, `SZFriendsIntentRouter+Join.m`),
presentation (`SZFriendsPresentationJoin.h`). The views' side is PROTOCOL.md § Joining.

## Context

A new computer must get the person's profile without copying any private key (ADR 0012), with the person's say-so on
a computer that already has it, and without trusting anything between the two: nearby, any device can answer an NN
session; online, the host forwards everything. The owner's words: "a new app install on a new computer can request
sharing a profile from the other devices by entering its username. then all devices connected receive a
notification; after they confirm the new device must enter a code that appears on the old device."

## Decision

**The request.** The new computer draws a 16-byte request id and signs (its own device key, domain
`"SZFriends join request v1"`) its device key, static key, name, system, the Friends ID typed and the time. Nearby it
goes over NN to every device the new computer cannot recognise, exactly as Add by ID's request, and every device
answers RECEIVED alike; online it is the payload of a protocol 3 open `to.join` that Friends ID (`'J'`, 1, the
request), which the host hands to each connected device of the person holding the ID (HOST-PROTOCOL-ONLINE.md § Join
requests; at most 60 an hour toward one person, 40 an hour from one device), nobody answers, and nothing is stored.
The new computer counts its join opens against those 40 itself, apart from Add by ID's 5 opens by ID an hour (amended
after review: they shared the 5, so a few repeats left the new computer unable to send its code).
A device keeps it only if it verifies, names this profile's ID, is within 10 minutes of its clock, and comes from a
device the chain neither holds nor ever revoked. At most 3 rows wait on one device, 6 new rows an hour, one per
requesting computer; a row ends 30 minutes after the last copy. At 3 rows the newest request takes the place of the
waiting row repeated least recently (an approval keeps its place), and taking a place is not a new row: it spends
nothing of the hour (amended after review: six requests nobody wanted used to fill the hour, and the person's own
computer's request was then turned away). So spam cannot keep the person's new computer off the list: its request,
repeated every presence window nearby and every 20 minutes online, is the most recently repeated one and shows again
at its next repeat whatever came between. A row the person denied, or that another computer added meanwhile, gives
its hour's slot back. Rows live in memory only.

**Approval.** Only the person's Approve draws a code: 8 digits from `randombytes_uniform`, valid 5 minutes, shown on
that device only. Approve again on an approved row is success with the same code (a second click or a second view
never voids the one shown); the views disable Approve once pressed. Deny ends the request, and the same computer is
turned away for 30 minutes.

**The code.** Typing it runs CPace (draft-irtf-cfrg-cpace-13, ristretto255 with SHA-512, checked against its
Appendix B.3 vectors) on a new NN session from the new computer: nearby to every device again, online as an open
carrying NN message 1 (`'J'`, 2) that only a device holding an approval answers. PRS is the code; CI is
lv_cat(`"SZFriends join v1"`, request id, device key, static key); sid is the NN handshake hash; ADa the new device
key; ADb the approving device's key and the root key. The approving device answers Yb with tag Tb = BLAKE2b-256 keyed
with ISK over `"SZFriends join responder v1"`; the new computer, only once Tb verifies, signs its consent to that root
(ADR 0012) and sends it with Ta over the consent; the approving device then signs the add link, stores the chain,
and sends the chain and its welcome in 900-byte parts under a third tag: the PROFILE frame, the person's presence
secret and the secret the person's computers find each other by, so a computer joined online reaches friends and
syncs online at once. The new computer adopts the chain only if it holds the new computer with its own static key and
the device that showed the code, and the profile only if its Friends ID is the one typed. From then on it checks in
for the person (protocol 3, HOST-PROTOCOL.md § Devices), after releasing the ID it held on its own, and never draws an
ID after a collision: the person's ID is reserved from their first computer. WHY a PAKE: a hash or MAC of
an 8-digit code over an unauthenticated session falls to offline guessing; CPace gives whoever lacks the code one
guess per run. Every run counts one of 3 attempts before any work, so the third failure ends the approval.

**Why the new computer dials.** The plan has the approving device connect; it cannot find the new computer (no
presence tags, no record, not a friend). The new computer can always reach the profile's devices by ID, so it opens
every session, and its code field shows from the start: "approve there, then type the code it shows".

## Alternatives considered

- **SPAKE2 or OPAQUE.** SPAKE2 needs fixed generators with unknown discrete logs; OPAQUE is asymmetric and built for
  stored passwords. CPace is balanced, has CFRG vectors, and runs on libsodium's ristretto255 as it is.
- **A short authentication string compared by eye** (as Bluetooth pairing). The person would compare two codes on two
  screens; typing one code is easier and binds the session the same way.
- **A host-side join mailbox.** Stored state on the host and a new message type; opens by ID already fan out.

## Consequences

- Online, the host reads the request: the new computer's keys, name and system, which it learns anyway once that
  computer checks in. It cannot approve or learn the code; replaying a request only refreshes the same row, and the
  most it can do is spend attempts (3) or join opens (40 an hour for the caller), which ends that try.
- Nearby, any device may answer a code session; one that is not the approving device cannot produce Tb, which the new
  computer reports as a wrong code. Every device the new computer could not recognise received its request id, so any
  of them, like the host, can spend the 3 attempts: a nuisance that ends that try, never a way in.
- A restart forgets rows and approvals; the new computer repeats its request (each presence window nearby, every
  20 minutes online). A code already shown must be approved again.
- A friend learns of the new computer only from the chain (ADR 0012); syncing the profile's friends and chats to it is
  the sync area's.

## Verification

`friends-identity-check`: `SZFriendsCPaceTests` (the draft's vectors, invalid points), `SZFriendsJoinTests` (a whole
run; wrong, three wrong and expired codes; no approval; a device in the middle with two sessions, a substituted root
or substituted keys; every changed byte), `SZFriendsJoinLimitTests` (what is shown, spam limits, six spam requests
before the person's own, the most recently repeated request keeping its place, Approve twice, Deny, codes, format).
`friends-session-check`: JOIN only in NN, both ways. `friends-driver-check`: join payloads reach the helper and never
Add by ID, go out `to.join` under a budget of 40 an hour apart from Add by ID's 5, and an open through `to.join` that
is not a join payload is silence. `friends-views-check` and `friends-gtk-details-check`: Approve disabled once pressed.
`friends-e2e-devices-check`: the request shows on both of the profile's computers and clears on the one that did not
approve.
`friends-helper-check`: two helpers joining nearby (a middle device, wrong codes, Deny, uniform answers) and through an
in-memory host with no nearby route (the joined computer holds the presence and own-devices secrets and can reach the
other online), the pre-join release owed, and the intents and views through a real helper. `friends-host-check`: a
joined device checking in for its person against the real host, and 4002 stopping it.
`friends-presentation-check`: the rows, badge and `join` view against § Joining's pending schemas.
