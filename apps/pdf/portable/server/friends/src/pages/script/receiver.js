// Shenzhen Friends link pages, part 4 of 8: the browser end of a download link (PROTOCOL.md § Links, Browser
// downloads). It connects to the host as a guest, proves the link's secret with an HMAC over the sender's challenge,
// opens a WebRTC data channel (STUN first, the host's TURN relay only when no direct path opens), then receives the
// sealed metadata and, after Download, the sealed chunks, hashing each one and writing it to a sink. The last chunk
// is written only after the whole file's SHA-256 matches, so a file that did not arrive intact never completes.
//
// A download whose connection drops (the relay ends every session after an hour; networks change) carries on: the
// page connects again with fresh nonces, so a fresh session and content key, checks that the metadata is the same
// file's, and asks for the chunks from the first one it has not written. Its hash and sink carry over, so files of
// any size finish. It gives up after `resumes` reconnections in a row that brought no new chunk.
//
// `env` holds what it needs from the browser (WebSocket, RTCPeerConnection, crypto, timers, now), so the tests run
// this same code in Node against a JS sender and node-datachannel.

const LINK_TIMING = Object.freeze({
    directMs: 12_000, // a direct path must open within this, or the relay is tried
    relayMs: 25_000, // then the relayed connection must open within this
    candidateBatchMs: 50,
    retryMs: 3_000, // first wait before connecting to the host again; doubles after each failure
    retries: 4, // connection failures before the page says it cannot connect
    heldWithinMs: 300_000, // an unanswered open that ends sooner was for a link nobody holds
    relayAnswerMs: 5_000,
    resumes: 3, // reconnections in a row without a new chunk before a download fails
    disconnectedMs: 8_000, // a peer connection disconnected this long counts as lost (the relay ended it, say)
    stallMs: 30_000, // so does a download that receives nothing this long while the sender has credit
});
const CREDIT_WINDOW = 64; // chunks the sender may send ahead of what has been written (about 4 MiB)
const CREDIT_STEP = 16;
const SETUP_JSON_MAX = 3_000; // candidates per setup payload are batched under this, well inside 4,096 bytes sealed
const END_REASONS = new Set(['revoked', 'expired', 'changed', 'unavailable']);

class LinkReceiver {
    constructor(env, { wsUrl, link, stunUrls = [], timing = {}, onState = () => {} }) {
        this.env = env;
        this.wsUrl = wsUrl;
        this.link = link;
        this.stunUrls = stunUrls;
        this.timing = { ...LINK_TIMING, ...timing };
        this.onState = onState;
        this.phase = 'idle';
        this.failures = 0;
        this.work = Promise.resolve();
        this.outgoing = Promise.resolve();
    }

    emit(state, detail = {}) {
        // While a download reconnects, the page keeps showing its progress, and says what it is waiting for.
        if (this.resuming && (state === 'connecting' || state === 'waiting')) {
            this.state = 'progress';
            this.onState('progress', { received: this.received, size: this.meta.size, resuming: state });
            return;
        }
        this.state = state;
        this.onState(state, detail);
    }

    // Runs `step` after every earlier one, so messages and records are handled in the order they arrived.
    serial(step) {
        this.work = this.work.then(step).catch((error) => this.fail(error?.linkReason ?? 'lost'));
        return this.work;
    }

    async start() {
        this.keys = this.keys ?? await linkKeys(this.env, this.link);
        this.phase = 'idle';
        this.failures = 0;
        this.connect();
    }

    connect() {
        if (this.phase === 'failed' || this.phase === 'done') return;
        this.closeSignalling();
        this.nonce = randomBytes(this.env, 16);
        this.sid = null;
        this.phase = 'connecting';
        if (this.state !== 'waiting') this.emit('connecting');
        const ws = new this.env.WebSocket(this.wsUrl);
        this.ws = ws;
        ws.onmessage = (event) => {
            let msg = null;
            try {
                msg = JSON.parse(event.data);
            } catch {
                msg = null;
            }
            if (this.ws !== ws || !msg) return;
            // A relay answer is awaited by a step already in the queue, so it does not wait its turn.
            if (msg.type === 'relay_credentials_result' || msg.type === 'relay_refused') this.relayAnswer?.(msg);
            else this.serial(() => this.hostMessage(msg));
        };
        ws.onclose = () => {
            if (this.ws === ws) this.serial(() => this.hostClosed());
        };
        ws.onerror = () => {};
    }

