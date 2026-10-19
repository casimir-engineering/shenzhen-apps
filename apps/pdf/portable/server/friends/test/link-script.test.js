// The page script's parts on their own (src/pages/script/): link payloads parsed as strictly as the apps parse
// them, the incremental SHA-256, 64-bit sizes and indexes, the metadata record, and the rules that keep the script
// from fetching anything or writing markup.

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import { test } from 'node:test';

import { linkScriptSource } from '../src/link-pages.js';
import { loadLinkScript } from './link-support.js';

const api = loadLinkScript();
// The script without its comments (whole-line ones and ` // ` at a line's end), so prose never trips a check.
const codeOnly = () => linkScriptSource().replace(/^\s*\/\/.*$/gm, '').replace(/\s\/\/\s.*$/gm, '');
const b64 = (bytes) => Buffer.from(bytes).toString('base64url');

// PROTOCOL.md § Links: d. = 0x01, link id (16), secret (32), exactly 49 bytes; f. = 0x01, identity key (32), invite
// token (16), ID length and ID, name length and name.
function downloadPayload() {
    return b64(Buffer.concat([Buffer.of(1), crypto.randomBytes(48)]));
}

function friendPayload({ id = 'brave-otter', name = 'Mei', extra = Buffer.alloc(0), nameBytes } = {}) {
    const nameBuffer = nameBytes ?? Buffer.from(name);
    return b64(Buffer.concat([Buffer.of(1), crypto.randomBytes(48), Buffer.of(id.length), Buffer.from(id),
        Buffer.of(nameBuffer.length), nameBuffer, extra]));
}

// The same bytes with an unused trailing bit set: decodes, but not canonically.
function nonCanonical(text) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    return text.slice(0, -1) + alphabet[alphabet.indexOf(text.at(-1)) ^ 1];
}

test('download link payloads: exactly the version, link id and secret, 49 bytes, as the helper and apps take', () => {
    const plain = downloadPayload();
    const link = api.parseLinkPayload('d', plain);
    assert.equal(link.linkId.length, 16);
    assert.equal(link.secret.length, 32);
    assert.equal(link.name, '');
    assert.equal(api.appLinkUrl('pdf', link), `shenzhenpdf://friends/link#d.${plain}`);
    assert.equal(api.appLinkUrl('files', link), `shenzhenfiles://friends/link#d.${plain}`);
    assert.equal(api.appLinkUrl('3d', link), `shenzhen3d://friends/link#d.${plain}`);
    const bytes = Buffer.from(plain, 'base64url');
    // The form with a sender's name after the secret, once proposed, is refused like any other extra bytes.
    for (const bad of [b64(bytes.subarray(0, 48)), b64(Buffer.concat([bytes, Buffer.of(9)])),
        b64(Buffer.concat([Buffer.of(2), bytes.subarray(1)])),
        b64(Buffer.concat([bytes, Buffer.of(3), Buffer.from('Mei')])),
        b64(Buffer.concat([bytes, Buffer.of(3), Buffer.from('ab')])), `${plain}=`, plain.replace(/.$/, '+'),
        '', 'A'.repeat(513), nonCanonical(plain)]) {
        assert.equal(api.parseLinkPayload('d', bad), null, bad);
    }
    assert.equal(api.parseLinkPayload('f', plain), null, 'a download payload is not a friend link');
});

// The fixture belongs to the helper (portable/friends), outside this package. In a copy of the package alone (the
// server's `git archive` of portable/server/friends) the helper's tree is absent, so the test runs in the
// repository's suite instead; inside the repository a missing fixture still fails.
const HELPER_LINKS = new URL('../../../friends/service/links/', import.meta.url);
const STANDALONE = (process.env.FRIENDS_TEST_STANDALONE === '1' || !fs.existsSync(HELPER_LINKS))
    && 'the helper resources are outside this copy';

