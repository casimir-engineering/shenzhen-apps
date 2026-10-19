// The relay's reach and how long a relayed session may last, without coturn: the peers the generated configuration
// allows, the session limit's settings, the limit itself on a fake clock, the CLI conversation against a stand-in
// that reads commands as coturn does, and the running host asking that stand-in to end a session past its bound.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import { test } from 'node:test';

import { onlineConfig } from '../src/config-online.js';
import { coturnConfig, publicAddress, validDeniedRange } from '../src/coturn-config.js';
import { RelaySessionLimit, cancelSessions, coturnCliPassword } from '../src/relay-limit.js';
import { cliAddress, relayConfigText } from '../src/relay.js';
import { FakeClock } from './helpers.js';
import { EVENTS_PASSWORD, TURN_SECRET, nowS, startOnline, waitFor } from './online-helpers.js';

const BASE = { realm: 'friends.test', secret: 'x'.repeat(40), listeningIps: ['203.0.113.10'], minPort: 49160,
    maxPort: 49415 };
const env = (extra) => ({ FRIENDS_M2: 'on', FRIENDS_RELAY: 'on', FRIENDS_TURN_SECRET: 'x'.repeat(40),
    FRIENDS_TURN_REALM: 'friends.test', FRIENDS_TURN_LISTEN_IPS: '203.0.113.10',
    FRIENDS_TURN_EVENTS_PASSWORD: 'e'.repeat(32), ...extra });
const linesOf = (text) => text.trim().split('\n');

test('peers are the relay\'s own addresses, their public mappings and the other relays listed, nothing else', () => {
    const lines = linesOf(coturnConfig({ ...BASE, listeningIps: ['10.0.0.5', '2001:db8:5::10'],
        externalIps: ['198.51.100.20/10.0.0.5'], otherRelays: ['1.1.1.1', '2606:4700::1111'] }));
    assert.deepEqual(lines.filter((line) => line.startsWith('allowed-peer-ip=')).map((line) => line.slice(16)),
        ['10.0.0.5', '2001:db8:5::10', '198.51.100.20', '1.1.1.1', '2606:4700::1111']);
    const denied = lines.filter((line) => line.startsWith('denied-peer-ip=')).map((line) => line.slice(15));
    assert.deepEqual(denied.slice(0, 2), ['0.0.0.0-255.255.255.255', '::1-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff']);
    assert.ok(denied.every(validDeniedRange), 'no range from ::');
    // An admin's other relays must be public, single addresses: a private one would reopen the server's networks.
    for (const bad of ['10.0.0.1', '127.0.0.1', '::1', 'fd00::1', '1.1.1.1-1.1.1.9', '0.0.0.0', '::', 'relay.org']) {
        assert.ok(!publicAddress(bad), bad);
        assert.throws(() => coturnConfig({ ...BASE, otherRelays: [bad] }), /other relays/, bad);
        assert.throws(() => onlineConfig(env({ FRIENDS_TURN_OTHER_RELAYS: bad }), '/data'),
            /FRIENDS_TURN_OTHER_RELAYS/, bad);
    }
    assert.deepEqual(onlineConfig(env({ FRIENDS_TURN_OTHER_RELAYS: '1.1.1.1, 2606:4700::1111' }), '/data')
        .turn.otherRelays, ['1.1.1.1', '2606:4700::1111']);
    assert.throws(() => coturnConfig({ ...BASE, maxAllocateLifetimeS: 86_400 }), /max-allocate-lifetime/);
});

