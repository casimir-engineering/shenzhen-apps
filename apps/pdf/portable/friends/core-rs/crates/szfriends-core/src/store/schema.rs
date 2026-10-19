//! The store's schema, statement for statement as the helper writes it (`SZFriendsStoreSchema.m`). SQLite keeps each
//! CREATE statement's text in `sqlite_master`, so these strings are kept byte-identical to the helper's: the suite
//! compares the schema a Rust store makes with the one the helper exports (`objc-store.json`). A shipped migration is
//! never edited; a change appends one, here and in the helper.

/// The schema version this build writes (`SZFriendsStoreSchemaVersion`).
pub const SCHEMA_VERSION: i64 = 9;

/// One forward-only step: its version, the oldest schema that can still read the store after it (0 leaves
/// `min_reader_version` alone, as additive steps do), and its statements.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Migration {
    pub version: i64,
    pub min_reader_version: i64,
    pub sql: &'static str,
}

/// Every migration ever shipped, oldest first.
pub const SHIPPED: [Migration; 9] = [
    Migration { version: 1, min_reader_version: 1, sql: V1 },
    Migration { version: 2, min_reader_version: 2, sql: V2 },
    Migration { version: 3, min_reader_version: 0, sql: V3 },
    Migration { version: 4, min_reader_version: 0, sql: V4 },
    Migration { version: 5, min_reader_version: 0, sql: V5 },
    Migration { version: 6, min_reader_version: 0, sql: V6 },
    Migration { version: 7, min_reader_version: 0, sql: V7 },
    Migration { version: 8, min_reader_version: 0, sql: V8 },
    Migration { version: 9, min_reader_version: 0, sql: V9 },
];

/// Schema v1 (ADR 0003 § Schema v1). Times are Unix seconds (REAL); keys and secrets are BLOBs whose lengths the
/// schema itself checks.
const V1: &str = r#"CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, value) WITHOUT ROWID;
CREATE TABLE profile (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  name TEXT,
  picture_kind INTEGER NOT NULL DEFAULT 0, picture_set INTEGER NOT NULL DEFAULT 0,
  picture_index INTEGER NOT NULL DEFAULT -1, picture_path TEXT, picture_sha256 BLOB,
  friends_id TEXT, friends_id_state INTEGER NOT NULL DEFAULT 0, previous_friends_id TEXT,
  id_collisions INTEGER NOT NULL DEFAULT 0);
CREATE TABLE friends (
  conversation_id TEXT PRIMARY KEY NOT NULL,
  identity_pk BLOB UNIQUE CHECK (identity_pk IS NULL OR length(identity_pk) = 32),
  static_pk BLOB CHECK (static_pk IS NULL OR length(static_pk) = 32),
  friends_id TEXT, name TEXT,
  picture_kind INTEGER NOT NULL DEFAULT 0, picture_set INTEGER NOT NULL DEFAULT 0,
  picture_index INTEGER NOT NULL DEFAULT -1, picture_path TEXT, picture_sha256 BLOB,
  relation INTEGER NOT NULL CHECK (relation BETWEEN 0 AND 4),
  verified INTEGER NOT NULL DEFAULT 0, verified_at REAL, comparison_code TEXT,
  auto_accept INTEGER NOT NULL DEFAULT 0, key_change_pending INTEGER NOT NULL DEFAULT 0,
  presence_secret BLOB CHECK (presence_secret IS NULL OR length(presence_secret) = 32),
  callback_token BLOB CHECK (callback_token IS NULL OR length(callback_token) = 16),
  callback_secret BLOB CHECK (callback_secret IS NULL OR length(callback_secret) = 32),
  last_interaction_at REAL NOT NULL, unread_count INTEGER NOT NULL DEFAULT 0,
  request_at REAL, request_found_nearby INTEGER NOT NULL DEFAULT 0);
CREATE INDEX friends_by_interaction ON friends(last_interaction_at DESC, conversation_id);
CREATE TABLE id_requests (
  conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,
  target_friends_id TEXT NOT NULL,
  request_token BLOB NOT NULL UNIQUE CHECK (length(request_token) = 16),
  callback_secret BLOB NOT NULL CHECK (length(callback_secret) = 32),
  created_at REAL NOT NULL, expires_at REAL NOT NULL);
CREATE TABLE messages (
  seq INTEGER PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,
  item_id TEXT NOT NULL, kind INTEGER NOT NULL, direction INTEGER NOT NULL,
  body TEXT, folded TEXT, transfer_id TEXT, event_kind TEXT, event_args TEXT,
  sent_at REAL NOT NULL, received_at REAL NOT NULL,
  UNIQUE (conversation_id, item_id));
CREATE INDEX messages_by_time ON messages(conversation_id, sent_at, item_id);
CREATE TABLE outbox (
  entry_id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,
  kind INTEGER NOT NULL, state INTEGER NOT NULL,
  created_at REAL NOT NULL, queued_at REAL NOT NULL, updated_at REAL NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, item_id TEXT, client_token TEXT, failure_reason TEXT, payload BLOB);
