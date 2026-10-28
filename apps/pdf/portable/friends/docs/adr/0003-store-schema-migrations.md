# ADR 0003: Store schema and migrations

Status: Accepted by lead; owner review pending. Date: 2026-10-12.
Brief: § Storage, § Outbox and delivery, § Transfers, release gate "Search". Areas: store (owner), helper,
presentation.

## Context

The helper needs friends, history, outbox and transfer state that survive `kill -9` and power loss, can be
searched in Chinese and English without the network, and stay private to the helper. M0 asks whether macOS
12's system SQLite has FTS5 with the trigram tokenizer.

## Decision

**System SQLite, one file, one owner.** `friends.sqlite` in the state directory (0600 inside 0700), linked
with `-lsqlite3`, so it costs no binary size. Only the helper opens it: one write connection on one serial
queue (the single writer) and one read-only connection for search and snapshots. Clients, views, host
adapters and Shenzhen Files ask the helper.

**Pragmas at every open:** `journal_mode=WAL`, `synchronous=FULL`, `fullfsync=ON`, `checkpoint_fullfsync=ON`,
`foreign_keys=ON`, `busy_timeout=5000`, `trusted_schema=OFF`. On macOS a plain `fsync` can leave data in the
drive's cache; FULL with `F_FULLFSYNC` is what makes a durable ACK (ADR 0001) true after a power cut.
Messages are few, so the per-commit cost is acceptable; transfer progress is batched (below).

**FTS probe.** At open the helper creates `temp.probe USING fts5(x, tokenize='trigram')` and fills it from a temp
trigger. If that fails (SQLite before 3.34.0 has no trigram; before 3.44, macOS 15 and earlier, FTS5 is not
innocuous, so `trusted_schema=OFF` refuses it inside a trigger), search runs on the substring scan alone: slower,
never wrong, logged once.
The M0 check on macOS 12 decides whether the helper vendors the amalgamation; that is a deps change with no
schema change. No trigram options newer than the macOS 12 library (such as `remove_diacritics`).

**Schema v1.** Columns abbreviated; the store area owns the exact DDL.

- `meta`: `min_reader_version`, store id, creation time.
- `profile` (one row): name friends see, picture (animal set version and index, or own-picture file),
  Friends ID, reserved flag, previous ID for the rename notice.
- `friends`: `identity_pk` UNIQUE, `static_pk`, last known Friends ID, name, picture, state (request in,
  request out, friend, blocked, removed), verified, comparison code, `auto_accept` (default 0), their
  presence secret, last interaction, unread count.
- `messages`: friend, `msg_id` BLOB(16), direction, kind (text, link, request, offer, transfer event), body,
  folded body for search, sender and receive times, delivery state; UNIQUE(friend, direction, `msg_id`).
- `outbox`: pending sends (message, request or offer), state Queued / Connecting / Sending / Delivered /
  Failed, attempts, next attempt.
- `transfers`: `offer_id` PRIMARY KEY, friend, direction, name, type, size, digest, state, durable bytes,
  source binding, staging and final paths.
- `id_requests`: pending Add by ID: target ID, request token, callback secret, expiry (ADR 0004).
- `settings`: helper-wide values: own presence secret, visibility deadline, Nearby-permission-asked flag.
- `search`: FTS5 external-content table over folded message bodies and transfer names,
  `tokenize='trigram'`, kept in step by triggers.

Keys never live here; the identity key store does (Keychain, or a file key store under
`SZFRIENDS_STATE_DIR` in tests). Files: `received/` with staging in `received/.partial/`, `outgoing/` for the
immutable snapshots of files being sent, `pictures/`, and the host-list cache `hosts.json`, all in the state
directory.

