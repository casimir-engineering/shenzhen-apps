// Download links (HOST-PROTOCOL-ONLINE.md § Download links): a sender's helper registers each live link; a browser
// opening the link connects as a guest (/v1?guest=1), opens exactly one sid to that helper and talks to it through
// the host.
//
// Who holds a link is kept in the database by keyed hashes of the link and the identity (online-store.js), so nobody
// else can claim a link while its sender is offline, or after a restart. Where the sender is connected right now is
// kept in memory only. While the sender is offline an open for a registered link waits up to 30 minutes and is
// delivered when the sender's helper registers the link again; an open for a link nobody registered gets the usual
// 2 minutes. Guests count by address (an IPv4 address or an IPv6 /56): a few connections at once, fewer of them
// waiting, so nobody can fill the host's guest places and take every download link offline.
//
// A link that ended leaves a tombstone for 31 days: its sender's helper sends one when it revokes or expires a link
// (and again on every connection), and a binding that expires here leaves one of its own. An open for a link nobody
// holds whose tombstone is here is answered at once with why (`link_ended`), so the page says so instead of waiting.

import { clientKey } from './address.js';
import { decodeBase64url } from './keys.js';
import {
    ONLINE_LIMITS, decodeId, decodePayload, linkIdHash, linkTombstoneHash, tombstoneKey, validReq,
} from './online-protocol.js';
import {
    TOMBSTONE_S, bindLink, bindingForTomb, linkOwner, linksHeldBy, pruneLinks, saveTombstone, tombstoneReason,
    unbindLink,
} from './online-store.js';
import { CLOSE } from './protocol.js';
import { DailyCap } from './ratelimit.js';

const LINK_HASH = /^[A-Za-z0-9_-]{43}$/;
const IDENTITY_HASH = /^[0-9a-f]{64}$/;
const ENDED = new Set(['revoked', 'expired']);

// The address key every guest limit counts by: an IPv4 address or an IPv6 /56 (address.js).
function addressOf(session) {
    return session.ticket?.wideKey ?? 'unknown';
}

function addTo(map, key, value) {
    let set = map.get(key);
    if (!set) {
        set = new Set();
        map.set(key, set);
    }
    set.add(value);
}

function removeFrom(map, key, value) {
    const set = map.get(key);
    set?.delete(value);
    if (set?.size === 0) map.delete(key);
}

