// coturn's per-allocation events (as its redis-statsdb client sends them) and the statistics derived from them.

import assert from 'node:assert/strict';
import net from 'node:net';
import { test } from 'node:test';

import { FakeClock } from './helpers.js';
import { RelayEventSink, defaultGateway, parseCommand, parseEvent, parsePrometheus } from '../src/relay-events.js';
import { eventSources } from '../src/relay.js';
import { RelayStats } from '../src/relay-stats.js';

function resp(...args) {
    return `*${args.length}\r\n${args.map((a) => `$${Buffer.byteLength(a)}\r\n${a}\r\n`).join('')}`;
}

const USER = '1760400000:AAAAAAAAAAAAAAAAAAAAAA';
const ALLOC = '001000000000000001';
const STATUS = `turn/realm/friends.test/user/${USER}/allocation/${ALLOC}/status`;
const TRAFFIC = `turn/realm/friends.test/user/${USER}/allocation/${ALLOC}/traffic`;

test('RESP commands parse across arbitrary chunk boundaries', () => {
    const bytes = Buffer.from(resp('PUBLISH', STATUS, 'new lifetime=600, type=UDP, local=a, remote=b'));
    for (let cut = 1; cut < bytes.length; cut += 7) assert.equal(parseCommand(bytes.subarray(0, cut)), null);
    assert.deepEqual(parseCommand(bytes).args[0], 'PUBLISH');
    assert.throws(() => parseCommand(Buffer.from('PING\r\n')));
});

test('events keep the status word and the counters, never the addresses coturn puts beside them', () => {
    const event = parseEvent(STATUS, 'new lifetime=600, type=UDP, local=203.0.113.10:3478, remote=198.51.100.7:5000');
    assert.deepEqual(event, { type: 'status', username: USER, allocation: ALLOC, status: 'new' });
    assert.deepEqual(parseEvent(TRAFFIC, 'rcvp=10, rcvb=12000, sentp=9, sentb=11000'), { type: 'traffic',
        username: USER, allocation: ALLOC, kind: 'traffic', rcvp: 10, rcvb: 12000, sentp: 9, sentb: 11000 });
    assert.equal(parseEvent('turn/other', 'x'), null);
    assert.equal(parseEvent(TRAFFIC, 'garbage'), null);
});

test('the sink answers like Redis, demands the password, and feeds the statistics', async (t) => {
    const clock = new FakeClock();
    const stats = new RelayStats({ clock, timeZone: 'Asia/Hong_Kong', hostId: 'main-hk' });
    stats.noteOpen('helper');
    stats.noteAnswered('helper');
    stats.noteCredential({ attempt: 'AAAAAAAAAAAAAAAAAAAAAA', kind: 'helper', sid: 's1' });
    const sink = new RelayEventSink({ password: 'p'.repeat(32), stats });
    const port = await sink.start();
    t.after(() => sink.stop());
    const socket = net.connect(port, '127.0.0.1');
    t.after(() => socket.destroy());
    const replies = [];
    socket.on('data', (d) => replies.push(d.toString()));
    await new Promise((resolve) => socket.once('connect', resolve));
    socket.write(resp('PUBLISH', STATUS, 'new lifetime=600'));
    assert.equal(sink.receiving, false);
    socket.write(resp('AUTH', 'p'.repeat(32)) + resp('SELECT', '0'));
    socket.write(resp('PUBLISH', STATUS, 'new lifetime=600, type=UDP, local=203.0.113.10:3478, remote=198.51.100.7:5'));
    socket.write(resp('PUBLISH', TRAFFIC, 'rcvp=30000, rcvb=37500000, sentp=100, sentb=12000'));
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(replies.join(''), '-NOAUTH Authentication required.\r\n+OK\r\n+OK\r\n:0\r\n:0\r\n');
    assert.equal(sink.counts.events, 2, 'nothing was taken before AUTH');
    assert.equal(sink.receiving, true, 'the dashboard says the relay is sending its statistics');
    stats.tick();
    const { counters } = stats.snapshot();
    assert.equal(counters.now_sessions, 1);
    assert.equal(counters.relayed_helper, 1);
    assert.equal(counters.bytes_up + counters.bytes_down, 37_512_000);
    assert.equal(counters.capped_sessions, 1, '37.5 MB in a minute is 625,000 bytes a second');
    assert.equal(counters.peak_bps, 5_001_600);
    assert.ok(!JSON.stringify(counters).includes('198.51.100.7'));
    assert.ok(!JSON.stringify([...stats.allocations.values()]).includes('198.51.100'));
});

