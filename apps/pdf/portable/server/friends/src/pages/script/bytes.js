// Shenzhen Friends link pages, part 1 of 8: bytes, base64url and the link payloads (PROTOCOL.md § Links).
//
// The parts in src/pages/script/ are joined in order into the one script the pages load (link-pages.js); they share
// one function scope, so each part's top-level names are visible to the later parts. Nothing here touches the page.

const LINK_SCRIPT_TEXT = new TextEncoder();
const LINK_NAME_DECODER = new TextDecoder('utf-8', { fatal: true });
const LINK_MAX_FRAGMENT = 512;
const LINK_FRIENDS_ID = /^[a-z]{3,8}(-[a-z]{3,8}){1,2}$/;
const LINK_B64URL = /^[A-Za-z0-9_-]*$/;
const LINK_CONTROL = /\p{Cc}/u;
// Invisible format characters the helper strips from names (SZFriendsIsStrippedCharacter): every bidi control (which
// could make "…\u202Efdp.exe" read as "…exe.pdf"), the zero-width space, the word joiner, byte-order marks and the
// interlinear annotation marks.
const LINK_STRIPPED = /[\u061C\u200B\u200E\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF\uFFF9-\uFFFB]/gu;
const LINK_DOWNLOAD_BYTES = 49;
const TWO_POW_32 = 4294967296;

function utf8(text) {
    return LINK_SCRIPT_TEXT.encode(text);
}

function concatBytes(...parts) {
    let length = 0;
    for (const part of parts) length += part.length;
    const out = new Uint8Array(length);
    let at = 0;
    for (const part of parts) {
        out.set(part, at);
        at += part.length;
    }
    return out;
}

function bytesEqual(a, b) {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i];
    return diff === 0;
}

function b64uEncode(bytes) {
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// Unpadded base64url that decodes canonically: no `=`, no length of 1 mod 4, unused trailing bits zero (checked by
// encoding the result again). Anything else is null.
function b64uDecode(text) {
    if (typeof text !== 'string' || !LINK_B64URL.test(text) || text.length % 4 === 1) return null;
    let binary;
    try {
        binary = atob(text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (text.length % 4)) % 4));
    } catch {
        return null;
    }
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return b64uEncode(bytes) === text ? bytes : null;
}

function randomBytes(env, length) {
    const bytes = new Uint8Array(length);
    env.crypto.getRandomValues(bytes);
    return bytes;
}

// 64-bit big-endian unsigned integers as plain numbers up to 2^53 - 1, never through 32-bit operators, so sizes and
// counters past 4 GiB stay exact.
function writeU64(bytes, at, value) {
    const high = Math.floor(value / TWO_POW_32);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    view.setUint32(at, high);
    view.setUint32(at + 4, value - high * TWO_POW_32);
}

function readU32(bytes, at) {
    return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(at);
}

// A person's name as the links carry it (PROTOCOL.md § Links): UTF-8 without control characters, or null. A name
// of only spaces counts as none, so the page words itself as for a link without a name.
function decodeName(bytes) {
    let name;
    try {
        name = LINK_NAME_DECODER.decode(bytes);
    } catch {
        return null;
    }
    if (LINK_CONTROL.test(name)) return null;
    return plainName(name);
}

// A name or file name from someone else, as the page shows and saves it: without the characters above.
function plainName(text) {
    return String(text).replace(LINK_STRIPPED, '').trim();
}

function lengthPrefixed(bytes, at, min, max) {
    if (at >= bytes.length) return null;
    const length = bytes[at];
    if (length < min || length > max || at + 1 + length > bytes.length) return null;
    return { value: bytes.subarray(at + 1, at + 1 + length), next: at + 1 + length };
}

// The fragment of /f or /d (without `#`), checked as strictly as the apps check it. A download link is the version,
// the link id and the secret, exactly 49 bytes (PROTOCOL.md § Links): the sender's name comes only inside the sealed
// metadata.
function parseLinkPayload(kind, fragment) {
    if (typeof fragment !== 'string' || fragment.length === 0 || fragment.length > LINK_MAX_FRAGMENT) return null;
    const bytes = b64uDecode(fragment);
    if (!bytes || bytes[0] !== 0x01) return null;
    if (kind === 'd') {
        if (bytes.length !== LINK_DOWNLOAD_BYTES) return null;
        return { kind, linkId: bytes.slice(1, 17), secret: bytes.slice(17, 49), name: '', appPayload: `d.${fragment}` };
    }
    if (kind !== 'f' || bytes.length < 51) return null;
    const id = lengthPrefixed(bytes, 49, 3, 64);
    if (!id) return null;
    let friendsId = '';
    for (const byte of id.value) friendsId += String.fromCharCode(byte);
    if (!LINK_FRIENDS_ID.test(friendsId)) return null;
    const nameField = lengthPrefixed(bytes, id.next, 0, 160);
    if (!nameField || nameField.next !== bytes.length) return null;
    const name = decodeName(nameField.value);
    if (name === null) return null;
    return { kind, friendsId, name, appPayload: `f.${fragment}` };
}

// Every app that opens these links, in the order the pages offer them, and the URL scheme each registers.
const LINK_APP_SCHEMES = Object.freeze({ pdf: 'shenzhenpdf', files: 'shenzhenfiles', '3d': 'shenzhen3d' });
const LINK_APPS = Object.freeze(Object.keys(LINK_APP_SCHEMES));

// What the page's Open buttons open: the app's own scheme with the same payload (PROTOCOL.md § Links).
function appLinkUrl(app, link) {
    return `${LINK_APP_SCHEMES[app] ?? LINK_APP_SCHEMES.pdf}://friends/link#${link.appPayload}`;
}
