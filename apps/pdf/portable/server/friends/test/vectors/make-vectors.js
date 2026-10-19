#!/usr/bin/env node
// Writes host-list-v1.json: interop vectors for the host list, the check-in and release signatures and the host's
// signed replies, shared by
// this package's tests and the helper's (portable/friends/service/host/tests). Ed25519 signatures are
// deterministic, so the same seeds always give the same file; vectors.test.js regenerates it and fails on any
// difference, which catches a change to the signed formats on either side.
//
// TEST ONLY: every key here comes from a public seed. `friends-hostlist release-check` refuses all of them.
//
//   node test/vectors/make-vectors.js [--write]

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { signAttestation } from '../../src/attestation.js';
import { signPayload } from '../../src/hostlist.js';
import { encodeBase64url, privateKeyFromSeed, rawPublicKey, signEd25519 } from '../../src/keys.js';
import {
    attestationSignedBytes, checkinSignedBytes, hostReplySignedBytes, lengthPrefixed, releaseSignedBytes, releasedBody,
    reserveResultBody, welcomeBody,
} from '../../src/protocol.js';

export const VECTORS_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), 'host-list-v1.json');

function seed(label) {
    return crypto.createHash('sha256').update(`SZFriends TEST vector seed: ${label}`).digest();
}

function key(label) {
    const s = seed(label);
    const privateKey = privateKeyFromSeed(s);
    return { seed: s.toString('hex'), public_key: encodeBase64url(rawPublicKey(privateKey)), privateKey };
}

function hosts(keys) {
    return [
        { id: 'main-hk', role: 'both', urls: ['wss://friends.example.test/v1'], turn_uris: [], region: 'Hong Kong',
            priority: 1, public_key: keys.host.public_key },
        { id: 'alt-sg', role: 'rendezvous', urls: ['wss://alt.example.test/v1', 'ws://127.0.0.1:9/v1'],
            region: 'Singapore', priority: 2, public_key: keys.other.public_key },
    ];
}

function tamper(envelope) {
    const bytes = Buffer.from(envelope.payload, 'base64url');
    const text = bytes.toString('utf8').replace('"version":3', '"version":9');
    return { ...envelope, payload: Buffer.from(text, 'utf8').toString('base64url') };
}

// signPayload validates its input, which the invalid-payload vectors must bypass to test the parsers.
function signRaw(payload, signer) {
    const bytes = Buffer.from(JSON.stringify(payload), 'utf8');
    const signed = Buffer.concat([Buffer.from('SZFriends host list v1\n', 'utf8'), bytes]);
    const sig = encodeBase64url(signEd25519(signer, signed));
    return { payload: encodeBase64url(bytes), sigs: [{ key: 'primary', sig }] };
}