    send(type, fields) {
        if (this.ws?.readyState === 1) this.ws.send(JSON.stringify({ type, v: 1, ...fields }));
    }

    // A setup message to the sender, sealed under this session's key, in order with every other.
    signal(message) {
        const { ws, sid } = this;
        this.outgoing = this.outgoing.then(async () => {
            const payload = await sealSetup(this.env, this.session, LINK_FROM.opener, this.link.linkId, message);
            if (this.ws === ws && ws.readyState === 1) {
                ws.send(JSON.stringify({ type: 'sig_msg', v: 1, sid, payload: b64uEncode(payload) }));
            }
        }).catch(() => {});
        return this.outgoing;
    }

    async hostMessage(msg) {
        if (msg.type === 'challenge' && this.phase === 'connecting') {
            const hello = await sealSetup(this.env, this.keys.setup, LINK_FROM.opener, this.link.linkId,
                { t: 'hello', v: 1, n: b64uEncode(this.nonce) });
            this.send('link_open', { req: 1, link_id: b64uEncode(this.link.linkId), payload: b64uEncode(hello) });
            this.phase = 'opening';
        } else if (msg.type === 'sig_opened' && this.phase === 'opening') {
            // Nobody holds the link, and its sender left word why (HOST-PROTOCOL-ONLINE.md § Download links).
            if (msg.link_ended === 'revoked' || msg.link_ended === 'expired') return this.end(msg.link_ended);
            this.sid = msg.sid;
            this.openedAt = this.env.now();
            this.ownerOnline = msg.owner_online === true;
            this.phase = 'hello';
            this.failures = 0;
            this.emit(this.ownerOnline ? 'connecting' : 'waiting');
        } else if (msg.type === 'sig_refused') {
            this.fail('busy');
        } else if (msg.type === 'sig_msg' && msg.sid === this.sid) {
            await this.setupMessage(b64uDecode(msg.payload));
        } else if (msg.type === 'sig_closed' && msg.sid === this.sid) {
            this.sidClosed(msg.reason);
        }
        return undefined;
    }

    async setupMessage(bytes) {
        if (!bytes) return;
        if (this.phase === 'hello') {
            const msg = await openSetup(this.env, this.keys.setup, LINK_FROM.sender, this.link.linkId, bytes);
            if (msg?.t === 'end') return this.end(msg.reason);
            const senderNonce = msg?.t === 'challenge' && msg.o === b64uEncode(this.nonce) ? b64uDecode(msg.n) : null;
            if (!senderNonce || senderNonce.length !== 16) return undefined;
            this.senderNonce = senderNonce;
            this.session = await sessionKey(this.env, this.link, this.nonce, senderNonce);
            const mac = await proofMac(this.env, this.keys, this.link, senderNonce, this.nonce);
            this.phase = 'proved';
            this.emit('connecting');
            this.signal({ t: 'proof', mac: b64uEncode(mac) });
            return this.attempt(1, null);
        }
        if (this.phase !== 'proved') return undefined;
        const msg = await openSetup(this.env, this.session, LINK_FROM.sender, this.link.linkId, bytes);
        if (msg?.t === 'end') return this.end(msg.reason);
        if (!msg || msg.a !== this.attemptNo || !this.pc) return undefined;
        if (msg.t === 'answer' && typeof msg.sdp === 'string' && !this.remoteSet) {
            await this.pc.setRemoteDescription({ type: 'answer', sdp: msg.sdp });
            this.remoteSet = true;
            for (const candidate of this.early.splice(0)) await this.addCandidate(candidate);
        } else if (msg.t === 'cand' && Array.isArray(msg.c)) {
            for (const candidate of msg.c.slice(0, 64)) {
                if (this.remoteSet) await this.addCandidate(candidate);
                else this.early.push(candidate);
            }
        }
        return undefined;
    }

    async addCandidate(candidate) {
        if (!Array.isArray(candidate) || typeof candidate[0] !== 'string' || typeof candidate[1] !== 'string') return;
        try {
            await this.pc.addIceCandidate({ candidate: candidate[0], sdpMid: candidate[1] });
        } catch {
            // A candidate this browser cannot use is skipped, as any other would be.
        }
    }

