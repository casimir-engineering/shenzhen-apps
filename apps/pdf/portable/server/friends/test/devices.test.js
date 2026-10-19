// Several devices of one person (HOST-PROTOCOL.md § Devices; protocol 3): a device checks in with its own key and its
// person's device chain; the Friends ID, the attestation and the statistics' people belong to the root, while
// connections stay per device. Revoked devices are refused, also with a chain from before their revocation, and are
// disconnected when a chain that revokes them arrives. Protocol 1 and 2 helpers check in exactly as before.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { checkAttestation } from '../src/attestation.js';
import { renderDashboard } from '../src/dashboard-page.js';
import { encodeBase64url, identityHash, signEd25519 } from '../src/keys.js';
import { CLOSE, checkinSignedBytes } from '../src/protocol.js';
import { summarize } from '../src/stats.js';
import { ChainBuilder, device } from './chain-builder.js';
import { IDENTITY_SECRET, TestClient, openLink, startMain, startPair, waitFor } from './helpers.js';

const P3 = { protocol: 3 };

async function checkin(url, who, options) {
    const client = await TestClient.connect(url);
    const reply = await client.checkin(who, options);
    return { client, reply };
}

test('a second device gets its person ID, attested for the root, while the first stays connected', async (t) => {
    const { url, host, clock } = await startMain(t);
    const [mac, laptop] = [device(), device()];
    const chain = new ChainBuilder(mac).add(laptop);
    const first = await checkin(url, mac, { friendsId: 'maple-river' });
    assert.equal(first.reply.friends_id, 'maple-river');
    const second = await checkin(url, laptop, { ...P3, root: mac, chain: chain.bytes, friendsId: 'other-name' });
    assert.equal(second.reply.type, 'welcome');
    assert.equal(second.reply.reservation, 'reserved');
    assert.equal(second.reply.friends_id, 'maple-river', 'the ID belongs to the root, not the device');
    const claim = (who) => ({ friendsId: 'maple-river', identityKey: who.raw, now: clock.now() });
    assert.equal(checkAttestation(second.reply.attestation, host.list, claim(mac)), 'valid',
        'what friends check nearby is the root key, which they pin');
    assert.equal(checkAttestation(second.reply.attestation, host.list, claim(laptop)), 'wrong_holder');
    // Both devices are live at once: a person's devices never replace each other.
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(host.liveCount(), 2);
    assert.equal(first.client.ws.readyState, first.client.ws.OPEN);
    // The root itself may check in with protocol 3 and no chain, or with its chain.
    const again = await checkin(url, mac, { ...P3, chain: chain.bytes });
    assert.equal(again.reply.friends_id, 'maple-river');
    for (const c of [first, second, again]) c.client.close();
});

test('a device the chain does not show for that root is refused', async (t) => {
    const { url } = await startMain(t);
    const [mac, laptop, stranger] = [device(), device(), device()];
    const chain = new ChainBuilder(mac).add(laptop);
    const refused = async (who, options, code = 'bad_chain') => {
        const { client, reply } = await checkin(url, who, options);
        assert.equal(reply.code, code, JSON.stringify(options.root?.b64));
        assert.equal((await client.closed).code, CLOSE.policy);
    };
    await refused(stranger, { ...P3, root: mac, chain: chain.bytes });
    await refused(laptop, { ...P3, root: stranger, chain: chain.bytes });
    await refused(laptop, { ...P3, root: mac });
    await refused(laptop, { ...P3, root: mac, chain: Buffer.from([1, 0, 1, 0, 0]) });
    // The chain is covered by the signature: another chain swapped in after signing does not verify.
    const other = new ChainBuilder(mac).add(laptop).add(stranger);
    await refused(laptop, { ...P3, root: mac, chain: chain.bytes, sentChain: other.bytes }, 'bad_signature');
});

