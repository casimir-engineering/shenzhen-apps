// The coturn configuration the host generates, and the STUN responder.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import dgram from 'node:dgram';
import { test } from 'node:test';
import zlib from 'node:zlib';

import { onlineConfig } from '../src/config-online.js';
import { coturnConfig, validDeniedRange } from '../src/coturn-config.js';
import { relayConfigText } from '../src/relay.js';
import { MAGIC_COOKIE, StunResponder, bindingResponse, parseMappedAddress } from '../src/stun.js';

const BASE = { realm: 'friends.meerkat.orgabots.com', secret: 'x'.repeat(40), listeningIps: ['203.0.113.10'],
    minPort: 49160, maxPort: 49415 };

test('the relay is capped at 5 Mbit/s per session with no server-wide cap, and reaches only relays', () => {
    const conf = coturnConfig(BASE);
    const lines = conf.trim().split('\n');
    assert.ok(lines.includes('max-bps=625000'));
    assert.ok(lines.includes('use-auth-secret'));
    assert.ok(lines.includes('user-quota=2'));
    assert.ok(lines.includes('no-tcp-relay'));
    assert.ok(lines.includes('no-stdout-log') && lines.includes('log-file=/dev/null'));
    assert.ok(!lines.some((line) => /^(bps-capacity|total-quota|allow-loopback-peers|lt-cred-mech)/.test(line)));
    for (const range of ['10.0.0.0-10.255.255.255', '172.16.0.0-172.31.255.255', '192.168.0.0-192.168.255.255',
        '127.0.0.0-127.255.255.255', '100.64.0.0-100.127.255.255', 'fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
        '::1']) {
        assert.ok(lines.includes(`denied-peer-ip=${range}`), range);
    }
    // Every Friends relay path is relay to relay: the relay's own address is the only peer, and every other
    // address of both families is denied, the IPv6 range starting at ::1, never at ::.
    assert.deepEqual(lines.filter((line) => line.startsWith('allowed-peer-ip=')), ['allowed-peer-ip=203.0.113.10']);
    assert.ok(lines.includes('denied-peer-ip=0.0.0.0-255.255.255.255'));
    assert.ok(lines.includes('denied-peer-ip=::1-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'));
    assert.ok(!lines.includes('denied-peer-ip=203.0.113.10'), 'never both allowed and denied');
    assert.ok(lines.includes('max-allocate-lifetime=600') && lines.includes('stale-nonce=600'));
    assert.ok(lines.includes('no-cli') && !lines.some((line) => /^cli(-|$)/.test(line)), 'no CLI without a limit');
    // NAT64 for local use (RFC 8215) and Teredo, which can carry traffic to IPv4 hosts behind them.
    assert.ok(lines.includes('denied-peer-ip=64:ff9b:1::-64:ff9b:1:ffff:ffff:ffff:ffff:ffff'));
    assert.ok(lines.includes('denied-peer-ip=2001::-2001:0:ffff:ffff:ffff:ffff:ffff:ffff'));
});

test('the server\'s other addresses are denied too, and no denied range starts at ::', () => {
    const turn = { realm: 'friends.test', secret: 'x'.repeat(40), listeningIps: ['203.0.113.10'], minPort: 49160,
        maxPort: 49415, eventsIp: '127.0.0.1', eventsPort: 6390, eventsPassword: 'e'.repeat(32),
        deniedPeers: ['2001:db8:5::10', '2001:db8:5::-2001:db8:5::ffff:ffff:ffff:ffff'] };
    const lines = relayConfigText(turn).trim().split('\n');
    for (const range of turn.deniedPeers) assert.ok(lines.includes(`denied-peer-ip=${range}`), range);
    for (const line of lines.filter((l) => l.startsWith('denied-peer-ip='))) {
        assert.ok(validDeniedRange(line.slice('denied-peer-ip='.length)), line);
    }
    for (const bad of ['::-::ffff', '0::-1::', '0:0:0:0:0:0:0:0-::1', '::', '10.0.0.9-10.0.0.1', '10.0.0.1-::1',
        'example.org', '1.2.3.4-5.6.7.8-9.9.9.9']) {
        assert.ok(!validDeniedRange(bad), bad);
        assert.throws(() => coturnConfig({ ...BASE, extraDenied: [bad] }), /from ::/, bad);
    }
    const env = (extra) => ({ FRIENDS_M2: 'on', FRIENDS_RELAY: 'on', FRIENDS_TURN_SECRET: 'x'.repeat(40),
        FRIENDS_TURN_REALM: 'friends.test', FRIENDS_TURN_LISTEN_IPS: '203.0.113.10',
        FRIENDS_TURN_EVENTS_PASSWORD: 'e'.repeat(32), ...extra });
    assert.deepEqual(onlineConfig(env({ FRIENDS_TURN_DENIED_PEERS: '2001:db8:5::10' }), '/data').turn.deniedPeers,
        ['2001:db8:5::10']);
    assert.throws(() => onlineConfig(env({ FRIENDS_TURN_DENIED_PEERS: '::-2001:db8::1' }), '/data'),
        /FRIENDS_TURN_DENIED_PEERS/);
    assert.equal(onlineConfig(env({ FRIENDS_TURN_EVENTS_FROM: 'gateway' }), '/data').turn.eventsFrom, 'gateway');
    assert.throws(() => onlineConfig(env({ FRIENDS_TURN_EVENTS_FROM: 'the gateway' }), '/data'),
        /FRIENDS_TURN_EVENTS_FROM/);
});

