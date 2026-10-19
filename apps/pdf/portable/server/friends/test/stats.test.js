// Statistics (brief § Admin statistics, ADR 0005 § Statistics and retention) against a scripted population on
// a main host and a replica with one fake clock: relaunches, crashes and two hosts must give exact unique counts,
// adoption shares and app versions; retention must drop identities at 12 months and active sets at 31 days.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { recordSample, rollupDay } from '../src/records.js';
import { summarize } from '../src/stats.js';
import { DAY_MS, TestClient, identity, startPair, waitFor } from './helpers.js';

const OLD_APP = '26.9.1-1';
const MID_APP = '26.10.1-1';
const NEW_APP = '26.10.12-1';

async function launch(url, who, options) {
    const client = await TestClient.connect(url);
    const welcome = await client.checkin(who, options);
    assert.equal(welcome.type, 'welcome');
    return client;
}

function count(host, sql, ...args) {
    return host.db.prepare(sql).get(...args).n;
}

test('a scripted population gives exact uniques, adoption and app versions across two hosts', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const { main, replica, clock } = pair;
    const people = Object.fromEntries('ABCDEFG'.split('').map((name) => [name, identity()]));
    const ids = Object.fromEntries('ABCDEFG'.split('').map((name) => [name, `person-${name.toLowerCase()}aa`]));
    const day = (who, host, listVersion, appVersion) => launch(host.url, people[who],
        { friendsId: ids[who], listVersion, appVersion });

    clock.set('2026-10-01T02:00:00Z'); // 10:00 in Hong Kong
    for (let i = 0; i < 3; i++) (await day('A', main, 1, OLD_APP)).close(); // quits and relaunches
    (await day('B', main, 1, OLD_APP)).terminate(); // crashes
    (await day('B', main, 1, OLD_APP)).close();
    (await day('C', main, 1, OLD_APP)).close();

    clock.set('2026-10-02T02:00:00Z');
    (await day('A', replica, 2, MID_APP)).close();
    (await day('D', replica, 2, MID_APP)).close();
    (await day('E', main, 2, MID_APP)).close();

    clock.set('2026-10-15T02:00:00Z');
    (await day('B', main, 2, MID_APP)).close();

    clock.set('2026-10-30T02:00:00Z');
    const stillOpen = [await day('F', main, 2, NEW_APP), await day('G', replica, 1, OLD_APP),
        await day('A', main, 2, NEW_APP)];
    await waitFor(() => replica.host.db.prepare('SELECT COUNT(*) AS n FROM forward_queue').get().n === 0);

    const stats = summarize(main.host);
    assert.equal(stats.today, '2026-10-30');
    assert.deepEqual(stats.uniques, { today: 3, last7Days: 3, last30Days: 7, allTime: 7 });
    assert.equal(stats.lists.actives, 7);
    const adoption = Object.fromEntries(stats.lists.rows.map((r) => [r.version, [r.users, Math.round(r.share * 100)]]));
    assert.deepEqual(adoption, { 2: [5, 71], 1: [2, 29] });
    assert.deepEqual(stats.appVersions.map((v) => [v.version, v.users]), [[MID_APP, 3], [NEW_APP, 2], [OLD_APP, 2]]);
    assert.equal(stats.ids.reserved, 7);
    assert.equal(stats.online.now, 2, 'the replica has not reported yet, so only the main host counts');
    replica.host.tick();
    await waitFor(() => summarize(main.host).online.now === 3);

    clock.advance(DAY_MS); // 31 October: C's only day falls out of the 30-day window
    assert.equal(summarize(main.host).uniques.last30Days, 6);
    for (const c of stillOpen) c.close();
});

