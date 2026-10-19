// Download links: a browser (a guest connection) opens a link by its id; the host forwards connection setup between
// it and the helper that registered the link, waits for that helper while it is offline, and refuses everything
// else a guest might try.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';

import { encodeBase64url } from '../src/keys.js';
import { ONLINE_LIMITS, linkIdHash, newId } from '../src/online-protocol.js';
import { IDENTITY_SECRET } from './helpers.js';
import {
    FakeHelper, GUEST_ICE, b64, guest, identity, nextOf, nowS, startOnline, text, waitFor,
} from './online-helpers.js';

async function register(helper, clock, linkId = newId()) {
    helper.send('link_register', { link_id: linkId, expires: nowS(clock) + 7 * 86_400 });
    const reply = await nextOf(helper.client, 'link_registered');
    return { linkId, reply };
}

test('a browser opens a link and talks to the sender\'s helper through the host', async (t) => {
    const { url, clock } = await startOnline(t);
    const mei = await FakeHelper.connect(url, { friendsId: 'kind-mole' });
    const { linkId, reply } = await register(mei, clock);
    assert.equal(reply.ok, true);
    const browser = await guest(url);
    browser.send('link_open', { req: 1, link_id: linkId, payload: b64('sealed offer') });
    const opened = await nextOf(browser, 'sig_opened');
    assert.equal(opened.owner_online, true);
    const incoming = await nextOf(mei.client, 'sig_incoming');
    assert.equal(incoming.via, 'link');
    assert.equal(incoming.link_id, linkId);
    assert.equal(text(incoming.payload), 'sealed offer');
    mei.message(opened.sid, 'sealed answer');
    assert.equal(text((await nextOf(browser, 'sig_msg')).payload), 'sealed answer');
    browser.send('relay_credentials', { req: 2, sid: opened.sid });
    const creds = await nextOf(browser, 'relay_credentials_result');
    assert.deepEqual(creds.ice_servers, GUEST_ICE, 'a browser has no signed list, so it is told where TURN is');
    mei.send('sig_close', { sid: opened.sid });
    assert.equal((await nextOf(browser, 'sig_closed')).reason, 'closed');
    assert.equal((await browser.closed).code, 1000, 'a guest connection ends with its one sid');
    mei.close();
});

test('while the sender is offline the browser waits, and is connected when the sender comes back', async (t) => {
    const { url, clock } = await startOnline(t);
    const who = identity();
    let mei = await FakeHelper.connect(url, { who, friendsId: 'kind-mole' });
    const { linkId } = await register(mei, clock);
    await mei.close();
    const browser = await guest(url);
    browser.send('link_open', { req: 1, link_id: linkId, payload: b64('sealed offer') });
    const opened = await nextOf(browser, 'sig_opened');
    assert.equal(opened.owner_online, false);
    clock.advance(5 * 60_000);
    mei = await FakeHelper.connect(url, { who, friendsId: 'kind-mole' });
    await register(mei, clock, linkId);
    const incoming = await nextOf(mei.client, 'sig_incoming');
    assert.equal(incoming.sid, opened.sid);
    browser.close();
    mei.close();
});

test('a link id belongs to whoever registered it first; 50 live links per identity', async (t) => {
    const { url, clock } = await startOnline(t);
    const mei = await FakeHelper.connect(url, { friendsId: 'kind-mole' });
    const thief = await FakeHelper.connect(url, { friendsId: 'sly-ferret' });
    const { linkId } = await register(mei, clock);
    assert.equal((await register(thief, clock, linkId)).reply.reason, 'taken');
    for (let i = 1; i < ONLINE_LIMITS.linksPerIdentity; i++) assert.equal((await register(mei, clock)).reply.ok, true);
    assert.equal((await register(mei, clock)).reply.reason, 'too_many');
    mei.close();
    thief.close();
});

test('a guest may only open a link first, and only within 10 seconds', async (t) => {
    const { url } = await startOnline(t, { env: { FRIENDS_CHECKIN_TIMEOUT_MS: '300' } });
    const curious = await guest(url);
    curious.send('rdv_lookup', { req: 1, keys: [encodeBase64url(Buffer.alloc(32))] });
    assert.equal((await nextOf(curious, 'error')).code, 'bad_request');
    assert.equal((await curious.closed).code, 1008);
    const idle = await guest(url);
    assert.equal((await idle.closed).code, 1008);
    const sneaky = await guest(url);
    sneaky.send('checkin', {});
    assert.equal((await nextOf(sneaky, 'error')).code, 'bad_request');
});

