// What the link pages say and show (src/pages/script/view.js, render.js, save.js): the words for each state, the
// buttons each kind of computer gets, the remembered app, the warning before a file too large for the browser,
// and names that stay text however hostile.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

import { loadLinkScript } from './link-support.js';

const api = loadLinkScript();
const plain = (text) => text.replace(/[⁨⁩]/g, '');
const URLS = { pdf: 'https://example.org/pdf', files: 'https://example.org/files', '3d': 'https://example.org/3d' };
const MAC = { mac: true, platform: 'mac', handheld: false, webrtc: true, fileSystemAccess: true, serviceWorker: true };
const PHONE = { mac: false, platform: 'android', handheld: true, webrtc: true, fileSystemAccess: false,
    serviceWorker: false };
const WINDOWS = { ...MAC, mac: false, platform: 'windows' };
const OTHER = { ...MAC, mac: false, platform: 'other' };

function friendLink(name = 'Mei') {
    const bytes = Buffer.concat([Buffer.of(1), crypto.randomBytes(48), Buffer.of(11), Buffer.from('brave-otter'),
        Buffer.of(Buffer.byteLength(name)), Buffer.from(name)]);
    return api.parseLinkPayload('f', bytes.toString('base64url'));
}

function downloadLink() {
    return api.parseLinkPayload('d', Buffer.concat([Buffer.of(1), crypto.randomBytes(48)]).toString('base64url'));
}

const META = { name: 'Site photos.pdf', size: 12_400_000, type: 'application/pdf', sender: 'Mei', thumbnail: null };

