// Browsers opening download links cannot fill the host's guest places or run up relay credentials: only a link
// someone registered waits for its sender, each address may keep only two waiting, and relay credentials for guests
// have hourly budgets per link and per address.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ONLINE_LIMITS, newId } from '../src/online-protocol.js';
import { FakeHelper, b64, from, guest, identity, nextOf, nowS, startOnline } from './online-helpers.js';

const PROXIED = { FRIENDS_TRUSTED_PROXY: '127.0.0.1' };

async function openLink(url, linkId, address) {
    const browser = await guest(url, { headers: address ? from(address) : undefined });
    browser.send('link_open', { req: 1, link_id: linkId, payload: b64('sealed offer') });
    const opened = await nextOf(browser, 'sig_opened');
    return { browser, opened };
}

test('a link nobody registered gets the usual 2 minutes, not the 30 a waiting link gets', async (t) => {
    const { url, clock, online } = await startOnline(t);
    const { browser, opened } = await openLink(url, newId());
    assert.equal(opened.owner_online, false);
    const entry = online.sids.get(opened.sid);
    assert.equal(entry.held, false);
    assert.equal(entry.expiresAt - clock.now(), ONLINE_LIMITS.sidLifetimeMs);
    clock.advance(ONLINE_LIMITS.sidLifetimeMs + 1);
    assert.equal((await nextOf(browser, 'sig_closed', 3000)).reason, 'expired');
    assert.equal((await browser.closed).code, 1000);
});

test('each address keeps at most two opens waiting for an offline sender', async (t) => {
    const { url, clock, online } = await startOnline(t, { env: PROXIED });
    const mei = await FakeHelper.connect(url, { who: identity(), friendsId: 'kind-mole' });
    const linkId = newId();
    mei.send('link_register', { link_id: linkId, expires: nowS(clock) + 86_400 });
    await nextOf(mei.client, 'link_registered');
    await mei.close();
    const held = [];
    for (const address of ['2001:db8:0:1::7', '2001:db8:0:2::7', '2001:db8:0:3::7', '203.0.113.7']) {
        const { opened } = await openLink(url, linkId, address);
        assert.equal(opened.owner_online, false);
        held.push(online.sids.get(opened.sid).held);
    }
    assert.deepEqual(held, [true, true, false, true], 'one /56 holds two; another address its own');
});

test('guests get at most 10 relay credentials an hour per address', async (t) => {
    const { url, clock } = await startOnline(t, { env: PROXIED });
    const mei = await FakeHelper.connect(url, { friendsId: 'kind-mole' });
    const linkId = newId();
    mei.send('link_register', { link_id: linkId, expires: nowS(clock) + 86_400 });
    await nextOf(mei.client, 'link_registered');
    const results = [];
    for (let i = 0; i < 6; i++) {
        const { browser, opened } = await openLink(url, linkId, '198.51.100.20');
        await nextOf(mei.client, 'sig_incoming');
        mei.message(opened.sid, 'sealed answer');
        await nextOf(browser, 'sig_msg');
        for (let j = 0; j < ONLINE_LIMITS.relayCredentialsPerSidEnd; j++) {
            browser.send('relay_credentials', { req: 2 + j, sid: opened.sid });
            results.push((await nextOf(browser, ['relay_credentials_result', 'relay_refused'])).type);
        }
        await browser.close();
        await nextOf(mei.client, 'sig_closed');
        // Past the credentials' 300 s, so only the hourly budget refuses, never the share an address holds at once.
        clock.advance(ONLINE_LIMITS.relayCredentialTtlS * 1000 + 1000);
    }
    assert.equal(results.filter((type) => type === 'relay_credentials_result').length,
        ONLINE_LIMITS.guestCredentialsPerAddressPerHour);
    assert.deepEqual(results.slice(-2), ['relay_refused', 'relay_refused']);
    mei.close();
});

test('guests get at most 60 relay credentials an hour per link, from any number of addresses', async (t) => {
    const { online, clock } = await startOnline(t);
    const browser = (i) => ({ guest: true, ticket: { wideKey: `address-${i}` } });
    for (let i = 0; i < ONLINE_LIMITS.guestCredentialsPerLinkPerHour; i++) {
        assert.ok(online.takeCredentialBudget(browser(i), { linkHash: 'one-link' }));
    }
    assert.ok(!online.takeCredentialBudget(browser(99), { linkHash: 'one-link' }));
    assert.ok(online.takeCredentialBudget(browser(99), { linkHash: 'another-link' }));
    clock.advance(60 * 60_000);
    assert.ok(online.takeCredentialBudget(browser(100), { linkHash: 'one-link' }));
});
