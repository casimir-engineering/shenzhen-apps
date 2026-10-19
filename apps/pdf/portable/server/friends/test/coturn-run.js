// A coturn built from pinned source (FRIENDS_TEST_COTURN names its turnserver), run on loopback from the host's own
// configuration generator with the test allowances only: loopback peers, and the statistics sink on ::1, because
// coturn refuses to relay to its statistics address and the test's peers are on 127.0.0.1. Without
// FRIENDS_TEST_COTURN the suites that use it skip and say so; nothing is downloaded or installed.

import { spawn } from 'node:child_process';
import dgram from 'node:dgram';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

import { coturnConfig } from '../src/coturn-config.js';
import { EVENTS_PASSWORD, TURN_SECRET, waitFor } from './online-helpers.js';
import { stunBinding } from './turn-client.js';

export const COTURN = process.env.FRIENDS_TEST_COTURN;
export const COTURN_SKIP = COTURN && fs.existsSync(COTURN) ? false
    : 'set FRIENDS_TEST_COTURN to a turnserver built from pinned source to run the relay against coturn';

export async function freeUdpPort() {
    const socket = dgram.createSocket('udp4');
    await new Promise((resolve) => socket.bind(0, '127.0.0.1', resolve));
    const { port } = socket.address();
    await new Promise((resolve) => socket.close(resolve));
    return port;
}

export async function freeTcpPort() {
    const server = net.createServer();
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address();
    await new Promise((resolve) => server.close(resolve));
    return port;
}

// `options` go to the generator as they are (cli, staleNonceS, ...). Resolves once coturn answers STUN.
export async function startCoturn(t, { sinkPort, ...options }) {
    const work = fs.mkdtempSync(path.join(os.tmpdir(), 'szf-coturn-'));
    t.after(() => fs.rmSync(work, { recursive: true, force: true }));
    const port = await freeUdpPort();
    const minPort = 50_000 + Math.floor(Math.random() * 10_000);
    const conf = coturnConfig({ realm: 'friends.test', secret: TURN_SECRET, listeningIps: ['127.0.0.1'],
        listeningPort: port, minPort, maxPort: minPort + 63,
        statsdb: { ip: '::1', port: sinkPort, password: EVENTS_PASSWORD },
        test: { allowLoopbackPeers: true, pidfile: path.join(work, 'turnserver.pid') }, ...options });
    const confPath = path.join(work, 'turnserver.conf');
    fs.writeFileSync(confPath, conf, { mode: 0o600 });
    const output = [];
    const child = spawn(COTURN, ['-c', confPath], { cwd: work, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', (d) => output.push(d));
    child.stderr.on('data', (d) => output.push(d));
    t.after(async () => {
        if (child.exitCode === null) {
            child.kill('SIGTERM');
            await new Promise((resolve) => child.once('exit', resolve));
        }
    });
    await waitFor(async () => Boolean(await stunBinding('127.0.0.1', port).catch(() => null)), { timeoutMs: 8000,
        intervalMs: 200 });
    return { port, output };
}