**Search.** Same semantics as ShenzhenPDF's Cmd+K palette: case- and diacritic-insensitive, every
whitespace-separated term must occur in any order, exact-phrase hits rank first, then newest. The helper
stores a folded copy of each body (Foundation's case and diacritic folding) and folds queries the same way,
so matching does not depend on the SQLite version. Terms of three or more characters go through the trigram
index as quoted phrases. One- and two-character terms (合同, 合) filter those candidates with `instr()`;
when every term is short, the helper scans messages newest first up to the result limit. Chat volumes are
small, so the scan fits the 100 ms feedback budget.

**Migrations.** `PRAGMA user_version` is the schema version. Migrations are an ordered list in code,
forward-only, each in one `BEGIN IMMEDIATE` transaction with its version bump; a shipped migration is never
edited. Before migrating, the helper writes `VACUUM INTO 'friends.sqlite.before-v<N>'` and keeps only the
latest copy. Additive changes (new tables, new columns with defaults) leave `min_reader_version` alone, so an
older helper, such as an older Shenzhen Files, still opens the store. A change older code would misread
raises it; a helper older than `min_reader_version` reports "needs update" to its clients and does not open
the store (ADR 0002).

**Crash recovery.** WAL rolls back incomplete transactions. At start the helper also returns outbox items in
Connecting or Sending to Queued; pauses inbound transfers at their durable byte count and truncates staging
files to it; finishes publishing (the final path is recorded in state "publishing" before the rename, so a
final file without its staging file is marked received and a staging file still present is renamed again);
and deletes staging files that no row references.

**Durable progress.** Inbound chunks are written, the staging file gets `F_FULLFSYNC`, and only then is the
new durable byte count committed, batched every 4 MiB or 1 s. PROGRESS reports only committed counts, so the
database never claims bytes the disk could lose.

**Deletes.** Delete history removes messages, transfer records and index rows, then runs `VACUUM` and a
truncating checkpoint so removed text does not survive in free pages or the WAL. Files already in
`received/` stay: they are documents the person may have opened or imported, and the Settings text promises
it ("Files you received stay in Received files"). Delete identity (Reset Friends) removes the key-store item
and everything in the state directory except `received/`, after the host release (ADR 0005).

**What lives where.** ShenzhenPDF's `settings.yaml` holds only `friends.enabled` (Shenzhen Files has its own
equivalent): whether that app shows Friends and starts the helper. Everything the two apps share lives in the
store, so both see one state: name, picture, friends, history, automatic acceptance, the Nearby-permission
flag, the visibility deadline. No secrets in YAML or logs. History is not encrypted in the database;
FileVault protects it at rest (brief).

## Alternatives considered

- **Core Data**: Apple-only, opaque migrations, no FTS5, unusable by a later Linux service.
- **Vendoring SQLite now**: about 1.5 MB and an upgrade duty, for nothing if macOS 12's library passes M0.
- **SQLCipher**: FileVault already covers the disk; the brief rules out another layer.
- **`synchronous=NORMAL`**: faster, but a power cut can drop a transaction we already acknowledged.
- **FTS5 `unicode61`**: does not segment Chinese, so 合同 would not match inside a sentence.

## Consequences

- Each commit pays an `F_FULLFSYNC` of a few milliseconds; measure on reference hardware.
- Older helpers survive additive migrations; breaking ones require the newer app.
- Short terms are a scan; revisit if their p95 crosses 100 ms on the largest test dataset.

## Verification

- Migration suite: committed fixture databases for every shipped version (generated by a script) migrate to
  the current schema; a failed migration leaves the original and its backup intact.
- `kill -9` the helper during a message insert, mid-transfer, between rename and commit, and mid-migration:
  on restart no acknowledged message is missing or duplicated, durable bytes never exceed the staging file,
  and published files match their digest.
- Search: messages and transfer names survive restart; 合同 and 合 find the right messages; mixed queries
  such as "合同 report"; case-insensitive Latin; a result opens the exact message; dataset size and p95
  reported. A forced probe failure exercises the scan-only path.
- Source-contract test: nothing outside `friends/service/` mentions `sqlite3` or `friends.sqlite`.
- After Delete history, a byte search of the database and WAL files finds none of the deleted text.

## Corrections

Recorded on 2026-10-12 after the M1 build wave; the store area's schema (`SZFriendsStoreSchema.m`) and search
(`SZFriendsStoreSearch.m`) are the reference.

