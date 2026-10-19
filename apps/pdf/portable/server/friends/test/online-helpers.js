// Test support for online Friends: hosts with FRIENDS_M2 and FRIENDS_RELAY on (loopback only, the STUN and statistics
// ports on 127.0.0.1 and chosen by the system), a fake helper that speaks protocol 2, and a browser guest. Nothing
// here leaves 127.0.0.1.

import crypto from 'node:crypto';

import { encodeBase64url, signEd25519 } from '../src/keys.js';
import { ONLINE_LIMITS, recordSignedBytes, rendezvousKey } from '../src/online-protocol.js';
import {
    FakeClock, TestClient, identity, keyPair, listPayload, signList, startHost, startMain, waitFor,
} from './helpers.js';

export const TURN_SECRET = 'test-turn-secret-0123456789abcdef0123';
export const EVENTS_PASSWORD = 'testEventsPassword0123456789abcd';
export const GUEST_ICE = ['turn:127.0.0.1:3478?transport=udp'];

// The settings every online suite starts from; `relay: false` leaves the relay off, `m2: false` online Friends.
export function onlineEnv({ m2 = true, relay = true } = {}) {
    return {
        ...(m2 ? { FRIENDS_M2: 'on', FRIENDS_STUN_PORTS: '0', FRIENDS_STUN_LISTEN: '127.0.0.1',
            FRIENDS_TURN_URIS: GUEST_ICE.join(',') } : {}),
        ...(relay ? { FRIENDS_RELAY: 'on', FRIENDS_TURN_SECRET: TURN_SECRET, FRIENDS_TURN_REALM: 'friends.test',
            FRIENDS_TURN_LISTEN_IPS: '127.0.0.1', FRIENDS_TURN_EVENTS_PASSWORD: EVENTS_PASSWORD,
            // No session limit, so no suite reaches for a coturn CLI on 127.0.0.1 unless it starts one itself.
            FRIENDS_TURN_EVENTS_PORT: '0', FRIENDS_TURN_MAX_SESSION_S: '0' } : {}),
    };
}

export async function startOnline(t, { env = {}, online = {}, ...options } = {}) {
    const started = await startMain(t, { ...options, env: { ...onlineEnv(online), ...env } });
    return { ...started, online: started.host.online };
}

// Waits for the next message of `type` (or of any type in an array), leaving every other message queued in order.
export async function nextOf(client, type, timeoutMs = 3000) {
    const types = Array.isArray(type) ? type : [type];
    let found = null;
    await waitFor(() => {
        const index = client.queue.findIndex((msg) => types.includes(msg.type));
        if (index < 0) return false;
        [found] = client.queue.splice(index, 1);
        return true;
    }, { timeoutMs, intervalMs: 5 });
    return found;
}

// True when no message of `type` arrives within `ms`.
export async function silent(client, type, ms = 150) {
    await new Promise((resolve) => setTimeout(resolve, ms));
    return !client.queue.some((msg) => msg.type === type);
}

export function sealedBlob() {
    return crypto.randomBytes(ONLINE_LIMITS.sealedRecordBytes);
}

export function nowS(clock) {
    return Math.floor(clock.now() / 1000);
}

// Moves the clock to the start of the next rendezvous period, when lookups show what was published in this one.
export function nextPeriod(clock) {
    const periodMs = ONLINE_LIMITS.rdvPeriodS * 1000;
    clock.advance(periodMs - (clock.now() % periodMs));
}

// A connection that seems to come from `address`: the host believes X-Real-IP from 127.0.0.1 only when the suite
// sets FRIENDS_TRUSTED_PROXY=127.0.0.1.
export function from(address) {
    return { 'X-Real-IP': address };
}

