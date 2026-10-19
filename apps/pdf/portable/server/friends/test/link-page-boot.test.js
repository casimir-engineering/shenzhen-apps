// The pages' script as the browser runs it: /links/links.js from the host, evaluated in a fresh context with a small
// stand-in for the page's DOM. Hostile names stay text, the Open buttons are plain links to the app schemes, the
// chosen app is remembered, and the download page sends the host the link id and never the secret.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';
import vm from 'node:vm';

import { startMain, waitFor } from './helpers.js';

class FakeElement {
    constructor(tag, id = null) {
        Object.assign(this, { tagName: tag.toUpperCase(), id, attributes: new Map(), children: [], listeners: [],
            textContent: '', hidden: false, className: '' });
    }

    setAttribute(name, value) {
        this.attributes.set(name, String(value));
    }

    getAttribute(name) {
        return this.attributes.has(name) ? this.attributes.get(name) : null;
    }

    removeAttribute(name) {
        this.attributes.delete(name);
    }

    addEventListener(type, listener) {
        this.listeners.push({ type, listener });
    }

    click() {
        for (const { type, listener } of this.listeners) if (type === 'click') listener({ preventDefault() {} });
    }

    replaceChildren(...children) {
        this.children = children;
    }

    append(...children) {
        this.children.push(...children);
    }
}

const IDS = ['title', 'lead', 'notes', 'actions', 'about', 'about-heading', 'about-text', 'about-links', 'file',
    'file-thumb', 'file-name', 'file-size', 'progress', 'progress-bar', 'progress-text'];

function fakePage({ page, hash, protocol = 'https:', host = 'friends.example' }) {
    const created = [];
    const elements = new Map(IDS.map((id) => [id, new FakeElement(id === 'file-thumb' ? 'img' : 'div', id)]));
    const body = new FakeElement('body');
    body.setAttribute('data-page', page);
    body.setAttribute('data-pdf-url', 'https://example.org/pdf');
    body.setAttribute('data-files-url', 'https://example.org/files');
    body.setAttribute('data-3d-url', 'https://example.org/3d');
    const document = {
        body,
        title: '',
        getElementById: (id) => elements.get(id) ?? null,
        createElement: (tag) => {
            const element = new FakeElement(tag);
            created.push(element);
            return element;
        },
    };
    const storage = new Map();
    const sockets = [];
    class FakeSocket {
        constructor(url) {
            this.url = url;
            this.sent = [];
            this.readyState = 1;
            sockets.push(this);
        }

        send(text) {
            this.sent.push(text);
        }

        close() {
            this.readyState = 3;
        }
    }
    const window = {
        location: { hash, protocol, host },
        navigator: { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like '
            + 'Gecko) Version/18.0 Safari/605.1.15', maxTouchPoints: 0 },
        localStorage: { getItem: (k) => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, String(v)) },
        crypto: globalThis.crypto,
        WebSocket: FakeSocket,
        RTCPeerConnection: function RTCPeerConnection() {},
        isSecureContext: true,
        setTimeout,
        clearTimeout,
        addEventListener() {},
        URL,
        Blob,
    };
    return { window, document, elements, created, storage, sockets };
}

async function run(t, page) {
    const { port } = await startMain(t);
    const source = await (await fetch(`http://127.0.0.1:${port}/links/links.js`)).text();
    vm.runInNewContext(source, { window: page.window, document: page.document, TextEncoder, TextDecoder, btoa, atob,
        console });
    return page;
}

const HOSTILE = '<img src=x onerror=alert(1)>‮evil';

function friendFragment(name) {
    return Buffer.concat([Buffer.of(1), crypto.randomBytes(48), Buffer.of(11), Buffer.from('brave-otter'),
        Buffer.of(Buffer.byteLength(name)), Buffer.from(name)]).toString('base64url');
}

test('the friend page shows a hostile name as text and opens the apps through plain links', async (t) => {
    const fragment = friendFragment(HOSTILE);
    const page = await run(t, fakePage({ page: 'friend', hash: `#${fragment}` }));
    const title = page.elements.get('title').textContent;
    assert.ok(title.includes('<img src=x onerror=alert(1)>'), 'the name is text');
    assert.ok(title.includes(`⁨${HOSTILE.replace('\u202E', '')}⁩ invited you`),
        'without its bidi override, and isolated, so it cannot reorder the sentence');
    assert.ok(!title.includes('\u202E'));
    assert.equal(page.document.title, title);
    assert.ok(!page.created.some((e) => e.tagName === 'IMG' || e.tagName === 'SCRIPT'));
    const buttons = page.elements.get('actions').children;
    assert.deepEqual(buttons.map((b) => [b.tagName, b.getAttribute('href')]), [
        ['A', `shenzhenpdf://friends/link#f.${fragment}`], ['A', `shenzhenfiles://friends/link#f.${fragment}`],
        ['A', `shenzhen3d://friends/link#f.${fragment}`]]);
    buttons[1].click();
    assert.equal(page.storage.get('szfriends-app'), 'files', 'the choice is remembered');
    buttons[2].click();
    assert.equal(page.storage.get('szfriends-app'), '3d', 'Shenzhen 3D as well');
    const about = page.elements.get('about-links').children;
    assert.deepEqual(about.map((a) => [a.textContent, a.getAttribute('href')]), [
        ['Get ShenzhenPDF', 'https://example.org/pdf'], ['Get Shenzhen Files', 'https://example.org/files'],
        ['Get Shenzhen 3D', 'https://example.org/3d']]);
});

test('a remembered app leads the friend page next time', async (t) => {
    const fragment = friendFragment('Mei');
    for (const [app, scheme] of [['files', 'shenzhenfiles'], ['3d', 'shenzhen3d']]) {
        const page = fakePage({ page: 'friend', hash: `#${fragment}` });
        page.storage.set('szfriends-app', app);
        await run(t, page);
        const first = page.elements.get('actions').children[0];
        assert.equal(first.getAttribute('href'), `${scheme}://friends/link#f.${fragment}`);
        assert.equal(first.className, 'button primary');
    }
});

test('the download page sends the host only the link id; the secret never leaves the page', async (t) => {
    const raw = Buffer.concat([Buffer.of(1), crypto.randomBytes(48)]);
    const fragment = raw.toString('base64url');
    const page = await run(t, fakePage({ page: 'download', hash: `#${fragment}` }));
    await waitFor(() => page.sockets.length > 0);
    assert.equal(page.sockets.length, 1);
    assert.equal(page.sockets[0].url, 'wss://friends.example/v1?guest=1');
    page.sockets[0].onmessage({ data: JSON.stringify({ type: 'challenge', v: 1, nonce: 'x', host_id: 'main-hk' }) });
    await waitFor(() => page.sockets[0].sent.length > 0);
    const open = JSON.parse(page.sockets[0].sent[0]);
    assert.equal(open.type, 'link_open');
    assert.equal(open.link_id, raw.subarray(1, 17).toString('base64url'));
    const everything = page.sockets[0].sent.join('');
    assert.ok(!everything.includes(raw.subarray(17).toString('base64url')), 'no secret');
    assert.ok(!everything.includes(fragment), 'no fragment');
    assert.equal(page.elements.get('title').textContent, 'Connecting to the sender…');
});

test('a broken download link says so and connects nowhere', async (t) => {
    const page = await run(t, fakePage({ page: 'download', hash: '#AAAA' }));
    assert.equal(page.elements.get('title').textContent, 'This download link is incomplete');
    assert.equal(page.sockets.length, 0);
});
