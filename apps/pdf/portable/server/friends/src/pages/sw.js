// Shenzhen Friends download page: the service worker that streams a download to the browser's downloads (save.js,
// streamSink). Scope /d/save/. The page posts { type: 'szf-save', id, name, size } with a MessagePort, then opens
// /d/save/<id> in a hidden frame; this worker answers that request with a stream fed from the port, one chunk per
// "pull", so the file never sits in memory. An id is answered once, and only within a minute of being posted.

'use strict';

const SAVE_ID = /^\/d\/save\/([0-9a-f]{32})$/;
const SAVE_WAIT_MS = 60_000;
const pending = new Map();

function disposition(name) {
    const ascii = name.replace(/[^\x20-\x7e]|["\\]/g, '_');
    return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`;
}

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('message', (event) => {
    const data = event.data;
    const port = event.ports && event.ports[0];
    if (!port || !data || data.type !== 'szf-save' || typeof data.id !== 'string' || !/^[0-9a-f]{32}$/.test(data.id)
        || typeof data.name !== 'string' || !Number.isSafeInteger(data.size) || data.size < 0) return;
    let controller = null;
    const stream = new ReadableStream({
        start(c) {
            controller = c;
        },
        pull() {
            port.postMessage({ type: 'pull' });
        },
        cancel() {
            port.postMessage({ type: 'cancel' });
        },
    }, new CountQueuingStrategy({ highWaterMark: 4 }));
    port.onmessage = (message) => {
        const body = message.data || {};
        try {
            if (body.type === 'chunk' && body.bytes instanceof Uint8Array) controller.enqueue(body.bytes);
            else if (body.type === 'close') controller.close();
            else if (body.type === 'abort') controller.error(new Error('The file did not arrive intact.'));
        } catch {
            // The download was cancelled; the page hears "cancel" from the stream.
        }
    };
    pending.set(data.id, { stream, name: data.name, size: data.size });
    setTimeout(() => pending.delete(data.id), SAVE_WAIT_MS);
    port.postMessage({ type: 'ready' });
});

self.addEventListener('fetch', (event) => {
    const url = new URL(event.request.url);
    const match = url.origin === self.location.origin ? SAVE_ID.exec(url.pathname) : null;
    const entry = match && pending.get(match[1]);
    if (!entry) return;
    pending.delete(match[1]);
    event.respondWith(new Response(entry.stream, {
        headers: {
            'Content-Type': 'application/octet-stream',
            'Content-Disposition': disposition(entry.name),
            'Content-Length': String(entry.size),
            'X-Content-Type-Options': 'nosniff',
            'Content-Security-Policy': "default-src 'none'",
        },
    }));
});
