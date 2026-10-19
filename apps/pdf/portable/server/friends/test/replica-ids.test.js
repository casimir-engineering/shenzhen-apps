// The Friends ID table on replicas (ADR 0005 § Replicas, HOST-PROTOCOL.md § Host links): the main host copies it to
// every replica and keeps the copies current, so a promoted replica cannot hand anyone's ID to the first claimant;
// a promoted replica without a finished copy hands out nothing; forwarded reservations and releases need the
// helper's own signature; and a replica believes only a main host that signs its nonce. Each test failed before.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { WebSocketServer } from 'ws';

import { idTableState } from '../src/id-sync.js';
import { encodeBase64url, identityHash, signEd25519 } from '../src/keys.js';
import { checkinSignedBytes, message, releaseSignedBytes } from '../src/protocol.js';
import { reserveId } from '../src/records.js';
import {
    IDENTITY_SECRET, SECRET, TestClient, identity, keyPair, listPayload, openLink, signList, startHost, startPair,
    waitFor,
} from './helpers.js';

async function claim(url, who, friendsId) {
    const client = await TestClient.connect(url);
    const welcome = await client.checkin(who, { friendsId });
    client.close();
    return welcome;
}

async function release(url, who) {
    const client = await TestClient.connect(url);
    const answer = await client.release(who, { friendsId: '' });
    client.close();
    return answer.released;
}

function holds(host, friendsId) {
    return host.db.prepare('SELECT COUNT(*) AS n FROM identities WHERE friends_id = ?').get(friendsId).n === 1;
}

// The next authenticated link message of `type`, skipping the ID-table copy a link receives first.
async function nextOf(client, type) {
    for (;;) {
        const msg = await client.linkNext();
        if (msg.type === type) return msg;
    }
}

function promotedList(pair, version) {
    const entries = pair.entries(pair.main.port).map((e) => ({ ...e, priority: e.id === 'alt-sg' ? 1 : 2,
        port: e.id === 'alt-sg' ? pair.replica.port : e.port }));
    return signList(listPayload({ version, entries }), [pair.admin]);
}

test('the ID table is copied to the replica, kept current, and caught up when the link returns', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const { main, replica } = pair;
    const early = identity();
    const visitor = identity();
    await claim(main.url, early, 'first-claim');
    await claim(replica.url, visitor, 'through-replica');
    await waitFor(() => holds(replica.host, 'first-claim') && holds(replica.host, 'through-replica'));
    assert.equal(idTableState(replica.host.db), 'synced');
    assert.equal(await release(main.url, early), true);
    await waitFor(() => !holds(replica.host, 'first-claim'));

    replica.host.replicaLink.stop();
    await waitFor(() => !main.host.hostLinks.has('alt-sg'));
    await claim(main.url, identity(), 'while-apart');
    assert.equal(await release(main.url, visitor), true);
    // More rows than one page, written straight to the table: only a full copy can bring them over.
    const day = main.host.today();
    for (let i = 0; i < 900; i++) {
        const word = [i % 26, Math.floor(i / 26) % 26, Math.floor(i / 676)].map((n) => String.fromCharCode(97 + n))
            .join('');
        reserveId(main.host.db, { identityHash: crypto.randomBytes(32), friendsId: `bulk-${word}x`,
            afterCollision: false, day });
    }
    replica.host.replicaLink.start();
    await pair.linkUp();
    await waitFor(() => holds(replica.host, 'while-apart') && !holds(replica.host, 'through-replica'));
    await waitFor(() => replica.host.db.prepare('SELECT COUNT(*) AS n FROM identities').get().n === 901);
});

test('a replica promoted to main host keeps every reserved ID from strangers', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const owner = identity();
    assert.equal((await claim(pair.replica.url, owner, 'maple-river')).reservation, 'reserved');
    await waitFor(() => holds(pair.replica.host, 'maple-river'));
    assert.equal(pair.main.host.offerList(promotedList(pair, 3), { source: 'admin' }).ok, true);
    await waitFor(() => pair.replica.host.isMain && !pair.main.host.isMain);
    // Before the copy existed, a fresh key took maple-river here at once.
    assert.equal((await claim(pair.replica.url, identity(), 'maple-river')).reservation, 'taken');
    assert.equal((await claim(pair.replica.url, owner, 'other-name')).friends_id, 'maple-river');
    // The old main host, now a replica, takes the new main host's copy.
    await waitFor(() => idTableState(pair.main.host.db) === 'synced', { timeoutMs: 8000 });
});

test('a replica made main host before its copy finished hands out no IDs unless the admin says so', async (t) => {
    const pair = await startPair(t, { replicaEnv: { FRIENDS_REPLICA_SECRET: 'some-other-secret-0123456789abcdef' } });
    await waitFor(() => pair.main.logs.some((line) => line.includes('"host_link"') && line.includes('refused')));
    assert.equal(idTableState(pair.replica.host.db), 'unsynced');
    assert.equal(pair.replica.host.offerList(promotedList(pair, 3), { source: 'admin' }).ok, true);
    assert.equal(pair.replica.host.isMain, true);
    assert.equal((await claim(pair.replica.url, identity(), 'too-early')).reservation, 'unavailable');
    const { dir } = pair.replica;
    await pair.replica.host.stop();
    const accepted = await startHost(t, { hostId: 'alt-sg', hostKey: pair.replicaKey, pinned: [pair.admin],
        clock: pair.clock, dataDir: dir, env: { FRIENDS_ALLOW_UNSYNCED_MAIN: '1' } });
    assert.equal((await claim(accepted.url, identity(), 'too-early')).reservation, 'reserved');
});

