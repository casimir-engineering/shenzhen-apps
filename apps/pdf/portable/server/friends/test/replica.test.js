// Replicas (ADR 0005 § Replicas): a main host and a replica on loopback. The replica forwards reservations and
// releases to the main host, never allocates, answers "unavailable" while the main host is down, queues check-in
// summaries until they are acknowledged, and passes new lists on to its own helpers.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { summarize } from '../src/stats.js';
import {
    DAY_MS, TestClient, identity, keyPair, listPayload, openLink, signList, startHost, startPair, waitFor,
} from './helpers.js';

test('a check-in through the replica reserves the ID on the main host', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    assert.equal(pair.replica.host.isMain, false);
    const client = await TestClient.connect(pair.replica.url);
    const welcome = await client.checkin(identity(), { friendsId: 'river-stone', listVersion: 2 });
    assert.equal(welcome.reservation, 'reserved');
    assert.equal(welcome.friends_id, 'river-stone');
    const row = pair.main.host.db.prepare('SELECT friends_id FROM identities').get();
    assert.equal(row.friends_id, 'river-stone');
    await waitFor(() => pair.main.host.db.prepare('SELECT COUNT(*) AS n FROM daily_seen').get().n === 1);
    client.close();
});

test('one ID raced through both hosts is granted once', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    for (let round = 0; round < 10; round++) {
        const id = `race-word${'abcdefghij'[round]}`;
        const viaMain = await TestClient.connect(pair.main.url);
        const viaReplica = await TestClient.connect(pair.replica.url);
        await Promise.all([viaMain.challenge(), viaReplica.challenge()]);
        const replies = await Promise.all([viaMain.checkin(identity(), { friendsId: id }),
            viaReplica.checkin(identity(), { friendsId: id })]);
        assert.deepEqual(replies.map((r) => r.reservation).sort(), ['reserved', 'taken'], id);
        viaMain.close();
        viaReplica.close();
    }
});

test('a collision through the replica is renamed by the main host', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const holder = await TestClient.connect(pair.main.url);
    await holder.checkin(identity(), { friendsId: 'maple-river' });
    const newcomer = await TestClient.connect(pair.replica.url);
    assert.equal((await newcomer.checkin(identity(), { friendsId: 'maple-river' })).reservation, 'taken');
    assert.equal((await newcomer.reserve('maple-harbor')).reservation, 'reserved');
    const day = pair.main.host.db.prepare('SELECT renames, collisions FROM daily_stats WHERE day = ?')
        .get(pair.main.host.today());
    assert.deepEqual({ ...day }, { renames: 1, collisions: 1 });
    holder.close();
    newcomer.close();
});

test('with the main host down the replica answers unavailable and counts the check-ins later', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const port = pair.main.port;
    const dataDir = pair.main.dir;
    // A regular of this replica: the main host has seen their own signed check-in through it, so their summaries
    // from the outage count. A newcomer's do not (host-links.js), and their ID waits for the main host.
    const regular = identity();
    const first = await TestClient.connect(pair.replica.url);
    assert.equal((await first.checkin(regular, { friendsId: 'steady-pine' })).reservation, 'reserved');
    first.close();
    await waitFor(() => pair.replica.host.db.prepare('SELECT COUNT(*) AS n FROM forward_queue').get().n === 0);
    await pair.main.host.stop();
    await waitFor(() => pair.replica.host.replicaLink.state === 'down');
    pair.clock.advance(DAY_MS);
    const newcomer = identity();
    for (const [who, friendsId] of [[regular, 'steady-pine'], [newcomer, 'lonely-pine']]) {
        const client = await TestClient.connect(pair.replica.url);
        const welcome = await client.checkin(who, { friendsId });
        assert.deepEqual([welcome.reservation, welcome.friends_id], ['unavailable', null]);
        client.close();
    }
    assert.equal(pair.replica.host.db.prepare('SELECT COUNT(*) AS n FROM forward_queue').get().n, 2);
    const restarted = await startHost(t, { hostId: 'main-hk', hostKey: pair.mainKey, pinned: [pair.admin],
        clock: pair.clock, dataDir, env: { FRIENDS_LISTEN_PORT: String(port) } });
    await waitFor(() => restarted.host.hostLinks.has('alt-sg'), { timeoutMs: 9000 });
    await waitFor(() => pair.replica.host.db.prepare('SELECT COUNT(*) AS n FROM forward_queue').get().n === 0);
    const today = restarted.host.today();
    assert.equal(restarted.host.db.prepare('SELECT COUNT(*) AS n FROM daily_seen WHERE day = ?').get(today).n, 1,
        'the regular counts for the outage day; the newcomer does not');
    const again = await TestClient.connect(pair.replica.url);
    assert.equal((await again.checkin(newcomer, { friendsId: 'lonely-pine' })).reservation, 'reserved');
    again.close();
});