    // One connection attempt: `relay` null for the direct one (STUN only), or the TURN servers for the relayed one.
    async attempt(number, relay) {
        this.closePeer();
        this.attemptNo = number;
        this.remoteSet = false;
        this.early = [];
        this.candidates = [];
        this.offerSent = false;
        const pc = new this.env.RTCPeerConnection(relay ? { iceServers: relay, iceTransportPolicy: 'relay' }
            : { iceServers: this.stunUrls.map((urls) => ({ urls })) });
        this.pc = pc;
        const channel = pc.createDataChannel('szf-link', { ordered: true });
        channel.binaryType = 'arraybuffer';
        this.channel = channel;
        pc.onicecandidate = (event) => {
            if (this.pc === pc) this.queueCandidate(event.candidate);
        };
        channel.onopen = () => {
            if (this.channel === channel) this.serial(() => this.channelOpen(number));
        };
        channel.onmessage = (event) => {
            if (this.channel === channel) this.serial(() => this.record(new Uint8Array(event.data)));
        };
        channel.onclose = () => {
            if (this.channel === channel) this.serial(() => this.lost());
        };
        pc.onconnectionstatechange = () => {
            if (this.pc !== pc) return;
            this.env.clearTimeout(this.disconnectedTimer);
            if (pc.connectionState === 'failed') this.serial(() => this.lost());
            if (pc.connectionState !== 'disconnected') return;
            this.disconnectedTimer = this.env.setTimeout(() => {
                if (this.pc === pc) this.serial(() => this.lost());
            }, this.timing.disconnectedMs);
        };
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        await this.signal({ t: 'offer', a: number, relay: Boolean(relay), sdp: pc.localDescription.sdp });
        this.offerSent = true;
        this.flushCandidates();
        this.attemptTimer = this.env.setTimeout(() => this.serial(() => this.attemptTimedOut(number)),
            relay ? this.timing.relayMs : this.timing.directMs);
    }

    queueCandidate(candidate) {
        if (candidate === null || candidate === undefined) this.candidates.push(null);
        else if (candidate.candidate) this.candidates.push([candidate.candidate, candidate.sdpMid ?? '0']);
        if (!this.candidateTimer) {
            this.candidateTimer = this.env.setTimeout(() => this.flushCandidates(), this.timing.candidateBatchMs);
        }
    }

    flushCandidates() {
        this.env.clearTimeout(this.candidateTimer);
        this.candidateTimer = null;
        if (!this.offerSent || this.candidates.length === 0) return;
        const a = this.attemptNo;
        let batch = [];
        let size = 0;
        for (const candidate of this.candidates.splice(0)) {
            if (candidate === null) {
                if (batch.length > 0) this.signal({ t: 'cand', a, c: batch });
                batch = [];
                this.signal({ t: 'cand', a, end: true });
                continue;
            }
            const cost = candidate[0].length + candidate[1].length + 8;
            if (size + cost > SETUP_JSON_MAX && batch.length > 0) {
                this.signal({ t: 'cand', a, c: batch });
                batch = [];
                size = 0;
            }
            batch.push(candidate);
            size += cost;
        }
        if (batch.length > 0) this.signal({ t: 'cand', a, c: batch });
    }

    async attemptTimedOut(number) {
        if (number !== this.attemptNo || this.channelReady || this.phase !== 'proved') return undefined;
        if (this.ws?.readyState !== 1) return this.fail('lost');
        if (number > 1) return this.fail('nopath');
        const relay = await this.requestRelay();
        if (this.phase !== 'proved' || this.channelReady) return undefined;
        return relay ? this.attempt(2, relay) : this.fail('nopath');
    }

    // TURN credentials for this sid, as RTCIceServer entries, or null when the host gives none.
    requestRelay() {
        return new Promise((resolve) => {
            const timer = this.env.setTimeout(() => resolve(null), this.timing.relayAnswerMs);
            this.relayAnswer = (msg) => {
                this.env.clearTimeout(timer);
                this.relayAnswer = null;
                const uris = msg.type === 'relay_credentials_result' && Array.isArray(msg.ice_servers)
                    ? msg.ice_servers.filter((uri) => typeof uri === 'string' && /^turns?:/.test(uri)) : [];
                resolve(uris.length === 0 ? null
                    : uris.map((urls) => ({ urls, username: msg.username, credential: msg.credential })));
            };
            this.send('relay_credentials', { req: 2, sid: this.sid });
        });
    }