function refuse(socket, status, text) {
    socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

export class LinkRegistry {
    constructor(online) {
        this.online = online;
        this.served = new Map(); // link hash -> { identityHash, hostId, session, expires }: where it is served now
        this.held = new Map(); // link hash -> Set of sids waiting for the sender
        this.holding = new Map(); // guest address key -> Set of sids it has waiting
        this.opens = new DailyCap({ limit: ONLINE_LIMITS.linkOpensPerDay });
        this.guestCount = 0;
        this.guestsByAddress = new Map(); // guest address key -> open guest connections
    }

    get host() {
        return this.online.host;
    }

    get db() {
        return this.online.host.db;
    }

    hash(linkId) {
        return linkIdHash(this.host.config.identitySecret, linkId);
    }

    // The key a link's tombstone is filed under, from the link id (an open) or from the helper's tombstone hash.
    tombKey(tombHash) {
        return tombstoneKey(this.host.config.identitySecret, tombHash);
    }

    get size() {
        return this.served.size;
    }

    // ---- the sender's helper ----------------------------------------------------------------------------------

    register(session, msg) {
        const now = this.online.nowS();
        if (!decodeId(msg.link_id) || !Number.isSafeInteger(msg.expires) || msg.expires <= now
            || msg.expires > now + ONLINE_LIMITS.linkMaxTtlS) {
            return session.fail('bad_request', 'A link registration names a link id and its expiry.');
        }
        const linkHash = this.hash(msg.link_id);
        const me = session.identityHash.toString('hex');
        const owner = linkOwner(this.db, linkHash, now);
        if (owner && owner.identityHash !== me) {
            return session.send('link_registered', { link_id: msg.link_id, ok: false, reason: 'taken' });
        }
        if (!owner && linksHeldBy(this.db, me, now) >= ONLINE_LIMITS.linksPerIdentity) {
            return session.send('link_registered', { link_id: msg.link_id, ok: false, reason: 'too_many' });
        }
        bindLink(this.db, { linkHash, identityHash: me, expires: msg.expires,
            tombKey: this.tombKey(linkTombstoneHash(msg.link_id)) });
        this.served.set(linkHash, { identityHash: me, hostId: this.online.hostId, session, expires: msg.expires });
        this.online.federation.broadcast('link_bind', { link_hash: linkHash, identity_hash: me,
            host_id: this.online.hostId, expires: msg.expires });
        session.send('link_registered', { link_id: msg.link_id, ok: true });
        this.release(linkHash);
        return undefined;
    }

    unregister(session, msg) {
        if (!decodeId(msg.link_id)) return session.fail('bad_request', 'A link id is 16 bytes.');
        const linkHash = this.hash(msg.link_id);
        const owner = linkOwner(this.db, linkHash, this.online.nowS());
        if (owner && owner.identityHash === session.identityHash.toString('hex')) {
            unbindLink(this.db, linkHash);
            this.served.delete(linkHash);
            this.online.federation.broadcast('link_unbind', { link_hash: linkHash, removed: true });
        }
        return session.send('link_unregistered', { link_id: msg.link_id });
    }

    // Tombstones from the sender's helper: each ends the helper's own binding with that key, if it still has one (on
    // Revoke, which sends its tombstone first, or for a link revoked while the host could not be told), and is kept
    // so opens of the link are told why it ended. Only the link's holder can replace a tombstone someone else left.
    tombstones(session, msg) {
        const now = this.online.nowS();
        const list = Array.isArray(msg.tombstones) ? msg.tombstones : null;
        const valid = (t) => t && ENDED.has(t.reason) && decodeBase64url(t.hash, 32) && Number.isSafeInteger(t.until)
            && t.until > now && t.until <= now + TOMBSTONE_S;
        if (!list || list.length === 0 || list.length > ONLINE_LIMITS.tombstonesPerMessage || !list.every(valid)) {
            return session.fail('bad_request', 'Tombstones are 1 to 64 of a hash, a reason and a time.');
        }
        const me = session.identityHash.toString('hex');
        for (const t of list) {
            const tombKey = this.tombKey(decodeBase64url(t.hash, 32));
            const linkHash = bindingForTomb(this.db, tombKey, me, now);
            if (linkHash) {
                unbindLink(this.db, linkHash);
                this.served.delete(linkHash);
                this.online.federation.broadcast('link_unbind', { link_hash: linkHash, removed: true });
            }
            saveTombstone(this.db, { tombKey, identityHash: me, reason: t.reason, until: t.until,
                holder: Boolean(linkHash) });
            this.online.federation.broadcast('link_tomb', { tomb_key: tombKey, identity_hash: me, reason: t.reason,
                until: t.until });
        }
        return undefined;
    }

    // Why a link ended, when nobody holds it and its tombstone is here: "revoked", "expired", or null.
    ended(linkId) {
        const now = this.online.nowS();
        if (linkOwner(this.db, this.hash(linkId), now)) return null;
        return tombstoneReason(this.db, this.tombKey(linkTombstoneHash(linkId)), now);
    }

    // Where the link is served now, as a route, or null while its sender is offline.
    route(linkHash) {
        const link = this.served.get(linkHash);
        if (!link || link.expires <= this.online.nowS()) return null;
        return { hostId: link.hostId, identityHash: link.identityHash };
    }

    // Whether an open for a link whose sender is offline may wait for it: only for a link someone holds (bindings
    // outlive restarts, so a real sender's link always has one), and only while the opener's address has fewer than
    // two opens waiting.
    mayHold(session, linkHash) {
        if (!linkOwner(this.db, linkHash, this.online.nowS())) return false;
        const set = this.holding.get(addressOf(session));
        if (!set) return true;
        for (const sid of set) if (!this.online.sids.get(sid)?.held) set.delete(sid);
        return set.size < ONLINE_LIMITS.heldGuestsPerAddress;
    }

    hold(entry, session) {
        addTo(this.held, entry.linkHash, entry.sid);
        entry.holder = addressOf(session);
        addTo(this.holding, entry.holder, entry.sid);
    }

    unhold(entry) {
        removeFrom(this.held, entry.linkHash, entry.sid);
        if (entry.holder) removeFrom(this.holding, entry.holder, entry.sid);
    }

    // The sender is back: every open waiting for this link is delivered.
    release(linkHash) {
        const waiting = this.held.get(linkHash);
        const route = this.route(linkHash);
        if (!waiting || !route) return;
        this.held.delete(linkHash);
        for (const sid of waiting) {
            const entry = this.online.sids.get(sid);
            if (entry?.held) this.online.signal.deliver(entry, route);
        }
    }

    // The sender's connection closed: its links are offline until it registers them again.
    sessionClosed(session) {
        for (const [linkHash, link] of [...this.served]) {
            if (link.session !== session) continue;
            this.served.delete(linkHash);
            this.online.federation.broadcast('link_unbind', { link_hash: linkHash, removed: false });
        }
    }

    sweep() {
        const now = this.online.nowS();
        for (const [linkHash, link] of [...this.served]) if (link.expires <= now) this.served.delete(linkHash);
    }

    prune() {
        pruneLinks(this.db, this.online.nowS());
        this.opens.roll(this.host.today());
    }

    // ---- from other hosts -------------------------------------------------------------------------------------

    remoteBind(origin, body) {
        const now = this.online.nowS();
        if (body.host_id !== origin || !LINK_HASH.test(String(body.link_hash))
            || !IDENTITY_HASH.test(String(body.identity_hash))
            || !Number.isSafeInteger(body.expires) || body.expires <= now
            || body.expires > now + ONLINE_LIMITS.linkMaxTtlS) return;
        const owner = linkOwner(this.db, body.link_hash, now);
        if (owner && owner.identityHash !== body.identity_hash) return;
        bindLink(this.db, { linkHash: body.link_hash, identityHash: body.identity_hash, expires: body.expires });
        this.served.set(body.link_hash, { identityHash: body.identity_hash, hostId: origin, session: null,
            expires: body.expires });
        this.release(body.link_hash);
    }

    remoteUnbind(origin, body) {
        const link = typeof body.link_hash === 'string' ? this.served.get(body.link_hash) : null;
        if (!link || link.hostId !== origin) return;
        this.served.delete(body.link_hash);
        if (body.removed === true) unbindLink(this.db, body.link_hash);
    }

    remoteTomb(origin, body) {
        const now = this.online.nowS();
        if (!LINK_HASH.test(String(body.tomb_key)) || !IDENTITY_HASH.test(String(body.identity_hash))
            || !ENDED.has(body.reason) || !Number.isSafeInteger(body.until) || body.until <= now
            || body.until > now + TOMBSTONE_S) return;
        saveTombstone(this.db, { tombKey: body.tomb_key, identityHash: body.identity_hash, reason: body.reason,
            until: body.until });
    }

    // Links served on hosts that can no longer be reached go offline here.
    hostsGone(gone) {
        for (const [linkHash, link] of [...this.served]) if (gone(link.hostId)) this.served.delete(linkHash);
    }

    // What a host sends over a link that has just come up: the links served on every host but `exceptHost`.
    servedLinks(exceptHost) {
        const now = this.online.nowS();
        return [...this.served].filter(([, link]) => link.hostId !== exceptHost && link.expires > now)
            .map(([linkHash, link]) => ({ link_hash: linkHash, identity_hash: link.identityHash, host_id: link.hostId,
                expires: link.expires }));
    }

    // ---- guests (a browser opening a download link) -----------------------------------------------------------

    upgradeGuest(req, socket, head) {
        const { wideKey } = clientKey(req, socket, this.host.config.trustedProxies);
        if (!this.online.budgets.guests.take(wideKey)
            || (this.guestsByAddress.get(wideKey) ?? 0) >= ONLINE_LIMITS.guestsOpenPerAddress) {
            return refuse(socket, 429, 'Too Many Requests');
        }
        if (this.guestCount >= ONLINE_LIMITS.guestConnections) return refuse(socket, 503, 'Service Unavailable');
        const admitted = this.host.admission.admit(req, socket);
        if (!admitted.ok) return refuse(socket, admitted.status, admitted.text);
        return this.host.wss.handleUpgrade(req, socket, head, (ws) => {
            this.guestCount += 1;
            this.guestsByAddress.set(wideKey, (this.guestsByAddress.get(wideKey) ?? 0) + 1);
            this.host.accept(ws, admitted.ticket, false, { guest: true });
        });
    }

    guestClosed(session) {
        this.guestCount = Math.max(0, this.guestCount - 1);
        const key = addressOf(session);
        const open = (this.guestsByAddress.get(key) ?? 1) - 1;
        if (open > 0) this.guestsByAddress.set(key, open);
        else this.guestsByAddress.delete(key);
    }

    // A guest may open one link, as its first message, and then only talk on that sid.
    handleGuest(session, msg) {
        if (session.state === 'challenged') {
            if (msg.type !== 'link_open') return session.fail('bad_request', 'A guest opens one link.');
            const payload = decodePayload(msg.payload);
            if (!validReq(msg.req) || !decodeId(msg.link_id) || !payload) {
                return session.fail('bad_request', 'A link open names a link id and carries a payload.');
            }
            clearTimeout(session.deadline);
            session.state = 'guest';
            session.ticket.authenticate();
            const target = this.online.signal.linkTarget(msg.link_id);
            if (!this.opens.take(target.linkHash, this.host.today())) {
                session.send('sig_refused', { req: msg.req, reason: 'rate_limited' });
                return session.close(CLOSE.tryLater, 'rate limited');
            }
            return this.online.signal.openSid({ session, req: msg.req, target, payload });
        }
        switch (msg.type) {
        case 'sig_msg': return this.online.signal.message(session, msg);
        case 'sig_close': return this.online.signal.close(session, msg);
        case 'relay_credentials': return this.online.credentials(session, msg);
        default: return session.fail('bad_request', 'Unknown message type.');
        }
    }
}
