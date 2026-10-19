// ADR 0005 § Privacy: after a scripted run through a main host and a replica, including refused signatures,
// rate limiting, collisions, a release and a replica outage, no IP address, identity key or Friends ID appears in
// any log line or anywhere in the database files.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';

import crypto from 'node:crypto';

import { identityHash } from '../src/keys.js';
import { createLogger } from '../src/log.js';
import { recordCheckin } from '../src/records.js';
import {
    DAY_MS, IDENTITY_SECRET, TestClient, identity, keyPair, startMain, startPair, waitFor,
} from './helpers.js';

const IPV4 = /\b(?:\d{1,3}\.){3}\d{1,3}\b/;
const IPV6 = /(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}|::1\b|::ffff:/i;

function databaseBytes(dataDir) {
    return fs.readdirSync(dataDir).filter((name) => name.startsWith('friends.sqlite'))
        .map((name) => fs.readFileSync(path.join(dataDir, name)));
}

test('no address, identity key or Friends ID reaches the logs or the database', async (t) => {
    const pair = await startPair(t, { replicaEnv: { FRIENDS_RATE_CONNECTIONS_PER_MINUTE: '6' } });
    await pair.linkUp();
    const people = [identity(), identity(), identity()];
    const ids = ['secret-alpha', 'secret-bravo', 'secret-charlie'];
    const forwarded = { 'X-Real-IP': '198.51.100.23' };

    const a = await TestClient.connect(pair.main.url, { headers: forwarded });
    await a.checkin(people[0], { friendsId: ids[0] });
    const b = await TestClient.connect(pair.replica.url);
    assert.equal((await b.checkin(people[1], { friendsId: ids[0] })).reservation, 'taken');
    await b.reserve(ids[1]);
    const forged = await TestClient.connect(pair.replica.url);
    await forged.checkin(people[2], { friendsId: ids[2], signer: keyPair() });
    await a.release(people[0], { friendsId: ids[0] });
    for (let i = 0; i < 8; i++) {
        try {
            (await TestClient.connect(pair.replica.url)).close();
        } catch {
            // rate limited, as intended
        }
    }
    await pair.main.host.stop();
    await waitFor(() => pair.replica.host.replicaLink.state === 'down');
    pair.clock.advance(61_000);
    const c = await TestClient.connect(pair.replica.url);
    await c.checkin(people[2], { friendsId: ids[2] });
    pair.replica.host.tick();
    b.close();
    c.close();
    await pair.replica.host.stop();

    const logs = [...pair.main.logs, ...pair.replica.logs];
    assert.ok(logs.some((line) => line.includes('rate_limited')), 'the run exercised rate limiting');
    assert.ok(logs.some((line) => line.includes('checkin_refused')), 'the run exercised a refused signature');
    const secrets = [...people.flatMap((p) => [p.b64, p.raw.toString('hex')]), ...ids, '198.51.100.23'];
    for (const line of logs) {
        // The timestamp is ours and looks like hex groups; everything else in the line is checked.
        const { time, ...rest } = JSON.parse(line);
        assert.ok(time);
        const fields = JSON.stringify(rest);
        assert.doesNotMatch(fields, IPV4, line);
        assert.doesNotMatch(fields, IPV6, line);
        for (const secret of secrets) assert.ok(!line.includes(secret), `log line carries a secret: ${line}`);
    }
    for (const dataDir of [pair.main.host.config.dataDir, pair.replica.host.config.dataDir]) {
        for (const bytes of databaseBytes(dataDir)) {
            const text = bytes.toString('latin1');
            for (const literal of ['127.0.0.1', '::1', '198.51.100.23', 'ffff']) {
                assert.ok(!text.includes(literal), `database holds ${literal}`);
            }
            for (const who of people) {
                assert.equal(bytes.indexOf(who.raw), -1, 'database holds a raw identity key');
                assert.ok(!text.includes(who.b64), 'database holds an encoded identity key');
            }
        }
    }
});

test('the logger drops fields it does not know and reduces errors to their code', () => {
    const lines = [];
    const log = createLogger((line) => lines.push(line));
    log('checkin', { conn: 'abc', address: '203.0.113.9', identity_key: 'AAAA', friends_id: 'maple-river' });
    assert.deepEqual(Object.keys(JSON.parse(lines[0])).sort(), ['conn', 'event', 'time']);
});

