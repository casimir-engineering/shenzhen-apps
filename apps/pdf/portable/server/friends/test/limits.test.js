// Connection limits (HOST-PROTOCOL.md § Errors, close codes and limits): per-address budgets keyed by IPv6 /64 and
// IPv4 address, open connections per address, a separate budget for connections that have not checked in, and the
// message size a helper may send. Each test here failed against the limits before they were keyed and split.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { addressPrefix, prefixKey } from '../src/address.js';
import { CLOSE, MAX_CHECKIN_BYTES, MAX_CLIENT_MESSAGE_BYTES } from '../src/protocol.js';
import { DailyCap, RateLimiter } from '../src/ratelimit.js';
import { FakeClock, TestClient, identity, startMain, waitFor } from './helpers.js';

const PROXIED = { FRIENDS_TRUSTED_PROXY: '127.0.0.1' };
const from = (address) => ({ headers: { 'X-Real-IP': address } });

test('addresses reduce to their IPv4 address or IPv6 /64', () => {
    const cases = {
        '203.0.113.9': '4:203.0.113.9',
        '::ffff:203.0.113.9': '4:203.0.113.9',
        '::FFFF:198.51.100.1': '4:198.51.100.1',
        '2001:db8:1:2::1': '6:2001:db8:1:2',
        '2001:0db8:0001:0002:ffff:ffff:ffff:ffff': '6:2001:db8:1:2',
        '2001:db8:1:2:3:4:5:6%en0': '6:2001:db8:1:2',
        '64:ff9b::192.0.2.1': '6:64:ff9b:0:0',
        '::1': '6:0:0:0:0',
        'not an address': null,
        '': null,
    };
    for (const [address, prefix] of Object.entries(cases)) assert.equal(addressPrefix(address), prefix, address);
    assert.equal(prefixKey('6:2001:db8:1:2'), prefixKey('6:2001:db8:1:2'));
    assert.notEqual(prefixKey('6:2001:db8:1:2'), prefixKey('6:2001:db8:1:3'));
    assert.ok(!prefixKey('4:203.0.113.9').includes('203'), 'the key is a keyed hash, not the address');
});

test('online Friends\' wide key counts IPv6 by /56 and IPv4 by address', () => {
    const wide = (address) => addressPrefix(address, { wide: true });
    assert.equal(wide('2001:db8:1:2::1'), '6/56:2001:db8:1:0');
    assert.equal(wide('2001:db8:1:ff::1'), wide('2001:db8:1:2::1'), 'one /56');
    assert.notEqual(wide('2001:db8:1:100::1'), wide('2001:db8:1:2::1'), 'the next /56');
    assert.equal(wide('::ffff:203.0.113.9'), '4:203.0.113.9');
    assert.equal(wide('nonsense'), null);
});

test('every address in one IPv6 /64 shares one connection budget', async (t) => {
    const { url } = await startMain(t, { env: { ...PROXIED, FRIENDS_RATE_CONNECTIONS_PER_MINUTE: '2' } });
    const open = [await TestClient.connect(url, from('2001:db8:1:2::1')),
        await TestClient.connect(url, from('2001:db8:1:2:ffff::9'))];
    await assert.rejects(TestClient.connect(url, from('2001:db8:1:2:abcd::3')), /HTTP 429/);
    open.push(await TestClient.connect(url, from('2001:db8:1:3::1')));
    open.push(await TestClient.connect(url, from('::ffff:203.0.113.7')), await TestClient.connect(url,
        from('203.0.113.7')));
    await assert.rejects(TestClient.connect(url, from('203.0.113.7')), /HTTP 429/,
        'a mapped address counts as its IPv4 address');
    for (const client of open) client.close();
});

test('one address may hold at most six open connections', async (t) => {
    const env = { ...PROXIED, FRIENDS_MAX_CONNECTIONS_PER_ADDRESS: '', FRIENDS_RATE_CONNECTIONS_PER_MINUTE: '100' };
    const { url, host } = await startMain(t, { env });
    assert.equal(host.config.limits.connectionsPerAddressOpen, 6);
    const six = [];
    for (let i = 0; i < 6; i++) six.push(await TestClient.connect(url, from(`2001:db8:5:5::${i + 1}`)));
    await assert.rejects(TestClient.connect(url, from('2001:db8:5:5::99')), /HTTP 429/);
    const other = await TestClient.connect(url, from('2001:db8:5:6::1'));
    await six[0].close();
    await waitFor(() => host.admission.open.size === 2 && [...host.admission.open.values()].includes(5));
    six.push(await TestClient.connect(url, from('2001:db8:5:5::7')));
    for (const client of [...six, other]) client.close();
});