test('retention removes identities after 12 months and past active sets, keeping daily totals',
    async (t) => {
        const pair = await startPair(t);
        const { main, clock } = pair;
        clock.set('2026-10-01T02:00:00Z');
        const early = identity();
        (await launch(main.url, early, { friendsId: 'early-bird' })).close();
        main.host.tick();
        clock.set('2026-11-20T02:00:00Z');
        const later = identity();
        (await launch(main.url, later, { friendsId: 'late-owl' })).close();
        main.host.maintenance();
        assert.equal(count(main.host, "SELECT COUNT(*) AS n FROM daily_seen WHERE day = '2026-10-01'"), 0,
            'past days keep no active set');
        assert.equal(count(main.host, 'SELECT COUNT(*) AS n FROM connection_samples WHERE day = ?', '2026-10-01'), 0);
        assert.equal(count(main.host, 'SELECT COUNT(*) AS n FROM identities'), 2);

        clock.set('2027-10-01T02:00:00Z');
        main.host.maintenance();
        assert.equal(count(main.host, 'SELECT COUNT(*) AS n FROM identities'), 2, 'twelve months to the day stays');
        clock.set('2027-10-02T02:00:00Z');
        main.host.maintenance();
        assert.equal(count(main.host, 'SELECT COUNT(*) AS n FROM identities'), 1);
        assert.equal(count(main.host, 'SELECT uniques AS n FROM daily_stats WHERE day = ?', '2026-10-01'), 1,
            'daily totals are kept');
        (await launch(main.url, identity(), { friendsId: 'early-bird' })).close();
        assert.equal(count(main.host, "SELECT COUNT(*) AS n FROM identities WHERE friends_id = 'early-bird'"), 1,
            'the expired ID was released for someone new');
    });

test('peak and average connections per day sum the hosts minute by minute', async (t) => {
    const pair = await startPair(t);
    const { db } = pair.main.host;
    const day = '2026-10-12';
    recordSample(db, { minute: 1000, hostId: 'main-hk', day, connections: 3 });
    recordSample(db, { minute: 1000, hostId: 'alt-sg', day, connections: 2 });
    recordSample(db, { minute: 1001, hostId: 'main-hk', day, connections: 1 });
    rollupDay(db, day, { isToday: false });
    const row = db.prepare('SELECT peak_connections, avg_connections FROM daily_stats WHERE day = ?').get(day);
    assert.deepEqual({ ...row }, { peak_connections: 5, avg_connections: 3 });
});

test('the last 24 hours show the peak per hour, ending with the current hour', async (t) => {
    const pair = await startPair(t);
    const { main, clock } = pair;
    clock.set('2026-10-12T06:47:48Z'); // 14:47 in Hong Kong
    const nowMinute = Math.floor(clock.now() / 60_000);
    const { db } = main.host;
    recordSample(db, { minute: nowMinute, hostId: 'main-hk', day: '2026-10-12', connections: 2 });
    recordSample(db, { minute: nowMinute - 90, hostId: 'main-hk', day: '2026-10-12', connections: 4 });
    recordSample(db, { minute: nowMinute - 91, hostId: 'main-hk', day: '2026-10-12', connections: 6 });
    recordSample(db, { minute: nowMinute - 25 * 60, hostId: 'main-hk', day: '2026-10-11', connections: 99 });
    const hours = summarize(main.host).online.last24Hours;
    assert.equal(hours.length, 24);
    assert.deepEqual(hours.at(-1), { label: '14:00', value: 2 });
    assert.deepEqual(hours.at(-2), { label: '13:00', value: 6 }, '13:16 and 13:17 share an hour; the peak wins');
    assert.deepEqual(hours.at(-3), { label: '12:00', value: 0 });
    assert.equal(hours[0].label, '15:00');
    assert.ok(hours.every((h) => h.value !== 99));
});

test('ID occupancy counts two-word IDs against the three-word line', async (t) => {
    const pair = await startPair(t);
    const { main } = pair;
    (await launch(main.url, identity(), { friendsId: 'two-words' })).close();
    (await launch(main.url, identity(), { friendsId: 'now-three-words' })).close();
    const { ids } = summarize(main.host);
    assert.equal(ids.reserved, 2);
    assert.equal(ids.twoWord, 1);
    assert.equal(ids.threshold, 131072);
    assert.equal(ids.twoWordShare, 1 / 4194304);
});
