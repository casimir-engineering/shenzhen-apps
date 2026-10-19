// Revoked and expired download links (HOST-PROTOCOL-ONLINE.md § Download links, Tombstones): the sender's helper
// leaves a tombstone (a hash of the link id, never the id) when it revokes or expires a link and sends it on every
// connection; a binding that expires on the host leaves one too. An open for a link nobody holds whose tombstone is
// here is answered at once with why, so the page says "revoked" or "expired" instead of waiting, and an app opening
// the link is told the same. Nobody but the link's holder can end a live link this way.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { linkTombstoneHash, tombstoneKey } from '../src/online-protocol.js';
import { CHUNK, LinkSender } from './link-sender.js';
import { fakeRtc, loadLinkScript, startReceiver } from './link-support.js';
import { FakeHelper, nextOf, nowS, startOnline, waitFor } from './online-helpers.js';

const api = loadLinkScript();
const b64 = (bytes) => Buffer.from(bytes).toString('base64url');

async function linkWithSender(t, host) {
    const rtc = fakeRtc();
    const sender = await LinkSender.start(host.url, { clock: host.clock, file: crypto.randomBytes(CHUNK + 9),
        RTCPeerConnection: rtc.RTCPeerConnection });
    t.after(() => sender.offline().catch(() => {}));
    return { sender, rtc };
}

function openPage(t, host, sender, rtc = fakeRtc()) {
    const page = startReceiver(api, { url: host.url, fragment: sender.fragment, clock: host.clock,
        RTCPeerConnection: rtc.RTCPeerConnection });
    t.after(() => page.receiver.shutdown());
    return page;
}

test('a revoked link: the page says so at once, with no wait, even with its sender offline', async (t) => {
    const host = await startOnline(t);
    const { sender } = await linkWithSender(t, host);
    sender.tombstone('revoked'); // as the helper revokes: the tombstone first, which ends the binding
    sender.unregister();
    await nextOf(sender.helper.client, 'link_unregistered');
    await sender.offline();
    const page = openPage(t, host, sender);
    assert.equal((await page.reached('failed', 3000)).reason, 'revoked');
    assert.ok(!page.states.some((s) => s.state === 'waiting'), 'never "Waiting for the sender"');
});

test('a link revoked while its host could not be told ends there as soon as the tombstone arrives', async (t) => {
    const host = await startOnline(t);
    const { sender } = await linkWithSender(t, host);
    sender.tombstone('revoked'); // no link_unregister: the helper restarted and kept only the hash
    await waitFor(() => host.online.links.size === 0);
    const page = openPage(t, host, sender);
    assert.equal((await page.reached('failed', 3000)).reason, 'revoked');
    assert.equal(sender.peersMade, 0);
});

test('a binding that expires on the host leaves an "expired" tombstone for 31 days', async (t) => {
    const host = await startOnline(t);
    const { sender } = await linkWithSender(t, host);
    await sender.offline();
    host.clock.advance(86_400_000 + 1000);
    host.online.links.prune();
    const page = openPage(t, host, sender);
    assert.equal((await page.reached('failed', 3000)).reason, 'expired');
    host.clock.advance(31 * 86_400_000);
    host.online.links.prune();
    assert.equal(host.online.links.ended(b64(sender.linkId)), null, 'gone after 31 days');
});

test('an app opening an ended link is told why in sig_opened, and no sid is made', async (t) => {
    const host = await startOnline(t);
    const { sender } = await linkWithSender(t, host);
    sender.tombstone('expired');
    sender.unregister();
    await nextOf(sender.helper.client, 'link_unregistered');
    const opener = await FakeHelper.connect(host.url, { friendsId: 'calm-heron' });
    t.after(() => opener.close());
    const opened = await opener.open({ link_id: b64(sender.linkId) });
    assert.equal(opened.type, 'sig_opened');
    assert.equal(opened.owner_online, false);
    assert.equal(opened.link_ended, 'expired');
    assert.equal(host.online.sids.size, 0);
});

