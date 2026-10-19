// The two switches (FRIENDS_M2, FRIENDS_RELAY), what protocol 1 and protocol 2 helpers see with each, the separate
// message budget online Friends has, and the settings refused at start.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { onlineConfig } from '../src/config-online.js';
import { CLOSE } from '../src/protocol.js';
import { TestClient, identity, startMain } from './helpers.js';
import { FakeHelper, guest, nextOf, onlineEnv, startOnline } from './online-helpers.js';

test('with online Friends off, protocol 2 helpers are told so and their online messages are unknown', async (t) => {
    const { url, host } = await startMain(t);
    assert.equal(host.online, null);
    const helper = await FakeHelper.connect(url);
    assert.equal(helper.welcome.type, 'welcome');
    assert.equal(helper.welcome.online, false);
    helper.send('rdv_lookup', { req: 1, keys: [helper.key] });
    assert.equal((await nextOf(helper.client, 'error')).code, 'bad_request');
    assert.equal((await helper.client.closed).code, CLOSE.policy);
    await assert.rejects(guest(url), /HTTP 404/, 'no download links either');
});

test('with online Friends on, protocol 1 welcomes are unchanged and protocol 2 ones say it is on', async (t) => {
    const { url } = await startOnline(t);
    const old = await TestClient.connect(url);
    const welcome = await old.checkin(identity(), { protocol: 1 });
    assert.equal(welcome.type, 'welcome');
    assert.equal(Object.hasOwn(welcome, 'online'), false);
    const helper = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    assert.equal(helper.welcome.online, true);
    old.close();
    helper.close();
});

test('online messages have their own budget, so a burst of them never starves check-in and IDs', async (t) => {
    const { url } = await startOnline(t, { env: { FRIENDS_RATE_MESSAGES_PER_10S: '3' } });
    const helper = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    for (let i = 0; i < 30; i++) helper.send('rdv_lookup', { req: i, keys: [helper.key] });
    for (let i = 0; i < 30; i++) assert.ok((await nextOf(helper.client, 'rdv_records')).records);
    helper.send('reserve', { friends_id: 'calm-heron' });
    assert.equal((await nextOf(helper.client, 'reserve_result')).type, 'reserve_result');
    for (let i = 0; i < 200; i++) helper.send('rdv_lookup', { req: i, keys: [helper.key] });
    assert.equal((await nextOf(helper.client, 'error')).code, 'rate_limited');
    assert.equal((await helper.client.closed).code, CLOSE.tryLater);
});

test('the relay switch: credentials are refused with no_relay while it is off', async (t) => {
    const { url, clock } = await startOnline(t, { online: { relay: false } });
    const alice = await FakeHelper.connect(url, { friendsId: 'calm-heron' });
    const bob = await FakeHelper.connect(url, { friendsId: 'bold-otter' });
    await bob.publish({ nowS: Math.floor(clock.now() / 1000) });
    const opened = await alice.open({ rdv_key: bob.key });
    await nextOf(bob.client, 'sig_incoming');
    bob.message(opened.sid, 'answer');
    await nextOf(alice.client, 'sig_msg');
    assert.equal((await alice.credentials(opened.sid)).reason, 'no_relay');
    alice.close();
    bob.close();
});

test('settings that cannot work stop the host at start, naming the variable', () => {
    const relay = onlineEnv();
    assert.deepEqual(onlineConfig({}, '/data'), { enabled: false, relay: false, stunPorts: [], stunListen: ['0.0.0.0'],
        guestIceServers: [], turn: null });
    assert.throws(() => onlineConfig({ FRIENDS_M2: 'yes' }, '/data'), /FRIENDS_M2 must be on or off/);
    assert.throws(() => onlineConfig({ FRIENDS_RELAY: 'on' }, '/data'), /FRIENDS_RELAY=on needs FRIENDS_M2=on/);
    assert.throws(() => onlineConfig({ ...relay, FRIENDS_TURN_SECRET: 'short' }, '/data'), /FRIENDS_TURN_SECRET/);
    assert.throws(() => onlineConfig({ ...relay, FRIENDS_TURN_LISTEN_IPS: '' }, '/data'), /FRIENDS_TURN_LISTEN_IPS/);
    assert.throws(() => onlineConfig({ ...relay, FRIENDS_TURN_EVENTS_PASSWORD: 'has spaces in it, no good' },
        '/data'), /FRIENDS_TURN_EVENTS_PASSWORD/);
    assert.throws(() => onlineConfig({ ...relay, FRIENDS_TURN_URIS: 'http://example.org' }, '/data'),
        /FRIENDS_TURN_URIS/);
    assert.throws(() => onlineConfig({ FRIENDS_M2: 'on', FRIENDS_STUN_PORTS: '3479,99999' }, '/data'),
        /FRIENDS_STUN_PORTS/);
    const on = onlineConfig({ ...relay, FRIENDS_STUN_PORTS: '', FRIENDS_TURN_EVENTS_PORT: '' }, '/data');
    assert.deepEqual(on.stunPorts, [3479], 'the classifier port by default');
    assert.equal(on.turn.confFile, '/data/relay/turnserver.conf');
    assert.deepEqual([on.turn.minPort, on.turn.maxPort, on.turn.eventsPort], [49160, 49415, 6390]);
});
