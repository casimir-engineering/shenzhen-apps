// Schema v1, its v2 to v11 migrations, and the forward-only migration runner (ADR 0003 § Schema v1, § Migrations).
//
// A shipped migration is never edited: the committed v1 fixture (tests/fixtures/store-v1.sql) must keep migrating
// to the current schema, and an older helper must keep reading whatever an additive migration produced.

#import <sys/stat.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSInteger SZFriendsStoreSchemaVersion = 12;

// Pictures are columns rather than an archived object so a later Linux helper reads them with plain SQL.
// Times are Unix seconds (REAL). Keys and secrets are BLOBs with their lengths checked by the schema itself, so a
// bug elsewhere cannot store a truncated key.
static NSString *const SZFriendsSchemaV1 =
    @"CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;\n"
     "CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, value) WITHOUT ROWID;\n"
     "CREATE TABLE profile (\n"
     "  id INTEGER PRIMARY KEY CHECK (id = 1),\n"
     "  name TEXT,\n"
     "  picture_kind INTEGER NOT NULL DEFAULT 0, picture_set INTEGER NOT NULL DEFAULT 0,\n"
     "  picture_index INTEGER NOT NULL DEFAULT -1, picture_path TEXT, picture_sha256 BLOB,\n"
     "  friends_id TEXT, friends_id_state INTEGER NOT NULL DEFAULT 0, previous_friends_id TEXT,\n"
     "  id_collisions INTEGER NOT NULL DEFAULT 0);\n"
     "CREATE TABLE friends (\n"
     "  conversation_id TEXT PRIMARY KEY NOT NULL,\n"
     "  identity_pk BLOB UNIQUE CHECK (identity_pk IS NULL OR length(identity_pk) = 32),\n"
     "  static_pk BLOB CHECK (static_pk IS NULL OR length(static_pk) = 32),\n"
     "  friends_id TEXT, name TEXT,\n"
     "  picture_kind INTEGER NOT NULL DEFAULT 0, picture_set INTEGER NOT NULL DEFAULT 0,\n"
     "  picture_index INTEGER NOT NULL DEFAULT -1, picture_path TEXT, picture_sha256 BLOB,\n"
     "  relation INTEGER NOT NULL CHECK (relation BETWEEN 0 AND 4),\n"
     "  verified INTEGER NOT NULL DEFAULT 0, verified_at REAL, comparison_code TEXT,\n"
     "  auto_accept INTEGER NOT NULL DEFAULT 0, key_change_pending INTEGER NOT NULL DEFAULT 0,\n"
     "  presence_secret BLOB CHECK (presence_secret IS NULL OR length(presence_secret) = 32),\n"
     "  callback_token BLOB CHECK (callback_token IS NULL OR length(callback_token) = 16),\n"
     "  callback_secret BLOB CHECK (callback_secret IS NULL OR length(callback_secret) = 32),\n"
     "  last_interaction_at REAL NOT NULL, unread_count INTEGER NOT NULL DEFAULT 0,\n"
     "  request_at REAL, request_found_nearby INTEGER NOT NULL DEFAULT 0);\n"
     "CREATE INDEX friends_by_interaction ON friends(last_interaction_at DESC, conversation_id);\n"
     "CREATE TABLE id_requests (\n"
     "  conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,\n"
     "  target_friends_id TEXT NOT NULL,\n"
     "  request_token BLOB NOT NULL UNIQUE CHECK (length(request_token) = 16),\n"
     "  callback_secret BLOB NOT NULL CHECK (length(callback_secret) = 32),\n"
     "  created_at REAL NOT NULL, expires_at REAL NOT NULL);\n"
     // seq is the rowid alias the FTS index points at: an INTEGER PRIMARY KEY survives VACUUM unchanged, where a
     // bare rowid may be renumbered and would desynchronise an external-content index.
     // UNIQUE(conversation_id, item_id) rather than ADR 0003's (friend, direction, msg_id): a conversation is one
     // identity key, so incoming rows still dedupe by sender key and id, and an id then names exactly one item for
     // search results, citations and retry_item. Honest ids are 128 random bits, so the two never collide.
     "CREATE TABLE messages (\n"
     "  seq INTEGER PRIMARY KEY,\n"
     "  conversation_id TEXT NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,\n"
     "  item_id TEXT NOT NULL, kind INTEGER NOT NULL, direction INTEGER NOT NULL,\n"
     "  body TEXT, folded TEXT, transfer_id TEXT, event_kind TEXT, event_args TEXT,\n"
     "  sent_at REAL NOT NULL, received_at REAL NOT NULL,\n"
     "  UNIQUE (conversation_id, item_id));\n"
     "CREATE INDEX messages_by_time ON messages(conversation_id, sent_at, item_id);\n"
     "CREATE TABLE outbox (\n"
     "  entry_id TEXT PRIMARY KEY NOT NULL,\n"
     "  conversation_id TEXT NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,\n"
     "  kind INTEGER NOT NULL, state INTEGER NOT NULL,\n"
     "  created_at REAL NOT NULL, queued_at REAL NOT NULL, updated_at REAL NOT NULL,\n"
     "  attempts INTEGER NOT NULL DEFAULT 0, item_id TEXT, client_token TEXT, failure_reason TEXT, payload BLOB);\n"
     "CREATE INDEX outbox_pending ON outbox(conversation_id, state, created_at);\n"
     "CREATE UNIQUE INDEX outbox_item ON outbox(conversation_id, item_id) WHERE item_id IS NOT NULL;\n"
     "CREATE INDEX outbox_token ON outbox(client_token) WHERE client_token IS NOT NULL;\n"
     "CREATE TABLE transfers (\n"
     "  transfer_id TEXT PRIMARY KEY NOT NULL,\n"
     "  conversation_id TEXT NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,\n"
     "  outgoing INTEGER NOT NULL, state INTEGER NOT NULL CHECK (state BETWEEN 0 AND 9),\n"
     "  file_name TEXT NOT NULL, uniform_type TEXT, size INTEGER NOT NULL CHECK (size >= 0),\n"
     "  digest BLOB NOT NULL CHECK (length(digest) = 32),\n"
     "  verified_bytes INTEGER NOT NULL DEFAULT 0 CHECK (verified_bytes >= 0 AND verified_bytes <= size),\n"
     "  accepted_automatically INTEGER NOT NULL DEFAULT 0, asked_low_disk INTEGER NOT NULL DEFAULT 0,\n"
     "  staged_path TEXT, partial_path TEXT, final_path TEXT, publishing INTEGER NOT NULL DEFAULT 0,\n"
     "  received_path TEXT,\n"
     "  revision_source TEXT, revision_document_id TEXT, revision_id TEXT, revision_label TEXT,\n"
     "  revision_sha256 BLOB, revision_size INTEGER,\n"
     "  bytes_per_second REAL NOT NULL DEFAULT 0, failure_reason TEXT,\n"
     "  created_at REAL NOT NULL, updated_at REAL NOT NULL);\n"
     "CREATE INDEX transfers_by_conversation ON transfers(conversation_id, created_at);\n";