test('the friend page: who invited you, every app on a Mac, the remembered one first', () => {
    const view = api.friendView({ link: friendLink(), traits: MAC, remembered: null, urls: URLS });
    assert.equal(plain(view.title), 'Mei invited you to Shenzhen Friends');
    assert.deepEqual(view.actions.map((a) => [a.label, Boolean(a.primary)]),
        [['Open in ShenzhenPDF', true], ['Open in Shenzhen Files', false], ['Open in Shenzhen 3D', false]]);
    assert.match(view.actions[0].href, /^shenzhenpdf:\/\/friends\/link#f\./);
    assert.match(view.actions[1].href, /^shenzhenfiles:\/\/friends\/link#f\./);
    assert.match(view.actions[2].href, /^shenzhen3d:\/\/friends\/link#f\./);
    assert.match(plain(view.lead), /Open this invitation in any of these apps to add Mei\.$/);
    assert.deepEqual(view.about.links.map((l) => [l.label, l.href]),
        [['Get ShenzhenPDF', URLS.pdf], ['Get Shenzhen Files', URLS.files], ['Get Shenzhen 3D', URLS['3d']]]);
    assert.match(view.about.text, new RegExp('Shenzhen 3D is a 3D model viewer\\. All three are free for Macs with '
        + 'Apple silicon, and Shenzhen 3D also runs on Windows and Linux\\.'));
    const remembered = api.friendView({ link: friendLink(), traits: MAC, remembered: 'files', urls: URLS });
    assert.equal(remembered.actions[0].label, 'Open in Shenzhen Files');
    assert.ok(remembered.actions[0].primary);
    const threeD = api.friendView({ link: friendLink(), traits: MAC, remembered: '3d', urls: URLS });
    assert.deepEqual(threeD.actions.map((a) => [a.label, Boolean(a.primary)]),
        [['Open in Shenzhen 3D', true], ['Open in ShenzhenPDF', false], ['Open in Shenzhen Files', false]]);
    const unknown = api.friendView({ link: friendLink(), traits: MAC, remembered: 'other', urls: URLS });
    assert.deepEqual(unknown.actions.map((a) => a.id), ['open-pdf', 'open-files', 'open-3d']);
    const not3d = api.friendView({ link: friendLink(), traits: MAC, remembered: '3d', opened: '3d', urls: URLS });
    assert.equal(not3d.notes[0].text, 'Nothing opened? Shenzhen 3D may not be on this Mac yet. Get it below, then '
        + 'open this link again.');
    const opened = api.friendView({ link: friendLink(), traits: MAC, remembered: 'pdf', opened: 'pdf', urls: URLS });
    assert.match(opened.notes[0].text, /^Nothing opened\? ShenzhenPDF may not be on this Mac yet\./);
});

test('without a Shenzhen 3D address there is no Get link for it and no note sending people to one', () => {
    const urls = { ...URLS, '3d': '' };
    const view = api.friendView({ link: friendLink(), traits: MAC, remembered: '3d', opened: '3d', urls });
    assert.deepEqual(view.about.links.map((l) => l.label), ['Get ShenzhenPDF', 'Get Shenzhen Files']);
    assert.deepEqual(view.actions.map((a) => a.label),
        ['Open in Shenzhen 3D', 'Open in ShenzhenPDF', 'Open in Shenzhen Files']);
    assert.equal(view.notes[0].text, 'Nothing opened? Shenzhen 3D may not be on this Mac yet. Open this link in '
        + 'ShenzhenPDF or Shenzhen Files instead.');
    const download = api.downloadView({ link: downloadLink(), traits: MAC, remembered: '3d', opened: '3d',
        state: 'ready', meta: META, saver: { tooLarge: false }, urls });
    assert.doesNotMatch(download.notes[0].text, /Get it below/);
    assert.ok(!download.about.links.some((l) => /3D/.test(l.label)));
});

test('on Windows and Linux the friend page offers Shenzhen 3D, the one app there', () => {
    for (const [traits, noun] of [[WINDOWS, 'computer'], [{ ...WINDOWS, platform: 'linux' }, 'computer']]) {
        const view = api.friendView({ link: friendLink(), traits, remembered: 'pdf', opened: '3d', urls: URLS });
        assert.deepEqual(view.actions.map((a) => [a.label, Boolean(a.primary)]), [['Open in Shenzhen 3D', true]]);
        assert.match(plain(view.lead), /Open this invitation in Shenzhen 3D to add Mei\.$/);
        assert.equal(view.about.heading, 'New to Shenzhen 3D?');
        assert.deepEqual(view.about.links.map((l) => l.label), ['Get Shenzhen 3D']);
        assert.equal(view.notes[0].text, `Nothing opened? Shenzhen 3D may not be on this ${noun} yet. Get it below, `
            + 'then open this link again.');
    }
});

test('the friend page where no app opens links says where Friends works and offers no button that cannot work', () => {
    // Shenzhen 3D's phone builds reach friends only nearby and open no links yet.
    for (const traits of [OTHER, PHONE, { ...PHONE, platform: 'ipad-iphone' }]) {
        const view = api.friendView({ link: friendLink(), traits, urls: URLS });
        assert.deepEqual(view.actions, []);
        assert.equal(plain(view.lead), 'Shenzhen Friends works in ShenzhenPDF, Shenzhen Files and Shenzhen 3D on a '
            + 'Mac with Apple silicon, and in Shenzhen 3D on Windows and Linux. Open this link on one of those '
            + 'computers to add Mei.');
    }
    const nameless = api.friendView({ link: friendLink(''), traits: MAC, urls: URLS });
    assert.equal(nameless.title, 'You’re invited to Shenzhen Friends');
    assert.match(nameless.lead, /Friends ID brave-otter/);
    const broken = api.friendView({ link: null, traits: MAC, urls: URLS });
    assert.equal(broken.title, 'This invitation link is incomplete');
    assert.deepEqual(broken.actions, []);
});

test('the download page waits for the sender, whatever they use', () => {
    // The link carries no name (PROTOCOL.md § Links): the sender is named once the sealed metadata arrives.
    const model = { link: downloadLink(), traits: MAC, urls: URLS, state: 'waiting' };
    const view = api.downloadView(model);
    assert.equal(plain(view.title), 'Waiting for the sender');
    assert.equal(view.lead, 'The file comes once the sender has ShenzhenPDF, Shenzhen Files or Shenzhen 3D open. '
        + 'Keep this page open.');
    assert.equal(plain(api.downloadView({ ...model, state: 'connecting' }).title), 'Connecting to the sender…');
    assert.equal(plain(api.downloadView({ ...model, state: 'connecting', meta: META }).title), 'Connecting to Mei…');
});

test('once the metadata arrives: the file, Download, and the apps that run here', () => {
    const base = { link: downloadLink(), urls: URLS, state: 'ready', meta: META };
    const mac = api.downloadView({ ...base, traits: MAC, saver: api.chooseSaver(MAC, META.size) });
    assert.equal(plain(mac.title), 'Mei shared a file with you', 'the name from the metadata when the link has none');
    assert.deepEqual(mac.file, { name: 'Site photos.pdf', size: '12 MB', thumbnailUrl: undefined });
    assert.deepEqual(mac.actions.map((a) => a.label),
        ['Download', 'Open in ShenzhenPDF', 'Open in Shenzhen Files', 'Open in Shenzhen 3D']);
    assert.ok(mac.actions[0].primary);
    const windows = api.downloadView({ ...base, traits: WINDOWS, saver: api.chooseSaver(WINDOWS, META.size) });
    assert.deepEqual(windows.actions.map((a) => a.label), ['Download', 'Open in Shenzhen 3D']);
    assert.equal(windows.about.heading, 'New to Shenzhen 3D?');
    const phone = api.downloadView({ ...base, traits: PHONE, saver: api.chooseSaver(PHONE, META.size) });
    assert.deepEqual(phone.actions.map((a) => a.label), ['Download'], 'the phone builds cannot fetch the file');
    assert.equal(phone.about, null);
    const other = api.downloadView({ ...base, traits: OTHER, saver: api.chooseSaver(OTHER, META.size) });
    assert.deepEqual(other.actions.map((a) => a.label), ['Download'], 'only Download where no app runs');
    assert.equal(other.about, null);
    const remembered = api.downloadView({ ...base, traits: MAC, remembered: 'files',
        saver: api.chooseSaver(MAC, META.size) });
    assert.deepEqual(remembered.actions.map((a) => [a.label, Boolean(a.primary)]),
        [['Download', true], ['Open in Shenzhen Files', false], ['Open in ShenzhenPDF', false],
            ['Open in Shenzhen 3D', false]]);
});

test('a file too large for a browser that must hold it in memory is refused before it starts', () => {
    const huge = { ...META, size: 3 * 2 ** 30 };
    const safari = { ...MAC, fileSystemAccess: false, serviceWorker: false };
    assert.deepEqual(api.chooseSaver(safari, huge.size), { kind: 'memory', tooLarge: true });
    assert.deepEqual(api.chooseSaver(safari, 2 ** 30), { kind: 'memory', tooLarge: false });
    assert.deepEqual(api.chooseSaver(PHONE, 600 * 2 ** 20), { kind: 'memory', tooLarge: true });
    assert.deepEqual(api.chooseSaver(MAC, 50 * 2 ** 40), { kind: 'file', tooLarge: false }, 'no size limit');
    assert.deepEqual(api.chooseSaver({ ...PHONE, serviceWorker: true }, 50 * 2 ** 40),
        { kind: 'stream', tooLarge: false });
    const view = api.downloadView({ link: downloadLink(), traits: safari, urls: URLS, state: 'ready',
        meta: huge, saver: api.chooseSaver(safari, huge.size) });
    assert.deepEqual(view.actions.map((a) => [a.label, Boolean(a.primary)]),
        [['Open in ShenzhenPDF', true], ['Open in Shenzhen Files', false], ['Open in Shenzhen 3D', false]],
        'no Download; the apps instead');
    assert.equal(view.notes[0].tone, 'warn');
    assert.equal(view.notes[0].text, 'This file is too large for this browser to save. Open this page in Chrome or '
        + 'Edge on a computer, or open the file in ShenzhenPDF, Shenzhen Files or Shenzhen 3D.');
    const phone = api.downloadView({ link: downloadLink(), traits: PHONE, urls: URLS, state: 'ready', meta: huge,
        saver: api.chooseSaver(PHONE, huge.size) });
    assert.deepEqual(phone.actions, [], 'no app on a phone can fetch it either');
    assert.match(phone.notes[0].text, /Edge on a computer\.$/);
});

test('browsers are told apart by what they can do', () => {
    const win = (ua, extra = {}) => ({ navigator: { userAgent: ua, maxTouchPoints: extra.touch ?? 0,
        serviceWorker: {} }, isSecureContext: true, ReadableStream, RTCPeerConnection: function rtc() {},
    crypto: { subtle: {} }, ...extra.win });
    const safari = api.browserTraits(win('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
        + '(KHTML, like Gecko) Version/18.0 Safari/605.1.15'));
    assert.ok(safari.mac && safari.platform === 'mac' && !safari.serviceWorker && !safari.fileSystemAccess);
    const ipad = api.browserTraits(win('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
        + '(KHTML, like Gecko) Version/18.0 Safari/605.1.15', { touch: 5 }));
    assert.ok(!ipad.mac && ipad.handheld && ipad.platform === 'ipad-iphone', 'an iPad asking for the desktop site');
    const chrome = api.browserTraits(win('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        + '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36', { win: { showSaveFilePicker() {} } }));
    assert.ok(chrome.mac && chrome.fileSystemAccess && chrome.serviceWorker);
    const windows = api.browserTraits(win('Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 '
        + 'Firefox/131.0'));
    assert.ok(!windows.mac && !windows.handheld && windows.serviceWorker && windows.platform === 'windows');
    const linux = api.browserTraits(win('Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0'));
    assert.equal(linux.platform, 'linux');
    const chromebook = api.browserTraits(win('Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 '
        + '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'));
    assert.equal(chromebook.platform, 'other', 'no app runs on ChromeOS');
    const android = api.browserTraits(win('Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
        + 'Chrome/130.0.0.0 Mobile Safari/537.36'));
    assert.ok(android.handheld && android.serviceWorker && !android.mac && android.platform === 'android');
    assert.equal(api.browserTraits(win('x', { win: { RTCPeerConnection: undefined } })).webrtc, false);
});

test('every failure says what happened and offers Try again only when trying again can help', () => {
    const base = { link: downloadLink(), traits: MAC, urls: URLS, state: 'failed', meta: META };
    const expect = {
        changed: ['Mei changed this file after sharing the link', false],
        revoked: ['Mei stopped sharing this file', false],
        expired: ['This link has expired', false],
        gone: ['This link isn’t working', false],
        unavailable: ['Mei can’t send this file right now', false],
        corrupt: ['The file didn’t arrive intact', true],
        nopath: ['Couldn’t connect to Mei', true],
        lost: ['The connection to Mei was lost', true],
        unreachable: ['This page can’t connect', true],
        busy: ['Too many downloads from this network right now', true],
        cancelled: ['Download cancelled', true],
    };
    for (const [reason, [title, retry]] of Object.entries(expect)) {
        const view = api.downloadView({ ...base, detail: { reason } });
        assert.equal(plain(view.title), title, reason);
        assert.equal(view.actions.some((a) => a.id === 'retry'), retry, reason);
    }
    const lost = api.downloadView({ ...base, detail: { reason: 'lost' }, wasDownloading: true });
    assert.equal(lost.lead, 'The download stopped and nothing was saved. Try again.');
});

test('progress, completion, and the Save button when the file was kept in memory', () => {
    const base = { link: downloadLink(), traits: MAC, urls: URLS, meta: META };
    const progress = api.downloadView({ ...base, state: 'progress',
        detail: { received: 4_500_000, size: 12_400_000 } });
    assert.equal(progress.progress.text, '4.5 MB of 12 MB');
    assert.deepEqual(progress.actions.map((a) => a.id), ['cancel']);
    assert.equal(plain(progress.notes[0].text),
        'Keep this page open until the download finishes: the file is coming straight from Mei’s computer.');
    const resuming = api.downloadView({ ...base, state: 'progress',
        detail: { received: 4_500_000, size: 12_400_000, resuming: 'connecting' } });
    assert.equal(resuming.progress.text, '4.5 MB of 12 MB', 'the progress stays');
    assert.equal(plain(resuming.notes[0].text),
        'The connection to Mei dropped. Reconnecting to carry on from where it stopped…');
    const waiting = api.downloadView({ ...base, state: 'progress',
        detail: { received: 4_500_000, size: 12_400_000, resuming: 'waiting' } });
    assert.equal(plain(waiting.notes[0].text), 'Waiting for Mei to come back online. The download will carry on '
        + 'from where it stopped. Keep this page open.');
    assert.deepEqual(waiting.actions.map((a) => a.id), ['cancel']);
    const file = api.downloadView({ ...base, state: 'done', sink: { kind: 'file' } });
    assert.equal(plain(file.lead), 'Site photos.pdf is saved where you chose.');
    const stream = api.downloadView({ ...base, state: 'done', sink: { kind: 'stream' } });
    assert.equal(plain(stream.lead), 'Your browser has saved Site photos.pdf.');
    const memory = api.downloadView({ ...base, state: 'done', sink: { kind: 'memory', url: 'blob:x' } });
    assert.deepEqual(memory.actions.map((a) => [a.label, a.href, a.download]), [['Save file', 'blob:x',
        'Site photos.pdf']]);
});

test('sizes read as people expect', () => {
    assert.deepEqual([0, 1, 999, 1000, 999_999, 12_400_000, 5e9].map(api.formatBytes),
        ['0 bytes', '1 byte', '999 bytes', '1.0 KB', '1.0 MB', '12 MB', '5.0 GB']);
});