CREATE INDEX outbox_pending ON outbox(conversation_id, state, created_at);
CREATE UNIQUE INDEX outbox_item ON outbox(conversation_id, item_id) WHERE item_id IS NOT NULL;
CREATE INDEX outbox_token ON outbox(client_token) WHERE client_token IS NOT NULL;
CREATE TABLE transfers (
  transfer_id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,
  outgoing INTEGER NOT NULL, state INTEGER NOT NULL CHECK (state BETWEEN 0 AND 9),
  file_name TEXT NOT NULL, uniform_type TEXT, size INTEGER NOT NULL CHECK (size >= 0),
  digest BLOB NOT NULL CHECK (length(digest) = 32),
  verified_bytes INTEGER NOT NULL DEFAULT 0 CHECK (verified_bytes >= 0 AND verified_bytes <= size),
  accepted_automatically INTEGER NOT NULL DEFAULT 0, asked_low_disk INTEGER NOT NULL DEFAULT 0,
  staged_path TEXT, partial_path TEXT, final_path TEXT, publishing INTEGER NOT NULL DEFAULT 0,
  received_path TEXT,
  revision_source TEXT, revision_document_id TEXT, revision_id TEXT, revision_label TEXT,
  revision_sha256 BLOB, revision_size INTEGER,
  bytes_per_second REAL NOT NULL DEFAULT 0, failure_reason TEXT,
  created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE INDEX transfers_by_conversation ON transfers(conversation_id, created_at);
"#;

/// v2, from the M1 security reviews: the pending static key, Add by ID answers, case-insensitive transfer ids.
/// Raises min_reader_version to 2.
const V2: &str = r#"ALTER TABLE friends ADD COLUMN pending_static_pk BLOB
  CHECK (pending_static_pk IS NULL OR length(pending_static_pk) = 32);
ALTER TABLE id_requests ADD COLUMN answered_at REAL;
CREATE TABLE id_request_answers (
  request_token BLOB NOT NULL REFERENCES id_requests(request_token) ON DELETE CASCADE,
  identity_pk BLOB NOT NULL CHECK (length(identity_pk) = 32),
  conversation_id TEXT NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE,
  answered_at REAL NOT NULL,
  PRIMARY KEY (request_token, identity_pk)) WITHOUT ROWID;
CREATE INDEX id_request_answers_by_conversation ON id_request_answers(conversation_id);
CREATE INDEX transfers_by_id_nocase ON transfers(transfer_id COLLATE NOCASE);
"#;

/// v3, from the wave-3 re-check: request_since, host attestations on people and the profile. Additive.
const V3: &str = r#"ALTER TABLE friends ADD COLUMN request_since REAL;
ALTER TABLE friends ADD COLUMN attested_friends_id TEXT;
ALTER TABLE friends ADD COLUMN id_attestation BLOB
  CHECK (id_attestation IS NULL OR length(id_attestation) BETWEEN 1 AND 1024);
ALTER TABLE friends ADD COLUMN id_attestation_day TEXT;
ALTER TABLE profile ADD COLUMN attested_friends_id TEXT;
ALTER TABLE profile ADD COLUMN id_attestation BLOB
  CHECK (id_attestation IS NULL OR length(id_attestation) BETWEEN 1 AND 1024);
ALTER TABLE profile ADD COLUMN id_attestation_day TEXT;
ALTER TABLE id_request_answers ADD COLUMN attested INTEGER NOT NULL DEFAULT 0;
UPDATE friends SET request_since = coalesce(request_at, last_interaction_at) WHERE relation IN (0, 1);
"#;

/// v4: messages.via_assistant and friends.unconfirmed_answer_id. Additive.
const V4: &str = r#"ALTER TABLE messages ADD COLUMN via_assistant INTEGER NOT NULL DEFAULT 0;
ALTER TABLE friends ADD COLUMN unconfirmed_answer_id TEXT;
"#;

/// v5: messages.cancelled. Additive.
const V5: &str = r#"ALTER TABLE messages ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0;
"#;

/// v6: transfer_thumbnails, one file preview per transfer (ADR 0008). Additive.
const V6: &str = r#"CREATE TABLE transfer_thumbnails (
  transfer_id TEXT PRIMARY KEY NOT NULL REFERENCES transfers(transfer_id) ON DELETE CASCADE,
  source INTEGER NOT NULL CHECK (source IN (1, 2)),
  width INTEGER NOT NULL CHECK (width BETWEEN 1 AND 192),
  height INTEGER NOT NULL CHECK (height BETWEEN 1 AND 192),
  png_name TEXT NOT NULL CHECK (length(png_name) = 36),
  qoi BLOB CHECK (qoi IS NULL OR length(qoi) BETWEEN 23 AND 64000),
  delivered INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL) WITHOUT ROWID;
"#;

