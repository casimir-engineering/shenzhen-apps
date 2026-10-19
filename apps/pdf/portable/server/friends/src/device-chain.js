// A person's device chain, as the host reads it at check-in (HOST-PROTOCOL.md § Devices; ADR 0012). The helper's
// SZFriendsDeviceChain is the reference: the byte format, the signatures and consents, the structure checks and the
// rules that decide which devices count are the same here, and test/vectors/device-chain-v1.json holds chains the
// helper built with the verdicts it gave them. The host reads a chain only to learn whether the device checking in
// speaks for the root, and which devices the chain revokes; it keeps neither the chain nor its names.
//
// One deliberate difference: device names and systems are checked for length and UTF-8 only, never for the helper's
// trimming rules, so the host never refuses a chain a helper would accept.

import { blake2b } from './blake2b.js';
import { verifyEd25519 } from './keys.js';

export const CHAIN_LIMITS = Object.freeze({ maxLinks: 128, encodedMax: 64_000, parentsMax: 8, labelMax: 64 });
export const KIND = Object.freeze({ genesis: 0, add: 1, revoke: 2, rename: 3 });
export const CHAIN_DOMAINS = Object.freeze({
    link: 'SZFriends chain link v1',
    consent: 'SZFriends device consent v1',
    hash: 'SZFriends chain hash v1',
});

const VERSION = 1;
const UTF8 = new TextDecoder('utf-8', { fatal: true });

// Public keys and signature R points the helper's libsodium refuses: the seven encodings of small-order points (the
// sign bit ignored) and keys that are not canonical. Node's verify takes them (the identity point verifies a trivial
// signature for any message), so without this the host would accept a consent nobody made, in a chain every helper
// refuses.
const SMALL_ORDER = [
    '0000000000000000000000000000000000000000000000000000000000000000',
    '0100000000000000000000000000000000000000000000000000000000000000',
    '26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05',
    'c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a',
    'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
    'edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
    'eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
].map((hex) => Buffer.from(hex, 'hex'));

export function hasSmallOrder(point) {
    const masked = Buffer.from(point);
    masked[31] &= 0x7f;
    return SMALL_ORDER.some((encoding) => encoding.equals(masked));
}

// libsodium's ge25519_is_canonical: the y coordinate (sign bit masked) is below 2^255 - 19.
function isCanonicalPoint(point) {
    if ((point[31] & 0x7f) !== 0x7f || point[0] < 0xed) return true;
    for (let i = 1; i < 31; i++) if (point[i] !== 0xff) return true;
    return false;
}

// Ed25519 as the helper verifies it (crypto_sign_verify_detached).
function verifiesLikeHelper(key, bytes, signature) {
    if (!key || key.length !== 32 || !signature || signature.length !== 64) return false;
    if (hasSmallOrder(key) || !isCanonicalPoint(key) || hasSmallOrder(signature.subarray(0, 32))) return false;
    return verifyEd25519(key, bytes, signature);
}

export function linkHash(encoded) {
    return blake2b(Buffer.concat([Buffer.from(CHAIN_DOMAINS.hash, 'utf8'), encoded]), 32);
}

export function consentSignedBytes(rootKey, deviceKey, staticKey) {
    return Buffer.concat([Buffer.from(CHAIN_DOMAINS.consent, 'utf8'), rootKey, deviceKey, staticKey]);
}

export function linkSignedBytes(rootKey, body) {
    return Buffer.concat([Buffer.from(CHAIN_DOMAINS.link, 'utf8'), rootKey, body]);
}

class Refused extends Error {
    constructor(reason) {
        super(reason);
        this.reason = reason;
    }
}

function reader(bytes) {
    let at = 0;
    return {
        take(count) {
            if (bytes.length - at < count) throw new Refused('malformed');
            const out = bytes.subarray(at, at + count);
            at += count;
            return out;
        },
        label() {
            const length = this.take(1)[0];
            if (length === 0 || length > CHAIN_LIMITS.labelMax) throw new Refused('malformed');
            try {
                UTF8.decode(this.take(length));
            } catch {
                throw new Refused('malformed');
            }
        },
        get position() {
            return at;
        },
    };
}

