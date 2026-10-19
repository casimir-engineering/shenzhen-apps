// coturn's per-allocation events, received by the host itself (ADR 0010 § Statistics). coturn's `redis-statsdb`
// option publishes, for every allocation, its start ("new"), refreshes, end ("deleted") and byte counts every 4,096
// packets and at the end. It speaks the Redis protocol (RESP) and only writes: AUTH, SELECT, SET, PUBLISH, DEL.
// Rather than run a Redis container to pass those on, the host answers them itself on a port published only on the
// server's loopback, behind a password, and keeps only what statistics need.
//
// Inside Docker the port is also reachable from every container on the shared network, so the sink accepts a
// connection only from the addresses coturn's connections arrive from (FRIENDS_TURN_EVENTS_FROM: in the container,
// the network's gateway, which Docker's published port connects from) and drops one that has not signed in within
// 5 seconds, so nothing else can hold its few connection places.
//
// What coturn sends that the host must not keep: the "new" and "refreshed" status lines name the client's address
// (`remote=`). The parser reads the status word and nothing after it, and no line is ever logged or stored.

import net from 'node:net';

import { addressIn } from './address.js';
import { safeEqual } from './keys.js';

const MAX_BUFFER = 64 * 1024;
// coturn opens one connection per relay thread; a few more cover a restart.
const MAX_CONNECTIONS = 32;
const AUTH_TIMEOUT_MS = 5000;
const CHANNEL = new RegExp('^turn/(?:realm/[^/]{0,128}/)?user/([^/]{1,128})/allocation/(\\d{1,20})/'
    + '(status|traffic|traffic/peer|total_traffic|total_traffic/peer)$');
const STATUS = /^(new|refreshed|deleted)\b/;
const COUNTERS = /^rcvp=(\d+), rcvb=(\d+), sentp=(\d+), sentb=(\d+)$/;

// One RESP array of bulk strings from `buffer` at `offset`: { args, next } or null when incomplete. Throws on
// anything that is not what hiredis sends.
export function parseCommand(buffer, offset = 0) {
    const lineEnd = (from) => {
        const at = buffer.indexOf('\r\n', from, 'latin1');
        return at < 0 ? null : at;
    };
    let end = lineEnd(offset);
    if (end === null) return null;
    if (buffer[offset] !== 0x2a) throw new Error('not an array');
    const count = Number(buffer.toString('latin1', offset + 1, end));
    if (!Number.isSafeInteger(count) || count < 1 || count > 16) throw new Error('bad array length');
    let at = end + 2;
    const args = [];
    for (let i = 0; i < count; i++) {
        end = lineEnd(at);
        if (end === null) return null;
        if (buffer[at] !== 0x24) throw new Error('not a bulk string');
        const length = Number(buffer.toString('latin1', at + 1, end));
        if (!Number.isSafeInteger(length) || length < 0 || length > 8192) throw new Error('bad bulk length');
        const start = end + 2;
        if (buffer.length < start + length + 2) return null;
        args.push(buffer.toString('utf8', start, start + length));
        at = start + length + 2;
    }
    return { args, next: at };
}

// One published event, reduced to what statistics use, or null.
export function parseEvent(channel, value) {
    const match = CHANNEL.exec(channel);
    if (!match) return null;
    const [, username, allocation, kind] = match;
    if (kind === 'status') {
        const status = STATUS.exec(value);
        return status ? { type: 'status', username, allocation, status: status[1] } : null;
    }
    const counters = COUNTERS.exec(value);
    if (!counters) return null;
    return { type: 'traffic', username, allocation, kind, rcvp: Number(counters[1]), rcvb: Number(counters[2]),
        sentp: Number(counters[3]), sentb: Number(counters[4]) };
}

export class RelayEventSink {
    // `allowFrom` is a BlockList of the addresses coturn connects from; null allows loopback only.
    constructor({ password, stats, host = '127.0.0.1', port = 0, onEvent = null, allowFrom = null,
        authTimeoutMs = AUTH_TIMEOUT_MS }) {
        this.password = password;
        this.allowFrom = allowFrom ?? loopbackOnly();
        this.authTimeoutMs = authTimeoutMs;
        this.stats = stats;
        this.host = host;
        this.port = port;
        this.onEvent = onEvent;
        this.connections = new Set();
        this.authed = new Set();
        this.counts = { events: 0, refused: 0, foreign: 0, unsigned: 0 };
    }

    // Whether coturn is connected and signed in now: the dashboard's "receiving" line.
    get receiving() {
        return this.authed.size > 0;
    }

