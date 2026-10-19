// Host protocol: the constants and signed byte strings the service, the signing CLI and the tests share.
// HOST-PROTOCOL.md is the document. The helper declares the version it speaks as SZFriendsHostProtocolVersion in
// portable/friends/service/host/SZFriendsHostConnection.h; this host serves every version from 1 to this one on the
// same path, and the online Friends additions of version 2 are in online-protocol.js.

import crypto from 'node:crypto';

// The highest protocol this host speaks. Version 1 and 2 helpers keep working unchanged.
export const HOST_PROTOCOL_VERSION = 3;
// The first protocol in which a device checks in for a person: its own key, the person's root key and their device
// chain (devices.js; HOST-PROTOCOL.md § Devices).
export const DEVICES_PROTOCOL = 3;
// `v` in every message. Equal to the protocol version today; kept separate so a later protocol can add a message
// without changing the envelope every message shares.
export const WIRE_VERSION = 1;
export const WS_PATH = '/v1';
// A replica dials its main host at WS_PATH?link=1, which selects the host-link limits below.
export const LINK_QUERY = 'link';
// Signed host lists, and messages on host links, are at most 64 KiB (ADR 0005).
export const MAX_MESSAGE_BYTES = 64 * 1024;
// What a helper sends (checkin, reserve, release) is well under 1 KiB. ws enforces this as maxPayload on helper
// connections, across fragments, before parsing anything, so a connection can park at most 8 KiB of unfinished
// message.
export const MAX_CLIENT_MESSAGE_BYTES = 8 * 1024;
// Except a protocol 3 check-in, which carries the person's device chain (at most 64,000 bytes, so 85,334 characters
// of base64url): ws allows this much on helper connections, and every other message is held to the limit above
// (client-session.js). Host links carry such a check-in in a forwarded reservation, so they allow twice that.
export const MAX_CHECKIN_BYTES = 96 * 1024;
export const MAX_LINK_MESSAGE_BYTES = 192 * 1024;
export const CHALLENGE_BYTES = 32;
export const PING_INTERVAL_MS = 25_000;
// ADR 0005 step 4: a client draws at most 20 new IDs per connection; more is a bug or an enumeration attempt.
export const MAX_RESERVES_PER_CONNECTION = 20;
// ADR 0006 § Three-word threshold: occupancy of the two-word space at which the admin publishes new_id_words 3.
export const TWO_WORD_SPACE = 2048 * 2048;
export const THREE_WORD_THRESHOLD = TWO_WORD_SPACE / 32;

// Every signature has its own domain so one made for a check-in never verifies as a release or a host link.
// The helper signs UTF-8(domain) || message (SZFriendsIdentity -signatureForMessage:domain:).
export const DOMAINS = Object.freeze({
    checkin: 'SZFriends checkin v1',
    release: 'SZFriends release v1',
    hostLink: 'SZFriends host link v2',
    hostLinkWelcome: 'SZFriends host link welcome v2',
    hostList: 'SZFriends host list v1\n',
    hostReply: 'SZFriends host reply v1',
    identityHash: 'SZFriends identity hash v1',
    identitySecretCheck: 'SZFriends identity secret check v1',
    idAttestation: 'SZFriends id attestation v1',
    hostLinkKey: 'SZFriends host link key v2',
});

// Close codes the host sends; the helper backs off on all of them except after its own release.
export const CLOSE = Object.freeze({
    normal: 1000,
    goingAway: 1001,
    policy: 1008, // malformed message or bad signature
    tryLater: 1013, // rate limited or full
    replaced: 4000, // a newer authenticated connection for the same identity
    released: 4001, // the identity released its ID
    revoked: 4002, // this device was removed from its person's devices (protocol 3)
});

// ADR 0005: two or three lowercase words of 3 to 8 letters joined by hyphens. Syntax only, never the word list,
// so a new list version needs no host change.
const FRIENDS_ID = /^[a-z]{3,8}(-[a-z]{3,8}){1,2}$/;
export function validFriendsId(value) {
    return typeof value === 'string' && FRIENDS_ID.test(value);
}

export function friendsIdWordCount(value) {
    return value.split('-').length;
}

const HOST_ID = /^[a-z0-9][a-z0-9-]{0,31}$/;
export function validHostId(value) {
    return typeof value === 'string' && HOST_ID.test(value);
}

// App versions are shown on the dashboard, so they stay short and printable; anything else is refused rather
// than stored.
const APP_VERSION = /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,47}$/;
export function validAppVersion(value) {
    return typeof value === 'string' && APP_VERSION.test(value);
}

export function validCount(value, max = 2 ** 31 - 1) {
    return Number.isSafeInteger(value) && value >= 0 && value <= max;
}

