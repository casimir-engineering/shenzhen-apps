// The download page's service worker (src/pages/sw.js), run in a fresh context with a stand-in for its global scope:
// it answers /d/save/<id> once with a stream fed chunk by chunk from the page, as an attachment of the file's size,
// fails the download when the page aborts it, and answers nothing else.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

import { loadLinkScript } from './link-support.js';

const SOURCE = fs.readFileSync(new URL('../src/pages/sw.js', import.meta.url), 'utf8');
const ORIGIN = 'https://friends.example';
const ID = '00112233445566778899aabbccddeeff';

function startWorker() {
    const listeners = new Map();
    const self = {
        location: { origin: ORIGIN },
        clients: { claim: async () => {} },
        skipWaiting() {},
        addEventListener: (type, fn) => listeners.set(type, fn),
    };
    // The worker forgets an unanswered save after a minute; that timer must not keep the test process alive.
    const timer = (fn, ms) => setTimeout(fn, ms).unref();
    vm.runInNewContext(SOURCE, { self, ReadableStream, CountQueuingStrategy, Response, URL, Uint8Array, Error,
        setTimeout: timer, encodeURIComponent });
    const fetchEvent = (url) => {
        let response = null;
        listeners.get('fetch')({ request: { url }, respondWith: (r) => { response = r; } });
        return response;
    };
    return { listeners, fetchEvent };
}

function post(worker, data) {
    const channel = new MessageChannel();
    const replies = [];
    channel.port1.onmessage = (event) => replies.push(event.data.type);
    worker.listeners.get('message')({ data, ports: [channel.port2] });
    return { port: channel.port1, replies, close: () => channel.port1.close() };
}

const until = async (check) => {
    for (let i = 0; i < 200 && !check(); i += 1) await new Promise((resolve) => setTimeout(resolve, 5));
    assert.ok(check());
};

test('a save is answered once, as an attachment, with each chunk the page sends', async (t) => {
    const worker = startWorker();
    const page = post(worker, { type: 'szf-save', id: ID, name: 'Site “photos”.pdf', size: 6 });
    t.after(page.close);
    await until(() => page.replies.includes('ready'));
    const response = worker.fetchEvent(`${ORIGIN}/d/save/${ID}`);
    assert.ok(response);
    assert.equal(response.headers.get('content-length'), '6');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.match(response.headers.get('content-disposition'),
        /^attachment; filename="Site _photos_.pdf"; filename\*=UTF-8''Site%20%E2%80%9Cphotos%E2%80%9D\.pdf$/);
    const reader = response.body.getReader();
    await until(() => page.replies.includes('pull'));
    page.port.postMessage({ type: 'chunk', bytes: new Uint8Array([1, 2, 3]) });
    page.port.postMessage({ type: 'chunk', bytes: new Uint8Array([4, 5, 6]) });
    page.port.postMessage({ type: 'close' });
    const got = [];
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        got.push(...value);
    }
    assert.deepEqual(got, [1, 2, 3, 4, 5, 6]);
    assert.equal(worker.fetchEvent(`${ORIGIN}/d/save/${ID}`), null, 'only once');
});

test('an aborted save fails the download rather than finishing it', async (t) => {
    const worker = startWorker();
    const page = post(worker, { type: 'szf-save', id: ID, name: 'a.pdf', size: 10 });
    t.after(page.close);
    await until(() => page.replies.includes('ready'));
    const reader = worker.fetchEvent(`${ORIGIN}/d/save/${ID}`).body.getReader();
    page.port.postMessage({ type: 'chunk', bytes: new Uint8Array([1]) });
    page.port.postMessage({ type: 'abort' });
    await reader.read();
    await assert.rejects(reader.read());
});