// v2, from the M1 security reviews:
//   - friends.pending_static_pk: a static key a friend presented, certified by their same identity key, kept for the
//     person's review across restarts instead of in the helper's memory (ADR 0001 § Keys);
//   - id_requests.answered_at and id_request_answers: an Add by ID survives its first answer until it expires,
//     admitting at most three distinct keys, so a second holder of an unreserved ID can still answer;
//   - a case-insensitive index on transfer ids, so an incoming offer whose id differs from another only in case is
//     found and refused (APFS folds case; two such transfers once shared one staging file).
// It raises min_reader_version to 2: a v1 helper would read an answered request as still pending and broadcast it
// again, and would save people without regard to the pending key.
static NSString *const SZFriendsSchemaV2 =
    @"ALTER TABLE friends ADD COLUMN pending_static_pk BLOB\n"
     "  CHECK (pending_static_pk IS NULL OR length(pending_static_pk) = 32);\n"
     "ALTER TABLE id_requests ADD COLUMN answered_at REAL;\n"
     "CREATE TABLE id_request_answers (\n"
     "  request_token BLOB NOT NULL REFERENCES id_requests(request_token) ON DELETE CASCADE,\n"
     "  identity_pk BLOB NOT NULL CHECK (length(identity_pk) = 32),\n"
     "  conversation_id TEXT NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,\n"
     "  answered_at REAL NOT NULL,\n"
     "  PRIMARY KEY (request_token, identity_pk)) WITHOUT ROWID;\n"
     "CREATE INDEX id_request_answers_by_conversation ON id_request_answers(conversation_id);\n"
     "CREATE INDEX transfers_by_id_nocase ON transfers(transfer_id COLLATE NOCASE);\n";

