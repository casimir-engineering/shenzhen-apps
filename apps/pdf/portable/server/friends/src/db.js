// SQLite through node:sqlite (ADR 0005 § Runtime): WAL, a busy timeout, forward-only migrations keyed by
// PRAGMA user_version. Synchronous on purpose: every statement is short, and one process means one writer, which is
// what makes "first reservation wins" a property of the transaction rather than of timing.
//
// What is stored (ADR 0005 § Statistics and retention, § Privacy): no IP address and no identity key anywhere.
// Identities are named by an HMAC of their key with the fleet's identity secret (keys.js identityHash). Which
// identities were active on a day is kept only for the current day, under a salt that is deleted with that day's
// rows at rollover, so no table says on which days a person was online beyond their first and last check-in. With
// several devices (protocol 3) an identity is a person, named by their root key; their devices are named the same way
// by their device keys, and a device's name never reaches the host's storage.

import { DatabaseSync } from 'node:sqlite';

const MIGRATIONS = [
    // v1
    `CREATE TABLE identities (
        identity_hash BLOB PRIMARY KEY,
        friends_id TEXT UNIQUE,
        first_day TEXT NOT NULL,
        last_day TEXT NOT NULL,
        app_version TEXT,
        list_version INTEGER,
        protocol INTEGER
    ) WITHOUT ROWID;
    CREATE INDEX identities_last_day ON identities(last_day);
    CREATE TABLE daily_active (
        day TEXT NOT NULL,
        identity_hash BLOB NOT NULL,
        PRIMARY KEY (day, identity_hash)
    ) WITHOUT ROWID;
    CREATE TABLE daily_stats (
        day TEXT PRIMARY KEY,
        uniques INTEGER NOT NULL DEFAULT 0,
        identities INTEGER NOT NULL DEFAULT 0,
        reserved INTEGER NOT NULL DEFAULT 0,
        reservations INTEGER NOT NULL DEFAULT 0,
        collisions INTEGER NOT NULL DEFAULT 0,
        renames INTEGER NOT NULL DEFAULT 0,
        releases INTEGER NOT NULL DEFAULT 0,
        peak_connections INTEGER NOT NULL DEFAULT 0,
        avg_connections REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE connection_samples (
        minute INTEGER NOT NULL,
        host_id TEXT NOT NULL,
        day TEXT NOT NULL,
        connections INTEGER NOT NULL,
        PRIMARY KEY (minute, host_id)
    ) WITHOUT ROWID;
    CREATE INDEX connection_samples_day ON connection_samples(day);
    CREATE TABLE host_lists (
        version INTEGER PRIMARY KEY,
        envelope TEXT NOT NULL,
        published_at INTEGER NOT NULL
    );
    CREATE TABLE forward_queue (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        body TEXT NOT NULL
    );
    CREATE TABLE meta (
        key TEXT PRIMARY KEY,
        value INTEGER NOT NULL
    );`,
    // v2: keyed identity hashes (v1's were unkeyed, so v1 identity rows cannot be carried over; see migrate),
    // today-only salted active sets, new identities per day, text settings, and the staging table a replica fills
    // while it copies the main host's ID table.
    `DROP TABLE daily_active;
    DELETE FROM forward_queue;
    CREATE TABLE daily_seen (
        day TEXT NOT NULL,
        token BLOB NOT NULL,
        PRIMARY KEY (day, token)
    ) WITHOUT ROWID;
    CREATE TABLE day_salts (
        day TEXT PRIMARY KEY,
        salt BLOB NOT NULL
    );
    ALTER TABLE daily_stats ADD COLUMN new_identities INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE id_staging (
        identity_hash BLOB PRIMARY KEY,
        friends_id TEXT NOT NULL,
        first_day TEXT NOT NULL,
        last_day TEXT NOT NULL
    ) WITHOUT ROWID;`,
    // v3 (main host): the identities each replica forwarded a helper's own signed check-in for, and the last day it
    // did. A replica's check-in summaries count only for these (host-links.js); rows go after 31 days.
    `CREATE TABLE replica_proofs (
        replica_id TEXT NOT NULL,
        identity_hash BLOB NOT NULL,
        last_day TEXT NOT NULL,
        PRIMARY KEY (replica_id, identity_hash)
    ) WITHOUT ROWID;
    CREATE INDEX replica_proofs_last_day ON replica_proofs(last_day);`,
    // v4 (online Friends, online-store.js): who holds each live download link, by keyed hashes of the link and the
    // identity, until the link expires; and the relay's counters, one row per host per statistics day, kept like
    // daily_stats.
    `CREATE TABLE link_bindings (
        link_hash TEXT PRIMARY KEY,
        identity_hash BLOB NOT NULL,
        expires INTEGER NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX link_bindings_identity ON link_bindings(identity_hash);
    CREATE TABLE relay_daily (
        day TEXT NOT NULL,
        host_id TEXT NOT NULL,
        ${['opens_helper', 'opens_id', 'opens_link', 'answered_helper', 'answered_id', 'answered_link',
        'credentials', 'relayed_helper', 'relayed_id', 'relayed_link', 'relayed_other', 'sessions', 'bytes_up',
        'bytes_down', 'session_seconds', 'peak_bps', 'capped_sessions', 'capped_minutes', 'now_sessions']
        .map((column) => `${column} INTEGER NOT NULL DEFAULT 0,`).join('\n        ')}
        PRIMARY KEY (day, host_id)
    ) WITHOUT ROWID;`,
    // v5 (online-store.js): why a download link stopped working, for 31 days, so its page can say "revoked" or
    // "expired" instead of waiting. Keyed by a keyed hash of the link's tombstone hash (never the link id); each
    // binding keeps that key too, so an expired binding leaves its tombstone behind.
    `ALTER TABLE link_bindings ADD COLUMN tomb_key TEXT;
    CREATE INDEX link_bindings_tomb ON link_bindings(tomb_key);
    CREATE TABLE link_tombstones (
        tomb_key TEXT PRIMARY KEY,
        identity_hash BLOB NOT NULL,
        reason TEXT NOT NULL,
        until INTEGER NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX link_tombstones_identity ON link_tombstones(identity_hash);`,
    // v6 (protocol 3, device-records.js): a person's devices by keyed hash, for devices per person and joins; the
    // revocations the host has seen in people's chains, so a revoked device cannot check in with an older chain; and
    // today's salted set of devices, kept like daily_seen.
    `CREATE TABLE devices (
        device_hash BLOB PRIMARY KEY,
        identity_hash BLOB NOT NULL,
        first_day TEXT NOT NULL,
        last_day TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX devices_identity ON devices(identity_hash);
    CREATE INDEX devices_last_day ON devices(last_day);
    CREATE TABLE device_revocations (
        identity_hash BLOB NOT NULL,
        device_hash BLOB NOT NULL,
        link_hash BLOB NOT NULL,
        last_day TEXT NOT NULL,
        PRIMARY KEY (identity_hash, device_hash)
    ) WITHOUT ROWID;
    CREATE TABLE daily_seen_devices (
        day TEXT NOT NULL,
        token BLOB NOT NULL,
        PRIMARY KEY (day, token)
    ) WITHOUT ROWID;
    ALTER TABLE daily_stats ADD COLUMN device_uniques INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE daily_stats ADD COLUMN joins INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE daily_stats ADD COLUMN revocations INTEGER NOT NULL DEFAULT 0;`,
];

