// Online Friends on the host (HOST-PROTOCOL-ONLINE.md; ADR 0010): rendezvous records, connection setup
// between helpers and between a browser and a helper (download links), relay credentials, the STUN responder, the
// relay's statistics, and passing all of it between hosts. Runs only with FRIENDS_M2=on; protocol 1 helpers never
// reach it. This file holds the dispatch, the records and the credentials; signalling, links, the links between
// hosts and the relay's services each have their own module.

import { Federation } from './online-federation.js';
import { IncomingGate } from './online-incoming.js';
import { LinkRegistry } from './online-links.js';
import { ONLINE_LIMITS, kindOf, newId, turnRestCredential, validReq } from './online-protocol.js';
import { Signalling } from './online-signal.js';
import { CostBudget } from './ratelimit.js';
import { RelayServices } from './relay.js';
import { RelayAllocationCap } from './relay-allocations.js';
import { RelayStats } from './relay-stats.js';
import { RecordStore } from './rendezvous.js';
import { SidTable } from './signaling.js';
import { decodeBase64url } from './keys.js';

const MINUTE = 60_000;

export class OnlineService {
    constructor(host) {
        const { clock, config } = host;
        this.host = host;
        this.clock = clock;
        this.hostId = config.hostId;
        this.settings = config.online;
        this.records = new RecordStore({ hostId: this.hostId, identitySecret: config.identitySecret, clock });
        this.sids = new SidTable({ clock, lifetimeMs: ONLINE_LIMITS.sidLifetimeMs, waitMs: ONLINE_LIMITS.linkWaitMs });
        const L = ONLINE_LIMITS;
        const budget = (limit, windowMs) => new CostBudget({ limit, windowMs, clock });
        this.budgets = {
            publish: budget(L.publishesPerMinute, MINUTE),
            lookup: budget(L.lookupKeysPer5Min, 5 * MINUTE),
            open: budget(L.opensPerMinute, MINUTE),
            openById: budget(L.opensByIdPerHour, 60 * MINUTE),
            join: budget(L.joinsPerHour, 60 * MINUTE),
            joinTarget: budget(L.joinsPerPersonPerHour, 60 * MINUTE),
            credentials: budget(L.relayCredentialsPerHour, 60 * MINUTE),
            guestCredentialsPerLink: budget(L.guestCredentialsPerLinkPerHour, 60 * MINUTE),
            guestCredentialsPerAddress: budget(L.guestCredentialsPerAddressPerHour, 60 * MINUTE),
            guests: budget(L.guestsPerAddressPerMinute, MINUTE),
        };
        this.relayHeld = new RelayAllocationCap({ clock });
        this.incoming = new IncomingGate({ clock });
        this.stats = new RelayStats({ clock, timeZone: config.statsTimeZone, db: host.db, hostId: this.hostId });
        this.signal = new Signalling(this);
        this.links = new LinkRegistry(this);
        this.federation = new Federation(this);
        this.relay = new RelayServices(this);
        this.timers = [];
    }

    async start() {
        this.stats.load();
        await this.relay.start();
        this.timers.push(setInterval(() => this.host.guard('online', () => this.sweep()), 1000));
    }

    async stop() {
        for (const timer of this.timers) clearInterval(timer);
        this.timers = [];
        await this.relay.stop();
        this.stats.flush();
    }

    nowS() {
        return Math.floor(this.clock.now() / 1000);
    }

    // The relay, when this host runs one and the switch is on; otherwise credentials are refused with no_relay.
    get relayOn() {
        return this.settings.relay;
    }

    // ---- dispatch -------------------------------------------------------------------------------------------

    // A message from a checked-in helper that declared protocol 2 (client-session.js decides that).
    handle(session, msg) {
        switch (msg.type) {
        case 'rdv_publish': return this.publish(session, msg);
        case 'rdv_lookup': return this.lookup(session, msg);
        case 'sig_open': return this.signal.open(session, msg);
        case 'sig_msg': return this.signal.message(session, msg);
        case 'sig_close': return this.signal.close(session, msg);
        case 'relay_credentials': return this.credentials(session, msg);
        case 'link_register': return this.links.register(session, msg);
        case 'link_unregister': return this.links.unregister(session, msg);
        case 'link_tombstones': return this.links.tombstones(session, msg);
        default: return session.fail('bad_request', 'Unknown message type.');
        }
    }

    // ---- rendezvous records ---------------------------------------------------------------------------------

    publish(session, msg) {
        const me = session.identityHash.toString('hex');
        if (!this.budgets.publish.take(me)) {
            return session.send('rdv_published', { seq: Number.isSafeInteger(msg.seq) ? msg.seq : null,
                accepted: false, reason: 'rate_limited', shown_from: null });
        }
        const result = this.records.publishLocal(session, msg);
        if (!result.ok && (result.error === 'malformed' || result.error === 'signature')) {
            return session.fail(result.error === 'signature' ? 'bad_signature' : 'bad_request',
                'The rendezvous record does not verify.');
        }
        // Lookups show an accepted record from the next period boundary, for that one period.
        const shownFrom = result.ok ? (this.records.period() + 1) * ONLINE_LIMITS.rdvPeriodS : null;
        session.send('rdv_published', { seq: msg.seq, accepted: result.ok, reason: result.ok ? null : result.error,
            shown_from: shownFrom });
        if (result.ok) this.federation.broadcastRecord(result.record);
        return undefined;
    }