// v3, from the wave-3 security re-check:
//   - friends.request_since: when the request now waiting in either direction began, kept while it waits, so a
//     repeated request cannot stretch the helper's IK window for requesters or the 14-day expiry of unanswered
//     incoming requests (request_at is the card's "asked ..." time, which a repeat refreshes);
//   - attested_friends_id, id_attestation, id_attestation_day on friends and on the profile: the host's signed word
//     that an identity key held a Friends ID on a day, theirs (an Add by ID answer shown as confirmed) and ours (what
//     our IK callback presents). A confirmation counts only while attested_friends_id equals friends_id, so any
//     change of the ID voids it, even one written by a helper that predates these columns;
//   - id_request_answers.attested: whether an answer carried such an attestation, so keys without one can be held to
//     fewer of a request's answer slots and the last stays for the holder the host vouches for.
// Additive, so min_reader_version stays 2: a v2 helper ignores these columns, and the worst it can leave behind is
// an older request_since, which only closes the IK window and the expiry earlier.
static NSString *const SZFriendsSchemaV3 =
    @"ALTER TABLE friends ADD COLUMN request_since REAL;\n"
     "ALTER TABLE friends ADD COLUMN attested_friends_id TEXT;\n"
     "ALTER TABLE friends ADD COLUMN id_attestation BLOB\n"
     "  CHECK (id_attestation IS NULL OR length(id_attestation) BETWEEN 1 AND 1024);\n"
     "ALTER TABLE friends ADD COLUMN id_attestation_day TEXT;\n"
     "ALTER TABLE profile ADD COLUMN attested_friends_id TEXT;\n"
     "ALTER TABLE profile ADD COLUMN id_attestation BLOB\n"
     "  CHECK (id_attestation IS NULL OR length(id_attestation) BETWEEN 1 AND 1024);\n"
     "ALTER TABLE profile ADD COLUMN id_attestation_day TEXT;\n"
     "ALTER TABLE id_request_answers ADD COLUMN attested INTEGER NOT NULL DEFAULT 0;\n"
     // Requests already waiting count from when they were asked, or failing that their latest interaction.
     "UPDATE friends SET request_since = coalesce(request_at, last_interaction_at) WHERE relation IN (0, 1);\n";

// v4, from the assistant work and the wave-4 security re-check:
//   - messages.via_assistant: this message or file came via the assistant of one of the two people, so both sides
//     show "Via the assistant" (PROTOCOL.md § Intents, Via the assistant);
//   - friends.unconfirmed_answer_id: the Friends ID our Add by ID asked for, on a row whose answer the host could not
//     confirm and which now waits for the person's acceptance as an incoming request. It counts only while the row is
//     an incoming request, so any other relation, even one an older helper wrote, voids it.
// Additive, so min_reader_version stays 2: a v3 helper ignores both columns.
static NSString *const SZFriendsSchemaV4 =
    @"ALTER TABLE messages ADD COLUMN via_assistant INTEGER NOT NULL DEFAULT 0;\n"
     "ALTER TABLE friends ADD COLUMN unconfirmed_answer_id TEXT;\n";

// v5, from the wave-5 reviews: messages.cancelled, an outgoing message the person withdrew while it was still queued or
// connecting (PROTOCOL.md cancel_message). Its outbox entry is deleted in the same transaction, so nothing can send it
// afterwards, and the conversation says "Cancelled" where it would otherwise say nothing about it.
// Additive, so min_reader_version stays 2: a v4 helper ignores the column and shows such a message without a status,
// as it shows any outgoing message with no delivery record, and never sends it, because its entry is gone.
static NSString *const SZFriendsSchemaV5 = @"ALTER TABLE messages ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0;\n";

