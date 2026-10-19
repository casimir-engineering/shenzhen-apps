// A sender's helper for download links, written in Node from PROTOCOL.md § Links (Browser downloads) with node:crypto
// only, so the page script is checked against an independent implementation of the same wire format. It checks in as
// a protocol 2 helper, registers a link, answers guests' opens with a challenge, creates a peer connection only after
// a valid proof, and sends the sealed metadata and chunks under the opener's credit, from the chunk the opener's
// start names (a download carrying on after a drop). `behaviour` makes it misbehave in the ways the tests need.

import crypto from 'node:crypto';

import { newId } from '../src/online-protocol.js';
import { FakeHelper, identity, nextOf, nowS } from './online-helpers.js';

const LABEL = { setup: 'SZFriends link setup v1', proof: 'SZFriends link proof v1',
    session: 'SZFriends link session v1', content: 'SZFriends link content v1', record: 'SZFriends link record v1' };
const FROM = { opener: 0x4f, sender: 0x53 };
const TYPE = { meta: 0x4d, chunk: 0x43, last: 0x46, end: 0x45, control: 0x51 };
export const CHUNK = 65280;

const b64 = (bytes) => Buffer.from(bytes).toString('base64url');
const hkdf = (secret, salt, info) => Buffer.from(crypto.hkdfSync('sha256', secret, salt, Buffer.from(info), 32));

