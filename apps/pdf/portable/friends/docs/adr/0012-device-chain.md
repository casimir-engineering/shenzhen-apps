# ADR 0012: Device chain

Status: Accepted (lead integrator, 2026-10-15). Date: 2026-10-14.
Plan: [friends-multi-device.md](../../../docs/plans/friends-multi-device.md) § Identity. Areas: identity (owner of the
chain), session (the CHAIN frame), store (schema v8), helper (sessions and the key policy). Interfaces:
`service/identity/SZFriendsDeviceChain.h`, `service/store/SZFriendsStoreDevices.h`, `SZFriendsFrameTypeChain` in
`service/session/SZFriendsSession.h`.

## Context

One person now uses Friends on several computers. Friends pin a person by one Ed25519 identity key (ADR 0001 § Keys;
Review amendment 6: one identity key per conversation), comparison codes and QR codes are bound to it, and the
host's ID belongs to it. No private key may be copied between computers. So the person needs a public statement,
verifiable by any friend from the key they pinned, of which other keys speak for them; one that grows when a device
joins, shrinks when one is revoked, and still agrees with itself when two devices change it while apart.

## Decision

**Keys.** The person's **root key** is the identity key of their first device, unchanged. Every device has its own
`SZFriendsIdentity`: an Ed25519 **device key** and an X25519 Noise static key, in its own key store, never copied.
On the first device the device key is the root key itself: the existing identity simply becomes device one. WHY:
every friendship, stored static key, certificate and comparison code of an existing profile stays valid, and a
friend whose helper predates this change keeps talking to the first device as before. (The plan's "the root key only
signs genesis" is amended accordingly: as the first device's key it also signs that device's links.) A joining device
generates its identity as any new install does and learns its root from the chain it is given.

**Links.** The chain is a set of signed links, each naming by hash the links its signer had seen (its parents, up to
8), so concurrent changes form a graph rather than a conflict:

| Kind | Signed by | Carries |
|---|---|---|
| genesis | the root, about itself | its static key, name, system, its consent |
| add | an authorized device | the new device's key, static key, name, system, and the new device's **consent** |
| revoke | an authorized device | the device removed (itself allowed) |
| rename | the device itself | its new name and system |

Format, all integers big-endian: `version u8 (1) | kind u8 | milliseconds u64 | parent count u8 | parents (32 each) |
signer (32) | subject (32)`, then for genesis and add `static key (32) | name length u8 | name | system length u8 |
system | consent (64)`, for rename the two labels, then the signer's Ed25519 signature over `root key || every byte
before it`, domain `"SZFriends chain link v1"`. Binding the root key means a link cannot be replayed into another
person's chain. The **consent** is the new device's own signature, domain `"SZFriends device consent v1"`, over
`root key || device key || static key`: nobody can put someone else's device in their chain, and a device's static key
is bound to its device key by the device itself. A link's hash is BLAKE2b-256(`"SZFriends chain hash v1"` || link).
Labels are 1 to 64 bytes of UTF-8 without control characters; the clock is the signer's and never decides anything
but which of two concurrent renames shows. A chain encodes as `version u8 (1) | count u16 | (length u16 | link)*`,
parents first, ties by hash, so two devices holding the same links hold the same bytes.

**Limits.** At most 128 links and 64,000 encoded bytes, so one chain fits one CHAIN frame. Renames stop at 112 links,
so adds and revocations always have room.

**What is refused outright** (the whole chain, never part of it): a bad length, version, label or order; a link
before its parent or a missing parent; a repeated link; a second genesis (a fork of the person); a signature or a
consent that does not verify; a link whose signer was never added among the links it saw; a revocation of a device
never added; an add of a device revoked among the links it saw (**a revoked device is never added again**; builders
also refuse to add any device a chain ever revoked); one device key with two static keys.

**Which links count** (`SZFriendsDeviceChainRules.m`), as a pure function of the set of links, so merging is a set
union and every holder of the same links computes the same devices:

1. A revocation *r* of device X is void when a concurrent revocation *r'* (one that did not see *r*) removed *r*'s
   signer, unless *r'* was signed by X itself, or by a device added through X by adds *r* did not see. So two devices
   revoking each other are both revoked (**revocation wins**); a revoked device cannot undo its own revocation, alone
   or through a device it added behind the revoker's back; and a device that was revoked cannot, by pretending not to
   have seen its revocation, take a third device with it.
2. Starting from every revocation not void by 1, an add or rename counts when its signer had an add that counts among
   the links it saw (the first device has its genesis), and no remaining revocation of its signer missed it: what a
   device signs that a revocation of it did not see is void, **and so is everything that rested on it**: devices it
   added that way and what they signed. A revocation whose signer had no counting add among the links it saw, or had
   been revoked there, is dropped, and 2 runs again. Revocations only ever drop, so this ends.
3. Revoked: the subjects of the remaining revocations. Authorized: the subjects of adds that count, unless revoked.
   A device added only by void links is **void**: not authorized, and it may be added again.

**Friends.** CHAIN is session frame 24 with one field, Chain (tag 33, 3 to 64,000 bytes), in session **minor 2**
(`SZFriendsSessionMinor`). A helper sends its chain once on every XX and IK session with a friend that negotiated
minor 2, as soon as the session is live (`-sendChainOnLink:`); NN never carries it and strangers never get it, since
it names the person's computers. The receiver keeps a friend's chain only when it verifies from the root key it
pinned for that friend and holds the genesis it kept before (`-mergeDeviceChainData:forRootKey:`); a chain that does
not, or forks it, ends that session. Kept chains only grow. From then on the store finds the friend from any device
their chain authorizes (`-personWithIdentityKey:`), so IK from those devices passes the key policy exactly as the first
device's does, and such a device's handshake must use the static key the chain gives it (a different one ends the
session; it is not a key change for review). A revoked device is refused by the key policy before any reply and closed
when a session with it goes live in either direction, including a revoked first device, whose key is still the
person's identity key. A chain that revokes the very device that sent it ends that session. One exception, our own
removed computers (amended after review): IK from one completes, and the session carries our chain alone and closes,
so a computer removed while away learns it was removed; our devices also look for it by the tags it still advertises,
under the own-devices secret and the ones that replaced it since (ADR 0014), and dial it to tell it the same way. What
it learns is a chain it verifies itself; nothing else reaches it. Comparison codes and QR
codes stay bound to the root: they are stored per person, never per device.

**Own chain and migration.** The store keeps this person's chain beside friends' (schema v8: `device_chains`, one
row per root with `own` marking ours; `chain_devices`, every device by key with its state and last connection). An
existing single-device profile gets its chain the first time one is needed (a session going live with a friend, or
Your devices), never at launch: a genesis signed by its identity, with this Mac's computer name and "macOS 26.1"
(`-ownDeviceChainCreatingGenesisWithIdentity:error:`). Reset Friends deletes every chain with the people.

**For the join and sync areas** (internal API; all helper-only):

- Join, new device: `SZFriendsDeviceConsent(identity, rootKey)` once the root is known (from the approving device in
  the CPace session); after CPace, `+[SZFriendsDeviceChain chainWithData:expectedRootKey:nil error:]` on the chain it
  receives, then `-[SZFriendsStore adoptOwnDeviceChain:localDeviceKey:error:]`.
- Join, approving device: `-[SZFriendsDeviceChain chainByAddingDeviceKey:staticKey:consent:name:system:signedBy:
  date:error:]` on `-ownDeviceChain`, then `-mergeOwnDeviceChain:error:`, then send `encodedData`.
- Sync: `-mergeOwnDeviceChain:error:` for a chain from an own device (CHAIN on own-device sessions, before anything
  else); `-rootKeyForDeviceKey:` tells an own device (our root) from a friend's; `-staticKeyForDeviceKey:ofRootKey:`
  gives the static key to dial a device with IK; `-noteDeviceKey:seenAtDate:error:` and `-devicesOfRootKey:` feed
  Your devices; `-chainByRevokingDeviceKey:signedBy:date:error:` and `-chainByRenamingTo:system:signedBy:date:error:`
  build Revoke and a changed system; `-[SZFriendsDeviceChain revokesDeviceKey:]` on our own key is "This computer was
  removed from your profile".

## Alternatives considered

- **Copy the identity key to every device.** No chain at all, but the plan forbids it: one stolen laptop is the whole
  person forever, and nothing can be revoked.
- **Certificates signed by the root only.** Simple, but adding or revoking a device needs the first device, on and in
  reach; a lost first device would freeze the profile.
- **A linear chain with one writer at a time** (Keybase's sigchain). Two devices changing it while apart conflict and
  one change must lose; we would need a coordinator our host must not be.
- **Last writer wins by timestamp.** A thief sets their clock; revocation could be undone by a later "add".
- **Matrix-style cross-signing with a master key kept offline.** Strong, but asks people to keep a recovery key, which
  Friends has never asked of anyone.

## Consequences

- Known limit, stated in the plan: a stolen device that is still authorized can revoke your other devices until its
  revocation reaches it. Once revoked, the most it can do is revoke, on a branch that never saw its revocation, the
  devices that revoked it (rule 1): revoke it from one device and the others stay. If even that fails, Reset Friends.
- A revocation made by a device that had not yet seen something the revoked device added voids that addition too
  (rule 2): the honest added device must be added again, so devices should exchange chains before one signs a
  revocation (sync area).
- Whoever holds the first device holds the root key and could start a second genesis. Friends refuse it once they
  hold the first (forks never merge), which is why every session with a friend carries the chain from this release on;
  a friend who never received a chain would pin whichever reached them first.
- A new device can reach a friend only after a chain carrying it has reached that friend from any of the person's
  devices: IK message 1 cannot carry a chain (responders read at most 1,024 bytes of it, ADR 0001 amendment 8).
  Likewise friends learn of a revocation at their next session with any of the person's devices.
- A friend whose helper predates minor 2 knows only the first device; the person's other devices cannot open IK to
  them. Messages for such friends leave from the first device (sync area: outbox delivery from a sibling).
- Friends learn the names and systems of each other's computers, because what they verify must be signed; no view
  shows them.
- 128 links bound a chain's life. With renames capped at 112, a person can still add and revoke for years; a future
  record may compact a chain into a new genesis signed by an authorized device, which friends accept by its signer.
- **First contact from a device other than the first** (amended on acceptance). Such a device sends our chain before
  its REQUEST, and before its answer to an Add by ID, on minor 2 sessions (`-sendFirstContactChainOnLink:`); the first
  device sends none (it is the person). The receiver keeps a chain that verifies from its own genesis, names the
  session's device with the static key the handshake used, and is not that device's own; the request then makes a
  person keyed by the root, with the first device's static key, and the chain is stored as theirs. A row an Add by ID
  answer made under the device's key moves to the root when the chain arrives (`-rekeyConversation:fromDeviceKey:
  toChain:error:`), never a friend's or a verified one. The host attests a Friends ID for the root, so only the device
  that is the root shows the attestation; another device answers unattested, and the requester accepts it as a request.
  Friends' other devices are dialed nearby and online with `-staticKeyForDeviceKey:ofRootKey:`.
- The host reads chains as the helper does, including libsodium's refusals that Node's verify lacks: a public key or
  signature point of small order, and a key that is not canonical (`src/device-chain.js`), so the host never accepts
  a consent nobody made in a chain every helper refuses.

## Verification

- `friends-identity-check`: `SZFriendsDeviceChainTests` (genesis from an existing identity, add, revoke, rename (one
  that saw the label it replaces shows whatever the clocks, as § Links says; amended on acceptance), every
  single-byte change refused, an outsider's link, a claimed device, out-of-order, missing-parent and forked chains,
  revoked signers on a concurrent branch and what rests on them, revocation winning a merge, mutual revocations, a
  revoked device's revenge) and `SZFriendsDeviceChainPropertyTests` (120 seeded histories of three partitioned
  replicas: merges commute, associate and are idempotent, revocations by untouched devices win, no device rests on an
  add its revoked signer made unseen, decoding is independent of link order, a changed byte is refused).
- `friends-session-check`: the CHAIN codec, minor negotiation, the largest chain over a live session, NN refusing it.
- `friends-store-check`: v7 to v8, the lazy genesis, friends' chains from the pinned root only and only growing, forks
  and claimed keys refused, the device index behind person lookups, the own chain, adoption, Reset Friends.
- `friends-e2e-devices-check`: a computer removed while it was off learns it once back nearby (scenario 8).
- `friends-helper-check`: chains kept from a friend's session, their other devices admitted by the key policy, static
  keys checked against the chain, forged chains and self-revoking senders ending sessions, a revoked first device
  refused in the key policy and when a dialed session goes live, our own removed computer admitted by IK alone and
  matched by its tags, our chain sent only to friends on minor 2;
  `SZFriendsHelperNearbyFirstContactTests` (a request from a joined computer keyed by the root, a chain not naming its
  sender ignored, an answered row moved to the root, the chain before the request).
- `friends-host-server-check`: small-order keys refused as the helper refuses them.