    lookup(session, msg) {
        const keys = Array.isArray(msg.keys) ? msg.keys.map((k) => decodeBase64url(k, 32)) : null;
        if (!validReq(msg.req) || !keys || keys.length < 1 || keys.length > ONLINE_LIMITS.lookupKeysPerMessage
            || keys.some((k) => !k)) {
            return session.fail('bad_request', 'A lookup names 1 to 32 rendezvous keys.');
        }
        if (!this.budgets.lookup.take(session.identityHash.toString('hex'), keys.length)) {
            return session.send('rdv_records', { req: msg.req, records: null, reason: 'rate_limited' });
        }
        return session.send('rdv_records', { req: msg.req, records: this.records.lookup(keys) });
    }

    // ---- relay credentials ----------------------------------------------------------------------------------

    credentials(session, msg) {
        const entry = this.sids.get(msg.sid);
        const place = entry ? this.signal.placeOf(entry, session) : null;
        if (!validReq(msg.req) || !place || place.side === 'waiting') {
            return session.fail('bad_request', 'Relay credentials name an open sid.');
        }
        const refuse = (reason) => session.send('relay_refused', { req: msg.req, reason });
        if (!this.relayOn) return refuse('no_relay');
        // Only for a connection both sides have taken part in, so nobody mints relay time by opening sids to no one.
        if (!entry.a.spoke || !entry.b?.spoke) return refuse('not_answered');
        const end = place.end;
        if (end.credentials >= ONLINE_LIMITS.relayCredentialsPerSidEnd) return refuse('rate_limited');
        const owners = this.relayHeld.admit(this.relayShares(session, entry, place));
        if (!owners) return refuse('rate_limited');
        if (!this.takeCredentialBudget(session, entry)) return refuse('rate_limited');
        end.credentials += 1;
        const issued = this.issueCredential({ sid: entry.sid, kind: kindOf(entry.via), owners });
        return session.send('relay_credentials_result', { req: msg.req, ...issued,
            ...(session.guest ? { ice_servers: this.settings.guestIceServers } : {}) });
    }

    // A helper's hourly budget is its identity's; a browser has none, so its link and its address each have one.
    takeCredentialBudget(session, entry) {
        const { budgets } = this;
        if (!session.guest) return budgets.credentials.take(session.identityHash.toString('hex'));
        return budgets.guestCredentialsPerLink.take(entry.linkHash ?? 'none')
            && budgets.guestCredentialsPerAddress.take(session.ticket?.wideKey ?? 'unknown');
    }

    // The shares of the relay a credential would count in (relay-allocations.js): a helper's identity or a browser's
    // address, the network either connects from, and the pair of friends when the answering end was one the caller
    // reached lately (online-incoming.js). On the answering host the caller's identity is not known, so a pair is
    // that end and the caller's host.
    relayShares(session, entry, place) {
        const L = ONLINE_LIMITS;
        const me = session.guest ? null : session.identityHash.toString('hex');
        const own = me ? [`identity:${me}`, L.relayHeldPerIdentity]
            : [`guest:${session.ticket?.wideKey ?? 'unknown'}`, L.relayHeldPerGuestAddress];
        const far = place.side === 'a' ? entry.b : entry.a;
        const farName = far.identityHash ?? (far.hostId ? `host:${far.hostId}` : null);
        const pair = me && farName && entry.b.known === true
            ? [`pair:${[me, farName].sort().join(':')}`, L.relayReservedPerPair] : null;
        const { minPort, maxPort } = this.settings.turn ?? {};
        const capacity = Number.isInteger(minPort) && Number.isInteger(maxPort) ? maxPort - minPort + 1 : Infinity;
        const reserve = capacity === Infinity ? 0 : Math.max(L.relayReservedPerPair,
            Math.floor(capacity / L.relayReservedPart));
        return { own, net: [`net:${session.ticket?.netKey ?? 'unknown'}`, L.relayHeldPerNetwork], pair, capacity,
            reserve };
    }

    // A TURN REST credential for one relay attempt, valid 300 s to start an allocation. The attempt id joins
    // coturn's events to the sid's kind in the statistics and to `owners` for the relay cap; it names nobody.
    issueCredential({ sid, kind, owners }) {
        const attempt = newId();
        const expires = this.nowS() + ONLINE_LIMITS.relayCredentialTtlS;
        const { username, credential } = turnRestCredential({ secret: this.settings.turn.secret, expires,
            label: attempt });
        this.stats.noteCredential({ attempt, sid, kind });
        if (owners) this.relayHeld.issued({ attempt, owners, expiresS: expires });
        return { username, credential, expires };
    }

    // ---- connections closing, expiry, the minute tick -------------------------------------------------------

    sessionClosed(session) {
        if (session.guest) this.links.guestClosed(session);
        this.signal.sessionClosed(session);
        const withdrawn = this.records.sessionClosed(session);
        if (withdrawn) this.federation.broadcastWithdraw(withdrawn);
        this.links.sessionClosed(session);
    }

    sweep() {
        this.signal.sweep();
        for (const record of this.records.sweep()) {
            if (record.session) this.federation.broadcastWithdraw(record);
        }
        this.links.sweep();
        this.relayHeld.prune();
        this.relay.sweep();
    }

    // Once a minute, from the host's own tick: rates and minutes at the cap, today's row, expired link bindings.
    tick() {
        this.stats.tick();
        this.links.prune();
        this.incoming.sweep();
    }

    // What the dashboard shows of this host's memory: all of it goes when the process stops.
    get counts() {
        return { records: this.records.size, sids: this.sids.size, links: this.links.size,
            guests: this.links.guestCount };
    }
}
