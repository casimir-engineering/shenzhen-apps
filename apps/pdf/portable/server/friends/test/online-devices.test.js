// Online Friends with several devices (protocol 3): a device that checked in for a person publishes under the
// person's rendezvous key, so friends reach every device from the root key they pin; and a new computer's join
// request reaches every connected device of the person holding a Friends ID, on any host, first answer wins, kept
// nowhere but in its sid and capped per person.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { identityHash } from '../src/keys.js';
import { ONLINE_LIMITS } from '../src/online-protocol.js';
import { CLOSE } from '../src/protocol.js';
import { ChainBuilder, device } from './chain-builder.js';
import { IDENTITY_SECRET } from './helpers.js';
import { FakeHelper, nextOf, nowS, silent, startOnline, startTrio, text } from './online-helpers.js';

// The person's first Mac and a laptop that joined it, both online with protocol 3 and a record published.
async function person(url, clock, { laptopUrl = url } = {}) {
    const [macKey, laptopKey] = [device(), device()];
    const chain = new ChainBuilder(macKey).add(laptopKey);
    const mac = await FakeHelper.connect(url, { who: macKey, protocol: 3, friendsId: 'maple-river' });
    const laptop = await FakeHelper.connect(laptopUrl, { who: laptopKey, root: macKey, chain: chain.bytes,
        protocol: 3, friendsId: 'other-name' });
    assert.equal(laptop.welcome.friends_id, 'maple-river');
    for (const d of [mac, laptop]) assert.equal((await d.publish({ nowS: nowS(clock) })).reply.accepted, true);
    return { mac, laptop, macKey };
}

test('a joined device is reached by its person key and by its person ID', async (t) => {
    const { url, clock, online } = await startOnline(t);
    const { mac, laptop } = await person(url, clock);
    assert.equal(online.records.routesByKey(mac.rdvKey).length, 2, 'both devices under the root key');
    const friend = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    for (const to of [{ rdv_key: mac.key }, { friends_id: 'maple-river' }]) {
        const opened = await friend.open(to, Buffer.from('hello'));
        for (const d of [mac, laptop]) assert.equal((await nextOf(d.client, 'sig_incoming')).sid, opened.sid);
        friend.send('sig_close', { sid: opened.sid });
    }
    for (const h of [friend, mac, laptop]) h.close();
});

test('a join request reaches every device of the ID holder, and the first to answer takes it', async (t) => {
    const { url, clock } = await startOnline(t);
    const { mac, laptop } = await person(url, clock);
    const newcomer = await FakeHelper.connect(url, { protocol: 3, friendsId: 'fresh-start' });
    const opened = await newcomer.open({ join: 'maple-river' }, Buffer.from('join request'));
    assert.equal(opened.type, 'sig_opened');
    for (const d of [mac, laptop]) {
        const incoming = await nextOf(d.client, 'sig_incoming');
        assert.deepEqual([incoming.sid, incoming.via, text(incoming.payload)], [opened.sid, 'join', 'join request']);
    }
    laptop.message(opened.sid, 'approved: start the code exchange');
    assert.equal(text((await nextOf(newcomer.client, 'sig_msg')).payload), 'approved: start the code exchange');
    assert.equal((await nextOf(mac.client, 'sig_closed')).reason, 'answered_elsewhere');
    // An ID nobody holds looks the same to the newcomer.
    assert.equal((await newcomer.open({ join: 'nobody-here' })).type, 'sig_opened');
    for (const h of [newcomer, mac, laptop]) h.close();
});

test('join requests are protocol 3 only, and capped per person', async (t) => {
    const { url, clock, online } = await startOnline(t);
    const { mac, laptop, macKey } = await person(url, clock);
    const old = await FakeHelper.connect(url, { protocol: 2, friendsId: 'old-timer' });
    old.send('sig_open', { req: 1, to: { join: 'maple-river' }, payload: 'eA' });
    assert.equal((await nextOf(old.client, 'error')).code, 'bad_request');
    assert.equal((await old.client.closed).code, CLOSE.policy);
    // Once the person has had their hour's join requests, more reach nobody; the sender cannot tell.
    const holder = identityHash(IDENTITY_SECRET, macKey.raw).toString('hex');
    assert.ok(online.budgets.joinTarget.take(holder, ONLINE_LIMITS.joinsPerPersonPerHour));
    const newcomer = await FakeHelper.connect(url, { protocol: 3, friendsId: 'fresh-start' });
    assert.equal((await newcomer.open({ join: 'maple-river' })).type, 'sig_opened');
    assert.ok(await silent(mac.client, 'sig_incoming') && await silent(laptop.client, 'sig_incoming'));
    // Ordinary opens by ID are not join requests and keep their own budget.
    assert.equal((await newcomer.open({ friends_id: 'maple-river' })).type, 'sig_opened');
    assert.equal((await nextOf(mac.client, 'sig_incoming')).via, 'id');
    for (const h of [newcomer, mac, laptop]) h.close();
});

test('a join request crosses hosts to devices connected elsewhere', async (t) => {
    const { clock, main, sg, tk } = await startTrio(t);
    const { mac, laptop } = await person(sg.url, clock, { laptopUrl: main.url });
    const newcomer = await FakeHelper.connect(tk.url, { protocol: 3, friendsId: 'fresh-start' });
    const opened = await newcomer.open({ join: 'maple-river' }, Buffer.from('join request'));
    for (const d of [mac, laptop]) {
        const incoming = await nextOf(d.client, 'sig_incoming', 5000);
        assert.deepEqual([incoming.via, text(incoming.payload)], ['join', 'join request']);
    }
    mac.message(opened.sid, 'approved');
    assert.equal(text((await nextOf(newcomer.client, 'sig_msg', 5000)).payload), 'approved');
    for (const h of [newcomer, mac, laptop]) h.close();
});