/// v7: links, invites, link_requests and link_contacts (friends-links.md). Additive.
const V7: &str = r#"CREATE TABLE links (
  link_id BLOB PRIMARY KEY NOT NULL CHECK (length(link_id) = 16),
  secret BLOB NOT NULL CHECK (length(secret) = 32),
  file_name TEXT NOT NULL, uniform_type TEXT, size INTEGER NOT NULL CHECK (size >= 0),
  sha256 BLOB NOT NULL CHECK (length(sha256) = 32), blake2b BLOB NOT NULL CHECK (length(blake2b) = 32),
  snapshot_path TEXT, source_path TEXT, source_mtime_ns INTEGER, source_ctime_ns INTEGER,
  source_inode INTEGER, source_device INTEGER,
  thumbnail_png BLOB CHECK (thumbnail_png IS NULL OR length(thumbnail_png) BETWEEN 1 AND 48000),
  created_at REAL NOT NULL, expires_at REAL NOT NULL, downloads INTEGER NOT NULL DEFAULT 0,
  CHECK ((snapshot_path IS NULL) <> (source_path IS NULL))) WITHOUT ROWID;
CREATE TABLE invites (
  token BLOB PRIMARY KEY NOT NULL CHECK (length(token) = 16),
  one_time INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, expires_at REAL,
  used_at REAL, revoked_at REAL) WITHOUT ROWID;
CREATE TABLE link_requests (
  conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES id_requests(conversation_id) ON DELETE CASCADE,
  invite_token BLOB NOT NULL CHECK (length(invite_token) = 16)) WITHOUT ROWID;
CREATE TABLE link_contacts (
  conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES friends(conversation_id) ON DELETE CASCADE)
  WITHOUT ROWID;
"#;

/// v8: device_chains and chain_devices (ADR 0012). Additive.
const V8: &str = r#"CREATE TABLE device_chains (
  root_pk BLOB PRIMARY KEY NOT NULL CHECK (length(root_pk) = 32),
  genesis_hash BLOB NOT NULL CHECK (length(genesis_hash) = 32),
  chain BLOB NOT NULL CHECK (length(chain) BETWEEN 3 AND 64000),
  own INTEGER NOT NULL DEFAULT 0 CHECK (own IN (0, 1)),
  updated_at REAL NOT NULL) WITHOUT ROWID;
CREATE UNIQUE INDEX device_chains_own ON device_chains(own) WHERE own = 1;
CREATE TABLE chain_devices (
  device_pk BLOB PRIMARY KEY NOT NULL CHECK (length(device_pk) = 32),
  root_pk BLOB NOT NULL REFERENCES device_chains(root_pk) ON DELETE CASCADE,
  static_pk BLOB NOT NULL CHECK (length(static_pk) = 32),
  name TEXT NOT NULL, system TEXT NOT NULL,
  state INTEGER NOT NULL CHECK (state BETWEEN 1 AND 3),
  added_at REAL NOT NULL, revoked_at REAL, last_seen_at REAL) WITHOUT ROWID;
CREATE INDEX chain_devices_by_root ON chain_devices(root_pk);
"#;

/// v9: the sync tables (friends-multi-device.md § Sync). Additive.
const V9: &str = r#"CREATE TABLE sync_events (
  author BLOB NOT NULL CHECK (length(author) = 32), seq INTEGER NOT NULL CHECK (seq >= 1),
  lamport INTEGER NOT NULL CHECK (lamport >= 1), kind INTEGER NOT NULL, scope TEXT NOT NULL,
  subject TEXT NOT NULL, header BLOB NOT NULL, body BLOB, applied INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (author, seq)) WITHOUT ROWID;
CREATE INDEX sync_events_unapplied ON sync_events(lamport) WHERE applied = 0;
CREATE INDEX sync_events_by_kind ON sync_events(kind, subject);
CREATE TABLE sync_registers (
  key TEXT PRIMARY KEY NOT NULL, lamport INTEGER NOT NULL, author BLOB NOT NULL, value BLOB) WITHOUT ROWID;
CREATE TABLE sync_origins (
  conversation_id TEXT NOT NULL, item_id TEXT NOT NULL, author BLOB NOT NULL, seq INTEGER NOT NULL,
  PRIMARY KEY (conversation_id, item_id, author, seq)) WITHOUT ROWID;
CREATE INDEX sync_origins_by_event ON sync_origins(author, seq);
CREATE TABLE sync_deleted (
  conversation_id TEXT NOT NULL, item_id TEXT NOT NULL, PRIMARY KEY (conversation_id, item_id)) WITHOUT ROWID;
CREATE TABLE sync_files (
  transfer_id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL, item_id TEXT,
  outgoing INTEGER NOT NULL, state INTEGER NOT NULL, file_name TEXT NOT NULL, uniform_type TEXT,
  size INTEGER NOT NULL CHECK (size >= 0), digest BLOB NOT NULL CHECK (length(digest) = 32),
  created_at REAL NOT NULL, holders BLOB NOT NULL DEFAULT x'') WITHOUT ROWID;
CREATE TABLE sync_state (key TEXT PRIMARY KEY NOT NULL, value) WITHOUT ROWID;
"#;
