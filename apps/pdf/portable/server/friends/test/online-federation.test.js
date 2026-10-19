// Online Friends across hosts, over the real authenticated host links: a helper on either host of a pair is found,
// reached and answered from the other, replicas reach each other through the main host, and no host can place
// records for another host's helpers or keep them after the host's link goes down.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { encodeBase64url } from '../src/keys.js';
import { linkIdHash, newId } from '../src/online-protocol.js';
import { IDENTITY_SECRET, startPair } from './helpers.js';
import {
    FakeHelper, b64, guest, nextOf, nextPeriod, nowS, onlineEnv, startTrio, text, waitFor,
} from './online-helpers.js';

async function federation(t) {
    const pair = await startPair(t, { mainEnv: onlineEnv(), replicaEnv: onlineEnv() });
    await pair.linkUp();
    return { ...pair, mainOnline: pair.main.host.online, replicaOnline: pair.replica.host.online };
}

test('a helper on the replica is looked up, reached and answered from the main host', async (t) => {
    const { main, replica, clock, mainOnline, replicaOnline } = await federation(t);
    const bob = await FakeHelper.connect(replica.url, { friendsId: 'bold-otter' });
    const alice = await FakeHelper.connect(main.url, { friendsId: 'calm-heron' });
    const { fields } = await bob.publish({ nowS: nowS(clock) });
    await waitFor(() => mainOnline.records.size === 1);
    nextPeriod(clock);
    alice.send('rdv_lookup', { req: 1, keys: [bob.key] });
    assert.equal((await nextOf(alice.client, 'rdv_records')).records[0], fields.sealed);

    const opened = await alice.open({ rdv_key: bob.key }, Buffer.from('ik-1'));
    const incoming = await nextOf(bob.client, 'sig_incoming');
    assert.equal(incoming.sid, opened.sid);
    assert.equal(text(incoming.payload), 'ik-1');
    bob.message(opened.sid, 'ik-2');
    assert.equal(text((await nextOf(alice.client, 'sig_msg')).payload), 'ik-2');
    alice.message(opened.sid, 'candidate');
    assert.equal(text((await nextOf(bob.client, 'sig_msg')).payload), 'candidate');
    assert.equal(mainOnline.stats.day().answered_helper, 1, 'counted once, where the sid was opened');
    assert.equal(replicaOnline.stats.day().answered_helper, 0);
    // The replica's helper can get relay credentials for the sid, now answered on both sides.
    assert.equal((await bob.credentials(opened.sid)).type, 'relay_credentials_result');
    await bob.close();
    assert.equal((await nextOf(alice.client, 'sig_closed')).reason, 'gone');
    await waitFor(() => mainOnline.records.size === 0);
    alice.close();
});

test('Add by ID online crosses hosts: the replica\'s copy of the ID table finds a holder on the main host',
    async (t) => {
        const { main, replica, clock } = await federation(t);
        const bob = await FakeHelper.connect(main.url, { friendsId: 'bold-otter' });
        await bob.publish({ nowS: nowS(clock) });
        const alice = await FakeHelper.connect(replica.url, { friendsId: 'calm-heron' });
        await waitFor(() => replica.host.db.prepare('SELECT COUNT(*) AS n FROM identities WHERE friends_id = ?')
            .get('bold-otter').n === 1 && replica.host.online.records.size === 1);
        await alice.open({ friends_id: 'bold-otter' }, Buffer.from('nn-1'));
        assert.equal((await nextOf(bob.client, 'sig_incoming')).via, 'id');
        alice.close();
        bob.close();
    });

test('a browser on the main host reaches a link registered on the replica', async (t) => {
    const { main, replica, clock, mainOnline } = await federation(t);
    const mei = await FakeHelper.connect(replica.url, { friendsId: 'kind-mole' });
    const linkId = newId();
    mei.send('link_register', { link_id: linkId, expires: nowS(clock) + 86_400 });
    await nextOf(mei.client, 'link_registered');
    await waitFor(() => mainOnline.links.route(linkIdHash(IDENTITY_SECRET, linkId)) !== null);
    const browser = await guest(main.url);
    browser.send('link_open', { req: 1, link_id: linkId, payload: b64('offer') });
    assert.equal((await nextOf(browser, 'sig_opened')).owner_online, true);
    assert.equal((await nextOf(mei.client, 'sig_incoming')).link_id, linkId);
    browser.close();
    mei.close();
});

test('every host answers a lookup the same way: the same record, or the same filler', async (t) => {
    const { main, replica, clock, mainOnline } = await federation(t);
    const bob = await FakeHelper.connect(replica.url, { friendsId: 'bold-otter' });
    const { fields } = await bob.publish({ nowS: nowS(clock) });
    await waitFor(() => mainOnline.records.size === 1);
    nextPeriod(clock);
    const nobody = encodeBase64url(Buffer.alloc(32, 9));
    const answers = [];
    for (const url of [main.url, replica.url]) {
        const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
        alice.send('rdv_lookup', { req: 1, keys: [bob.key, nobody] });
        answers.push((await nextOf(alice.client, 'rdv_records')).records);
        await alice.close();
    }
    assert.deepEqual(answers[0], answers[1]);
    assert.equal(answers[0][0], fields.sealed);
    bob.close();
});

