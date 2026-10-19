// Connection setup (HOST-PROTOCOL-ONLINE.md § Connection setup): opens, the messages that follow, closes and expiry,
// on this host and across hosts. What keeps presence private lives here: an open is answered before anything is
// looked up, the same way whether or not the target exists; a target refuses by staying silent; a target that closes
// or leaves without having spoken becomes nobody, so its caller's sid simply expires as if nobody had been there.
// Several devices of one person all hold records under the person's one rendezvous key: an open to that key reaches
// each connected device, the first to answer wins and the others are let go. Opens over a device's incoming budgets
// (online-incoming.js) are dropped as silently. A join request (protocol 3) is an open to every connected device of the
// person holding a Friends ID, from a new device asking to join that person; it is forwarded like any other open and
// kept nowhere but in its sid.

import { decodeBase64url, encodeBase64url } from './keys.js';
import {
    ONLINE_LIMITS, decodeId, decodePayload, kindOf, linkIdHash, newId, speaksOnline, validReq,
} from './online-protocol.js';
import { CLOSE, DEVICES_PROTOCOL, validFriendsId } from './protocol.js';
import { LOCAL, REMOTE, localEnd, remoteEnd } from './signaling.js';

const CLOSE_REASONS = new Set(['closed', 'gone', 'expired', 'limit']);

export class Signalling {
    constructor(online) {
        this.online = online;
        this.sids = online.sids;
    }

    get host() {
        return this.online.host;
    }

    placeOf(entry, session) {
        return this.sids.place(entry, { type: LOCAL, session });
    }

    // ---- opening ----------------------------------------------------------------------------------------------

    // `to` names exactly one of: rdv_key (a friend: every device of theirs that is connected; the first to answer
    // wins), friends_id (Add by ID online), link_id (a download link, from the app opening it) or, from protocol 3,
    // join (a Friends ID: every connected device of its holder, asked to let this device join them).
    parseTarget(to, session) {
        if (!to || typeof to !== 'object' || Array.isArray(to)) return null;
        const named = Object.keys(to);
        if (named.length !== 1) return null;
        if (to.friends_id !== undefined) return validFriendsId(to.friends_id) ? { via: 'id', id: to.friends_id } : null;
        if (to.join !== undefined) {
            const speaks = (session.declaredProtocol ?? 1) >= DEVICES_PROTOCOL;
            return speaks && validFriendsId(to.join) ? { via: 'join', id: to.join } : null;
        }
        if (to.link_id !== undefined) return decodeId(to.link_id) ? this.linkTarget(to.link_id) : null;
        const key = to.rdv_key !== undefined ? decodeBase64url(to.rdv_key, 32) : null;
        return key ? { via: 'rdv', key } : null;
    }

    linkTarget(linkId) {
        return { via: 'link', linkId, linkHash: linkIdHash(this.host.config.identitySecret, linkId) };
    }

    open(session, msg) {
        const target = this.parseTarget(msg.to, session);
        const payload = decodePayload(msg.payload);
        if (!validReq(msg.req) || !target || !payload) {
            return session.fail('bad_request', 'An open names one target and carries a payload.');
        }
        const me = session.identityHash.toString('hex');
        const { budgets } = this.online;
        const byVia = { id: budgets.openById, join: budgets.join }[target.via];
        if (this.sids.openedBy(session) >= ONLINE_LIMITS.openSidsPerConnection || !budgets.open.take(me)
            || (byVia && !byVia.take(me))) {
            return session.send('sig_refused', { req: msg.req, reason: 'rate_limited' });
        }
        return this.openSid({ session, req: msg.req, target, payload });
    }

    // Where the target is now: a list of { hostId, identityHash }, possibly empty. Never reported to the caller.
    resolve(target) {
        const { records, federation } = this.online;
        let found = [];
        if (target.via === 'rdv') found = records.routesByKey(target.key);
        else if (target.via === 'id' || target.via === 'join') {
            const row = this.host.db.prepare('SELECT identity_hash FROM identities WHERE friends_id = ?')
                .get(target.id);
            const person = row ? Buffer.from(row.identity_hash).toString('hex') : null;
            // Join requests toward one person are capped per hour, whoever sends them; over the cap they reach
            // nobody, which the sender cannot tell from an ID nobody holds.
            const admitted = person && (target.via === 'id' || this.online.budgets.joinTarget.take(person));
            found = admitted ? records.routesByIdentity(person) : [];
        } else found = [this.online.links.route(target.linkHash)];
        return found.filter((route) => route && (route.hostId === this.online.hostId
            || federation.reaches(route.hostId)));
    }

