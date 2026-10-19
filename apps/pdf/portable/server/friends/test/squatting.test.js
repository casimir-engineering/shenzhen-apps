// ID squatting (ADR 0005 § ID reservation, § Statistics and retention): identity keys cost nothing to make, so an
// address gets at most three new IDs a day, new identities are counted apart from unique users, and an ID whose
// identity never checks in again is freed after 30 days. Each test here failed before those rules existed.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { summarize } from '../src/stats.js';
import { DAY_MS, TestClient, identity, startMain, startPair } from './helpers.js';

const DEFAULT_CAP = { FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY: '' };

async function claim(url, who, friendsId, headers) {
    const client = await TestClient.connect(url, { headers });
    const welcome = await client.checkin(who, { friendsId });
    client.close();
    return welcome;
}

test('an address gets at most three new IDs a day; IDs already held are always given back', async (t) => {
    const { url, host, clock } = await startMain(t, { env: { ...DEFAULT_CAP, FRIENDS_TRUSTED_PROXY: '127.0.0.1' } });
    assert.equal(host.config.limits.newIdsPerAddressPerDay, 3);
    const people = Array.from({ length: 5 }, () => identity());
    const v6 = { 'X-Real-IP': '2001:db8:7:7::1' };
    assert.equal((await claim(url, people[0], 'squat-worda', v6)).reservation, 'reserved');
    // A collision does not use up the budget.
    assert.equal((await claim(url, people[1], 'squat-worda', v6)).reservation, 'taken');
    for (const [i, who] of people.slice(1, 3).entries()) {
        assert.equal((await claim(url, who, `squat-word${'bc'[i]}`, v6)).reservation, 'reserved');
    }
    const fourth = await claim(url, people[3], 'squat-wordd', { 'X-Real-IP': '2001:db8:7:7:ffff::2' });
    assert.deepEqual([fourth.reservation, fourth.friends_id], ['unavailable', null], 'same /64, fourth new ID');
    assert.equal((await claim(url, people[0], 'whatever-else', v6)).friends_id, 'squat-worda', 'a holder gets its ID');
    assert.equal((await claim(url, people[4], 'other-place', { 'X-Real-IP': '198.51.100.4' })).reservation,
        'reserved', 'another address has its own budget');
    clock.advance(DAY_MS);
    assert.equal((await claim(url, people[3], 'squat-wordd', v6)).reservation, 'reserved', 'a new day, a new budget');
});

test('a replica spends the budget for the helpers it sees, and the main host honours it', async (t) => {
    const pair = await startPair(t, { replicaEnv: DEFAULT_CAP });
    await pair.linkUp();
    for (let i = 0; i < 3; i++) {
        assert.equal((await claim(pair.replica.url, identity(), `via-replica${'abc'[i]}`)).reservation, 'reserved');
    }
    assert.equal((await claim(pair.replica.url, identity(), 'via-replicad')).reservation, 'unavailable');
    assert.equal(pair.main.host.db.prepare('SELECT COUNT(*) AS n FROM identities WHERE friends_id IS NOT NULL')
        .get().n, 3);
});

test('new identities are counted apart from unique users', async (t) => {
    const { url, host, clock } = await startMain(t, { env: { FRIENDS_DASHBOARD_PASSWORD: 'dashboard-password-x' } });
    const regular = identity();
    await claim(url, regular, 'regular-user');
    for (let i = 0; i < 4; i++) await claim(url, identity(), `throwaway${'abcd'[i]}`);
    let stats = summarize(host);
    assert.deepEqual(stats.newIdentities, { today: 5, last7Days: 5, last30Days: 5 });
    clock.advance(DAY_MS);
    await claim(url, regular, 'regular-user');
    host.tick();
    stats = summarize(host);
    assert.equal(stats.uniques.today, 1);
    assert.deepEqual(stats.newIdentities, { today: 0, last7Days: 5, last30Days: 5 });
});

test('an ID whose identity never checks in again is freed after 30 days of absence', async (t) => {
    const { url, host, clock } = await startMain(t);
    clock.set('2026-10-01T02:00:00Z');
    const once = identity();
    const twice = identity();
    await claim(url, once, 'gone-after');
    await claim(url, twice, 'stays-here');
    clock.set('2026-10-02T02:00:00Z');
    await claim(url, twice, 'stays-here');
    const holder = (id) => host.db.prepare('SELECT COUNT(*) AS n FROM identities WHERE friends_id = ?').get(id).n;
    clock.set('2026-10-31T02:00:00Z');
    host.maintenance();
    assert.equal(holder('gone-after'), 1, '30 days of absence keeps the ID');
    clock.set('2026-11-01T02:00:00Z');
    host.maintenance();
    assert.equal(holder('gone-after'), 0, 'the 31st day frees it');
    assert.equal(holder('stays-here'), 1, 'an identity that came back keeps its ID');
    assert.equal(host.db.prepare('SELECT COUNT(*) AS n FROM identities').get().n, 2, 'the rows stay for statistics');
    assert.equal((await claim(url, identity(), 'gone-after')).reservation, 'reserved');
});
