// Host replies are signed (HOST-PROTOCOL.md § Signatures): welcome, reserve_result and released carry host_sig by
// the host key the signed list gives that host, over the connection's challenge and the reply's fields, so a
// TLS-intercepting proxy can neither forge one nor replay one as the answer to another request. These replies were
// unsigned before.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { releasedBody, reserveResultBody, welcomeBody } from '../src/protocol.js';
import {
    TestClient, identity, keyPair, listPayload, replySignedBy, signList, startMain, startPair,
} from './helpers.js';

test('welcome, reserve_result and released are signed by this host over the challenge and the request', async (t) => {
    const main = await startMain(t, { version: 3 });
    const holder = await TestClient.connect(main.url);
    await holder.checkin(identity(), { friendsId: 'maple-river' });
    const who = identity();
    const client = await TestClient.connect(main.url);
    const challenge = await client.challenge();
    const welcome = await client.checkin(who, { friendsId: 'maple-river', listVersion: 1 });
    const body = welcomeBody({ requested: 'maple-river', reservation: 'taken', friendsId: null,
        updateRequired: false, hostListPayload: welcome.host_list.payload });
    assert.ok(replySignedBy(main.hostKey, challenge, welcome, body), 'welcome');
    assert.ok(!replySignedBy(keyPair(), challenge, welcome, body), 'only this host\'s key verifies');
    const result = await client.reserve('maple-harbor');
    const resultBody = reserveResultBody({ requested: 'maple-harbor', reservation: 'reserved',
        friendsId: 'maple-harbor' });
    assert.ok(replySignedBy(main.hostKey, challenge, result, resultBody), 'reserve_result');
    assert.ok(!replySignedBy(main.hostKey, challenge, result, reserveResultBody({ requested: 'cedar-lake',
        reservation: 'reserved', friendsId: 'maple-harbor' })), 'the answer to one request is not another\'s');
    const released = await client.release(who, { friendsId: 'maple-harbor' });
    assert.ok(replySignedBy(main.hostKey, challenge, released, releasedBody({ released: true })), 'released');
    const other = await TestClient.connect(main.url);
    assert.ok(!replySignedBy(main.hostKey, await other.challenge(), welcome, body), 'bound to its connection');
    holder.close();
    other.close();
});

test('a replica signs its own replies with its own key', async (t) => {
    const pair = await startPair(t);
    await pair.linkUp();
    const client = await TestClient.connect(pair.replica.url);
    const challenge = await client.challenge();
    const welcome = await client.checkin(identity(), { friendsId: 'river-stone', listVersion: 2 });
    const body = welcomeBody({ requested: 'river-stone', reservation: 'reserved', friendsId: 'river-stone',
        updateRequired: false, hostListPayload: null });
    assert.ok(replySignedBy(pair.replicaKey, challenge, welcome, body));
    assert.ok(!replySignedBy(pair.mainKey, challenge, welcome, body));
    client.close();
});

test('a host whose key is not the one its list names does not start', async (t) => {
    const admin = keyPair();
    const listText = signList(listPayload({ entries: [{ id: 'main-hk', key: keyPair(), priority: 1 }] }), [admin]);
    await assert.rejects(startMain(t, { admin, listText }), /FRIENDS_HOST_KEY_FILE/);
});
