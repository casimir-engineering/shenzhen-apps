// How many opens reach one device, and from whom: one caller, or one network, cannot use up a device's opens, and
// the people it has answered lately keep a reserve of their own. Over-budget opens are dropped silently.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { IncomingGate } from '../src/online-incoming.js';
import { ONLINE_LIMITS } from '../src/online-protocol.js';
import { FakeClock, startPair } from './helpers.js';
import { FakeHelper, from, nextOf, nowS, onlineEnv, startOnline, waitFor } from './online-helpers.js';

const PROXIED = { FRIENDS_TRUSTED_PROXY: '127.0.0.1' };

async function withBob(t, env = PROXIED) {
    const started = await startOnline(t, { env });
    const bob = await FakeHelper.connect(started.url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(started.clock) });
    return { ...started, bob };
}

const incomingCount = (helper) => helper.queue.filter((m) => m.type === 'sig_incoming').length;
const settle = () => new Promise((resolve) => setTimeout(resolve, 150));

async function openMany(caller, target, n) {
    const sids = [];
    for (let i = 0; i < n; i++) sids.push((await caller.open({ rdv_key: target.key })).sid);
    return sids;
}

test('one caller flooding a device cannot keep a second caller out', async (t) => {
    const { url, bob } = await withBob(t, {});
    const mallory = await FakeHelper.connect(url, { friendsId: 'sly-ferret' });
    const carol = await FakeHelper.connect(url, { friendsId: 'gentle-moth' });
    await openMany(mallory, bob, ONLINE_LIMITS.incomingPerCallerPerMinute + 2);
    await waitFor(() => incomingCount(bob) === ONLINE_LIMITS.incomingPerCallerPerMinute);
    await settle();
    assert.equal(incomingCount(bob), 10, 'ten a minute from one caller');
    const [sid] = await openMany(carol, bob, 1);
    await waitFor(() => bob.queue.some((m) => m.type === 'sig_incoming' && m.sid === sid));
    for (const helper of [mallory, carol, bob]) helper.close();
});

test('callers from one network share 20 opens a minute toward one device; IPv6 counts by /56', async (t) => {
    const { url, clock, bob } = await withBob(t);
    const callers = [];
    for (const address of ['2001:db8:0:1::5', '2001:db8:0:2::5', '2001:db8:0:3::5']) {
        callers.push(await FakeHelper.connect(url, { friendsId: 'sly-ferret', headers: from(address) }));
    }
    for (const caller of callers) await openMany(caller, bob, 10);
    await waitFor(() => incomingCount(bob) === ONLINE_LIMITS.incomingPerPrefixPerMinute);
    await settle();
    assert.equal(incomingCount(bob), 20, 'three /64s of one /56 are one network');
    const elsewhere = await FakeHelper.connect(url, { friendsId: 'gentle-moth', headers: from('2001:db8:0:100::5') });
    const [sid] = await openMany(elsewhere, bob, 1);
    await waitFor(() => bob.queue.some((m) => m.type === 'sig_incoming' && m.sid === sid));
    clock.advance(60_000);
    const [later] = await openMany(callers[2], bob, 1);
    await waitFor(() => bob.queue.some((m) => m.type === 'sig_incoming' && m.sid === later), { timeoutMs: 2000 });
    for (const helper of [...callers, elsewhere, bob]) helper.close();
});

test('a device gets 60 opens a minute from strangers, and the people it answered lately keep a reserve', async (t) => {
    const { url, bob } = await withBob(t);
    const friend = await FakeHelper.connect(url, { friendsId: 'calm-heron', headers: from('192.0.2.50') });
    const [first] = await openMany(friend, bob, 1);
    await nextOf(bob.client, 'sig_incoming');
    bob.message(first, 'ik-2');
    await nextOf(friend.client, 'sig_msg');
    const strangers = [];
    for (let i = 1; i <= 7; i++) {
        strangers.push(await FakeHelper.connect(url, { friendsId: 'sly-ferret', headers: from(`198.51.100.${i}`) }));
    }
    for (const stranger of strangers) await openMany(stranger, bob, 10);
    // The friend's first open came from the same budget, and was taken from the queue above.
    await waitFor(() => incomingCount(bob) === ONLINE_LIMITS.incomingPerMinute - 1);
    const late = await FakeHelper.connect(url, { friendsId: 'quiet-fox', headers: from('198.51.100.99') });
    const [dropped] = await openMany(late, bob, 1);
    const [reserved] = await openMany(friend, bob, 1);
    await waitFor(() => bob.queue.some((m) => m.type === 'sig_incoming' && m.sid === reserved));
    await settle();
    assert.ok(!bob.queue.some((m) => m.sid === dropped), 'a stranger over the budget is dropped');
    assert.equal(incomingCount(bob), 60);
    for (const helper of [...strangers, late, friend, bob]) helper.close();
});

test('across hosts, the caller\'s host tells the target\'s host that the caller was answered before', async (t) => {
    const pair = await startPair(t, { mainEnv: onlineEnv(), replicaEnv: onlineEnv() });
    await pair.linkUp();
    const { main, replica, clock } = pair;
    const bob = await FakeHelper.connect(replica.url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(clock) });
    await waitFor(() => main.host.online.records.size === 1);
    const friend = await FakeHelper.connect(main.url, { friendsId: 'calm-heron' });
    const sent = [];
    const { federation } = main.host.online;
    const send = federation.send.bind(federation);
    federation.send = (hostId, type, body) => {
        if (type === 'sig_route' && body.op === 'open') sent.push(body.known);
        return send(hostId, type, body);
    };
    const first = await friend.open({ rdv_key: bob.key });
    await nextOf(bob.client, 'sig_incoming');
    bob.message(first.sid, 'ik-2');
    await nextOf(friend.client, 'sig_msg');
    await friend.open({ rdv_key: bob.key });
    await nextOf(bob.client, 'sig_incoming');
    assert.deepEqual(sent, [false, true]);
    assert.equal(replica.host.online.incoming.reserve.entries.size, 1, 'the second open came from the reserve');
    friend.close();
    bob.close();
});

test('who was answered is remembered as keyed hashes, for 7 days, within a bounded memory', () => {
    const clock = new FakeClock();
    const gate = new IncomingGate({ clock, maxKnown: 3 });
    gate.answered('bob', 'alice');
    assert.ok(gate.isKnown('bob', 'alice'));
    assert.ok(!gate.isKnown('alice', 'bob'), 'answered, not the other way round');
    assert.ok(!gate.isKnown('bob', null), 'a browser is never known');
    assert.ok(![...gate.known.keys()].some((key) => key.includes('alice') || key.includes('bob')));
    clock.advance(ONLINE_LIMITS.answeredMemoryMs + 1);
    assert.ok(!gate.isKnown('bob', 'alice'));
    for (const caller of ['a', 'b', 'c', 'd']) gate.answered('bob', caller);
    assert.equal(gate.known.size, 3);
    assert.ok(!gate.isKnown('bob', 'a') && gate.isKnown('bob', 'd'), 'the oldest goes first');
});