test('connections that have not checked in never take a checked-in helper\'s slot', async (t) => {
    const env = { FRIENDS_MAX_CONNECTIONS: '2', FRIENDS_MAX_UNAUTHENTICATED: '5' };
    const { url } = await startMain(t, { env });
    const idle = [];
    for (let i = 0; i < 4; i++) {
        const client = await TestClient.connect(url);
        await client.challenge();
        idle.push(client);
    }
    // Before the split, four idle sockets filled a cap of two and every real helper got 503.
    const helpers = [];
    for (let i = 0; i < 2; i++) {
        const helper = await TestClient.connect(url);
        assert.equal((await helper.checkin(identity())).type, 'welcome');
        helpers.push(helper);
    }
    await assert.rejects(TestClient.connect(url), /HTTP 503/, 'checked-in connections are at their cap');
    for (const client of [...idle, ...helpers]) client.close();
});

test('connections that have not checked in share a budget of their own, 200 by default, with 10 s each', async (t) => {
    const defaults = await startMain(t);
    assert.equal(defaults.host.config.limits.maxUnauthenticated, 200);
    assert.equal(defaults.host.config.limits.checkinTimeoutMs, 10_000);
    const { url } = await startMain(t, { env: { FRIENDS_MAX_UNAUTHENTICATED: '3' } });
    const idle = [];
    for (let i = 0; i < 3; i++) idle.push(await TestClient.connect(url));
    await assert.rejects(TestClient.connect(url), /HTTP 503/);
    const helper = idle[0];
    assert.equal((await helper.checkin(identity())).type, 'welcome');
    const next = await TestClient.connect(url);
    for (const client of [...idle, next]) client.close();
});

test('a helper connection carries at most 8 KiB per message, fragments included, but for its check-in', async (t) => {
    const { url } = await startMain(t);
    // Before check-in only a check-in may be larger (it may carry a device chain), and never past its own limit.
    const big = await TestClient.connect(url);
    await big.challenge();
    big.sendRaw(JSON.stringify({ type: 'checkin', v: 1, pad: 'x'.repeat(MAX_CHECKIN_BYTES) }));
    assert.equal((await big.closed).code, 1009);
    const large = await TestClient.connect(url);
    await large.challenge();
    large.sendRaw(JSON.stringify({ type: 'checkin', v: 1, pad: 'x'.repeat(MAX_CLIENT_MESSAGE_BYTES) }));
    assert.equal((await large.next()).code, 'bad_request', 'a large check-in is read, then refused on its merits');
    const release = await TestClient.connect(url);
    await release.challenge();
    release.sendRaw(JSON.stringify({ type: 'release', v: 1, pad: 'x'.repeat(MAX_CLIENT_MESSAGE_BYTES) }));
    assert.equal((await release.closed).code, 1009);
    // After check-in, 8 KiB again: in one message, and parked in an unfinished fragmented one.
    const after = await TestClient.connect(url);
    assert.equal((await after.checkin(identity())).type, 'welcome');
    after.sendRaw(JSON.stringify({ type: 'reserve', v: 1, pad: 'x'.repeat(MAX_CLIENT_MESSAGE_BYTES) }));
    assert.equal((await after.closed).code, 1009);
    const fragments = await TestClient.connect(url);
    assert.equal((await fragments.checkin(identity())).type, 'welcome');
    fragments.ws.send('{"type":"reserve","v":1,"pad":"', { fin: false });
    for (let i = 0; i < 3; i++) fragments.ws.send('y'.repeat(3000), { fin: false });
    const closed = await Promise.race([fragments.closed, new Promise((r) => setTimeout(() => r(null), 3000))]);
    assert.equal(closed?.code, 1009);
});

test('host links keep the larger limit and may do nothing but link', async (t) => {
    const { url } = await startMain(t);
    const link = await TestClient.connect(`${url}?link=1`);
    await link.challenge();
    link.send('host_hello', { host_id: 'alt-sg', sig: 'x', mac: 'y', pad: 'z'.repeat(20_000) });
    assert.equal((await link.next()).code, 'bad_signature', 'a 20 KB hello is read, then refused on its merits');
    const linkCheckin = await TestClient.connect(`${url}?link=1`);
    assert.equal((await linkCheckin.checkin(identity())).code, 'bad_request');
    const helperHello = await TestClient.connect(url);
    await helperHello.challenge();
    helperHello.send('host_hello', { host_id: 'alt-sg' });
    assert.equal((await helperHello.next()).code, 'bad_request');
    assert.equal((await helperHello.closed).code, CLOSE.policy);
});

test('limiter maps are bounded: a flood of new keys is refused rather than remembered', () => {
    const clock = new FakeClock();
    const limiter = new RateLimiter({ limit: 5, windowMs: 60_000, maxKeys: 2, clock });
    assert.ok(limiter.allow('a') && limiter.allow('b'));
    assert.equal(limiter.allow('c'), false);
    clock.advance(11 * 60_000);
    assert.equal(limiter.allow('c'), true, 'forgotten keys make room');
    const cap = new DailyCap({ limit: 1, maxKeys: 1 });
    assert.ok(cap.take('a', '2026-10-12'));
    assert.equal(cap.take('b', '2026-10-12'), false);
    assert.ok(cap.take('b', '2026-10-13'), 'a new day starts empty');
});