test('a session limit turns on coturn\'s CLI, at the address given, with a password derived from the secret', () => {
    const turn = { ...onlineConfig(env({ FRIENDS_TURN_MAX_SESSION_S: '3600' }), '/data').turn, cliIp: '172.18.0.1' };
    const lines = linesOf(relayConfigText(turn));
    const password = coturnCliPassword('x'.repeat(40));
    assert.ok(password.length >= 43 && password !== 'x'.repeat(40) && password === coturnCliPassword('x'.repeat(40)));
    for (const line of ['cli', 'cli-ip=172.18.0.1', 'cli-port=5766', `cli-password=${password}`]) {
        assert.ok(lines.includes(line), line);
    }
    assert.ok(!lines.includes('no-cli'));
    assert.ok(linesOf(relayConfigText({ ...turn, maxSessionS: 0 })).includes('no-cli'), 'no limit, no CLI');

    const defaults = onlineConfig(env({}), '/data').turn;
    assert.deepEqual([defaults.maxSessionS, defaults.cliIp, defaults.cliPort], [3600, '127.0.0.1', 5766]);
    assert.equal(onlineConfig(env({ FRIENDS_TURN_CLI_IP: 'gateway' }), '/data').turn.cliIp, 'gateway');
    assert.throws(() => onlineConfig(env({ FRIENDS_TURN_CLI_IP: 'the gateway' }), '/data'), /FRIENDS_TURN_CLI_IP/);
    for (const bad of ['-1', 'an hour', '86401', '1.5']) {
        assert.throws(() => onlineConfig(env({ FRIENDS_TURN_MAX_SESSION_S: bad }), '/data'),
            /FRIENDS_TURN_MAX_SESSION_S/, bad);
    }
    const routes = 'Iface\tDestination\tGateway\tFlags\neth0\t00000000\t010012AC\t0003\n';
    assert.equal(cliAddress('gateway', () => routes), '172.18.0.1');
    assert.equal(cliAddress('127.0.0.1'), '127.0.0.1');
    assert.throws(() => cliAddress('gateway', () => 'Iface\tDestination\n'), /FRIENDS_TURN_CLI_IP/);
});

test('an allocation is ended once its bound has passed since its credential was issued, and asked again', async () => {
    const clock = new FakeClock();
    const asked = [];
    let answer = true;
    const limit = new RelaySessionLimit({ clock, maxSessionS: 3600, credentialTtlS: 300,
        cancel: async (ids) => {
            asked.push(ids);
            return answer;
        } });
    const issuedNow = `${nowS(clock) + 300}:AAAAAAAAAAAAAAAAAAAAAA`;
    limit.onStatus({ username: issuedNow, allocation: '001000000000000001', status: 'new' });
    // Issued two hours ago and first heard of in a refresh (this service restarted meanwhile): due at once.
    limit.onStatus({ username: `${nowS(clock) - 7200}:BBBBBBBBBBBBBBBBBBBBBB`, allocation: '002',
        status: 'refreshed' });
    // No readable expiry, or one further off than this host's credentials: the bound counts from now.
    limit.onStatus({ username: 'not-a-rest-username', allocation: '003', status: 'new' });
    limit.onStatus({ username: `${nowS(clock) + 999_999}:C`, allocation: '004', status: 'new' });
    limit.onStatus({ username: issuedNow, allocation: 'not a number', status: 'new' });
    await limit.sweep();
    assert.deepEqual(asked, [['002']]);
    limit.onStatus({ username: '', allocation: '002', status: 'deleted' });

    clock.advance(3599_000);
    await limit.sweep();
    assert.equal(asked.length, 1, 'nothing else is due yet');
    clock.advance(1000);
    await limit.sweep();
    assert.deepEqual(asked[1], ['001000000000000001', '003', '004']);
    answer = false;
    clock.advance(10_000);
    await limit.sweep();
    assert.equal(asked.length, 2, 'not asked again within 30 s');
    clock.advance(20_000);
    await limit.sweep();
    assert.deepEqual(asked[2], ['001000000000000001', '003', '004']);
    assert.deepEqual(limit.counts, { ended: 4, failed: 3 });
    for (const allocation of ['001000000000000001', '003', '004']) {
        limit.onStatus({ username: '', allocation, status: 'deleted' });
    }
    clock.advance(60_000);
    await limit.sweep();
    assert.equal(asked.length, 3, 'nothing left once coturn says they ended');
});

test('an allocation coturn never says has ended is forgotten, and comes back due if it is refreshed', async () => {
    const clock = new FakeClock();
    const asked = [];
    const limit = new RelaySessionLimit({ clock, maxSessionS: 60, credentialTtlS: 300,
        cancel: async (ids) => {
            asked.push(ids);
            return true;
        } });
    const username = `${nowS(clock) + 300}:AAAAAAAAAAAAAAAAAAAAAA`;
    limit.onStatus({ username, allocation: '005', status: 'new' });
    clock.advance(60_000);
    await limit.sweep();
    // coturn restarted meanwhile, so no "deleted" ever comes: asked every 30 s while it might still be alive...
    for (let s = 30; s <= 660; s += 30) {
        clock.advance(30_000);
        await limit.sweep();
    }
    assert.equal(asked.length, 23);
    assert.equal(limit.live.size, 1);
    // ...and forgotten once coturn has said nothing of it, past its bound, for longer than an allocation lives
    // unrefreshed (600 s) and a minute.
    clock.advance(1000);
    await limit.sweep();
    assert.equal(limit.live.size, 0);
    assert.equal(asked.length, 23);
    // Were it alive after all, its next refresh brings it back, due at once, and it is not forgotten while coturn
    // keeps reporting its refreshes.
    limit.onStatus({ username, allocation: '005', status: 'refreshed' });
    await limit.sweep();
    assert.deepEqual(asked.at(-1), ['005']);
    assert.equal(asked.length, 24);
    for (let s = 0; s < 1200; s += 300) {
        clock.advance(300_000);
        limit.onStatus({ username, allocation: '005', status: 'refreshed' });
        await limit.sweep();
    }
    assert.equal(limit.live.size, 1);
    assert.equal(asked.length, 28);
});

