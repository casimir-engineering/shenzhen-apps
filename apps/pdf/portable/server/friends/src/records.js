// Everything the host writes: ID reservations (main host only), check-in summaries, releases, connection
// samples, published host lists, the replica's forwarding queue, and retention. Functions that change who holds
// which ID return the change, so the main host can pass it on to its replicas (id-sync.js).

import crypto from 'node:crypto';

import { addDays, addMonths } from './clock.js';
import { metaAdd, transaction } from './db.js';
import { validFriendsId } from './protocol.js';

const COUNTERS = new Set(['reservations', 'collisions', 'renames', 'releases', 'new_identities', 'uniques', 'joins',
    'revocations']);
// ADR 0005 § Statistics and retention: an ID reserved by an identity that never checks in on a later day is freed
// after this many days of absence, so throwaway keys cannot hold IDs for the full 12 months.
export const PROBATION_DAYS = 30;

export function bumpDaily(db, day, counter, delta = 1) {
    if (!COUNTERS.has(counter)) throw new Error(`unknown counter ${counter}`);
    db.prepare(`INSERT INTO daily_stats (day, ${counter}) VALUES (?, ?)
        ON CONFLICT(day) DO UPDATE SET ${counter} = ${counter} + excluded.${counter}`).run(day, delta);
}

// Creates the identity row on first sight and counts it once in the all-time total and in that day's new
// identities, whichever arrives first: a reservation or a check-in summary (a replica may forward either first).
function ensureIdentity(db, identityHash, day) {
    const inserted = db.prepare(`INSERT INTO identities (identity_hash, first_day, last_day) VALUES (?, ?, ?)
        ON CONFLICT(identity_hash) DO NOTHING`).run(identityHash, day, day);
    if (inserted.changes > 0) {
        metaAdd(db, 'identities_ever', 1);
        bumpDaily(db, day, 'new_identities');
    }
}

function idRow(db, identityHash) {
    return db.prepare('SELECT friends_id, first_day, last_day FROM identities WHERE identity_hash = ?')
        .get(identityHash);
}

// ADR 0005 § ID reservation, in one BEGIN IMMEDIATE transaction:
// - a key that already holds an ID gets that ID back (a reinstall that kept its key adopts it; a key holds one ID);
// - with `allowNew` false (this address has used its new IDs for the day) nothing new is granted: "unavailable";
// - otherwise the ID is granted if nobody holds it (first reservation wins), else the answer is "taken".
// The UNIQUE constraint on friends_id is the last line of defence; hitting it also means "taken".
export function reserveId(db, { identityHash, friendsId, afterCollision, day, allowNew = true }) {
    return transaction(db, () => {
        ensureIdentity(db, identityHash, day);
        const mine = idRow(db, identityHash);
        if (mine.friends_id) return { reservation: 'reserved', friendsId: mine.friends_id, granted: false };
        if (!allowNew) return { reservation: 'unavailable', friendsId: null, granted: false };
        // Syntax only (ADR 0005); a malformed ID is refused like a taken one, so the helper draws another.
        if (!validFriendsId(friendsId)) return { reservation: 'invalid', friendsId: null, granted: false };
        const holder = db.prepare('SELECT 1 AS held FROM identities WHERE friends_id = ?').get(friendsId);
        if (holder) {
            bumpDaily(db, day, 'collisions');
            return { reservation: 'taken', friendsId: null, granted: false };
        }
        db.prepare('UPDATE identities SET friends_id = ? WHERE identity_hash = ?').run(friendsId, identityHash);
        bumpDaily(db, day, 'reservations');
        if (afterCollision) bumpDaily(db, day, 'renames');
        const change = { identityHash, friendsId, firstDay: mine.first_day, lastDay: mine.last_day };
        return { reservation: 'reserved', friendsId, granted: true, change };
    });
}

// Reset Friends: deletes the identity's row, which frees whatever ID it holds. The caller has verified the
// identity's signature, so only the holder can release; the claimed ID is not needed to find the row, which keeps
// a release working for a helper whose store lost track of a rename. Idempotent: nothing to delete is success.
export function releaseId(db, { identityHash, day }) {
    return transaction(db, () => {
        const row = idRow(db, identityHash);
        const deleted = db.prepare('DELETE FROM identities WHERE identity_hash = ?').run(identityHash).changes;
        if (deleted > 0) bumpDaily(db, day, 'releases');
        // The person is gone with their ID: so are their devices and the revocations their chain carried.
        db.prepare('DELETE FROM devices WHERE identity_hash = ?').run(identityHash);
        db.prepare('DELETE FROM device_revocations WHERE identity_hash = ?').run(identityHash);
        return { released: true, hadId: Boolean(row?.friends_id) };
    });
}