test('a host cannot place a record for a helper connected elsewhere', async (t) => {
    const { replica, clock, mainOnline, replicaOnline } = await federation(t);
    const bob = await FakeHelper.connect(replica.url, { friendsId: 'bold-otter' });
    const { fields } = await bob.publish({ nowS: nowS(clock) });
    await waitFor(() => mainOnline.records.size === 1);
    const [record] = replicaOnline.records.all();
    const forged = { identity_key: encodeBase64url(record.identityKey), host_id: 'main-hk', ...fields,
        seq: fields.seq + 1 };
    assert.equal(mainOnline.records.acceptRemote('alt-sg', forged), false, 'names another host');
    assert.equal(mainOnline.records.acceptRemote('alt-sg', { ...forged, host_id: 'alt-sg' }), false,
        'signature covers the sequence number');
    // Over the link itself: a replica speaking for another host is refused by the main host.
    mainOnline.federation.fromLink('alt-sg', { type: 'rdv_record', v: 1, origin: 'alt-tk',
        ...forged, host_id: 'alt-tk' });
    assert.equal(mainOnline.records.size, 1);
    bob.close();
});

test('records of a replica whose link goes down are dropped at once', async (t) => {
    const { main, replica, clock, mainOnline } = await federation(t);
    const bob = await FakeHelper.connect(replica.url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(clock) });
    const alice = await FakeHelper.connect(main.url, { friendsId: 'calm-heron' });
    await waitFor(() => mainOnline.records.size === 1);
    const opened = await alice.open({ rdv_key: bob.key });
    await nextOf(bob.client, 'sig_incoming');
    bob.message(opened.sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    replica.host.replicaLink.stop();
    await waitFor(() => !main.host.hostLinks.has('alt-sg'));
    assert.equal(mainOnline.records.size, 0);
    assert.equal((await nextOf(alice.client, 'sig_closed')).reason, 'gone', 'the answered sid ends');
    alice.close();
    bob.close();
});

test('replicas reach each other through the main host, and lose each other\'s records when one goes', async (t) => {
    const { clock, main, sg, tk } = await startTrio(t);
    const bob = await FakeHelper.connect(tk.url, { friendsId: 'bold-otter' });
    const { fields } = await bob.publish({ nowS: nowS(clock) });
    await waitFor(() => sg.host.online.records.size === 1 && main.host.online.records.size === 1);
    const alice = await FakeHelper.connect(sg.url, { friendsId: 'calm-heron' });
    nextPeriod(clock);
    alice.send('rdv_lookup', { req: 1, keys: [bob.key] });
    assert.equal((await nextOf(alice.client, 'rdv_records')).records[0], fields.sealed);
    const opened = await alice.open({ rdv_key: bob.key }, Buffer.from('ik-1'));
    assert.equal(text((await nextOf(bob.client, 'sig_incoming')).payload), 'ik-1');
    bob.message(opened.sid, 'ik-2');
    assert.equal(text((await nextOf(alice.client, 'sig_msg')).payload), 'ik-2');
    assert.equal(main.host.online.sids.size, 0, 'the main host only passes messages on');
    await tk.host.stop();
    assert.equal((await nextOf(alice.client, 'sig_closed')).reason, 'gone');
    await waitFor(() => sg.host.online.records.size === 0);
    alice.close();
});

test('a replica that comes up late learns every record the others hold', async (t) => {
    const { clock, sg, tk } = await startTrio(t);
    const bob = await FakeHelper.connect(tk.url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(clock) });
    await waitFor(() => sg.host.online.records.size === 1);
    sg.host.replicaLink.restart();
    await waitFor(() => sg.host.replicaLink.state !== 'up' || sg.host.online.records.size === 0);
    await waitFor(() => sg.host.replicaLink.state === 'up' && sg.host.online.records.size === 1);
    bob.close();
});

test('an open passed to a host where the target has just left is forgotten there, and the caller hears nothing',
    async (t) => {
        const { main, mainOnline, replicaOnline } = await federation(t);
        const alice = await FakeHelper.connect(main.url, { friendsId: 'calm-heron' });
        const opened = await alice.open({ rdv_key: encodeBase64url(Buffer.alloc(32, 7)) });
        const entry = mainOnline.sids.get(opened.sid);
        // As if the record still named a helper on the replica that has just disconnected.
        mainOnline.signal.deliver(entry, { hostId: 'alt-sg', identityHash: '00'.repeat(32) });
        assert.equal(entry.waiting.length, 1);
        await waitFor(() => entry.waiting.length === 0);
        assert.equal(replicaOnline.sids.size, 0);
        assert.ok(mainOnline.sids.get(opened.sid), 'the caller keeps its sid until it expires');
        assert.equal(alice.queue.filter((m) => m.type === 'sig_closed').length, 0);
        alice.close();
    });
