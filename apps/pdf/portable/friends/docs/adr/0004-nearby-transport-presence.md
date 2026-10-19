# ADR 0004: Nearby transport and presence

Status: Accepted by lead; owner review pending. Date: 2026-10-12.
Brief: § Nearby, release gates "Discovery", "Routes", "Friends ID". Areas: discovery (owner), session, store.

## Context

Nearby Friends must work without a shared network, with Wi-Fi off on one Mac, and with the host down. A
person found several ways is one row. Strangers must not identify or follow hidden friends, and launch
must never show a permission prompt to someone who has not opened Friends.

## Decision

**Two adapters, started together, each independent**, on activation and after wake.

- **Network.framework:** one listener and one browser for the Bonjour type `_szfriends._tcp`, TCP with
  `include_peer_to_peer`, so one code path covers LAN and peer-to-peer Wi-Fi. Route class comes from the
  connection's path: an `awdl` or `llw` interface is peer-to-peer Wi-Fi, anything else LAN. Instance names
  are random per presence window, never the Mac's name. TXT: `v=1`, `t=<tag>` and, while Add-by-ID
  requests are pending, `c=<callback tags>`.
- **CoreBluetooth:** a peripheral advertising one fixed Friends service UUID (plus a fixed public UUID
  during visibility); a characteristic returning the current tags and the L2CAP PSM; the channel published
  with `publishL2CAPChannelWithEncryption:NO`, since Noise encrypts and link encryption would demand
  pairing. A central scans for the service UUID with duplicates off and restarts each window so rotated
  tags are seen. If the spike shows the tag fits the advertised local name, it goes there and the read is
  skipped. L2CAP streams carry the same Noise sessions as TCP.

Bluetooth addresses, peripheral identifiers and Bonjour instance names are never identity.

**The merger.** Adapters report sightings (method, endpoint, tags, public flag, time) to the discovery
merger: pure, no radios, clock injected. It maps tags to friends, keeps a separate expiry per method
(Bonjour: removal plus 30 s; Bluetooth: 90 s since last seen) and drops a candidate only when every method
has expired, so a brief loss does not flip the route icon. A denied, off or failing method reports its own
state, never delays the others, and starts itself when its radio or permission returns. A stranger enters
Nearby only after a handshake has returned their key and profile, which keeps one row per person.

**Route racing.** A friend seen on several methods is dialed on all of them with IK, staggered toward the
faster routes (LAN at 0 ms, peer-to-peer Wi-Fi at 150 ms, Bluetooth at 500 ms; the spike tunes). The first
completed handshake carries traffic; slower attempts continue only while they could find a faster class,
then close. A Bluetooth sighting triggers Wi-Fi attempts to every endpoint known for that friend and a fresh
browse. Bluetooth carries messages and files only while no Wi-Fi route works. Tie-break and transfer
migration: ADR 0001.

**Presence tags.** Each identity holds a 32-byte presence secret and sends it to each friend on acceptance
(PRESENCE_SECRET). Tag for window `w` = first 8 bytes of BLAKE2b-256 keyed with the secret over
`"SZFriends presence v1" || u64be(w)`, with `w = floor(unix seconds / 900)`. Matchers try `w-1`, `w` and
`w+1`, tolerating 15 minutes of clock skew. A stranger sees 8 bytes that change every 15 minutes and cannot
link one window to the next. On remove or block the helper draws a new secret at once and queues it to every
remaining friend through the outbox; the removed or blocked person keeps a dead secret. Friends not yet
updated are still found by us, because their own tags did not change, and the next session updates them. A
false match costs one failed IK.

**Hidden listeners.** Outside visibility a listener accepts only IK from a known, unblocked static or from
a key presenting one of its pending request tokens (step 4 below), both checked on message 1 before any
reply, and NN Add-by-ID requests. Anything else is closed without a reply.

**Public visibility.** "Make myself visible for 5 minutes" stores an absolute deadline and adds a public
entry on both adapters: a separate Bonjour instance with TXT `p=1` and no tag, and the public UUID on
Bluetooth. Public entries accept XX, and the responder's message 2 payload carries name and picture, so a
browser can list the person and close before message 3 without revealing itself; completing message 3 is a
friend request. The deadline stops both adapters together. Expiry, sleep, wake and disabling never extend
it; after a wake past the deadline, visibility stops before anything else is advertised.

**Add by ID nearby, over Noise NN with uniform replies.**

1. The requester opens NN to each nearby Friends device, hidden or public, once per device per window, and
   sends REQUEST_BY_ID: target ID, a fresh 16-byte request token, a fresh 32-byte callback secret, the
   requester's cert and static key, and an Ed25519 signature over the NN handshake hash, so the request
   cannot be replayed into another session.
