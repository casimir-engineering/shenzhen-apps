// Host protocol 2, online Friends (HOST-PROTOCOL-ONLINE.md; ADR 0010): the constants, limits, signed bytes
// and validators for rendezvous records, connection setup, download links and relay credentials. Everything in
// protocol 1 stays as it is; a helper that declares protocol 2 in its check-in may also send the messages below.

import crypto from 'node:crypto';

import { decodeBase64url, hmacSha256 } from './keys.js';
import { lengthPrefixed } from './protocol.js';

// The first protocol with online Friends.
export const ONLINE_PROTOCOL = 2;

export const ONLINE_DOMAINS = Object.freeze({
    rendezvousKey: 'SZFriends rendezvous key v1',
    rendezvousRecord: 'SZFriends rendezvous record v1',
    linkIdHash: 'SZFriends link id hash v1',
    linkTombstone: 'SZFriends link tombstone v1',
    linkTombstoneKey: 'SZFriends link tombstone key v1',
    rendezvousFiller: 'SZFriends rendezvous filler v1',
});

// Every limit HOST-PROTOCOL-ONLINE.md names, in one place so the tests and the document agree.
export const ONLINE_LIMITS = Object.freeze({
    sealedRecordBytes: 512, // a record's sealed blob, exactly; lookups answer this many bytes for every key
    recordMaxTtlS: 900, // a record expires at most 15 minutes after it was published
    rdvPeriodS: 60, // lookups change only at these boundaries of host time; a record shows the period after its own
    publishesPerMinute: 10, // per identity
    lookupKeysPerMessage: 32,
    lookupKeysPer5Min: 256, // per identity, across reconnects
    payloadBytes: 4096, // a forwarded setup payload, decoded
    opensPerMinute: 30, // sig_open per identity
    opensByIdPerHour: 5,
    joinsPerHour: 40, // join requests (sig_open to.join) per device: one waiting device opens again every 100 s
    joinsPerPersonPerHour: 60, // join requests toward one person, from everyone; more reach nobody
    incomingPerMinute: 60, // sids delivered to one device from callers it has not answered lately; more are dropped
    incomingReservedPerMinute: 30, // more for callers whose opens it answered in the last 7 days
    incomingPerCallerPerMinute: 10, // per (target, caller identity)
    incomingPerPrefixPerMinute: 20, // per (target, caller address prefix: IPv4 address or IPv6 /56)
    answeredMemoryMs: 7 * 86_400_000, // how long a caller counts as answered, in memory only
    openSidsPerConnection: 16,
    sidLifetimeMs: 120_000,
    linkWaitMs: 30 * 60_000, // a download link's sid waits this long for its sender before its lifetime starts
    messagesPerSidDirection: 64,
    messagesPer10s: 200, // per connection, every online message together; check-in keeps its own budget
    relayCredentialTtlS: 300,
    relayCredentialsPerHour: 30, // per identity
    relayCredentialsPerSidEnd: 2,
    relayHeldPerIdentity: 4, // unused credentials and live allocations at once (relay-allocations.js)
    relayHeldPerGuestAddress: 4, // the same per IPv4 address or IPv6 /56, for browsers
    relayHeldPerNetwork: 12, // the same per IPv4 /24 or IPv6 /56, helpers and browsers together
    relayReservedPart: 4, // 1/4 of the relay's ports is kept for pairs of friends who answered each other lately
    relayReservedPerPair: 4, // of which one such pair holds at most 4
    linksPerIdentity: 50,
    linkMaxTtlS: 31 * 86_400,
    linkOpensPerDay: 500, // per link
    tombstonesPerMessage: 64,
    guestsPerAddressPerMinute: 10, // per IPv4 address or IPv6 /56, as every guest limit
    guestsOpenPerAddress: 4, // guest connections open at once
    heldGuestsPerAddress: 2, // of which waiting for an offline sender
    guestCredentialsPerLinkPerHour: 60,
    guestCredentialsPerAddressPerHour: 10,
    guestConnections: 200,
});

// What a helper with protocol 2 may send once it has checked in, and what a guest may send.
export const ONLINE_TYPES = new Set([
    'rdv_publish', 'rdv_lookup', 'sig_open', 'sig_msg', 'sig_close', 'relay_credentials', 'link_register',
    'link_unregister', 'link_tombstones', 'link_open',
]);

// What hosts send each other about online Friends inside the link envelope (§ Between hosts).
export const HOST_ONLINE_TYPES = new Set(['rdv_record', 'rdv_withdraw', 'link_bind', 'link_unbind', 'link_tomb',
    'sig_route', 'host_gone']);