// Today's salt for the active set, made on first use. Deleted with the day's rows at rollover (discardPastDays),
// after which nothing links that day's tokens to anyone.
export function daySalt(db, day) {
    db.prepare('INSERT INTO day_salts (day, salt) VALUES (?, ?) ON CONFLICT(day) DO NOTHING')
        .run(day, crypto.randomBytes(32));
    return db.prepare('SELECT salt FROM day_salts WHERE day = ?').get(day).salt;
}

// One check-in, from this host or forwarded by a replica: last-seen day and versions, and the day's unique count.
// A check-in for today (or a replica's tomorrow) goes into the day's salted active set, which deduplicates exactly.
// A replica's summary for a day whose salt is gone counts for that day only when the identity is new or its last
// check-in was before that day, the cases where it cannot already have been counted. MAX keeps such a summary from
// moving last_day backwards.
export function recordCheckin(db, { identityHash, day, today, appVersion, listVersion, protocol }) {
    return transaction(db, () => {
        const before = idRow(db, identityHash);
        ensureIdentity(db, identityHash, day);
        db.prepare(`UPDATE identities SET
                app_version = CASE WHEN ? >= last_day THEN ? ELSE app_version END,
                list_version = CASE WHEN ? >= last_day THEN ? ELSE list_version END,
                protocol = CASE WHEN ? >= last_day THEN ? ELSE protocol END,
                last_day = MAX(last_day, ?),
                first_day = MIN(first_day, ?)
            WHERE identity_hash = ?`)
            .run(day, appVersion, day, listVersion, day, protocol, day, day, identityHash);
        const hasSalt = db.prepare('SELECT 1 AS present FROM day_salts WHERE day = ?').get(day);
        if (day >= today || hasSalt) {
            const token = crypto.createHmac('sha256', daySalt(db, day)).update(identityHash).digest();
            db.prepare('INSERT INTO daily_seen (day, token) VALUES (?, ?) ON CONFLICT DO NOTHING').run(day, token);
        } else if (!before || before.last_day < day) {
            bumpDaily(db, day, 'uniques');
        }
        const after = idRow(db, identityHash);
        return { identityHash, friendsId: after.friends_id, firstDay: after.first_day, lastDay: after.last_day,
            advanced: !before || before.last_day !== after.last_day || before.first_day !== after.first_day };
    });
}

// Past days: their final unique count goes into daily_stats, then their active sets and salts are deleted.
export function discardPastDays(db, today) {
    const days = db.prepare('SELECT day FROM day_salts WHERE day < ? UNION SELECT DISTINCT day FROM daily_seen '
        + 'WHERE day < ? UNION SELECT DISTINCT day FROM daily_seen_devices WHERE day < ?').all(today, today, today)
        .map((row) => row.day);
    for (const day of days) {
        transaction(db, () => {
            rollupDay(db, day, { isToday: false });
            db.prepare('DELETE FROM daily_seen WHERE day = ?').run(day);
            db.prepare('DELETE FROM daily_seen_devices WHERE day = ?').run(day);
            db.prepare('DELETE FROM day_salts WHERE day = ?').run(day);
        });
    }
    return days.length;
}

export function recordSample(db, { minute, hostId, day, connections }) {
    db.prepare(`INSERT INTO connection_samples (minute, host_id, day, connections) VALUES (?, ?, ?, ?)
        ON CONFLICT(minute, host_id) DO UPDATE SET connections = MAX(connections, excluded.connections)`)
        .run(minute, hostId, day, connections);
}

// Recomputes a day's derived columns from the raw tables. Counters (reservations, collisions...) are bumped live
// and left alone. `reserved` and `identities` are only meaningful as of today, so past days keep what they had.
export function rollupDay(db, day, { isToday }) {
    const uniques = db.prepare('SELECT COUNT(*) AS n FROM daily_seen WHERE day = ?').get(day).n;
    const devices = db.prepare('SELECT COUNT(*) AS n FROM daily_seen_devices WHERE day = ?').get(day).n;
    const perMinute = db.prepare(`SELECT MAX(total) AS peak, AVG(total) AS average FROM
        (SELECT SUM(connections) AS total FROM connection_samples WHERE day = ? GROUP BY minute)`).get(day);
    db.prepare(`INSERT INTO daily_stats (day) VALUES (?) ON CONFLICT(day) DO NOTHING`).run(day);
    db.prepare(`UPDATE daily_stats SET uniques = MAX(uniques, ?), device_uniques = MAX(device_uniques, ?),
        peak_connections = ?, avg_connections = ? WHERE day = ?`)
        .run(uniques, devices, perMinute.peak ?? 0, perMinute.average ?? 0, day);
    if (isToday) {
        const identities = db.prepare('SELECT COUNT(*) AS n FROM identities').get().n;
        const reserved = db.prepare('SELECT COUNT(*) AS n FROM identities WHERE friends_id IS NOT NULL').get().n;
        db.prepare('UPDATE daily_stats SET identities = ?, reserved = ? WHERE day = ?').run(identities, reserved, day);
    }
}

