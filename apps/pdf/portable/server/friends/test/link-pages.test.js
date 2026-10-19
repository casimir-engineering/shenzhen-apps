// The link pages as the host serves them (src/link-pages.js): the routes, the security headers every response
// carries, the one same-origin script, and the settings the pages are filled from.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { linksConfig } from '../src/config-links.js';
import { startMain } from './helpers.js';
import { onlineEnv } from './online-helpers.js';

const TURN_URIS = 'stun:127.0.0.1:3479,turn:127.0.0.1:3478?transport=udp';

async function host(t, env = {}) {
    const started = await startMain(t, { env: { ...onlineEnv({ relay: false }), FRIENDS_TURN_URIS: TURN_URIS,
        ...env } });
    return { ...started, base: `http://127.0.0.1:${started.port}` };
}

function directives(policy) {
    return new Map(policy.split(';').map((part) => part.trim().split(/\s+/)).map(([name, ...v]) => [name, v]));
}

test('/f and /d are served with a strict policy, no referrer, no framing and no cookies', async (t) => {
    const { base, port } = await host(t);
    for (const path of ['/f', '/d']) {
        const res = await fetch(`${base}${path}`);
        assert.equal(res.status, 200, path);
        assert.equal(res.headers.get('content-type'), 'text/html; charset=utf-8');
        assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
        assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
        assert.equal(res.headers.get('x-frame-options'), 'DENY');
        assert.equal(res.headers.get('set-cookie'), null);
        const csp = directives(res.headers.get('content-security-policy'));
        assert.deepEqual(csp.get('default-src'), ["'none'"]);
        assert.deepEqual(csp.get('script-src'), ["'self'"]);
        assert.deepEqual(csp.get('style-src'), ["'self'"]);
        assert.deepEqual(csp.get('frame-ancestors'), ["'none'"]);
        assert.deepEqual(csp.get('base-uri'), ["'none'"]);
        if (path === '/d') {
            assert.deepEqual(csp.get('connect-src'), ["'self'", `ws://127.0.0.1:${port}`, `wss://127.0.0.1:${port}`]);
            assert.deepEqual(csp.get('img-src'), ["'self'", 'blob:']);
            assert.deepEqual(csp.get('worker-src'), ["'self'"]);
        } else {
            assert.equal(csp.get('connect-src'), undefined, 'the friend page connects nowhere');
        }
        const html = await res.text();
        assert.match(html, /<meta name="referrer" content="no-referrer">/);
        const loads = [...html.matchAll(/\s(?:src|href)="([^"]*)"/g)].map((m) => m[1]);
        assert.deepEqual(loads.sort(), ['/links/links.css', '/links/links.js'], 'only this host\'s own files');
        assert.doesNotMatch(html, /<script>|\sstyle="|\son[a-z]+="/, 'no inline script, style or handler');
    }
});

