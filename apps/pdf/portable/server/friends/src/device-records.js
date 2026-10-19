// What the host writes about people's devices (db.js schema 6; HOST-PROTOCOL.md § Devices), and nothing else: each
// device by a keyed hash of its key, under the person it belongs to, with its first and last check-in day; today's
// salted set of devices, like the people's (records.js); and the revocations seen in people's chains, by the hash of
// the revoking link, so a device revoked once cannot check in again with a chain from before its revocation. No
// device name, system, key or chain is stored.

import crypto from 'node:crypto';

import { addMonths } from './clock.js';
import { transaction } from './db.js';
import { bumpDaily, daySalt } from './records.js';

const DEVICE_TOKEN = Buffer.from('SZFriends device token v1', 'utf8');

// One device's check-in for `day`, counted once in today's devices. A device first seen under a person whose key it
// is not (any device but the first) is a join, counted on that day. Returns whether it was new.
export function recordDevice(db, { identityHash, deviceHash, day, today }) {
    return transaction(db, () => {
        const inserted = db.prepare(`INSERT INTO devices (device_hash, identity_hash, first_day, last_day)
            VALUES (?, ?, ?, ?) ON CONFLICT(device_hash) DO NOTHING`).run(deviceHash, identityHash, day, day).changes;
        if (inserted === 0) {
            db.prepare(`UPDATE devices SET last_day = MAX(last_day, ?), first_day = MIN(first_day, ?),
                identity_hash = ? WHERE device_hash = ?`).run(day, day, identityHash, deviceHash);
        } else if (!Buffer.from(deviceHash).equals(Buffer.from(identityHash))) {
            bumpDaily(db, day, 'joins');
        }
        const hasSalt = db.prepare('SELECT 1 AS present FROM day_salts WHERE day = ?').get(day);
        if (day >= today || hasSalt) {
            const token = crypto.createHmac('sha256', daySalt(db, day)).update(DEVICE_TOKEN).update(deviceHash)
                .digest();
            db.prepare('INSERT INTO daily_seen_devices (day, token) VALUES (?, ?) ON CONFLICT DO NOTHING')
                .run(day, token);
        }
        return inserted > 0;
    });
}

// The revoking link's hash the host holds for this device of this person, or null.
export function revocationFor(db, { identityHash, deviceHash }) {
    const row = db.prepare('SELECT link_hash FROM device_revocations WHERE identity_hash = ? AND device_hash = ?')
        .get(identityHash, deviceHash);
    return row ? Buffer.from(row.link_hash) : null;
}

export function forgetRevocation(db, { identityHash, deviceHash }) {
    db.prepare('DELETE FROM device_revocations WHERE identity_hash = ? AND device_hash = ?')
        .run(identityHash, deviceHash);
}

// Every revocation a verified chain carries: `revoked` is [{ deviceHash, linkHash }]. New ones are counted for `day`
// when `count` is set (the main host keeps the statistics). Returns the device hashes revoked for the first time.
export function noteRevocations(db, { identityHash, revoked, day, count }) {
    return transaction(db, () => {
        const fresh = [];
        for (const { deviceHash, linkHash } of revoked) {
            const inserted = db.prepare(`INSERT INTO device_revocations (identity_hash, device_hash, link_hash,
                last_day) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`).run(identityHash, deviceHash, linkHash, day)
                .changes;
            if (inserted > 0) {
                fresh.push(deviceHash);
                if (count) bumpDaily(db, day, 'revocations');
            } else {
                db.prepare(`UPDATE device_revocations SET last_day = MAX(last_day, ?)
                    WHERE identity_hash = ? AND device_hash = ?`).run(day, identityHash, deviceHash);
            }
        }
        return fresh;
    });
}

// A revocation no chain has carried for a year is forgotten, on every host (the main host also drops the rows of a
// person it no longer knows, with their ID).
export function expireRevocations(db, today) {
    return db.prepare('DELETE FROM device_revocations WHERE last_day < ?').run(addMonths(today, -12)).changes;
}

// Devices per person over people seen in the window, and how many people have 1, 2, 3 or 4 and more.
export function devicesPerPerson(db, fromDay) {
    const rows = db.prepare(`SELECT COUNT(*) AS n FROM devices WHERE last_day >= ? GROUP BY identity_hash`)
        .all(fromDay);
    const buckets = [0, 0, 0, 0];
    let devices = 0;
    for (const { n } of rows) {
        devices += n;
        buckets[Math.min(n, 4) - 1] += 1;
    }
    return { people: rows.length, devices, average: rows.length > 0 ? devices / rows.length : 0,
        one: buckets[0], two: buckets[1], three: buckets[2], fourOrMore: buckets[3] };
}
