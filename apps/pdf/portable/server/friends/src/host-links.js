// The main host's side of a link from a replica (ADR 0005 § Replicas). A replica proves three things over the
// main host's challenge: it holds the host key the current signed list names for it (so anything not in the list
// is refused), it knows the shared replica secret, and it uses the same identity secret (both as HMACs, so no
// secret travels). The main host answers with a signature by its own host key over the replica's nonce and both
// hosts' key shares, then copies its Friends ID table to the replica (id-sync.js). Every message after that handshake
// is authenticated with a key only these two hosts can derive (link-auth.js), so neither TLS interception between
// them nor another replica can inject or rewrite one. Reservations and releases a replica forwards carry the helper's
// own signature (forward-proof.js), which the main host checks before acting as the only allocator. Check-in
// summaries and connection counts are counted here so unique users are deduplicated across hosts.
//
// What a compromised replica (its host key and both secrets) can still do is bounded here. It can mint identity
// keys and sign check-ins for them, so the new IDs it may obtain are capped per day
// (FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY). Its check-in summaries count only for identities whose own signed check-in
// it forwarded, so it cannot keep other people's rows alive or inflate the counts with made-up names.

import { addDays, validDay } from './clock.js';
import { verifyCheckinProof, verifyReleaseProof } from './forward-proof.js';
import { hostEntry } from './hostlist.js';
import { IdTableSender } from './id-sync.js';
import {
    decodeBase64url, encodeBase64url, hmacSha256, identityHash, identitySecretCheck, safeEqual, signEd25519,
    verifyEd25519,
} from './keys.js';
import { LinkAuth, newKeyShare } from './link-auth.js';
import { HOST_ONLINE_TYPES } from './online-protocol.js';
import { cleanRelayDay, saveRelayDay } from './online-store.js';
import {
    CLOSE, hostLinkSignedBytes, hostLinkWelcomeSignedBytes, validAppVersion, validCount, validHostId,
} from './protocol.js';
import { recordReplicaProof, recordSample, replicaForwardedProof } from './records.js';

const MAX_BATCH = 200;
const UNAVAILABLE = { reservation: 'unavailable', friendsId: null, granted: false };

// When every check passes, the replica's id, the handshake both signatures cover (with this host's new key share)
// and this end's link authentication; else null.
export function verifyHostHello(host, challenge, msg) {
    const { config } = host;
    if (!host.isMain || !config.replicaSecret) return null;
    const replicaId = msg.host_id;
    if (!validHostId(replicaId) || replicaId === config.hostId) return null;
    const entry = hostEntry(host.list, replicaId);
    const signature = decodeBase64url(msg.sig, 64);
    const mac = decodeBase64url(msg.mac, 32);
    const identityCheck = decodeBase64url(msg.identity_check, 32);
    const nonce = decodeBase64url(msg.nonce, 32);
    const replicaShare = decodeBase64url(msg.key_share, 32);
    if (!entry || !signature || !mac || !identityCheck || !nonce || !replicaShare) return null;
    const bytes = hostLinkSignedBytes({ mainHostId: config.hostId, challenge, replicaHostId: replicaId, nonce,
        replicaShare });
    // Every check always runs, so timing does not reveal which one failed.
    const signed = verifyEd25519(entry.publicKey, bytes, signature);
    const knows = safeEqual(hmacSha256(config.replicaSecret, bytes), mac);
    const sameIdentities = safeEqual(identitySecretCheck(config.identitySecret, challenge), identityCheck);
    if (!(signed && knows && sameIdentities)) return null;
    const own = newKeyShare();
    const transcript = { mainHostId: config.hostId, replicaHostId: replicaId, challenge, nonce, replicaShare,
        mainShare: own.share };
    const auth = LinkAuth.derive({ secret: config.replicaSecret, side: 'main', privateKey: own.privateKey,
        transcript });
    return auth ? { replicaId, transcript, auth } : null;
}

export class HostLink {
    // `hello` is what verifyHostHello returned.
    constructor(host, session, hello) {
        this.host = host;
        this.session = session;
        this.replicaId = hello.replicaId;
        this.transcript = hello.transcript;
        this.auth = hello.auth;
        this.sender = new IdTableSender(host, this);
    }

    // Every message after host_welcome is authenticated with the link key.
    send(type, fields) {
        const { ws } = this.session;
        if (ws.readyState === ws.OPEN) ws.send(this.auth.wrap(type, fields));
    }

    welcome() {
        const { config } = this.host;
        const sig = signEd25519(config.hostKey, hostLinkWelcomeSignedBytes(this.transcript));
        this.session.send('host_welcome', { host_id: config.hostId, host_list: this.host.currentListFor(0),
            key_share: encodeBase64url(this.transcript.mainShare), sig: encodeBase64url(sig) });
        this.sender.start();
    }

    closed() {
        this.sender.stop();
        this.host.hostLinkClosed(this);
    }

    // Nothing is answered after a failure: an error message would be one the replica cannot authenticate either.
    drop(reason) {
        this.host.log('host_link', { conn: this.session.connId, state: 'dropped', reason, host: this.replicaId });
        this.session.close(CLOSE.policy, 'host link');
    }

    handle(envelope) {
        const msg = this.auth.unwrap(envelope);
        if (!msg) {
            this.drop('authentication');
            return undefined;
        }
        switch (msg.type) {
        case 'fwd_reserve':
            return this.reserve(msg);
        case 'fwd_release':
            return this.release(msg);
        case 'fwd_summaries':
            return this.summaries(msg);
        case 'report':
            return this.report(msg);
        default:
            // Online Friends between hosts (online-federation.js), when it is on here.
            if (HOST_ONLINE_TYPES.has(msg.type)) this.host.online?.federation.fromLink(this.replicaId, msg);
            // A newer replica may send messages this main host does not know yet; ignoring them keeps the link up.
            return undefined;
        }
    }