test('the script, stylesheet and service worker are served; nothing else under the pages is', async (t) => {
    const { base } = await host(t);
    const script = await fetch(`${base}/links/links.js`);
    assert.equal(script.headers.get('content-type'), 'text/javascript; charset=utf-8');
    const source = await script.text();
    assert.match(source, /^'use strict';\n\(\(\) => \{/);
    assert.doesNotThrow(() => new Function(source), 'the joined parts are one valid script'); // eslint-disable-line
    assert.equal((await fetch(`${base}/links/links.css`)).headers.get('content-type'), 'text/css; charset=utf-8');
    const worker = await fetch(`${base}/d/sw.js`);
    assert.equal(worker.status, 200);
    assert.match(await worker.text(), /addEventListener\('fetch'/);
    for (const path of ['/f/', '/d/', '/links/', '/links/other.js', '/d/save/00112233445566778899aabbccddeeff',
        '/pages/friend.html', '/script/main.js']) {
        assert.equal((await fetch(`${base}${path}`)).status, 404, path);
    }
});

test('HEAD answers like GET without a body; other methods are refused; unchanged files answer 304', async (t) => {
    const { base } = await host(t);
    const head = await fetch(`${base}/d`, { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.ok(Number(head.headers.get('content-length')) > 500);
    assert.equal((await head.text()).length, 0);
    const post = await fetch(`${base}/f`, { method: 'POST', body: 'x' });
    assert.equal(post.status, 405);
    assert.equal(post.headers.get('allow'), 'GET, HEAD');
    const etag = (await fetch(`${base}/links/links.js`)).headers.get('etag');
    assert.equal((await fetch(`${base}/links/links.js`, { headers: { 'If-None-Match': etag } })).status, 304);
});

test('the download page gets the host\'s STUN servers but never its TURN servers', async (t) => {
    const { base } = await host(t);
    const html = await (await fetch(`${base}/d`)).text();
    assert.match(html, /data-stun="stun:127\.0\.0\.1:3479"/);
    assert.doesNotMatch(html, /turn:/);
});

test('a Host header that is not a host name never reaches the policy', async (t) => {
    const { port } = await host(t);
    const http = await import('node:http');
    const policy = await new Promise((resolve, reject) => {
        const req = http.request({ host: '127.0.0.1', port, path: '/d',
            headers: { Host: "evil.example; script-src 'unsafe-inline'" } }, (res) => {
            res.resume();
            resolve(res.headers['content-security-policy']);
        });
        req.on('error', reject);
        req.end();
    });
    assert.ok(policy);
    assert.doesNotMatch(policy, /unsafe-inline|evil/);
    assert.deepEqual(directives(policy).get('connect-src'), ["'self'"]);
});

test('the pages link to the apps from the settings, which must be https', async (t) => {
    const { base } = await host(t, { FRIENDS_LINKS_PDF_URL: 'https://example.org/pdf?a=1&b="2"' });
    const html = await (await fetch(`${base}/f`)).text();
    assert.match(html, /data-pdf-url="https:\/\/example\.org\/pdf\?a=1&amp;b=%222%22"/);
    assert.match(html, /data-files-url="https:\/\/github\.com\/casimir-engineering\/shenzhen-files\/releases\/latest"/);
    assert.match(html, /data-3d-url=""/, 'Shenzhen 3D has no download address unless one is set');
    const download = await (await fetch(`${base}/d`)).text();
    assert.match(download, /data-3d-url=""/);
    assert.equal(linksConfig({ FRIENDS_LINKS_3D_URL: 'https://example.org/3d' }).threeDUrl, 'https://example.org/3d');
    for (const value of ['http://example.org/', 'javascript:alert(1)', 'https://user:pw@example.org/', 'nonsense',
        `https://example.org/${'a'.repeat(300)}`]) {
        for (const name of ['FRIENDS_LINKS_FILES_URL', 'FRIENDS_LINKS_3D_URL']) {
            assert.throws(() => linksConfig({ [name]: value }),
                new RegExp(`^Error: ${name} must be an https URL of at most 300 characters$`), value);
        }
    }
});

test('Shenzhen 3D has no download address unless FRIENDS_LINKS_3D_URL is set', async (t) => {
    assert.equal(linksConfig({}).threeDUrl, '');
    assert.equal(linksConfig({ FRIENDS_LINKS_3D_URL: '' }).threeDUrl, '');
    assert.doesNotMatch(JSON.stringify(linksConfig({})), /shenzhen-3D/);
    const { base } = await host(t, { FRIENDS_LINKS_3D_URL: 'https://example.org/3d' });
    for (const path of ['/f', '/d']) {
        assert.match(await (await fetch(`${base}${path}`)).text(), /data-3d-url="https:\/\/example\.org\/3d"/, path);
    }
});

test('the friend page is served while online Friends is off', async (t) => {
    const started = await startMain(t);
    const res = await fetch(`http://127.0.0.1:${started.port}/f`);
    assert.equal(res.status, 200);
});
