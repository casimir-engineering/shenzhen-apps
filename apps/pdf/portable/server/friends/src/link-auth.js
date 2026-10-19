// The key exchange and message authentication on host links (HOST-PROTOCOL.md § Host links). The handshake proves
// each host to the other, but TLS alone protected everything after it: whoever could intercept TLS between a replica
// and the main host (a mis-issued certificate for the main host's name) could relay the handshake and then inject or
// rewrite reservation answers, which the replica signs for its helpers, and ID-table rows, which a promoted replica
// would allocate from.
//
// Each link has its own secret. The replica's host_hello and the main host's host_welcome each carry a key share, a
// fresh X25519 public key, under that host's signature by the key the signed list gives it; the welcome's signature
// covers both shares. The link key is HKDF-SHA256 of the X25519 shared secret, salted with the replica secret, with the
// whole handshake as info. The private halves live only in the two hosts' memory until the key is derived, so no one
// else can compute it: not an interceptor, and not another replica, although every replica holds the replica secret
// and can see the rest of the handshake. Swapping a share breaks a host-key signature. Before key shares the key came
// from the replica secret and the handshake's public values alone, so any replica that could intercept TLS between
// another replica and the main host could compute that link's key and inject messages into it.
//
// Every message after the handshake travels as {type: 'link', v, seq, body, mac}: `body` is the message's own JSON
// text, and `mac` is HMAC-SHA256 under the link key of length-prefixed (direction, seq, body). Each direction numbers
// its messages from 1 and the receiver accepts only the next number, so nothing can be dropped, replayed, reordered or
// reflected back to its sender. The caller drops the link on any failure; no secret travels. Messages are not
// encrypted here: TLS keeps them from onlookers.

import crypto from 'node:crypto';

import { decodeBase64url, encodeBase64url, hmacSha256, safeEqual } from './keys.js';
import { hostLinkKeyInfo, lengthPrefixed, message } from './protocol.js';

const DIRECTIONS = Object.freeze({ main: 'main to replica', replica: 'replica to main' });
const KEY_BYTES = 32;

// A fresh X25519 key pair for one link: `share` is the raw 32-byte public key that travels in the handshake.
export function newKeyShare() {
    const { privateKey, publicKey } = crypto.generateKeyPairSync('x25519');
    return { privateKey, share: Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url') };
}

// X25519 of our private key and the other side's share, or null when the share is not a usable public key. OpenSSL
// already refuses a low-order share, whose shared secret is all zeros and so known to everyone; the explicit check
// keeps that true whatever library is underneath.
export function sharedSecret(privateKey, peerShare) {
    if (!Buffer.isBuffer(peerShare) || peerShare.length !== KEY_BYTES) return null;
    try {
        const publicKey = crypto.createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: encodeBase64url(peerShare) },
            format: 'jwk' });
        const shared = crypto.diffieHellman({ privateKey, publicKey });
        return shared.some((byte) => byte !== 0) ? shared : null;
    } catch {
        return null;
    }
}

// `transcript` is {mainHostId, replicaHostId, challenge, nonce, replicaShare, mainShare}.
export function linkKey({ secret, shared, transcript }) {
    return Buffer.from(crypto.hkdfSync('sha256', shared, secret, hostLinkKeyInfo(transcript), KEY_BYTES));
}

export class LinkAuth {
    // One end of a link once both shares are known. `side` is 'main' or 'replica', `privateKey` that side's own
    // X25519 key from newKeyShare. Null when the other side's share is unusable, which only a broken or hostile host
    // that signed it could send.
    static derive({ secret, side, privateKey, transcript }) {
        if (!DIRECTIONS[side]) throw new Error(`unknown link side ${side}`);
        const shared = sharedSecret(privateKey, side === 'main' ? transcript.replicaShare : transcript.mainShare);
        return shared ? new LinkAuth(linkKey({ secret, shared, transcript }), side) : null;
    }

    constructor(key, side) {
        if (!DIRECTIONS[side]) throw new Error(`unknown link side ${side}`);
        this.key = key;
        this.sending = DIRECTIONS[side];
        this.receiving = DIRECTIONS[side === 'main' ? 'replica' : 'main'];
        this.sent = 0;
        this.received = 0;
    }

    mac(direction, seq, body) {
        return hmacSha256(this.key, lengthPrefixed([direction, String(seq), body]));
    }

    // The envelope text for the next message from this side.
    wrap(type, fields = {}) {
        this.sent += 1;
        const body = message(type, fields);
        return message('link', { seq: this.sent, body, mac: encodeBase64url(this.mac(this.sending, this.sent, body)) });
    }

    // The message inside `envelope` when it is the next authentic one from the other side, else null.
    unwrap(envelope) {
        if (!envelope || envelope.type !== 'link' || typeof envelope.body !== 'string'
            || envelope.seq !== this.received + 1) {
            return null;
        }
        const mac = decodeBase64url(envelope.mac, 32);
        if (!mac || !safeEqual(mac, this.mac(this.receiving, envelope.seq, envelope.body))) return null;
        let inner;
        try {
            inner = JSON.parse(envelope.body);
        } catch {
            return null;
        }
        if (!inner || typeof inner !== 'object' || typeof inner.type !== 'string' || inner.type === 'link') return null;
        this.received = envelope.seq;
        return inner;
    }
}
