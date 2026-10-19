// Runs the link pages' own code (portable/server/friends/src/pages/script/) on what the helper sealed, and seals what
// the helper must open, so the two implementations of PROTOCOL.md § Links are checked against each other byte for
// byte. Usage: node link-page-vectors.mjs <pages script dir> <input JSON>; prints one JSON object.
//
// The page parts share one function scope when joined (bytes.js says so), so they run joined, in a fresh context.

import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const [dir, inputText] = process.argv.slice(2);
const input = JSON.parse(inputText);
const parts = ['bytes.js', 'sha256.js', 'link-crypto.js', 'receiver.js'];
const exported = 'b64uEncode, b64uDecode, linkKeys, sessionKey, contentKey, sealSetup, openSetup, proofMac, '
    + 'sealRecord, openRecord, parseMeta, parseLinkPayload, LINK_FROM, RECORD, Sha256, utf8';
const code = `${parts.map((part) => readFileSync(`${dir}/${part}`, 'utf8')).join('\n')}\n`
    + `globalThis.api = { ${exported} };`;
const context = vm.createContext({ TextEncoder, TextDecoder, atob, btoa, crypto: globalThis.crypto, console });
vm.runInContext(code, context);
const { api } = context;
const env = { crypto: globalThis.crypto };
const d = (text) => api.b64uDecode(text);
const e = (bytes) => api.b64uEncode(bytes);

const link = { linkId: d(input.link_id), secret: d(input.secret) };
const openerNonce = d(input.opener_nonce);
const senderNonce = d(input.sender_nonce);
const keys = await api.linkKeys(env, link);
const session = await api.sessionKey(env, link, openerNonce, senderNonce);
const content = await api.contentKey(env, link, openerNonce, senderNonce, 1);
const out = {};
out.hello = await api.openSetup(env, keys.setup, api.LINK_FROM.opener, link.linkId, d(input.hello));
out.challenge = await api.openSetup(env, keys.setup, api.LINK_FROM.sender, link.linkId, d(input.challenge));
out.answer = await api.openSetup(env, session, api.LINK_FROM.sender, link.linkId, d(input.answer));
out.proof = e(await api.proofMac(env, keys, link, senderNonce, openerNonce));
out.offer = e(await api.sealSetup(env, session, api.LINK_FROM.opener, link.linkId,
    { t: 'offer', a: 1, relay: false, sdp: 'v=0' }));
const meta = await api.openRecord(env, content, [api.RECORD.meta], 0, d(input.meta));
const parsed = meta && api.parseMeta(meta.plain);
out.meta = parsed && { name: parsed.name, size: parsed.size, type: parsed.type, sender: parsed.sender,
    sha256: e(parsed.sha256), thumbnail: parsed.thumbnail ? e(parsed.thumbnail) : null };
const chunk = await api.openRecord(env, content, [api.RECORD.chunk, api.RECORD.last], 7, d(input.final));
out.final = chunk && { type: chunk.type, plain: e(chunk.plain) };
const hash = new api.Sha256();
hash.update(d(input.final_plain));
out.sha256 = e(hash.digest());
out.control = e(await api.sealRecord(env, content, api.RECORD.control, 0, api.utf8(JSON.stringify(
    { t: 'start', upto: 64 }))));
const download = api.parseLinkPayload('d', input.download_fragment);
out.download = download && { link_id: e(download.linkId), secret: e(download.secret) };
const friend = api.parseLinkPayload('f', input.friend_fragment);
out.friend = friend && { friends_id: friend.friendsId, name: friend.name };
process.stdout.write(JSON.stringify(out));
