// Test support: device chains built in JavaScript, in the helper's byte format (ADR 0012 § Format), so suites can make
// people with several devices, revocations, and chains the helper's builders would refuse to make. Keys come from
// one-byte TEST seeds the way test/vectors/make-chain-vectors.m makes them, so a chain built here from the same seeds,
// labels and times is byte for byte the helper's (test/device-chain.test.js checks that).

import crypto from 'node:crypto';

import { CHAIN_DOMAINS, KIND, consentSignedBytes, linkHash, linkSignedBytes } from '../src/device-chain.js';
import { encodeBase64url, privateKeyFromSeed, rawPublicKey, signEd25519 } from '../src/keys.js';

const BASE_MS = 1_791_800_000_000;

// An Ed25519 device key (with the same shape as helpers.js keyPair) and a 32-byte stand-in for its X25519 static
// key: the host never uses a static key, it only checks that the device's consent covers it.
export function device(seed) {
    const bytes = typeof seed === 'number' ? Buffer.alloc(32, seed) : seed ?? crypto.randomBytes(32);
    const privateKey = privateKeyFromSeed(bytes);
    const raw = rawPublicKey(privateKey);
    const staticKey = typeof seed === 'number' ? x25519Public(Buffer.alloc(32, (seed + 0x40) & 0xff))
        : crypto.randomBytes(32);
    return { privateKey, raw, b64: encodeBase64url(raw), staticKey };
}

// The helper's static key for a TEST seed: X25519 of the clamped private bytes, as libsodium computes it.
function x25519Public(privateBytes) {
    const prefix = Buffer.from('302e020100300506032b656e04220420', 'hex');
    const key = crypto.createPrivateKey({ key: Buffer.concat([prefix, privateBytes]), format: 'der', type: 'pkcs8' });
    return Buffer.from(crypto.createPublicKey(key).export({ format: 'jwk' }).x, 'base64url');
}

function label(text) {
    const bytes = Buffer.from(text, 'utf8');
    return Buffer.concat([Buffer.from([bytes.length]), bytes]);
}

// One signed link. `parents` are link hashes; `minute` counts from the vectors' base time.
export function signLink({ root, kind, parents = [], signer, subject, name = 'Mac', system = 'macOS 26.1',
    minute = 0, consentBy = subject }) {
    const time = Buffer.alloc(8);
    time.writeBigUInt64BE(BigInt(BASE_MS + minute * 60_000));
    const parts = [Buffer.from([1, kind]), time, Buffer.from([parents.length]), ...parents, signer.raw, subject.raw];
    const carriesKeys = kind === KIND.genesis || kind === KIND.add;
    if (carriesKeys) parts.push(subject.staticKey);
    if (kind !== KIND.revoke) parts.push(label(name), label(system));
    if (carriesKeys) {
        parts.push(signEd25519(consentBy.privateKey, consentSignedBytes(root.raw, subject.raw, subject.staticKey)));
    }
    const body = Buffer.concat(parts);
    const encoded = Buffer.concat([body, signEd25519(signer.privateKey, linkSignedBytes(root.raw, body))]);
    return { encoded, hash: linkHash(encoded), parents };
}

// The chain encoding: version, count, then each link with its length, in the given order.
export function encodeLinks(links) {
    const head = Buffer.from([1, links.length >> 8, links.length & 0xff]);
    return Buffer.concat([head, ...links.flatMap((link) => {
        const length = Buffer.alloc(2);
        length.writeUInt16BE(link.encoded.length);
        return [length, link.encoded];
    })]);
}

// The helper's canonical order: parents first, smallest hash first among the links that may come next.
export function canonical(links) {
    const waiting = [...links].sort((a, b) => Buffer.compare(a.hash, b.hash));
    const placed = new Set();
    const out = [];
    while (waiting.length > 0) {
        const next = waiting.findIndex((l) => l.parents.every((p) => placed.has(p.toString('hex'))));
        const [link] = waiting.splice(next, 1);
        placed.add(link.hash.toString('hex'));
        out.push(link);
    }
    return out;
}

// A growing chain for one person: every new link names the current heads as its parents, like the helper's builders.
export class ChainBuilder {
    constructor(root, { name = 'Mac', minute = 0 } = {}) {
        this.root = root;
        this.links = [signLink({ root, kind: KIND.genesis, signer: root, subject: root, name, minute })];
    }

    get heads() {
        const named = new Set(this.links.flatMap((l) => l.parents.map((p) => p.toString('hex'))));
        return this.links.filter((l) => !named.has(l.hash.toString('hex'))).map((l) => l.hash)
            .sort(Buffer.compare);
    }

    append(fields) {
        const link = signLink({ root: this.root, parents: this.heads, ...fields });
        this.links.push(link);
        return link;
    }

    add(subject, signer = this.root, extra = {}) {
        this.append({ kind: KIND.add, signer, subject, ...extra });
        return this;
    }

    revoke(subject, signer = this.root, extra = {}) {
        this.append({ kind: KIND.revoke, signer, subject, ...extra });
        return this;
    }

    // A copy that shares the links so far: two branches made from one chain are concurrent.
    fork() {
        const copy = Object.create(ChainBuilder.prototype);
        copy.root = this.root;
        copy.links = [...this.links];
        return copy;
    }

    merge(other) {
        const known = new Set(this.links.map((l) => l.hash.toString('hex')));
        for (const link of other.links) if (!known.has(link.hash.toString('hex'))) this.links.push(link);
        return this;
    }

    get bytes() {
        return encodeLinks(canonical(this.links));
    }

    get b64() {
        return encodeBase64url(this.bytes);
    }
}

export { CHAIN_DOMAINS, KIND };