test('a revoked device is refused, also later with a chain from before its revocation', async (t) => {
    const { url } = await startMain(t);
    const [mac, laptop, tablet] = [device(), device(), device()];
    const before = new ChainBuilder(mac).add(laptop).add(tablet);
    const after = before.fork().revoke(laptop);
    const live = await checkin(url, laptop, { ...P3, root: mac, chain: before.bytes });
    assert.equal(live.reply.type, 'welcome');
    // The tablet brings the chain that revokes the laptop: the laptop is disconnected at once.
    const tablet1 = await checkin(url, tablet, { ...P3, root: mac, chain: after.bytes });
    assert.equal(tablet1.reply.type, 'welcome');
    assert.equal((await live.client.next()).code, 'device_revoked');
    assert.equal((await live.client.closed).code, CLOSE.revoked);
    // Its own old chain no longer gets it in, nor does the new one.
    for (const chain of [before, after]) {
        const { client, reply } = await checkin(url, laptop, { ...P3, root: mac, chain: chain.bytes });
        assert.equal(reply.code, 'device_revoked');
        assert.equal((await client.closed).code, CLOSE.revoked);
    }
    tablet1.client.close();
});

test('a revoked first device is refused even as a protocol 1 helper', async (t) => {
    const { url } = await startMain(t);
    const [mac, laptop] = [device(), device()];
    const chain = new ChainBuilder(mac).add(laptop).revoke(mac, laptop);
    const fine = await checkin(url, mac, { friendsId: 'maple-river' });
    assert.equal(fine.reply.type, 'welcome', 'before any chain revokes it');
    fine.client.close();
    const other = await checkin(url, laptop, { ...P3, root: mac, chain: chain.bytes });
    assert.equal(other.reply.friends_id, 'maple-river');
    const { client, reply } = await checkin(url, mac, { friendsId: 'maple-river' });
    assert.equal(reply.code, 'device_revoked');
    assert.equal((await client.closed).code, CLOSE.revoked);
    other.client.close();
});

test('a revocation the rules make void is forgotten once a chain shows it', async (t) => {
    const { url, host } = await startMain(t);
    const [mac, laptop, tablet] = [device(), device(), device()];
    const base = new ChainBuilder(mac).add(laptop).add(tablet);
    // The laptop revokes the tablet while, concurrently, the first Mac revokes the laptop: the laptop's revocation
    // of the tablet is void, so in the merged chain the tablet stays.
    const laptopSide = base.fork().revoke(tablet, laptop);
    const macSide = base.fork().revoke(laptop, mac);
    const merged = laptopSide.fork().merge(macSide);
    assert.equal((await checkin(url, mac, { ...P3, chain: laptopSide.bytes })).reply.type, 'welcome');
    const stale = await checkin(url, tablet, { ...P3, root: mac, chain: base.bytes });
    assert.equal(stale.reply.code, 'device_revoked', 'the host saw the tablet revoked');
    const now = await checkin(url, tablet, { ...P3, root: mac, chain: merged.bytes });
    assert.equal(now.reply.type, 'welcome', 'the merged chain voids that revocation');
    const person = identityHash(IDENTITY_SECRET, mac.raw);
    const rows = host.db.prepare('SELECT COUNT(*) AS n FROM device_revocations WHERE identity_hash = ?').get(person);
    assert.equal(rows.n, 1, 'only the laptop stays revoked');
    now.client.close();
});

test('statistics count people and devices apart, with joins and revocations per day', async (t) => {
    const { url, host } = await startMain(t);
    const [mac, laptop, tablet, solo] = [device(), device(), device(), device()];
    const chain = new ChainBuilder(mac).add(laptop).add(tablet);
    const clients = [];
    clients.push((await checkin(url, mac, { friendsId: 'maple-river' })).client);
    clients.push((await checkin(url, laptop, { ...P3, root: mac, chain: chain.bytes })).client);
    clients.push((await checkin(url, tablet, { ...P3, root: mac, chain: chain.bytes })).client);
    clients.push((await checkin(url, solo, { friendsId: 'quiet-fern', protocol: 2 })).client);
    chain.revoke(tablet, laptop);
    clients.push((await checkin(url, laptop, { ...P3, root: mac, chain: chain.bytes })).client);
    await waitFor(() => summarize(host).people.revocationsToday === 1);
    const { people, uniques } = summarize(host);
    assert.equal(uniques.today, 2, 'two people');
    assert.equal(people.peopleToday, 2);
    assert.equal(people.devicesToday, 4);
    assert.equal(people.joinsToday, 2, 'the laptop and the tablet joined');
    assert.equal(people.revocationsToday, 1);
    assert.deepEqual({ ...people.perPerson, average: undefined }, { people: 2, devices: 4, average: undefined,
        one: 1, two: 0, three: 1, fourOrMore: 0 });
    assert.equal(people.days.length, 14);
    const page = renderDashboard(summarize(host));
    for (const text of ['People and devices', 'People today', 'Devices per person', 'Devices joined today',
        'Devices revoked today']) {
        assert.ok(page.includes(text), `the dashboard shows ${text}`);
    }
    for (const client of clients) client.close();
});

