// The download page's receiver (src/pages/script/receiver.js) against a host on loopback and the JS sender
// (link-sender.js), over the in-memory peer connection: the proof before any peer connection, the sealed metadata
// and chunks, the whole-file hash, the relay as last resort, and every way a download must fail rather than
// complete.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { ONLINE_LIMITS } from '../src/online-protocol.js';
import { CHUNK, LinkSender } from './link-sender.js';
import { collectingSink, fakeRtc, loadLinkScript, startReceiver } from './link-support.js';
import { startOnline, waitFor } from './online-helpers.js';

const api = loadLinkScript();
const PNG = Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), crypto.randomBytes(40)]);

async function setup(t, { size = 3 * CHUNK + 1234, behaviour = {}, rtc = fakeRtc(), timing } = {}) {
    const host = await startOnline(t);
    const file = crypto.randomBytes(size);
    const sender = await LinkSender.start(host.url, { clock: host.clock, file, thumbnail: PNG, behaviour,
        RTCPeerConnection: rtc.RTCPeerConnection, turn: 'turn:127.0.0.1:3478?transport=udp' });
    t.after(() => sender.offline().catch(() => {}));
    const page = startReceiver(api, { url: host.url, fragment: sender.fragment, clock: host.clock, timing,
        RTCPeerConnection: rtc.RTCPeerConnection });
    t.after(() => page.receiver.shutdown());
    return { host, file, sender, page, rtc };
}

test('a file arrives whole: metadata first, then every chunk, checked against its SHA-256', async (t) => {
    const { file, sender, page, rtc } = await setup(t);
    const ready = await page.reached('ready');
    assert.equal(ready.meta.name, 'Site photos.pdf');
    assert.equal(ready.meta.size, file.length);
    assert.equal(ready.meta.sender, 'Mei');
    assert.deepEqual(Buffer.from(ready.meta.thumbnail), PNG);
    const sink = collectingSink();
    await page.receiver.download(sink);
    await page.reached('done');
    assert.ok(sink.closed && !sink.aborted);
    assert.ok(sink.bytes().equals(file));
    await waitFor(() => sender.done.length === 1);
    assert.deepEqual(sender.done, [true]);
    assert.ok(rtc.stats.maxMessage <= 65536, 'every data-channel message is at most 64 KiB');
    assert.ok(rtc.stats.maxMessage > 65000, 'chunks fill their records');
});

test('an empty file and a file of exactly one chunk both complete', async (t) => {
    for (const size of [0, CHUNK]) {
        const { file, page } = await setup(t, { size });
        await page.reached('ready');
        const sink = collectingSink();
        await page.receiver.download(sink);
        await page.reached('done');
        assert.ok(sink.bytes().equals(file), `size ${size}`);
    }
});

test('the sender creates no peer connection before the page proves the link secret', async (t) => {
    const { sender, page } = await setup(t);
    await page.reached('ready');
    assert.equal(sender.badProofs, 0);
    assert.equal(sender.peersMade, 1);
    const stranger = startReceiver(api, { url: page.receiver.wsUrl.replace('?guest=1', ''),
        fragment: Buffer.concat([Buffer.of(1), Buffer.from(page.link.linkId), crypto.randomBytes(32)])
            .toString('base64url'), RTCPeerConnection: fakeRtc().RTCPeerConnection });
    t.after(() => stranger.receiver.shutdown());
    await waitFor(() => sender.refusedHellos === 1);
    assert.equal(sender.peersMade, 1, 'a page with the wrong secret gets no peer connection');
    assert.ok(!stranger.states.some((s) => s.state === 'ready'), 'and never sees the metadata');
});

test('a tampered chunk stops the download and nothing is kept', async (t) => {
    const { page } = await setup(t, { behaviour: { tamperChunk: 1 } });
    await page.reached('ready');
    const sink = collectingSink();
    await page.receiver.download(sink);
    assert.equal((await page.reached('failed')).reason, 'corrupt');
    assert.ok(sink.aborted && !sink.closed);
});

test('a chunk relabelled to hide the last one is refused, so truncation cannot pass as the end', async (t) => {
    const { page } = await setup(t, { behaviour: { relabelLast: true } });
    await page.reached('ready');
    const sink = collectingSink();
    await page.receiver.download(sink);
    assert.equal((await page.reached('failed')).reason, 'corrupt');
    assert.ok(sink.aborted);
});