test('download link payloads follow the one rule the helper and the apps share (friends/service/links/tests)',
    { skip: STANDALONE }, () => {
    const fixture = JSON.parse(fs.readFileSync(new URL('tests/download-payloads.json', HELPER_LINKS), 'utf8'));
    for (const payload of fixture.accepted) {
        assert.equal(api.parseLinkPayload('d', payload.slice(2))?.appPayload, payload, payload);
    }
    for (const { payload, why } of fixture.refused) {
        assert.equal(api.parseLinkPayload('d', payload.slice(2)), null, why);
    }
});

test('friend link payloads follow PROTOCOL.md and nothing may follow the name', () => {
    const link = api.parseLinkPayload('f', friendPayload());
    assert.equal(link.name, 'Mei');
    assert.equal(link.friendsId, 'brave-otter');
    assert.match(link.appPayload, /^f\./);
    assert.equal(api.parseLinkPayload('f', friendPayload({ name: '' })).name, '', 'a link without a name');
    assert.equal(api.parseLinkPayload('f', friendPayload({ name: '<img src=x onerror=alert(1)>' })).name,
        '<img src=x onerror=alert(1)>', 'markup is only text');
    for (const bad of [friendPayload({ extra: Buffer.of(0) }), friendPayload({ id: 'Brave-Otter' }),
        friendPayload({ id: 'ab-cd' }), friendPayload({ name: 'line\nbreak' }),
        friendPayload({ nameBytes: Buffer.from([0xc3, 0x28]) }), downloadPayload()]) {
        assert.equal(api.parseLinkPayload('f', bad), null);
    }
});

test('SHA-256 chunk by chunk equals SHA-256 of the whole, whatever the chunk boundaries', () => {
    for (const size of [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 65280 * 3 + 7]) {
        const data = crypto.randomBytes(size);
        const expected = crypto.createHash('sha256').update(data).digest();
        const whole = new api.Sha256().update(new Uint8Array(data)).digest();
        assert.deepEqual(Buffer.from(whole), expected, `size ${size}`);
        const split = new api.Sha256();
        for (let at = 0; at < size;) {
            const step = 1 + Math.floor(Math.random() * 200);
            split.update(new Uint8Array(data.subarray(at, at + step)));
            at += step;
        }
        assert.deepEqual(Buffer.from(split.digest()), expected, `size ${size} in pieces`);
    }
});

test('sizes and chunk indexes past 4 GiB are exact: the hash length and the record nonce are 64-bit', () => {
    for (const bytes of [2 ** 32 + 5, 5 * 2 ** 30, 2 ** 53 - 1]) {
        const length = Buffer.from(api.sha256LengthBytes(bytes));
        assert.equal(length.readBigUInt64BE(0), BigInt(bytes) * 8n, `${bytes} bytes`);
    }
    const nonce = Buffer.from(api.recordNonce(api.RECORD.chunk, 2 ** 32 + 9));
    assert.equal(nonce[0], 0x43);
    assert.deepEqual([...nonce.subarray(1, 4)], [0, 0, 0]);
    assert.equal(nonce.readBigUInt64BE(4), 2n ** 32n + 9n);
    assert.equal(api.formatBytes(5 * 2 ** 30), '5.4 GB');
    const source = codeOnly();
    for (const name of ['received', 'nextIndex', 'byteCount', 'size']) {
        assert.doesNotMatch(source, new RegExp(`${name}\\s*(\\|=|>>>?=|<<=|\\|\\s*0)`), `${name} is never 32-bit`);
    }
});

function metaRecord(fields, thumbnail = Buffer.alloc(0)) {
    const json = Buffer.from(JSON.stringify(fields));
    const length = Buffer.alloc(4);
    length.writeUInt32BE(json.length);
    return new Uint8Array(Buffer.concat([length, json, thumbnail]));
}