// The name a helper's friends look it up by: one per device key. Unkeyed on purpose, since every friend holds the
// key and must be able to compute it. It lives only in memory on the hosts, never in a database or a log.
export function rendezvousKey(identityKey) {
    return crypto.createHash('sha256').update(ONLINE_DOMAINS.rendezvousKey, 'utf8').update(identityKey).digest();
}

// The 512 bytes a lookup answers for a key with no record shown: a function of the key and the period only, the same
// on every host (keyed with FRIENDS_IDENTITY_SECRET, which every host shares) and after a restart, so two lookups
// of one key in one period agree whether or not anyone is behind it, and both change at the period's end.
export function rendezvousFiller(identitySecret, rdvKey, period) {
    const key = hmacSha256(identitySecret, Buffer.from(ONLINE_DOMAINS.rendezvousFiller, 'utf8'));
    const head = Buffer.alloc(8);
    head.writeBigUInt64BE(BigInt(period));
    const blocks = [];
    for (let i = 0; blocks.length * 32 < ONLINE_LIMITS.sealedRecordBytes; i++) {
        blocks.push(hmacSha256(key, Buffer.concat([rdvKey, head, Buffer.from([i])])));
    }
    return Buffer.concat(blocks).subarray(0, ONLINE_LIMITS.sealedRecordBytes);
}

export function recordSignedBytes({ hostId, rdvKey, seq, expires, sealed }) {
    const digest = crypto.createHash('sha256').update(sealed).digest();
    return Buffer.concat([Buffer.from(ONLINE_DOMAINS.rendezvousRecord, 'utf8'),
        lengthPrefixed([hostId, rdvKey, String(seq), String(expires), digest])]);
}

// How hosts name a download link, in memory, between hosts and in the database: a keyed hash of its id, so the
// database cannot be used to find the link itself.
export function linkIdHash(identitySecret, linkId) {
    return hmacSha256(identitySecret, Buffer.concat([Buffer.from(ONLINE_DOMAINS.linkIdHash, 'utf8'),
        Buffer.from(linkId, 'utf8')])).toString('base64url');
}

// A link's tombstone hash, as the sender's helper keeps it after the link ends: SHA-256 of the domain and the link
// id's 16 bytes. The helper keeps only this; the host files it under a keyed hash of it (tombstoneKey), and computes
// the same from the link id an opener names.
export function linkTombstoneHash(linkId) {
    return crypto.createHash('sha256').update(Buffer.from(ONLINE_DOMAINS.linkTombstone, 'utf8'))
        .update(decodeBase64url(linkId, 16)).digest();
}

export function tombstoneKey(identitySecret, tombHash) {
    return hmacSha256(identitySecret, Buffer.concat([Buffer.from(ONLINE_DOMAINS.linkTombstoneKey, 'utf8'),
        tombHash])).toString('base64url');
}

// 16 random bytes, base64url: sids, link ids and relay attempt ids all have this form.
export function decodeId(value) {
    return decodeBase64url(value, 16);
}

export function newId() {
    return crypto.randomBytes(16).toString('base64url');
}

// A forwarded payload: canonical base64url of 1 to 4,096 bytes. The host never looks inside.
export function decodePayload(value) {
    const bytes = decodeBase64url(value);
    return bytes && bytes.length >= 1 && bytes.length <= ONLINE_LIMITS.payloadBytes ? bytes : null;
}

export function validReq(value) {
    return Number.isSafeInteger(value) && value >= 0 && value <= 2 ** 31;
}

// The TURN REST API scheme (draft-uberti-behave-turn-rest-00) as coturn implements it with use-auth-secret:
// username "<expiry unix seconds>:<label>", password base64(HMAC-SHA1(secret, username)). coturn refuses a username
// whose time has passed when an allocation is authenticated; refreshes of a live allocation reuse the session's key,
// so the expiry bounds when a relay may start, not how long it may run (measured, ADR 0010).
export function turnRestCredential({ secret, expires, label }) {
    const username = `${expires}:${label}`;
    const credential = crypto.createHmac('sha1', secret).update(username).digest('base64');
    return { username, credential };
}

// Whether a connection may take part in online Friends: a checked-in helper that declared protocol 2 or later.
export function speaksOnline(session) {
    return Boolean(session) && session.state === 'checked_in' && (session.declaredProtocol ?? 1) >= ONLINE_PROTOCOL;
}

// The kind of connection a sid sets up, as statistics count it. A join request is an open by Friends ID.
export function kindOf(via) {
    if (via === 'rdv') return 'helper';
    return via === 'join' ? 'id' : via;
}