// v6, file previews (brief § Transfers, Thumbnails before acceptance; SZFriendsTransferThumbnails.h): one row per
// transfer with a picture, naming its PNG in <state dir>/thumbnails/ by a name this Mac chose, and on the sending side
// the QOI the outbox delivers until the friend's Mac acknowledges it. The row cascades with its transfer, so even an
// older helper's deletes leave no row naming a transfer that is gone (the next helper that knows the table removes
// the file at start). The CHECKs repeat SZFriendsThumbnailMaxSide (192) and SZFriendsThumbnailMaxBytes (64,000).
// Additive, so min_reader_version stays 2: a v5 helper ignores the table, shows no pictures and sends none.
static NSString *const SZFriendsSchemaV6 =
    @"CREATE TABLE transfer_thumbnails (\n"
     "  transfer_id TEXT PRIMARY KEY NOT NULL REFERENCES transfers(transfer_id) ON DELETE CASCADE,\n"
     "  source INTEGER NOT NULL CHECK (source IN (1, 2)),\n"
     "  width INTEGER NOT NULL CHECK (width BETWEEN 1 AND 192),\n"
     "  height INTEGER NOT NULL CHECK (height BETWEEN 1 AND 192),\n"
     "  png_name TEXT NOT NULL CHECK (length(png_name) = 36),\n"
     "  qoi BLOB CHECK (qoi IS NULL OR length(qoi) BETWEEN 23 AND 64000),\n"
     "  delivered INTEGER NOT NULL DEFAULT 0,\n"
     "  created_at REAL NOT NULL) WITHOUT ROWID;\n";

// v7, friend and download links (friends-links.md; SZFriendsStoreLinks.h): each download link this person made, with
// the snapshot it serves (an APFS clone in <state dir>/links/, or the original's size, dates and hashes); the invite
// tokens behind their friend links; the invite one of our own Add by ID requests presents; and the people who are
// in the list only because they sent this person a file through a link. Additive, so min_reader_version stays 2: a
// v6 helper ignores all four, serves no links, and shows such a person as no longer a friend.
static NSString *const SZFriendsSchemaV7 =
    @"CREATE TABLE links (\n"
     "  link_id BLOB PRIMARY KEY NOT NULL CHECK (length(link_id) = 16),\n"
     "  secret BLOB NOT NULL CHECK (length(secret) = 32),\n"
     "  file_name TEXT NOT NULL, uniform_type TEXT, size INTEGER NOT NULL CHECK (size >= 0),\n"
     "  sha256 BLOB NOT NULL CHECK (length(sha256) = 32), blake2b BLOB NOT NULL CHECK (length(blake2b) = 32),\n"
     "  snapshot_path TEXT, source_path TEXT, source_mtime_ns INTEGER, source_ctime_ns INTEGER,\n"
     "  source_inode INTEGER, source_device INTEGER,\n"
     "  thumbnail_png BLOB CHECK (thumbnail_png IS NULL OR length(thumbnail_png) BETWEEN 1 AND 48000),\n"
     "  created_at REAL NOT NULL, expires_at REAL NOT NULL, downloads INTEGER NOT NULL DEFAULT 0,\n"
     "  CHECK ((snapshot_path IS NULL) <> (source_path IS NULL))) WITHOUT ROWID;\n"
     "CREATE TABLE invites (\n"
     "  token BLOB PRIMARY KEY NOT NULL CHECK (length(token) = 16),\n"
     "  one_time INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, expires_at REAL,\n"
     "  used_at REAL, revoked_at REAL) WITHOUT ROWID;\n"
     "CREATE TABLE link_requests (\n"
     "  conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES id_requests(conversation_id) ON DELETE CASCADE,\n"
     "  invite_token BLOB NOT NULL CHECK (length(invite_token) = 16)) WITHOUT ROWID;\n"
     "CREATE TABLE link_contacts (\n"
     "  conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE)\n"
     "  WITHOUT ROWID;\n";

