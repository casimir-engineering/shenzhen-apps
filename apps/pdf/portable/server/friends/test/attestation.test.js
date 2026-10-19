// ID attestations (HOST-PROTOCOL.md § ID attestations): every answer that says "reserved" carries the host's
// signature over (host id, Friends ID, identity key, UTC day), so a helper can show a nearby requester that it holds
// the ID. Before attestations, nothing tied an ID to a key offline and anyone who heard an Add by ID could answer it
// as the holder; each test here failed then (no attestation in any answer).

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { checkAttestation, signAttestation, utcDay } from '../src/attestation.js';
import { verifyEnvelope } from '../src/hostlist.js';
import { decodeBase64url } from '../src/keys.js';
import { DAY_MS, TestClient, identity, keyPair, listPayload, signList, startMain, startPair } from './helpers.js';
import { makeVectors } from './vectors/make-vectors.js';

function claimOf(who, friendsId, now) {
    return { friendsId, identityKey: who.raw, now };
}

test('a check-in that reserves an ID carries an attestation for this key and ID, dated today', async (t) => {
    const { url, host, clock } = await startMain(t);
    const who = identity();
    const client = await TestClient.connect(url);
    const welcome = await client.checkin(who, { friendsId: 'maple-river' });
    assert.equal(welcome.reservation, 'reserved');
    const { attestation } = welcome;
    assert.deepEqual([attestation.host_id, attestation.friends_id, attestation.identity_key, attestation.day],
        ['main-hk', 'maple-river', who.b64, utcDay(clock.now())]);
    assert.equal(checkAttestation(attestation, host.list, claimOf(who, 'maple-river', clock.now())), 'valid');
    assert.equal(checkAttestation(attestation, host.list, claimOf(identity(), 'maple-river', clock.now())),
        'wrong_holder', 'it speaks for this key only');
    client.close();

    // A collision answers without one; the rename that follows carries one for the new ID.
    const newcomer = identity();
    const second = await TestClient.connect(url);
    const taken = await second.checkin(newcomer, { friendsId: 'maple-river' });
    assert.deepEqual([taken.reservation, taken.attestation], ['taken', null]);
    const renamed = await second.reserve('maple-harbor');
    assert.equal(renamed.reservation, 'reserved');
    assert.equal(checkAttestation(renamed.attestation, host.list, claimOf(newcomer, 'maple-harbor', clock.now())),
        'valid');
    second.close();

    // Every launch brings a fresh one, so it lapses only for someone who stopped opening the app.
    clock.advance(40 * DAY_MS);
    assert.equal(checkAttestation(attestation, host.list, claimOf(who, 'maple-river', clock.now())), 'expired');
    const later = await TestClient.connect(url);
    const again = await later.checkin(who, { friendsId: 'maple-river', reserved: true });
    assert.equal(checkAttestation(again.attestation, host.list, claimOf(who, 'maple-river', clock.now())), 'valid');
    later.close();
});

test('a replica signs attestations with its own host key', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const who = identity();
    const client = await TestClient.connect(pair.replica.url);
    const welcome = await client.checkin(who, { friendsId: 'river-stone', listVersion: 2 });
    assert.equal(welcome.attestation.host_id, 'alt-sg');
    const now = pair.clock.now();
    assert.equal(checkAttestation(welcome.attestation, pair.main.host.list, claimOf(who, 'river-stone', now)),
        'valid');
    // The same statement under the main host's name does not verify: each host signs only as itself.
    const relabelled = { ...welcome.attestation, host_id: 'main-hk' };
    assert.equal(checkAttestation(relabelled, pair.main.host.list, claimOf(who, 'river-stone', now)),
        'bad_signature');
    client.close();
});

test('only a rendezvous host in the list can attest', async (t) => {
    const admin = keyPair();
    const relayKey = keyPair();
    const mainKey = keyPair();
    const text = signList(listPayload({ entries: [{ id: 'main-hk', key: mainKey, priority: 1 },
        { id: 'relay-hk', key: relayKey, priority: 2, role: 'relay' }] }), [admin]);
    const { list } = verifyEnvelope(text, [admin.raw]);
    const { url, host } = await startMain(t, { hostKey: mainKey });
    const who = identity();
    const client = await TestClient.connect(url);
    const { attestation } = await client.checkin(who, { friendsId: 'maple-river' });
    client.close();
    const now = host.clock.now();
    assert.equal(checkAttestation(attestation, list, claimOf(who, 'maple-river', now)), 'valid');
    // relay-hk's key signing the same statement is refused: relays never check helpers in.
    const byRelay = signAttestation({ hostId: 'relay-hk', hostKey: relayKey.privateKey, friendsId: 'maple-river',
        identityKey: who.raw, day: attestation.day });
    assert.equal(checkAttestation(byRelay, list, claimOf(who, 'maple-river', now)), 'unknown_host');
    for (const broken of [null, [], 'x', { ...attestation, identity_key: 'AAAA' }, { ...attestation, day: '12/10' },
        { ...attestation, friends_id: 'Maple-River' }]) {
        assert.equal(checkAttestation(broken, list, claimOf(who, 'maple-river', now)), 'malformed');
    }
});

test('the shared vectors give the verdicts the helper checks', () => {
    const vectors = makeVectors();
    const { list, now, cases } = vectors.attestations;
    const verified = verifyEnvelope(JSON.stringify(list), vectors.pinned.map((k) => decodeBase64url(k, 32)));
    assert.ok(verified.ok);
    assert.ok(cases.length >= 10);
    for (const c of cases) {
        const claim = { friendsId: c.claim.friends_id, identityKey: decodeBase64url(c.claim.identity_key, 32),
            now: Date.parse(now) };
        assert.equal(checkAttestation(c.attestation, verified.list, claim), c.verdict, c.name);
    }
});