test('the metadata record must name the file, its size and its SHA-256; a thumbnail must be a PNG', () => {
    const good = { name: 'Site photos.pdf', size: 5 * 2 ** 30, sha256: b64(crypto.randomBytes(32)), sender: 'Mei' };
    const png = Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), Buffer.alloc(20)]);
    const meta = api.parseMeta(metaRecord(good, png));
    assert.equal(meta.size, 5 * 2 ** 30);
    assert.equal(meta.type, 'application/octet-stream');
    assert.ok(meta.thumbnail);
    assert.equal(api.parseMeta(metaRecord(good, Buffer.from('<svg onload=alert(1)>'))).thumbnail, null);
    for (const bad of [{ ...good, size: -1 }, { ...good, size: 1.5 }, { ...good, size: 2 ** 53 },
        { ...good, sha256: b64(crypto.randomBytes(31)) }, { ...good, name: '' }, { ...good, name: 'a\u0000b' },
        { ...good, name: 'x'.repeat(256) }, { ...good, sender: 7 }, { ...good, name: '\u202E\u2066' }]) {
        assert.equal(api.parseMeta(metaRecord(bad)), null, JSON.stringify(bad));
    }
    assert.equal(api.parseMeta(new Uint8Array([0, 0, 1, 0, 1])), null, 'a length past the record');
});

test('the script fetches nothing, writes no markup and keeps no cookies', () => {
    const source = codeOnly();
    for (const banned of [/innerHTML/, /outerHTML/, /insertAdjacentHTML/, /document\.write/, /\beval\(/,
        /new Function/, /\bfetch\(/, /XMLHttpRequest/, /sendBeacon/, /EventSource/, /importScripts/, /cookie/i,
        /https?:\/\//, /location\.hash\s*=/, /history\.(push|replace)State/]) {
        assert.doesNotMatch(source, banned);
    }
    assert.equal(source.match(/new this\.env\.WebSocket\(/g).length, 1, 'one WebSocket, to the page\'s own host');
    assert.match(source,
        /wsUrl: `\$\{win\.location\.protocol === 'https:' \? 'wss' : 'ws'\}:\/\/\$\{win\.location\.host\}/);
    assert.doesNotMatch(source, /location\.hash[^;]*send|send[^;]*location\.hash/);
});

test('names lose bidi controls and other invisible format characters, so the extension shown is the real one', () => {
    const hostile = 'Invoice \u202Efdp.exe';
    const meta = api.parseMeta(metaRecord({ name: hostile, size: 1, sha256: b64(crypto.randomBytes(32)),
        sender: 'M\u200Fei\u2067' }));
    assert.equal(meta.name, 'Invoice fdp.exe', 'shown as it is: an .exe');
    assert.ok(meta.name.endsWith('.exe'));
    assert.equal(meta.sender, 'Mei');
    assert.equal(api.saveName(hostile), 'Invoice fdp.exe', 'and saved as one');
    for (const mark of ['\u061C', '\u200B', '\u200E', '\u202A', '\u202B', '\u202C', '\u202D', '\u2060', '\u2066',
        '\u2068', '\u2069', '\uFEFF', '\uFFF9', '\uFFFB']) {
        assert.equal(api.saveName(`a${mark}b.pdf`), 'ab.pdf', escape(mark));
    }
    const letters = 'Ünïcödé 文件 👩\u200D💻.pdf';
    assert.equal(api.plainName(letters), letters, 'letters and joiners stay');
    const long = `${'x'.repeat(300)}.pdf`;
    assert.equal(api.saveName(long).length, 200);
    assert.ok(api.saveName(long).endsWith('.pdf'), 'a long name is cut before its extension');
});

test('the file name offered to the browser has no path in it', () => {
    assert.equal(api.saveName('../../etc/passwd'), '_.._etc_passwd');
    assert.equal(api.saveName('...'), 'download');
    assert.equal(api.saveName('Report: Q3 <final>.pdf'), 'Report_ Q3 _final_.pdf');
    assert.equal(api.saveName('a\u0000b\nc.pdf'), 'a_b_c.pdf');
});
