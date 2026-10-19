// Every replica holds FRIENDS_REPLICA_SECRET, so a host link's key must not come from that secret and the handshake
// alone. It did: the key was HMAC-SHA256 under the secret of both host ids and the handshake's two random values, all
// of which travel in the clear, so a compromised replica that could also intercept TLS between another replica and the
// main host could compute that link's key and inject messages the other replica believes, such as reservation answers
// it signs for its helpers or ID-table rows. Each host now adds a fresh X25519 key share under its host-key signature,
// and the key comes from their shared secret (link-auth.js). These tests play that third replica: listed, linked to
// the main host itself, holding both fleet secrets and its own host key, and relaying the other link. Each failed
// before: the old derivation reproduced the link's MACs, a forged message was applied, and a swapped share went
// unnoticed.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { decodeBase64url, encodeBase64url, hmacSha256 } from '../src/keys.js';
import { LinkAuth, linkKey, newKeyShare, sharedSecret } from '../src/link-auth.js';
import { lengthPrefixed } from '../src/protocol.js';
import { IDENTITY_SECRET, SECRET, TestClient, identity, keyPair, openLink, waitFor } from './helpers.js';
import { startProxiedPair } from './link-proxy.js';

function rows(host, friendsId) {
    return host.db.prepare('SELECT COUNT(*) AS n FROM identities WHERE friends_id = ?').get(friendsId).n;
}

// What any replica could compute for any link before key shares: the derivation this change replaced.
function keyBeforeShares({ mainHostId, replicaHostId, challenge, nonce }) {
    return hmacSha256(SECRET, Buffer.concat([Buffer.from('SZFriends host link key v1', 'utf8'),
        lengthPrefixed([mainHostId, replicaHostId, challenge, nonce])]));
}

// alt-sg's current link as the relay saw it: every handshake value that travelled, and each side's authenticated
// envelopes so far.
function observed(proxy) {
    const fromMain = proxy.fromMain.map((text) => JSON.parse(text));
    const fromReplica = proxy.fromReplica.map((text) => JSON.parse(text));
    const welcomeAt = fromMain.findLastIndex((msg) => msg.type === 'host_welcome');
    const helloAt = fromReplica.findLastIndex((msg) => msg.type === 'host_hello');
    const challenge = fromMain.slice(0, welcomeAt).findLast((msg) => msg.type === 'challenge');
    const [hello, welcome] = [fromReplica[helloAt], fromMain[welcomeAt]];
    return {
        transcript: { mainHostId: challenge.host_id, replicaHostId: hello.host_id,
            challenge: decodeBase64url(challenge.nonce, 32), nonce: decodeBase64url(hello.nonce, 32),
            replicaShare: decodeBase64url(hello.key_share, 32), mainShare: decodeBase64url(welcome.key_share, 32) },
        fromMain: fromMain.slice(welcomeAt + 1).filter((msg) => msg.type === 'link'),
        fromReplica: fromReplica.slice(helloAt + 1).filter((msg) => msg.type === 'link'),
    };
}

// Every key the third replica can form for alt-sg's link from what it holds, by name: the replica secret, its own
// link to the main host, a key share of its own, and everything alt-sg's handshake sent in the clear.
function candidateKeys({ transcript }, thirdLink) {
    const own = newKeyShare();
    const keys = new Map([['the derivation before key shares', keyBeforeShares(transcript)],
        ['its own link\'s key', thirdLink.auth.key]]);
    for (const [whose, share] of [['replica', transcript.replicaShare], ['main host', transcript.mainShare]]) {
        const shared = sharedSecret(own.privateKey, share);
        if (shared) keys.set(`its own share with the ${whose}'s`, linkKey({ secret: SECRET, shared, transcript }));
    }
    return keys;
}

// The main host, alt-sg linked through the relay, and the third replica alt-two linked straight to the main host.
// A check-in through alt-sg puts a message on its link each way.
async function startWithThirdReplica(t) {
    const thirdKey = keyPair();
    const pair = await startProxiedPair(t, { extraEntries: [{ id: 'alt-two', key: thirdKey, priority: 3, port: 9 }] });
    const third = await openLink(pair.main.url, { replicaId: 'alt-two', replicaKey: thirdKey, secret: SECRET,
        identitySecret: IDENTITY_SECRET });
    t.after(() => third.terminate());
    assert.equal(third.welcome.type, 'host_welcome', 'the third replica has a link of its own');
    const client = await TestClient.connect(pair.replica.url);
    assert.equal((await client.checkin(identity(), { friendsId: 'both-ways', listVersion: 2 })).reservation,
        'reserved');
    await client.close();
    await waitFor(() => rows(pair.replica.host, 'both-ways') === 1);
    return { ...pair, third };
}

