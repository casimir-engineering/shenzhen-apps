// The relay's side of the running host: coturn's configuration written at every start, the STUN port, the relay
// counters kept per host per day (and sent by replicas), the dashboard's relay section and its test credential.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import dgram from 'node:dgram';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { test } from 'node:test';

import { MAGIC_COOKIE, parseMappedAddress } from '../src/stun.js';
import { PASSWORD, startPair } from './helpers.js';
import { FakeHelper, TURN_SECRET, nextOf, nowS, onlineEnv, startOnline, waitFor } from './online-helpers.js';

function request(socketPath, { method = 'GET', urlPath = '/' } = {}) {
    return new Promise((resolve, reject) => {
        const headers = { Authorization: `Basic ${Buffer.from(`admin:${PASSWORD}`).toString('base64')}` };
        const req = http.request({ socketPath, method, path: urlPath, headers }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
        });
        req.on('error', reject);
        req.end();
    });
}

const dashboard = { FRIENDS_DASHBOARD_PASSWORD: PASSWORD };

// A sid both ends have spoken on, so relay credentials can be issued for it.
async function answeredSid(url, clock) {
    const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    const bob = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: nowS(clock) });
    const opened = await alice.open({ rdv_key: bob.key });
    await nextOf(bob.client, 'sig_incoming');
    bob.message(opened.sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    return { alice, bob, sid: opened.sid };
}

test('coturn\'s configuration is written at every start, 0600, with the cap and without server-wide limits',
    async (t) => {
        const first = await startOnline(t);
        const file = first.host.config.online.turn.confFile;
        assert.ok(file.startsWith(first.host.config.dataDir));
        assert.equal(fs.statSync(file).mode & 0o777, 0o600);
        const lines = fs.readFileSync(file, 'utf8').trim().split('\n');
        for (const line of ['max-bps=625000', 'user-quota=2', 'use-auth-secret', `static-auth-secret=${TURN_SECRET}`,
            'no-stdout-log', 'log-file=/dev/null', 'listening-ip=127.0.0.1', 'allowed-peer-ip=127.0.0.1',
            'denied-peer-ip=0.0.0.0-255.255.255.255', 'max-allocate-lifetime=600', 'no-cli']) {
            assert.ok(lines.includes(line), line);
        }
        assert.ok(!lines.some((line) => /^(bps-capacity|total-quota)=/.test(line)), 'no server-wide cap');
        assert.ok(!lines.some((line) => /^denied-peer-ip=::-/.test(line)), 'no range from ::');
        assert.ok(lines.some((line) => line.startsWith('redis-statsdb="ip=127.0.0.1 ')), 'statistics to this host');
        await first.host.stop();
        fs.writeFileSync(file, 'edited by hand\n');
        const again = await startOnline(t, { dataDir: path.dirname(first.host.config.dataDir),
            hostKey: first.hostKey, admin: first.admin });
        assert.ok(fs.readFileSync(again.host.config.online.turn.confFile, 'utf8').includes('max-bps=625000'));
    });

test('the STUN port answers Binding requests with the address it saw', async (t) => {
    const { online } = await startOnline(t);
    const [port] = online.relay.stunPorts;
    const client = dgram.createSocket('udp4');
    t.after(() => client.close());
    await new Promise((resolve) => client.bind(0, '127.0.0.1', resolve));
    const request = Buffer.alloc(20);
    request.writeUInt16BE(0x0001, 0);
    request.writeUInt32BE(MAGIC_COOKIE, 4);
    crypto.randomBytes(12).copy(request, 8);
    const reply = await new Promise((resolve) => {
        client.once('message', resolve);
        client.send(request, port, '127.0.0.1');
    });
    assert.deepEqual(parseMappedAddress(reply), { family: 4, address: '127.0.0.1', port: client.address().port });
});

test('relay counters are kept per host per day, survive a restart, and show on the dashboard', async (t) => {
    const first = await startOnline(t, { env: dashboard });
    const { alice, bob, sid } = await answeredSid(first.url, first.clock);
    const issued = await alice.credentials(sid);
    first.online.stats.onStatus({ username: issued.username, allocation: '1', status: 'new' });
    first.online.stats.onTraffic({ allocation: '1', kind: 'traffic', rcvb: 37_500_000, sentb: 7_500_000 });
    first.host.tick();
    const row = first.host.db.prepare('SELECT * FROM relay_daily WHERE host_id = ?').get('main-hk');
    assert.equal(row.day, first.host.today());
    assert.deepEqual([row.opens_helper, row.answered_helper, row.credentials, row.relayed_helper, row.sessions,
        row.bytes_up, row.bytes_down, row.capped_sessions], [1, 1, 1, 1, 1, 37_500_000, 7_500_000, 1]);
    const stats = JSON.parse((await request(first.host.config.dashboardSocket, { urlPath: '/stats.json' })).body);
    assert.equal(stats.relay.state, 'on');
    assert.equal(stats.relay.today.share.friends, 1);
    assert.equal(stats.relay.today.bytes, 45_000_000);
    assert.equal(stats.relay.now.sessions, 1);
    const page = (await request(first.host.config.dashboardSocket)).body;
    for (const words of ['Relayed now', 'Held at 5 Mbit/s', 'Friend connections that needed it', '45 MB relayed',
        'coturn is not sending its statistics']) {
        assert.ok(page.includes(words), words);
    }
    alice.close();
    bob.close();
    await first.host.stop();
    const again = await startOnline(t, { env: dashboard, dataDir: path.dirname(first.host.config.dataDir),
        hostKey: first.hostKey, admin: first.admin, clock: first.clock });
    assert.equal(again.online.stats.day().bytes_up, 37_500_000, 'today carries on from the stored row');
});

test('a replica sends its relay counters with its minute report', async (t) => {
    const pair = await startPair(t, { mainEnv: onlineEnv(), replicaEnv: onlineEnv() });
    await pair.linkUp();
    const { alice, bob, sid } = await answeredSid(pair.replica.url, pair.clock);
    assert.equal((await bob.credentials(sid)).type, 'relay_credentials_result');
    pair.replica.host.tick();
    await waitFor(() => pair.main.host.db.prepare('SELECT credentials FROM relay_daily WHERE host_id = ?')
        .get('alt-sg')?.credentials === 1);
    alice.close();
    bob.close();
});

test('the dashboard issues a test credential only while the relay is on', async (t) => {
    const on = await startOnline(t, { env: dashboard });
    const res = await request(on.host.config.dashboardSocket, { method: 'POST', urlPath: '/relay-test' });
    assert.equal(res.status, 200);
    const issued = JSON.parse(res.body);
    assert.match(issued.username, /^\d+:[A-Za-z0-9_-]{22}$/);
    assert.equal(issued.credential, crypto.createHmac('sha1', TURN_SECRET).update(issued.username).digest('base64'));
    assert.deepEqual(issued.uris, ['turn:127.0.0.1:3478?transport=udp']);
    const off = await startOnline(t, { env: dashboard, online: { relay: false } });
    const refused = await request(off.host.config.dashboardSocket, { method: 'POST', urlPath: '/relay-test' });
    assert.equal(refused.status, 409);
    const page = (await request(off.host.config.dashboardSocket)).body;
    assert.ok(page.includes('the relay is off (FRIENDS_RELAY)'));
});
