// The signed host list (ADR 0005 § Signed host list): verification and parsing shared by the service and the
// signing CLI. The helper implements the same rules in SZFriendsHostList; the shared vectors in
// test/vectors/host-list-v1.json keep the two in agreement.
//
// Envelope: {"payload": "<base64url of UTF-8 JSON>", "sigs": [{"key": "primary"|"backup", "sig": "..."}]}.
// Each signature is Ed25519 over "SZFriends host list v1\n" || payload bytes. Clients parse exactly the bytes that
// were signed, so nothing is ever re-serialised before verification.

import { decodeBase64url, encodeBase64url, signEd25519, verifyEd25519 } from './keys.js';
import { MAX_MESSAGE_BYTES, hostListSignedBytes, validHostId } from './protocol.js';

export const MAX_SIGNATURES = 4;
export const MAX_HOSTS = 32;
const MAX_URLS = 8;
const MAX_URL_LENGTH = 512;
const ROLES = new Set(['rendezvous', 'relay', 'both']);
const LOOPBACK_HOSTS = new Set(['127.0.0.1', '[::1]', 'localhost']);
const ISO_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;

function fail(error) {
    return { ok: false, error };
}

// wss:// anywhere; cleartext ws:// only on loopback, which is what the local test harness uses. A signed list is
// trusted, but a typo that turned production traffic into cleartext should still fail to verify.
export function validHostUrl(value) {
    if (typeof value !== 'string' || value.length > MAX_URL_LENGTH) return false;
    let url;
    try {
        url = new URL(value);
    } catch {
        return false;
    }
    if (url.username || url.password || url.hash) return false;
    if (url.protocol === 'wss:') return url.hostname.length > 0;
    return url.protocol === 'ws:' && LOOPBACK_HOSTS.has(url.hostname);
}

function validEntry(entry, index) {
    const where = `hosts[${index}]`;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return `${where} is not an object`;
    if (!validHostId(entry.id)) return `${where}.id is not a host id`;
    if (!ROLES.has(entry.role)) return `${where}.role must be rendezvous, relay or both`;
    if (!Array.isArray(entry.urls) || entry.urls.length < 1 || entry.urls.length > MAX_URLS) {
        return `${where}.urls must list 1 to ${MAX_URLS} URLs`;
    }
    if (!entry.urls.every(validHostUrl)) return `${where}.urls must be wss:// (ws:// only on loopback)`;
    const turn = entry.turn_uris ?? [];
    const shortString = (u) => typeof u === 'string' && u.length <= MAX_URL_LENGTH;
    if (!Array.isArray(turn) || turn.length > MAX_URLS || !turn.every(shortString)) {
        return `${where}.turn_uris must be a short list of strings`;
    }
    if (typeof entry.region !== 'string' || entry.region.length < 1 || entry.region.length > 64) {
        return `${where}.region must be a short string`;
    }
    if (!Number.isSafeInteger(entry.priority) || entry.priority < 1 || entry.priority > 1000) {
        return `${where}.priority must be an integer from 1 to 1000`;
    }
    if (!decodeBase64url(entry.public_key, 32)) return `${where}.public_key must be a 32-byte base64url key`;
    return null;
}

