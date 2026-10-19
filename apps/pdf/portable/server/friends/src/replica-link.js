// A replica's link to the main host (ADR 0005 § Replicas). Reservations and releases are forwarded with the
// helper's own signature and answered by the main host, the only allocator; when it cannot be reached in time the
// replica answers "unavailable" and never allocates. The main host's Friends ID table is copied here (id-sync.js),
// so this host can take over as the main host. Check-in summaries wait in the database until the main host
// acknowledges them, so counts survive an outage of either side. Connection counts go up once a minute. Nothing
// from the main host is believed before it signs this link's nonce and both key shares, and after that only messages
// authenticated with a key only the two ends of this link can derive (link-auth.js), in order; anything else drops
// the link.

import WebSocket from 'ws';

import { mainHost } from './hostlist.js';
import { IdTableReceiver } from './id-sync.js';
import {
    decodeBase64url, encodeBase64url, hmacSha256, identitySecretCheck, randomBytes, signEd25519, verifyEd25519,
} from './keys.js';
import { LinkAuth, newKeyShare } from './link-auth.js';
import { errorCode } from './log.js';
import { HOST_ONLINE_TYPES } from './online-protocol.js';
import {
    LINK_QUERY, MAX_LINK_MESSAGE_BYTES, hostLinkSignedBytes, hostLinkWelcomeSignedBytes, message, validFriendsId,
} from './protocol.js';
import { acknowledgeForwards, enqueueForward, pendingForwards } from './records.js';

const RESERVATIONS = new Set(['reserved', 'taken', 'invalid', 'unavailable']);
const UNAVAILABLE = { reservation: 'unavailable', friendsId: null };
const BATCH = 100;
const MAX_BACKOFF_MS = 60_000;

export class ReplicaLink {
    constructor(host) {
        this.host = host;
        this.ws = null;
        this.state = 'down';
        this.pending = new Map();
        this.nextReq = 1;
        this.attempt = 0;
        this.sentThrough = 0;
        this.stopped = true;
        this.ids = new IdTableReceiver(host);
    }

    start() {
        this.stopped = false;
        this.connect();
    }

    stop() {
        this.stopped = true;
        clearTimeout(this.retry);
        clearTimeout(this.heartbeat);
        this.ws?.terminate();
        this.ws = null;
        this.down();
    }

    // The main host changed in a new list: drop the old link and dial the new main at once.
    restart() {
        this.stop();
        this.attempt = 0;
        this.start();
    }

    connect() {
        if (this.stopped) return;
        const main = mainHost(this.host.list);
        if (!main || main.id === this.host.config.hostId) return;
        if (!this.host.config.hostKey || !this.host.config.replicaSecret) {
            this.host.log('replica_link', { state: 'unconfigured' });
            return;
        }
        // ?link=1 gives this connection the host-link message limit instead of a helper's.
        const url = new URL(main.urls[this.attempt % main.urls.length]);
        url.searchParams.set(LINK_QUERY, '1');
        const ws = new WebSocket(url, { maxPayload: MAX_LINK_MESSAGE_BYTES, handshakeTimeout: 10_000,
            perMessageDeflate: false });
        this.ws = ws;
        this.mainId = main.id;
        this.mainKey = main.publicKey;
        this.nonce = randomBytes(32);
        // A new X25519 key pair for every connection, so every link has its own key.
        this.keyShare = newKeyShare();
        this.challenge = null;
        this.auth = null;
        ws.on('message', (data) => this.receive(ws, data));
        ws.on('ping', () => this.alive(ws));
        ws.on('open', () => this.alive(ws));
        ws.on('error', (error) => this.host.log('replica_link', { state: 'error', code: errorCode(error) }));
        ws.on('close', () => {
            if (this.ws !== ws) return;
            this.ws = null;
            this.down();
            this.schedule();
        });
    }

    // The main host pings every interval; silence for two and a half of them means the link is dead even if TCP
    // has not noticed yet.
    alive(ws) {
        clearTimeout(this.heartbeat);
        this.heartbeat = setTimeout(() => ws.terminate(), this.host.config.limits.pingIntervalMs * 2.5);
    }