    openSid({ session, req, target, payload }) {
        const sid = newId();
        const routes = this.resolve(target);
        const link = target.via === 'link';
        // A link nobody holds that its sender ended: answered at once with why, and the sid exists nowhere.
        const ended = link && routes.length === 0 ? this.online.links.ended(target.linkId) : null;
        if (ended) {
            session.send('sig_opened', { req, sid, owner_online: false, link_ended: ended });
            this.online.stats.noteOpen(kindOf(target.via));
            if (session.guest) session.close(CLOSE.normal, 'link ended');
            return undefined;
        }
        // Only a registered link waits for its sender, and only a few per address at once (online-links.js).
        const held = link && routes.length === 0 && this.online.links.mayHold(session, target.linkHash);
        const entry = this.sids.create({ sid, a: localEnd(session), via: target.via, linkId: target.linkId ?? null,
            linkHash: target.linkHash ?? null, held });
        entry.payload = payload;
        entry.caller = { identity: entry.a.identityHash, prefix: session.ticket?.wideKey ?? 'unknown' };
        // Answered before any delivery, the same way whether or not the target exists. Only a link says whether its
        // sender is online: whoever holds a download link is told it is waiting for the sender anyway.
        session.send('sig_opened', { req, sid, ...(link ? { owner_online: routes.length > 0 } : {}) });
        this.online.stats.noteOpen(kindOf(target.via));
        if (held) this.online.links.hold(entry, session);
        for (const route of routes) this.deliver(entry, route);
        return undefined;
    }

    // Hands the open to the target's connection, here or on its host, after the caller's budgets toward that target.
    // A target over its budgets, or not connected, leaves the sid a sink: the caller cannot tell.
    deliver(entry, route) {
        const { incoming } = this.online;
        const { identity, prefix } = entry.caller;
        if (!incoming.admitCaller({ target: route.identityHash, caller: identity, prefix })) return;
        const known = incoming.isKnown(route.identityHash, identity);
        if (route.hostId === this.online.hostId) {
            this.deliverHere(entry, route.identityHash, known);
            return;
        }
        // `known` stays with the end: a pair of friends may draw on the relay's reserve (online.js).
        this.sids.deliver(entry, { ...remoteEnd(route.hostId, route.identityHash), known });
        this.online.federation.send(route.hostId, 'sig_route', { op: 'open', sid: entry.sid, via: entry.via,
            link_id: entry.linkId, identity_hash: route.identityHash, known,
            payload: encodeBase64url(entry.payload) });
    }

    deliverHere(entry, identityHash, known) {
        const target = this.host.live.get(identityHash);
        if (!target || target === entry.a.session || !speaksOnline(target)) return false;
        if (this.sids.place(entry, { type: LOCAL, session: target })) return false;
        if (!this.online.incoming.admitTarget(identityHash, known)) return false;
        this.sids.deliver(entry, { ...localEnd(target), known });
        target.send('sig_incoming', { sid: entry.sid, via: entry.via, link_id: entry.linkId,
            payload: encodeBase64url(entry.payload) });
        return true;
    }

    // ---- messages ---------------------------------------------------------------------------------------------

    message(session, msg) {
        const payload = decodePayload(msg.payload);
        if (typeof msg.sid !== 'string' || !payload) return session.fail('bad_request', 'A message names a sid.');
        const entry = this.sids.get(msg.sid);
        const place = entry ? this.placeOf(entry, session) : null;
        if (!place) return session.send('sig_closed', { sid: msg.sid, reason: 'unknown' });
        if (place.end.sent >= ONLINE_LIMITS.messagesPerSidDirection) {
            return this.closeEnd(entry, place.end, 'limit', true);
        }
        this.spoke(entry, place, payload);
        return undefined;
    }

    // `place.end` sent `payload`: the first message from a waiting end makes it the far end and lets the others go.
    spoke(entry, place, payload) {
        const { end } = place;
        end.sent += 1;
        if (place.side === 'waiting') {
            for (const other of this.sids.choose(entry, end)) this.letGo(entry, other);
            if (entry.originHere) {
                this.online.stats.noteAnswered(kindOf(entry.via));
                this.online.incoming.answered(end.identityHash, entry.caller.identity);
            }
        }
        end.spoke = true;
        const to = end === entry.a ? (entry.b ? [entry.b] : entry.waiting) : [entry.a];
        for (const far of to) this.forward(entry, far, payload);
    }

    forward(entry, end, payload) {
        const text = encodeBase64url(payload);
        if (end.type === LOCAL) end.session.send('sig_msg', { sid: entry.sid, payload: text });
        else this.online.federation.send(end.hostId, 'sig_route', { op: 'msg', sid: entry.sid, payload: text });
    }

    // Another end of the same person answered first. Only targets are let go, so this tells a caller nothing.
    letGo(entry, end) {
        if (end.type === LOCAL) end.session.send('sig_closed', { sid: entry.sid, reason: 'answered_elsewhere' });
        else this.online.federation.send(end.hostId, 'sig_route', { op: 'drop', sid: entry.sid });
    }

    // ---- closing ----------------------------------------------------------------------------------------------

    close(session, msg) {
        const entry = this.sids.get(msg.sid);
        const place = entry ? this.placeOf(entry, session) : null;
        if (place) this.closeEnd(entry, place.end, 'closed', false);
        return undefined;
    }

