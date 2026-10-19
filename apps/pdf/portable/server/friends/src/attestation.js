// ID attestations (HOST-PROTOCOL.md § ID attestations). Anyone nearby who hears an Add by ID can answer it, and
// nothing offline ties a Friends ID to a key, so the requester cannot tell the ID's holder from a bystander. The
// host can: with every answer that says "reserved" it signs (host id, Friends ID, identity key, UTC day) with its
// host key. The helper keeps the newest and shows it when it answers an Add by ID; the requester checks it against
// the key the signed list gives that host, and that it is for the key it is talking to and recent.
//
// The helper has the same check (SZFriendsHostAttestationCheck in portable/friends/service/host/); the shared
// vectors in test/vectors/host-list-v1.json hold both sides to the same bytes and verdicts.

import { addDays, validDay } from './clock.js';
import { hostEntry } from './hostlist.js';
import { decodeBase64url, encodeBase64url, signEd25519, verifyEd25519 } from './keys.js';
import { attestationSignedBytes, validFriendsId, validHostId } from './protocol.js';

// An attestation stays good for this many days after the day it was signed. Every check-in brings a fresh one, so
// only someone who stopped opening ShenzhenPDF lets it lapse; an ID released and given to someone else can still be
// shown by its previous holder for at most this long.
export const ATTESTATION_MAX_AGE_DAYS = 30;

// Attestations are dated in UTC, not the statistics zone, so a helper anywhere can check the date without knowing
// the host's configuration.
export function utcDay(ms) {
    return new Date(ms).toISOString().slice(0, 10);
}

export function signAttestation({ hostId, hostKey, friendsId, identityKey, day }) {
    const sig = signEd25519(hostKey, attestationSignedBytes({ hostId, friendsId, identityKey, day }));
    return { host_id: hostId, friends_id: friendsId, identity_key: encodeBase64url(identityKey), day,
        sig: encodeBase64url(sig) };
}

// 'valid', or the first reason it is not, in this order:
// - 'malformed': not an attestation at all;
// - 'unknown_host': the host is not a rendezvous host in `list` (only those check helpers in);
// - 'bad_signature': not signed by the key `list` gives that host;
// - 'wrong_holder': a genuine attestation, for another Friends ID or another identity key than claimed;
// - 'expired': dated more than ATTESTATION_MAX_AGE_DAYS before `now`, or more than a day after it (clock skew).
export function checkAttestation(attestation, list, { friendsId, identityKey, now }) {
    const a = attestation;
    if (!a || typeof a !== 'object' || Array.isArray(a)) return 'malformed';
    const key = decodeBase64url(a.identity_key, 32);
    const sig = decodeBase64url(a.sig, 64);
    // A real calendar day only: Date.parse would take 2026-02-30 as 2 March, and the dates below compare as text.
    const realDay = validDay(a.day) && addDays(a.day, 0) === a.day;
    if (!validHostId(a.host_id) || !validFriendsId(a.friends_id) || !realDay || !key || !sig) return 'malformed';
    const entry = hostEntry(list, a.host_id);
    if (!entry || !entry.rendezvous) return 'unknown_host';
    const bytes = attestationSignedBytes({ hostId: a.host_id, friendsId: a.friends_id, identityKey: key, day: a.day });
    if (!verifyEd25519(entry.publicKey, bytes, sig)) return 'bad_signature';
    if (a.friends_id !== friendsId || !Buffer.isBuffer(identityKey) || !key.equals(identityKey)) return 'wrong_holder';
    const today = utcDay(now);
    if (a.day > addDays(today, 1) || a.day < addDays(today, -ATTESTATION_MAX_AGE_DAYS)) return 'expired';
    return 'valid';
}