test('a guest connection may not open a second link or reach other sids', async (t) => {
    const { url, clock } = await startOnline(t);
    const mei = await FakeHelper.connect(url, { friendsId: 'kind-mole' });
    const { linkId } = await register(mei, clock);
    const browser = await guest(url);
    browser.send('link_open', { req: 1, link_id: linkId, payload: b64('offer') });
    await nextOf(browser, 'sig_opened');
    browser.send('link_open', { req: 2, link_id: linkId, payload: b64('again') });
    assert.equal((await nextOf(browser, 'error')).code, 'bad_request');
    await waitFor(() => mei.queue.some((m) => m.type === 'sig_incoming'));
    mei.close();
});

test('who holds a link survives a restart, so nobody else can claim it while its sender is away', async (t) => {
    const first = await startOnline(t);
    const who = identity();
    const mei = await FakeHelper.connect(first.url, { who, friendsId: 'kind-mole' });
    const { linkId } = await register(mei, first.clock);
    await mei.close();
    await first.host.stop();
    const files = fs.readdirSync(first.host.config.dataDir).filter((f) => f.startsWith('friends.sqlite'));
    const bytes = Buffer.concat(files.map((f) => fs.readFileSync(path.join(first.host.config.dataDir, f))));
    assert.equal(bytes.indexOf(Buffer.from(linkId)), -1, 'the link id itself is not stored');
    const again = await startOnline(t, { dataDir: path.dirname(first.host.config.dataDir), hostKey: first.hostKey,
        admin: first.admin, clock: first.clock });
    const thief = await FakeHelper.connect(again.url, { friendsId: 'sly-ferret' });
    assert.equal((await register(thief, again.clock, linkId)).reply.reason, 'taken');
    const back = await FakeHelper.connect(again.url, { who, friendsId: 'kind-mole' });
    assert.equal((await register(back, again.clock, linkId)).reply.ok, true);
    back.send('link_unregister', { link_id: linkId });
    await nextOf(back.client, 'link_unregistered');
    assert.equal((await register(thief, again.clock, linkId)).reply.ok, true, 'free once its sender lets it go');
    thief.close();
    back.close();
});

test('a browser opening links gets at most 10 guest connections a minute per address, 4 at once', async (t) => {
    const { url, online } = await startOnline(t);
    const browsers = [];
    for (let i = 0; i < ONLINE_LIMITS.guestsOpenPerAddress; i++) browsers.push(await guest(url));
    await assert.rejects(guest(url), /HTTP 429/, 'four open at once');
    for (const browser of browsers) await browser.close();
    await waitFor(() => online.links.guestCount === 0);
    // The refused fifth counted too: five more, one at a time, make ten this minute.
    for (let i = ONLINE_LIMITS.guestsOpenPerAddress + 1; i < ONLINE_LIMITS.guestsPerAddressPerMinute; i++) {
        await (await guest(url)).close();
        await waitFor(() => online.links.guestCount === 0);
    }
    await assert.rejects(guest(url), /HTTP 429/, 'ten a minute');
});

test('the sender going offline puts its links on hold until it registers them again', async (t) => {
    const { url, clock, online } = await startOnline(t);
    const who = identity();
    const mei = await FakeHelper.connect(url, { who, friendsId: 'kind-mole' });
    const { linkId } = await register(mei, clock);
    const linkHash = linkIdHash(IDENTITY_SECRET, linkId);
    assert.ok(online.links.route(linkHash));
    await mei.close();
    await waitFor(() => online.links.route(linkHash) === null);
    const browser = await guest(url);
    browser.send('link_open', { req: 1, link_id: linkId, payload: b64('offer') });
    assert.equal((await nextOf(browser, 'sig_opened')).owner_online, false);
    clock.advance(ONLINE_LIMITS.linkWaitMs + 1);
    assert.equal((await nextOf(browser, 'sig_closed', 3000)).reason, 'expired');
});