    reserve(msg) {
        if (typeof msg.friends_id !== 'string' || msg.friends_id.length > 64 || !Number.isSafeInteger(msg.req)) {
            this.drop('malformed');
            return;
        }
        const proof = verifyCheckinProof(msg.proof, this.replicaId);
        // The main host checks the device chain itself (devices.js): a replica cannot reserve a person's ID for a
        // device that is not theirs, and the revocations the chain carries are counted here.
        const member = proof ? this.host.admitDevice(proof) : null;
        let result = UNAVAILABLE;
        if (member?.ok) {
            const hash = member.personHash;
            const day = this.host.today();
            recordReplicaProof(this.host.db, { replicaId: this.replicaId, identityHash: hash, day });
            result = this.allocateForReplica({ identityHash: hash, friendsId: msg.friends_id, day,
                afterCollision: msg.after_collision === true, wantsNew: msg.allow_new === true });
        } else {
            this.host.log('forward_refused', { host: this.replicaId, scope: 'reserve' });
        }
        this.send('fwd_reserve_result', { req: msg.req, reservation: result.reservation,
            friends_id: result.friendsId, granted: result.granted === true });
    }

    // The replica's daily budget of new IDs is spent like an address's: taken before the allocation and refunded
    // when no new ID was granted. A key that already holds an ID always gets it back, budget or not.
    allocateForReplica({ identityHash: hash, friendsId, day, afterCollision, wantsNew }) {
        const budget = this.host.replicaNewIds;
        const allowNew = wantsNew && budget.take(this.replicaId, day);
        const result = this.host.allocate({ identityHash: hash, friendsId, afterCollision, allowNew });
        if (allowNew && !result.granted) budget.refund(this.replicaId, day);
        if (budget.used(this.replicaId, day) >= budget.limit) this.host.noteReplicaLimit(this.replicaId, day);
        return result;
    }

    release(msg) {
        if (!Number.isSafeInteger(msg.req)) {
            this.drop('malformed');
            return;
        }
        const identityKey = verifyReleaseProof(msg.proof, this.replicaId);
        if (!identityKey) {
            this.host.log('forward_refused', { host: this.replicaId, scope: 'release' });
            this.send('fwd_release_result', { req: msg.req, released: false });
            return;
        }
        const released = this.host.releaseHere(identityHash(this.host.config.identitySecret, identityKey));
        this.send('fwd_release_result', { req: msg.req, released });
    }

    // Queued summaries may be days old after an outage. Each counts for the day the replica saw it, unless it is
    // older than the 30-day window or in the future, which only a broken clock produces, and only for an identity
    // whose own signed check-in this replica forwarded (recorded in reserve above, kept 31 days). A replica sends a
    // check-in's summary after its forwarded reservation (client-session.js), so with the link up every summary has
    // its proof; check-ins of people new to this replica during a main-host outage go uncounted.
    summaries(msg) {
        if (!Array.isArray(msg.items) || msg.items.length > MAX_BATCH) {
            this.drop('malformed');
            return;
        }
        const today = this.host.today();
        const oldest = addDays(today, -30);
        const tomorrow = addDays(today, 1);
        let through = 0;
        let unproven = 0;
        for (const item of msg.items) {
            if (!item || !Number.isSafeInteger(item.seq)) continue;
            through = Math.max(through, item.seq);
            const hash = decodeBase64url(item.identity_hash, 32);
            const deviceHash = item.device_hash === undefined ? hash : decodeBase64url(item.device_hash, 32);
            if (!hash || !deviceHash || !validDay(item.day) || item.day < oldest || item.day > tomorrow
                || !validAppVersion(item.app_version) || !validCount(item.list_version)
                || !validCount(item.protocol, 1000)) {
                continue;
            }
            if (!replicaForwardedProof(this.host.db, { replicaId: this.replicaId, identityHash: hash })) {
                unproven += 1;
                continue;
            }
            this.host.countCheckin({ identityHash: hash, deviceHash, day: item.day, appVersion: item.app_version,
                listVersion: item.list_version, protocol: item.protocol });
        }
        if (unproven > 0) this.host.log('forward_refused', { host: this.replicaId, scope: 'summary', count: unproven });
        this.send('ack', { through });
    }

    report(msg) {
        const nowMinute = Math.floor(this.host.clock.now() / 60_000);
        if (!validCount(msg.connections, 10_000_000) || !Number.isSafeInteger(msg.minute)
            || Math.abs(msg.minute - nowMinute) > 10 || !validDay(msg.day)) {
            return;
        }
        const listVersions = new Map();
        if (msg.list_versions && typeof msg.list_versions === 'object') {
            for (const [version, count] of Object.entries(msg.list_versions).slice(0, 64)) {
                if (/^\d{1,9}$/.test(version) && validCount(count, 10_000_000)) {
                    listVersions.set(Number(version), count);
                }
            }
        }
        recordSample(this.host.db, { minute: msg.minute, hostId: this.replicaId, day: msg.day,
            connections: msg.connections });
        // The replica's relay counters for its current statistics day (relay-stats.js), one row per host per day.
        const relay = msg.relay && validDay(msg.relay.day) ? cleanRelayDay(msg.relay.counters) : null;
        if (relay && msg.relay.day >= addDays(msg.day, -1) && msg.relay.day <= msg.day) {
            saveRelayDay(this.host.db, { day: msg.relay.day, hostId: this.replicaId, counters: relay });
        }
        this.host.replicaReports.set(this.replicaId, { at: this.host.clock.now(), connections: msg.connections,
            listVersions });
    }
}
