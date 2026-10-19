// Check-in (ADR 0005 § Check-in): the challenge, signature checks bound to the challenge and the host id, the
// welcome, update_required, one live connection per identity, and the per-connection limits.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { decodeBase64url } from '../src/keys.js';
import { CLOSE } from '../src/protocol.js';
import { TestClient, identity, keyPair, listPayload, signList, startMain, waitFor } from './helpers.js';

test('the challenge carries 32 random bytes, the host id and the time', async (t) => {
    const { url } = await startMain(t);
    const a = await TestClient.connect(url);
    const b = await TestClient.connect(url);
    const first = await a.challenge();
    const second = await b.challenge();
    assert.equal(first.v, 1);
    assert.equal(first.host_id, 'main-hk');
    assert.equal(decodeBase64url(first.nonce, 32).length, 32);
    assert.notEqual(first.nonce, second.nonce);
    assert.ok(!Number.isNaN(Date.parse(first.time)));
    a.close();
    b.close();
});

test('a valid check-in reserves the ID and says nothing about lists the helper already holds', async (t) => {
    const { url, host } = await startMain(t);
    const client = await TestClient.connect(url);
    const welcome = await client.checkin(identity(), { listVersion: 1 });
    assert.equal(welcome.type, 'welcome');
    assert.equal(welcome.reservation, 'reserved');
    assert.equal(welcome.friends_id, 'maple-river');
    assert.equal(welcome.update_required, false);
    assert.equal(welcome.host_list, null);
    assert.equal(host.liveCount(), 1);
    await client.close();
    await waitFor(() => host.liveCount() === 0);
});

test('a helper holding an older list gets the current one in its welcome', async (t) => {
    const { url } = await startMain(t, { version: 5 });
    const client = await TestClient.connect(url);
    const welcome = await client.checkin(identity(), { listVersion: 2 });
    assert.ok(welcome.host_list.payload);
    assert.equal(JSON.parse(Buffer.from(welcome.host_list.payload, 'base64url')).version, 5);
    client.close();
});

test('signatures from another key, for another host or over another challenge are refused', async (t) => {
    const { url, host } = await startMain(t);
    const who = identity();
    const cases = [
        { name: 'wrong key', options: { signer: keyPair() } },
        { name: 'other host id', options: { hostId: 'alt-sg' } },
        { name: 'replayed challenge', options: { challengeOverride: Buffer.alloc(32, 7) } },
    ];
    for (const { name, options } of cases) {
        const client = await TestClient.connect(url);
        const reply = await client.checkin(who, options);
        assert.equal(reply.type, 'error', name);
        assert.equal(reply.code, 'bad_signature', name);
        assert.equal((await client.closed).code, CLOSE.policy, name);
    }
    assert.equal(host.liveCount(), 0);
});

test('a signature captured on one connection does not verify on the next', async (t) => {
    const { url } = await startMain(t);
    const who = identity();
    const first = await TestClient.connect(url);
    const firstChallenge = decodeBase64url((await first.challenge()).nonce, 32);
    assert.equal((await first.checkin(who)).type, 'welcome');
    first.close();
    const second = await TestClient.connect(url);
    const reply = await second.checkin(who, { challengeOverride: firstChallenge });
    assert.equal(reply.code, 'bad_signature');
});

test('malformed check-ins, binary frames and unknown types close the connection', async (t) => {
    const { url } = await startMain(t);
    const bad = [
        (c) => c.send('checkin', { identity_key: 'short', friends_id: 'maple-river', reserved: false,
            app_version: '1', protocol: 1, list_version: 1, sig: 'x' }),
        (c) => c.ws.send(Buffer.from([1, 2, 3])),
        (c) => c.sendRaw('{not json'),
        (c) => c.send('teleport', {}),
        (c) => c.sendRaw(JSON.stringify({ type: 'checkin' })),
    ];
    for (const send of bad) {
        const client = await TestClient.connect(url);
        await client.challenge();
        send(client);
        const reply = await client.next();
        assert.equal(reply.type, 'error');
        assert.equal((await client.closed).code, CLOSE.policy);
    }
});

test('a connection that never checks in is closed', async (t) => {
    const { url } = await startMain(t, { env: { FRIENDS_CHECKIN_TIMEOUT_MS: '200' } });
    const client = await TestClient.connect(url);
    await client.challenge();
    const reply = await client.next(3000);
    assert.equal(reply.code, 'checkin_timeout');
    assert.equal((await client.closed).code, CLOSE.policy);
});

test('a protocol older than the minimum gets update_required but still checks in', async (t) => {
    const { url } = await startMain(t, { env: { FRIENDS_MIN_PROTOCOL: '2' } });
    const client = await TestClient.connect(url);
    const welcome = await client.checkin(identity(), { protocol: 1 });
    assert.equal(welcome.update_required, true);
    assert.equal(welcome.reservation, 'reserved');
    client.close();
});

test('a newer connection for the same identity closes the older one', async (t) => {
    const { url, host } = await startMain(t);
    const who = identity();
    const old = await TestClient.connect(url);
    await old.checkin(who);
    const fresh = await TestClient.connect(url);
    await fresh.checkin(who);
    assert.equal((await old.closed).code, CLOSE.replaced);
    assert.equal(host.liveCount(), 1);
    fresh.close();
});