    // The data channel is open: the host is no longer needed, so the setup ends and the guest connection with it.
    async channelOpen(number) {
        if (number !== this.attemptNo || this.phase !== 'proved') return;
        this.env.clearTimeout(this.attemptTimer);
        this.channelReady = true;
        this.content = await contentKey(this.env, this.link, this.nonce, this.senderNonce, number);
        this.controlIndex = 0;
        this.send('sig_close', { sid: this.sid });
        this.closeSignalling();
    }

    async record(bytes) {
        if (this.phase === 'failed' || this.phase === 'done' || !this.content) return undefined;
        if (bytes[0] === RECORD.end) {
            const rec = await openRecord(this.env, this.content, [RECORD.end], 0, bytes);
            let reason = null;
            try {
                reason = rec && JSON.parse(new TextDecoder().decode(rec.plain)).reason;
            } catch {
                reason = null;
            }
            return rec ? this.end(reason) : this.fail('corrupt');
        }
        if (this.phase === 'proved') {
            const rec = await openRecord(this.env, this.content, [RECORD.meta], 0, bytes);
            const meta = rec && parseMeta(rec.plain);
            if (!meta) return this.fail('corrupt');
            if (this.resuming) return this.carryOn(meta);
            this.meta = meta;
            this.phase = 'ready';
            return this.emit('ready', { meta });
        }
        if (this.phase !== 'downloading') return this.fail('corrupt');
        return this.chunk(bytes);
    }

    async chunk(bytes) {
        const rec = await openRecord(this.env, this.content, [RECORD.chunk, RECORD.last], this.nextIndex, bytes);
        if (!rec) return this.fail('corrupt');
        const last = rec.type === RECORD.last;
        const { size } = this.meta;
        this.received += rec.plain.length;
        if (rec.plain.length > CHUNK_BYTES || (!last && (rec.plain.length !== CHUNK_BYTES || this.received >= size))
            || (last && this.received !== size)) return this.fail('corrupt');
        this.hash.update(rec.plain);
        this.nextIndex += 1;
        this.stalls = 0;
        this.watchStall();
        if (last) return this.finish(rec.plain);
        await this.sink.write(rec.plain);
        if (this.nextIndex % CREDIT_STEP === 0) {
            await this.control({ t: 'credit', upto: this.nextIndex + CREDIT_WINDOW });
        }
        return this.emit('progress', { received: this.received, size });
    }

    async finish(lastChunk) {
        this.env.clearTimeout(this.stallTimer);
        if (!bytesEqual(this.hash.digest(), this.meta.sha256)) return this.fail('corrupt');
        await this.sink.write(lastChunk);
        await this.sink.close();
        this.phase = 'done';
        await this.control({ t: 'done', ok: true });
        this.emit('done', { received: this.received, size: this.meta.size });
        const { pc } = this;
        this.env.setTimeout(() => pc?.close(), 1000);
        return undefined;
    }

    async control(message) {
        const { channel } = this;
        const index = this.controlIndex;
        this.controlIndex += 1;
        const sealed = await sealRecord(this.env, this.content, RECORD.control, index, utf8(JSON.stringify(message)));
        if (channel?.readyState === 'open') channel.send(sealed);
    }

    // Download: chunks go to `sink` ({write, close, abort}); the sender may run CREDIT_WINDOW chunks ahead.
    async download(sink) {
        if (this.phase !== 'ready') return;
        this.sink = sink;
        this.hash = new Sha256();
        this.nextIndex = 0;
        this.received = 0;
        this.stalls = 0;
        this.phase = 'downloading';
        this.watchStall();
        this.emit('progress', { received: 0, size: this.meta.size });
        await this.control({ t: 'start', upto: CREDIT_WINDOW });
    }

