// How much of the relay one identity or one browser address holds at once: unused credentials and the allocations
// coturn reports alive count toward 4, and a fifth credential is refused until one ends. On a fake clock, through the
// running host, and against a real coturn (FRIENDS_TEST_COTURN; skipped, saying so, without it).

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ONLINE_LIMITS } from '../src/online-protocol.js';
import { RelayAllocationCap } from '../src/relay-allocations.js';
import { COTURN_SKIP, startCoturn } from './coturn-run.js';
import { FakeClock } from './helpers.js';
import { FakeHelper, nextOf, nowS, startOnline, waitFor } from './online-helpers.js';
import { TurnClient } from './turn-client.js';

const CAP = ONLINE_LIMITS.relayHeldPerIdentity;

test('unused credentials and live allocations count; expired, ended and silent ones do not', () => {
    const clock = new FakeClock();
    const held = new RelayAllocationCap({ clock });
    const expiresS = nowS(clock) + 300;
    for (let i = 0; i < CAP; i++) held.issued({ attempt: `a${i}`, owners: ['identity:aa'], expiresS });
    assert.equal(held.held('identity:aa'), CAP);
    assert.ok(!held.allows('identity:aa', CAP) && held.allows('identity:bb', CAP), 'per owner');
    // Two allocations under one credential count twice, and keep counting once the credential has expired.
    held.onStatus({ username: `${expiresS}:a0`, allocation: '11', status: 'new' });
    held.onStatus({ username: `${expiresS}:a0`, allocation: '12', status: 'new' });
    held.onStatus({ username: `${expiresS}:a1`, allocation: '13', status: 'refreshed' });
    held.onStatus({ username: `${expiresS}:nobody`, allocation: '14', status: 'new' });
    assert.equal(held.held('identity:aa'), CAP + 1);
    clock.advance(301_000);
    held.prune();
    assert.equal(held.held('identity:aa'), 3, 'the unused credentials expired; three allocations live');
    held.onStatus({ username: '', allocation: '12', status: 'deleted' });
    assert.equal(held.held('identity:aa'), 2);
    assert.ok(held.allows('identity:aa', CAP));
    // An allocation coturn has said nothing of for longer than one lives unrefreshed, and a minute, has ended.
    clock.advance(600_000);
    held.onStatus({ username: `${expiresS}:a1`, allocation: '13', status: 'refreshed' });
    clock.advance(61_000);
    held.prune();
    assert.equal(held.held('identity:aa'), 1, 'only the refreshed one is left');
    assert.equal(held.credentials.size, 1, 'and only its credential is remembered');
});

async function answeredSid(alice, bob) {
    const opened = await alice.open({ rdv_key: bob.key });
    await nextOf(bob.client, 'sig_incoming');
    bob.message(opened.sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    return opened.sid;
}

test('a fifth credential is refused while four are held, and given once one has expired', async (t) => {
    const { url, clock } = await startOnline(t);
    const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    const bob = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(clock) });
    const sids = [await answeredSid(alice, bob), await answeredSid(alice, bob), await answeredSid(alice, bob)];
    const results = [];
    for (const sid of sids) {
        for (let i = 0; i < ONLINE_LIMITS.relayCredentialsPerSidEnd; i++) results.push(await alice.credentials(sid));
    }
    assert.deepEqual(results.map((r) => r.type), ['relay_credentials_result', 'relay_credentials_result',
        'relay_credentials_result', 'relay_credentials_result', 'relay_refused', 'relay_refused']);
    assert.equal(results[4].reason, 'rate_limited');
    assert.equal((await bob.credentials(sids[2])).type, 'relay_credentials_result', 'bob holds his own share');
    clock.advance(ONLINE_LIMITS.relayCredentialTtlS * 1000 + 1000);
    await bob.publish({ nowS: nowS(clock) });
    assert.equal((await alice.credentials(await answeredSid(alice, bob))).type, 'relay_credentials_result',
        'unused credentials past their 300 s hold nothing');
    alice.close();
    bob.close();
});

test('coturn: a credential is refused while four allocations live, and given once one ends', { skip: COTURN_SKIP },
    async (t) => {
        // coturn checks the usernames' expiry against the real time, so the host's clock starts there.
        const clock = new FakeClock();
        clock.ms = Date.now();
        const { url, online } = await startOnline(t, { env: { FRIENDS_TURN_EVENTS_LISTEN: '::1' }, clock });
        const { port } = await startCoturn(t, { sinkPort: online.relay.eventsPort });
        await waitFor(() => online.relay.receiving, { timeoutMs: 5000 });
        const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
        const bob = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
        await bob.publish({ nowS: nowS(clock) });
        const clients = [];
        t.after(() => Promise.all(clients.map((c) => c.close())));
        for (let i = 0; i < CAP / 2; i++) {
            const sid = await answeredSid(alice, bob);
            for (let j = 0; j < 2; j++) {
                const issued = await alice.credentials(sid);
                assert.equal(issued.type, 'relay_credentials_result');
                const client = new TurnClient({ server: '127.0.0.1', port, username: issued.username,
                    password: issued.credential });
                await client.open();
                clients.push(client);
                assert.equal((await client.allocate(600)).cls, 2);
            }
        }
        await waitFor(() => online.relayHeld.allocations.size === CAP, { timeoutMs: 5000 });
        // Past the credentials' 300 s on the host's clock: only the live allocations hold the share now.
        clock.advance(ONLINE_LIMITS.relayCredentialTtlS * 1000 + 1000);
        await bob.publish({ nowS: nowS(clock) });
        let sid = await answeredSid(alice, bob);
        assert.equal((await alice.credentials(sid)).reason, 'rate_limited', 'four allocations live');
        await clients[0].refresh(0);
        await waitFor(() => online.relayHeld.allocations.size === CAP - 1, { timeoutMs: 5000 });
        sid = await answeredSid(alice, bob);
        assert.equal((await alice.credentials(sid)).type, 'relay_credentials_result', 'one ended');
        alice.close();
        bob.close();
    });
