// The admin dashboard (ADR 0005 § Admin dashboard): a Unix socket only, basic auth, server-rendered HTML with
// no scripts, the JSON it renders from, and publishing a signed list.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import { test } from 'node:test';

import { PASSWORD, TestClient, identity, listPayload, signList, startMain, startPair, waitFor } from './helpers.js';

function request(socketPath, { method = 'GET', path = '/', auth = `admin:${PASSWORD}`, body } = {}) {
    return new Promise((resolve, reject) => {
        const headers = auth ? { Authorization: `Basic ${Buffer.from(auth).toString('base64')}` } : {};
        const req = http.request({ socketPath, method, path, headers }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({ status: res.statusCode, headers: res.headers,
                body: Buffer.concat(chunks).toString('utf8') }));
        });
        req.on('error', reject);
        req.setTimeout(5000, () => req.destroy(new Error('timeout')));
        req.end(body);
    });
}

const env = { FRIENDS_DASHBOARD_PASSWORD: PASSWORD };

test('the dashboard listens on a 0600 socket in the data directory, not on TCP', async (t) => {
    const { host, port } = await startMain(t, { env });
    const socket = host.config.dashboardSocket;
    assert.ok(socket.startsWith(host.config.dataDir));
    const stat = fs.statSync(socket);
    assert.ok(stat.isSocket());
    assert.equal(stat.mode & 0o777, 0o600);
    // The TCP port serves the WebSocket only.
    const tcp = await fetch(`http://127.0.0.1:${port}/`, { headers: { Authorization: `Basic ${Buffer.from(
        `admin:${PASSWORD}`).toString('base64')}` } });
    assert.equal(tcp.status, 404);
});

test('without the right user and password the dashboard says nothing', async (t) => {
    const { host } = await startMain(t, { env });
    const socket = host.config.dashboardSocket;
    for (const auth of [null, `admin:wrong-password-x`, `root:${PASSWORD}`, 'garbage']) {
        const res = await request(socket, { auth });
        assert.equal(res.status, 401, String(auth));
        assert.match(res.headers['www-authenticate'], /Basic realm="Friends host"/);
        assert.doesNotMatch(res.body, /Online/);
    }
});

test('the page renders every section, escapes text and allows no scripts', async (t) => {
    const { host, url } = await startMain(t, { env });
    const client = await TestClient.connect(url);
    await client.checkin(identity(), { appVersion: '26.10.12-1' });
    host.tick();
    const res = await request(host.config.dashboardSocket);
    assert.equal(res.status, 200);
    assert.match(res.headers['content-type'], /text\/html/);
    assert.match(res.headers['content-security-policy'], /default-src 'none'/);
    assert.doesNotMatch(res.headers['content-security-policy'], /script-src/);
    for (const heading of ['Online now', 'Unique users today', 'New identities today', 'Online users, last 24 hours',
        'Host list adoption', 'Friends IDs', 'Relay', 'App versions', 'Hosts in list v1']) {
        assert.ok(res.body.includes(heading), heading);
    }
    assert.doesNotMatch(res.body, /<script/i);
    assert.doesNotMatch(res.body, /https?:\/\//, 'no external assets');
    assert.ok(res.body.includes('26.10.12-1'));
    client.close();
});

test('stats.json carries the numbers the page shows', async (t) => {
    const { host, url } = await startMain(t, { env });
    const client = await TestClient.connect(url);
    await client.checkin(identity());
    const res = await request(host.config.dashboardSocket, { path: '/stats.json' });
    const stats = JSON.parse(res.body);
    assert.equal(stats.online.now, 1);
    assert.equal(stats.uniques.today, 1);
    assert.equal(stats.host.role, 'main');
    assert.equal(stats.relay.state, 'off', 'online Friends is off unless FRIENDS_M2 is on');
    client.close();
});

test('publishing a signed list through the dashboard pushes it; bad lists are refused', async (t) => {
    const main = await startMain(t, { env });
    const socket = main.host.config.dashboardSocket;
    const v2 = signList(listPayload({ version: 2, entries: [{ id: 'main-hk', key: main.hostKey, priority: 1,
        role: 'both' }] }), [main.admin]);
    const ok = await request(socket, { method: 'POST', path: '/lists', body: v2 });
    assert.equal(ok.status, 200);
    assert.deepEqual(JSON.parse(ok.body), { published: 2 });
    const again = await request(socket, { method: 'POST', path: '/lists', body: v2 });
    assert.equal(again.status, 400);
    const junk = await request(socket, { method: 'POST', path: '/lists', body: '{"payload":"x","sigs":[]}' });
    assert.equal(junk.status, 400);
    const huge = await request(socket, { method: 'POST', path: '/lists', body: 'x'.repeat(70_000) });
    assert.equal(huge.status, 413);
});

test('a replica shows only what it sees and refuses to publish', async (t) => {
    const pair = await startPair(t, { replicaEnv: env });
    await pair.linkUp();
    const socket = pair.replica.host.config.dashboardSocket;
    await waitFor(() => pair.replica.host.db.prepare("SELECT value FROM settings WHERE key = 'id_table'").get()
        ?.value === 'synced');
    const page = await request(socket);
    assert.match(page.body, /This is a replica/);
    assert.match(page.body, /holds a complete copy of the Friends ID table/);
    assert.doesNotMatch(page.body, /Unique users today/);
    const publish = await request(socket, { method: 'POST', path: '/lists', body: '{}' });
    assert.equal(publish.status, 409);
});

test('without a password the dashboard does not start', async (t) => {
    const { host, logs } = await startMain(t);
    assert.equal(host.dashboard, null);
    assert.equal(fs.existsSync(host.config.dashboardSocket), false);
    assert.ok(logs.some((line) => line.includes('"dashboard"') && line.includes('disabled')));
});

test('a stale socket from a crash is replaced, but a regular file is never deleted', async (t) => {
    const first = await startMain(t, { env });
    const socket = first.host.config.dashboardSocket;
    const { dir } = first;
    await first.host.stop();
    // A process killed while listening leaves its socket file behind, as a crashed host would.
    const script = `require('node:net').createServer()
        .listen(${JSON.stringify(socket)}, () => process.kill(process.pid, 'SIGKILL'))`;
    const crash = spawnSync(process.execPath, ['-e', script], { timeout: 5000 });
    assert.equal(crash.signal, 'SIGKILL');
    assert.ok(fs.lstatSync(socket).isSocket());
    const again = await startMain(t, { env, dataDir: dir });
    assert.equal((await request(socket, { path: '/stats.json' })).status, 200);
    await again.host.stop();
    fs.writeFileSync(socket, 'not a socket');
    await assert.rejects(startMain(t, { env, dataDir: dir }), /not a socket/);
    assert.equal(fs.readFileSync(socket, 'utf8'), 'not a socket');
});
