# ADR 0016: Getting a file again

Status: Proposed. Date: 2026-10-21.
Builds on ADR 0001 (sessions, transfers), ADR 0014 (sync, files between own devices) and ADR 0015 (the portable core,
which implements the same). Areas: session (the AGAIN frame, session minor 3), sync (who holds a file's bytes), store
(schema v12), helper (`nearby/SZFriendsNearbyService+Again.m`, `service/sync/SZFriendsAgain.m`; core-rs
`sync/again.rs`, helper `service/again.rs`). Client contract: PROTOCOL.md § Getting a file again.

## Context

The owner's words, testing a phone beside a Mac: "I should be able to download any previous file that is available on
a device". A received file the person moves or deletes is gone for good today: its item still says "Saved to
Downloads", Open fails, and the person's other computers still believe this one holds the bytes (ADR 0014 keeps who
holds a file as a union that only grows), so Get there waits forever on a computer that has nothing to give. The
friend who sent it may still have it, but a friend's helper serves a file only once, after an offer and an answer.

## Decision

**Holding is a fact that can stop.** A computer holds a file's bytes when its published copy is where it was saved at
the file's size (received, or copied from another computer), when its outgoing snapshot is there, or when the file
it sent is still at the path it was sent from with the same size and modification time (schema v12 records that path
and time on the outgoing transfer row: `transfers.source_path`, `transfers.source_mtime_ns`; never synced). The FILE
HELD event (kind 9) gains an optional body field, tag 2, u64 1: "the author no longer holds these bytes". Capture
sends it when this computer is listed as a holder and no longer holds them, and FILE HELD without it when it holds
them again. Each author's FILE HELD events apply in that author's order, so the last one decides whether the author
is listed, and every computer ends with the same holders. An older helper ignores the unknown field and keeps the
author listed, which is what it did before: a Get there ends on NONE, as it already did.

**Get after a deletion.** A file whose row is here but whose bytes are not is wanted like a file that was never here,
but only when the person asks (Get): what the person moved or deleted never comes back by itself. The copy is ADR
0014's WANT/PART/NONE; the finished copy is published where received files go and replaces the row's path.

**Again from the friend.** When no computer of the profile holds a file a friend sent, the person may ask that
friend's computer for it (Get again). A new session frame carries it, AGAIN (type 27, session minor 3), one field
AGAIN (tag 36, 1 to 64,000 bytes): one message of a small exchange, the requester's WANT and the sender's PART or
NONE. Integers are big-endian; `id` is the offer id the file was offered under (16 bytes).

    1 WANT   id (16) | offset u64 | parts u16       send these parts of the file offered under id
    2 PART   id (16) | offset u64 | last u8 | bytes at most 48 KiB, in order from offset
    3 NONE   id (16) | reason u8                    0: this computer does not have it; 1: not now

The requester copies one file at a time per session, at most 16 parts requested and not yet arrived, into
`received/.partial/again-<transfer id>` (a later session resumes it), and publishes it only once its whole BLAKE2b
digest matches the digest it was offered with; it stores nothing else of the friend's. NONE 0 ends the request (the
item says the friend no longer has it); NONE 1 leaves it for the next session.

The sender serves without asking anyone, because it already chose to send that file to that person, and only that:

- the session is IK or XX with someone in its list as a friend (not blocked, not removed), who is the person the
  transfer was offered to: the transfer row is outgoing, in that person's conversation, and was delivered. The
  person's other devices reach the same conversation through their chain (ADR 0012), so any of them may ask;
- it serves from its own bytes only: the outgoing snapshot, a copy of it, or the file at the path it was sent from,
  unchanged since (size and modification time), and only after the whole file's digest matches the one it offered.
  A changed file is a file it does not have (NONE 0);
- when its profile's records say another of its own computers holds the bytes, it answers NONE 1, so the requester
  waits for that computer rather than hearing "doesn't have it";
- a session copies one file at a time: a WANT for another file within 60 s of the last WANT for an unfinished one is
  NONE 1; at most 20 digest checks per person per hour (a file checked once is not checked again while it stays
  unchanged), beyond which it is NONE 1; at most 16 parts per WANT. An id that is not such a transfer, of any kind, is
  NONE 0, so the friend learns nothing about other files.

A helper sends AGAIN only on a session whose negotiated minor is 3 or more (an older one closes on an unknown type), and
ignores it on a session with its own devices (they copy over SYNC) or with anyone not in its list as a friend.

## Alternatives considered

- **Offering the file again** (OFFER with the same id, answered at once): it reuses the transfer machinery but moves the
  sender's row back through Sending, shows the friend a transfer they did not start, needs the snapshot the sender
  deleted on delivery, and both state machines would gain a backwards edge. The sync copy already does exactly this
  job without touching either row.
- **Reusing SYNC between friends**: SYNC is between one person's devices only, which the helper checks on every frame;
  mixing the two would put that rule at the mercy of the message type.
- **Keeping every sent snapshot**: doubles the disk space of everything ever sent, for a request that may never come.
- **A new sync event kind for "released"**: an older helper refuses unknown kinds and the whole sync session closes;
  a field it ignores degrades to today's behaviour.

## Consequences

- A friend who moved, edited or deleted a file they sent cannot give it again; the item says so ("Mei Lin doesn’t have
  this file anymore.") and the person asks them to send it.
- Files sent before schema v12 have no source path: once delivered, only a copy on one of the sender's computers serves
  them.
- A friend whose helper predates minor 3 never answers: the item waits ("Copies when Mei Lin is nearby…").
- The sender reads a whole file to check its digest before serving it; the per-person limit bounds that work.

## Verification

`friends-sync-check`: FILE HELD with and without the field in both orders, capture of a deleted copy, Get after a
deletion, no automatic copy of what the person deleted. `friends-session-check`: AGAIN's bounds, minor 3.
`friends-helper-check`: `fetch_from_friend` and its errors, the sender's rules (another person's file, a changed
file, a deleted one, limits), a copy resumed. `friends-presentation-check` and the core's `presentation_devices`:
`devices-conversation-mei-again.json` built from facts. `friends-core-rs-interop-check`: Get again between the
Objective-C helper and the Rust helper both ways, and a computer that deleted a file getting it from the person's other
computer both ways.