2. Every device answers with the same fixed-size RECEIVED frame as soon as the request parses, before any
   lookup, so neither content nor timing reveals who holds the ID. Non-holders keep nothing. A holder stores
   it as a request row; a blocked sender is dropped after the same reply. Limits per sender key: 5 pending,
   one per target per hour; per listener: 60 NN sessions a minute.
3. The requester stores the request in `id_requests` and, while it is pending (at most 4, expiring after 7
   days), advertises callback tags derived from each callback secret exactly like presence tags. The outbox
   keeps offering the request to newly seen devices (and, in M2, online).
4. On Accept, the holder matches the callback tag, dials IK to the requester's static and presents the
   request token; the requester's listener accepts an unknown key only with a token it issued. That session
   runs the comparison-code exchange (ADR 0001), and both sides show the friend as unverified with its code.
5. Two unreserved holders of one ID may both accept; the requester sees each with name and code (brief).

**Permissions at launch.** Until the user has opened Friends once, launch activation runs only the host
connection.

- Local Network (macOS 15 and later) has no query API, and browsing is what prompts. The Network.framework
  adapter starts at launch only when the store's Nearby-permission-asked flag is set; the first dropdown
  open sets it and starts the adapter, which prompts. Denial is inferred only from the DNS-SD
  `PolicyDenied` error, never from an empty result.
- CoreBluetooth: the class property `CBManager.authorization` reads the state without creating a manager,
  which would prompt. Not determined: wait for the first open. Allowed: start at launch. Denied or
  restricted: report it and start nothing.

Each state (searching, nobody visible, Local Network access denied, Wi-Fi off, Bluetooth access denied,
Bluetooth off) reaches the views as its own snapshot state; the wording lives in the strings catalog.

## Alternatives considered

- **Multipeer Connectivity**: no Bluetooth on macOS, no control over what advertisements reveal.
- **Fixed identifiers or the Friends ID in advertisements**: strangers could identify and follow hidden devices.
- **One tag per friend**: an advertisement cannot carry a tag for every friend.
- **Bluetooth link encryption**: requires pairing dialogs; Noise already encrypts.

## Consequences

- Nearby devices learn the requester's identity key and static key and the ID asked for, never who holds it.
- **Any nearby device that hears an Add by ID can answer it.** The request token is a bearer secret every
  recipient receives, so the token proves only that the answer heard the broadcast. An answer is an unverified
  person until codes are compared; Review amendments, 1, bounds what a false answer gets. The host's attestation
  (Review amendments, 9) tells the holder apart when the holder has checked in within 30 days; a holder that never
  reached a host answers unattested like anyone else, so the requester accepts that answer as a request of its own
  before it becomes a friend (Review amendments, 11), and someone whose ID was released and given to another can
  still show their last attestation for up to 30 days.
- **Anyone with a request waiting, in either direction, can locate our hidden listener** while IK stays open to
  them (Review amendments, 8 and 12): six hours for a request they sent us after finding us nearby, never for one
  sent to our Friends ID; seven days for a request we sent to someone nearby, and for an Add by ID answer while the
  request that admitted it lasts (seven days from our asking). Then the request lapses.
- **Recipients of a broadcast can follow the requester while its callback tags are on the air**, because callback
  tags are presence tags over a callback secret every recipient learns. Review amendments, 2, cuts that to the
  first hours after each broadcast and to one day per secret.
- **The Bonjour SRV hostname and IP address are not rotated.** Network.framework registers the hidden and public
  entries under the Mac's mDNS hostname (often the owner's name, "Raphaels-MacBook-Pro.local"), which survives
  Reset Friends, and its current address. A stranger on the same network can link one window's tag to the next by
  hostname or address even though the instance name, tag and port change. Bluetooth has no such stable value
  once the PSM rotates, apart from the address rotation macOS schedules on its own; while visible this holds only
  since the public entry got its own characteristic and channel per window (Review amendments, 7). Whether the BLE
  address really changes when advertising restarts is a hardware-matrix row, not yet observed.
- **While visible, the public entry shares that hostname and address with the hidden entry**, so anyone who saw
  the person's public name and picture can recognise their hidden device on the same network for as long as the
  hostname and address stay the same, well past the 15-minute window.
- **Tags can be relayed.** A tag is a bearer value accepted for windows `w-1` to `w+1`, so anyone can re-advertise
  a captured tag for about 30 minutes, anywhere. Friends of its owner then dial the relayer with IK; message 1
  stays opaque, but the relayer learns which devices, hostnames or addresses are that person's friends.