test('a third replica holding the shared secret cannot compute another replica\'s link key', async (t) => {
    const { main, proxy, third } = await startWithThirdReplica(t);
    const seen = observed(proxy);
    assert.ok(seen.fromMain.length > 0 && seen.fromReplica.length > 0, 'the link carried a message each way');
    const realKey = main.host.hostLinks.get('alt-sg').auth.key;
    assert.ok(new LinkAuth(realKey, 'replica').unwrap(seen.fromMain[0]), 'the recorded envelope is authentic');
    const candidates = candidateKeys(seen, third);
    for (const [name, key] of candidates) {
        assert.equal(new LinkAuth(key, 'replica').unwrap(seen.fromMain[0]), null, `${name}: main host to replica`);
        assert.equal(new LinkAuth(key, 'main').unwrap(seen.fromReplica[0]), null, `${name}: replica to main host`);
    }
    assert.equal(candidates.size, 4, 'every candidate could be formed and was tried');
});

test('a third replica holding the shared secret cannot forge a message on another replica\'s link', async (t) => {
    const { main, replica, proxy, third, linkUp } = await startWithThirdReplica(t);
    // Toward the replica: an ID-table row under the key every replica could compute before, with the next number.
    const seen = observed(proxy);
    const forger = new LinkAuth(candidateKeys(seen, third).get('the derivation before key shares'), 'main');
    forger.sent = seen.fromMain.length;
    proxy.toReplica(forger.wrap('id_set', { identity_hash: encodeBase64url(crypto.randomBytes(32)),
        friends_id: 'planted-id', first_day: '2026-10-12', last_day: '2026-10-12' }));
    await waitFor(() => replica.logs.some((line) => line.includes('link authentication')));
    assert.equal(rows(replica.host, 'planted-id'), 0, 'the forged ID-table row was not applied');

    // Toward the main host, on the new link: a connection count, under the key its own share gives with the main
    // host's share. The main host records a replica's counts as they come, so an accepted one would show at once.
    await linkUp();
    const fresh = observed(proxy);
    const toMain = new LinkAuth(candidateKeys(fresh, third).get('its own share with the main host\'s'), 'replica');
    toMain.sent = fresh.fromReplica.length;
    proxy.toMain(toMain.wrap('report', { minute: Math.floor(main.clock.now() / 60_000), day: main.host.today(),
        connections: 4242, list_versions: {} }));
    await waitFor(() => main.logs.some((line) => line.includes('"dropped"') && line.includes('authentication')));
    assert.notEqual(main.host.replicaReports.get('alt-sg')?.connections, 4242, 'the forged count was not recorded');
});

function withShare(type, share) {
    return (text) => {
        const msg = JSON.parse(text);
        return msg.type === type ? JSON.stringify({ ...msg, key_share: encodeBase64url(share) }) : text;
    };
}

test('a key share swapped in the hello is refused by the main host', async (t) => {
    const { main, replica, proxy, linkUp } = await startProxiedPair(t);
    // Were this accepted, the main host would share the link key with whoever holds the swapped share's private half.
    proxy.rewriteFromReplica = withShare('host_hello', newKeyShare().share);
    proxy.cut();
    await waitFor(() => main.logs.some((line) => line.includes('"host_link"') && line.includes('"refused"')),
        { timeoutMs: 8000 });
    assert.notEqual(replica.host.replicaLink.state, 'up');
    proxy.rewriteFromReplica = (text) => text;
    await linkUp();
});

test('a key share swapped in the welcome is refused by the replica', async (t) => {
    const { replica, proxy, linkUp } = await startProxiedPair(t);
    proxy.rewriteFromMain = withShare('host_welcome', newKeyShare().share);
    proxy.cut();
    await waitFor(() => replica.logs.some((line) => line.includes('main host signature')), { timeoutMs: 8000 });
    assert.notEqual(replica.host.replicaLink.state, 'up');
    proxy.rewriteFromMain = (text) => text;
    await linkUp();
});

test('a low-order or malformed key share gives no link', async (t) => {
    const ends = { replica: newKeyShare(), main: newKeyShare() };
    const transcript = { mainHostId: 'main-hk', replicaHostId: 'alt-sg', challenge: crypto.randomBytes(32),
        nonce: crypto.randomBytes(32), replicaShare: ends.replica.share, mainShare: ends.main.share };
    // An all-zero share's shared secret is all zeros, which anyone can compute.
    for (const mainShare of [Buffer.alloc(32), Buffer.alloc(31, 7), null]) {
        assert.equal(LinkAuth.derive({ secret: SECRET, side: 'replica', privateKey: ends.replica.privateKey,
            transcript: { ...transcript, mainShare } }), null);
    }
    assert.ok(LinkAuth.derive({ secret: SECRET, side: 'replica', privateKey: ends.replica.privateKey, transcript }));

    // A hello signed with alt-sg's listed key and both secrets, carrying a low-order share, is refused, and the main
    // host keeps the link it had.
    const { main, replicaKey } = await startProxiedPair(t);
    const before = main.host.hostLinks.get('alt-sg');
    const link = await openLink(main.url, { replicaKey, keyShare: { privateKey: ends.replica.privateKey,
        share: Buffer.alloc(32) } });
    assert.equal(link.welcome.code, 'bad_signature');
    assert.equal(main.host.hostLinks.get('alt-sg'), before);
});
