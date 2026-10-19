// Friends ID reservation (ADR 0005 § ID reservation) and release, on a main host.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { metaGet } from '../src/db.js';
import { CLOSE } from '../src/protocol.js';
import { reserveId } from '../src/records.js';
import { TestClient, identity, keyPair, startMain } from './helpers.js';

function dailyRow(host) {
    return host.db.prepare('SELECT * FROM daily_stats WHERE day = ?').get(host.today());
}

test('two identities racing for one ID: the first reservation wins and the other is told it is taken', async (t) => {
    const { url } = await startMain(t);
    const clients = await Promise.all([TestClient.connect(url), TestClient.connect(url), TestClient.connect(url)]);
    await Promise.all(clients.map((c) => c.challenge()));
    const replies = await Promise.all(clients.map((c) => c.checkin(identity(), { friendsId: 'tulip-harbor' })));
    assert.deepEqual(replies.map((r) => r.reservation).sort(), ['reserved', 'taken', 'taken']);
    assert.equal(replies.find((r) => r.reservation === 'reserved').friends_id, 'tulip-harbor');
    assert.ok(replies.filter((r) => r.reservation === 'taken').every((r) => r.friends_id === null));
    for (const c of clients) c.close();
});

test('after a collision the newcomer reserves a fresh ID on the same connection, counted as a rename', async (t) => {
    const { url, host } = await startMain(t);
    const holder = await TestClient.connect(url);
    await holder.checkin(identity(), { friendsId: 'maple-river' });
    const newcomer = await TestClient.connect(url);
    const welcome = await newcomer.checkin(identity(), { friendsId: 'maple-river' });
    assert.equal(welcome.reservation, 'taken');
    const second = await newcomer.reserve('maple-harbor');
    assert.equal(second.type, 'reserve_result');
    assert.equal(second.reservation, 'reserved');
    assert.equal(second.friends_id, 'maple-harbor');
    const day = dailyRow(host);
    assert.equal(day.collisions, 1);
    assert.equal(day.reservations, 2);
    assert.equal(day.renames, 1);
    holder.close();
    newcomer.close();
});

test('a key holds one ID: a reinstall that kept its key gets its recorded ID back', async (t) => {
    const { url } = await startMain(t);
    const who = identity();
    const first = await TestClient.connect(url);
    await first.checkin(who, { friendsId: 'cedar-lake' });
    first.close();
    const again = await TestClient.connect(url);
    const welcome = await again.checkin(who, { friendsId: 'pebble-moon' });
    assert.equal(welcome.reservation, 'reserved');
    assert.equal(welcome.friends_id, 'cedar-lake');
    const asked = await again.reserve('otter-field');
    assert.equal(asked.friends_id, 'cedar-lake');
    again.close();
});

test('IDs are checked for syntax only: two or three words of 3 to 8 lowercase letters', async (t) => {
    const { url } = await startMain(t);
    for (const [friendsId, expected] of [['Maple-River', 'invalid'], ['maple', 'invalid'], ['a-b', 'invalid'],
        ['maple-river-lake-sun', 'invalid'], ['ma-river', 'invalid'], ['zzzzz-qqqqq', 'reserved'],
        ['maple-river-lake', 'reserved']]) {
        const client = await TestClient.connect(url);
        const welcome = await client.checkin(identity(), { friendsId });
        assert.equal(welcome.reservation, expected, friendsId);
        client.close();
    }
});

test('a connection may try at most 20 IDs', async (t) => {
    const { url } = await startMain(t, { env: { FRIENDS_RATE_MESSAGES_PER_10S: '100' } });
    const holder = await TestClient.connect(url);
    await holder.checkin(identity(), { friendsId: 'aaa-aaa' });
    holder.close();
    const client = await TestClient.connect(url);
    await client.checkin(identity(), { friendsId: 'aaa-aaa' });
    for (let i = 0; i < 20; i++) {
        const reply = await client.reserve('aaa-aaa');
        assert.equal(reply.reservation, 'taken');
    }
    const refused = await client.reserve('bbb-bbb');
    assert.equal(refused.code, 'too_many_reservations');
    assert.equal((await client.closed).code, CLOSE.tryLater);
});

test('reserve before check-in is refused', async (t) => {
    const { url } = await startMain(t);
    const client = await TestClient.connect(url);
    await client.challenge();
    const reply = await client.reserve('maple-river');
    assert.equal(reply.code, 'not_checked_in');
});

test('release frees the ID for someone else and deletes the identity', async (t) => {
    const { url, host } = await startMain(t);
    const who = identity();
    const owner = await TestClient.connect(url);
    await owner.checkin(who, { friendsId: 'quiet-meadow' });
    const released = await owner.release(who, { friendsId: 'quiet-meadow' });
    assert.equal(released.type, 'released');
    assert.equal(released.released, true);
    assert.equal((await owner.closed).code, CLOSE.released);
    assert.equal(host.db.prepare('SELECT COUNT(*) AS n FROM identities').get().n, 0);
    assert.equal(dailyRow(host).releases, 1);
    const next = await TestClient.connect(url);
    assert.equal((await next.checkin(identity(), { friendsId: 'quiet-meadow' })).reservation, 'reserved');
    next.close();
});

test('release works as the first message, is idempotent, and needs the identity signature', async (t) => {
    const { url, host } = await startMain(t);
    const who = identity();
    const owner = await TestClient.connect(url);
    await owner.checkin(who, { friendsId: 'quiet-meadow' });
    owner.close();
    const forged = await TestClient.connect(url);
    const refused = await forged.release(who, { friendsId: 'quiet-meadow', signer: keyPair() });
    assert.equal(refused.code, 'bad_signature');
    assert.equal(host.db.prepare('SELECT COUNT(*) AS n FROM identities').get().n, 1);
    const fresh = await TestClient.connect(url);
    assert.equal((await fresh.release(who, { friendsId: 'quiet-meadow' })).released, true);
    const twice = await TestClient.connect(url);
    assert.equal((await twice.release(who, { friendsId: 'quiet-meadow' })).released, true);
    assert.equal(host.db.prepare('SELECT COUNT(*) AS n FROM identities').get().n, 0);
});

test('a checked-in connection releases only its own identity', async (t) => {
    const { url } = await startMain(t);
    const me = identity();
    const someoneElse = identity();
    const client = await TestClient.connect(url);
    await client.checkin(me);
    const reply = await client.release(someoneElse);
    assert.equal(reply.code, 'bad_request');
});

test('the reservation transaction grants an ID once even when called back to back', async (t) => {
    const { host } = await startMain(t);
    const day = host.today();
    const results = Array.from({ length: 50 }, (_, i) => reserveId(host.db, { identityHash: Buffer.alloc(32, i),
        friendsId: 'same-word', afterCollision: false, day }));
    assert.equal(results.filter((r) => r.reservation === 'reserved').length, 1);
    assert.equal(results.filter((r) => r.reservation === 'taken').length, 49);
    assert.equal(metaGet(host.db, 'identities_ever'), 50);
});
