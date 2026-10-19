// Test support for host links: a relay that sits between a replica and the main host, as a TLS-intercepting attacker
// would, and a main host and replica whose list sends the replica's link through it. Loopback only.

import assert from 'node:assert/strict';
import { once } from 'node:events';

import WebSocket, { WebSocketServer } from 'ws';

import { FakeClock, keyPair, listPayload, signList, startHost, waitFor } from './helpers.js';

// The relay passes everything on and records the text it received from each side before any rewrite. A test can
// inject a message either way (toReplica, toMain), rewrite messages in flight (rewriteFromReplica, rewriteFromMain:
// text in, text out) and cut the replica's current connection (cut), after which the replica dials again.
export async function startProxy(t, mainPort) {
    const wss = new WebSocketServer({ host: '127.0.0.1', port: 0 });
    await once(wss, 'listening');
    const proxy = { port: wss.address().port, fromMain: [], fromReplica: [], toReplica: null, toMain: null,
        rewriteFromReplica: (text) => text, rewriteFromMain: (text) => text, cut: () => {} };
    wss.on('connection', (down, req) => {
        const up = new WebSocket(`ws://127.0.0.1:${mainPort}${req.url}`, { perMessageDeflate: false });
        const early = [];
        up.on('open', () => early.splice(0).forEach((text) => up.send(text)));
        up.on('message', (data) => {
            proxy.fromMain.push(data.toString());
            down.send(proxy.rewriteFromMain(data.toString()));
        });
        up.on('ping', (data) => down.ping(data));
        down.on('message', (data) => {
            proxy.fromReplica.push(data.toString());
            const text = proxy.rewriteFromReplica(data.toString());
            if (up.readyState === WebSocket.OPEN) up.send(text);
            else early.push(text);
        });
        up.on('close', () => down.terminate());
        down.on('close', () => up.terminate());
        up.on('error', () => {});
        down.on('error', () => {});
        proxy.toReplica = (text) => down.send(text);
        proxy.toMain = (text) => up.send(text);
        proxy.cut = () => down.terminate();
    });
    t.after(() => new Promise((resolve) => {
        for (const client of wss.clients) client.terminate();
        wss.close(() => resolve());
    }));
    return proxy;
}

// A main host (main-hk) and a replica (alt-sg) whose list sends the replica's link through the proxy, with the link
// up. `extraEntries` adds hosts to both lists, such as a third replica a test plays itself.
export async function startProxiedPair(t, { extraEntries = [] } = {}) {
    const admin = keyPair();
    const mainKey = keyPair();
    const replicaKey = keyPair();
    const clock = new FakeClock();
    const entries = (port) => [{ id: 'main-hk', key: mainKey, priority: 1, port, role: 'both' },
        { id: 'alt-sg', key: replicaKey, priority: 2, port: 9 }, ...extraEntries];
    const main = await startHost(t, { hostId: 'main-hk', hostKey: mainKey, pinned: [admin], clock,
        listText: signList(listPayload({ version: 1, entries: entries(9) }), [admin]) });
    const proxy = await startProxy(t, main.port);
    const v2 = signList(listPayload({ version: 2, entries: entries(proxy.port) }), [admin]);
    assert.equal(main.host.offerList(v2, { source: 'admin' }).ok, true);
    const replica = await startHost(t, { hostId: 'alt-sg', hostKey: replicaKey, pinned: [admin], clock, listText: v2 });
    const linkUp = () => waitFor(() => replica.host.replicaLink?.state === 'up' && main.host.hostLinks.has('alt-sg')
        && main.host.hostLinks.get('alt-sg').sender.running === false, { timeoutMs: 8000 });
    await linkUp();
    return { main, replica, proxy, clock, linkUp, replicaKey };
}