function seal(key, iv, plain, aad) {
    const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    cipher.setAAD(aad);
    return Buffer.concat([cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
}

function open(key, iv, sealed, aad) {
    try {
        const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
        decipher.setAAD(aad);
        decipher.setAuthTag(sealed.subarray(sealed.length - 16));
        return Buffer.concat([decipher.update(sealed.subarray(0, sealed.length - 16)), decipher.final()]);
    } catch {
        return null;
    }
}

function nonce(type, index) {
    const out = Buffer.alloc(12);
    out[0] = type;
    out.writeBigUInt64BE(BigInt(index), 4);
    return out;
}

export class LinkSender {
    static async start(url, { clock, file, name = 'Site photos.pdf', sender = 'Mei', thumbnail = null,
        RTCPeerConnection, behaviour = {}, turn = null } = {}) {
        const s = new LinkSender();
        Object.assign(s, { url, clock, file, name, sender, thumbnail, RTCPeerConnection, behaviour, turn });
        s.who = identity();
        s.linkId = Buffer.from(newId(), 'base64url');
        s.secret = crypto.randomBytes(32);
        s.setupKey = hkdf(s.secret, s.linkId, LABEL.setup);
        s.proofKey = hkdf(s.secret, s.linkId, LABEL.proof);
        // PROTOCOL.md § Links: exactly the version, the link id and the secret; the name travels in the metadata.
        s.fragment = b64(Buffer.concat([Buffer.of(1), s.linkId, s.secret]));
        Object.assign(s, { sessions: new Map(), peersMade: 0, refusedHellos: 0, badProofs: 0, done: [],
            sentChunks: 0, controls: [], starts: [], drops: 0 });
        await s.online();
        return s;
    }

    async online() {
        this.helper = await FakeHelper.connect(this.url, { who: this.who, friendsId: 'kind-mole' });
        this.helper.client.ws.on('message', (data) => this.hostMessage(JSON.parse(data.toString())));
        this.helper.send('link_register', { link_id: b64(this.linkId), expires: nowS(this.clock) + 86_400 });
        const registered = await nextOf(this.helper.client, 'link_registered');
        if (!registered.ok) throw new Error(`link not registered: ${registered.reason}`);
    }

    async offline() {
        for (const session of this.sessions.values()) session.pc?.close();
        await this.helper.close();
    }

    unregister() {
        this.helper.send('link_unregister', { link_id: b64(this.linkId) });
    }

    // What a helper keeps after revoking or expiring a link, and tells its host on every connection.
    tombstone(reason) {
        const hash = crypto.createHash('sha256').update(Buffer.concat([Buffer.from('SZFriends link tombstone v1'),
            this.linkId])).digest();
        this.helper.send('link_tombstones', { tombstones: [{ hash: b64(hash), reason,
            until: nowS(this.clock) + 31 * 86_400 }] });
    }

    sealSetup(key, message) {
        const iv = crypto.randomBytes(12);
        const aad = Buffer.concat([Buffer.from(LABEL.setup), Buffer.of(FROM.sender), this.linkId]);
        return Buffer.concat([iv, seal(key, iv, Buffer.from(JSON.stringify(message)), aad)]);
    }

    openSetup(key, payload) {
        const bytes = Buffer.from(payload, 'base64url');
        const aad = Buffer.concat([Buffer.from(LABEL.setup), Buffer.of(FROM.opener), this.linkId]);
        const plain = bytes.length > 28 ? open(key, bytes.subarray(0, 12), bytes.subarray(12), aad) : null;
        return plain ? JSON.parse(plain.toString()) : null;
    }

    reply(sid, key, message) {
        this.helper.send('sig_msg', { sid, payload: b64(this.sealSetup(key, message)) });
    }

    hostMessage(msg) {
        if (msg.type === 'sig_incoming' && msg.via === 'link') this.incoming(msg);
        else if (msg.type === 'sig_msg') this.setup(msg).catch((error) => { this.error = error; });
        else if (msg.type === 'relay_credentials_result' || msg.type === 'relay_refused') this.relayAnswer?.(msg);
    }

    incoming(msg) {
        const hello = this.openSetup(this.setupKey, msg.payload);
        if (hello?.t !== 'hello') {
            this.refusedHellos += 1; // not sealed under this link's key: stay silent
            return;
        }
        if (this.behaviour.endBeforeChallenge) {
            this.reply(msg.sid, this.setupKey, { t: 'end', reason: this.behaviour.endBeforeChallenge });
            return;
        }
        const openerNonce = Buffer.from(hello.n, 'base64url');
        const senderNonce = crypto.randomBytes(16);
        const salt = Buffer.concat([openerNonce, senderNonce]);
        this.sessions.set(msg.sid, { openerNonce, senderNonce, salt, proved: false,
            sessionKey: hkdf(this.secret, salt, LABEL.session) });
        this.reply(msg.sid, this.setupKey, { t: 'challenge', n: b64(senderNonce), o: hello.n });
    }

    async setup(msg) {
        const session = this.sessions.get(msg.sid);
        const body = session && this.openSetup(session.sessionKey, msg.payload);
        if (!body) return;
        if (!session.proved) {
            const expected = crypto.createHmac('sha256', this.proofKey).update(Buffer.concat([Buffer.from(LABEL.proof),
                this.linkId, session.senderNonce, session.openerNonce])).digest();
            const mac = body.t === 'proof' ? Buffer.from(String(body.mac), 'base64url') : Buffer.alloc(0);
            if (mac.length !== 32 || !crypto.timingSafeEqual(mac, expected)) {
                this.badProofs += 1;
                this.helper.send('sig_close', { sid: msg.sid });
                return;
            }
            session.proved = true;
            return;
        }
        if (body.t === 'offer' && !(body.relay && this.behaviour.noRelay)) await this.answer(msg.sid, session, body);
        else if (body.t === 'cand' && session.pc && Array.isArray(body.c)) {
            for (const [candidate, mid] of body.c) await session.pc.addIceCandidate({ candidate, sdpMid: mid });
        }
    }

    relayServers(sid) {
        return new Promise((resolve) => {
            this.relayAnswer = (answer) => resolve(answer.type === 'relay_credentials_result'
                ? [{ urls: this.turn, username: answer.username, credential: answer.credential }] : []);
            this.helper.send('relay_credentials', { req: 9, sid });
        });
    }

    async answer(sid, session, offer) {
        session.pc?.close();
        const config = offer.relay ? { iceServers: await this.relayServers(sid), iceTransportPolicy: 'relay' }
            : { iceServers: [] };
        const pc = new this.RTCPeerConnection(config);
        this.peersMade += 1;
        session.pc = pc;
        session.attempt = offer.a;
        pc.onicecandidate = (event) => {
            if (event.candidate?.candidate) {
                this.reply(sid, session.sessionKey, { t: 'cand', a: offer.a,
                    c: [[event.candidate.candidate, event.candidate.sdpMid ?? '0']] });
            }
        };
        pc.ondatachannel = (event) => this.channel(session, event.channel, offer.a);
        await pc.setRemoteDescription({ type: 'offer', sdp: offer.sdp });
        await pc.setLocalDescription(await pc.createAnswer());
        this.reply(sid, session.sessionKey, { t: 'answer', a: offer.a, sdp: pc.localDescription.sdp });
    }

    record(key, type, index, plain) {
        const sealed = seal(key, nonce(type, index), plain, Buffer.from(LABEL.record));
        return Buffer.concat([Buffer.of(type), sealed]);
    }

    meta() {
        const sha256 = this.behaviour.wrongHash ? crypto.randomBytes(32)
            : crypto.createHash('sha256').update(this.file).digest();
        const json = Buffer.from(JSON.stringify({ name: this.name, size: this.file.length, type: 'application/pdf',
            sha256: b64(sha256), sender: this.sender }));
        const length = Buffer.alloc(4);
        length.writeUInt32BE(json.length);
        return Buffer.concat([length, json, this.thumbnail ?? Buffer.alloc(0)]);
    }

    channel(session, channel, attempt) {
        const key = hkdf(this.secret, session.salt, Buffer.concat([Buffer.from(LABEL.content), Buffer.of(attempt)]));
        const state = { next: 0, upto: 0, controlIndex: 0 };
        channel.binaryType = 'arraybuffer';
        const send = (bytes) => {
            this.maxRecord = Math.max(this.maxRecord ?? 0, bytes.length);
            channel.send(bytes);
        };
        const opened = () => {
            if (this.behaviour.endOnOpen) {
                send(this.record(key, TYPE.end, 0, Buffer.from(JSON.stringify({ reason: this.behaviour.endOnOpen }))));
                return;
            }
            send(this.record(key, TYPE.meta, 0, this.meta()));
        };
        channel.onmessage = (event) => {
            const bytes = Buffer.from(event.data);
            const plain = bytes[0] === TYPE.control
                ? open(key, nonce(TYPE.control, state.controlIndex), bytes.subarray(1), Buffer.from(LABEL.record))
                : null;
            if (!plain) return;
            state.controlIndex += 1;
            const control = JSON.parse(plain.toString());
            this.controls.push(control.t);
            if (control.t === 'done') this.done.push(control.ok);
            if (control.t === 'start') {
                this.starts.push(control.from ?? 0);
                if (Number.isSafeInteger(control.from) && control.from >= 0) state.next = control.from;
            }
            if (control.t === 'start' || control.t === 'credit') {
                state.upto = control.upto;
                this.pump(key, state, send, channel);
            }
        };
        if (channel.readyState === 'open') opened();
        else channel.onopen = opened;
    }

    pump(key, state, send, channel) {
        const count = Math.max(1, Math.ceil(this.file.length / CHUNK));
        if (state.pacing) return;
        while (state.next < state.upto && state.next < count && channel.readyState === 'open') {
            const i = state.next;
            if (this.behaviour.truncateAfter === i) {
                this.drops += 1;
                channel.close();
                return;
            }
            // A drop as the relay's session limit makes one: after `dropEvery` chunks on a connection, it ends a
            // moment later, once what was sent has arrived.
            if (this.behaviour.dropEvery && state.sent === this.behaviour.dropEvery) {
                if (!state.dropping) setTimeout(() => channel.close(), 30);
                if (!state.dropping) this.drops += 1;
                state.dropping = true;
                return;
            }
            state.sent = (state.sent ?? 0) + 1;
            const last = i === count - 1;
            const plain = this.file.subarray(i * CHUNK, Math.min(this.file.length, (i + 1) * CHUNK));
            const record = this.record(key, last ? TYPE.last : TYPE.chunk, i, plain);
            if (this.behaviour.tamperChunk === i) record[record.length - 20] ^= 0x01;
            if (this.behaviour.relabelLast && last) record[0] = TYPE.chunk;
            send(record);
            state.next += 1;
            this.sentChunks += 1;
            // A slow sender, so a relayed download lasts longer than the test's relay session limit.
            if (this.behaviour.chunkDelayMs) {
                state.pacing = true;
                setTimeout(() => {
                    state.pacing = false;
                    this.pump(key, state, send, channel);
                }, this.behaviour.chunkDelayMs);
                return;
            }
        }
    }
}