// Fixed-order, length-prefixed encoding (u32 big-endian length, then the bytes) so no JSON canonicalisation is
// needed and no field can bleed into its neighbour.
export function lengthPrefixed(fields) {
    const parts = [];
    for (const field of fields) {
        const bytes = typeof field === 'string' ? Buffer.from(field, 'utf8') : Buffer.from(field);
        const length = Buffer.alloc(4);
        length.writeUInt32BE(bytes.length);
        parts.push(length, bytes);
    }
    return Buffer.concat(parts);
}

function withDomain(domain, message) {
    return Buffer.concat([Buffer.from(domain, 'utf8'), message]);
}

// The message a check-in signs, after its domain. Naming the host id stops one host replaying a client's
// signature to another; the challenge stops replays to the same host. From protocol 3 it also names the person's
// root key and the SHA-256 of the chain it brings (empty without one), so neither can be swapped in transit.
export function checkinMessage({ hostId, challenge, identityKey, friendsId, reserved, appVersion, protocol,
    listVersion, rootKey = null, chain = null }) {
    const fields = [hostId, challenge, identityKey, friendsId, reserved ? '1' : '0', appVersion, String(protocol),
        String(listVersion)];
    if (protocol >= DEVICES_PROTOCOL) {
        fields.push(rootKey ?? Buffer.alloc(0), chain ? crypto.createHash('sha256').update(chain).digest() : '');
    }
    return lengthPrefixed(fields);
}

export function checkinSignedBytes(fields) {
    return withDomain(DOMAINS.checkin, checkinMessage(fields));
}

export function releaseMessage({ hostId, challenge, identityKey, friendsId }) {
    return lengthPrefixed([hostId, challenge, identityKey, friendsId]);
}

export function releaseSignedBytes(fields) {
    return withDomain(DOMAINS.release, releaseMessage(fields));
}

// Host links (link-auth.js): a replica proves it holds the host key the signed list names for it, and the shared
// replica secret, over the main host's challenge, both ids, its own nonce and its key share for this link (a fresh
// X25519 public key), so nobody can swap the share without breaking the signature.
export function hostLinkSignedBytes({ mainHostId, challenge, replicaHostId, nonce, replicaShare }) {
    return withDomain(DOMAINS.hostLink, lengthPrefixed([mainHostId, challenge, replicaHostId, nonce, replicaShare]));
}

// The main host's answer proves it holds the host key the list names for the main host, over the replica's own
// nonce, before the replica takes the ID table or any answer from it. It covers both key shares, so the replica
// knows the main host's share is the main host's and that its own arrived unchanged.
export function hostLinkWelcomeSignedBytes({ mainHostId, replicaHostId, challenge, nonce, replicaShare, mainShare }) {
    return withDomain(DOMAINS.hostLinkWelcome, lengthPrefixed([mainHostId, replicaHostId, challenge, nonce,
        replicaShare, mainShare]));
}

// The HKDF info for a host link's key (link-auth.js): the whole handshake both signatures covered, so the key also
// names the link it belongs to.
export function hostLinkKeyInfo({ mainHostId, replicaHostId, challenge, nonce, replicaShare, mainShare }) {
    return withDomain(DOMAINS.hostLinkKey, lengthPrefixed([mainHostId, replicaHostId, challenge, nonce, replicaShare,
        mainShare]));
}

// An ID attestation (attestation.js): the host's statement that `friendsId` was reserved for `identityKey` on `day`
// (UTC, YYYY-MM-DD), signed with the host key the list gives `hostId`.
export function attestationSignedBytes({ hostId, friendsId, identityKey, day }) {
    return withDomain(DOMAINS.idAttestation, lengthPrefixed([hostId, friendsId, identityKey, day]));
}

export function hostListSignedBytes(payloadBytes) {
    return withDomain(DOMAINS.hostList, Buffer.from(payloadBytes));
}

// The fields of a host reply that its signature covers, in order (HOST-PROTOCOL.md § Signatures). `requested` is
// the ID the helper's message asked for, so a reply cannot be replayed as the answer to another request on the
// same connection; `hostListPayload` is the payload string of the list in a welcome, or ''.
export function welcomeBody({ requested, reservation, friendsId, updateRequired, hostListPayload }) {
    return ['welcome', requested, reservation, friendsId ?? '', updateRequired ? '1' : '0', hostListPayload ?? ''];
}

export function reserveResultBody({ requested, reservation, friendsId }) {
    return ['reserve_result', requested, reservation, friendsId ?? ''];
}

export function releasedBody({ released }) {
    return ['released', released ? '1' : '0'];
}

// The host signs its reservation answers with its host key over this connection's challenge and a digest of the
// reply's fields, so a TLS-intercepting proxy can neither forge nor replay one; the helper checks the signature
// against the public key the signed list gives this host.
export function hostReplySignedBytes(challenge, bodyFields) {
    const digest = crypto.createHash('sha256').update(lengthPrefixed(bodyFields)).digest();
    return withDomain(DOMAINS.hostReply, lengthPrefixed([challenge, digest]));
}

export function message(type, fields = {}) {
    return JSON.stringify({ type, v: WIRE_VERSION, ...fields });
}
