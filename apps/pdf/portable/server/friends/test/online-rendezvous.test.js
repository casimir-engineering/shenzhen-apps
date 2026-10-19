// Rendezvous records: signed by the device key, bound to this host, expiring, newer only, memory only; lookups
// answer the same number of bytes for every key, fixed for a whole period, so they reveal nobody's presence.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';

import { encodeBase64url } from '../src/keys.js';
import { ONLINE_LIMITS, rendezvousFiller, rendezvousKey } from '../src/online-protocol.js';
import { IDENTITY_SECRET } from './helpers.js';
import {
    FakeHelper, identity, nextOf, nextPeriod, nowS, sealedBlob, startOnline, waitFor,
} from './online-helpers.js';

async function lookup(helper, keys) {
    helper.req += 1;
    helper.send('rdv_lookup', { req: helper.req, keys: keys.map((key) => encodeBase64url(key)) });
    return (await nextOf(helper.client, 'rdv_records')).records;
}

test('a record shows in lookups the period after it was published; unknown keys get filler of the same size',
    async (t) => {
        const { url, clock, online } = await startOnline(t);
        const bob = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
        const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
        const stranger = rendezvousKey(identity().raw);
        const keys = [bob.rdvKey, stranger];
        const before = await lookup(alice, keys);
        const sealed = sealedBlob();
        const { reply } = await bob.publish({ sealed, nowS: nowS(clock) });
        assert.equal(reply.accepted, true);
        assert.equal(reply.shown_from % ONLINE_LIMITS.rdvPeriodS, 0);
        assert.ok(reply.shown_from > nowS(clock) && reply.shown_from <= nowS(clock) + ONLINE_LIMITS.rdvPeriodS);
        assert.equal(online.records.size, 1);
        assert.deepEqual(await lookup(alice, keys), before, 'nothing changes in the middle of a period');
        const period = Math.floor(nowS(clock) / ONLINE_LIMITS.rdvPeriodS);
        assert.deepEqual(before, keys.map((key) => encodeBase64url(rendezvousFiller(IDENTITY_SECRET, key, period))));

        nextPeriod(clock);
        const shown = await lookup(alice, keys);
        assert.equal(shown[0], encodeBase64url(sealed));
        assert.notEqual(shown[1], before[1], 'filler changes at the boundary, as a record does');
        for (const record of shown) {
            assert.equal(Buffer.from(record, 'base64url').length, ONLINE_LIMITS.sealedRecordBytes);
        }
        await bob.close();
        await waitFor(() => online.records.size === 0);
        assert.deepEqual(await lookup(alice, keys), shown, 'leaving shows at the next boundary, not before');
        nextPeriod(clock);
        const after = await lookup(alice, keys);
        assert.notEqual(after[0], encodeBase64url(sealed));
        assert.deepEqual(await lookup(alice, keys), after);
        alice.close();
    });

test('a helper that does not publish again in a period looks, the next period, like nobody', async (t) => {
    const { url, clock } = await startOnline(t);
    const bob = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    const sealed = sealedBlob();
    await bob.publish({ sealed, nowS: nowS(clock) });
    nextPeriod(clock);
    assert.equal((await lookup(alice, [bob.rdvKey]))[0], encodeBase64url(sealed));
    nextPeriod(clock);
    const period = Math.floor(nowS(clock) / ONLINE_LIMITS.rdvPeriodS);
    assert.equal((await lookup(alice, [bob.rdvKey]))[0],
        encodeBase64url(rendezvousFiller(IDENTITY_SECRET, bob.rdvKey, period)), 'its record is live but not shown');
    const fresh = sealedBlob();
    await bob.publish({ sealed: fresh, nowS: nowS(clock) });
    nextPeriod(clock);
    assert.equal((await lookup(alice, [bob.rdvKey]))[0], encodeBase64url(fresh));
    bob.close();
    alice.close();
});