test('Prometheus series used to cross-check coturn', () => {
    const text = ['# HELP x', 'turn_total_allocations{type="UDP"} 3', 'turn_total_allocations{type="TCP"} 1',
        'turn_total_traffic_rcvb 1000', 'turn_total_traffic_sentb 2000', 'stun_binding_request 7'].join('\n');
    assert.deepEqual(parsePrometheus(text), { allocations: 4, bindings: 7,
        finishedBytes: { rcvb: 1000, sentb: 2000, peerRcvb: 0, peerSentb: 0 } });
});

test('the sink takes connections only from the addresses coturn connects from', async (t) => {
    const stats = new RelayStats({ clock: new FakeClock(), timeZone: 'Asia/Hong_Kong', hostId: 'main-hk' });
    const allowFrom = new net.BlockList();
    allowFrom.addAddress('192.0.2.1', 'ipv4');
    const sink = new RelayEventSink({ password: 'p'.repeat(32), stats, allowFrom });
    const port = await sink.start();
    t.after(() => sink.stop());
    const socket = net.connect(port, '127.0.0.1');
    t.after(() => socket.destroy());
    await new Promise((resolve) => socket.once('close', resolve));
    assert.equal(sink.counts.foreign, 1, 'a neighbour on the network is turned away at once');
    assert.equal(sink.connections.size, 0);
});

test('a connection that has not signed in within its deadline is dropped', async (t) => {
    const stats = new RelayStats({ clock: new FakeClock(), timeZone: 'Asia/Hong_Kong', hostId: 'main-hk' });
    const sink = new RelayEventSink({ password: 'p'.repeat(32), stats, authTimeoutMs: 100 });
    const port = await sink.start();
    t.after(() => sink.stop());
    const idle = net.connect(port, '127.0.0.1');
    const coturn = net.connect(port, '127.0.0.1');
    t.after(() => {
        idle.destroy();
        coturn.destroy();
    });
    await new Promise((resolve) => coturn.once('connect', resolve));
    coturn.write(resp('AUTH', 'p'.repeat(32)));
    await new Promise((resolve) => idle.once('close', resolve));
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.equal(sink.counts.unsigned, 1);
    assert.equal(sink.connections.size, 1, 'coturn, signed in, stays');
    assert.equal(sink.receiving, true);
});

test('in the container, coturn\'s connections come from the network\'s gateway', () => {
    const routes = ['Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT',
        'eth0\t00000000\t010012AC\t0003\t0\t0\t0\t00000000\t0\t0\t0',
        'eth0\t000012AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0'].join('\n');
    assert.equal(defaultGateway(routes), '172.18.0.1');
    assert.equal(defaultGateway(routes.split('\n').slice(0, 1).concat(routes.split('\n')[2]).join('\n')), null);
    const list = eventSources('gateway', () => routes);
    assert.ok(list.check('172.18.0.1', 'ipv4'));
    assert.ok(!list.check('172.18.0.5', 'ipv4'), 'not another container on the network');
    assert.throws(() => eventSources('gateway', () => 'Iface\tDestination\n'), /FRIENDS_TURN_EVENTS_FROM/);
    assert.throws(() => eventSources('gateway', () => {
        throw new Error('no /proc here');
    }), /no default gateway/);
    assert.equal(eventSources(''), null, 'loopback only');
    assert.ok(eventSources('10.0.0.0/8').check('10.1.2.3', 'ipv4'));
});