// v8, device chains (ADR 0012; SZFriendsStoreDevices.h): for this person and each friend, the newest verified chain of
// devices that speak for them, kept whole as the canonical encoding the chain's own decoder checks; and an index of
// every device in them, so a session's device key finds its person and a revoked one is refused with one lookup.
// `own` marks this person's chain; a device key belongs to one chain only. The chain rows are not tied to friends rows:
// a friend removed and added again keeps the chain pinned for their root. The existing profile's genesis is written
// when the helper first needs the chain, since signing it needs the identity. Additive, so min_reader_version stays 2:
// a v7 helper ignores both tables, accepts only each friend's first device and sends no chain.
static NSString *const SZFriendsSchemaV8 =
    @"CREATE TABLE device_chains (\n"
     "  root_pk BLOB PRIMARY KEY NOT NULL CHECK (length(root_pk) = 32),\n"
     "  genesis_hash BLOB NOT NULL CHECK (length(genesis_hash) = 32),\n"
     "  chain BLOB NOT NULL CHECK (length(chain) BETWEEN 3 AND 64000),\n"
     "  own INTEGER NOT NULL DEFAULT 0 CHECK (own IN (0, 1)),\n"
     "  updated_at REAL NOT NULL) WITHOUT ROWID;\n"
     "CREATE UNIQUE INDEX device_chains_own ON device_chains(own) WHERE own = 1;\n"
     "CREATE TABLE chain_devices (\n"
     "  device_pk BLOB PRIMARY KEY NOT NULL CHECK (length(device_pk) = 32),\n"
     "  root_pk BLOB NOT NULL REFERENCES device_chains(root_pk) ON DELETE CASCADE,\n"
     "  static_pk BLOB NOT NULL CHECK (length(static_pk) = 32),\n"
     "  name TEXT NOT NULL, system TEXT NOT NULL,\n"
     "  state INTEGER NOT NULL CHECK (state BETWEEN 1 AND 3),\n"
     "  added_at REAL NOT NULL, revoked_at REAL, last_seen_at REAL) WITHOUT ROWID;\n"
     "CREATE INDEX chain_devices_by_root ON chain_devices(root_pk);\n";

// v9, sync between this person's own devices (friends-multi-device.md § Sync; SZFriendsStoreSync.h): the signed event
// log every device keeps whole (bodies of deleted history dropped), the last-writer registers and their values, which
// events put each history item here (so a deletion takes exactly what the deleting device had seen, and keeps
// what it had not), items deleted that way (a late copy stays deleted), file records whose bytes may live on another
// device, and small sync state. Additive, so min_reader_version stays 2: a v8 helper ignores the tables, syncs nothing,
// and its own changes are picked up by the first v9 helper that scans for them.
static NSString *const SZFriendsSchemaV9 =
    @"CREATE TABLE sync_events (\n"
     "  author BLOB NOT NULL CHECK (length(author) = 32), seq INTEGER NOT NULL CHECK (seq >= 1),\n"
     "  lamport INTEGER NOT NULL CHECK (lamport >= 1), kind INTEGER NOT NULL, scope TEXT NOT NULL,\n"
     "  subject TEXT NOT NULL, header BLOB NOT NULL, body BLOB, applied INTEGER NOT NULL DEFAULT 0,\n"
     "  PRIMARY KEY (author, seq)) WITHOUT ROWID;\n"
     "CREATE INDEX sync_events_unapplied ON sync_events(lamport) WHERE applied = 0;\n"
     "CREATE INDEX sync_events_by_kind ON sync_events(kind, subject);\n"
     "CREATE TABLE sync_registers (\n"
     "  key TEXT PRIMARY KEY NOT NULL, lamport INTEGER NOT NULL, author BLOB NOT NULL, value BLOB) WITHOUT ROWID;\n"
     "CREATE TABLE sync_origins (\n"
     "  conversation_id TEXT NOT NULL, item_id TEXT NOT NULL, author BLOB NOT NULL, seq INTEGER NOT NULL,\n"
     "  PRIMARY KEY (conversation_id, item_id, author, seq)) WITHOUT ROWID;\n"
     "CREATE INDEX sync_origins_by_event ON sync_origins(author, seq);\n"
     "CREATE TABLE sync_deleted (\n"
     "  conversation_id TEXT NOT NULL, item_id TEXT NOT NULL, PRIMARY KEY (conversation_id, item_id)) WITHOUT ROWID;\n"
     "CREATE TABLE sync_files (\n"
     "  transfer_id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL, item_id TEXT,\n"
     "  outgoing INTEGER NOT NULL, state INTEGER NOT NULL, file_name TEXT NOT NULL, uniform_type TEXT,\n"
     "  size INTEGER NOT NULL CHECK (size >= 0), digest BLOB NOT NULL CHECK (length(digest) = 32),\n"
     "  created_at REAL NOT NULL, holders BLOB NOT NULL DEFAULT x'') WITHOUT ROWID;\n"
     "CREATE TABLE sync_state (key TEXT PRIMARY KEY NOT NULL, value) WITHOUT ROWID;\n";

// v10, received files saved to Downloads or a folder the person chose (PROTOCOL.md § Views, received): when each
// incoming file was published and how it came (0 a friend's offer, 1 a download link, 2 a copy from another of the
// person's computers). Additive, so min_reader_version stays 2: a v9 helper ignores both columns.
static NSString *const SZFriendsSchemaV10 =
    @"ALTER TABLE transfers ADD COLUMN received_at REAL;\n"
     "ALTER TABLE transfers ADD COLUMN received_via INTEGER NOT NULL DEFAULT 0;\n"
     "CREATE INDEX transfers_received ON transfers(received_at) WHERE received_at IS NOT NULL;\n";

