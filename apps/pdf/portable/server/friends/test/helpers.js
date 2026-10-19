// Test support: throwaway keys, signed lists, hosts on loopback with a controllable clock, and a scripted helper
// client. Nothing here listens beyond 127.0.0.1 or contacts any other host.

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import WebSocket from 'ws';

import { loadConfig } from '../src/config.js';
import { signPayload } from '../src/hostlist.js';
import { FriendsHost } from '../src/host.js';
import { LinkAuth, newKeyShare } from '../src/link-auth.js';
import { createLogger } from '../src/log.js';
import {
    decodeBase64url, encodeBase64url, hmacSha256, identitySecretCheck, rawPublicKey, signEd25519, verifyEd25519,
} from '../src/keys.js';
import {
    checkinSignedBytes, hostLinkSignedBytes, hostReplySignedBytes, message, releaseSignedBytes,
} from '../src/protocol.js';

export const SECRET = 'test-replica-secret-0123456789abcdef';
// What every shipped helper declares today. Suites about check-in, IDs and links between hosts run as these helpers,
// so protocol 1 keeps its coverage; the online Friends suites check in with protocol 2.
export const SHIPPED_PROTOCOL = 1;
export const IDENTITY_SECRET = 'test-identity-secret-0123456789abcdef';
export const PASSWORD = 'dashboard-password-for-tests';
// Every test client connects from 127.0.0.1, so suites that are not about the per-address limits lift them; the
// limit tests set their own values or clear these to get the defaults.
export const ROOMY_LIMITS = {
    FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY: '1000',
    FRIENDS_MAX_CONNECTIONS_PER_ADDRESS: '1000',
};

export function keyPair() {
    const { privateKey } = crypto.generateKeyPairSync('ed25519');
    return { privateKey, raw: rawPublicKey(privateKey), b64: encodeBase64url(rawPublicKey(privateKey)) };
}

export function tempDir(t, prefix = 'szf-host-') {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
    t?.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    return dir;
}

export class FakeClock {
    constructor(iso = '2026-10-12T06:47:48Z') {
        this.ms = Date.parse(iso);
    }

    now() {
        return this.ms;
    }

    advance(ms) {
        this.ms += ms;
    }

    set(iso) {
        this.ms = Date.parse(iso);
    }
}

export const DAY_MS = 86_400_000;

// A list of hosts on loopback. `entries` are {id, port?, key, priority, role}; ports may be filled in later, so a
// list can name a host before it starts (the replica tests start the main host first).
export function listPayload({ version = 1, entries, newIdWords = 2 }) {
    return {
        version,
        issued_at: '2026-10-12T06:00:00Z',
        new_id_words: newIdWords,
        hosts: entries.map((e) => ({ id: e.id, role: e.role ?? 'rendezvous',
            urls: [`ws://127.0.0.1:${e.port ?? 9}/v1`], region: e.region ?? 'Test', priority: e.priority,
            public_key: e.key.b64 })),
    };
}

export function signList(payload, signers) {
    return JSON.stringify(signPayload(payload, signers.map((s, i) => ({ name: i === 0 ? 'primary' : 'backup',
        privateKey: s.privateKey }))));
}

export async function startHost(t, { hostId, hostKey = keyPair(), listText, pinned, clock = new FakeClock(),
    env = {}, dataDir } = {}) {
    const dir = dataDir ?? tempDir(t);
    const listFile = path.join(dir, 'list.json');
    if (listText) fs.writeFileSync(listFile, listText);
    const keyFile = path.join(dir, 'host-key.pem');
    fs.writeFileSync(keyFile, hostKey.privateKey.export({ type: 'pkcs8', format: 'pem' }));
    const config = loadConfig({
        FRIENDS_HOST_ID: hostId,
        FRIENDS_LISTEN_HOST: '127.0.0.1',
        FRIENDS_LISTEN_PORT: '0',
        FRIENDS_DATA_DIR: path.join(dir, 'data'),
        FRIENDS_PINNED_KEYS: pinned.map((k) => k.b64).join(','),
        ...(listText ? { FRIENDS_HOST_LIST_FILE: listFile } : {}),
        FRIENDS_HOST_KEY_FILE: keyFile,
        FRIENDS_REPLICA_SECRET: SECRET,
        FRIENDS_IDENTITY_SECRET: IDENTITY_SECRET,
        FRIENDS_STATS_TZ: 'Asia/Hong_Kong',
        ...ROOMY_LIMITS,
        ...env,
    });
    const logs = [];
    const host = new FriendsHost(config, { clock, log: createLogger((line) => logs.push(line), clock) });
    const { port } = await host.start();
    t?.after(() => host.stop().catch(() => {}));
    return { host, port, url: `ws://127.0.0.1:${port}/v1`, logs, clock, dir, hostKey };
}