    // Nothing arriving for stallMs while downloading counts as a dropped connection: not every stack reports one.
    watchStall() {
        this.env.clearTimeout(this.stallTimer);
        const { pc } = this;
        this.stallTimer = this.env.setTimeout(() => {
            if (this.pc === pc && this.phase === 'downloading') this.serial(() => this.lost());
        }, this.timing.stallMs);
    }

    // The connection carrying the download dropped: connect again and carry on from the first chunk not yet written.
    lost() {
        if ((this.phase !== 'downloading' && !this.resuming) || this.stalls >= this.timing.resumes) {
            return this.fail('lost');
        }
        this.stalls += 1;
        this.resuming = true;
        this.closePeer();
        this.channelReady = false;
        this.content = null;
        this.failures = 0;
        this.phase = 'idle';
        this.connect();
        return undefined;
    }

    // The metadata on the new connection must describe the same file; then the chunks continue where they stopped.
    async carryOn(meta) {
        const same = meta.size === this.meta.size && bytesEqual(meta.sha256, this.meta.sha256);
        if (!same) return this.fail('corrupt');
        this.resuming = false;
        this.phase = 'downloading';
        this.watchStall();
        this.emit('progress', { received: this.received, size: this.meta.size });
        return this.control({ t: 'start', from: this.nextIndex, upto: this.nextIndex + CREDIT_WINDOW });
    }

    sidClosed(reason) {
        if (this.channelReady || this.phase === 'failed' || this.phase === 'done') return undefined;
        const unanswered = this.phase === 'hello';
        this.closeSignalling();
        if (!unanswered) return this.fail('lost');
        // Nobody answered. A link someone holds waits up to 30 minutes for its sender, so an open that ends sooner,
        // or one the sender received and never answered, is for a link that no longer works.
        const waitedForSender = !this.ownerOnline && this.env.now() - this.openedAt >= this.timing.heldWithinMs;
        if (reason === 'expired' && !waitedForSender) return this.fail('gone');
        return this.later();
    }

    hostClosed() {
        if (this.channelReady || this.phase === 'failed' || this.phase === 'done') return undefined;
        if (this.phase === 'proved') return undefined; // the attempt's timer decides
        if (this.phase !== 'hello') this.failures += 1;
        if (this.failures > this.timing.retries) return this.fail('unreachable');
        return this.later();
    }

    later() {
        this.closeSignalling();
        this.phase = 'connecting';
        const wait = this.timing.retryMs * 2 ** Math.max(0, this.failures - 1);
        this.retryTimer = this.env.setTimeout(() => this.connect(), wait);
    }

    end(reason) {
        return this.fail(END_REASONS.has(reason) ? reason : 'unavailable');
    }

    fail(reason) {
        if (this.phase === 'failed' || this.phase === 'done') return;
        const downloading = this.phase === 'downloading' || this.resuming;
        this.phase = 'failed';
        this.resuming = false;
        if (downloading && reason === 'cancelled') this.control({ t: 'cancel' }).catch(() => {});
        if (downloading) Promise.resolve(this.sink?.abort()).catch(() => {});
        this.shutdown();
        this.emit('failed', { reason });
    }

    cancel() {
        this.fail('cancelled');
    }

    closeSignalling() {
        const { ws } = this;
        this.ws = null;
        this.env.clearTimeout(this.retryTimer);
        if (ws && ws.readyState <= 1) ws.close();
    }

    closePeer() {
        this.env.clearTimeout(this.attemptTimer);
        this.env.clearTimeout(this.disconnectedTimer);
        this.env.clearTimeout(this.stallTimer);
        this.env.clearTimeout(this.candidateTimer);
        this.candidateTimer = null;
        const { pc } = this;
        this.pc = null;
        this.channel = null;
        try {
            pc?.close();
        } catch {
            // already closed
        }
    }

    shutdown() {
        this.closeSignalling();
        const { pc } = this;
        this.channel = null;
        this.env.clearTimeout(this.attemptTimer);
        this.env.clearTimeout(this.disconnectedTimer);
        this.env.clearTimeout(this.stallTimer);
        // Leave a moment for a last control record (cancel) to go out before the connection closes.
        this.env.setTimeout(() => {
            try {
                pc?.close();
            } catch {
                // already closed
            }
        }, 200);
        this.pc = null;
    }
}
