// What a replica forwards with a reservation or a release (HOST-PROTOCOL.md § Host links): the helper's own signed
// check-in or release, exactly as the helper sent it to the replica, with the replica's challenge. The main host
// verifies the helper's signature itself, for the replica's host id, and computes the identity hash from the key,
// so a compromised replica (which holds a host key and the replica secret) can act only for helpers that really
// signed to it, and can never release an ID whose owner did not ask.

import { decodeBase64url, verifyEd25519 } from './keys.js';
import { parseDevices } from './devices.js';
import { checkinSignedBytes, releaseSignedBytes, validAppVersion, validCount } from './protocol.js';

const MAX_ID_LENGTH = 64;

// Replica side: built when a helper's check-in verified on this connection.
export function checkinProof({ hostId, challenge, msg }) {
    return {
        host_id: hostId,
        challenge: challenge.toString('base64url'),
        identity_key: msg.identity_key,
        friends_id: msg.friends_id,
        reserved: msg.reserved,
        app_version: msg.app_version,
        protocol: msg.protocol,
        list_version: msg.list_version,
        // From protocol 3: the person's root key and the device chain that proves this device is theirs.
        ...(msg.root_key !== undefined ? { root_key: msg.root_key } : {}),
        ...(msg.chain !== undefined && msg.chain !== null ? { chain: msg.chain } : {}),
        sig: msg.sig,
    };
}

export function releaseProof({ hostId, challenge, msg }) {
    return { host_id: hostId, challenge: challenge.toString('base64url'), identity_key: msg.identity_key,
        friends_id: msg.friends_id, sig: msg.sig };
}

function common(proof, replicaId) {
    if (!proof || typeof proof !== 'object' || proof.host_id !== replicaId) return null;
    const challenge = decodeBase64url(proof.challenge, 32);
    const identityKey = decodeBase64url(proof.identity_key, 32);
    const signature = decodeBase64url(proof.sig, 64);
    if (!challenge || !identityKey || !signature) return null;
    if (typeof proof.friends_id !== 'string' || proof.friends_id.length > MAX_ID_LENGTH) return null;
    return { challenge, identityKey, signature };
}

// Main host side: { deviceKey, rootKey, chain } of a proof whose signature verifies, or null. The main host then
// checks the chain itself (devices.js), as the replica did.
export function verifyCheckinProof(proof, replicaId) {
    const parts = common(proof, replicaId);
    if (!parts || typeof proof.reserved !== 'boolean' || !validAppVersion(proof.app_version)
        || !validCount(proof.protocol, 1000) || proof.protocol < 1 || !validCount(proof.list_version)) {
        return null;
    }
    const devices = parseDevices(proof);
    if (!devices) return null;
    const signed = checkinSignedBytes({ hostId: replicaId, challenge: parts.challenge, identityKey: parts.identityKey,
        friendsId: proof.friends_id, reserved: proof.reserved, appVersion: proof.app_version,
        protocol: proof.protocol, listVersion: proof.list_version, ...devices });
    if (!verifyEd25519(parts.identityKey, signed, parts.signature)) return null;
    return { deviceKey: parts.identityKey, rootKey: devices.rootKey ?? null, chain: devices.chain ?? null };
}

export function verifyReleaseProof(proof, replicaId) {
    const parts = common(proof, replicaId);
    if (!parts) return null;
    const signed = releaseSignedBytes({ hostId: replicaId, challenge: parts.challenge, identityKey: parts.identityKey,
        friendsId: proof.friends_id });
    return verifyEd25519(parts.identityKey, signed, parts.signature) ? parts.identityKey : null;
}