// One host that is its own main: the common case for single-host tests.
export async function startMain(t, options = {}) {
    const admin = options.admin ?? keyPair();
    const hostKey = options.hostKey ?? keyPair();
    const listText = signList(listPayload({ version: options.version ?? 1,
        entries: [{ id: 'main-hk', key: hostKey, priority: 1, role: 'both' }] }), [admin]);
    const started = await startHost(t, { hostId: 'main-hk', hostKey, listText, pinned: [admin], ...options });
    return { ...started, admin, hostKey };
}

// Whether a reply carries a valid signature by `hostKey` over the connection's challenge and `body`
// (HOST-PROTOCOL.md § Signatures).
export function replySignedBy(hostKey, challengeMsg, reply, body) {
    const sig = decodeBase64url(reply.host_sig, 64);
    const bytes = hostReplySignedBytes(decodeBase64url(challengeMsg.nonce, 32), body);
    return Boolean(sig) && verifyEd25519(hostKey.raw, bytes, sig);
}

// A raw host link, as a replica (or something holding a replica's key and secrets) would open one, for tests that
// play a compromised or misconfigured replica. Resolves with the client after the main host's answer. After a
// host_welcome, linkSend and linkNext speak the link's authenticated envelope (link-auth.js), as a replica must;
// `transcript` holds the handshake's ids, random values and key shares; `keyShare` replaces the fresh one.
export async function openLink(url, { replicaId = 'alt-sg', replicaKey, secret = SECRET,
    identitySecret = IDENTITY_SECRET, keyShare = newKeyShare() } = {}) {
    const client = await TestClient.connect(`${url}?link=1`);
    const challengeMsg = await client.challenge();
    const challenge = decodeBase64url(challengeMsg.nonce, 32);
    const nonce = crypto.randomBytes(32);
    const bytes = hostLinkSignedBytes({ mainHostId: challengeMsg.host_id, challenge, replicaHostId: replicaId, nonce,
        replicaShare: keyShare.share });
    client.send('host_hello', { host_id: replicaId, sig: encodeBase64url(signEd25519(replicaKey.privateKey, bytes)),
        mac: encodeBase64url(hmacSha256(secret, bytes)),
        identity_check: encodeBase64url(identitySecretCheck(identitySecret, challenge)),
        nonce: encodeBase64url(nonce), key_share: encodeBase64url(keyShare.share) });
    client.welcome = await client.next();
    client.transcript = { mainHostId: challengeMsg.host_id, replicaHostId: replicaId, challenge, nonce,
        replicaShare: keyShare.share, mainShare: decodeBase64url(client.welcome.key_share, 32) };
    client.auth = client.welcome.type === 'host_welcome' ? LinkAuth.derive({ secret, side: 'replica',
        privateKey: keyShare.privateKey, transcript: client.transcript }) : null;
    client.linkSend = (type, fields) => client.sendRaw(client.auth.wrap(type, fields));
    client.linkNext = async (timeoutMs) => {
        const envelope = await client.next(timeoutMs);
        const inner = client.auth.unwrap(envelope);
        if (!inner) throw new Error(`not an authentic link message: ${JSON.stringify(envelope).slice(0, 120)}`);
        return inner;
    };
    return client;
}

// A main host and a replica (alt-sg) sharing one clock; the replica's list names the main host's real port.
export async function startPair(t, { mainEnv = {}, replicaEnv = {}, replicaKey = keyPair(), listedReplicaKey } = {}) {
    const admin = keyPair();
    const mainKey = keyPair();
    const clock = new FakeClock();
    const entries = (mainPort) => [
        { id: 'main-hk', key: mainKey, priority: 1, port: mainPort, role: 'both' },
        { id: 'alt-sg', key: listedReplicaKey ?? replicaKey, priority: 2, port: 9 },
    ];
    const main = await startHost(t, { hostId: 'main-hk', hostKey: mainKey, pinned: [admin], clock, env: mainEnv,
        listText: signList(listPayload({ version: 1, entries: entries(9) }), [admin]) });
    const v2 = signList(listPayload({ version: 2, entries: entries(main.port) }), [admin]);
    if (!main.host.offerList(v2, { source: 'admin' }).ok) throw new Error('could not publish the pair list');
    const replica = await startHost(t, { hostId: 'alt-sg', hostKey: replicaKey, pinned: [admin], clock,
        listText: v2, env: replicaEnv });
    const linkUp = () => waitFor(() => replica.host.replicaLink?.state === 'up' && main.host.hostLinks.has('alt-sg'));
    return { admin, mainKey, replicaKey, main, replica, clock, entries, linkUp };
}