test('identities are named by an HMAC with the fleet secret, never by a hash anyone could compute', async (t) => {
    const { url, host } = await startMain(t);
    const who = identity();
    const client = await TestClient.connect(url);
    await client.checkin(who, { friendsId: 'keyed-name' });
    client.close();
    const stored = Buffer.from(host.db.prepare('SELECT identity_hash FROM identities').get().identity_hash);
    const unkeyed = crypto.createHash('sha256').update('SZFriends identity hash v1').update(who.raw).digest();
    assert.ok(stored.equals(identityHash(IDENTITY_SECRET, who.raw)));
    assert.ok(!stored.equals(unkeyed), 'a friend who knows the key cannot find the row');
    for (const bytes of databaseBytes(host.config.dataDir)) assert.equal(bytes.indexOf(unkeyed), -1);
});

test('no table says on which days a person was online, beyond their first and last check-in', async (t) => {
    const { url, host, clock } = await startMain(t);
    const who = identity();
    const hash = identityHash(IDENTITY_SECRET, who.raw);
    clock.set('2026-10-01T02:00:00Z');
    for (let day = 0; day < 3; day++) {
        const client = await TestClient.connect(url);
        await client.checkin(who, { friendsId: 'daily-user' });
        client.close();
        host.tick();
        clock.advance(DAY_MS);
    }
    host.tick(); // 4 October: the third day's set is discarded too
    assert.deepEqual(host.db.prepare('SELECT day FROM day_salts').all().map((r) => r.day), []);
    assert.equal(host.db.prepare('SELECT COUNT(*) AS n FROM daily_seen').get().n, 0);
    const uniques = host.db.prepare("SELECT day, uniques FROM daily_stats WHERE day < '2026-10-04' ORDER BY day").all()
        .map((r) => [r.day, r.uniques]);
    assert.deepEqual(uniques, [['2026-10-01', 1], ['2026-10-02', 1], ['2026-10-03', 1]], 'the counts survive');
    const row = host.db.prepare('SELECT first_day, last_day FROM identities').get();
    assert.deepEqual([row.first_day, row.last_day], ['2026-10-01', '2026-10-03']);
    const client = await TestClient.connect(url);
    await client.checkin(who, { friendsId: 'daily-user' });
    client.close();
    const token = Buffer.from(host.db.prepare('SELECT token FROM daily_seen').get().token);
    assert.ok(!token.equals(hash), 'today\'s set holds a salted token, not the identity');
});

test('a replica\'s late summary for a past day counts only when it cannot have been counted already', (t) => {
    return startMain(t).then(({ host }) => {
        const hash = crypto.randomBytes(32);
        const summary = { identityHash: hash, appVersion: '26.10.12-1', listVersion: 1, protocol: 1,
            today: '2026-10-12' };
        const uniques = (day) => host.db.prepare('SELECT uniques FROM daily_stats WHERE day = ?').get(day)?.uniques;
        recordCheckin(host.db, { ...summary, day: '2026-10-09' });
        assert.equal(uniques('2026-10-09'), 1, 'a new identity');
        recordCheckin(host.db, { ...summary, day: '2026-10-10' });
        recordCheckin(host.db, { ...summary, day: '2026-10-10' });
        assert.equal(uniques('2026-10-10'), 1, 'counted once');
        recordCheckin(host.db, { ...summary, day: '2026-10-09' });
        assert.equal(uniques('2026-10-09'), 1, 'already seen later, so not again');
    });
});

test('a database refuses an identity secret other than the one it was written with', async (t) => {
    const first = await startMain(t);
    const { dir, admin, hostKey } = first;
    await first.host.stop();
    await assert.rejects(startMain(t, { dataDir: dir, admin, hostKey,
        env: { FRIENDS_IDENTITY_SECRET: 'a-different-identity-secret-0123456789' } }), /FRIENDS_IDENTITY_SECRET/);
    await assert.rejects(startMain(t, { env: { FRIENDS_IDENTITY_SECRET: 'short' } }), /FRIENDS_IDENTITY_SECRET/);
});