// One link: its fields, its own signature and its consent. `rootKey` is null only for the first link, a genesis,
// which names the root by signing itself.
function parseLink(encoded, rootKey) {
    const r = reader(encoded);
    const [version, kind] = r.take(2);
    const milliseconds = r.take(8).readBigUInt64BE();
    const count = r.take(1)[0];
    if (version !== VERSION || kind > KIND.rename) throw new Refused('malformed');
    const genesis = kind === KIND.genesis;
    if (genesis ? count !== 0 : count === 0 || count > CHAIN_LIMITS.parentsMax) throw new Refused('malformed');
    const parents = [];
    for (let i = 0; i < count; i++) {
        const parent = Buffer.from(r.take(32));
        if (parents.some((p) => p.equals(parent))) throw new Refused('malformed');
        parents.push(parent);
    }
    const signer = Buffer.from(r.take(32));
    const subject = Buffer.from(r.take(32));
    const carriesKeys = genesis || kind === KIND.add;
    const staticKey = carriesKeys ? Buffer.from(r.take(32)) : null;
    if (kind !== KIND.revoke) {
        r.label();
        r.label();
    }
    const consent = carriesKeys ? r.take(64) : null;
    const body = encoded.subarray(0, r.position);
    const signature = r.take(64);
    if (r.position !== encoded.length) throw new Refused('malformed');
    if ((genesis || kind === KIND.rename) && !signer.equals(subject)) throw new Refused('unauthorized');
    const root = genesis ? signer : rootKey;
    if (!root) throw new Refused('malformed');
    if (genesis && rootKey && !rootKey.equals(signer)) throw new Refused('wrong_root');
    if (!verifiesLikeHelper(signer, linkSignedBytes(root, body), signature)
        || (consent && !verifiesLikeHelper(subject, consentSignedBytes(root, subject, staticKey), consent))) {
        throw new Refused('forged');
    }
    return { kind, parents, signer, subject, staticKey, milliseconds, encoded, hash: linkHash(encoded) };
}

function addsSubject(link, key) {
    return (link.kind === KIND.genesis || link.kind === KIND.add) && link.subject.equals(key);
}

// The helper's structure checks, on links in the order they arrived: parents before children, one genesis, every
// signer added among the links it saw, revocations of added devices only, no revoked device added again, one static
// key per device.
function checkStructure(input) {
    if (input[0].kind !== KIND.genesis) throw new Refused('malformed');
    const indexOf = new Map();
    const staticOf = new Map();
    input.forEach((link, i) => {
        const hex = link.hash.toString('hex');
        if (i > 0 && link.kind === KIND.genesis) throw new Refused('wrong_root');
        if (indexOf.has(hex)) throw new Refused('malformed');
        const seen = new Set();
        for (const parent of link.parents) {
            const p = indexOf.get(parent.toString('hex'));
            if (p === undefined) throw new Refused('malformed');
            seen.add(p);
            for (const a of input[p].seen) seen.add(a);
        }
        if (link.staticKey) {
            const known = staticOf.get(link.subject.toString('hex'));
            if (known && !known.equals(link.staticKey)) throw new Refused('malformed');
            staticOf.set(link.subject.toString('hex'), link.staticKey);
        }
        if (i > 0) {
            const before = [...seen].map((a) => input[a]);
            if (!before.some((l) => addsSubject(l, link.signer))) throw new Refused('unauthorized');
            if (link.kind === KIND.revoke && !before.some((l) => addsSubject(l, link.subject))) {
                throw new Refused('malformed');
            }
            const revokedBefore = before.some((l) => l.kind === KIND.revoke && l.subject.equals(link.subject));
            if (link.kind === KIND.add && revokedBefore) throw new Refused('revoked_device');
        }
        link.seen = seen;
        indexOf.set(hex, i);
    });
}

// Kahn's order, smallest hash first among the links whose parents are placed, as the helper encodes a chain; then
// each link's ancestors as indexes into that order.
function canonicalOrder(input) {
    const waiting = [...input].sort((a, b) => Buffer.compare(a.hash, b.hash));
    const placed = new Set();
    const ordered = [];
    while (waiting.length > 0) {
        const next = waiting.findIndex((link) => link.parents.every((p) => placed.has(p.toString('hex'))));
        if (next < 0) throw new Refused('malformed');
        const [link] = waiting.splice(next, 1);
        placed.add(link.hash.toString('hex'));
        ordered.push(link);
    }
    const indexOf = new Map();
    ordered.forEach((link, i) => {
        const ancestors = new Set();
        for (const parent of link.parents) {
            const p = indexOf.get(parent.toString('hex'));
            ancestors.add(p);
            for (const a of ordered[p].ancestors) ancestors.add(a);
        }
        link.ancestors = ancestors;
        indexOf.set(link.hash.toString('hex'), i);
    });
    return ordered;
}

// ---- the rules (SZFriendsDeviceChainRules.m) ------------------------------------------------------------------

function derivesUnseen(device, origin, r, links) {
    const reached = new Set([device.toString('hex')]);
    const frontier = [device];
    const originHex = origin.toString('hex');
    while (frontier.length > 0) {
        const current = frontier.pop();
        if (current.toString('hex') === originHex) return true;
        links.forEach((add, a) => {
            if (add.kind !== KIND.add || !add.subject.equals(current)) return;
            if (a === r || links[r].ancestors.has(a)) return;
            const hex = add.signer.toString('hex');
            if (!reached.has(hex)) {
                reached.add(hex);
                frontier.push(add.signer);
            }
        });
    }
    return false;
}