// Reads each arrival as one command, as coturn's CLI does, so a client that sent several lines at once would fail.
async function fakeCli(t, { password }) {
    const commands = [];
    const server = net.createServer((socket) => {
        let authed = false;
        socket.write('TURN Server\r\nCoturn-4.18.0\r\n\r\nType \'?\' for help\r\nEnter password: \r\n');
        socket.on('data', (chunk) => {
            const command = chunk.toString('latin1').replace(/[\r\n]+$/, '');
            if (!authed) {
                authed = command === password;
                socket.write(authed ? '> ' : 'Enter password: \r\n');
            } else if (command === 'quit') {
                socket.end('Bye !\r\n');
            } else {
                commands.push(command);
                socket.write('> ');
            }
        });
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise((resolve) => server.close(resolve)));
    return { port: server.address().port, commands };
}

test('the CLI is asked one line at a time, and a refused password or no CLI is a failure', async (t) => {
    const cli = await fakeCli(t, { password: 'p'.repeat(43) });
    const ask = (password, ids, port = cli.port) => cancelSessions({ host: '127.0.0.1', port, password, ids,
        timeoutMs: 2000 });
    assert.equal(await ask('p'.repeat(43), ['001000000000000001', '7', '1; stop']), true);
    assert.deepEqual(cli.commands, ['cs 001000000000000001', 'cs 7'], 'only allocation ids, never anything else');
    assert.equal(await ask('wrong', ['8']), false);
    assert.deepEqual(cli.commands.length, 2);
    const closed = net.createServer();
    await new Promise((resolve) => closed.listen(0, '127.0.0.1', resolve));
    const { port } = closed.address();
    await new Promise((resolve) => closed.close(resolve));
    assert.equal(await ask('p'.repeat(43), ['9'], port), false);
});

function resp(...args) {
    return `*${args.length}\r\n${args.map((a) => `$${Buffer.byteLength(a)}\r\n${a}\r\n`).join('')}`;
}

test('the running host ends a relayed session past its bound through coturn\'s CLI', async (t) => {
    const cli = await fakeCli(t, { password: coturnCliPassword(TURN_SECRET) });
    const { online, clock } = await startOnline(t, { env: { FRIENDS_TURN_MAX_SESSION_S: '60',
        FRIENDS_TURN_CLI_PORT: String(cli.port) } });
    const conf = linesOf(fs.readFileSync(online.settings.turn.confFile, 'utf8'));
    assert.ok(conf.includes('cli-ip=127.0.0.1') && conf.includes(`cli-port=${cli.port}`));
    const socket = net.connect(online.relay.eventsPort, '127.0.0.1');
    t.after(() => socket.destroy());
    await new Promise((resolve) => socket.once('connect', resolve));
    const channel = `turn/realm/friends.test/user/${nowS(clock) + 300}:AAAAAAAAAAAAAAAAAAAAAA/allocation/`
        + '001000000000000009/status';
    socket.write(resp('AUTH', EVENTS_PASSWORD) + resp('PUBLISH', channel, 'new lifetime=600, remote=x'));
    await waitFor(() => online.relay.limit.live.size === 1, { timeoutMs: 3000 });
    assert.deepEqual(cli.commands, [], 'within its bound');
    clock.advance(60_000);
    await waitFor(() => cli.commands.length === 1, { timeoutMs: 3000 });
    assert.deepEqual(cli.commands, ['cs 001000000000000009']);
    socket.write(resp('PUBLISH', channel, 'deleted'));
    await waitFor(() => online.relay.limit.live.size === 0, { timeoutMs: 3000 });
});

test('without a session limit the host runs no CLI and asks nothing', async (t) => {
    const { online } = await startOnline(t);
    assert.equal(online.relay.limit, null);
    assert.ok(linesOf(fs.readFileSync(online.settings.turn.confFile, 'utf8')).includes('no-cli'));
});
