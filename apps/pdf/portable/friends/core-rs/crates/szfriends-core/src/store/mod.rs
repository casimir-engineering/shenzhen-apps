//! The store (`service/store/`, ADR 0003): `friends.sqlite` in the state directory, with the helper's schema,
//! migrations, pragmas and search index, the outbox, and transfers with durable progress. One write connection, used by
//! one owner; the person's whole Friends history lives here and nowhere else.
//!
//! What the Rust store adds (ADR 0015 § 17): it records the identity key it was made for in `meta`
//! (`identity_pk`), so a store and a key that do not belong together are never used together
//! ([`Store::identity_of`] feeds `IdentityManager::load_or_create`).

mod add_by_id;
pub mod attestation;
pub mod destination;
pub mod devices;
mod friend_links;
pub mod links;
mod migrate;
mod outbox;
mod people;
mod receive;
pub mod requests;
mod saved;
pub mod schema;
mod search;
pub mod sync_files;
pub mod sync_history;
pub mod sync_log;
pub mod sync_records;
mod sync_settings;
mod transfer_files;
mod transfer_local;
mod transfer_states;
mod transfers;

use std::fmt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use szfriends_identity::keystore::StoreIdentity;

pub use add_by_id::{
    IdRequest, ID_REQUEST_LIFETIME_SECONDS, ID_REQUEST_MAX_ANSWERS, ID_REQUEST_MAX_PENDING,
    ID_REQUEST_MAX_UNATTESTED_ANSWERS,
};
pub use destination::{
    ExternalPublisher, FolderRefusal, PhoneFolder, ReceivedDefaults, ReceivedFile, ReceivedSource, ENV_DOWNLOADS_DIR,
    RECEIVED_FOLDER_FILE,
};
pub use friend_links::{InviteRecord, INVITE_ACCEPTS_PER_DAY, ONE_TIME_INVITE_LIFETIME};
pub use links::{
    link_file_hashes, link_tombstone_hash, DownloadLinkRecord, EndReason, LinkTombstone, SourceStamp,
    DOWNLOAD_LINKS_MAX,
};
pub use outbox::{OutboxEntry, OutboxEvent, OutboxKind, OutboxState, OUTBOX_EXPIRY_SECONDS};
pub use people::{Direction, Item, ItemKind, Person, Relation};
pub use receive::DURABLE_BATCH_BYTES;
pub use saved::{ReceivedFallback, SavedPlace, RECEIVED_FALLBACK_FILE};
pub use schema::{Migration, SCHEMA_VERSION, SHIPPED};
pub use search::{fold, SearchHit};
pub use transfer_files::{file_digest, sanitized_file_name, unique_destination};
pub use transfers::{TransferEvent, TransferRecord, TransferState};

pub const DATABASE_NAME: &str = "friends.sqlite";

/// What a store operation reports (`SZFriendsStoreError`). Descriptions name what failed, never message text or keys.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StoreError {
    OpenFailed(String),
    /// The file needs a newer schema than this build reads: report "needs update", touch nothing.
    NewerSchema {
        needs: i64,
        reads: i64,
    },
    MigrationFailed(String),
    /// SQLite here has no FTS5 trigram tokenizer (ADR 0015 § 7: the store is then unavailable, not search-less).
    NoTrigram,
    Invalid(&'static str),
    NotFound,
    Constraint,
    /// The event no longer applies (a late or replayed answer); nothing changed.
    Stale,
    DiskFull,
    /// A person's keys change only through review; a conversation never moves to another key.
    KeyChangeRefused,
    FileMissing,
    DigestMismatch,
    /// The store was made for another identity, or a key is recorded twice.
    IdentityMismatch,
    Database(String),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for StoreError {}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        match error.sqlite_error_code() {
            Some(rusqlite::ErrorCode::DiskFull) => Self::DiskFull,
            Some(rusqlite::ErrorCode::ConstraintViolation) => Self::Constraint,
            _ => Self::Database(error.to_string()),
        }
    }
}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        if error.raw_os_error() == Some(28) {
            return Self::DiskFull; // ENOSPC
        }
        Self::Database(error.to_string())
    }
}

pub type Result<T> = std::result::Result<T, StoreError>;

