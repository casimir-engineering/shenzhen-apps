// What online Friends writes to SQLite (db.js, schemas 4 and 5), and nothing else: who holds each live download
// link, by keyed hashes of the link and the identity, so a link cannot be claimed by someone else while its sender
// is offline or after a restart; why a link stopped working (revoked or expired), for 31 days, by a keyed hash of
// its tombstone hash; and one row of relay counters per host per statistics day. Records, sids, payloads,
// candidates and addresses stay in memory or are never kept.

// The relay_daily columns, in the order snapshots and reports use them.
export const RELAY_COLUMNS = Object.freeze([
    'opens_helper', 'opens_id', 'opens_link', 'answered_helper', 'answered_id', 'answered_link', 'credentials',
    'relayed_helper', 'relayed_id', 'relayed_link', 'relayed_other', 'sessions', 'bytes_up', 'bytes_down',
    'session_seconds', 'peak_bps', 'capped_sessions', 'capped_minutes', 'now_sessions',
]);

const MAX_COUNTER = 2 ** 53 - 1;

// ---- download links ----------------------------------------------------------------------------------------

export function linkOwner(db, linkHash, nowS) {
    const row = db.prepare('SELECT identity_hash, expires FROM link_bindings WHERE link_hash = ? AND expires > ?')
        .get(linkHash, nowS);
    return row ? { identityHash: Buffer.from(row.identity_hash).toString('hex'), expires: row.expires } : null;
}

export function linksHeldBy(db, identityHashHex, nowS) {
    return db.prepare('SELECT COUNT(*) AS n FROM link_bindings WHERE identity_hash = ? AND expires > ?')
        .get(Buffer.from(identityHashHex, 'hex'), nowS).n;
}

// `tombKey` is null for a binding learnt from another host, which never sees the link id.
export function bindLink(db, { linkHash, identityHash, expires, tombKey = null }) {
    db.prepare(`INSERT INTO link_bindings (link_hash, identity_hash, expires, tomb_key) VALUES (?, ?, ?, ?)
        ON CONFLICT(link_hash) DO UPDATE SET identity_hash = excluded.identity_hash, expires = excluded.expires,
        tomb_key = COALESCE(excluded.tomb_key, tomb_key)`)
        .run(linkHash, Buffer.from(identityHash, 'hex'), expires, tombKey);
}

export function unbindLink(db, linkHash) {
    db.prepare('DELETE FROM link_bindings WHERE link_hash = ?').run(linkHash);
}

// Expired bindings go, each leaving an "expired" tombstone for TOMBSTONE_S; and tombstones past their time go.
export function pruneLinks(db, nowS) {
    db.prepare(`INSERT OR REPLACE INTO link_tombstones (tomb_key, identity_hash, reason, until)
        SELECT tomb_key, identity_hash, 'expired', expires + ? FROM link_bindings
        WHERE expires <= ? AND tomb_key IS NOT NULL`).run(TOMBSTONE_S, nowS);
    db.prepare('DELETE FROM link_tombstones WHERE until <= ?').run(nowS);
    return db.prepare('DELETE FROM link_bindings WHERE expires <= ?').run(nowS).changes;
}

// ---- tombstones of download links --------------------------------------------------------------------------

export const TOMBSTONE_S = 31 * 86_400;
export const TOMBSTONES_PER_IDENTITY = 500;

// The holder's live binding with this tombstone key: its link hash, or null.
export function bindingForTomb(db, tombKey, identityHashHex, nowS) {
    const row = db.prepare('SELECT link_hash FROM link_bindings WHERE tomb_key = ? AND identity_hash = ? '
        + 'AND expires > ?').get(tombKey, Buffer.from(identityHashHex, 'hex'), nowS);
    return row ? row.link_hash : null;
}

// The first identity to leave a tombstone keeps it and may change its reason and time, unless `holder`: the link's
// own holder (its binding, or its host's expiry) replaces whatever anyone else left. At most TOMBSTONES_PER_IDENTITY
// each: the ones that end soonest go first.
export function saveTombstone(db, { tombKey, identityHash, reason, until, holder = false }) {
    const who = Buffer.from(identityHash, 'hex');
    db.prepare(holder
        ? 'INSERT OR REPLACE INTO link_tombstones (tomb_key, identity_hash, reason, until) VALUES (?, ?, ?, ?)'
        : `INSERT INTO link_tombstones (tomb_key, identity_hash, reason, until) VALUES (?, ?, ?, ?)
        ON CONFLICT(tomb_key) DO UPDATE SET reason = excluded.reason, until = excluded.until
        WHERE identity_hash = excluded.identity_hash`).run(tombKey, who, reason, until);
    db.prepare(`DELETE FROM link_tombstones WHERE identity_hash = ? AND tomb_key NOT IN (
        SELECT tomb_key FROM link_tombstones WHERE identity_hash = ? ORDER BY until DESC, tomb_key LIMIT ?)`)
        .run(who, who, TOMBSTONES_PER_IDENTITY);
}

export function tombstoneReason(db, tombKey, nowS) {
    const row = db.prepare('SELECT reason FROM link_tombstones WHERE tomb_key = ? AND until > ?').get(tombKey, nowS);
    return row ? row.reason : null;
}

// ---- relay statistics --------------------------------------------------------------------------------------

export function emptyRelayDay() {
    return Object.fromEntries(RELAY_COLUMNS.map((column) => [column, 0]));
}

// A report from a replica, or anything else that claims to be a day's counters: whole non-negative numbers only.
export function cleanRelayDay(value) {
    if (!value || typeof value !== 'object') return null;
    const out = {};
    for (const column of RELAY_COLUMNS) {
        const n = value[column] ?? 0;
        if (!Number.isSafeInteger(n) || n < 0 || n > MAX_COUNTER) return null;
        out[column] = n;
    }
    return out;
}

export function saveRelayDay(db, { day, hostId, counters }) {
    const names = RELAY_COLUMNS.join(', ');
    const marks = RELAY_COLUMNS.map(() => '?').join(', ');
    const updates = RELAY_COLUMNS.map((column) => `${column} = excluded.${column}`).join(', ');
    db.prepare(`INSERT INTO relay_daily (day, host_id, ${names}) VALUES (?, ?, ${marks})
        ON CONFLICT(day, host_id) DO UPDATE SET ${updates}`)
        .run(day, hostId, ...RELAY_COLUMNS.map((column) => counters[column]));
}

export function loadRelayDay(db, { day, hostId }) {
    const row = db.prepare('SELECT * FROM relay_daily WHERE day = ? AND host_id = ?').get(day, hostId);
    return row ? cleanRelayDay(row) : null;
}

// Every host's row for each day from `from` on, newest first.
export function relayDays(db, from) {
    return db.prepare('SELECT * FROM relay_daily WHERE day >= ? ORDER BY day DESC, host_id').all(from);
}