test('records must be signed by the identity, name this host, expire within 15 minutes and only move forward',
    async (t) => {
        const { url, clock } = await startOnline(t);
        const bob = await FakeHelper.connect(url);
        const now = nowS(clock);
        assert.equal((await bob.publish({ nowS: now, expires: now + 901 })).reply.reason, 'expiry');
        assert.equal((await bob.publish({ nowS: now, expires: now })).reply.reason, 'expiry');
        assert.equal((await bob.publish({ nowS: now, seq: 10 })).reply.accepted, true);
        assert.equal((await bob.publish({ nowS: now, seq: 10 })).reply.reason, 'stale');
        const sealed = sealedBlob();
        assert.equal((await bob.publish({ nowS: now, seq: 11, sealed })).reply.accepted, true);
        assert.equal((await bob.publish({ nowS: now, seq: 12, sealed })).reply.reason, 'stale',
            'a record sealed the same as the one it replaces would stand out against the filler');

        const other = await FakeHelper.connect(url, { friendsId: 'quiet-fox' });
        other.send('rdv_publish', other.record({ nowS: now, hostId: 'alt-sg' }));
        assert.equal((await nextOf(other.client, 'error')).code, 'bad_signature');

        const forger = await FakeHelper.connect(url, { friendsId: 'brisk-wren' });
        forger.send('rdv_publish', forger.record({ nowS: now, signer: identity() }));
        assert.equal((await nextOf(forger.client, 'error')).code, 'bad_signature');

        const sloppy = await FakeHelper.connect(url, { friendsId: 'dusty-lark' });
        sloppy.send('rdv_publish', { ...sloppy.record({ nowS: now }), sealed: encodeBase64url(Buffer.alloc(100)) });
        assert.equal((await nextOf(sloppy.client, 'error')).code, 'bad_request');
        bob.close();
    });

test('a protocol 1 helper cannot send online Friends messages', async (t) => {
    const { url, clock } = await startOnline(t);
    const old = await FakeHelper.connect(url, { protocol: 1 });
    old.send('rdv_publish', old.record({ nowS: nowS(clock) }));
    const error = await nextOf(old.client, 'error');
    assert.equal(error.code, 'bad_request');
    assert.equal((await old.client.closed).code, 1008);
});

test('lookups are limited to 256 keys per 5 minutes per identity, across reconnects', async (t) => {
    const { url, clock } = await startOnline(t);
    const who = identity();
    let alice = await FakeHelper.connect(url, { who });
    const keys = Array.from({ length: 32 }, () => encodeBase64url(rendezvousKey(identity().raw)));
    for (let i = 0; i < 4; i++) {
        alice.send('rdv_lookup', { req: i, keys });
        assert.equal((await nextOf(alice.client, 'rdv_records')).records.length, 32);
    }
    await alice.close();
    alice = await FakeHelper.connect(url, { who });
    for (let i = 0; i < 4; i++) {
        alice.send('rdv_lookup', { req: i, keys });
        assert.ok((await nextOf(alice.client, 'rdv_records')).records);
    }
    alice.send('rdv_lookup', { req: 9, keys });
    const refused = await nextOf(alice.client, 'rdv_records');
    assert.equal(refused.records, null);
    assert.equal(refused.reason, 'rate_limited');
    clock.advance(5 * 60_000);
    alice.send('rdv_lookup', { req: 10, keys });
    assert.equal((await nextOf(alice.client, 'rdv_records')).records.length, 32);
    alice.close();
});

test('records expire, and nothing about them reaches the database', async (t) => {
    const { url, clock, online, dir } = await startOnline(t);
    const bob = await FakeHelper.connect(url);
    const sealed = sealedBlob();
    await bob.publish({ sealed, nowS: nowS(clock), expires: nowS(clock) + 60 });
    clock.advance(61_000);
    await waitFor(() => online.records.size === 0, { timeoutMs: 3000 });
    const files = fs.readdirSync(path.join(dir, 'data')).filter((f) => f.startsWith('friends.sqlite'));
    const bytes = Buffer.concat(files.map((f) => fs.readFileSync(path.join(dir, 'data', f))));
    assert.equal(bytes.indexOf(sealed.subarray(0, 32)), -1);
    assert.equal(bytes.indexOf(bob.rdvKey), -1);
    bob.close();
});
