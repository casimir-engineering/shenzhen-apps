// A minimal TURN client over UDP (RFC 8656 with long-term credentials, RFC 8489 messages) for the relay test against
// a locally built coturn: Allocate, Refresh, CreatePermission, ChannelBind, ChannelData and Data indications from
// peers. Enough to check what coturn does with the credentials and limits the host gives it; not a client for the
// app, which uses its own.

import crypto from 'node:crypto';
import dgram from 'node:dgram';
import zlib from 'node:zlib';

const COOKIE = 0x2112a442;
export const METHOD = { allocate: 0x003, refresh: 0x004, permission: 0x008, channelBind: 0x009, binding: 0x001,
    data: 0x007 };
const ATTR = { username: 0x0006, integrity: 0x0008, error: 0x0009, channel: 0x000c, lifetime: 0x000d,
    peer: 0x0012, data: 0x0013, relayed: 0x0016, realm: 0x0014, nonce: 0x0015, transport: 0x0019, mapped: 0x0020,
    fingerprint: 0x8028 };

function attr(type, value) {
    const head = Buffer.alloc(4);
    head.writeUInt16BE(type, 0);
    head.writeUInt16BE(value.length, 2);
    return Buffer.concat([head, value, Buffer.alloc((4 - (value.length % 4)) % 4)]);
}

function xorAddress(address, port) {
    const value = Buffer.alloc(8);
    value.writeUInt16BE(1, 0);
    value.writeUInt16BE(port ^ (COOKIE >>> 16), 2);
    const n = address.split('.').reduce((acc, octet) => ((acc << 8) | Number(octet)) >>> 0, 0);
    value.writeUInt32BE((n ^ COOKIE) >>> 0, 4);
    return value;
}