test('a download whose connection keeps dropping carries on from the last chunk written, to the end', async (t) => {
    // A drop every 7 chunks, as the relay's session limit makes on a long download: each new connection has fresh
    // nonces (so a fresh content key) and starts from the first chunk the page has not written.
    const { file, sender, page } = await setup(t, { size: 30 * CHUNK + 99, behaviour: { dropEvery: 7 } });
    await page.reached('ready');
    const sink = collectingSink();
    await page.receiver.download(sink);
    await page.reached('done', 20_000);
    assert.ok(sink.closed && !sink.aborted);
    assert.ok(sink.bytes().equals(file), 'every byte once, in order');
    assert.ok(sender.drops >= 4, `${sender.drops} drops`);
    assert.equal(sender.starts[0], 0);
    assert.ok(sender.starts.slice(1).every((from, i) => from > sender.starts[i]), `starts ${sender.starts}`);
    assert.equal(sender.sessions.size, sender.starts.length, 'a new session (and key) for every connection');
    assert.deepEqual(sender.done, [true]);
    const reconnecting = page.states.filter((s) => s.state === 'progress' && s.resuming);
    assert.ok(reconnecting.length >= 4, 'the page says it is reconnecting, and keeps its progress');
    assert.ok(!page.states.some((s) => s.state === 'failed' || s.state === 'connecting' && s.resuming));
});

// The relay's session limit, made short: every relayed connection ends 300 ms after it opens, mid-file, and the page
// carries on over a new relayed connection each time, whether the browser reports the drop or only goes quiet.
test('a relayed download outlives a short relay session limit, reported or silent', async (t) => {
    for (const relayEnd of ['state', 'silent']) {
        const rtc = fakeRtc({ direct: false, relaySessionMs: 300, relayEnd });
        const { file, sender, page } = await setup(t, { rtc, size: 40 * CHUNK + 3,
            behaviour: { chunkDelayMs: 25 }, timing: { directMs: 50, disconnectedMs: 100, stallMs: 400 } });
        await page.reached('ready');
        const sink = collectingSink();
        await page.receiver.download(sink);
        await page.reached('done', 20_000);
        assert.ok(sink.bytes().equals(file), relayEnd);
        assert.ok(rtc.stats.relayed >= 3 && sender.starts.length >= 3, `${relayEnd}: starts ${sender.starts}`);
        assert.equal(page.receiver.attemptNo, 2, 'each time through the relay');
    }
});

test('a connection that ends again and again at the same chunk fails the download, keeping nothing', async (t) => {
    const { sender, page } = await setup(t, { behaviour: { truncateAfter: 2 } });
    await page.reached('ready');
    const sink = collectingSink();
    await page.receiver.download(sink);
    assert.equal((await page.reached('failed')).reason, 'lost');
    assert.ok(sink.aborted && !sink.closed);
    assert.equal(sender.drops, 4, 'the first drop and three reconnections that brought nothing');
});

test('metadata for another file on the new connection is refused', async (t) => {
    const { sender, page } = await setup(t, { size: 20 * CHUNK, behaviour: { dropEvery: 5 } });
    await page.reached('ready');
    const sink = collectingSink();
    await page.receiver.download(sink);
    await waitFor(() => sender.drops === 1);
    sender.file = crypto.randomBytes(20 * CHUNK);
    sender.behaviour.wrongHash = true;
    assert.equal((await page.reached('failed')).reason, 'corrupt');
    assert.ok(sink.aborted && !sink.closed);
});

test('a file whose SHA-256 does not match never completes: the last chunk is held back', async (t) => {
    const { file, page } = await setup(t, { behaviour: { wrongHash: true } });
    await page.reached('ready');
    const sink = collectingSink();
    await page.receiver.download(sink);
    assert.equal((await page.reached('failed')).reason, 'corrupt');
    assert.ok(sink.aborted && !sink.closed);
    assert.ok(sink.bytes().length < file.length, 'the last chunk was never written');
});

test('the sender says the file changed, or the link was revoked or expired', async (t) => {
    for (const [behaviour, reason] of [[{ endOnOpen: 'changed' }, 'changed'],
        [{ endBeforeChallenge: 'revoked' }, 'revoked'], [{ endBeforeChallenge: 'expired' }, 'expired'],
        [{ endBeforeChallenge: 'something-new' }, 'unavailable']]) {
        const { page } = await setup(t, { behaviour });
        assert.equal((await page.reached('failed')).reason, reason);
        assert.ok(!page.states.some((s) => s.state === 'ready'));
    }
});

test('the page never lets the sender run more than 64 chunks ahead of what it has written', async (t) => {
    const { sender, page } = await setup(t, { size: 150 * CHUNK });
    await page.reached('ready');
    const sink = collectingSink({ writeDelayMs: 2 });
    let worst = 0;
    const timer = setInterval(() => {
        worst = Math.max(worst, sender.sentChunks - sink.chunks.length);
    }, 1);
    await page.receiver.download(sink);
    await page.reached('done');
    clearInterval(timer);
    assert.ok(worst <= 64 + 1, `the sender ran ${worst} chunks ahead`);
    assert.ok(sender.controls.filter((c) => c === 'credit').length >= 5);
});