test('the generator refuses what the brief rules out', () => {
    assert.throws(() => coturnConfig({ ...BASE, maxBps: 1_250_000 }), /625000/);
    assert.throws(() => coturnConfig({ ...BASE, secret: 'short' }), /32 characters/);
    assert.throws(() => coturnConfig({ ...BASE, listeningIps: [] }), /listening/);
    assert.throws(() => coturnConfig({ ...BASE, minPort: 49160, maxPort: 49161 }), /16 to 4,096/);
    assert.throws(() => coturnConfig({ ...BASE, extraDenied: ['::-::ffff'] }), /from ::/);
    assert.throws(() => coturnConfig({ ...BASE, statsdb: { ip: '127.0.0.1', port: 6390, password: 'has space' } }),
        /base64url/);
});

test('the STUN responder answers a Binding request with the mapped address and a valid fingerprint', async (t) => {
    const responder = new StunResponder();
    const [port] = await responder.start([{ address: '127.0.0.1', port: 0, type: 'udp4' }]);
    t.after(() => responder.stop());
    const client = dgram.createSocket('udp4');
    t.after(() => client.close());
    await new Promise((resolve) => client.bind(0, '127.0.0.1', resolve));
    const request = Buffer.alloc(20);
    request.writeUInt16BE(0x0001, 0);
    request.writeUInt32BE(MAGIC_COOKIE, 4);
    crypto.randomBytes(12).copy(request, 8);
    const reply = await new Promise((resolve) => {
        client.once('message', resolve);
        client.send(request, port, '127.0.0.1');
    });
    assert.equal(reply.readUInt16BE(0), 0x0101);
    assert.ok(reply.subarray(8, 20).equals(request.subarray(8, 20)));
    assert.deepEqual(parseMappedAddress(reply), { family: 4, address: '127.0.0.1', port: client.address().port });
    const fingerprintAt = reply.length - 8;
    assert.equal(reply.readUInt16BE(fingerprintAt), 0x8028);
    assert.equal(reply.readUInt32BE(fingerprintAt + 4), (zlib.crc32(reply.subarray(0, fingerprintAt)) ^ 0x5354554e)
        >>> 0);

    // Not STUN, a wrong cookie, a response: dropped, never answered.
    const wrong = Buffer.from(request);
    wrong.writeUInt32BE(0xdeadbeef, 4);
    for (const junk of [Buffer.from('hello'), wrong, bindingResponse(request, '127.0.0.1', 1)]) {
        client.send(junk, port, '127.0.0.1');
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(responder.counts.dropped, 3);
});

test('IPv6 mapped addresses round-trip, and each source gets a small budget', async () => {
    const request = Buffer.alloc(20);
    request.writeUInt16BE(0x0001, 0);
    request.writeUInt32BE(MAGIC_COOKIE, 4);
    crypto.randomBytes(12).copy(request, 8);
    const reply = bindingResponse(request, '2001:db8::5', 40000);
    assert.deepEqual(parseMappedAddress(reply), { family: 6, address: '2001:db8:0:0:0:0:0:5', port: 40000 });
    const responder = new StunResponder({ perSourcePerSecond: 3 });
    const sent = [];
    const socket = { send: (msg) => sent.push(msg) };
    for (let i = 0; i < 5; i++) responder.receive(socket, request, { address: '198.51.100.7', port: 5000 });
    assert.equal(sent.length, 3);
});