// Validates a payload object and returns the list in the shape the service uses, hosts sorted by priority then
// id. Exactly one rendezvous host may hold the lowest priority: that host is the only ID allocator, and two
// allocators could grant one ID twice.
export function validatePayload(payload) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return fail('payload is not an object');
    if (!Number.isSafeInteger(payload.version) || payload.version < 1) {
        return fail('version must be a positive integer');
    }
    if (typeof payload.issued_at !== 'string' || !ISO_TIME.test(payload.issued_at)
        || Number.isNaN(Date.parse(payload.issued_at))) {
        return fail('issued_at must be an RFC 3339 UTC time');
    }
    if (payload.new_id_words !== 2 && payload.new_id_words !== 3) return fail('new_id_words must be 2 or 3');
    if (!Array.isArray(payload.hosts) || payload.hosts.length < 1 || payload.hosts.length > MAX_HOSTS) {
        return fail(`hosts must list 1 to ${MAX_HOSTS} hosts`);
    }
    const seen = new Set();
    for (const [index, entry] of payload.hosts.entries()) {
        const problem = validEntry(entry, index);
        if (problem) return fail(problem);
        if (seen.has(entry.id)) return fail(`host id ${entry.id} appears twice`);
        seen.add(entry.id);
    }
    const hosts = payload.hosts.map((entry) => ({
        id: entry.id,
        role: entry.role,
        rendezvous: entry.role === 'rendezvous' || entry.role === 'both',
        relay: entry.role === 'relay' || entry.role === 'both',
        urls: [...entry.urls],
        turnUris: [...(entry.turn_uris ?? [])],
        region: entry.region,
        priority: entry.priority,
        publicKey: decodeBase64url(entry.public_key, 32),
    })).sort((a, b) => a.priority - b.priority || (a.id < b.id ? -1 : 1));
    const rendezvous = hosts.filter((host) => host.rendezvous);
    if (rendezvous.length === 0) return fail('no rendezvous host');
    if (rendezvous.length > 1 && rendezvous[0].priority === rendezvous[1].priority) {
        return fail('two rendezvous hosts share the lowest priority; only one host may allocate IDs');
    }
    return { ok: true, list: { version: payload.version, issuedAt: payload.issued_at, newIdWords: payload.new_id_words,
        hosts } };
}

// Verifies and parses an envelope. `pinnedKeys` are raw 32-byte public keys; one valid signature from any of them
// suffices. Freshness (only a higher version) is the caller's decision, not the parser's.
export function verifyEnvelope(input, pinnedKeys) {
    const text = Buffer.isBuffer(input) ? input.toString('utf8') : input;
    if (typeof text !== 'string' || Buffer.byteLength(text) > MAX_MESSAGE_BYTES) return fail('envelope is too large');
    let envelope;
    try {
        envelope = JSON.parse(text);
    } catch {
        return fail('envelope is not JSON');
    }
    return verifyEnvelopeObject(envelope, pinnedKeys);
}

export function verifyEnvelopeObject(envelope, pinnedKeys) {
    if (!envelope || typeof envelope !== 'object' || Array.isArray(envelope)) return fail('envelope is not an object');
    const payloadBytes = decodeBase64url(envelope.payload);
    if (!payloadBytes || payloadBytes.length === 0) return fail('payload is not base64url');
    if (!Array.isArray(envelope.sigs) || envelope.sigs.length < 1 || envelope.sigs.length > MAX_SIGNATURES) {
        return fail(`sigs must hold 1 to ${MAX_SIGNATURES} signatures`);
    }
    const signed = hostListSignedBytes(payloadBytes);
    const signedBy = [];
    for (const entry of envelope.sigs) {
        const signature = entry && typeof entry === 'object' ? decodeBase64url(entry.sig, 64) : null;
        if (!signature) return fail('a signature is malformed');
        const key = pinnedKeys.find((pinned) => verifyEd25519(pinned, signed, signature));
        if (key) signedBy.push(key);
    }
    if (signedBy.length === 0) return fail('no signature from a pinned key');
    let payload;
    try {
        payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(payloadBytes));
    } catch {
        return fail('payload is not UTF-8 JSON');
    }
    const parsed = validatePayload(payload);
    if (!parsed.ok) return parsed;
    const canonical = JSON.stringify({ payload: envelope.payload, sigs: envelope.sigs.map((s) => ({ key: s.key,
        sig: s.sig })) });
    return { ok: true, list: parsed.list, payloadBytes, envelope: canonical, signedBy };
}

// Signs a payload object with one or more {name, privateKey} signers. The payload is serialised once, here, and
// those bytes are what every client parses.
export function signPayload(payload, signers) {
    const parsed = validatePayload(payload);
    if (!parsed.ok) throw new Error(parsed.error);
    const payloadBytes = Buffer.from(JSON.stringify(payload), 'utf8');
    const signed = hostListSignedBytes(payloadBytes);
    return {
        payload: encodeBase64url(payloadBytes),
        sigs: signers.map(({ name, privateKey }) => ({ key: name, sig: encodeBase64url(signEd25519(privateKey,
            signed)) })),
    };
}

// The only ID allocator: the rendezvous host with the lowest priority (priority 1 in a normal list).
export function mainHost(list) {
    return list.hosts.find((host) => host.rendezvous) ?? null;
}

export function hostEntry(list, hostId) {
    return list.hosts.find((host) => host.id === hostId) ?? null;
}
