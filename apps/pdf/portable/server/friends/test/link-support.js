// Test support for the link pages: the page script loaded into Node (the same parts the host joins into
// /links/links.js), an in-memory RTCPeerConnection pair, node-datachannel when the suite names one, and a receiver
// started against a host. Nothing here leaves 127.0.0.1.

import { createRequire } from 'node:module';
import path from 'node:path';

import { linkScriptSource } from '../src/link-pages.js';

const SCRIPT_NAMES = ['parseLinkPayload', 'appLinkUrl', 'b64uEncode', 'b64uDecode', 'Sha256', 'sha256LengthBytes',
    'recordNonce', 'linkKeys', 'sealSetup', 'openSetup', 'proofMac', 'sealRecord', 'openRecord', 'contentKey',
    'sessionKey', 'parseMeta', 'LinkReceiver', 'RECORD', 'CHUNK_BYTES', 'LINK_FROM', 'CREDIT_WINDOW', 'browserTraits',
    'chooseSaver', 'saveName', 'memorySink', 'streamSink', 'openSink', 'friendView', 'downloadView', 'formatBytes',
    'renderView', 'writeU64', 'plainName'];

// The page script's functions, evaluated in this process as a browser would evaluate /links/links.js.
export function loadLinkScript() {
    // eslint-disable-next-line no-new-func
    return new Function(`'use strict';\n${linkScriptSource()}\nreturn { ${SCRIPT_NAMES.join(', ')} };`)();
}

// node-datachannel's RTCPeerConnection and cleanup, when FRIENDS_TEST_DATACHANNEL names the package's directory
// (README.md § Testing); null otherwise, and the suites that need it skip.
export function datachannelPolyfill() {
    const dir = process.env.FRIENDS_TEST_DATACHANNEL;
    if (!dir) return null;
    const require = createRequire(path.join(path.resolve(dir), 'package.json'));
    // cleanup() stops libdatachannel's threads, without which the test process never exits.
    return { RTCPeerConnection: require('./dist/cjs/polyfill/index.cjs').RTCPeerConnection,
        cleanup: require('./dist/cjs/lib/index.cjs').cleanup };
}

