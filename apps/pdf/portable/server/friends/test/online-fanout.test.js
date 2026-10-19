// One person with several devices (ADR 0010 § Several devices): every device keeps its own record under the
// person's one rendezvous key, and an open to that key reaches every connected device. The first to answer wins and
// the others are let go, on one host or across hosts; the caller sees one sid and one answer.
//
// In M2 a device's key is its identity key, so no helper can yet check in as a second device of someone else; these
// tests file a second device's record under the person's key directly, as multi-device check-in will.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ONLINE_LIMITS, rendezvousKey } from '../src/online-protocol.js';
import { encodeBase64url } from '../src/keys.js';
import { startPair } from './helpers.js';
import {
    FakeHelper, identity, nextOf, nextPeriod, nowS, onlineEnv, sealedBlob, silent, startOnline, text, waitFor,
} from './online-helpers.js';

// Moves `device`'s record (as `records` holds it) under `person`'s rendezvous key.
function addDevice(records, person, device) {
    const [record] = records.routesByKey(device.rdvKey);
    records.remove(record);
    records.store({ ...record, rdvKey: person.rdvKey }, record.session);
}

test('an open to a person reaches each device; the first to answer wins and the others are let go', async (t) => {
    const { url, clock, online } = await startOnline(t);
    const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    const laptop = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    const desktop = await FakeHelper.connect(url, { friendsId: 'brisk-wren' });
    for (const device of [laptop, desktop]) await device.publish({ nowS: nowS(clock) });
    addDevice(online.records, laptop, desktop);
    assert.equal(online.records.routesByKey(laptop.rdvKey).length, 2);
    const opened = await alice.open({ rdv_key: laptop.key }, Buffer.from('ik-1'));
    assert.equal(opened.type, 'sig_opened');
    for (const device of [laptop, desktop]) {
        const incoming = await nextOf(device.client, 'sig_incoming');
        assert.equal(incoming.sid, opened.sid);
        assert.equal(text(incoming.payload), 'ik-1');
    }
    alice.message(opened.sid, 'candidate before any answer');
    for (const device of [laptop, desktop]) {
        assert.equal(text((await nextOf(device.client, 'sig_msg')).payload), 'candidate before any answer');
    }
    desktop.message(opened.sid, 'ik-2 from the desktop');
    assert.equal(text((await nextOf(alice.client, 'sig_msg')).payload), 'ik-2 from the desktop');
    assert.equal((await nextOf(laptop.client, 'sig_closed')).reason, 'answered_elsewhere');
    laptop.message(opened.sid, 'too late');
    assert.equal((await nextOf(laptop.client, 'sig_closed')).reason, 'unknown');
    assert.ok(await silent(alice.client, 'sig_msg'), 'nothing from the device that lost');
    alice.message(opened.sid, 'candidate after the answer');
    assert.equal(text((await nextOf(desktop.client, 'sig_msg')).payload), 'candidate after the answer');
    assert.ok(await silent(laptop.client, 'sig_msg'));
    for (const helper of [alice, laptop, desktop]) helper.close();
});

test('each device replaces only its own record, and a lookup shows one of them', async (t) => {
    const { url, clock, online } = await startOnline(t);
    const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    const laptop = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    const desktop = await FakeHelper.connect(url, { friendsId: 'brisk-wren' });
    const sealed = sealedBlob();
    await desktop.publish({ nowS: nowS(clock) });
    addDevice(online.records, laptop, desktop);
    await laptop.publish({ sealed, nowS: nowS(clock) });
    assert.equal(online.records.routesByKey(laptop.rdvKey).length, 2, 'the laptop did not replace the desktop');
    nextPeriod(clock);
    alice.send('rdv_lookup', { req: 1, keys: [laptop.key] });
    const [shown] = (await nextOf(alice.client, 'rdv_records')).records;
    assert.equal(shown, encodeBase64url(sealed), 'the newest record published under the key');
    await desktop.close();
    await waitFor(() => online.records.routesByKey(laptop.rdvKey).length === 1);
    for (const helper of [alice, laptop]) helper.close();
});

test('an open names exactly one target', async (t) => {
    const { url } = await startOnline(t);
    const keys = Array.from({ length: 2 }, () => encodeBase64url(rendezvousKey(identity().raw)));
    for (const to of [{ rdv_keys: keys }, {}, { rdv_key: keys[0], friends_id: 'free-name' },
        { rdv_key: keys[0], extra: 1 }, { rdv_key: 'short' }, [keys[0]]]) {
        const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
        alice.send('sig_open', { req: 1, to, payload: 'cGF5bG9hZA' });
        assert.equal((await nextOf(alice.client, 'error')).code, 'bad_request', JSON.stringify(to).slice(0, 60));
    }
    assert.equal(ONLINE_LIMITS.targetKeysPerOpen, undefined, 'a friend needs only the person\'s key');
});

test('devices on two hosts: whichever answers first wins, and the other host lets its device go', async (t) => {
    const pair = await startPair(t, { mainEnv: onlineEnv(), replicaEnv: onlineEnv() });
    await pair.linkUp();
    const { main, replica, clock } = pair;
    const alice = await FakeHelper.connect(main.url, { friendsId: 'calm-heron' });
    const laptop = await FakeHelper.connect(main.url, { friendsId: 'bold-otter' });
    const desktop = await FakeHelper.connect(replica.url, { friendsId: 'brisk-wren' });
    for (const device of [laptop, desktop]) await device.publish({ nowS: nowS(clock) });
    await waitFor(() => main.host.online.records.size === 2);
    addDevice(main.host.online.records, laptop, desktop);

    // The device on the other host answers first.
    let opened = await alice.open({ rdv_key: laptop.key });
    await nextOf(laptop.client, 'sig_incoming');
    await nextOf(desktop.client, 'sig_incoming');
    desktop.message(opened.sid, 'from the replica');
    assert.equal(text((await nextOf(alice.client, 'sig_msg')).payload), 'from the replica');
    assert.equal((await nextOf(laptop.client, 'sig_closed')).reason, 'answered_elsewhere');

    // The device on the caller's host answers first.
    opened = await alice.open({ rdv_key: laptop.key });
    await nextOf(laptop.client, 'sig_incoming');
    await nextOf(desktop.client, 'sig_incoming');
    laptop.message(opened.sid, 'from the main host');
    assert.equal(text((await nextOf(alice.client, 'sig_msg')).payload), 'from the main host');
    assert.equal((await nextOf(desktop.client, 'sig_closed')).reason, 'answered_elsewhere');
    await waitFor(() => replica.host.online.sids.size === 1, { timeoutMs: 2000 });
    for (const helper of [alice, laptop, desktop]) helper.close();
});