test('while the sender is offline the page waits, and the file comes when the sender is back', async (t) => {
    const host = await startOnline(t);
    const rtc = fakeRtc();
    const file = crypto.randomBytes(CHUNK + 5);
    const sender = await LinkSender.start(host.url, { clock: host.clock, file,
        RTCPeerConnection: rtc.RTCPeerConnection });
    await sender.offline();
    const page = startReceiver(api, { url: host.url, fragment: sender.fragment, clock: host.clock,
        RTCPeerConnection: rtc.RTCPeerConnection });
    t.after(() => page.receiver.shutdown());
    await page.reached('waiting');
    await sender.online();
    t.after(() => sender.offline().catch(() => {}));
    await page.reached('ready');
    const sink = collectingSink();
    await page.receiver.download(sink);
    await page.reached('done');
    assert.ok(sink.bytes().equals(file));
});

test('after the host\'s 30-minute wait the page keeps waiting, and still gets the file', async (t) => {
    const host = await startOnline(t);
    const rtc = fakeRtc();
    const file = crypto.randomBytes(100);
    const sender = await LinkSender.start(host.url, { clock: host.clock, file,
        RTCPeerConnection: rtc.RTCPeerConnection });
    await sender.offline();
    const page = startReceiver(api, { url: host.url, fragment: sender.fragment, clock: host.clock,
        RTCPeerConnection: rtc.RTCPeerConnection });
    t.after(() => page.receiver.shutdown());
    await page.reached('waiting');
    const firstSid = page.receiver.sid;
    host.clock.advance(ONLINE_LIMITS.linkWaitMs + 1);
    await waitFor(() => page.receiver.sid && page.receiver.sid !== firstSid, { timeoutMs: 8000 });
    assert.ok(!page.states.some((s) => s.state === 'failed'), 'still waiting, on a new open');
    await sender.online();
    t.after(() => sender.offline().catch(() => {}));
    await page.reached('ready');
});

test('a link nobody holds any more ends with "not working" after the host\'s 2 minutes', async (t) => {
    const host = await startOnline(t);
    const sender = await LinkSender.start(host.url, { clock: host.clock, file: Buffer.alloc(10),
        RTCPeerConnection: fakeRtc().RTCPeerConnection });
    sender.unregister();
    await sender.offline();
    const page = startReceiver(api, { url: host.url, fragment: sender.fragment, clock: host.clock,
        RTCPeerConnection: fakeRtc().RTCPeerConnection });
    t.after(() => page.receiver.shutdown());
    await page.reached('waiting');
    host.clock.advance(ONLINE_LIMITS.sidLifetimeMs + 1);
    assert.equal((await page.reached('failed')).reason, 'gone');
});

test('when no direct path opens, the page asks the host for the relay and connects through it', async (t) => {
    const rtc = fakeRtc({ direct: false });
    const { file, page } = await setup(t, { rtc, timing: { directMs: 300 } });
    await page.reached('ready');
    const relayed = rtc.stats.configs.filter((c) => c.iceTransportPolicy === 'relay');
    assert.equal(relayed.length, 2, 'both ends use the relay for the second attempt');
    const pageConfig = relayed.find((c) => c.iceServers?.[0]?.urls?.startsWith('turn:127.0.0.1'));
    assert.ok(pageConfig?.iceServers[0].username && pageConfig.iceServers[0].credential);
    assert.ok(!rtc.stats.configs[0].iceServers.some((s) => String(s.urls).startsWith('turn:')),
        'the first attempt never uses the relay');
    const sink = collectingSink();
    await page.receiver.download(sink);
    await page.reached('done');
    assert.ok(sink.bytes().equals(file));
});

test('without any path the page says it could not connect', async (t) => {
    const rtc = fakeRtc({ direct: false });
    const { page } = await setup(t, { rtc, timing: { directMs: 200, relayMs: 300 },
        behaviour: { noRelay: true } });
    assert.equal((await page.reached('failed')).reason, 'nopath');
});

test('cancelling stops the download, tells the sender, and keeps nothing', async (t) => {
    const { sender, page } = await setup(t, { size: 200 * CHUNK });
    await page.reached('ready');
    const sink = collectingSink({ writeDelayMs: 5 });
    await page.receiver.download(sink);
    await waitFor(() => sink.chunks.length > 2);
    page.receiver.cancel();
    assert.equal((await page.reached('failed')).reason, 'cancelled');
    assert.ok(sink.aborted);
    await waitFor(() => sender.controls.includes('cancel'));
});