test('forwarded releases and reservations act only with the helper\'s own signature', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const victim = identity();
    await claim(pair.main.url, victim, 'maple-river');
    // A compromised replica holds alt-sg's host key and both secrets, and knows everyone's identity hash.
    const link = await openLink(pair.main.url, { replicaKey: pair.replicaKey });
    assert.equal(link.welcome.type, 'host_welcome');
    const victimHash = encodeBase64url(identityHash(IDENTITY_SECRET, victim.raw));
    link.linkSend('fwd_release', { req: 1, identity_hash: victimHash });
    assert.equal((await nextOf(link, 'fwd_release_result')).released, false);
    const challenge = crypto.randomBytes(32);
    const forged = { host_id: 'alt-sg', challenge: encodeBase64url(challenge), identity_key: victim.b64,
        friends_id: 'maple-river', sig: encodeBase64url(signEd25519(keyPair().privateKey, releaseSignedBytes({
            hostId: 'alt-sg', challenge, identityKey: victim.raw, friendsId: 'maple-river' }))) };
    link.linkSend('fwd_release', { req: 2, proof: forged });
    assert.equal((await nextOf(link, 'fwd_release_result')).released, false);
    assert.ok(holds(pair.main.host, 'maple-river'), 'the victim still holds the ID');

    const attacker = identity();
    link.linkSend('fwd_reserve', { req: 3, identity_hash: encodeBase64url(identityHash(IDENTITY_SECRET,
        attacker.raw)), friends_id: 'free-word', after_collision: false, allow_new: true });
    assert.equal((await nextOf(link, 'fwd_reserve_result')).reservation, 'unavailable', 'no proof, no reservation');
    const fields = { hostId: 'alt-sg', challenge, identityKey: attacker.raw, friendsId: 'maple-river', reserved: false,
        appVersion: '26.10.12-1', protocol: 1, listVersion: 2 };
    const proof = { host_id: 'alt-sg', challenge: encodeBase64url(challenge), identity_key: attacker.b64,
        friends_id: 'maple-river', reserved: false, app_version: '26.10.12-1', protocol: 1, list_version: 2,
        sig: encodeBase64url(signEd25519(attacker.privateKey, checkinSignedBytes(fields))) };
    link.linkSend('fwd_reserve', { req: 4, friends_id: 'maple-river', after_collision: false, allow_new: true,
        proof });
    assert.equal((await nextOf(link, 'fwd_reserve_result')).reservation, 'taken');
    link.linkSend('fwd_reserve', { req: 5, friends_id: 'free-word', after_collision: false, allow_new: true,
        proof: { ...proof, host_id: 'main-hk' } });
    assert.equal((await nextOf(link, 'fwd_reserve_result')).reservation, 'unavailable', 'a proof for another host');
    link.close();
});

test('a replica believes only a main host that signs its nonce with the listed key', async (t) => {
    const admin = keyPair();
    const mainKey = keyPair();
    const replicaKey = keyPair();
    const fake = new WebSocketServer({ host: '127.0.0.1', port: 0 });
    t.after(() => new Promise((resolve) => fake.close(resolve)));
    await new Promise((resolve) => fake.once('listening', resolve));
    fake.on('connection', (ws) => {
        ws.send(message('challenge', { host_id: 'main-hk', nonce: encodeBase64url(crypto.randomBytes(32)),
            time: new Date().toISOString() }));
        ws.on('message', () => {
            ws.send(message('host_welcome', { host_id: 'main-hk', host_list: null,
                sig: encodeBase64url(crypto.randomBytes(64)) }));
            ws.send(message('id_sync_begin', {}));
            ws.send(message('id_sync_page', { rows: [[encodeBase64url(crypto.randomBytes(32)), 'planted-id',
                '2026-10-12', '2026-10-12']] }));
            ws.send(message('id_sync_end', {}));
        });
    });
    const entries = [{ id: 'main-hk', key: mainKey, priority: 1, port: fake.address().port, role: 'both' },
        { id: 'alt-sg', key: replicaKey, priority: 2 }];
    const replica = await startHost(t, { hostId: 'alt-sg', hostKey: replicaKey, pinned: [admin],
        listText: signList(listPayload({ version: 1, entries }), [admin]), env: { FRIENDS_REPLICA_SECRET: SECRET } });
    await waitFor(() => replica.logs.some((line) => line.includes('main host signature')));
    assert.notEqual(replica.host.replicaLink.state, 'up');
    assert.equal(idTableState(replica.host.db), 'unsynced');
    assert.equal(replica.host.db.prepare('SELECT COUNT(*) AS n FROM identities').get().n, 0);
});