    schedule() {
        if (this.stopped) return;
        const cap = Math.min(MAX_BACKOFF_MS, 1000 * 2 ** this.attempt);
        this.attempt += 1;
        this.retry = setTimeout(() => this.connect(), 500 + Math.random() * cap);
    }

    down() {
        const wasUp = this.state === 'up';
        if (wasUp) this.host.log('replica_link', { state: 'down' });
        this.state = 'down';
        this.auth = null;
        this.sentThrough = 0;
        this.inFlight = false;
        this.ids.reset();
        for (const [, pending] of this.pending) {
            clearTimeout(pending.timer);
            pending.resolve(null);
        }
        this.pending.clear();
        if (wasUp) this.host.online?.federation.linkDown(this.mainId);
    }

    // host_hello goes as it is; everything after the main host's welcome is authenticated with the link key.
    send(type, fields) {
        if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
        this.ws.send(this.auth ? this.auth.wrap(type, fields) : message(type, fields));
    }

    receive(ws, data) {
        let msg;
        try {
            msg = JSON.parse(data.toString('utf8'));
        } catch {
            msg = null;
        }
        if (this.auth) {
            const inner = msg && this.auth.unwrap(msg);
            if (!inner) {
                this.host.log('replica_link', { state: 'refused', reason: 'link authentication' });
                ws.terminate();
                return undefined;
            }
            return this.authenticated(inner);
        }
        if (!msg || typeof msg !== 'object') return undefined;
        switch (msg.type) {
        case 'challenge':
            return this.hello(ws, msg);
        case 'host_welcome':
            return this.welcomed(ws, msg);
        case 'error':
            this.host.log('replica_link', { state: 'refused', code: String(msg.code ?? '') });
            return undefined;
        default:
            // Nothing else is believed before the main host has proved itself.
            return undefined;
        }
    }

    authenticated(msg) {
        switch (msg.type) {
        case 'fwd_reserve_result':
        case 'fwd_release_result':
            return this.answer(msg);
        case 'ack':
            if (Number.isSafeInteger(msg.through) && msg.through > 0) acknowledgeForwards(this.host.db, msg.through);
            this.inFlight = false;
            return this.flush();
        case 'host_list':
            if (msg.host_list) this.host.offerList(msg.host_list, { source: 'main' });
            return undefined;
        default:
            // Online Friends between hosts (online-federation.js), when it is on here.
            if (HOST_ONLINE_TYPES.has(msg.type)) this.host.online?.federation.fromLink(this.mainId, msg);
            else this.ids.handle(msg);
            return undefined;
        }
    }

    // Nothing from the main host is believed until it signs the replica's nonce with the host key the list gives
    // the main host: a TLS-intercepting proxy must not be able to feed this host an ID table it could later
    // allocate from.
    welcomed(ws, msg) {
        const signature = decodeBase64url(msg.sig, 64);
        const mainShare = decodeBase64url(msg.key_share, 32);
        const transcript = { mainHostId: this.mainId, replicaHostId: this.host.config.hostId,
            challenge: this.challenge, nonce: this.nonce, replicaShare: this.keyShare?.share, mainShare };
        const signed = msg.host_id === this.mainId && Boolean(this.challenge && this.keyShare && mainShare)
            && verifyEd25519(this.mainKey, hostLinkWelcomeSignedBytes(transcript), signature);
        const auth = signed ? LinkAuth.derive({ secret: this.host.config.replicaSecret, side: 'replica',
            privateKey: this.keyShare.privateKey, transcript }) : null;
        // The private half is needed for nothing else; dropping it now keeps it from outliving the handshake.
        this.keyShare = null;
        if (!auth) {
            this.host.log('replica_link', { state: 'refused', reason: signed ? 'key share' : 'main host signature' });
            ws.close();
            return undefined;
        }
        this.auth = auth;
        this.state = 'up';
        this.attempt = 0;
        this.host.log('replica_link', { state: 'up' });
        if (msg.host_list) this.host.offerList(msg.host_list, { source: 'main' });
        this.host.online?.federation.linkUp(this.mainId);
        return this.flush();
    }

