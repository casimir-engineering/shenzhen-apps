# Shenzhen Friends: one profile on several devices

Status: planned 2026-10-13, after the Shenzhen Files host. Owner: lead integrator. Supersedes the brief's
"one identity per Mac" decision. Builds on [shenzhen-friends.md](shenzhen-friends.md) and the ADRs in
`portable/friends/docs/adr/`. Every app on one Mac already shares one helper and one profile; a device here is a
computer, not an app.

## What people get

- On a new computer, Friends offers **Use my existing profile**: type your Friends ID. Every one of your devices
  that is on gets the request at the top of its Friends list ("MacBook Air (macOS 26) wants to join your
  profile", Approve / Deny). Approve on any one of them; it shows an 8-digit code; type that code on the new
  computer. The new computer then has your name, picture, ID, friends and chats.
- Chats, friends, requests, read state, name, picture and settings stay in sync across your devices: directly
  between devices nearby first, then over the Internet.
- **You** is a conversation with yourself: messages and files you put there reach all your devices. Drop a file
  on it to move it to your other computers.
- Profile → **Your devices** lists every device with its name, system (macOS 26.1, Linux…), last connection
  ("Now", "5 min ago", "Yesterday") and **Revoke** (two-click confirm). Revoking removes the device from your
  profile everywhere: it stops syncing, your friends stop accepting it, and it shows "This computer was removed
  from your profile".

## Identity: a device chain

- A person is identified by their **root key**: the Ed25519 identity key of their first device, unchanged from
  today. Friends keep pinning that key; verification codes stay per person.
- Each device has its own Ed25519 device key and X25519 Noise static key. A **device chain** is an append-only,
  hash-linked list of signed links:
  - *genesis*: the root key names the first device;
  - *add*: an authorized device adds a new device (keys, name, system, time);
  - *revoke*: an authorized device removes a device; *rename*: a device updates its own name or system.
- **Rules.** A link is valid only if signed by a device authorized in the chain before it. A revoked device can
  never be re-added and its signatures after its revocation are void. Concurrent branches merge by the union of
  additions and the union of revocations, and **revocation always wins**, so a branch that "keeps" a device cannot
  undo a revocation made on another branch. Known limit, stated in the docs: a stolen, still-authorized device
  can revoke your other devices; revoke it first from any device you hold, and if that fails, Reset Friends.
- No private key is copied between devices. The root key stays on the first device and only signs genesis.
- Friends receive the chain from any of your devices (a CHAIN frame on every session), verify it from the root,
  accept IK and XX sessions from any authorized device, and refuse revoked devices. The comparison code shown to
  friends remains bound to the root.

## Joining

1. The new device makes its device keys, then sends a **join request** (device keys, name, system) to the typed
   Friends ID: nearby by the same NN broadcast as Add by ID, and online through the host, which forwards it to the
   person's connected devices (rate-limited per ID, stored nowhere).
2. Each receiving device shows it as a waiting row with Approve and Deny, and the Friends badge counts it. Join
   requests never auto-approve; Deny is final for that request; at most 3 open requests per ID.
3. On Approve, that device connects to the new device and runs **CPace** (CFRG draft, ristretto255 over libsodium,
   validated against the draft's test vectors) with a fresh 8-digit code it displays, bound to the Noise handshake
   hash. The person types the code on the new device. Three wrong codes or 5 minutes cancel. A plain hash of a
   short code would fall to offline guessing; the PAKE gives one guess per attempt.
4. After CPace confirms, the approving device signs the *add* link and sends the chain and a sync bootstrap. Other
   devices clear the request when the chain reaches them.

## Sync

- **Event log.** Every change is an event signed by the device that made it, with that device's sequence number:
  messages in and out, transfer records, read markers, friend changes (requests, accept, remove, block, automatic
  acceptance), name and picture, shared settings, outbox entries and their status, chain links, deletions as
  tombstones.
- **Merging.** Messages and transfers are add-only sets keyed by conversation and message id; read markers take
  the maximum; relation and settings changes are last-writer-wins by Lamport clock then device id; tombstones
  win over the items they delete. Applying an event twice changes nothing.
- **Transport.** Own devices find each other with an own-devices presence secret (separate from friends' secret)
  and connect with IK using each other's chain keys. Anti-entropy exchanges version vectors and missing events, in
  order. Nearby routes first; online through the host's rendezvous, direct connection and last-resort relay.
- **Friends.** A friend delivers to whichever of your devices it reaches; that device acknowledges after its
  commit and syncs the message to the others. Any of your devices may deliver a queued message to a friend
  (message ids make duplicates harmless), so a message written on a laptop that went to sleep still leaves from
  the desktop.
- **Files.** Transfer records sync at once. File bodies up to 25 MB copy to your other devices automatically;
  larger ones show "On MacBook Pro · Get" and copy when asked. Files in **You** copy to every device regardless of
  size, since moving them is the point.

## Host

- Check-in uses the device key with the chain as proof of membership; the Friends ID belongs to the root. The host
  forwards join requests and own-device rendezvous; it stores no request.
- Statistics count people (roots) and devices separately: unique people, devices per person, joins and
  revocations per day.

## Verification

- Chain: forged, out-of-order, revoked-signer and forked chains; revocation-wins merges; re-adding a revoked device
  refused; friends refusing revoked devices.
- Joining: CPace against the draft vectors; wrong code, expired code, three attempts, MITM between new and old
  device fails; spam limits; no auto-approval.
- Sync: three devices with partitions and concurrent edits converge to identical stores (property tests over random
  event orders); tombstones; duplicate delivery; outbox delivery from a sibling; files auto-copy limits and You.
- Two-device and three-device e2e scenarios in the harness on loopback; the hardware matrix adds real Macs.
- UI: join request rows, code entry, device list with last connection and Revoke, You conversation, revoked
  device screen; independent security review and UX critique.
