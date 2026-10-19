// The main host's Friends ID table, copied to every replica (ADR 0005 § Replicas, HOST-PROTOCOL.md § Host links).
// Without a copy, a replica promoted to main host would allocate from an empty table and hand anyone's ID to the
// first claimant. The main host sends the whole table when a replica links, in pages, and then every grant,
// release and change of an ID holder's check-in days as it happens. Messages on one link arrive in order and each
// page is read when it is sent, so applying everything in order leaves the replica with the main host's table.
//
// What a host's table may be used for is recorded in settings.id_table:
// - 'authoritative': this host allocated IDs as the main host (or started as the first main host on an empty
//   database). Its table is the reference until another main host's copy replaces it.
// - 'synced': a complete copy from an allocating main host, kept current by its pushes since.
// - 'unsynced': a replica that has never finished a copy. Made the main host in this state it answers
//   "unavailable" to reservations, unless the admin sets FRIENDS_ALLOW_UNSYNCED_MAIN=1 (DEPLOY.md).
// Only an authoritative main host sends its table, so an unsynced one can never overwrite a good copy.

import { validDay } from './clock.js';
import { settingGet, settingSet, transaction } from './db.js';
import { decodeBase64url, encodeBase64url } from './keys.js';
import { validFriendsId } from './protocol.js';

// About 41 KB of JSON per page, under the 64 KiB host-link message limit with three-word IDs.
export const PAGE_ROWS = 400;
// A slow replica must not make the main host buffer the whole table in memory.
const MAX_BUFFERED_BYTES = 1024 * 1024;

export function idTableState(db) {
    return settingGet(db, 'id_table');
}

// Called whenever a list sets this host's role. A fresh database on the main host is the first deployment; a
// fresh database on a replica has nothing yet. Promotion keeps a synced copy, which becomes the reference.
export function settleIdTable(db, { isMain, allowUnsynced }) {
    const state = idTableState(db);
    if (isMain && (state === null || state === 'synced' || (state === 'unsynced' && allowUnsynced))) {
        settingSet(db, 'id_table', 'authoritative');
        return 'authoritative';
    }
    if (!isMain && state === null) {
        settingSet(db, 'id_table', 'unsynced');
        return 'unsynced';
    }
    return state;
}

export function canAllocate(db) {
    return idTableState(db) === 'authoritative';
}

function encodeRow(row) {
    return [encodeBase64url(row.identity_hash), row.friends_id, row.first_day, row.last_day];
}

// Main host side, one per replica link.
export class IdTableSender {
    constructor(host, link) {
        this.host = host;
        this.link = link;
        this.running = false;
        this.cursor = Buffer.alloc(0);
    }

    start() {
        if (!canAllocate(this.host.db)) return;
        this.running = true;
        this.cursor = Buffer.alloc(0);
        this.link.send('id_sync_begin', {});
        this.nextPage();
    }

    stop() {
        this.running = false;
        clearTimeout(this.wait);
    }

    nextPage() {
        if (!this.running || !this.host.db) return;
        const { ws } = this.link.session;
        if (ws.readyState !== ws.OPEN) {
            this.running = false;
            return;
        }
        if (ws.bufferedAmount > MAX_BUFFERED_BYTES) {
            this.wait = setTimeout(() => this.nextPage(), 50);
            return;
        }
        const rows = this.host.db.prepare(`SELECT identity_hash, friends_id, first_day, last_day FROM identities
            WHERE friends_id IS NOT NULL AND identity_hash > ? ORDER BY identity_hash LIMIT ?`)
            .all(this.cursor, PAGE_ROWS);
        if (rows.length > 0) {
            this.link.send('id_sync_page', { rows: rows.map(encodeRow) });
            this.cursor = rows[rows.length - 1].identity_hash;
        }
        if (rows.length < PAGE_ROWS) {
            this.running = false;
            this.link.send('id_sync_end', {});
            return;
        }
        setImmediate(() => this.nextPage());
    }

    // `change` is {identityHash, friendsId, firstDay, lastDay} for an ID holder, or {identityHash, unset: true}.
    push(change) {
        if (!canAllocate(this.host.db)) return;
        const identityHash = encodeBase64url(change.identityHash);
        if (change.unset) this.link.send('id_unset', { identity_hash: identityHash });
        else {
            this.link.send('id_set', { identity_hash: identityHash, friends_id: change.friendsId,
                first_day: change.firstDay, last_day: change.lastDay });
        }
    }
}

function decodeRow(value) {
    if (!Array.isArray(value) || value.length !== 4) return null;
    const [hash, friendsId, firstDay, lastDay] = value;
    const identityHash = decodeBase64url(hash, 32);
    if (!identityHash || !validFriendsId(friendsId) || !validDay(firstDay) || !validDay(lastDay)) return null;
    return { identityHash, friendsId, firstDay, lastDay };
}

// One ID per identity and one identity per ID: a row naming either replaces whatever held them before.
function upsert(db, table, row) {
    db.prepare(`DELETE FROM ${table} WHERE friends_id = ? AND identity_hash != ?`).run(row.friendsId, row.identityHash);
    db.prepare(`INSERT INTO ${table} (identity_hash, friends_id, first_day, last_day) VALUES (?, ?, ?, ?)
        ON CONFLICT(identity_hash) DO UPDATE SET friends_id = excluded.friends_id, first_day = excluded.first_day,
        last_day = excluded.last_day`).run(row.identityHash, row.friendsId, row.firstDay, row.lastDay);
}

// Replica side. While a copy is in flight, pages and pushes go to id_staging, which replaces the table at the end;
// pushes also go to the table itself, so a copy that never finishes still leaves the previous one current.
export class IdTableReceiver {
    constructor(host) {
        this.host = host;
        this.syncing = false;
    }

    reset() {
        this.syncing = false;
    }

    handle(msg) {
        const { db } = this.host;
        switch (msg.type) {
        case 'id_sync_begin':
            db.exec('DELETE FROM id_staging');
            this.syncing = true;
            return true;
        case 'id_sync_page':
            if (this.syncing && Array.isArray(msg.rows)) {
                const rows = msg.rows.slice(0, PAGE_ROWS).map(decodeRow).filter(Boolean);
                transaction(db, () => rows.forEach((row) => upsert(db, 'id_staging', row)));
            }
            return true;
        case 'id_sync_end':
            if (this.syncing) this.finish();
            return true;
        case 'id_set': {
            const row = decodeRow([msg.identity_hash, msg.friends_id, msg.first_day, msg.last_day]);
            if (row) {
                transaction(db, () => {
                    upsert(db, 'identities', row);
                    if (this.syncing) upsert(db, 'id_staging', row);
                });
            }
            return true;
        }
        case 'id_unset': {
            const identityHash = decodeBase64url(msg.identity_hash, 32);
            if (identityHash) {
                db.prepare('DELETE FROM identities WHERE identity_hash = ?').run(identityHash);
                db.prepare('DELETE FROM id_staging WHERE identity_hash = ?').run(identityHash);
            }
            return true;
        }
        default:
            return false;
        }
    }

    finish() {
        const { db } = this.host;
        const count = transaction(db, () => {
            db.exec(`DELETE FROM identities;
                INSERT INTO identities (identity_hash, friends_id, first_day, last_day)
                    SELECT identity_hash, friends_id, first_day, last_day FROM id_staging;
                DELETE FROM id_staging;`);
            settingSet(db, 'id_table', 'synced');
            return db.prepare('SELECT COUNT(*) AS n FROM identities').get().n;
        });
        this.syncing = false;
        this.host.log('id_table', { state: 'synced', count });
    }
}