export const SCHEMA_VERSION = MIGRATIONS.length;

export function openDatabase(path) {
    const db = new DatabaseSync(path, { timeout: 5000 });
    db.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;');
    migrate(db);
    return db;
}

function migrate(db) {
    const current = db.prepare('PRAGMA user_version').get().user_version;
    if (current > MIGRATIONS.length) {
        // A newer service wrote this database; refusing beats guessing at a schema we do not know.
        throw new Error(`database schema ${current} is newer than this service (${MIGRATIONS.length})`);
    }
    for (let version = current; version < MIGRATIONS.length; version++) {
        if (version === 1 && db.prepare('SELECT COUNT(*) AS n FROM identities').get().n > 0) {
            // v1 named identities by an unkeyed hash, which v2 cannot convert without the keys it never stored.
            // Dropping the rows would free every reserved ID for the first claimant, so refuse instead.
            throw new Error('database schema 1 holds identities that v2 cannot rename; restore from the host that '
                + 'wrote it or start from an empty data directory');
        }
        transaction(db, () => {
            db.exec(MIGRATIONS[version]);
            db.exec(`PRAGMA user_version = ${version + 1}`);
        });
    }
}

// BEGIN IMMEDIATE takes the write lock up front, so a reservation's read and insert cannot interleave with
// another writer's.
export function transaction(db, body) {
    db.exec('BEGIN IMMEDIATE');
    try {
        const result = body();
        db.exec('COMMIT');
        return result;
    } catch (error) {
        db.exec('ROLLBACK');
        throw error;
    }
}

export function metaGet(db, key) {
    return db.prepare('SELECT value FROM meta WHERE key = ?').get(key)?.value ?? 0;
}

export function metaAdd(db, key, delta) {
    db.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = value + ?')
        .run(key, delta, delta);
}

export function settingGet(db, key) {
    return db.prepare('SELECT value FROM settings WHERE key = ?').get(key)?.value ?? null;
}

export function settingSet(db, key, value) {
    db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
        .run(key, value);
}
