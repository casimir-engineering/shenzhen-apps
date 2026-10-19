// A STUN Binding responder (RFC 8489, the Binding method only) in Node's dgram: the second port helpers use to tell
// how their NAT maps (HOST-PROTOCOL-ONLINE.md § STUN and TURN addresses), and the first port too on a host that runs
// no relay. The same socket asking two ports of one server sees one mapped port behind an endpoint-independent NAT
// and two behind a symmetric one, which decides whether to try port prediction before the relay. coturn cannot answer
// on a second port of a server with one public address (measured, ADR 0010), so this one is ours.
//
// It answers a well-formed Binding request with XOR-MAPPED-ADDRESS and FINGERPRINT and drops everything else
// silently. Answers are at most about twice the request's size, and each source prefix gets a small budget, so the
// responder is a poor amplifier. Addresses are used only to answer and as keyed hashes in the budget.

import dgram from 'node:dgram';
import net from 'node:net';
import zlib from 'node:zlib';

import { addressPrefix, ipv6Groups, prefixKey } from './address.js';
import { CostBudget } from './ratelimit.js';

export const MAGIC_COOKIE = 0x2112a442;
const BINDING_REQUEST = 0x0001;
const BINDING_SUCCESS = 0x0101;
const XOR_MAPPED_ADDRESS = 0x0020;
const FINGERPRINT = 0x8028;
const FINGERPRINT_XOR = 0x5354554e;
const MAX_REQUEST = 548;

export function isBindingRequest(msg) {
    if (msg.length < 20 || msg.length > MAX_REQUEST) return false;
    if ((msg[0] & 0xc0) !== 0) return false;
    if (msg.readUInt16BE(0) !== BINDING_REQUEST) return false;
    if (msg.readUInt32BE(4) !== MAGIC_COOKIE) return false;
    const length = msg.readUInt16BE(2);
    return length % 4 === 0 && length === msg.length - 20;
}

function xorAddress(address, port, transactionId) {
    const plain = address.startsWith('::ffff:') && net.isIPv4(address.slice(7)) ? address.slice(7) : address;
    const xport = port ^ (MAGIC_COOKIE >>> 16);
    if (net.isIPv4(plain)) {
        const value = Buffer.alloc(8);
        value.writeUInt16BE(0x0001, 0);
        value.writeUInt16BE(xport, 2);
        const octets = plain.split('.').map(Number);
        value.writeUInt32BE((((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]) ^ MAGIC_COOKIE)
            >>> 0, 4);
        return value;
    }
    const value = Buffer.alloc(20);
    value.writeUInt16BE(0x0002, 0);
    value.writeUInt16BE(xport, 2);
    const mask = Buffer.alloc(16);
    mask.writeUInt32BE(MAGIC_COOKIE, 0);
    transactionId.copy(mask, 4);
    const raw = Buffer.alloc(16);
    (ipv6Groups(plain.split('%')[0]) ?? Array(8).fill(0)).forEach((group, i) => raw.writeUInt16BE(group, i * 2));
    for (let i = 0; i < 16; i++) value[4 + i] = raw[i] ^ mask[i];
    return value;
}

function attribute(type, value) {
    const header = Buffer.alloc(4);
    header.writeUInt16BE(type, 0);
    header.writeUInt16BE(value.length, 2);
    const padding = Buffer.alloc((4 - (value.length % 4)) % 4);
    return Buffer.concat([header, value, padding]);
}

export function bindingResponse(request, address, port) {
    const transactionId = request.subarray(8, 20);
    const mapped = attribute(XOR_MAPPED_ADDRESS, xorAddress(address, port, transactionId));
    const header = Buffer.alloc(20);
    header.writeUInt16BE(BINDING_SUCCESS, 0);
    header.writeUInt16BE(mapped.length + 8, 2);
    header.writeUInt32BE(MAGIC_COOKIE, 4);
    transactionId.copy(header, 8);
    const body = Buffer.concat([header, mapped]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE((zlib.crc32(body) ^ FINGERPRINT_XOR) >>> 0, 0);
    return Buffer.concat([body, attribute(FINGERPRINT, crc)]);
}

// Reads XOR-MAPPED-ADDRESS from a Binding success response, for the tests and the evidence run.
export function parseMappedAddress(response) {
    if (response.length < 20 || response.readUInt32BE(4) !== MAGIC_COOKIE) return null;
    const transactionId = response.subarray(8, 20);
    let at = 20;
    while (at + 4 <= response.length) {
        const type = response.readUInt16BE(at);
        const length = response.readUInt16BE(at + 2);
        const value = response.subarray(at + 4, at + 4 + length);
        if (type === XOR_MAPPED_ADDRESS) {
            const port = value.readUInt16BE(2) ^ (MAGIC_COOKIE >>> 16);
            if (value[1] === 0x01) {
                const n = (value.readUInt32BE(4) ^ MAGIC_COOKIE) >>> 0;
                return { family: 4, address: [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join('.'), port };
            }
            const mask = Buffer.alloc(16);
            mask.writeUInt32BE(MAGIC_COOKIE, 0);
            transactionId.copy(mask, 4);
            const raw = Buffer.alloc(16);
            for (let i = 0; i < 16; i++) raw[i] = value[4 + i] ^ mask[i];
            const groups = [];
            for (let i = 0; i < 16; i += 2) groups.push(raw.readUInt16BE(i).toString(16));
            return { family: 6, address: groups.join(':'), port };
        }
        at += 4 + length + ((4 - (length % 4)) % 4);
    }
    return null;
}

export class StunResponder {
    constructor({ clock = { now: () => Date.now() }, perSourcePerSecond = 20, totalPerSecond = 20_000 } = {}) {
        this.budget = new CostBudget({ limit: perSourcePerSecond, windowMs: 1000, clock });
        this.total = new CostBudget({ limit: totalPerSecond, windowMs: 1000, clock });
        this.sockets = [];
        this.counts = { answered: 0, dropped: 0 };
    }

    // `bindings`: [{ address, port, type: 'udp4' | 'udp6' }]; resolves with the bound ports.
    async start(bindings) {
        const ports = [];
        for (const { address, port, type } of bindings) {
            const socket = dgram.createSocket({ type, ipv6Only: type === 'udp6' });
            socket.on('message', (msg, rinfo) => this.receive(socket, msg, rinfo));
            socket.on('error', () => {});
            await new Promise((resolve, reject) => {
                socket.once('error', reject);
                socket.bind(port, address, resolve);
            });
            this.sockets.push(socket);
            ports.push(socket.address().port);
        }
        return ports;
    }

    receive(socket, msg, rinfo) {
        if (!isBindingRequest(msg)) {
            this.counts.dropped += 1;
            return;
        }
        const key = prefixKey(addressPrefix(rinfo.address) ?? 'unknown');
        if (!this.total.take('all') || !this.budget.take(key)) {
            this.counts.dropped += 1;
            return;
        }
        this.counts.answered += 1;
        socket.send(bindingResponse(msg, rinfo.address, rinfo.port), rinfo.port, rinfo.address);
    }

    async stop() {
        await Promise.all(this.sockets.map((socket) => new Promise((resolve) => socket.close(resolve))));
        this.sockets = [];
    }
}