// ADR 0005 § Statistics and retention: identities unseen for 12 months are deleted (which releases their ID); an
// ID whose identity never checked in on a later day is freed after PROBATION_DAYS of absence (the row stays for
// the statistics, and its owner reclaims the ID at a later check-in if nobody took it); connection samples are
// kept 30 days, replicas' forwarded check-in proofs 31 days, and daily aggregates indefinitely because nothing in
// them identifies anyone. `released` names every identity whose ID was freed, for the replicas' copies.
export function applyRetention(db, { today, nowMinute }) {
    return transaction(db, () => {
        const yearAgo = addMonths(today, -12);
        const probation = addDays(today, -PROBATION_DAYS);
        const released = db.prepare(`SELECT identity_hash FROM identities WHERE friends_id IS NOT NULL
            AND (last_day < ? OR (first_day = last_day AND last_day < ?))`).all(yearAgo, probation)
            .map((row) => row.identity_hash);
        const identities = db.prepare('DELETE FROM identities WHERE last_day < ?').run(yearAgo).changes;
        // Devices go with their person, or after a year unseen like any identity (device-records.js).
        db.prepare(`DELETE FROM devices WHERE last_day < ? OR identity_hash NOT IN
            (SELECT identity_hash FROM identities)`).run(yearAgo);
        const probationEnded = db.prepare(`UPDATE identities SET friends_id = NULL WHERE friends_id IS NOT NULL
            AND first_day = last_day AND last_day < ?`).run(probation).changes;
        const samples = db.prepare('DELETE FROM connection_samples WHERE minute < ?')
            .run(nowMinute - 30 * 1440).changes;
        // A summary is at most 30 days old when it arrives, so a proof older than that can no longer vouch for one.
        const proofs = db.prepare('DELETE FROM replica_proofs WHERE last_day < ?').run(addDays(today, -31)).changes;
        return { identities, probationEnded, released, samples, proofs };
    });
}

// Main host: a replica forwarded this identity's own signed check-in today. Its summaries for the identity count
// from now on (replicaForwardedProof), for as long as the row is kept.
export function recordReplicaProof(db, { replicaId, identityHash, day }) {
    db.prepare(`INSERT INTO replica_proofs (replica_id, identity_hash, last_day) VALUES (?, ?, ?)
        ON CONFLICT(replica_id, identity_hash) DO UPDATE SET last_day = MAX(last_day, excluded.last_day)`)
        .run(replicaId, identityHash, day);
}

export function replicaForwardedProof(db, { replicaId, identityHash }) {
    return Boolean(db.prepare('SELECT 1 AS present FROM replica_proofs WHERE replica_id = ? AND identity_hash = ?')
        .get(replicaId, identityHash));
}

export function storeHostList(db, { version, envelope, publishedAt }) {
    db.prepare('INSERT INTO host_lists (version, envelope, published_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING')
        .run(version, envelope, publishedAt);
}

export function latestHostList(db) {
    return db.prepare('SELECT version, envelope, published_at FROM host_lists ORDER BY version DESC LIMIT 1').get()
        ?? null;
}

export function publishedDates(db) {
    const out = new Map();
    for (const row of db.prepare('SELECT version, published_at FROM host_lists').all()) {
        out.set(row.version, row.published_at);
    }
    return out;
}

// Replica side: check-in summaries wait here while the main host is unreachable, and leave only when the main
// host acknowledges them. Bounded so a long outage cannot fill the disk; the oldest summaries go first.
const QUEUE_LIMIT = 200_000;
export function enqueueForward(db, body) {
    db.prepare('INSERT INTO forward_queue (body) VALUES (?)').run(JSON.stringify(body));
    db.prepare(`DELETE FROM forward_queue WHERE seq <= (SELECT MAX(seq) FROM forward_queue) - ?`).run(QUEUE_LIMIT);
}

export function pendingForwards(db, afterSeq, limit) {
    return db.prepare('SELECT seq, body FROM forward_queue WHERE seq > ? ORDER BY seq LIMIT ?').all(afterSeq, limit)
        .map((row) => ({ seq: row.seq, body: JSON.parse(row.body) }));
}

export function acknowledgeForwards(db, throughSeq) {
    db.prepare('DELETE FROM forward_queue WHERE seq <= ?').run(throughSeq);
}

export function queuedForwardCount(db) {
    return db.prepare('SELECT COUNT(*) AS n FROM forward_queue').get().n;
}