test('a tombstone from anyone but the holder neither ends a live link nor shows on it', async (t) => {
    const host = await startOnline(t);
    const { sender, rtc } = await linkWithSender(t, host);
    const stranger = await FakeHelper.connect(host.url, { friendsId: 'calm-heron' });
    t.after(() => stranger.close());
    stranger.send('link_tombstones', { tombstones: [{ hash: b64(linkTombstoneHash(b64(sender.linkId))),
        reason: 'revoked', until: nowS(host.clock) + 3600 }] });
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(host.online.links.size, 1, 'still served');
    const page = openPage(t, host, sender, rtc);
    await page.reached('ready');
    // When the holder ends it, the holder's reason is the one kept, not the stranger's.
    sender.tombstone('expired');
    sender.unregister();
    await nextOf(sender.helper.client, 'link_unregistered');
    assert.equal(host.online.links.ended(b64(sender.linkId)), 'expired');
});

test('tombstones are checked: a reason, a 32-byte hash and a time within 31 days, at most 64 at once', async (t) => {
    const host = await startOnline(t);
    const now = nowS(host.clock);
    const good = { hash: b64(crypto.randomBytes(32)), reason: 'revoked', until: now + 60 };
    for (const bad of [[], [{ ...good, reason: 'changed' }], [{ ...good, hash: b64(crypto.randomBytes(16)) }],
        [{ ...good, until: now }], [{ ...good, until: now + 32 * 86_400 }], Array(65).fill(good)]) {
        const helper = await FakeHelper.connect(host.url, { friendsId: 'calm-heron' });
        helper.send('link_tombstones', { tombstones: bad });
        const closed = await new Promise((resolve) => helper.client.ws.once('close', (code) => resolve(code)));
        assert.equal(closed, 1008, JSON.stringify(bad).slice(0, 80));
    }
});

test('at most 500 tombstones per identity: the ones ending soonest go first', async (t) => {
    const host = await startOnline(t);
    const helper = await FakeHelper.connect(host.url, { friendsId: 'calm-heron' });
    t.after(() => helper.close());
    const now = nowS(host.clock);
    const hashes = Array.from({ length: 520 }, () => crypto.randomBytes(32));
    for (let i = 0; i < hashes.length; i += 64) {
        helper.send('link_tombstones', { tombstones: hashes.slice(i, i + 64).map((hash, j) => ({ hash: b64(hash),
            reason: 'expired', until: now + 1000 + i + j })) });
    }
    const count = () => host.host.db.prepare('SELECT COUNT(*) AS n FROM link_tombstones').get().n;
    await waitFor(() => count() === 500);
    const key = (hash) => tombstoneKey(host.host.config.identitySecret, hash);
    const kept = (hash) => host.host.db.prepare('SELECT 1 FROM link_tombstones WHERE tomb_key = ?').get(key(hash));
    assert.ok(!kept(hashes[0]) && !kept(hashes[19]) && kept(hashes[20]) && kept(hashes[519]));
});

test('tombstones reach the other hosts, and nothing in them names the link', async (t) => {
    const host = await startOnline(t);
    const sent = [];
    host.online.federation.broadcast = (type, body) => sent.push({ type, body });
    const { sender } = await linkWithSender(t, host);
    sender.tombstone('revoked');
    await waitFor(() => sent.some((m) => m.type === 'link_tomb'));
    const tomb = sent.find((m) => m.type === 'link_tomb').body;
    assert.deepEqual(Object.keys(tomb).sort(), ['identity_hash', 'reason', 'tomb_key', 'until']);
    const id = b64(sender.linkId);
    assert.ok(!JSON.stringify(tomb).includes(id), 'no link id');
    assert.notEqual(tomb.tomb_key, b64(linkTombstoneHash(id)), 'and not the helper\'s hash either');
    const other = await startOnline(t);
    other.online.links.remoteTomb('main', tomb);
    assert.equal(other.online.links.ended(id), 'revoked');
});