/// Unix seconds now, as the store keeps times.
pub fn unix_now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// 128 random bits as 32 lowercase hex digits (`SZFriendsNewIdentifier`).
pub fn new_identifier() -> String {
    let mut bytes = [0u8; 16];
    szfriends_crypto::random_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `[A-Za-z0-9_-]`, 1 to 64 bytes: the opaque id rule every id the store keeps follows.
pub fn is_valid_identifier(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// What tests change; production opens with the defaults.
#[derive(Clone, Debug, Default)]
pub struct StoreOptions {
    /// `None`: the shipped list.
    pub migrations: Option<Vec<Migration>>,
    /// Behave as on a SQLite without the trigram tokenizer: search scans, and writes mark the index stale.
    pub disable_trigram: bool,
    /// Where received files go when the person chose nothing; `None`: [`ReceivedDefaults::contained`].
    pub received: Option<destination::ReceivedDefaults>,
}

pub struct Store {
    pub(crate) conn: Connection,
    state_dir: PathBuf,
    db_path: PathBuf,
    schema_version: i64,
    search_uses_index: bool,
    pub(crate) receiving: receive::Receiving,
    received_defaults: destination::ReceivedDefaults,
}

impl fmt::Debug for Store {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Store").field("db_path", &self.db_path).field("schema_version", &self.schema_version).finish()
    }
}

impl Store {
    /// Opens (or creates) the store in `state_dir`: the directory 0700, the file 0600 before SQLite sees it, the
    /// ADR 0003 pragmas, WAL, the pre-migration backup and migrations, the search index, and crash recovery.
    pub fn open(state_dir: impl AsRef<Path>) -> Result<Self> {
        Self::open_with(state_dir, StoreOptions::default())
    }

    pub fn open_with(state_dir: impl AsRef<Path>, options: StoreOptions) -> Result<Self> {
        let state_dir = state_dir.as_ref().to_path_buf();
        transfer_files::ensure_private_directory(&state_dir).map_err(|e| StoreError::OpenFailed(e.to_string()))?;
        let db_path = state_dir.join(DATABASE_NAME);
        transfer_files::create_private_file(&db_path).map_err(|e| StoreError::OpenFailed(e.to_string()))?;
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let conn = Connection::open_with_flags(&db_path, flags).map_err(|e| StoreError::OpenFailed(e.to_string()))?;
        // ADR 0003 § Pragmas. trusted_schema=OFF keeps SQL functions in the schema from running anything with side
        // effects if the file were ever tampered with; FULL with full fsync is what makes a durable ACK true.
        conn.execute_batch(
            "PRAGMA busy_timeout=5000; PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; \
             PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;",
        )?;
        let migrations = options.migrations.clone().unwrap_or_else(|| SHIPPED.to_vec());
        let code_version = migrations.iter().map(|m| m.version).max().unwrap_or(0);
        let (_, min_reader) = migrate::read_versions(&conn)?;
        // Checked before anything writes, so a store a newer app upgraded is left exactly as it was.
        if min_reader > code_version {
            return Err(StoreError::NewerSchema { needs: min_reader, reads: code_version });
        }
        let mode: String = conn.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
        if mode != "wal" {
            return Err(StoreError::OpenFailed("the store could not switch to WAL".into()));
        }
        let schema_version = migrate::migrate(&conn, &db_path, &migrations)?;
        let search_uses_index = search::prepare(&conn, !options.disable_trigram)?;
        // An entry caught mid-send after a crash is sent again under the same id; the recipient deduplicates.
        conn.execute(
            "UPDATE outbox SET state = ?1, updated_at = ?2 WHERE state IN (?3, ?4)",
            rusqlite::params![
                OutboxState::Queued as i64,
                unix_now(),
                OutboxState::Connecting as i64,
                OutboxState::Sending as i64
            ],
        )?;
        let received_defaults =
            options.received.clone().unwrap_or_else(|| destination::ReceivedDefaults::contained(&state_dir));
        let mut store = Self {
            conn,
            state_dir,
            db_path,
            schema_version,
            search_uses_index,
            receiving: Default::default(),
            received_defaults,
        };
        store.recover_transfers()?;
        Ok(store)
    }

    /// What the store in `state_dir` says about the identity it was made for, without creating anything: no file is
    /// a first start; a file without a recorded key cannot belong to any identity and is refused.
    pub fn identity_of(state_dir: impl AsRef<Path>) -> Result<StoreIdentity> {
        let path = state_dir.as_ref().join(DATABASE_NAME);
        if !path.exists() {
            return Ok(StoreIdentity::NoStore);
        }
        let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let conn = Connection::open_with_flags(&path, flags).map_err(|e| StoreError::OpenFailed(e.to_string()))?;
        let recorded = match Self::read_identity(&conn) {
            Ok(recorded) => recorded,
            // A WAL store closed cleanly has no -wal or -shm file, and Apple's system SQLite (iOS) will not create
            // them for a read-only connection: read it read-write instead, creating nothing.
            Err(_) => {
                let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
                let conn =
                    Connection::open_with_flags(&path, flags).map_err(|e| StoreError::OpenFailed(e.to_string()))?;
                Self::read_identity(&conn)?
            }
        };
        match recorded {
            Some(key) => Ok(StoreIdentity::Recorded(key)),
            None => Err(StoreError::IdentityMismatch),
        }
    }

    fn read_identity(conn: &Connection) -> Result<Option<[u8; 32]>> {
        let has_meta: i64 =
            conn.query_row("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'", [], |r| {
                r.get(0)
            })?;
        if has_meta == 0 {
            return Ok(None);
        }
        let text: Option<String> =
            conn.query_row("SELECT value FROM meta WHERE key = 'identity_pk'", [], |row| row.get(0)).optional()?;
        Ok(text.and_then(|t| hex_decode(&t)).and_then(|b| b.try_into().ok()))
    }

    /// The identity key this store was made for, if recorded.
    pub fn recorded_identity(&self) -> Result<Option<[u8; 32]>> {
        Self::read_identity(&self.conn)
    }

    /// Records the identity this store belongs to, once; another key afterwards is refused.
    pub fn record_identity(&mut self, key: &[u8; 32]) -> Result<()> {
        match self.recorded_identity()? {
            Some(existing) if &existing == key => Ok(()),
            Some(_) => Err(StoreError::IdentityMismatch),
            None => {
                let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
                self.conn.execute("INSERT INTO meta(key, value) VALUES ('identity_pk', ?1)", [hex])?;
                Ok(())
            }
        }
    }

    pub fn state_dir(&self) -> &Path {
        &self.state_dir
    }

    pub fn database_path(&self) -> &Path {
        &self.db_path
    }

    pub fn schema_version(&self) -> i64 {
        self.schema_version
    }

    /// `false` when SQLite here has no trigram tokenizer and search scans instead.
    pub fn search_uses_index(&self) -> bool {
        self.search_uses_index
    }

    /// The connection, for the suites' own checks.
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    /// `BEGIN IMMEDIATE` ... `COMMIT`; an error from `body` rolls everything back.
    pub(crate) fn write<T>(&mut self, body: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let transaction = self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let value = body(&transaction)?;
        transaction.commit()?;
        Ok(value)
    }
}

pub(crate) fn hex_decode(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}
