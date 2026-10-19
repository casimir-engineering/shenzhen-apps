// Relay credentials: only for a connection both sides have taken part in, short-lived, in the TURN REST scheme
// coturn checks, with nothing in the username that names anyone.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { encodeBase64url } from '../src/keys.js';
import { ONLINE_LIMITS } from '../src/online-protocol.js';
import { FakeHelper, TURN_SECRET, nextOf, nowS, startOnline } from './online-helpers.js';

async function answered(t, options) {
    const started = await startOnline(t, options);
    const alice = await FakeHelper.connect(started.url, { friendsId: 'calm-heron' });
    const bob = await FakeHelper.connect(started.url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(started.clock) });
    const opened = await alice.open({ rdv_key: encodeBase64url(bob.rdvKey) });
    await nextOf(bob.client, 'sig_incoming');
    return { ...started, alice, bob, sid: opened.sid };
}

test('no credentials before the target answers; then both ends get valid, short-lived ones', async (t) => {
    const { alice, bob, sid, clock, online } = await answered(t);
    assert.equal((await alice.credentials(sid)).reason, 'not_answered');
    bob.message(sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    for (const end of [alice, bob]) {
        const result = await end.credentials(sid);
        assert.equal(result.type, 'relay_credentials_result');
        assert.equal(result.expires, nowS(clock) + ONLINE_LIMITS.relayCredentialTtlS);
        const [expiry, attempt] = result.username.split(':');
        assert.equal(Number(expiry), result.expires);
        assert.match(attempt, /^[A-Za-z0-9_-]{22}$/, 'a random attempt id, nothing else');
        const expected = crypto.createHmac('sha1', TURN_SECRET).update(result.username).digest('base64');
        assert.equal(result.credential, expected);
        assert.equal(result.ice_servers, undefined, 'helpers take TURN URIs from the signed host list');
    }
    assert.equal((await alice.credentials(sid)).type, 'relay_credentials_result');
    assert.equal((await alice.credentials(sid)).reason, 'rate_limited', 'two per end per sid');
    assert.equal(online.stats.day().credentials, 3);
    alice.close();
    bob.close();
});

test('a host with the relay off refuses, and a sid that is not yours is a protocol error', async (t) => {
    const { alice, bob, sid, url } = await answered(t, { online: { relay: false } });
    bob.message(sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    assert.equal((await alice.credentials(sid)).reason, 'no_relay');
    const mallory = await FakeHelper.connect(url, { friendsId: 'sly-ferret' });
    mallory.send('relay_credentials', { req: 1, sid });
    assert.equal((await nextOf(mallory.client, 'error')).code, 'bad_request');
    alice.close();
    bob.close();
});