test('a replica with the wrong secret or an unlisted key is refused and never allocates', async (t) => {
    const pair = await startPair(t, { replicaEnv: { FRIENDS_REPLICA_SECRET: 'some-other-secret-0123456789abcdef' } });
    await waitFor(() => pair.main.logs.some((line) => line.includes('"host_link"') && line.includes('refused')));
    assert.equal(pair.main.host.hostLinks.size, 0);
    const client = await TestClient.connect(pair.replica.url);
    assert.equal((await client.checkin(identity())).reservation, 'unavailable');
    client.close();
    assert.equal(pair.main.host.db.prepare('SELECT COUNT(*) AS n FROM identities').get().n, 0);
    // A key the list does not give alt-sg, and an identity secret other than the fleet's, are refused the same way.
    for (const options of [{ replicaKey: keyPair() },
        { replicaKey: pair.replicaKey, identitySecret: 'another-identity-secret-0123456789abc' }]) {
        const link = await openLink(pair.main.url, options);
        assert.equal(link.welcome.code, 'bad_signature');
        assert.equal((await link.closed).code, 1008);
    }
    assert.equal(pair.main.host.hostLinks.size, 0);
});

test('a replica whose host key is not the one its list names does not start', async (t) => {
    await assert.rejects(startPair(t, { listedReplicaKey: keyPair() }), /FRIENDS_HOST_KEY_FILE/);
});

test('a release through the replica frees the ID on the main host', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const who = identity();
    const client = await TestClient.connect(pair.replica.url);
    await client.checkin(who, { friendsId: 'brief-visit' });
    assert.equal((await client.release(who, { friendsId: 'brief-visit' })).released, true);
    assert.equal(pair.main.host.db.prepare('SELECT COUNT(*) AS n FROM identities').get().n, 0);
});

test('a list published on the main host reaches the replica and its helpers', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const client = await TestClient.connect(pair.replica.url);
    await client.checkin(identity(), { listVersion: 2 });
    const v3 = signList(listPayload({ version: 3, entries: pair.entries(pair.main.port) }), [pair.admin]);
    assert.equal(pair.main.host.offerList(v3, { source: 'admin' }).ok, true);
    const pushed = await client.expect('host_list', 3000);
    assert.equal(JSON.parse(Buffer.from(pushed.host_list.payload, 'base64url')).version, 3);
    assert.equal(pair.replica.host.list.version, 3);
    client.close();
});

test('a list that makes the replica the main host turns it into the allocator', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const promoted = pair.entries(pair.main.port).map((e) => ({ ...e, priority: e.id === 'alt-sg' ? 1 : 2 }));
    const v3 = signList(listPayload({ version: 3, entries: promoted }), [pair.admin]);
    assert.equal(pair.main.host.offerList(v3, { source: 'admin' }).ok, true);
    await waitFor(() => pair.replica.host.isMain && !pair.main.host.isMain);
    const client = await TestClient.connect(pair.replica.url);
    assert.equal((await client.checkin(identity(), { friendsId: 'new-boss' })).reservation, 'reserved');
    client.close();
});

test('online now counts helpers on every host from the replicas\' reports', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const onMain = await TestClient.connect(pair.main.url);
    await onMain.checkin(identity(), { friendsId: 'here-one', listVersion: 2 });
    const onReplica = await Promise.all([TestClient.connect(pair.replica.url), TestClient.connect(pair.replica.url)]);
    await onReplica[0].checkin(identity(), { friendsId: 'there-one', listVersion: 2 });
    await onReplica[1].checkin(identity(), { friendsId: 'there-two', listVersion: 1 });
    pair.replica.host.tick();
    await waitFor(() => pair.main.host.replicaReports.has('alt-sg'));
    const stats = summarize(pair.main.host);
    assert.equal(stats.online.now, 3);
    assert.deepEqual(stats.online.hosts.map((h) => [h.id, h.connections, h.status]),
        [['main-hk', 1, 'this_host'], ['alt-sg', 2, 'reporting']]);
    const byVersion = Object.fromEntries(stats.lists.rows.map((r) => [r.version, r.online]));
    assert.deepEqual(byVersion, { 2: 2, 1: 1 });
    pair.clock.advance(4 * 60_000);
    assert.equal(summarize(pair.main.host).online.now, 1, 'a silent replica stops counting');
    onMain.close();
    for (const c of onReplica) c.close();
});