// v11, taking people off the list (PROTOCOL.md remove_friend): friends.left_list_at, when the person took someone
// who is no longer a friend off their list. The row and its history stay, so the person can still find and delete
// that history, and a new request brings them back. It counts only while the relation is Removed or Blocked, so a
// request, an acceptance or an Add by ID, even one an older helper wrote, puts them back on the list.
// Additive, so min_reader_version stays 2: a v10 helper ignores the column and still lists the person.
static NSString *const SZFriendsSchemaV11 = @"ALTER TABLE friends ADD COLUMN left_list_at REAL;\n";

// v12, getting a file again (ADR 0016): where an outgoing file was sent from and its modification time then, so the
// computer that sent it still holds its bytes while that file is unchanged, and can give it again to the friend it
// went to. Never synced. Additive, so min_reader_version stays 2: a v11 helper ignores both columns.
static NSString *const SZFriendsSchemaV12 = @"ALTER TABLE transfers ADD COLUMN source_path TEXT;\n"
                                             "ALTER TABLE transfers ADD COLUMN source_mtime_ns INTEGER;\n";

@implementation SZFriendsStoreMigration

+ (instancetype)migrationToVersion:(NSInteger)version
                  minReaderVersion:(NSInteger)minReaderVersion
                             apply:(BOOL (^)(SZFriendsStoreDB *db, NSError **error))apply {
    SZFriendsStoreMigration *migration = [[self alloc] init];
    migration->_version = version;
    migration->_minReaderVersion = minReaderVersion;
    migration->_apply = [apply copy];
    return migration;
}

@end

NSArray<SZFriendsStoreMigration *> *SZFriendsStoreShippedMigrations(void) {
    SZFriendsStoreMigration *v1 = [SZFriendsStoreMigration
        migrationToVersion:1
          minReaderVersion:1
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         if (![db exec:SZFriendsSchemaV1 error:error]) return NO;
                         NSString *seed = @"INSERT INTO meta(key, value) VALUES ('store_id', ?), ('created_at', ?)";
                         NSString *created = [NSString stringWithFormat:@"%.3f", NSDate.date.timeIntervalSince1970];
                         return [db run:seed binds:@[ SZFriendsNewIdentifier(), created ] row:nil error:error];
                     }];
    SZFriendsStoreMigration *v2 = [SZFriendsStoreMigration
        migrationToVersion:2
          minReaderVersion:2
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV2 error:error];
                     }];
    SZFriendsStoreMigration *v3 = [SZFriendsStoreMigration
        migrationToVersion:3
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV3 error:error];
                     }];
    SZFriendsStoreMigration *v4 = [SZFriendsStoreMigration
        migrationToVersion:4
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV4 error:error];
                     }];
    SZFriendsStoreMigration *v5 = [SZFriendsStoreMigration
        migrationToVersion:5
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV5 error:error];
                     }];
    SZFriendsStoreMigration *v6 = [SZFriendsStoreMigration
        migrationToVersion:6
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV6 error:error];
                     }];
    SZFriendsStoreMigration *v7 = [SZFriendsStoreMigration
        migrationToVersion:7
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV7 error:error];
                     }];
    SZFriendsStoreMigration *v8 = [SZFriendsStoreMigration
        migrationToVersion:8
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV8 error:error];
                     }];
    SZFriendsStoreMigration *v9 = [SZFriendsStoreMigration
        migrationToVersion:9
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV9 error:error];
                     }];
    SZFriendsStoreMigration *v10 = [SZFriendsStoreMigration
        migrationToVersion:10
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV10 error:error];
                     }];
    SZFriendsStoreMigration *v11 = [SZFriendsStoreMigration
        migrationToVersion:11
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV11 error:error];
                     }];
    SZFriendsStoreMigration *v12 = [SZFriendsStoreMigration
        migrationToVersion:12
          minReaderVersion:0
                     apply:^BOOL(SZFriendsStoreDB *db, NSError **error) {
                         return [db exec:SZFriendsSchemaV12 error:error];
                     }];
    return @[ v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12 ];
}

