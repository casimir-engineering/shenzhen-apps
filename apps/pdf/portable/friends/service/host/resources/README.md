# Host resources the helper bundles

`FRIENDS_HOST_RESOURCES` in `../host.mk` lists these for the helper bundle's Resources.

| File | What |
|---|---|
| `pinned-keys.json` | The host-list signing keys the helper pins: primary and backup public keys (ADR 0005) |
| `bootstrap-hosts.json` | The signed list the helper starts from and never goes below: `wss://friends.meerkat.orgabots.com/v1` |

**Both are TEST material.** The keys were generated on 2026-10-12 for development and their private halves were
deleted, so nobody can sign a list these keys accept; the bundled list names a TEST host key for `main-hk`.
`make -C portable friends-host-release-check` fails while any pinned key is marked as a test key or appears in the
test vectors, and while the bundled list does not verify with the pinned keys.

**For the lead, before any release:** generate the production primary and backup keys on the admin's Mac, write
this `pinned-keys.json` with `friends-hostlist pinned-file`, and re-sign `bootstrap-hosts.json` with the production
primary key and the real `main-hk` host key, as `../../../../server/friends/deploy/DEPLOY.md` steps 1 to 3 describe.
The helper's suite then checks that the new bundled list verifies with the new keys. The helper believes a
reservation answer only when the host signed it with the key the list names for that host, so a bundled list that
names any key other than the running `main-hk`'s means no app reserves an ID until a newer list arrives.
