// The admin dashboard: read-only HTML and JSON, plus publishing a signed host list, served on a Unix socket in
// the data directory and never on a TCP port or the shared Docker network (ADR 0005 § Admin dashboard). The admin
// reaches it with SSH local forwarding to that socket; HTTP basic auth from the stack's .env is a second check.

import fs from 'node:fs';
import http from 'node:http';

import { renderDashboard } from './dashboard-page.js';
import { safeEqual } from './keys.js';
import { newId } from './online-protocol.js';
import { MAX_MESSAGE_BYTES } from './protocol.js';
import { summarize } from './stats.js';

const SECURITY_HEADERS = {
    // Everything is inline and server-rendered: no scripts, no external assets, no framing.
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
        + "frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Cache-Control': 'no-store',
};

function authorized(config, header) {
    if (typeof header !== 'string' || !header.startsWith('Basic ')) return false;
    const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
    const colon = decoded.indexOf(':');
    if (colon < 0) return false;
    // Both comparisons always run, so timing does not reveal whether the user name was right.
    const user = safeEqual(decoded.slice(0, colon), config.dashboardUser);
    const password = safeEqual(decoded.slice(colon + 1), config.dashboardPassword);
    return user && password;
}

function send(res, status, type, body, extra = {}) {
    res.writeHead(status, { ...SECURITY_HEADERS, 'Content-Type': type, ...extra });
    res.end(body);
}

// Reads at most `limit` bytes; past that it keeps draining without storing, so the answer can still be a 413
// rather than a reset connection.
function readBody(req, limit) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;
        req.on('data', (chunk) => {
            size += chunk.length;
            if (size <= limit) chunks.push(chunk);
        });
        req.on('end', () => resolve(size > limit ? null : Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

// A relay credential for the admin's own check (DEPLOY.md, "Online Friends"): valid 5 minutes to start an
// allocation, counted in the statistics as a test session rather than a connection.
function relayTest(host, res) {
    if (!host.online?.relayOn) {
        const error = 'the relay is off on this host (FRIENDS_RELAY)';
        send(res, 409, 'application/json', `${JSON.stringify({ error })}\n`);
        return;
    }
    const issued = host.online.issueCredential({ sid: `test:${newId()}`, kind: 'test' });
    send(res, 200, 'application/json', `${JSON.stringify({ ...issued, uris: host.config.online.guestIceServers },
        null, 2)}\n`);
}

async function handle(host, req, res) {
    if (!authorized(host.config, req.headers.authorization)) {
        send(res, 401, 'text/plain; charset=utf-8', 'Sign in with the dashboard user and password from .env.\n',
            { 'WWW-Authenticate': 'Basic realm="Friends host", charset="UTF-8"' });
        return;
    }
    const { pathname } = new URL(req.url, 'http://dashboard');
    if (req.method === 'GET' && pathname === '/') {
        send(res, 200, 'text/html; charset=utf-8', renderDashboard(summarize(host)));
    } else if (req.method === 'GET' && pathname === '/stats.json') {
        send(res, 200, 'application/json', `${JSON.stringify(summarize(host), null, 2)}\n`);
    } else if (req.method === 'POST' && pathname === '/lists') {
        if (!host.isMain) {
            send(res, 409, 'application/json', `${JSON.stringify({ error: 'publish lists on the main host' })}\n`);
            return;
        }
        const body = await readBody(req, MAX_MESSAGE_BYTES);
        if (body === null) {
            send(res, 413, 'application/json', `${JSON.stringify({ error: 'a signed list is at most 64 KiB' })}\n`);
            return;
        }
        const result = host.offerList(body, { source: 'admin' });
        if (result.ok) send(res, 200, 'application/json', `${JSON.stringify({ published: result.version })}\n`);
        else send(res, 400, 'application/json', `${JSON.stringify({ error: result.error })}\n`);
    } else if (req.method === 'POST' && pathname === '/relay-test') {
        relayTest(host, res);
    } else {
        send(res, 404, 'text/plain; charset=utf-8', 'Not found\n');
    }
}

// Removes a leftover socket from a previous run, but never a regular file someone pointed the variable at.
function clearStaleSocket(socketPath) {
    let stat;
    try {
        stat = fs.lstatSync(socketPath);
    } catch (error) {
        if (error.code === 'ENOENT') return;
        throw error;
    }
    if (!stat.isSocket()) throw new Error('FRIENDS_DASHBOARD_SOCKET names a file that is not a socket');
    fs.unlinkSync(socketPath);
}

export async function startDashboard(host) {
    const { config } = host;
    if (!config.dashboardPassword) {
        host.log('dashboard', { state: 'disabled', reason: 'no password' });
        return null;
    }
    clearStaleSocket(config.dashboardSocket);
    const server = http.createServer((req, res) => {
        handle(host, req, res).catch((error) => {
            host.logError('dashboard', error);
            if (!res.headersSent) send(res, 500, 'text/plain; charset=utf-8', 'The dashboard failed; see the logs.\n');
        });
    });
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(config.dashboardSocket, resolve);
    });
    // The data directory is 0700 already; 0600 on the socket keeps it to the service's user (and root, which is
    // how SSH forwarding reaches it).
    fs.chmodSync(config.dashboardSocket, 0o600);
    host.log('dashboard', { state: 'listening' });
    return {
        close: () => new Promise((resolve) => {
            server.close(() => {
                try {
                    fs.unlinkSync(config.dashboardSocket);
                } catch {
                    // already gone
                }
                resolve();
            });
            server.closeAllConnections?.();
        }),
    };
}
