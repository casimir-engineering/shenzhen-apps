// The download page's receiver over real WebRTC: node-datachannel (libdatachannel, the helper's own stack) on both
// ends, through a host on loopback, directly and, with coturn, through the relay only. The receiver is the page's
// own script. Without FRIENDS_TEST_DATACHANNEL (the package's directory, README.md § Testing) these skip and say
// so; the relayed one also needs FRIENDS_TEST_COTURN. Nothing is downloaded or installed.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { after, test } from 'node:test';

import { COTURN_SKIP, startCoturn } from './coturn-run.js';
import { CHUNK, LinkSender } from './link-sender.js';
import { collectingSink, datachannelPolyfill, loadLinkScript, startReceiver } from './link-support.js';
import { startOnline, waitFor } from './online-helpers.js';

const polyfill = datachannelPolyfill();
const SKIP = polyfill ? false : 'set FRIENDS_TEST_DATACHANNEL to a node-datachannel directory to run real WebRTC';
const api = loadLinkScript();
// Peer connections close a moment after each test (receiver.js, shutdown); libdatachannel stops after them.
after(async () => {
    await new Promise((resolve) => setTimeout(resolve, 500));
    polyfill?.cleanup();
});

// libdatachannel takes TURN credentials inside a URL, so the polyfill needs them percent-encoded (TURN REST
// usernames hold a colon); browsers take them as they are.
function encodedCredentials(Base) {
    return class extends Base {
        constructor(config = {}) {
            super({ ...config, iceServers: (config.iceServers ?? []).map((server) => (server.username
                ? { ...server, username: encodeURIComponent(server.username),
                    credential: encodeURIComponent(server.credential) } : server)) });
        }
    };
}

async function transfer(t, { host, size, timing, turn = null, behaviour }) {
    const RTCPeerConnection = encodedCredentials(polyfill.RTCPeerConnection);
    const file = crypto.randomBytes(size);
    const sender = await LinkSender.start(host.url, { clock: host.clock, file, RTCPeerConnection, turn, behaviour });
    t.after(() => sender.offline().catch(() => {}));
    const page = startReceiver(api, { url: host.url, fragment: sender.fragment, RTCPeerConnection, timing });
    t.after(() => page.receiver.shutdown());
    await page.reached('ready', 20_000);
    const sink = collectingSink();
    await page.receiver.download(sink);
    await page.reached('done', 40_000);
    assert.ok(sink.bytes().equals(file), 'the file arrived whole');
    assert.ok(sender.maxRecord <= 65536, `records of ${sender.maxRecord} bytes`);
    await waitFor(() => sender.done.length === 1);
    return { sender, page };
}

test('a file reaches the page over a real data channel', { skip: SKIP, timeout: 60_000 }, async (t) => {
    const host = await startOnline(t, { clock: { now: () => Date.now() } });
    const { sender } = await transfer(t, { host, size: 40 * CHUNK + 77 });
    assert.equal(sender.peersMade, 1);
});

test('with no direct path allowed, the file comes through coturn', { skip: SKIP || COTURN_SKIP, timeout: 60_000 },
    async (t) => {
        const host = await startOnline(t, { env: { FRIENDS_TURN_EVENTS_LISTEN: '::1' },
            clock: { now: () => Date.now() } });
        const { port } = await startCoturn(t, { sinkPort: host.online.relay.eventsPort });
        const turn = `turn:127.0.0.1:${port}?transport=udp`;
        host.online.settings.guestIceServers = [turn];
        // A direct phase too short to finish, so the page moves to the relay at once.
        const { page } = await transfer(t, { host, size: 8 * CHUNK, turn, timing: { directMs: 1 } });
        assert.equal(page.receiver.attemptNo, 2, 'the relayed attempt carried the file');
    });

test('a download whose data channel drops carries on over a new one, with a new key', { skip: SKIP, timeout: 60_000 },
    async (t) => {
        const host = await startOnline(t, { clock: { now: () => Date.now() } });
        const { sender, page } = await transfer(t, { host, size: 90 * CHUNK + 5, behaviour: { dropEvery: 25 } });
        assert.ok(sender.drops >= 3, `${sender.drops} drops`);
        assert.equal(sender.peersMade, sender.starts.length, 'a new peer connection each time');
        assert.ok(sender.starts.at(-1) >= 75, `starts ${sender.starts}`);
        assert.ok(page.states.some((s) => s.state === 'progress' && s.resuming));
    });
