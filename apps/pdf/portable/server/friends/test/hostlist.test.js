// The signed host list (ADR 0005 § Signed host list): the shared vectors, strict parsing, publishing a new
// version to connected helpers within seconds, and refusing older, equal-but-different and badly signed lists.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';

import { mainHost, verifyEnvelope } from '../src/hostlist.js';
import { decodeBase64url } from '../src/keys.js';
import { TestClient, identity, keyPair, listPayload, signList, startMain } from './helpers.js';
import { VECTORS_PATH, vectorsText } from './vectors/make-vectors.js';

const vectors = JSON.parse(fs.readFileSync(VECTORS_PATH, 'utf8'));
const pinned = vectors.pinned.map((k) => decodeBase64url(k, 32));

test('the committed vectors are exactly what the generator produces', () => {
    assert.equal(fs.readFileSync(VECTORS_PATH, 'utf8'), vectorsText());
});

test('every vector list verifies or fails as recorded, and parses to the recorded fields', () => {
    for (const vector of vectors.host_lists) {
        const result = verifyEnvelope(JSON.stringify(vector.envelope), pinned);
        assert.equal(result.ok, vector.valid, `${vector.name}: ${result.error ?? ''}`);
        if (!vector.valid) continue;
        const { list } = result;
        assert.equal(list.version, vector.expected.version, vector.name);
        assert.equal(list.newIdWords, vector.expected.new_id_words, vector.name);
        assert.equal(list.issuedAt, vector.expected.issued_at, vector.name);
        const hosts = list.hosts.map((h) => ({ id: h.id, role: h.role, urls: h.urls, region: h.region,
            priority: h.priority, public_key: h.publicKey.toString('base64url') }));
        assert.deepEqual(hosts, vector.expected.hosts, vector.name);
        assert.equal(mainHost(list).id, 'main-hk');
    }
});

test('envelopes are parsed strictly', () => {
    const good = vectors.host_lists[0].envelope;
    const cases = {
        'padded base64': { ...good, payload: `${good.payload}=` },
        // Buffer.from skips characters outside the alphabet, so these would decode to the signed bytes if the
        // parser were lenient; two different strings must never name one payload.
        'stray character': { ...good, payload: `${good.payload}!` },
        'trailing newline': { ...good, payload: `${good.payload}\n` },
        'five signatures': { ...good, sigs: Array(5).fill(good.sigs[0]) },
        'signature too short': { ...good, sigs: [{ key: 'primary', sig: 'AAAA' }] },
        'not an object': [good],
    };
    for (const [name, envelope] of Object.entries(cases)) {
        assert.equal(verifyEnvelope(JSON.stringify(envelope), pinned).ok, false, name);
    }
    assert.equal(verifyEnvelope('x'.repeat(70_000), pinned).ok, false, 'oversized');
    assert.equal(verifyEnvelope('{', pinned).ok, false, 'not JSON');
});

test('one valid signature suffices even beside an invalid one', () => {
    const good = vectors.host_lists[0].envelope;
    const stranger = vectors.host_lists.find((v) => v.name === 'signed by a key nobody pins').envelope;
    const mixed = { payload: good.payload, sigs: [stranger.sigs[0], good.sigs[0]] };
    assert.equal(verifyEnvelope(JSON.stringify(mixed), pinned).ok, true);
});

function newerList(main, version, signer = main.admin) {
    return signList(listPayload({ version, entries: [{ id: 'main-hk', key: main.hostKey, priority: 1,
        role: 'both' }] }), [signer]);
}

test('a newer list published on the main host reaches connected helpers within seconds', async (t) => {
    const main = await startMain(t);
    const clients = await Promise.all([TestClient.connect(main.url), TestClient.connect(main.url)]);
    for (const [i, c] of clients.entries()) {
        await c.checkin(identity(), { friendsId: `word-list${'ab'[i]}`, listVersion: 1 });
    }
    const result = main.host.offerList(newerList(main, 2), { source: 'admin' });
    assert.deepEqual(result, { ok: true, version: 2 });
    for (const c of clients) {
        const pushed = await c.expect('host_list', 2000);
        assert.equal(JSON.parse(Buffer.from(pushed.host_list.payload, 'base64url')).version, 2);
        c.close();
    }
    const fresh = await TestClient.connect(main.url);
    const welcome = await fresh.checkin(identity(), { friendsId: 'fresh-start', listVersion: 1 });
    assert.equal(JSON.parse(Buffer.from(welcome.host_list.payload, 'base64url')).version, 2);
    fresh.close();
});

test('older, equal-but-different and badly signed lists are refused; the backup key is accepted', async (t) => {
    const backup = keyPair();
    const admin = keyPair();
    const main = await startMain(t, { admin, version: 3, pinned: [admin, backup] });
    assert.equal(main.host.offerList(newerList(main, 2), { source: 'admin' }).ok, false);
    const sameVersion = signList(listPayload({ version: 3, entries: [{ id: 'main-hk', key: main.hostKey, priority: 1,
        role: 'both', region: 'Elsewhere' }] }), [admin]);
    assert.match(main.host.offerList(sameVersion, { source: 'admin' }).error, /not newer/);
    assert.match(main.host.offerList(newerList(main, 4, keyPair()), { source: 'admin' }).error, /pinned/);
    assert.deepEqual(main.host.offerList(newerList(main, 4, backup), { source: 'admin' }), { ok: true, version: 4 });
    assert.match(main.host.offerList(main.host.envelope, { source: 'admin' }).error, /already current/);
});

test('the newest stored list survives a restart, and a newer file replaces it', async (t) => {
    const admin = keyPair();
    const first = await startMain(t, { admin, version: 2 });
    first.host.offerList(newerList(first, 3), { source: 'admin' });
    await first.host.stop();
    const again = await startMain(t, { admin, version: 2, dataDir: first.dir, hostKey: first.hostKey });
    assert.equal(again.host.list.version, 3);
    await again.host.stop();
    const newer = await startMain(t, { admin, version: 7, dataDir: first.dir });
    assert.equal(newer.host.list.version, 7);
});

// The deploy image's test stage copies only this package; everywhere else the helper's files must be present.
const STANDALONE = process.env.FRIENDS_TEST_STANDALONE === '1' && 'the helper resources are outside this copy';

test('the bundled list the helper ships verifies with its pinned keys', { skip: STANDALONE }, () => {
    const resources = new URL('../../../friends/service/host/resources/', import.meta.url);
    const pinnedFile = JSON.parse(fs.readFileSync(new URL('pinned-keys.json', resources), 'utf8'));
    const keys = pinnedFile.keys.map((k) => decodeBase64url(k.public_key, 32));
    const bootstrap = fs.readFileSync(new URL('bootstrap-hosts.json', resources), 'utf8');
    const result = verifyEnvelope(bootstrap, keys);
    assert.equal(result.ok, true, result.error);
    assert.deepEqual(result.list.hosts.map((h) => h.urls).flat(), ['wss://friends.meerkat.orgabots.com/v1']);
});