    // An end leaves the sid. One that never spoke becomes nobody, and on a target's host that has no target left the
    // caller's host forgets it too; one that spoke ends the sid for everyone.
    closeEnd(entry, end, reason, tellCloser) {
        if (tellCloser && end.type === LOCAL) this.endFor(end.session, entry.sid, reason);
        if (end.spoke) {
            this.finish(entry, end, reason);
            return;
        }
        this.sids.forget(entry, end);
        if (entry.a.type === REMOTE && !entry.b && entry.waiting.length === 0) {
            this.sids.delete(entry.sid);
            this.online.federation.send(entry.a.hostId, 'sig_route', { op: 'detach', sid: entry.sid });
        }
    }

    // Ends the sid for every end but `closer`, with `reason`.
    finish(entry, closer, reason) {
        this.sids.delete(entry.sid);
        if (entry.linkHash) this.online.links.unhold(entry);
        for (const end of [entry.a, entry.b, ...entry.waiting]) {
            if (!end || end === closer) continue;
            if (end.type === LOCAL) this.endFor(end.session, entry.sid, reason);
            else this.online.federation.send(end.hostId, 'sig_route', { op: 'close', sid: entry.sid, reason });
        }
    }

    endFor(session, sid, reason) {
        session.send('sig_closed', { sid, reason });
        if (session.guest) session.close(1000, 'done');
    }

    sessionClosed(session) {
        for (const { entry, end } of this.sids.involving({ type: LOCAL, session })) {
            if (this.sids.get(entry.sid) === entry) this.closeEnd(entry, end, 'gone', false);
        }
    }

    sweep() {
        for (const entry of this.sids.expired()) {
            this.sids.delete(entry.sid);
            if (entry.linkHash) this.online.links.unhold(entry);
            for (const end of [entry.a, entry.b, ...entry.waiting]) {
                if (end?.type === LOCAL) this.endFor(end.session, entry.sid, 'expired');
            }
        }
    }

    // ---- from other hosts (online-federation.js has checked where it came from) --------------------------------

    fromHost(from, body) {
        if (!decodeId(body.sid)) return;
        if (body.op === 'open') {
            this.remoteOpen(from, body);
            return;
        }
        const entry = this.sids.get(body.sid);
        const place = entry ? this.sids.place(entry, remoteEnd(from)) : null;
        if (!place) return;
        if (body.op === 'msg') {
            const payload = decodePayload(body.payload);
            // The sending host enforces the per-direction limit and closes the sid when it is reached.
            if (payload && place.end.sent < ONLINE_LIMITS.messagesPerSidDirection) this.spoke(entry, place, payload);
        } else if (body.op === 'detach') {
            if (place.side === 'waiting') this.sids.forget(entry, place.end);
        } else if (body.op === 'close') {
            this.finish(entry, place.end, CLOSE_REASONS.has(body.reason) ? body.reason : 'closed');
        } else if (body.op === 'drop' && place.side === 'a') {
            // The caller's host chose a device on another host: every end here is let go.
            this.sids.delete(entry.sid);
            for (const end of [entry.b, ...entry.waiting]) if (end?.type === LOCAL) this.letGo(entry, end);
        }
    }

    remoteOpen(from, body) {
        const payload = decodePayload(body.payload);
        if (!payload || !['rdv', 'id', 'link', 'join'].includes(body.via) || typeof body.identity_hash !== 'string') {
            return;
        }
        if (body.via === 'link' && !decodeId(body.link_id)) return;
        let entry = this.sids.get(body.sid);
        if (entry && !(entry.a.type === REMOTE && entry.a.hostId === from)) return;
        const created = !entry;
        if (created) {
            entry = this.sids.create({ sid: body.sid, a: remoteEnd(from), via: body.via,
                linkId: body.via === 'link' ? body.link_id : null, originHere: false });
            entry.payload = payload;
        }
        // The open for a link goes to whoever holds the link here, whatever the caller's host believed.
        const owner = body.via === 'link' ? this.online.links.route(linkIdHash(this.host.config.identitySecret,
            body.link_id)) : null;
        const identityHash = owner?.hostId === this.online.hostId ? owner.identityHash : body.identity_hash;
        // Nobody here to deliver to (the target left a moment ago): the caller's host forgets this end, and the
        // caller still sees only silence.
        if (!this.deliverHere(entry, identityHash, body.known === true) && created) {
            this.sids.delete(entry.sid);
            this.online.federation.send(from, 'sig_route', { op: 'detach', sid: entry.sid });
        }
    }

    // Hosts that can no longer be reached (`gone(hostId)` is true): their ends that spoke end their sids ("gone"),
    // the others become nobody.
    hostsGone(gone) {
        for (const entry of this.sids.withRemoteEnds(gone)) {
            for (const end of [entry.a, entry.b, ...entry.waiting]) {
                if (end?.type !== REMOTE || !gone(end.hostId) || this.sids.get(entry.sid) !== entry) continue;
                if (end.spoke) this.finish(entry, end, 'gone');
                else this.sids.forget(entry, end);
            }
        }
    }
}
