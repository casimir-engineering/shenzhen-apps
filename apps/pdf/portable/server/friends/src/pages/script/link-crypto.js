// Shenzhen Friends link pages, part 3 of 8: the download link's keys, sealed setup payloads, the proof, the sealed
// records and the metadata record (PROTOCOL.md § Links, Browser downloads). WebCrypto only: HKDF-SHA-256,
// HMAC-SHA-256, AES-256-GCM.

const LINK_LABEL = Object.freeze({
    setup: 'SZFriends link setup v1',
    proof: 'SZFriends link proof v1',
    session: 'SZFriends link session v1',
    content: 'SZFriends link content v1',
    record: 'SZFriends link record v1',
});

// Who sealed a setup payload: the opener (this page) or the sender's helper. Part of the associated data, so a
// payload is never accepted in the direction it was not sealed for.
const LINK_FROM = Object.freeze({ opener: 0x4f, sender: 0x53 });

// Record types, the first byte of every record and of its nonce.
const RECORD = Object.freeze({ meta: 0x4d, chunk: 0x43, last: 0x46, end: 0x45, control: 0x51 });
const RECORD_MAX_BYTES = 65536;
const CHUNK_BYTES = 65280;
const GCM_TAG_BYTES = 16;
const GCM_NONCE_BYTES = 12;

async function hkdf(env, ikm, salt, info) {
    const key = await env.crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
    const bits = await env.crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, 256);
    return new Uint8Array(bits);
}

function aesKey(env, raw) {
    return env.crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

// The keys a link's secret gives before any session: setup payloads sealed under `setup`, the proof under `proof`.
async function linkKeys(env, link) {
    const setup = await hkdf(env, link.secret, link.linkId, utf8(LINK_LABEL.setup));
    const proof = await hkdf(env, link.secret, link.linkId, utf8(LINK_LABEL.proof));
    return {
        setup: await aesKey(env, setup),
        proof: await env.crypto.subtle.importKey('raw', proof, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']),
    };
}

// After the challenge: setup payloads of this session, and the content key of each connection attempt, all bound to
// both sides' random values, so nothing recorded from another session opens here.
async function sessionKey(env, link, openerNonce, senderNonce) {
    return aesKey(env, await hkdf(env, link.secret, concatBytes(openerNonce, senderNonce), utf8(LINK_LABEL.session)));
}

async function contentKey(env, link, openerNonce, senderNonce, attempt) {
    const info = concatBytes(utf8(LINK_LABEL.content), Uint8Array.of(attempt));
    return aesKey(env, await hkdf(env, link.secret, concatBytes(openerNonce, senderNonce), info));
}

function setupAad(from, linkId) {
    return concatBytes(utf8(LINK_LABEL.setup), Uint8Array.of(from), linkId);
}

// A setup payload: a random 12-byte nonce, then AES-256-GCM of the message's JSON.
async function sealSetup(env, key, from, linkId, message) {
    const iv = randomBytes(env, GCM_NONCE_BYTES);
    const sealed = await env.crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: setupAad(from, linkId) },
        key, utf8(JSON.stringify(message)));
    return concatBytes(iv, new Uint8Array(sealed));
}

// The message a setup payload holds, or null when it does not open under `key` or is not a JSON object with `t`.
async function openSetup(env, key, from, linkId, bytes) {
    if (!(bytes instanceof Uint8Array) || bytes.length < GCM_NONCE_BYTES + GCM_TAG_BYTES) return null;
    try {
        const plain = await env.crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.subarray(0, GCM_NONCE_BYTES),
            additionalData: setupAad(from, linkId) }, key, bytes.subarray(GCM_NONCE_BYTES));
        const message = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plain));
        return message && typeof message === 'object' && typeof message.t === 'string' ? message : null;
    } catch {
        return null;
    }
}

// HMAC-SHA-256 over the sender's challenge: what proves to the sender that this page holds the link's secret.
async function proofMac(env, keys, link, senderNonce, openerNonce) {
    const message = concatBytes(utf8(LINK_LABEL.proof), link.linkId, senderNonce, openerNonce);
    return new Uint8Array(await env.crypto.subtle.sign('HMAC', keys.proof, message));
}

// A record's nonce: its type, three zero bytes and its index as 64 bits.
function recordNonce(type, index) {
    const nonce = new Uint8Array(GCM_NONCE_BYTES);
    nonce[0] = type;
    writeU64(nonce, 4, index);
    return nonce;
}

async function sealRecord(env, key, type, index, plain) {
    const sealed = await env.crypto.subtle.encrypt({ name: 'AES-GCM', iv: recordNonce(type, index),
        additionalData: utf8(LINK_LABEL.record) }, key, plain);
    return concatBytes(Uint8Array.of(type), new Uint8Array(sealed));
}

// The plaintext of a record of one of `types` at `index`, or null: wrong type, too long, or not authentic. The type
// byte is in the nonce, so a chunk relabelled as the last one (or the reverse) does not open.
async function openRecord(env, key, types, index, bytes) {
    if (bytes.length < 1 + GCM_TAG_BYTES || bytes.length > RECORD_MAX_BYTES || !types.includes(bytes[0])) return null;
    try {
        const plain = await env.crypto.subtle.decrypt({ name: 'AES-GCM', iv: recordNonce(bytes[0], index),
            additionalData: utf8(LINK_LABEL.record) }, key, bytes.subarray(1));
        return { type: bytes[0], plain: new Uint8Array(plain) };
    } catch {
        return null;
    }
}

// ---- the metadata record --------------------------------------------------------------------------------

const PNG_SIGNATURE = Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
const META_TEXT_MAX = 255;

function validText(value, max, allowEmpty) {
    return typeof value === 'string' && value.length <= max && (allowEmpty || value.length > 0)
        && !LINK_CONTROL.test(value);
}

// The metadata record: its JSON's length (4 bytes), the JSON, then the thumbnail's PNG bytes, if any.
function parseMeta(plain) {
    if (plain.length < 4) return null;
    const jsonLength = readU32(plain, 0);
    if (4 + jsonLength > plain.length) return null;
    let meta;
    try {
        meta = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plain.subarray(4, 4 + jsonLength)));
    } catch {
        return null;
    }
    const sha256 = meta && b64uDecode(meta.sha256);
    if (!sha256 || sha256.length !== 32 || !validText(meta.name, META_TEXT_MAX, false)
        || !Number.isSafeInteger(meta.size) || meta.size < 0
        || (meta.type !== undefined && !validText(meta.type, META_TEXT_MAX, true))
        || (meta.sender !== undefined && !validText(meta.sender, 160, true))) return null;
    const thumbnail = plain.subarray(4 + jsonLength);
    const png = thumbnail.length > PNG_SIGNATURE.length && bytesEqual(thumbnail.subarray(0, 8), PNG_SIGNATURE);
    const name = plainName(meta.name);
    if (!name) return null;
    return { name, size: meta.size, type: meta.type || 'application/octet-stream', sha256,
        sender: plainName(meta.sender ?? ''), thumbnail: png ? thumbnail.slice() : null };
}
