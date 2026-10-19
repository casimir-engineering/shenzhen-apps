// Which person a checking-in device speaks for (HOST-PROTOCOL.md § Devices). A protocol 3 helper checks in with its
// own device key, names the person's root key, and brings the person's device chain as proof that the root added it
// and has not revoked it. The Friends ID, the statistics' people and the rendezvous key all belong to the root; the
// connection, its budgets and its records' signatures to the device. A helper before protocol 3, and the first device
// of a person with no chain to show, is its own root.
//
// The host reads the chain, keeps the revocations it carries (device-records.js) and forgets the rest: a revoked
// device that still holds a chain from before its revocation is refused here once any of the person's devices has
// checked in with a newer one.

import { CHAIN_LIMITS, deviceState, readChain } from './device-chain.js';
import { forgetRevocation, noteRevocations, revocationFor } from './device-records.js';
import { decodeBase64url, identityHash } from './keys.js';
import { DEVICES_PROTOCOL } from './protocol.js';

// `deviceKey`, `rootKey` (null before protocol 3) and `chain` (bytes or null) come from a check-in whose signature
// verified. Returns { ok: true, personKey, personHash, deviceHash, revoked, others } where `revoked` lists the device
// hashes this chain revoked that the host had not seen revoked before and `others` counts the devices besides this one
// the chain authorizes; or { ok: false, error } with bad_chain or device_revoked.
export function admitDevice({ db, secret, deviceKey, rootKey, chain, day, count }) {
    const personKey = rootKey ?? deviceKey;
    const personHash = identityHash(secret, personKey);
    const deviceHash = identityHash(secret, deviceKey);
    let read = null;
    if (chain) {
        read = readChain(chain, personKey);
        if (!read.ok) return { ok: false, error: 'bad_chain' };
        const state = deviceState(read, deviceKey);
        if (state === 'revoked') return { ok: false, error: 'device_revoked' };
        if (state !== 'authorized') return { ok: false, error: 'bad_chain' };
    } else if (!personKey.equals(deviceKey)) {
        return { ok: false, error: 'bad_chain' };
    }
    // A revocation seen before: this chain must hold it. If it does and still authorizes the device, the rules made
    // that revocation void (a concurrent revocation removed its signer), so it is forgotten.
    const known = revocationFor(db, { identityHash: personHash, deviceHash });
    if (known) {
        if (!read?.linkHashes.has(known.toString('hex'))) return { ok: false, error: 'device_revoked' };
        forgetRevocation(db, { identityHash: personHash, deviceHash });
    }
    const revoked = read ? [...read.devices.values()].filter((d) => d.state === 'revoked')
        .map((d) => ({ deviceHash: identityHash(secret, d.deviceKey), linkHash: d.revokedBy[0] })) : [];
    const fresh = noteRevocations(db, { identityHash: personHash, revoked, day, count });
    const others = read ? [...read.devices.values()]
        .filter((d) => d.state === 'authorized' && !d.deviceKey.equals(deviceKey)).length : 0;
    return { ok: true, personKey, personHash, deviceHash, revoked: fresh, others };
}

// A check-in's device fields (HOST-PROTOCOL.md § Devices): from protocol 3, `root_key` and, unless the device is the
// root itself, `chain`. Null when they are malformed; empty before protocol 3, where the device is its own root.
export function parseDevices(msg) {
    if (!Number.isSafeInteger(msg.protocol) || msg.protocol < DEVICES_PROTOCOL) return {};
    const rootKey = decodeBase64url(msg.root_key, 32);
    const chain = msg.chain === undefined || msg.chain === null ? null : decodeBase64url(msg.chain);
    if (!rootKey || (msg.chain !== undefined && msg.chain !== null && !chain)) return null;
    if (chain && (chain.length < 3 || chain.length > CHAIN_LIMITS.encodedMax)) return null;
    return { rootKey, chain };
}