// An in-memory stand-in for RTCPeerConnection: a pair connects when the offerer applies the answer, and only both
// relayed when `direct` is false. Every message is at most 64 KiB, as browsers require; `stats` records the largest.
// `relaySessionMs` ends every relayed pair that long after it connects, as the host's relay session limit does:
// nothing more passes, and with `relayEnd: 'state'` both ends then report "disconnected" as browsers do, while with
// 'silent' they say nothing, as libdatachannel may not for a long while.
export function fakeRtc({ direct = true, relaySessionMs = 0, relayEnd = 'state' } = {}) {
    const registry = new Map();
    const stats = { maxMessage: 0, made: 0, configs: [], relayed: 0 };
    let nextId = 1;
    const later = (fn) => setImmediate(fn);

    class FakeChannel {
        constructor(label) {
            this.label = label;
            this.readyState = 'connecting';
            this.binaryType = 'arraybuffer';
            this.peer = null;
        }

        send(data) {
            if (this.readyState !== 'open') throw new Error('channel not open');
            if (this.pc?.cut) return;
            const bytes = typeof data === 'string' ? Buffer.from(data) : new Uint8Array(data);
            if (bytes.length > 65536) throw new Error(`message of ${bytes.length} bytes`);
            stats.maxMessage = Math.max(stats.maxMessage, bytes.length);
            const copy = bytes.slice().buffer;
            const { peer } = this;
            later(() => {
                if (peer.readyState === 'open') peer.onmessage?.({ data: copy });
            });
        }

        close() {
            if (this.readyState === 'closed') return;
            this.readyState = 'closed';
            later(() => this.onclose?.());
            if (this.peer) this.peer.close();
        }
    }

    class FakePeerConnection {
        constructor(config = {}) {
            this.id = nextId;
            nextId += 1;
            registry.set(this.id, this);
            stats.made += 1;
            stats.configs.push(config);
            this.relay = config.iceTransportPolicy === 'relay';
            this.channels = [];
        }

        createDataChannel(label) {
            const channel = new FakeChannel(label);
            channel.pc = this;
            this.channels.push(channel);
            return channel;
        }

        sdp(type) {
            return `fake-${type} ${this.id} ${this.relay ? 'relay' : 'all'}`;
        }

        async createOffer() {
            return { type: 'offer', sdp: this.sdp('offer') };
        }

        async createAnswer() {
            return { type: 'answer', sdp: this.sdp('answer') };
        }

        async setLocalDescription(description) {
            this.localDescription = description;
            later(() => {
                this.onicecandidate?.({ candidate: { candidate: `candidate:1 1 udp 1 192.0.2.${this.id} 9 typ host`,
                    sdpMid: '0' } });
                this.onicecandidate?.({ candidate: null });
            });
        }

        async setRemoteDescription(description) {
            const match = /^fake-(offer|answer) (\d+) (relay|all)$/.exec(description.sdp);
            if (!match) throw new Error('not a fake description');
            this.remote = registry.get(Number(match[2]));
            if (match[1] === 'answer') later(() => this.connect());
        }

        async addIceCandidate() {}

        connect() {
            const answerer = this.remote;
            if (!answerer || this.closed || answerer.closed || (!direct && !(this.relay && answerer.relay))) return;
            stats.relayed += this.relay && answerer.relay ? 1 : 0;
            if (relaySessionMs && this.relay && answerer.relay) {
                setTimeout(() => {
                    for (const pc of [this, answerer]) {
                        pc.cut = true;
                        pc.connectionState = 'disconnected';
                        if (relayEnd === 'state') pc.onconnectionstatechange?.();
                    }
                }, relaySessionMs);
            }
            for (const mine of this.channels) {
                const theirs = new FakeChannel(mine.label);
                theirs.pc = answerer;
                mine.peer = theirs;
                theirs.peer = mine;
                answerer.channels.push(theirs);
                mine.readyState = 'open';
                theirs.readyState = 'open';
                answerer.ondatachannel?.({ channel: theirs });
                theirs.onopen?.();
                mine.onopen?.();
            }
        }

        close() {
            this.closed = true;
            for (const channel of this.channels) channel.close();
        }
    }
    return { RTCPeerConnection: FakePeerConnection, stats };
}

// A receiver as the download page starts it, recording every state it reports.
export function startReceiver(api, { url, fragment, RTCPeerConnection, clock, timing = {}, stunUrls = [] }) {
    const states = [];
    const link = api.parseLinkPayload('d', fragment);
    if (!link) throw new Error('the sender made a link the page does not parse');
    const env = { WebSocket: globalThis.WebSocket, RTCPeerConnection, crypto: globalThis.crypto, setTimeout,
        clearTimeout, now: () => (clock ? clock.now() : Date.now()) };
    const receiver = new api.LinkReceiver(env, { wsUrl: `${url}?guest=1`, link, stunUrls,
        timing: { retryMs: 100, ...timing }, onState: (state, detail) => states.push({ state, ...detail }) });
    receiver.start();
    const reached = (state, timeoutMs = 10_000) => new Promise((resolve, reject) => {
        const deadline = Date.now() + timeoutMs;
        const check = () => {
            const found = states.find((entry) => entry.state === state);
            if (found) return resolve(found);
            if (Date.now() > deadline) {
                return reject(new Error(`no ${state} in time; states: ${states.map((s) => s.state).join(', ')}`));
            }
            return setTimeout(check, 10);
        };
        check();
    });
    return { receiver, states, reached, link };
}

// A sink that keeps what it is given, as the memory sink does, and says whether it was closed or aborted.
export function collectingSink({ writeDelayMs = 0 } = {}) {
    const sink = { chunks: [], closed: false, aborted: false };
    sink.write = async (bytes) => {
        if (writeDelayMs) await new Promise((resolve) => setTimeout(resolve, writeDelayMs));
        sink.chunks.push(Buffer.from(bytes));
    };
    sink.close = async () => {
        sink.closed = true;
    };
    sink.abort = async () => {
        sink.aborted = true;
    };
    sink.bytes = () => Buffer.concat(sink.chunks);
    return sink;
}