- After a remove or block, each remaining friend can find us again only after their next session with us; until
  then we find them by probing (Corrections).
- Which app name the prompts show depends on attribution (ADR 0002).

## Verification

- Merger tests with scripted adapters: simultaneous, out-of-order, flapping and expiring sightings; one row
  per person; a denied method leaves the others' time to first result unchanged.
- Tag tests: known-answer vectors, window boundaries, `w±1` matching, no match after rotation, none across
  identities.
- Racing tests with injected delays: first handshake wins, a faster class supersedes, Bluetooth then Wi-Fi.
- NN tests: holder, non-holder and blocked responders send byte-identical replies; the reply precedes the
  lookup (slow store fake); a signed request replayed into another session is rejected; limits hold.
- Two-helper harness over loopback Bonjour plus the scripted slow Bluetooth adapter (brief § Testing).
- Launch: with a fresh store, the adapter factory creates no browser, listener or Bluetooth manager until
  the first-open intent.
- Hardware matrix: peer-to-peer Wi-Fi, Bluetooth with Wi-Fi off, two hidden friends reconnecting while a
  third device cannot identify them, prompts, sleep and wake.

## Corrections

Recorded on 2026-10-12 after the M1 build wave, where the helper's nearby orchestration settled what this record
left open (`service/helper/nearby/`).

- **Probing for a friend whose tags we cannot match.** When the helper owes a delivery to a person whose tags it
  cannot match (it lacks their rotated presence secret, or they are a removed person waiting for our answer), it
  dials IK at each unrecognised device, at most once per device per window. A wrong device cannot decrypt IK's
  first message and learns nothing; the right one accepts a key it knows.
- **Removed and blocked keys are refused at IK**, on message 1 before any reply, like unknown keys; a blocked key is
  also dropped after the uniform RECEIVED of an NN request, and refused before message 3 when we browse its
  public entry.

## Review amendments

Recorded on 2026-10-12 from the independent security review of the M1 build. Each amends the decision above and
names the finding it answers; `service/discovery/SZFriendsDiscovery.h` and `service/helper/nearby/` hold the
numbers.

1. **Answers to Add by ID.** At most three distinct keys may answer one request; each becomes its own unverified
   person with its own conversation and is never merged into another or into an existing row matched by Friends ID.
   A session admitted by the token alone carries friendship creation only, until the person accepts. The holder's
   callback dials the static key REQUEST_BY_ID named (finding: Add by ID request token).
2. **Callback tags.** Callback tags go on the air only for the first hours after each broadcast that carried
   their secret, and a pending request draws a fresh callback secret every day and broadcasts again with the same
   token, so a device that heard yesterday's secret cannot recognise the requester today. Every advertisement
   carries exactly four callback slots, the real tags padded with random 8-byte values kept for the window, in
   the TXT record and the characteristic alike, so their number says nothing about how many requests are pending
   (finding: callback tags).
3. **Listener rotation.** At every window boundary the hidden entry moves to a fresh listener port and a freshly
   published L2CAP PSM, and Bluetooth restarts its advertising; the old listener stays a short while for
   connections already on their way. Only the hostname and address above remain linkable (finding: presence
   linkability).
4. **Presence secret rotation.** Remove and block settle every pending outbox entry of that conversation as
   refused, and PRESENCE_SECRET goes only to someone who is a friend at the moment it is sent, so an entry queued
   before the rotation can never hand the removed person the new secret (finding: rotation).
5. **Relayed tags.** A failed IK to an endpoint backs the dial off per endpoint, so a relayed tag draws each friend's
   dial rarely rather than continuously (finding: presence tag relay).
6. **Stranger pictures.** A picture from a public entry's XX message 2 passes the avatars area's received-image
   checks before ImageIO sees it (finding: stranger pictures).

Recorded on 2026-10-13 from the wave-3 security re-check, which found these residuals in the amendments above and
in this wave's code. `service/discovery/SZFriendsDiscovery.h`, `service/helper/nearby/SZFriendsNearbyLimits.h` and
`service/store/SZFriendsStore.h` hold the numbers.

7. **The Bluetooth public entry stands apart.** While visible, the public entry is served from a characteristic
   value of its own (its own UUID) that carries only the public PSM, never the hidden tag, the callback slots or the
   hidden PSM, and each presence window publishes a fresh public L2CAP channel, the old one staying a short overlap
   for readers already dialing it. The public UUID goes on the air only while a channel exists to dial, and the
   deadline withdraws every public channel at once, an overlapping one included. Before this, one value carried the
   hidden tag beside both PSMs and the public PSM survived the window boundary, so anyone who read it during the
   five visible minutes could tie the person's public name and picture to their hidden tag, and one window's tag to
   the next (finding: presence linkability, Bluetooth).
