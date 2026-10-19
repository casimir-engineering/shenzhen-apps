// What a relay credential can reach and for how long, against a coturn built from pinned source on loopback
// (coturn-run.js; skipped without FRIENDS_TEST_COTURN): one relay allocation reaches another, and nothing else
// (127.0.0.2 stands in for a public address); each refresh holds an allocation for at most 600 s; a stale nonce
// makes the client sign again but does not end the session, because coturn keeps the key; and the host has coturn
// end both allocations once FRIENDS_TURN_MAX_SESSION_S have passed since the credential was issued, through
// coturn's CLI, however the apps refresh.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { coturnCliPassword } from '../src/relay-limit.js';
import { COTURN_SKIP, freeTcpPort, startCoturn } from './coturn-run.js';
import { FakeHelper, TURN_SECRET, nextOf, nowS, startOnline, waitFor } from './online-helpers.js';
import { TurnClient } from './turn-client.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const MAX_SESSION_S = 6;

async function turnClient(t, port, issued) {
    const client = new TurnClient({ server: '127.0.0.1', port, username: issued.username,
        password: issued.credential });
    await client.open();
    t.after(() => client.close());
    return client;
}

async function relayCredential(t, url, clock) {
    const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    const bob = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    t.after(() => {
        alice.close();
        bob.close();
    });
    await bob.publish({ nowS: nowS(clock) });
    const opened = await alice.open({ rdv_key: bob.key });
    await nextOf(bob.client, 'sig_incoming');
    bob.message(opened.sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    const issued = await alice.credentials(opened.sid);
    assert.equal(issued.type, 'relay_credentials_result');
    return { ...issued, at: Date.now() };
}

test('a credential reaches only relays, for 600 s a refresh, and never past the session limit',
    { skip: COTURN_SKIP }, async (t) => {
        const cliPort = await freeTcpPort();
        const { url, clock, online } = await startOnline(t, { clock: { now: () => Date.now() },
            env: { FRIENDS_TURN_EVENTS_LISTEN: '::1', FRIENDS_TURN_MAX_SESSION_S: String(MAX_SESSION_S),
                FRIENDS_TURN_CLI_PORT: String(cliPort) } });
        // The host's generator with its CLI settings; stale-nonce at 1 s instead of 600, so a nonce goes stale here.
        const { port, output } = await startCoturn(t, { sinkPort: online.relay.eventsPort, staleNonceS: 1,
            cli: { ip: '127.0.0.1', port: cliPort, password: coturnCliPassword(TURN_SECRET) } });
        await waitFor(() => online.relay.receiving, { timeoutMs: 5000 });
        const issued = await relayCredential(t, url, clock);
        const a = await turnClient(t, port, issued);
        const b = await turnClient(t, port, issued);

        const allocatedAt = Date.now();
        const first = await a.allocate(3600);
        assert.equal(first.cls, 2);
        assert.equal(first.lifetime, 600, 'an allocation asked for an hour gets 600 s');
        assert.equal((await b.allocate(60)).cls, 2);
        assert.equal((await a.refresh(3600)).lifetime, 600, 'and so does each refresh');

        // Relay to relay, as every Friends relay path is.
        assert.equal((await b.permission(a.relayed.address, a.relayed.port)).cls, 2);
        assert.equal((await a.bindChannel(0x4001, b.relayed.address, b.relayed.port)).cls, 2);
        const arrived = new Promise((resolve) => {
            b.onData = (peer, data) => resolve({ peer, data: data.toString() });
        });
        a.sendChannel(0x4001, Buffer.from('relay to relay'));
        assert.deepEqual(await Promise.race([arrived, sleep(2000).then(() => null)]),
            { peer: a.relayed, data: 'relay to relay' });
        // Any address but the relays' is refused, here a loopback address no deny range of the server names.
        for (const address of ['127.0.0.2', '127.255.255.254']) {
            assert.equal((await a.permission(address, 9)).error, 403, address);
        }

        // The nonce goes stale: coturn asks again, the client signs with the new nonce and the same key, and the
        // session carries on. Nothing about the credential's 300 s is checked again. (coturn's clock counts whole
        // seconds, so a 1 s nonce is surely stale 3 s after it was given.)
        await sleep(Math.max(0, allocatedAt + 3000 - Date.now()));
        assert.equal((await a.refreshOnce(600)).error, 438, 'stale nonce');
        assert.equal((await a.refresh(600)).cls, 2, 'signed again, still allocated');
        assert.ok(Date.now() - issued.at < (MAX_SESSION_S - 1) * 1000, 'all of this ran inside the bound');

        // At the bound the host has coturn end both allocations, and they cannot be refreshed back.
        await waitFor(() => online.stats.allocations.size === 0 && online.relay.limit.counts.ended >= 2,
            { timeoutMs: 9000, intervalMs: 50 });
        assert.ok(Date.now() - issued.at >= (MAX_SESSION_S - 1) * 1000, 'not before the bound');
        assert.equal(online.relay.limit.live.size, 0);
        const after = await a.refresh(600);
        assert.notEqual(after.cls, 2);
        assert.equal(after.error, 437, 'the allocation is gone');
        assert.equal(Buffer.concat(output).length, 0, 'coturn printed nothing');
    });