export function identity() {
    return keyPair();
}

// A scripted helper: queues every message so a test can await them in order.
export class TestClient {
    static async connect(url, { headers } = {}) {
        const client = new TestClient();
        await client.open(url, headers);
        return client;
    }

    open(url, headers) {
        this.queue = [];
        this.waiters = [];
        this.ws = new WebSocket(url, { headers });
        this.closed = new Promise((resolve) => {
            this.ws.on('close', (code, reason) => resolve({ code, reason: reason.toString() }));
        });
        this.ws.on('message', (data) => {
            const msg = JSON.parse(data.toString());
            const waiter = this.waiters.shift();
            if (waiter) waiter(msg);
            else this.queue.push(msg);
        });
        return new Promise((resolve, reject) => {
            this.ws.once('open', resolve);
            this.ws.once('error', reject);
            this.ws.once('unexpected-response', (req, res) => reject(new Error(`HTTP ${res.statusCode}`)));
        });
    }

    next(timeoutMs = 5000) {
        if (this.queue.length > 0) return Promise.resolve(this.queue.shift());
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('no message in time')), timeoutMs);
            this.waiters.push((msg) => {
                clearTimeout(timer);
                resolve(msg);
            });
        });
    }

    async expect(type, timeoutMs) {
        const msg = await this.next(timeoutMs);
        if (msg.type !== type) throw new Error(`expected ${type}, got ${JSON.stringify(msg)}`);
        return msg;
    }

    send(type, fields) {
        this.ws.send(message(type, fields));
    }

    sendRaw(text) {
        this.ws.send(text);
    }

    async challenge() {
        this.challengeMsg = this.challengeMsg ?? await this.expect('challenge');
        return this.challengeMsg;
    }

    // Signs and sends a check-in for `who` against this connection's challenge, and returns the host's answer. From
    // protocol 3, `root` (default `who`) is the person and `chain` (bytes) their device chain; `sentChain` replaces
    // the chain sent after signing.
    async checkin(who, { friendsId = 'maple-river', reserved = false, appVersion = '26.10.12-1',
        protocol = SHIPPED_PROTOCOL, listVersion = 1, hostId, challengeOverride, signer, root = who, chain = null,
        sentChain = chain } = {}) {
        const challenge = await this.challenge();
        const devices = protocol >= 3 ? { rootKey: root.raw, chain } : {};
        const fields = { hostId: hostId ?? challenge.host_id,
            challenge: challengeOverride ?? decodeBase64url(challenge.nonce, 32), identityKey: who.raw, friendsId,
            reserved, appVersion, protocol, listVersion, ...devices };
        const sig = signEd25519((signer ?? who).privateKey, checkinSignedBytes(fields));
        const sent = sentChain ? { chain: encodeBase64url(sentChain) } : {};
        const extra = protocol >= 3 ? { root_key: root.b64, ...sent } : {};
        this.send('checkin', { identity_key: who.b64, friends_id: friendsId, reserved, app_version: appVersion,
            protocol, list_version: listVersion, ...extra, sig: encodeBase64url(sig) });
        return this.next();
    }

    async reserve(friendsId) {
        this.send('reserve', { friends_id: friendsId });
        return this.next();
    }

    async release(who, { friendsId = 'maple-river', signer } = {}) {
        const challenge = await this.challenge();
        const fields = { hostId: challenge.host_id, challenge: decodeBase64url(challenge.nonce, 32),
            identityKey: who.raw, friendsId };
        const sig = signEd25519((signer ?? who).privateKey, releaseSignedBytes(fields));
        this.send('release', { identity_key: who.b64, friends_id: friendsId, sig: encodeBase64url(sig) });
        return this.next();
    }

    close() {
        this.ws.close();
        return this.closed;
    }

    terminate() {
        this.ws.terminate();
        return this.closed;
    }
}

export async function waitFor(predicate, { timeoutMs = 5000, intervalMs = 20 } = {}) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (await predicate()) return;
        await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
    throw new Error('condition not met in time');
}
