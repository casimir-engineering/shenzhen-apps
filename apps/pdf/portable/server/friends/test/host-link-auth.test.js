// Host links after the handshake (HOST-PROTOCOL.md § Host links). The replica already refused a main host that
// could not sign its nonce, but everything after the welcome was believed on TLS alone, so a network attacker with a
// certificate for the main host's name could relay the handshake and then inject ID-table rows or rewrite
// reservation answers. Every message after the handshake now carries a MAC under a key only the link's two ends can
// derive (host-link-secrecy.test.js covers that part), with a sequence number per direction; any failure drops the
// link. Each test that drives a link here failed before (the injected message was applied, or the link stayed up).

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { encodeBase64url } from '../src/keys.js';
import { LinkAuth, newKeyShare } from '../src/link-auth.js';
import { message } from '../src/protocol.js';
import { SECRET, TestClient, identity, waitFor } from './helpers.js';
import { startProxiedPair } from './link-proxy.js';

function rows(host, friendsId) {
    return host.db.prepare('SELECT COUNT(*) AS n FROM identities WHERE friends_id = ?').get(friendsId).n;
}

test('a message injected toward the replica after the welcome drops the link and changes nothing', async (t) => {
    const { main, replica, proxy, linkUp } = await startProxiedPair(t);
    const planted = message('id_set', { identity_hash: encodeBase64url(crypto.randomBytes(32)),
        friends_id: 'planted-id', first_day: '2026-10-12', last_day: '2026-10-12' });
    proxy.toReplica(planted);
    await waitFor(() => replica.logs.some((line) => line.includes('link authentication')));
    assert.equal(rows(replica.host, 'planted-id'), 0, 'the injected ID-table row was not applied');

    // The link comes back on its own and works.
    await linkUp();
    const client = await TestClient.connect(replica.url);
    assert.equal((await client.checkin(identity(), { friendsId: 'after-drop', listVersion: 2 })).reservation,
        'reserved');
    client.close();
    await waitFor(() => rows(replica.host, 'after-drop') === 1);
    assert.equal(rows(main.host, 'planted-id'), 0);
});

test('a replayed or forged envelope toward the replica drops the link', async (t) => {
    const { replica, proxy, linkUp } = await startProxiedPair(t);
    const authentic = proxy.fromMain.filter((text) => JSON.parse(text).type === 'link');
    assert.ok(authentic.length >= 2, 'the main host sent authenticated messages');
    proxy.toReplica(authentic.at(-1));
    await waitFor(() => replica.logs.filter((line) => line.includes('link authentication')).length === 1);
    await linkUp();

    // The next sequence number with a body the attacker wrote: a reservation answer it would like believed.
    const latest = proxy.fromMain.filter((text) => JSON.parse(text).type === 'link').at(-1);
    const forged = JSON.parse(latest);
    forged.seq += 1;
    forged.body = message('fwd_reserve_result', { req: 1, reservation: 'reserved', friends_id: 'stolen-name',
        granted: true });
    proxy.toReplica(JSON.stringify(forged));
    await waitFor(() => replica.logs.filter((line) => line.includes('link authentication')).length === 2);
});

test('a message injected toward the main host after the hello drops the link and changes nothing', async (t) => {
    const { main, proxy, linkUp } = await startProxiedPair(t);
    const hash = crypto.randomBytes(32);
    proxy.toMain(message('fwd_summaries', { items: [{ seq: 1, identity_hash: encodeBase64url(hash),
        day: main.host.today(), app_version: '26.10.12-1', list_version: 2, protocol: 1 }] }));
    await waitFor(() => main.logs.some((line) => line.includes('"dropped"')));
    assert.equal(main.host.db.prepare('SELECT COUNT(*) AS n FROM identities WHERE identity_hash = ?').get(hash).n, 0);
    await linkUp();
});

// Both ends of one link, in memory: each holds its own key share's private half.
function linkEnds() {
    const mainKeys = newKeyShare();
    const replicaKeys = newKeyShare();
    const transcript = { mainHostId: 'main-hk', replicaHostId: 'alt-sg', challenge: crypto.randomBytes(32),
        nonce: crypto.randomBytes(32), replicaShare: replicaKeys.share, mainShare: mainKeys.share };
    return {
        main: LinkAuth.derive({ secret: SECRET, side: 'main', privateKey: mainKeys.privateKey, transcript }),
        replica: LinkAuth.derive({ secret: SECRET, side: 'replica', privateKey: replicaKeys.privateKey, transcript }),
        transcript, replicaKeys,
    };
}

test('a link key authenticates one direction of one link, in order', () => {
    const { main, replica, transcript, replicaKeys } = linkEnds();
    assert.deepEqual(main.key, replica.key, 'both ends derive the same key');
    const first = JSON.parse(main.wrap('ack', { through: 3 }));
    const second = JSON.parse(main.wrap('ack', { through: 4 }));
    assert.equal(new LinkAuth(main.key, 'main').unwrap(JSON.parse(main.wrap('x'))), null,
        'a message reflected back to its sender');
    assert.equal(replica.unwrap(second), null, 'out of order');
    assert.deepEqual(replica.unwrap(first), { type: 'ack', v: 1, through: 3 });
    assert.equal(replica.unwrap(first), null, 'replayed');
    assert.equal(replica.unwrap({ ...second, body: second.body.replace('4', '5') }), null, 'body changed');
    assert.equal(linkEnds().replica.unwrap(first), null, 'another link');
    const otherSecret = LinkAuth.derive({ secret: `${SECRET}x`, side: 'replica', privateKey: replicaKeys.privateKey,
        transcript });
    assert.equal(otherSecret.unwrap(first), null, 'another secret');
    const otherInfo = LinkAuth.derive({ secret: SECRET, side: 'replica', privateKey: replicaKeys.privateKey,
        transcript: { ...transcript, nonce: crypto.randomBytes(32) } });
    assert.equal(otherInfo.unwrap(first), null, 'another handshake with the same key shares');
    assert.deepEqual(replica.unwrap(second), { type: 'ack', v: 1, through: 4 });
    const answer = JSON.parse(replica.wrap('report', { connections: 1 }));
    assert.equal(main.unwrap(answer).type, 'report', 'the other direction counts on its own');
});