- **Message uniqueness is `UNIQUE(conversation_id, item_id)`**, not `UNIQUE(friend, direction, msg_id)`. A
  conversation belongs to one identity key, so incoming rows still deduplicate by sender key and id, and an id
  then names exactly one item, which search results, citations and `retry_item` rely on. Ids are 128 random bits
  chosen by their sender, so an honest incoming id never meets one of ours.
- **The FTS index is created at open, not by a migration.** The `search` table is not part of schema v1's
  versioned DDL. Each time the helper opens the store it creates the table if the trigram tokenizer exists, and
  keeps it in step with temporary triggers on its own connection, so a helper without trigram never fires a
  trigger that would fail on every insert. Writes made without the index mark it stale, and the next helper with
  trigram rebuilds it before trusting it. Vendoring SQLite later therefore still needs no schema change.
- **Schema v4** (recorded 2026-10-13). `messages.via_assistant` marks a message or file the assistant sent for either
  person (an event never carries it), and `friends.unconfirmed_answer_id` keeps the Friends ID an Add by ID asked
  for on a row whose answer no host confirmed and which waits for the person's acceptance as an incoming request
  (ADR 0004, Review amendments, 11). Reads return that ID only while the row is an incoming request, so any other
  relation, even one a v3 helper wrote, voids it. The migration is additive and keeps `min_reader_version` at 2.
  The same change lets requests we sent lapse (`-expireOutgoingRequestsAtDate:`; ADR 0004, Review amendments, 12).
- **Schema v5** (recorded 2026-10-13). `messages.cancelled` marks an outgoing message the person withdrew while it
  was still queued or connecting (PROTOCOL.md `cancel_message`). The outbox entry that would have delivered it is
  deleted in the same transaction, so nothing can send it afterwards, and the history keeps the message, which
  says Cancelled. The migration is additive and keeps `min_reader_version` at 2: a v4 helper shows such a message
  without a status, as any outgoing message with no delivery record, and never sends it.
- **Schema v6** (recorded 2026-10-13, wave 6a; ADR 0008). `transfer_thumbnails` holds one file preview per transfer:
  its source (the sender's picture, or one made on this Mac), its size, the path of a PNG in `<state>/thumbnails/` and,
  on the sending side, the QOI that still has to reach the friend (dropped once acknowledged). Rows cascade with their
  transfers. PNG names are random and chosen by this Mac, never derived from the sender's transfer id. Previews are
  deleted in the store's one state-change function, in the same transaction: when a transfer is declined or cancelled,
  or fails from queued, offered or waiting for you; the file is unlinked at once, and a row that a rollback brings back
  naming a missing file shows as no preview. Delete history removes previews with their transfers, Reset Friends
  removes `thumbnails/`, and at start the helper deletes files there that no row names. The migration is additive and
  keeps `min_reader_version` at 2: an older helper ignores the table, and the files its deletes leave behind go at the
  next sweep.
- **Search reads mentions as their labels** (recorded 2026-10-13, wave 6b; ADR 0007). A message's `folded` copy is the
  text a reader sees: each Friends link replaced by the words it shows (a mention's "@Name" as its sender wrote it,
  unescaped), never its destination, so the index holds no mention's Friends ID, key or scheme. Match ranges are found
  in that text and given back as ranges of the stored text, a match in a mention covering its label, so every hit has a
  match a view can show and a page of results is never cut short by hits the presentation drops. File names are folded
  as they are. Rows folded before this are refolded once when the store opens (`meta.search_fold`), the index kept in
  step through its triggers, or rebuilt when it was stale anyway. No schema change.
- **Schema v8, device chains** (recorded 2026-10-14; ADR 0012). `device_chains` holds one verified chain per root key,
  this person's marked `own`, as its canonical encoding; `chain_devices` indexes every device of every chain by key
  (root, static key, name, system, state, when added and revoked, last connection), and a device key belongs to one
  chain only. A friend's chain is replaced only by a superset of its links, in one transaction with its index.
  `personWithIdentityKey:` also finds a friend from any device their chain authorizes. Reset Friends deletes every
  chain. Additive, so `min_reader_version` stays 2: an older helper ignores both tables.