    hello(ws, msg) {
        const challenge = Buffer.from(String(msg.nonce ?? ''), 'base64url');
        // No key share left means this connection's handshake already ended in a refusal.
        if (msg.host_id !== this.mainId || challenge.length !== 32 || !this.keyShare) {
            ws.close();
            return;
        }
        this.challenge = challenge;
        const bytes = hostLinkSignedBytes({ mainHostId: this.mainId, challenge, replicaHostId: this.host.config.hostId,
            nonce: this.nonce, replicaShare: this.keyShare.share });
        this.send('host_hello', {
            host_id: this.host.config.hostId,
            sig: encodeBase64url(signEd25519(this.host.config.hostKey, bytes)),
            mac: encodeBase64url(hmacSha256(this.host.config.replicaSecret, bytes)),
            identity_check: encodeBase64url(identitySecretCheck(this.host.config.identitySecret, challenge)),
            nonce: encodeBase64url(this.nonce),
            key_share: encodeBase64url(this.keyShare.share),
        });
    }

    request(type, fields) {
        if (this.state !== 'up') return Promise.resolve(null);
        const req = this.nextReq++;
        return new Promise((resolve) => {
            const timer = setTimeout(() => {
                this.pending.delete(req);
                resolve(null);
            }, this.host.config.limits.forwardTimeoutMs);
            this.pending.set(req, { resolve, timer });
            this.send(type, { req, ...fields });
        });
    }

    answer(msg) {
        const pending = this.pending.get(msg.req);
        if (!pending) return;
        this.pending.delete(msg.req);
        clearTimeout(pending.timer);
        pending.resolve(msg);
    }

    // This host spends its own daily new-ID budget for the helper's address, because only it knows the address;
    // the main host grants a new ID only when told it may, and says whether it did so the slot can be refunded.
    async reserve({ friendsId, afterCollision, proof, addressKey }) {
        const day = this.host.today();
        const allowNew = this.host.admission.newIds.take(addressKey, day);
        const answer = await this.request('fwd_reserve', { friends_id: friendsId, after_collision: afterCollision,
            allow_new: allowNew, proof });
        if (allowNew && answer?.granted !== true) this.host.admission.newIds.refund(addressKey, day);
        if (!answer || !RESERVATIONS.has(answer.reservation)) return UNAVAILABLE;
        if (answer.reservation !== 'reserved') return { reservation: answer.reservation, friendsId: null };
        return validFriendsId(answer.friends_id) ? { reservation: 'reserved', friendsId: answer.friends_id }
            : UNAVAILABLE;
    }

    async release({ proof }) {
        const answer = await this.request('fwd_release', { proof });
        return answer?.released === true;
    }

    // `identity_hash` names the person; `device_hash` the device that checked in (the same before protocol 3).
    enqueueSummary({ identityHash, deviceHash = identityHash, day, appVersion, listVersion, protocol }) {
        enqueueForward(this.host.db, { identity_hash: encodeBase64url(identityHash),
            device_hash: encodeBase64url(deviceHash), day, app_version: appVersion, list_version: listVersion,
            protocol });
        this.flush();
    }

    // One batch in flight at a time; the main host's ack releases the next. After a reconnect sentThrough restarts
    // at zero, so anything sent but not acknowledged goes again (recording a summary twice changes nothing).
    flush() {
        if (this.state !== 'up' || this.inFlight) return;
        const rows = pendingForwards(this.host.db, this.sentThrough, BATCH);
        if (rows.length === 0) return;
        this.inFlight = true;
        this.sentThrough = rows[rows.length - 1].seq;
        this.send('fwd_summaries', { items: rows.map((row) => ({ seq: row.seq, ...row.body })) });
    }

    report({ minute, day, connections, listVersions }) {
        if (this.state !== 'up') return;
        const relay = this.host.online?.stats.snapshot();
        this.send('report', { minute, day, connections, list_versions: Object.fromEntries(listVersions),
            ...(relay ? { relay } : {}) });
    }
}