test('nothing else is answered: other paths, other origins, bad ids and malformed requests', async (t) => {
    const worker = startWorker();
    const bad = post(worker, { type: 'szf-save', id: 'not-hex', name: 'a', size: 1 });
    const negative = post(worker, { type: 'szf-save', id: ID, name: 'a', size: -1 });
    t.after(() => {
        bad.close();
        negative.close();
    });
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.deepEqual([...bad.replies, ...negative.replies], []);
    assert.equal(worker.fetchEvent(`${ORIGIN}/d/save/${ID}`), null);
    const page = post(worker, { type: 'szf-save', id: ID, name: 'a', size: 1 });
    t.after(page.close);
    await until(() => page.replies.includes('ready'));
    assert.equal(worker.fetchEvent(`https://elsewhere.example/d/save/${ID}`), null);
    assert.equal(worker.fetchEvent(`${ORIGIN}/d`), null);
    assert.equal(worker.fetchEvent(`${ORIGIN}/d/save/${ID}/x`), null);
});

test('the page streams through the worker one chunk per pull, in order, and the download ends whole', async () => {
    const worker = startWorker();
    const { streamSink } = loadLinkScript();
    let response = null;
    const win = { crypto: globalThis.crypto, MessageChannel, setTimeout: (fn, ms) => setTimeout(fn, ms).unref(),
        clearTimeout, navigator: { serviceWorker: { register: async (script, options) => {
            assert.deepEqual([script, options], ['/d/sw.js', { scope: '/d/save/' }]);
            return { active: { state: 'activated', postMessage: (data, ports) => worker.listeners.get('message')(
                { data, ports }) } };
        } } } };
    const doc = { createElement: () => ({}), body: { append: (frame) => {
        assert.equal(frame.hidden, true);
        response = worker.fetchEvent(`${ORIGIN}${frame.src}`);
    } } };
    const sink = await streamSink(win, doc, { name: 'big.bin', size: 40 * 1000 });
    assert.ok(response, 'the hidden frame opened the save');
    const reading = (async () => {
        const got = [];
        const reader = response.body.getReader();
        for (;;) {
            const { done, value } = await reader.read();
            if (done) return Buffer.concat(got);
            got.push(Buffer.from(value));
        }
    })();
    const expected = [];
    for (let i = 0; i < 40; i += 1) {
        const chunk = new Uint8Array(1000).fill(i);
        expected.push(Buffer.from(chunk));
        await sink.write(chunk);
    }
    await sink.close();
    assert.ok((await reading).equals(Buffer.concat(expected)));
});

test('Download falls back to memory only for a file memory can hold, and a closed picker does nothing', async () => {
    const { openSink } = loadLinkScript();
    const meta = { name: 'a.pdf', size: 1000, type: 'application/pdf' };
    const huge = { ...meta, size: 3 * 2 ** 30 };
    const traits = { mac: true, handheld: false, fileSystemAccess: true, serviceWorker: false };
    const failing = (name) => ({ URL, Blob, showSaveFilePicker: async () => {
        throw Object.assign(new Error(name), { name });
    } });
    assert.equal(await openSink(failing('AbortError'), {}, meta, traits), null, 'the person closed the picker');
    assert.equal((await openSink(failing('SecurityError'), {}, meta, traits)).kind, 'memory');
    assert.equal(await openSink(failing('SecurityError'), {}, huge, traits), 'nosave');
    const picked = { showSaveFilePicker: async ({ suggestedName }) => {
        assert.equal(suggestedName, 'a.pdf');
        return { createWritable: async () => ({ write: async () => {}, close: async () => {},
            abort: async () => {} }) };
    } };
    assert.equal((await openSink(picked, {}, huge, traits)).kind, 'file', 'any size to a picked file');
    const noWorker = { URL, Blob, crypto: globalThis.crypto, navigator: { serviceWorker: { register: async () => {
        throw new Error('no');
    } } } };
    const streaming = { ...traits, fileSystemAccess: false, serviceWorker: true };
    assert.equal((await openSink(noWorker, {}, meta, streaming)).kind, 'memory');
    assert.equal(await openSink(noWorker, {}, huge, streaming), 'nosave');
});
