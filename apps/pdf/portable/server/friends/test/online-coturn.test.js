// The relay end to end on loopback: a coturn built from pinned source (FRIENDS_TEST_COTURN names its turnserver),
// configured by the host's own generator, accepting the credentials the host issues for an answered sid, refusing
// wrong ones, a third allocation per credential and private peers, holding a session to 5 Mbit/s, and sending its
// statistics to the host. Without FRIENDS_TEST_COTURN the test skips and says so; it never downloads or installs.

import assert from 'node:assert/strict';
import dgram from 'node:dgram';
import { test } from 'node:test';

import { COTURN_SKIP, startCoturn } from './coturn-run.js';
import { FakeHelper, nextOf, nowS, startOnline, waitFor } from './online-helpers.js';
import { TurnClient } from './turn-client.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function turnClient(port, username, password) {
    const client = new TurnClient({ server: '127.0.0.1', port, username, password });
    await client.open();
    return client;
}

test('coturn takes the host\'s credentials and limits, and reports to the host', { skip: COTURN_SKIP }, async (t) => {
    const { url, clock, online } = await startOnline(t, { env: { FRIENDS_TURN_EVENTS_LISTEN: '::1' },
        clock: { now: () => Date.now() } });
    const { port, output } = await startCoturn(t, { sinkPort: online.relay.eventsPort });
    await waitFor(() => online.relay.receiving, { timeoutMs: 5000 });

    const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    const bob = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(clock) });
    const opened = await alice.open({ rdv_key: bob.key });
    await nextOf(bob.client, 'sig_incoming');
    bob.message(opened.sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    const issued = await alice.credentials(opened.sid);
    assert.equal(issued.type, 'relay_credentials_result');

    const clients = [];
    for (let i = 0; i < 3; i++) clients.push(await turnClient(port, issued.username, issued.credential));
    t.after(() => Promise.all(clients.map((c) => c.close())));
    assert.equal((await clients[0].allocate(60)).cls, 2, 'allocated with the host\'s credential');
    assert.equal((await clients[1].allocate(60)).cls, 2);
    assert.equal((await clients[2].allocate(60)).error, 486, 'two allocations per credential');
    const wrong = await turnClient(port, issued.username, 'bm90IGl0');
    t.after(() => wrong.close());
    assert.equal((await wrong.allocate(60)).error, 401);
    for (const address of ['10.0.0.1', '192.168.1.1', '100.64.0.1', '172.18.0.5']) {
        assert.equal((await clients[0].permission(address, 80)).error, 403, address);
    }

    // Offered twice the cap for three seconds, the peer receives about 625,000 bytes a second.
    const peer = dgram.createSocket('udp4');
    t.after(() => peer.close());
    await new Promise((resolve) => peer.bind(0, '127.0.0.1', resolve));
    let received = 0;
    peer.on('message', (msg) => {
        received += msg.length;
    });
    assert.equal((await clients[0].bindChannel(0x4000, '127.0.0.1', peer.address().port)).cls, 2);
    const packet = Buffer.alloc(1000, 0x61);
    const start = performance.now();
    let sent = 0;
    let atSecondOne = null;
    while (performance.now() - start < 3000) {
        const due = Math.floor(((performance.now() - start) / 1000) * 1250);
        for (; sent < due; sent++) clients[0].sendChannel(0x4000, packet);
        if (atSecondOne === null && performance.now() - start >= 1000) atSecondOne = received;
        await sleep(5);
    }
    await sleep(200);
    const steady = (received - atSecondOne) / ((performance.now() - start - 1000) / 1000);
    assert.ok(steady < 625_000 * 1.25 && steady > 625_000 * 0.6, `about 625,000 B/s, measured ${Math.round(steady)}`);

    // The host heard of both allocations and joined them to the sid's kind; coturn reports bytes every 4,096
    // packets and when an allocation ends, which is when this short run's arrive.
    await waitFor(() => online.stats.day().sessions === 2, { timeoutMs: 5000 });
    assert.equal(online.stats.allocations.size, 2);
    assert.equal(online.stats.day().relayed_helper, 1, 'two allocations of one connection are one relayed connection');
    for (const client of clients.slice(0, 2)) await client.refresh(0);
    await waitFor(() => online.stats.allocations.size === 0 && online.stats.day().bytes_up > 1_000_000,
        { timeoutMs: 5000 });
    // coturn counts what passed the cap, each packet with its 4-byte channel header: what the peer received.
    const counted = online.stats.day().bytes_up;
    assert.ok(Math.abs(counted - received * 1.004) < received * 0.01, `counted ${counted}, received ${received}`);
    assert.equal(Buffer.concat(output).length, 0, 'coturn printed nothing');
    alice.close();
    bob.close();
});