    async start() {
        this.server = net.createServer((socket) => this.accept(socket));
        await new Promise((resolve, reject) => {
            this.server.once('error', reject);
            this.server.listen(this.port, this.host, resolve);
        });
        this.port = this.server.address().port;
        return this.port;
    }

    accept(socket) {
        if (!addressIn(this.allowFrom, socket.remoteAddress)) {
            this.counts.foreign += 1;
            socket.destroy();
            return;
        }
        if (this.connections.size >= MAX_CONNECTIONS) {
            socket.destroy();
            return;
        }
        const state = { buffer: Buffer.alloc(0), authed: false, socket };
        this.connections.add(socket);
        const deadline = setTimeout(() => {
            if (state.authed) return;
            this.counts.unsigned += 1;
            socket.destroy();
        }, this.authTimeoutMs);
        deadline.unref?.();
        socket.on('close', () => {
            clearTimeout(deadline);
            this.connections.delete(socket);
            this.authed.delete(socket);
        });
        socket.on('error', () => socket.destroy());
        socket.on('data', (chunk) => {
            state.buffer = Buffer.concat([state.buffer, chunk]);
            if (state.buffer.length > MAX_BUFFER) {
                socket.destroy();
                return;
            }
            try {
                let parsed = parseCommand(state.buffer);
                while (parsed) {
                    socket.write(this.command(state, parsed.args));
                    state.buffer = state.buffer.subarray(parsed.next);
                    parsed = state.buffer.length > 0 ? parseCommand(state.buffer) : null;
                }
            } catch {
                socket.destroy();
            }
        });
    }

    command(state, args) {
        const name = args[0].toUpperCase();
        if (name === 'AUTH') {
            state.authed = safeEqual(args[args.length - 1], this.password);
            if (state.authed) this.authed.add(state.socket);
            else this.counts.refused += 1;
            return state.authed ? '+OK\r\n' : '-WRONGPASS invalid password\r\n';
        }
        if (!state.authed) return '-NOAUTH Authentication required.\r\n';
        if (name === 'PUBLISH' && args.length === 3) {
            const event = parseEvent(args[1], args[2]);
            if (event) {
                this.counts.events += 1;
                if (event.type === 'status') this.stats.onStatus(event);
                else this.stats.onTraffic(event);
                this.onEvent?.(event);
            }
            return ':0\r\n';
        }
        if (name === 'DEL') return ':0\r\n';
        return '+OK\r\n'; // SELECT, SET
    }

    async stop() {
        for (const socket of this.connections) socket.destroy();
        if (this.server) await new Promise((resolve) => this.server.close(() => resolve()));
    }
}

function loopbackOnly() {
    const list = new net.BlockList();
    list.addSubnet('127.0.0.0', 8, 'ipv4');
    list.addAddress('::1', 'ipv6');
    return list;
}

// The default route's gateway in Linux's /proc/net/route text (little-endian hex), or null: inside a container on
// one Docker network, the address Docker's published ports connect from.
export function defaultGateway(routeText) {
    for (const line of String(routeText).split('\n').slice(1)) {
        const [, destination, gateway, flags] = line.trim().split(/\s+/);
        if (destination !== '00000000' || !/^[0-9A-Fa-f]{8}$/.test(gateway ?? '')) continue;
        if ((Number.parseInt(flags, 16) & 0x2) === 0) continue; // RTF_GATEWAY
        const n = Number.parseInt(gateway, 16);
        const address = [n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, n >>> 24].join('.');
        if (address !== '0.0.0.0') return address;
    }
    return null;
}

// Prometheus text exposition (coturn's --prometheus): the few series the dashboard cross-checks. Traffic series grow
// only when an allocation ends; turn_total_allocations is live.
export function parsePrometheus(text) {
    const out = { allocations: 0, finishedBytes: { rcvb: 0, sentb: 0, peerRcvb: 0, peerSentb: 0 }, bindings: 0 };
    for (const line of String(text).split('\n')) {
        if (line.startsWith('#') || line.trim() === '') continue;
        const match = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([0-9.eE+-]+)/.exec(line);
        if (!match) continue;
        const value = Number(match[3]);
        switch (match[1]) {
        case 'turn_total_allocations': out.allocations += value; break;
        case 'turn_total_traffic_rcvb': out.finishedBytes.rcvb += value; break;
        case 'turn_total_traffic_sentb': out.finishedBytes.sentb += value; break;
        case 'turn_total_traffic_peer_rcvb': out.finishedBytes.peerRcvb += value; break;
        case 'turn_total_traffic_peer_sentb': out.finishedBytes.peerSentb += value; break;
        case 'stun_binding_request': out.bindings += value; break;
        default: break;
        }
    }
    return out;
}
