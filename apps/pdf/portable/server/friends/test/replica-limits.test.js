// What a compromised replica can do at the main host (HOST-PROTOCOL.md § Host links). A replica holds its host key and
// both secrets, so it can make up identity keys and sign check-ins for them over its own challenges. The main host
// therefore caps the new IDs it grants through each replica per day and says so on the dashboard, and counts a
// replica's check-in summaries only for identities whose own signed check-in that replica forwarded. Before, a
// replica could squat free IDs as fast as it liked and keep any identity's row alive with made-up summaries; each
// test here failed then.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { renderDashboard } from '../src/dashboard-page.js';
import { encodeBase64url, identityHash, signEd25519 } from '../src/keys.js';
import { checkinSignedBytes } from '../src/protocol.js';
import { summarize } from '../src/stats.js';
import {
    DAY_MS, IDENTITY_SECRET, TestClient, identity, keyPair, listPayload, openLink, signList, startHost, startPair,
} from './helpers.js';

async function claim(url, who, friendsId) {
    const client = await TestClient.connect(url);
    const welcome = await client.checkin(who, { friendsId, listVersion: 2 });
    client.close();
    return welcome.reservation;
}

test('new IDs granted through one replica are capped per day, and the dashboard says so', async (t) => {
    const pair = await startPair(t, { mainEnv: { FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY: '2' } });
    await pair.linkUp();
    const { main, replica, clock } = pair;
    const people = Array.from({ length: 3 }, () => identity());
    assert.equal(await claim(replica.url, people[0], 'first-pick'), 'reserved');
    assert.equal(await claim(replica.url, people[1], 'second-pick'), 'reserved');
    assert.equal(await claim(replica.url, people[2], 'third-pick'), 'unavailable', 'the third new ID waits');
    assert.equal(await claim(replica.url, people[0], 'first-pick'), 'reserved', 'a holder always gets its ID back');
    assert.equal(await claim(main.url, identity(), 'direct-pick'), 'reserved', 'the main host\'s own helpers are not '
        + 'limited by a replica\'s budget');
    assert.ok(main.logs.some((line) => line.includes('"replica_limit"') && line.includes('alt-sg')));

    const stats = summarize(main.host);
    assert.deepEqual(stats.replicaNewIds, { limit: 2, atLimit: [{ id: 'alt-sg', granted: 2 }] });
    assert.match(renderDashboard(stats), /alt-sg reached today's limit of 2 new Friends\s+IDs/);

    clock.advance(DAY_MS);
    main.host.tick();
    assert.equal(await claim(replica.url, people[2], 'third-pick'), 'reserved', 'a new day, a new budget');
    assert.deepEqual(summarize(main.host).replicaNewIds.atLimit, []);
    assert.doesNotMatch(renderDashboard(summarize(main.host)), /reached today's limit/);
});

test('the default is 200 new IDs per replica per day', async (t) => {
    const pair = await startPair(t);
    assert.equal(pair.main.host.config.limits.newIdsPerReplicaPerDay, 200);
});

// A check-in proof as a replica forwards it: the helper's own signature over the replica's challenge.
function proofFor(who, friendsId) {
    const challenge = crypto.randomBytes(32);
    const fields = { hostId: 'alt-sg', challenge, identityKey: who.raw, friendsId, reserved: false,
        appVersion: '26.10.12-1', protocol: 1, listVersion: 1 };
    return { host_id: 'alt-sg', challenge: encodeBase64url(challenge), identity_key: who.b64, friends_id: friendsId,
        reserved: false, app_version: '26.10.12-1', protocol: 1, list_version: 1,
        sig: encodeBase64url(signEd25519(who.privateKey, checkinSignedBytes(fields))) };
}

async function nextOf(link, type) {
    for (;;) {
        const msg = await link.linkNext();
        if (msg.type === type) return msg;
    }
}

test('a replica\'s summaries count only for identities whose own check-in it forwarded', async (t) => {
    const admin = keyPair();
    const mainKey = keyPair();
    const replicaKey = keyPair();
    // No replica runs: the test holds alt-sg's key and secrets, as a compromised replica would.
    const entries = [{ id: 'main-hk', key: mainKey, priority: 1, role: 'both' },
        { id: 'alt-sg', key: replicaKey, priority: 2 }];
    const { host, url, clock, logs } = await startHost(t, { hostId: 'main-hk', hostKey: mainKey, pinned: [admin],
        listText: signList(listPayload({ version: 1, entries }), [admin]) });
    const link = await openLink(url, { replicaKey });
    assert.equal(link.welcome.type, 'host_welcome');
    const someone = identity();
    const summary = (who, seq) => ({ seq, identity_hash: encodeBase64url(identityHash(IDENTITY_SECRET, who.raw)),
        day: host.today(), app_version: '26.10.12-1', list_version: 1, protocol: 1 });
    const rowsFor = (who) => host.db.prepare('SELECT COUNT(*) AS n FROM identities WHERE identity_hash = ?')
        .get(identityHash(IDENTITY_SECRET, who.raw)).n;
    const seenToday = () => host.db.prepare('SELECT COUNT(*) AS n FROM daily_seen').get().n;

    link.linkSend('fwd_summaries', { items: [summary(someone, 1)] });
    assert.equal((await nextOf(link, 'ack')).through, 1, 'acknowledged, so the replica does not resend it');
    assert.equal(rowsFor(someone), 0, 'no row for an identity this replica never vouched for');
    assert.equal(seenToday(), 0);
    assert.ok(logs.some((line) => line.includes('"forward_refused"') && line.includes('"summary"')));

    link.linkSend('fwd_reserve', { req: 1, friends_id: 'came-through', after_collision: false, allow_new: true,
        proof: proofFor(someone, 'came-through') });
    assert.equal((await nextOf(link, 'fwd_reserve_result')).reservation, 'reserved');
    link.linkSend('fwd_summaries', { items: [summary(someone, 2)] });
    await nextOf(link, 'ack');
    assert.equal(seenToday(), 1, 'counted once its own check-in came through this replica');

    // Forwarded proofs are kept 31 days, the oldest a summary may be.
    clock.advance(32 * DAY_MS);
    host.maintenance();
    const before = host.db.prepare('SELECT last_day FROM identities WHERE identity_hash = ?')
        .get(identityHash(IDENTITY_SECRET, someone.raw)).last_day;
    link.linkSend('fwd_summaries', { items: [summary(someone, 3)] });
    await nextOf(link, 'ack');
    const after = host.db.prepare('SELECT last_day FROM identities WHERE identity_hash = ?')
        .get(identityHash(IDENTITY_SECRET, someone.raw)).last_day;
    assert.equal(after, before, 'an old proof no longer keeps the row alive');
    link.close();
});