// A helper with protocol 2: checks in, then speaks online Friends.
export class FakeHelper {
    // With protocol 3, `root` and `chain` make it a device of the person whose root key `root` holds.
    static async connect(url, { who = identity(), friendsId = 'maple-river', protocol = 2, headers, root = who,
        chain = null } = {}) {
        const helper = new FakeHelper();
        helper.who = who;
        helper.client = await TestClient.connect(url, { headers });
        helper.welcome = await helper.client.checkin(who, { friendsId, protocol, root, chain });
        helper.hostId = helper.client.challengeMsg.host_id;
        helper.rdvKey = rendezvousKey(root.raw);
        helper.req = 0;
        return helper;
    }

    get queue() {
        return this.client.queue;
    }

    get key() {
        return encodeBase64url(this.rdvKey);
    }

    send(type, fields) {
        this.client.send(type, fields);
    }

    record({ seq = Date.now(), expires, sealed = sealedBlob(), hostId = this.hostId, signer = this.who,
        nowS: now } = {}) {
        const exp = expires ?? now + 600;
        const sig = signEd25519(signer.privateKey, recordSignedBytes({ hostId, rdvKey: this.rdvKey, seq, expires: exp,
            sealed }));
        return { seq, expires: exp, sealed: encodeBase64url(sealed), sig: encodeBase64url(sig) };
    }

    async publish(options) {
        const fields = this.record(options);
        this.send('rdv_publish', fields);
        const reply = await nextOf(this.client, 'rdv_published');
        return { reply, fields };
    }

    async open(to, payload = Buffer.from('noise ik message 1')) {
        this.req += 1;
        this.send('sig_open', { req: this.req, to, payload: encodeBase64url(payload) });
        return nextOf(this.client, ['sig_opened', 'sig_refused']);
    }

    message(sid, payload) {
        this.send('sig_msg', { sid, payload: encodeBase64url(Buffer.from(payload)) });
    }

    async credentials(sid) {
        this.req += 1;
        this.send('relay_credentials', { req: this.req, sid });
        return nextOf(this.client, ['relay_credentials_result', 'relay_refused']);
    }

    close() {
        return this.client.close();
    }
}

export function b64(text) {
    return encodeBase64url(Buffer.from(text));
}

export function text(b64value) {
    return Buffer.from(b64value, 'base64url').toString();
}

export async function guest(url, { headers } = {}) {
    return TestClient.connect(`${url}?guest=1`, { headers });
}

// A main host and two replicas (alt-sg, alt-tk) with online Friends on, sharing one clock, all on loopback.
// Replicas reach each other only through the main host, as in production.
export async function startTrio(t, { env = {} } = {}) {
    const admin = keyPair();
    const keys = { 'main-hk': keyPair(), 'alt-sg': keyPair(), 'alt-tk': keyPair() };
    const clock = new FakeClock();
    const entries = (mainPort) => [
        { id: 'main-hk', key: keys['main-hk'], priority: 1, port: mainPort, role: 'both' },
        { id: 'alt-sg', key: keys['alt-sg'], priority: 2, port: 9 },
        { id: 'alt-tk', key: keys['alt-tk'], priority: 3, port: 9 },
    ];
    const allEnv = { ...onlineEnv(), ...env };
    const main = await startHost(t, { hostId: 'main-hk', hostKey: keys['main-hk'], pinned: [admin], clock,
        env: allEnv, listText: signList(listPayload({ version: 1, entries: entries(9) }), [admin]) });
    const v2 = signList(listPayload({ version: 2, entries: entries(main.port) }), [admin]);
    if (!main.host.offerList(v2, { source: 'admin' }).ok) throw new Error('could not publish the trio list');
    const replica = async (id) => startHost(t, { hostId: id, hostKey: keys[id], pinned: [admin], clock,
        listText: v2, env: allEnv });
    const sg = await replica('alt-sg');
    const tk = await replica('alt-tk');
    await waitFor(() => main.host.hostLinks.has('alt-sg') && main.host.hostLinks.has('alt-tk')
        && sg.host.replicaLink?.state === 'up' && tk.host.replicaLink?.state === 'up');
    return { admin, clock, main, sg, tk };
}

export { identity, waitFor };