function staticallyCountedRevocations(links) {
    const counted = new Set();
    links.forEach((revocation, r) => {
        if (revocation.kind !== KIND.revoke) return;
        const voided = links.some((other, o) => o !== r && other.kind === KIND.revoke
            && other.subject.equals(revocation.signer) && !other.ancestors.has(r)
            && !derivesUnseen(other.signer, revocation.subject, r, links));
        if (!voided) counted.add(r);
    });
    return counted;
}

function hadCountedAdd(signer, seen, links, effective) {
    for (const a of seen) {
        const link = links[a];
        if (effective.has(a) && link.kind !== KIND.revoke && link.kind !== KIND.rename && link.subject.equals(signer)) {
            return true;
        }
    }
    return false;
}

function effectiveLinks(links, revocations) {
    const effective = new Set();
    links.forEach((link, i) => {
        if (link.kind === KIND.genesis) {
            effective.add(i);
            return;
        }
        if (link.kind === KIND.revoke || !hadCountedAdd(link.signer, link.ancestors, links, effective)) return;
        const missed = [...revocations].some((r) => links[r].subject.equals(link.signer) && !links[r].ancestors.has(i));
        if (!missed) effective.add(i);
    });
    return effective;
}

function revocationStands(r, links, revocations, effective) {
    const revocation = links[r];
    if (!hadCountedAdd(revocation.signer, revocation.ancestors, links, effective)) return false;
    return ![...revocation.ancestors].some((e) => revocations.has(e) && links[e].subject.equals(revocation.signer));
}

// Every device the chain names: 'authorized', 'revoked' (with the hashes of the revocations that count) or 'void'
// (added only by links that do not count).
function applyRules(links) {
    const revocations = staticallyCountedRevocations(links);
    let effective;
    for (;;) {
        effective = effectiveLinks(links, revocations);
        const dropped = [...revocations].filter((r) => !revocationStands(r, links, revocations, effective));
        if (dropped.length === 0) break;
        for (const r of dropped) revocations.delete(r);
    }
    const devices = new Map();
    links.forEach((link, i) => {
        const hex = link.subject.toString('hex');
        if (link.kind === KIND.genesis || link.kind === KIND.add) {
            const device = devices.get(hex) ?? { deviceKey: link.subject, state: 'void', revokedBy: [] };
            if (effective.has(i) && device.state === 'void') device.state = 'authorized';
            devices.set(hex, device);
        }
    });
    links.forEach((link, r) => {
        if (link.kind !== KIND.revoke || !revocations.has(r)) return;
        const device = devices.get(link.subject.toString('hex'));
        device.state = 'revoked';
        device.revokedBy.push(link.hash);
    });
    for (const device of devices.values()) device.revokedBy.sort(Buffer.compare);
    return devices;
}

// Reads a chain the way the helper's +chainWithData:expectedRootKey:error: does. `expectedRoot` (32 bytes), when
// given, must be the chain's root. Returns { ok: true, rootKey, genesisHash, linkCount, linkHashes (hex), devices }
// or { ok: false, error } with one of malformed, forged, unauthorized, revoked_device, wrong_root, full.
export function readChain(bytes, expectedRoot = null) {
    try {
        if (!Buffer.isBuffer(bytes) || bytes.length < 3 || bytes.length > CHAIN_LIMITS.encodedMax
            || bytes[0] !== VERSION) {
            throw new Refused('malformed');
        }
        const count = bytes.readUInt16BE(1);
        if (count === 0 || count > CHAIN_LIMITS.maxLinks) throw new Refused('full');
        let at = 3;
        let root = expectedRoot;
        const input = [];
        for (let i = 0; i < count; i++) {
            if (bytes.length - at < 2) throw new Refused('malformed');
            const length = bytes.readUInt16BE(at);
            at += 2;
            if (bytes.length - at < length) throw new Refused('malformed');
            const link = parseLink(bytes.subarray(at, at + length), root);
            at += length;
            if (i === 0 && link.kind !== KIND.genesis) throw new Refused('malformed');
            root = root ?? link.signer;
            input.push(link);
        }
        if (at !== bytes.length) throw new Refused('malformed');
        checkStructure(input);
        const links = canonicalOrder(input);
        return { ok: true, rootKey: links[0].signer, genesisHash: links[0].hash, linkCount: links.length,
            linkHashes: new Set(links.map((l) => l.hash.toString('hex'))), devices: applyRules(links) };
    } catch (error) {
        if (error instanceof Refused) return { ok: false, error: error.reason };
        throw error;
    }
}

// The state the chain gives `deviceKey`: 'authorized', 'revoked', 'void', or 'absent' when it never names it.
export function deviceState(chain, deviceKey) {
    return chain.devices.get(deviceKey.toString('hex'))?.state ?? 'absent';
}