function readXorAddress(value) {
    const port = value.readUInt16BE(2) ^ (COOKIE >>> 16);
    const n = (value.readUInt32BE(4) ^ COOKIE) >>> 0;
    return { address: [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join('.'), port };
}

export function parse(msg) {
    if (msg.length < 20 || msg.readUInt32BE(4) !== COOKIE) return null;
    const type = msg.readUInt16BE(0);
    const out = { type, method: (type & 0x000f) | ((type & 0x00e0) >> 1) | ((type & 0x3e00) >> 2),
        cls: ((type & 0x0100) >> 7) | ((type & 0x0010) >> 4), tid: msg.subarray(8, 20).toString('hex'), attrs: {} };
    let at = 20;
    while (at + 4 <= msg.length) {
        const t = msg.readUInt16BE(at);
        const l = msg.readUInt16BE(at + 2);
        out.attrs[t] = msg.subarray(at + 4, at + 4 + l);
        at += 4 + l + ((4 - (l % 4)) % 4);
    }
    const error = out.attrs[ATTR.error];
    if (error) out.error = error[2] * 100 + error[3];
    if (out.attrs[ATTR.lifetime]?.length === 4) out.lifetime = out.attrs[ATTR.lifetime].readUInt32BE(0);
    return out;
}

function build(method, cls, attrs, key) {
    const type = (method & 0x000f) | ((method & 0x0070) << 1) | ((method & 0x0f80) << 2)
        | ((cls & 1) << 4) | ((cls & 2) << 7);
    const tid = crypto.randomBytes(12);
    let body = Buffer.concat(attrs);
    const header = Buffer.alloc(20);
    header.writeUInt16BE(type, 0);
    header.writeUInt32BE(COOKIE, 4);
    tid.copy(header, 8);
    if (key) {
        header.writeUInt16BE(body.length + 24, 2);
        const mac = crypto.createHmac('sha1', key).update(Buffer.concat([header, body])).digest();
        body = Buffer.concat([body, attr(ATTR.integrity, mac)]);
    }
    header.writeUInt16BE(body.length + 8, 2);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE((zlib.crc32(Buffer.concat([header, body])) ^ 0x5354554e) >>> 0, 0);
    return { tid: tid.toString('hex'), bytes: Buffer.concat([header, body, attr(ATTR.fingerprint, crc)]) };
}

export class TurnClient {
    constructor({ server, port, username, password }) {
        this.server = server;
        this.port = port;
        this.username = username;
        this.password = password;
        this.pending = new Map();
        this.onChannelData = null;
        this.onData = null; // (peer {address, port}, data): a Data indication, from a peer with a permission
        this.socket = dgram.createSocket('udp4');
        this.socket.on('message', (msg) => this.receive(msg));
    }

    async open() {
        await new Promise((resolve) => this.socket.bind(0, '127.0.0.1', resolve));
        this.socket.setRecvBufferSize(8 * 1024 * 1024);
        this.socket.setSendBufferSize(8 * 1024 * 1024);
    }

    receive(msg) {
        if ((msg[0] & 0xc0) === 0x40) {
            const channel = msg.readUInt16BE(0);
            const length = msg.readUInt16BE(2);
            this.onChannelData?.(channel, msg.subarray(4, 4 + length));
            return;
        }
        const parsed = parse(msg);
        if (parsed?.method === METHOD.data && parsed.cls === 1 && parsed.attrs[ATTR.peer]) {
            this.onData?.(readXorAddress(parsed.attrs[ATTR.peer]), parsed.attrs[ATTR.data] ?? Buffer.alloc(0));
            return;
        }
        const waiter = parsed && this.pending.get(parsed.tid);
        if (waiter) {
            this.pending.delete(parsed.tid);
            waiter(parsed);
        }
    }

    transact(method, attrs, { auth = true, timeoutMs = 2000 } = {}) {
        const authAttrs = auth && this.nonce ? [attr(ATTR.username, Buffer.from(this.username)),
            attr(ATTR.realm, this.realm), attr(ATTR.nonce, this.nonce)] : [];
        const { tid, bytes } = build(method, 0, [...attrs, ...authAttrs], auth && this.nonce ? this.key() : null);
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(tid);
                reject(new Error(`no answer to method ${method}`));
            }, timeoutMs);
            this.pending.set(tid, (reply) => {
                clearTimeout(timer);
                resolve(reply);
            });
            this.socket.send(bytes, this.port, this.server);
        });
    }

    key() {
        return crypto.createHash('md5').update(`${this.username}:${this.realm.toString()}:${this.password}`).digest();
    }

    // Sends with credentials, learning or refreshing the realm and nonce on 401 and 438 as RFC 8656 says.
    async request(method, attrs) {
        let reply = await this.transact(method, attrs);
        for (let tries = 0; tries < 2 && (reply.error === 401 || reply.error === 438); tries++) {
            if (reply.error === 401 && this.nonce && tries > 0) break;
            this.realm = reply.attrs[ATTR.realm] ?? this.realm;
            this.nonce = reply.attrs[ATTR.nonce] ?? this.nonce;
            reply = await this.transact(method, attrs);
        }
        return reply;
    }

    async allocate(lifetime = 600) {
        const lt = Buffer.alloc(4);
        lt.writeUInt32BE(lifetime);
        const reply = await this.request(METHOD.allocate, [attr(ATTR.transport, Buffer.from([17, 0, 0, 0])),
            attr(ATTR.lifetime, lt)]);
        if (reply.cls === 2) this.relayed = readXorAddress(reply.attrs[ATTR.relayed]);
        return reply;
    }

    refresh(lifetime) {
        const lt = Buffer.alloc(4);
        lt.writeUInt32BE(lifetime);
        return this.request(METHOD.refresh, [attr(ATTR.lifetime, lt)]);
    }

    // One Refresh with the nonce already held, never learning a new one: a stale nonce shows as coturn reports it.
    refreshOnce(lifetime) {
        const lt = Buffer.alloc(4);
        lt.writeUInt32BE(lifetime);
        return this.transact(METHOD.refresh, [attr(ATTR.lifetime, lt)]);
    }

    permission(address, port) {
        return this.request(METHOD.permission, [attr(ATTR.peer, xorAddress(address, port))]);
    }

    bindChannel(channel, address, port) {
        const number = Buffer.alloc(4);
        number.writeUInt16BE(channel, 0);
        return this.request(METHOD.channelBind, [attr(ATTR.channel, number), attr(ATTR.peer, xorAddress(address,
            port))]);
    }

    sendChannel(channel, data) {
        const head = Buffer.alloc(4);
        head.writeUInt16BE(channel, 0);
        head.writeUInt16BE(data.length, 2);
        this.socket.send(Buffer.concat([head, data]), this.port, this.server);
    }

    close() {
        return new Promise((resolve) => this.socket.close(resolve));
    }
}

export async function stunBinding(server, port) {
    const socket = dgram.createSocket('udp4');
    await new Promise((resolve) => socket.bind(0, '127.0.0.1', resolve));
    const { tid, bytes } = build(METHOD.binding, 0, [], null);
    const reply = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('no STUN answer')), 1500);
        socket.on('message', (msg) => {
            const parsed = parse(msg);
            if (parsed?.tid === tid) {
                clearTimeout(timer);
                resolve(parsed);
            }
        });
        socket.send(bytes, port, server);
    }).finally(() => socket.close());
    const mapped = reply.attrs[ATTR.mapped];
    return mapped ? readXorAddress(mapped) : null;
}
