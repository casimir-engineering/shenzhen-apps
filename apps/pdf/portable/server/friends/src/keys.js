// Ed25519 and encoding helpers over node:crypto. Keys travel as raw 32-byte values in base64url, as the helper's
// libsodium keys do; node:crypto wants KeyObjects, so raw keys go through JWK, which carries exactly those bytes.

import crypto from 'node:crypto';

import { DOMAINS } from './protocol.js';

const BASE64URL = /^[A-Za-z0-9_-]*$/;

// Strict: base64url alphabet, no padding, and the exact decoded length when one is expected. Buffer.from would
// silently skip invalid characters, which would let two different strings name the same key.
export function decodeBase64url(value, expectedLength) {
    if (typeof value !== 'string' || !BASE64URL.test(value) || value.length % 4 === 1) return null;
    const bytes = Buffer.from(value, 'base64url');
    if (bytes.toString('base64url') !== value) return null;
    if (expectedLength !== undefined && bytes.length !== expectedLength) return null;
    return bytes;
}

export function encodeBase64url(bytes) {
    return Buffer.from(bytes).toString('base64url');
}

export function publicKeyObject(raw) {
    return crypto.createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: encodeBase64url(raw) }, format: 'jwk' });
}

// A 32-byte seed is what libsodium calls the secret half before expansion; the shared test vectors carry seeds
// so the helper's tests can rebuild the same keys. PKCS#8 for Ed25519 is a fixed 16-byte prefix and the seed.
const PKCS8_ED25519_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
export function privateKeyFromSeed(seed) {
    if (!seed || seed.length !== 32) throw new Error('an Ed25519 seed is 32 bytes');
    return crypto.createPrivateKey({ key: Buffer.concat([PKCS8_ED25519_PREFIX, seed]), format: 'der', type: 'pkcs8' });
}

export function rawPublicKey(keyObject) {
    const publicKey = keyObject.type === 'private' ? crypto.createPublicKey(keyObject) : keyObject;
    return Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
}

export function signEd25519(privateKey, bytes) {
    return crypto.sign(null, bytes, privateKey);
}

// False for any malformed input rather than throwing: every caller treats "cannot verify" as "invalid".
export function verifyEd25519(rawKey, bytes, signature) {
    if (!rawKey || rawKey.length !== 32 || !signature || signature.length !== 64) return false;
    try {
        return crypto.verify(null, bytes, publicKeyObject(rawKey), signature);
    } catch {
        return false;
    }
}

// What the database and the statistics use in place of an identity key (ADR 0005 § Privacy: no identity keys
// in the database). Keyed with the fleet's FRIENDS_IDENTITY_SECRET: every friend knows a person's public key, so
// an unkeyed hash would let anyone holding a copy of the database find that person's row. Every host uses the
// same secret, so the main host still counts unique users across replicas by this value.
export function identityHash(secret, identityKey) {
    return crypto.createHmac('sha256', secret).update(DOMAINS.identityHash, 'utf8').update(identityKey).digest();
}

// Proves knowledge of the identity secret without revealing it: stored in the database, so starting with another
// secret is refused instead of orphaning every row, and sent over a host link's challenge, so a replica with
// another secret is refused instead of forwarding counts under names the main host cannot match.
export function identitySecretCheck(secret, challenge = Buffer.alloc(0)) {
    return crypto.createHmac('sha256', secret).update(DOMAINS.identitySecretCheck, 'utf8').update(challenge).digest();
}

export function hmacSha256(secret, bytes) {
    return crypto.createHmac('sha256', secret).update(bytes).digest();
}

export function sha256(bytes) {
    return crypto.createHash('sha256').update(bytes).digest();
}

// Constant-time comparison of two strings or buffers of any length: hashing first makes the lengths equal, so
// timingSafeEqual neither throws nor leaks the expected length.
export function safeEqual(a, b) {
    const left = crypto.createHash('sha256').update(a).digest();
    const right = crypto.createHash('sha256').update(b).digest();
    return crypto.timingSafeEqual(left, right);
}

export function randomBytes(count) {
    return crypto.randomBytes(count);
}

export function randomId() {
    return crypto.randomBytes(6).toString('hex');
}
