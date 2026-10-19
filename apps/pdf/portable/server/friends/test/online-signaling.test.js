// Connection setup between two fake helpers: the host forwards opaque payloads both ways, answers every open the
// same way, and never lets a caller tell an absent target from one that chose not to answer.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { encodeBase64url } from '../src/keys.js';
import { ONLINE_LIMITS, rendezvousKey } from '../src/online-protocol.js';
import { FakeHelper, b64, identity, nextOf, nowS, silent, startOnline, text, waitFor } from './online-helpers.js';

async function pair(t) {
    const started = await startOnline(t);
    const alice = await FakeHelper.connect(started.url, { friendsId: 'calm-heron' });
    const bob = await FakeHelper.connect(started.url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(started.clock) });
    return { ...started, alice, bob };
}

test('an open reaches the target with its payload and no caller identity; answers and candidates flow both ways',
    async (t) => {
        const { alice, bob, online } = await pair(t);
        const opened = await alice.open({ rdv_key: encodeBase64url(bob.rdvKey) }, Buffer.from('ik-1 + offer'));
        assert.equal(opened.type, 'sig_opened');
        assert.equal(opened.owner_online, undefined, 'only links say whether anyone is there');
        const incoming = await nextOf(bob.client, 'sig_incoming');
        assert.equal(incoming.sid, opened.sid);
        assert.equal(incoming.via, 'rdv');
        assert.equal(text(incoming.payload), 'ik-1 + offer');
        assert.deepEqual(Object.keys(incoming).sort(), ['link_id', 'payload', 'sid', 'type', 'v', 'via']);

        alice.message(opened.sid, 'candidate a1');
        bob.message(opened.sid, 'ik-2 + answer');
        assert.equal(text((await nextOf(bob.client, 'sig_msg')).payload), 'candidate a1');
        assert.equal(text((await nextOf(alice.client, 'sig_msg')).payload), 'ik-2 + answer');
        assert.equal(online.stats.day().answered_helper, 1);

        alice.send('sig_close', { sid: opened.sid });
        assert.equal((await nextOf(bob.client, 'sig_closed')).reason, 'closed');
        alice.close();
        bob.close();
    });

test('a missing target, a silent one, one that closes unanswered and one that leaves look the same', async (t) => {
    const { alice, bob, url, clock } = await pair(t);
    const carol = await FakeHelper.connect(url, { friendsId: 'gentle-moth' });
    await carol.publish({ nowS: nowS(clock) });
    const nobody = await alice.open({ rdv_key: encodeBase64url(rendezvousKey(identity().raw)) });
    const silentSid = await alice.open({ rdv_key: encodeBase64url(bob.rdvKey) });
    const closedSid = await alice.open({ rdv_key: encodeBase64url(bob.rdvKey) });
    const leftSid = await alice.open({ rdv_key: encodeBase64url(carol.rdvKey) });
    const opens = [nobody, silentSid, closedSid, leftSid];
    for (const opened of opens) assert.deepEqual(Object.keys(opened).sort(), Object.keys(nobody).sort());
    await nextOf(bob.client, 'sig_incoming');
    await nextOf(bob.client, 'sig_incoming');
    await nextOf(carol.client, 'sig_incoming');
    for (const opened of opens) alice.message(opened.sid, 'candidate');
    // Bob refuses one by staying silent and the other by closing it unanswered; Carol leaves without answering.
    bob.send('sig_close', { sid: closedSid.sid });
    await carol.close();
    assert.ok(await silent(alice.client, 'sig_closed'));
    clock.advance(ONLINE_LIMITS.sidLifetimeMs + 1);
    const expired = [];
    for (let i = 0; i < 4; i++) expired.push(await nextOf(alice.client, 'sig_closed'));
    assert.deepEqual(expired.map((m) => m.reason), ['expired', 'expired', 'expired', 'expired']);
    assert.deepEqual(expired.map((m) => m.sid).sort(), opens.map((m) => m.sid).sort());
    alice.close();
    bob.close();
});

test('a target that answered and then disconnects is reported gone at once', async (t) => {
    const { alice, bob } = await pair(t);
    const opened = await alice.open({ rdv_key: encodeBase64url(bob.rdvKey) });
    await nextOf(bob.client, 'sig_incoming');
    bob.message(opened.sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    await bob.close();
    const closed = await nextOf(alice.client, 'sig_closed');
    assert.equal(closed.reason, 'gone');
    alice.close();
});

test('Add by ID online reaches the holder of a reserved ID that published a record', async (t) => {
    const { alice, bob } = await pair(t);
    assert.equal(bob.welcome.reservation, 'reserved');
    const opened = await alice.open({ friends_id: 'bold-otter' }, Buffer.from('nn-1'));
    const incoming = await nextOf(bob.client, 'sig_incoming');
    assert.equal(incoming.sid, opened.sid);
    assert.equal(incoming.via, 'id');
    // Five per hour per caller: the sixth is refused to the caller, who is the only one it tells anything.
    for (let i = 0; i < 4; i++) assert.equal((await alice.open({ friends_id: 'free-name' })).type, 'sig_opened');
    assert.equal((await alice.open({ friends_id: 'free-name' })).reason, 'rate_limited');
    alice.close();
    bob.close();
});

test('per sid, each direction carries at most 64 messages; unknown sids are reported closed', async (t) => {
    const { alice, bob } = await pair(t);
    const opened = await alice.open({ rdv_key: encodeBase64url(bob.rdvKey) });
    await nextOf(bob.client, 'sig_incoming');
    for (let i = 0; i < ONLINE_LIMITS.messagesPerSidDirection; i++) alice.message(opened.sid, `c${i}`);
    await waitFor(() => bob.queue.filter((m) => m.type === 'sig_msg').length === 64);
    alice.message(opened.sid, 'one too many');
    assert.equal((await nextOf(alice.client, 'sig_closed')).reason, 'limit');
    assert.equal((await nextOf(bob.client, 'sig_closed')).reason, 'limit');
    alice.send('sig_msg', { sid: opened.sid, payload: b64('late') });
    assert.equal((await nextOf(alice.client, 'sig_closed')).reason, 'unknown');
    alice.close();
    bob.close();
});

test('a connection holds at most 16 open sids', async (t) => {
    const { alice, bob } = await pair(t);
    for (let i = 0; i < 16; i++) assert.equal((await alice.open({ rdv_key: encodeBase64url(bob.rdvKey) })).type,
        'sig_opened');
    const refused = await alice.open({ rdv_key: encodeBase64url(bob.rdvKey) });
    assert.equal(refused.type, 'sig_refused');
    alice.close();
    bob.close();
});