test('through a replica a device gets its person ID, and the main host checks the chain itself', async (t) => {
    const { main, replica, linkUp } = await startPair(t);
    await linkUp();
    const [mac, laptop, stranger] = [device(), device(), device()];
    const chain = new ChainBuilder(mac).add(laptop);
    const first = await checkin(main.url, mac, { friendsId: 'maple-river' });
    assert.equal(first.reply.friends_id, 'maple-river');
    const viaReplica = await checkin(replica.url, laptop, { ...P3, root: mac, chain: chain.bytes });
    assert.equal(viaReplica.reply.friends_id, 'maple-river');
    await waitFor(() => summarize(main.host).people.devicesToday === 2);
    assert.equal(summarize(main.host).people.joinsToday, 1);
    // A compromised replica forwarding a stranger's own signed check-in under someone's root gets nothing for it.
    const link = await openLink(main.url, { replicaKey: replica.hostKey });
    const forward = async (who, req) => {
        const challenge = crypto.randomBytes(32);
        const fields = { hostId: 'alt-sg', challenge, identityKey: who.raw, friendsId: 'maple-river', reserved: false,
            appVersion: '26.10.12-1', protocol: 3, listVersion: 1, rootKey: mac.raw, chain: chain.bytes };
        const proof = { host_id: 'alt-sg', challenge: encodeBase64url(challenge), identity_key: who.b64,
            friends_id: 'maple-river', reserved: false, app_version: '26.10.12-1', protocol: 3, list_version: 1,
            root_key: mac.b64, chain: chain.b64,
            sig: encodeBase64url(signEd25519(who.privateKey, checkinSignedBytes(fields))) };
        link.linkSend('fwd_reserve', { req, friends_id: 'maple-river', after_collision: false, allow_new: true,
            proof });
        let answer = await link.linkNext();
        while (answer.type !== 'fwd_reserve_result') answer = await link.linkNext();
        return [answer.req, answer.reservation];
    };
    assert.deepEqual(await forward(stranger, 7), [7, 'unavailable']);
    assert.deepEqual(await forward(laptop, 8), [8, 'reserved'], 'the same proof from the real device');
    first.client.close();
    viaReplica.client.close();
});

test('the first device keeps the person ID on release while its chain lists other devices', async (t) => {
    const { url } = await startMain(t);
    const [mac, laptop] = [device(), device()];
    const both = new ChainBuilder(mac).add(laptop);
    // The release's answer, past whatever the host sent after the welcome.
    const released = async (client) => {
        for (let msg = await client.release(mac); ; msg = await client.next()) {
            if (msg.type === 'released') return msg.released;
        }
    };
    // Reset Friends on the Mac while the laptop still uses the profile: the ID stays the person's.
    const first = await checkin(url, mac, { ...P3, chain: both.bytes, friendsId: 'maple-river' });
    assert.equal(first.reply.friends_id, 'maple-river');
    assert.equal(await released(first.client), false, 'not released while the laptop is listed');
    const laptopIn = await checkin(url, laptop, { ...P3, root: mac, chain: both.bytes, friendsId: 'other-name' });
    assert.equal(laptopIn.reply.friends_id, 'maple-river', 'the laptop still holds the person ID');
    laptopIn.client.close();
    // Once the laptop is removed, the Mac's release frees it.
    const last = await checkin(url, mac, { ...P3, chain: both.fork().revoke(laptop).bytes, friendsId: 'maple-river' });
    assert.equal(await released(last.client), true);
});

test('the challenge says the host protocol, so a helper checks in with the devices fields only where they are read',
    async (t) => {
        const { url } = await startMain(t);
        const client = await TestClient.connect(url);
        assert.equal((await client.challenge()).protocol, 3);
        client.close();
    });