8. **Pending requests open the hidden listener briefly.** Someone whose friend request waits for our answer may open
   IK to our hidden listener only within six hours of when that request began; asking again does not move the start,
   and our own answer travels over the IK we dial, so nothing later needs theirs. An incoming request nobody answers
   lapses after 14 days. An outgoing request keeps IK open while it waits, because the answer arrives that way, and
   an Add by ID request lapses after 7 days; a removed person gets IK only by presenting the token of an unexpired Add
   by ID of ours that admits their key. Without the bound, one request sent during our five visible minutes taught
   the sender our static key, and IK answered by our listener alone let them find our device in every window for as
   long as we left the request unanswered (finding: tracking by anyone who sent a request).
9. **Attested answers to Add by ID.** The holder of a Friends ID presents its newest host attestation (ADR 0005,
   Review amendments, 4) beside its certificate in the IK callback, never in NN, which names nobody. The requester
   believes it only when it verifies against the key the signed host list gives that host, covers the identity key
   of the session and the Friends ID that was asked for, and is at most 30 days old (one day ahead for clock skew);
   the person's ID is then marked confirmed (PROTOCOL.md, `id_confirmed`). Of the three keys a token admits, at most
   two may answer without one, so throwaway keys cannot use up every answer and lock out the real holder. A
   confirmed ID says the host reserved it for that key, not who is at the keyboard: comparing codes still decides
   `verified` (finding: Add by ID request token, the part the first review left open).
10. **Admission keeps friends in.** Per-address limits count an IPv6 /64 as one address, and a full listener or
   address closes its oldest connection that has not authenticated instead of refusing the newcomer. A connection
   that has not delivered a complete message 1 two seconds after accept is closed, and a connection stops counting as
   soon as the responder knows who the initiator is. Sessions with people who are not friends reset their idle timer
   only on frames that move their request forward, end three minutes after going live whatever they carry, and give
   way to a newcomer oldest-idle first when their cap is full (findings: admission lockout, idle limits).

Recorded on 2026-10-13 from the wave-4 security re-check, which found these residuals in amendments 1, 8 and 9 and
in that wave's code. Amendment 8's sentence that an outgoing request keeps IK open "while it waits" is corrected by
12: nothing lapsed outgoing requests, so their keys stayed open for good.

11. **An unattested acceptance is a request.** An ACCEPT that arrives on the IK callback answering our Add by ID,
   from a key whose answer showed no valid host attestation and whose ID no host confirmed, no longer makes a friend:
   the row becomes an incoming request whose card names the ID we asked for and says the Friends server could not
   confirm it is theirs (PROTOCOL.md § Views, `conversation`). Only the person's Accept makes a friend and queues
   our presence secret. Before this, whoever heard the broadcast could answer under the name of the person we meant,
   become a friend at once and recognise our presence tags from then on (finding: unattested answers become friends).
12. **Requests we sent lapse, and requests by ID never open IK.** IK from the key of an outgoing request is accepted
   only while an answer can still come: seven days from when a request to someone found nearby began, and for an Add
   by ID answer's key while the request that admitted it is unexpired; then the row lapses (deleted when it holds no
   history, else Removed), as incoming requests do, and so does a keyless "Request sent" row whose request expired.
   A friend request that arrived by Friends ID gets no IK window at all: its sender never learned our static key from
   us, so the window served only someone who already had it, renewed by every fresh key they asked from (finding: IK
   open to OutgoingRequest keys; by-ID incoming windows renew).
13. **Add by ID trusts no claimed ID.** A row's Friends ID is whatever that person's PROFILE last said, so it stops a
   new Add by ID only for a friend or a blocked person whose ID a host confirmed (`already_friends`, `blocked`) and
   for our own keyless request while it is still out. Any other row naming the ID, a request in either direction
   included, leaves the request to go out to every device nearby, so the holder's answer reaches us; "Request sent"
   is never said when nothing went out (finding: add_by_id attestation bypass).
14. **Smaller residuals.** NN is admitted at most six times a minute from one address, beside the sixty a minute per
   listener, so one host can no longer keep everyone's Add by ID out. The holder attaches its attestation only to the
   callback that carries ACCEPT, never to one carrying a decline. A responder refuses any handshake message longer
   than 1,024 bytes on its length prefix, before any Diffie-Hellman (ADR 0001, Review amendments), and a token naming
   no request of ours is judged unattested without parsing what it carries (findings: discovery admission residuals,
   attestation on decline, session refusal timing).