export function makeVectors() {
    const keys = Object.fromEntries(['primary', 'backup', 'other', 'host', 'identity'].map((n) => [n, key(n)]));
    const payload = { version: 3, issued_at: '2026-10-12T06:00:00Z', new_id_words: 2, hosts: hosts(keys) };
    const primary = { name: 'primary', privateKey: keys.primary.privateKey };
    const backup = { name: 'backup', privateKey: keys.backup.privateKey };
    const valid = signPayload(payload, [primary]);
    const expected = { version: 3, new_id_words: 2, issued_at: payload.issued_at,
        hosts: payload.hosts.map(({ id, role, urls, region, priority, public_key: pk }) => ({ id, role, urls, region,
            priority, public_key: pk })) };
    const lists = [
        { name: 'signed by primary', valid: true, envelope: valid, expected },
        { name: 'signed by backup', valid: true, envelope: signPayload(payload, [backup]), expected },
        { name: 'signed by both', valid: true, envelope: signPayload(payload, [primary, backup]), expected },
        { name: 'three words for new IDs', valid: true,
            envelope: signPayload({ ...payload, version: 4, new_id_words: 3 }, [primary]),
            expected: { ...expected, version: 4, new_id_words: 3 } },
        { name: 'signed by a key nobody pins', valid: false,
            envelope: signPayload(payload, [{ name: 'primary', privateKey: keys.other.privateKey }]) },
        { name: 'payload changed after signing', valid: false, envelope: tamper(valid) },
        { name: 'signature missing', valid: false, envelope: { payload: valid.payload, sigs: [] } },
        { name: 'two hosts share the lowest priority', valid: false, envelope: signRaw({ ...payload,
            hosts: payload.hosts.map((h) => ({ ...h, priority: 1 })) }, keys.primary.privateKey) },
        { name: 'cleartext URL off loopback', valid: false, envelope: signRaw({ ...payload,
            hosts: [{ ...payload.hosts[0], urls: ['ws://friends.example.test/v1'] }] }, keys.primary.privateKey) },
        { name: 'new_id_words out of range', valid: false,
            envelope: signRaw({ ...payload, new_id_words: 4 }, keys.primary.privateKey) },
        { name: 'host key of the wrong length', valid: false, envelope: signRaw({ ...payload,
            hosts: [{ ...payload.hosts[0], public_key: 'AAAA' }] }, keys.primary.privateKey) },
    ];
    const challenge = seed('challenge');
    const identityKey = Buffer.from(keys.identity.public_key, 'base64url');
    const checkinFields = { hostId: 'main-hk', challenge, identityKey, friendsId: 'maple-river', reserved: false,
        appVersion: '26.10.12-1', protocol: 1, listVersion: 3 };
    const checkinBytes = checkinSignedBytes(checkinFields);
    const releaseFields = { hostId: 'main-hk', challenge, identityKey, friendsId: 'maple-river' };
    const releaseBytes = releaseSignedBytes(releaseFields);
    const strip = (k) => ({ seed: k.seed, public_key: k.public_key });
    // Replies as the host sends them: each carries host_sig by the `host` key over the challenge and its body.
    const replies = [
        { name: 'welcome with a newer list', requested: 'maple-river',
            message: { type: 'welcome', reservation: 'reserved', friends_id: 'maple-river', update_required: true,
                host_list: valid },
            body: welcomeBody({ requested: 'maple-river', reservation: 'reserved', friendsId: 'maple-river',
                updateRequired: true, hostListPayload: valid.payload }) },
        { name: 'welcome, taken', requested: 'maple-river',
            message: { type: 'welcome', reservation: 'taken', friends_id: null, update_required: false,
                host_list: null },
            body: welcomeBody({ requested: 'maple-river', reservation: 'taken', friendsId: null,
                updateRequired: false, hostListPayload: null }) },
        { name: 'reserve_result after a collision', requested: 'maple-harbor',
            message: { type: 'reserve_result', reservation: 'reserved', friends_id: 'maple-harbor' },
            body: reserveResultBody({ requested: 'maple-harbor', reservation: 'reserved',
                friendsId: 'maple-harbor' }) },
        { name: 'released', requested: null, message: { type: 'released', released: true },
            body: releasedBody({ released: true }) },
    ].map(({ name, requested, message, body }) => {
        const signed = hostReplySignedBytes(challenge, body);
        return { name, requested, message: { ...message, v: 1,
            host_sig: encodeBase64url(signEd25519(keys.host.privateKey, signed)) },
        body_hex: lengthPrefixed(body).toString('hex'), signed_bytes_hex: signed.toString('hex') };
    });
    const attestations = makeAttestations(keys, identityKey, valid);
    return {
        comment: 'TEST VECTORS ONLY. Every key derives from a public seed; never pin one. Regenerate with '
            + 'node test/vectors/make-vectors.js --write after a deliberate change to a signed format.',
        test_public_keys: Object.values(keys).map((k) => k.public_key),
        keys: Object.fromEntries(Object.entries(keys).map(([name, k]) => [name, strip(k)])),
        pinned: [keys.primary.public_key, keys.backup.public_key],
        host_lists: lists,
        checkin: { host_id: 'main-hk', challenge: encodeBase64url(challenge), identity_key: keys.identity.public_key,
            friends_id: 'maple-river', reserved: false, app_version: '26.10.12-1', protocol: 1, list_version: 3,
            signed_bytes_hex: checkinBytes.toString('hex'),
            sig: encodeBase64url(signEd25519(keys.identity.privateKey, checkinBytes)) },
        release: { host_id: 'main-hk', challenge: encodeBase64url(challenge), identity_key: keys.identity.public_key,
            friends_id: 'maple-river', signed_bytes_hex: releaseBytes.toString('hex'),
            sig: encodeBase64url(signEd25519(keys.identity.privateKey, releaseBytes)) },
        host_replies: { host_id: 'main-hk', challenge: encodeBase64url(challenge), host_key: keys.host.public_key,
            replies },
        attestations,
    };
}

