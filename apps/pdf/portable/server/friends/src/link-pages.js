// The pages a friend link and a download link open (friends-links.md § Pages; PROTOCOL.md § Links): /f and /d,
// their stylesheet, their one script and the download page's service worker, all from src/pages/, read once at
// start. No third-party code, no analytics, no cookies. Each page's Content-Security-Policy allows only this host
// (and, for /d, its WebSocket and the blob: thumbnails and downloads it makes), frame-ancestors 'none', and every
// response says Referrer-Policy: no-referrer. Everything secret in a link is after `#`, which browsers never send,
// so no request ever carries it.

import crypto from 'node:crypto';
import fs from 'node:fs';

const PAGES = new URL('./pages/', import.meta.url);

// The script's parts, joined in this order into one function scope (src/pages/script/bytes.js says why).
export const LINK_SCRIPT_PARTS = Object.freeze(['bytes.js', 'sha256.js', 'link-crypto.js', 'receiver.js', 'save.js',
    'view.js', 'render.js', 'main.js']);

// Every path this module answers. The ingress (deploy/nginx-friends.conf) routes exactly these to the service.
export const LINK_PAGE_PATHS = Object.freeze(['/f', '/d', '/links/links.css', '/links/links.js', '/d/sw.js']);

const SHARED_POLICY = "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
const LOOPBACK_HOST = /^(127\.0\.0\.1|localhost|\[::1\])(:\d{1,5})?$/;
const HOST_HEADER = /^([A-Za-z0-9-]{1,63}\.)*[A-Za-z0-9-]{1,63}(:\d{1,5})?$|^\[[0-9A-Fa-f:.]{2,45}\](:\d{1,5})?$/;

function read(name) {
    return fs.readFileSync(new URL(name, PAGES), 'utf8');
}

// The parts as one source text, without the wrapper (the tests evaluate it with their own).
export function linkScriptSource() {
    return LINK_SCRIPT_PARTS.map((part) => read(`script/${part}`)).join('\n');
}

function escapeAttribute(value) {
    return String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')
        .replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function fill(template, values) {
    return template.replace(/\{\{(\w+)\}\}/g, (_, key) => escapeAttribute(values[key] ?? ''));
}

// /d talks to this host's WebSocket. 'self' covers it in current browsers; the host is named as well for older
// ones, from the request's own Host header when it is a plain host name or address.
function downloadPolicy(req) {
    const host = String(req.headers.host ?? '');
    let sockets = '';
    if (HOST_HEADER.test(host)) sockets = LOOPBACK_HOST.test(host) ? ` ws://${host} wss://${host}` : ` wss://${host}`;
    return "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; "
        + `connect-src 'self'${sockets}; worker-src 'self'; frame-src 'self'; ${SHARED_POLICY}`;
}

const FRIEND_POLICY = `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; ${SHARED_POLICY}`;
const ASSET_POLICY = `default-src 'none'; ${SHARED_POLICY}`;

function asset(type, text, policy) {
    const body = Buffer.from(text, 'utf8');
    const etag = `"${crypto.createHash('sha256').update(body).digest('base64url').slice(0, 27)}"`;
    return { type, body, etag, policy };
}

export function linkPages(config) {
    const values = {
        stun: config.online.guestIceServers.filter((uri) => uri.startsWith('stun:')).join(' '),
        pdfUrl: config.links.pdfUrl,
        filesUrl: config.links.filesUrl,
        threeDUrl: config.links.threeDUrl,
    };
    const html = 'text/html; charset=utf-8';
    const js = 'text/javascript; charset=utf-8';
    const assets = new Map([
        ['/f', asset(html, fill(read('friend.html'), values), () => FRIEND_POLICY)],
        ['/d', asset(html, fill(read('download.html'), values), downloadPolicy)],
        ['/links/links.css', asset('text/css; charset=utf-8', read('links.css'), () => ASSET_POLICY)],
        ['/links/links.js', asset(js, `'use strict';\n(() => {\n${linkScriptSource()}\n})();\n`, () => ASSET_POLICY)],
        ['/d/sw.js', asset(js, read('sw.js'), () => ASSET_POLICY)],
    ]);
    if (LINK_PAGE_PATHS.some((path) => !assets.has(path)) || assets.size !== LINK_PAGE_PATHS.length) {
        throw new Error('LINK_PAGE_PATHS and the served pages differ');
    }
    return {
        // Answers a request for a page or one of its files and returns true; returns false for anything else.
        handle(req, res) {
            let pathname;
            try {
                pathname = new URL(req.url, 'http://host').pathname;
            } catch {
                return false;
            }
            const page = assets.get(pathname);
            if (!page) return false;
            const headers = {
                'Content-Security-Policy': page.policy(req),
                'Referrer-Policy': 'no-referrer',
                'X-Content-Type-Options': 'nosniff',
                'X-Frame-Options': 'DENY',
                'Cross-Origin-Opener-Policy': 'same-origin',
                'Cross-Origin-Resource-Policy': 'same-origin',
                'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
                'Cache-Control': 'no-cache',
            };
            if (req.method !== 'GET' && req.method !== 'HEAD') {
                res.writeHead(405, { ...headers, Allow: 'GET, HEAD', 'Content-Type': 'text/plain' }).end();
                return true;
            }
            if (req.headers['if-none-match'] === page.etag) {
                res.writeHead(304, { ...headers, ETag: page.etag }).end();
                return true;
            }
            res.writeHead(200, { ...headers, 'Content-Type': page.type, 'Content-Length': page.body.length,
                ETag: page.etag });
            res.end(req.method === 'HEAD' ? undefined : page.body);
            return true;
        },
    };
}
