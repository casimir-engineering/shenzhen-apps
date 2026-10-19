// The relay held per network and the reserve kept for friends (relay-allocations.js; HOST-PROTOCOL-ONLINE.md § Relay
// credentials). Helper identities cost nothing to make, so a network (an IPv4 /24 or an IPv6 /56) holds at most 12 at
// once, and a quarter of the relay's ports is kept for pairs of friends who answered each other lately, 4 a pair.
// Addresses come from X-Real-IP, believed from 127.0.0.1 in these suites; nothing leaves 127.0.0.1.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { addressPrefix } from '../src/address.js';
import { ONLINE_LIMITS } from '../src/online-protocol.js';
import { RelayAllocationCap } from '../src/relay-allocations.js';
import { FakeClock } from './helpers.js';
import { FakeHelper, from, nextOf, nowS, startOnline } from './online-helpers.js';

const L = ONLINE_LIMITS;

test('the net key counts IPv4 by /24 and IPv6 by /56', () => {
    const net = (address) => addressPrefix(address, { net: true });
    assert.equal(net('198.51.100.7'), '4/24:198.51.100');
    assert.equal(net('198.51.100.200'), net('198.51.100.7'), 'one /24');
    assert.notEqual(net('198.51.101.7'), net('198.51.100.7'), 'the next /24');
    assert.equal(net('::ffff:198.51.100.9'), '4/24:198.51.100');
    assert.equal(net('2001:db8:1:ff::1'), addressPrefix('2001:db8:1:2::1', { wide: true }), 'one /56');
    assert.equal(net('nonsense'), null);
});

test('a credential counts in its own, its network\'s and the relay\'s share; pairs draw on the reserve', () => {
    const clock = new FakeClock();
    const held = new RelayAllocationCap({ clock });
    const expiresS = nowS(clock) + 300;
    let n = 0;
    const take = (shares) => {
        const owners = held.admit({ capacity: 16, reserve: 4, pair: null, ...shares });
        if (owners) held.issued({ attempt: `a${n++}`, owners, expiresS });
        return owners;
    };
    const own = (i) => [`identity:${i}`, 4];
    const net = (i) => [`net:${i}`, 12];
    for (let i = 0; i < 3; i++) for (let j = 0; j < 4; j++) assert.ok(take({ own: own(i), net: net('n1') }));
    assert.equal(take({ own: own(3), net: net('n1') }), null, 'the network holds 12, whoever asks');
    assert.equal(take({ own: own(3), net: net('n2') }), null, 'the general part (16 - 4) is full');
    const pair = ['pair:x', 4];
    assert.deepEqual(take({ own: own(3), net: net('n2'), pair }), ['identity:3', 'net:n2', 'relay', 'pair:x']);
    for (let i = 0; i < 3; i++) assert.ok(take({ own: own(4 + i), net: net('n3'), pair }));
    assert.equal(take({ own: own(8), net: net('n4'), pair }), null, 'a pair holds 4 of the reserve');
    assert.equal(take({ own: own(8), net: net('n4'), pair: ['pair:y', 4] }), null, 'the relay is full');
    clock.advance(301_000);
    held.prune();
    assert.equal(held.held('relay'), 0);
    assert.equal(held.byOwner.size, 0, 'every share is forgotten with its credentials');
});

test('when no more credentials can be remembered, none is issued', () => {
    const clock = new FakeClock();
    const held = new RelayAllocationCap({ clock, maxTracked: 2 });
    const shares = { own: ['identity:a', 4], net: ['net:a', 12], pair: null, capacity: 256, reserve: 64 };
    for (let i = 0; i < 2; i++) held.issued({ attempt: `a${i}`, owners: held.admit(shares),
        expiresS: nowS(clock) + 300 });
    assert.equal(held.admit({ ...shares, own: ['identity:b', 4], net: ['net:b', 12] }), null);
});

async function helperAt(url, address, friendsId) {
    return FakeHelper.connect(url, { friendsId, headers: from(address) });
}

async function answeredSid(caller, target) {
    const opened = await caller.open({ rdv_key: target.key });
    await nextOf(target.client, 'sig_incoming');
    target.message(opened.sid, 'answer');
    await nextOf(caller.client, 'sig_msg');
    return opened.sid;
}

// `caller` asks for `count` credentials over fresh sids to `target`, two a sid; returns the replies' types.
async function ask(caller, target, count) {
    const types = [];
    let sid = null;
    for (let i = 0; i < count; i++) {
        if (i % L.relayCredentialsPerSidEnd === 0) sid = await answeredSid(caller, target);
        types.push((await caller.credentials(sid)).type);
    }
    return types;
}

const OK = 'relay_credentials_result';
const NO = 'relay_refused';

test('one /24 holds 12 however many identities ask; another network is not held back', async (t) => {
    const { url, clock } = await startOnline(t, { env: { FRIENDS_TRUSTED_PROXY: '127.0.0.1' } });
    const bob = await helperAt(url, '203.0.113.1', 'bold-otter');
    await bob.publish({ nowS: nowS(clock) });
    const helpers = [];
    for (let i = 0; i < 4; i++) helpers.push(await helperAt(url, `198.51.100.${10 + i}`, `calm-heron-${i}`));
    for (let i = 0; i < 3; i++) assert.deepEqual(await ask(helpers[i], bob, L.relayHeldPerIdentity), Array(4).fill(OK));
    assert.deepEqual(await ask(helpers[3], bob, 1), [NO], 'a fourth identity in the same /24');
    const elsewhere = await helperAt(url, '198.51.101.10', 'keen-lynx');
    assert.deepEqual(await ask(elsewhere, bob, 1), [OK]);
    for (const helper of [bob, elsewhere, ...helpers]) helper.close();
});

test('with the relay full of strangers, friends who answered each other still get 4 of the reserve', async (t) => {
    // 16 ports: 12 for anyone, 4 kept for friends.
    const env = { FRIENDS_TRUSTED_PROXY: '127.0.0.1', FRIENDS_TURN_PORTS: '49160-49175' };
    const { url, clock } = await startOnline(t, { env });
    const tom = await helperAt(url, '203.0.113.9', 'tall-moose');
    const bob = await helperAt(url, '203.0.113.1', 'bold-otter');
    const dave = await helperAt(url, '203.0.113.2', 'dry-wren');
    for (const target of [tom, bob, dave]) await target.publish({ nowS: nowS(clock) });
    const strangers = [];
    for (let i = 0; i < 3; i++) strangers.push(await helperAt(url, `198.51.${100 + i}.1`, `sly-ferret-${i}`));
    for (const stranger of strangers) assert.deepEqual(await ask(stranger, tom, 4), Array(4).fill(OK));
    const alice = await helperAt(url, '192.0.2.1', 'calm-heron');
    assert.deepEqual(await ask(alice, bob, 1), [NO], 'bob has never answered alice before this sid');
    const sid = await answeredSid(alice, bob);
    assert.deepEqual([(await alice.credentials(sid)).type, (await alice.credentials(sid)).type], [OK, OK]);
    assert.deepEqual([(await bob.credentials(sid)).type, (await bob.credentials(sid)).type], [OK, OK],
        'bob draws on the same pair\'s part');
    const carol = await helperAt(url, '192.0.2.77', 'warm-finch');
    await answeredSid(carol, dave);
    assert.deepEqual(await ask(carol, dave, 1), [NO], 'the reserve is used up: the relay is full');
    for (const helper of [tom, bob, dave, alice, carol, ...strangers]) helper.close();
});
