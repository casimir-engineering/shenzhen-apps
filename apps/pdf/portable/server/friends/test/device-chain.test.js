// The host's reader of device chains (src/device-chain.js) against the helper's own chains and verdicts
// (test/vectors/device-chain-v1.json), and the structure rules it must enforce on chains no honest builder makes.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

import { blake2b } from '../src/blake2b.js';
import { CHAIN_LIMITS, KIND, deviceState, hasSmallOrder, linkHash, linkSignedBytes, readChain }
    from '../src/device-chain.js';
import { decodeBase64url, signEd25519 } from '../src/keys.js';
import { ChainBuilder, canonical, device, encodeLinks, signLink } from './chain-builder.js';

const vectors = JSON.parse(fs.readFileSync(new URL('./vectors/device-chain-v1.json', import.meta.url), 'utf8'));

test('BLAKE2b-256 matches the RFC 7693 test value and node:crypto at 64 bytes', async () => {
    assert.equal(blake2b(Buffer.from('abc'), 32).toString('hex'),
        'bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319');
    const crypto = await import('node:crypto');
    for (const size of [0, 1, 127, 128, 129, 1000]) {
        const data = crypto.randomBytes(size);
        assert.deepEqual(blake2b(data, 64), crypto.createHash('blake2b512').update(data).digest());
    }
});

test('every helper-built chain gets the helper verdict and device states', () => {
    for (const vector of vectors.cases) {
        const expected = vector.expected_root ? decodeBase64url(vector.expected_root, 32) : null;
        const read = readChain(decodeBase64url(vector.chain), expected);
        if (vector.error) {
            assert.deepEqual(read, { ok: false, error: vector.error }, vector.name);
            continue;
        }
        assert.equal(read.ok, true, `${vector.name}: ${read.error}`);
        assert.equal(read.rootKey.toString('hex'), vector.root, vector.name);
        assert.equal(read.genesisHash.toString('hex'), vector.genesis_hash, vector.name);
        assert.equal(read.linkCount, vector.link_hashes.length, vector.name);
        const states = Object.fromEntries([...read.devices].map(([hex, d]) => [hex, d.state]));
        assert.deepEqual(states, vector.devices, vector.name);
    }
});

test('a chain built here from the vector seeds is the helper chain byte for byte', () => {
    const [a, b] = [device(0x11), device(0x22)];
    assert.equal(a.raw.toString('hex'), vectors.keys.a);
    const chain = new ChainBuilder(a, { name: "Mei's iMac" }).add(b, a, { name: 'MacBook Air', minute: 1 });
    assert.equal(chain.b64, vectors.cases.find((c) => c.name === 'add').chain);
});

test('a revocation is reported with the hash of the link that revoked', () => {
    const [a, b] = [device(), device()];
    const chain = new ChainBuilder(a).add(b).revoke(b);
    const read = readChain(chain.bytes, a.raw);
    assert.equal(deviceState(read, b.raw), 'revoked');
    assert.deepEqual(read.devices.get(b.raw.toString('hex')).revokedBy, [chain.links[2].hash]);
    assert.equal(deviceState(read, a.raw), 'authorized');
    assert.equal(deviceState(read, device().raw), 'absent');
});

test('chains no helper builds are refused whole', () => {
    const [a, b, c] = [device(), device(), device()];
    const refused = (links, why, root = a.raw) => assert.deepEqual(readChain(encodeLinks(links), root),
        { ok: false, error: why });
    // A revoked device added again.
    const readded = new ChainBuilder(a).add(b).revoke(b);
    readded.add(b);
    refused(readded.links, 'revoked_device');
    // Signed by a device the chain never added.
    const stranger = new ChainBuilder(a);
    stranger.append({ kind: KIND.add, signer: c, subject: b });
    refused(stranger.links, 'unauthorized');
    // Someone else's device claimed: the consent is not the device's own.
    const claimed = new ChainBuilder(a);
    claimed.append({ kind: KIND.add, signer: a, subject: b, consentBy: c });
    refused(claimed.links, 'forged');
    // A second genesis (a fork of the person), a child before its parent, a parent that is missing.
    const fork = new ChainBuilder(a);
    refused([...fork.links, signLink({ root: a, kind: KIND.genesis, signer: a, subject: a, name: 'Other' })],
        'wrong_root');
    const ordered = new ChainBuilder(a).add(b).add(c, b);
    refused([ordered.links[0], ordered.links[2], ordered.links[1]], 'malformed');
    refused([ordered.links[0], ordered.links[2]], 'malformed');
    // The root it was asked for, and nothing else.
    assert.equal(readChain(ordered.bytes, b.raw).error, 'wrong_root');
    // Revoking a device the chain never added.
    const ghost = new ChainBuilder(a);
    ghost.append({ kind: KIND.revoke, signer: a, subject: c });
    refused(ghost.links, 'malformed');
    // Nothing that is not a chain.
    assert.equal(readChain(Buffer.from([2, 0, 1])).error, 'malformed');
    assert.equal(readChain(Buffer.from([1, 0, 0])).error, 'full');
    assert.equal(readChain(Buffer.alloc(CHAIN_LIMITS.encodedMax + 1, 1)).error, 'malformed');
});

test('small-order keys are refused as the helper refuses them', () => {
    // The identity point verifies a signature of R = identity, S = 0 for any message under Node's verify: an add of
    // such a "device" would carry a consent nobody made. Every helper refuses it (libsodium), so the host does too.
    const [a] = [device()];
    const identity = Buffer.alloc(32);
    identity[0] = 1;
    const trivial = Buffer.concat([identity, Buffer.alloc(32)]);
    const fake = { raw: identity, staticKey: Buffer.alloc(32, 7) };
    const genesis = new ChainBuilder(a);
    const time = Buffer.alloc(8);
    const label = (text) => Buffer.concat([Buffer.from([text.length]), Buffer.from(text)]);
    const head = genesis.links[0].hash;
    const body = Buffer.concat([Buffer.from([1, KIND.add]), time, Buffer.from([1]), head, a.raw, identity,
        fake.staticKey, label('Ghost'), label('macOS 26.1'), trivial]);
    const encoded = Buffer.concat([body, signEd25519(a.privateKey, linkSignedBytes(a.raw, body))]);
    const ghost = { encoded, hash: linkHash(encoded), parents: [head] };
    assert.ok(hasSmallOrder(identity) && !hasSmallOrder(a.raw));
    assert.deepEqual(readChain(encodeLinks([...genesis.links, ghost]), a.raw), { ok: false, error: 'forged' });
    // The sign bit does not hide it.
    const flipped = Buffer.from(identity);
    flipped[31] |= 0x80;
    assert.ok(hasSmallOrder(flipped));
});

test('arrival order does not change the verdict', () => {
    const [a, b, c] = [device(), device(), device()];
    const chain = new ChainBuilder(a).add(b).add(c, b);
    const reordered = encodeLinks([chain.links[0], ...canonical(chain.links).slice(1)]);
    assert.equal(readChain(reordered, a.raw).ok, true);
    assert.equal(deviceState(readChain(reordered, a.raw), c.raw), 'authorized');
});