BOOL SZFriendsStoreReadVersions(SZFriendsStoreDB *db, NSInteger *userVersion, NSInteger *minReaderVersion,
                                NSError **error) {
    NSNumber *version = [db scalar:@"PRAGMA user_version" binds:nil error:error];
    if (!version) return NO;
    *userVersion = version.integerValue;
    *minReaderVersion = 0;
    NSNumber *hasMeta = [db scalar:@"SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'"
                             binds:nil
                             error:error];
    if (!hasMeta) return NO;
    if (hasMeta.integerValue == 0) return YES;
    id minimum = [db scalar:@"SELECT value FROM meta WHERE key = 'min_reader_version'" binds:nil error:error];
    *minReaderVersion = [minimum respondsToSelector:@selector(integerValue)] ? [minimum integerValue] : 0;
    return YES;
}

// VACUUM INTO writes a consistent copy without blocking the WAL. Only the latest backup is kept: older ones hold
// history the person may since have deleted, and the newest is the one a failed upgrade needs.
static BOOL SZFriendsStoreBackUp(SZFriendsStoreDB *db, NSString *databasePath, NSInteger targetVersion,
                                 NSError **error) {
    NSString *directory = databasePath.stringByDeletingLastPathComponent;
    NSString *prefix = [databasePath.lastPathComponent stringByAppendingString:@".before-v"];
    NSString *backup = [NSString stringWithFormat:@"%@%ld", prefix, (long)targetVersion];
    NSString *backupPath = [directory stringByAppendingPathComponent:backup];
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtPath:backupPath error:NULL]; // VACUUM INTO refuses an existing file, even an empty one
    if (![db run:@"VACUUM INTO ?" binds:@[ backupPath ] row:nil error:error]) return NO;
    // The copy holds the whole history, so it gets the database's own 0600 (it is created with the umask's mode).
    chmod(backupPath.fileSystemRepresentation, 0600);
    for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL] ?: @[]) {
        if ([name hasPrefix:prefix] && ![name isEqualToString:backup]) {
            [files removeItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];
        }
    }
    return YES;
}

NSInteger SZFriendsStoreMigrate(SZFriendsStoreDB *db, NSString *databasePath,
                                NSArray<SZFriendsStoreMigration *> *migrations, NSError **error) {
    NSInteger current = 0, minReader = 0;
    if (!SZFriendsStoreReadVersions(db, &current, &minReader, error)) return -1;
    NSArray *sorted = [migrations sortedArrayUsingComparator:^NSComparisonResult(SZFriendsStoreMigration *a,
                                                                               SZFriendsStoreMigration *b) {
        return [@(a.version) compare:@(b.version)];
    }];
    NSMutableArray<SZFriendsStoreMigration *> *pending = [NSMutableArray array];
    for (SZFriendsStoreMigration *migration in sorted) {
        if (migration.version > current) [pending addObject:migration];
    }
    if (pending.count == 0) return current;
    // A version-0 file is new and empty: nothing to protect yet.
    if (current > 0 && !SZFriendsStoreBackUp(db, databasePath, pending.lastObject.version, error)) {
        NSString *why = @"could not write the pre-migration backup";
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorMigrationFailed, why));
        return -1;
    }
    for (SZFriendsStoreMigration *migration in pending) {
        NSError *failure = nil;
        BOOL ok = [db transaction:^BOOL(NSError **inner) {
            if (!migration.apply(db, inner)) return NO;
            // user_version lives in the header page, so it commits or rolls back with the migration itself.
            NSString *bump = [NSString stringWithFormat:@"PRAGMA user_version = %ld", (long)migration.version];
            if (![db exec:bump error:inner]) return NO;
            if (migration.minReaderVersion <= 0) return YES;
            NSString *upsert = @"INSERT INTO meta(key, value) VALUES ('min_reader_version', ?) "
                               @"ON CONFLICT(key) DO UPDATE SET value = excluded.value";
            return [db run:upsert binds:@[ [@(migration.minReaderVersion) stringValue] ] row:nil error:inner];
        } error:&failure];
        if (!ok) {
            NSString *why = [NSString stringWithFormat:@"migration to v%ld failed: %@", (long)migration.version,
                                                       failure.localizedDescription ?: @"unknown"];
            SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorMigrationFailed, why));
            return -1;
        }
        current = migration.version;
    }
    return current;
}

NS_ASSUME_NONNULL_END