test('a second check-in on one connection is refused', async (t) => {
    const { url } = await startMain(t);
    const client = await TestClient.connect(url);
    const who = identity();
    await client.checkin(who);
    const reply = await client.checkin(who);
    assert.equal(reply.code, 'bad_request');
});

test('a flood of messages is cut off', async (t) => {
    const { url } = await startMain(t, { env: { FRIENDS_RATE_MESSAGES_PER_10S: '3' } });
    const client = await TestClient.connect(url);
    await client.checkin(identity());
    for (let i = 0; i < 5; i++) client.send('reserve', { friends_id: `word-word${'abcde'[i]}` });
    const replies = [];
    for (;;) {
        const msg = await client.next();
        replies.push(msg);
        if (msg.type === 'error') break;
    }
    assert.equal(replies.at(-1).code, 'rate_limited');
    assert.equal((await client.closed).code, CLOSE.tryLater);
});

test('too many connections from one address are refused before the upgrade', async (t) => {
    const { url } = await startMain(t, { env: { FRIENDS_RATE_CONNECTIONS_PER_MINUTE: '2' } });
    const a = await TestClient.connect(url);
    const b = await TestClient.connect(url);
    await assert.rejects(TestClient.connect(url), /HTTP 429/);
    a.close();
    b.close();
});

test('behind the ingress the limit counts the forwarded address, only from a configured proxy', async (t) => {
    const env = { FRIENDS_RATE_CONNECTIONS_PER_MINUTE: '1', FRIENDS_TRUSTED_PROXY: '10.9.0.0/16, 127.0.0.1' };
    const { url } = await startMain(t, { env });
    const a = await TestClient.connect(url, { headers: { 'X-Real-IP': '203.0.113.1' } });
    const b = await TestClient.connect(url, { headers: { 'X-Real-IP': '203.0.113.2' } });
    await assert.rejects(TestClient.connect(url, { headers: { 'X-Real-IP': '203.0.113.1' } }), /HTTP 429/);
    a.close();
    b.close();
    // A peer outside FRIENDS_TRUSTED_PROXY (here every client, from 127.0.0.1) cannot choose its budget with the
    // header, as a container beside the ingress would try to.
    const elsewhere = await startMain(t, { env: { FRIENDS_RATE_CONNECTIONS_PER_MINUTE: '1',
        FRIENDS_TRUSTED_PROXY: '172.18.0.5' } });
    const c = await TestClient.connect(elsewhere.url, { headers: { 'X-Real-IP': '203.0.113.3' } });
    await assert.rejects(TestClient.connect(elsewhere.url, { headers: { 'X-Real-IP': '203.0.113.4' } }),
        /HTTP 429/);
    c.close();
    assert.ok(elsewhere.logs.some((line) => line.includes('proxy_untrusted')), 'an ignored header is logged');
    const untrusted = await startMain(t, { env: { FRIENDS_RATE_CONNECTIONS_PER_MINUTE: '1' } });
    const d = await TestClient.connect(untrusted.url, { headers: { 'X-Real-IP': '203.0.113.5' } });
    await assert.rejects(TestClient.connect(untrusted.url, { headers: { 'X-Real-IP': '203.0.113.6' } }), /HTTP 429/);
    d.close();
});

test('the old trust-everything switch is refused at start, and proxies must be addresses', async (t) => {
    await assert.rejects(startMain(t, { env: { FRIENDS_TRUST_PROXY: '1' } }), /FRIENDS_TRUSTED_PROXY/);
    await assert.rejects(startMain(t, { env: { FRIENDS_TRUSTED_PROXY: 'ingress' } }), /FRIENDS_TRUSTED_PROXY/);
    await assert.rejects(startMain(t, { env: { FRIENDS_TRUSTED_PROXY: '10.0.0.0/40' } }), /FRIENDS_TRUSTED_PROXY/);
});

test('only /v1 upgrades; plain HTTP gets 404 except the health check', async (t) => {
    const { port } = await startMain(t);
    await assert.rejects(TestClient.connect(`ws://127.0.0.1:${port}/v2`), /HTTP 404/);
    assert.equal((await fetch(`http://127.0.0.1:${port}/`)).status, 404);
    assert.equal((await fetch(`http://127.0.0.1:${port}/stats.json`)).status, 404);
    const health = await fetch(`http://127.0.0.1:${port}/healthz`);
    assert.equal(health.status, 200);
});

test('a peer that stops answering pings is dropped and no longer counted online', async (t) => {
    const { url, host } = await startMain(t, { env: { FRIENDS_PING_INTERVAL_MS: '100' } });
    const client = await TestClient.connect(url);
    await client.checkin(identity());
    assert.equal(host.liveCount(), 1);
    // Stop the socket from answering pings, as a sleeping Mac would.
    client.ws._socket.pause();
    await waitFor(() => host.liveCount() === 0, { timeoutMs: 5000 });
    client.terminate();
});

test('the host refuses to start without a list that verifies', async (t) => {
    const admin = keyPair();
    const stranger = keyPair();
    const listText = signList(listPayload({ entries: [{ id: 'main-hk', key: keyPair(), priority: 1 }] }), [stranger]);
    await assert.rejects(startMain(t, { admin, listText }), /does not verify/);
    await assert.rejects(startMain(t, { admin, listText: null }), /no verified host list/);
});
