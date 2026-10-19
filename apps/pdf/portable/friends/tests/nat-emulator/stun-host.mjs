// The punching matrix's STUN on the public side (SZFNATMatrix.m): the host service's own responder
// (server/friends/src/stun.js) on 127.0.0.1, so the helpers classify their NATs and learn their mappings exactly as
// they would from the Friends host. Every emulated NAT's public address is 127.0.0.1, so the per-source budget that
// keeps the real responder a poor amplifier is raised here.
//
// Usage: node stun-host.mjs <path to stun.js> <udp port count> <tcp: 0 or 1>
// With tcp 1 it also answers STUN over TCP (RFC 8489 framing) on the first UDP port's number, standing in for
// coturn's TCP listener when no coturn runs, so the TCP path learns its mapped address too.
// Prints {"udp":[ports...],"tcp":port} once listening, and exits when stdin closes.

import net from 'node:net';

const [stunPath, countText, tcpText] = process.argv.slice(2);
const { StunResponder, bindingResponse, isBindingRequest } = await import(stunPath);

const responder = new StunResponder({ perSourcePerSecond: 1_000_000, totalPerSecond: 1_000_000 });
const count = Number(countText);
let udp = [];
let tcp = 0;
for (let attempt = 0; attempt < 20 && tcp === 0; attempt++) {
    udp = await responder.start(Array.from({ length: count }, () => ({ address: '127.0.0.1', port: 0, type: 'udp4' })));
    if (tcpText !== '1') break;
    const server = net.createServer((socket) => {
        let buffer = Buffer.alloc(0);
        socket.on('error', () => socket.destroy());
        socket.on('data', (chunk) => {
            buffer = Buffer.concat([buffer, chunk]);
            while (buffer.length >= 20) {
                const length = 20 + buffer.readUInt16BE(2);
                if (buffer.length < length) break;
                const message = buffer.subarray(0, length);
                buffer = buffer.subarray(length);
                if (!isBindingRequest(message)) continue;
                socket.write(bindingResponse(message, socket.remoteAddress, socket.remotePort));
            }
        });
    });
    tcp = await new Promise((resolve) => {
        server.once('error', () => resolve(0));
        server.listen(udp[0], '127.0.0.1', () => resolve(udp[0]));
    });
    if (tcp === 0) await responder.stop();
}
process.stdout.write(`${JSON.stringify({ udp, tcp })}\n`);
process.stdin.resume();
process.stdin.on('end', () => process.exit(0));
process.stdin.on('close', () => process.exit(0));