// ID attestations checked against the 'signed by primary' list (main-hk signs with `host`, alt-sg with `other`) at
// `now`, for a claimed (Friends ID, identity key). `verdict` is what both sides' checks must answer.
function makeAttestations(keys, identityKey, list) {
    const now = '2026-10-13T03:00:00Z';
    const claim = { friends_id: 'maple-river', identity_key: keys.identity.public_key };
    const sign = (hostId, signer, day, friendsId = 'maple-river') => signAttestation({ hostId,
        hostKey: signer.privateKey, friendsId, identityKey, day });
    const mainSigned = sign('main-hk', keys.host, '2026-10-12');
    const cases = [
        { name: 'signed by the main host', attestation: mainSigned, verdict: 'valid',
            signed_bytes_hex: attestationSignedBytes({ hostId: 'main-hk', friendsId: 'maple-river', identityKey,
                day: '2026-10-12' }).toString('hex') },
        { name: 'signed by a replica', attestation: sign('alt-sg', keys.other, '2026-10-13'), verdict: 'valid' },
        { name: 'thirty days old', attestation: sign('main-hk', keys.host, '2026-09-13'), verdict: 'valid' },
        { name: 'thirty-one days old', attestation: sign('main-hk', keys.host, '2026-09-12'), verdict: 'expired' },
        { name: 'dated tomorrow', attestation: sign('main-hk', keys.host, '2026-10-14'), verdict: 'valid' },
        { name: 'dated two days ahead', attestation: sign('main-hk', keys.host, '2026-10-15'), verdict: 'expired' },
        { name: 'another ID claimed', attestation: mainSigned, verdict: 'wrong_holder',
            claim: { ...claim, friends_id: 'maple-harbor' } },
        { name: 'another key claimed', attestation: mainSigned, verdict: 'wrong_holder',
            claim: { ...claim, identity_key: keys.other.public_key } },
        { name: 'signed by a key the list does not give that host',
            attestation: sign('main-hk', keys.other, '2026-10-12'), verdict: 'bad_signature' },
        { name: 'ID changed after signing', attestation: { ...mainSigned, friends_id: 'maple-harbor' },
            verdict: 'bad_signature', claim: { ...claim, friends_id: 'maple-harbor' } },
        { name: 'a host the list does not name', attestation: sign('gone-host', keys.other, '2026-10-12'),
            verdict: 'unknown_host' },
        { name: 'not a calendar day', attestation: sign('main-hk', keys.host, '2026-02-30'), verdict: 'malformed' },
        { name: 'signature missing', attestation: { ...mainSigned, sig: undefined }, verdict: 'malformed' },
    ];
    return { list, now, cases: cases.map((c) => ({ claim, ...c })) };
}

export function vectorsText() {
    return `${JSON.stringify(makeVectors(), null, 2)}\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    if (process.argv.includes('--write')) fs.writeFileSync(VECTORS_PATH, vectorsText());
    else process.stdout.write(vectorsText());
}
