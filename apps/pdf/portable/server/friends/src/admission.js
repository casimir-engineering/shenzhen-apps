// Which WebSocket upgrades the host accepts (HOST-PROTOCOL.md § Errors, close codes and limits). Every limit
// counts by address key (address.js), so one IPv6 /64 or one IPv4 address is one budget:
// - new connections per minute per key, refused with 429;
// - open connections per key, refused with 429, so one address cannot hold thousands of sockets;
// - connections that have not checked in yet, which cost memory and prove nothing, share a budget of their own
//   (503 when full) and never take a slot from checked-in helpers;
// - checked-in connections and host links up to FRIENDS_MAX_CONNECTIONS (503 when full).
// A ticket follows each accepted TCP socket until it closes, whether or not the upgrade completed, so a count can
// never leak.

import { clientKey } from './address.js';
import { DailyCap, RateLimiter } from './ratelimit.js';

const PROXY_WARNING_INTERVAL_MS = 60_000;

class Ticket {
    // `key` is the address key the limits here count by; `wideKey` the coarser one online Friends' limits use, and
    // `netKey` the coarsest, for the relay held per network (address.js).
    constructor(admission, { key, wideKey, netKey }) {
        this.admission = admission;
        this.key = key;
        this.wideKey = wideKey;
        this.netKey = netKey;
        this.state = 'pending';
    }

    // The connection checked in (or a replica proved itself): it moves from the unauthenticated budget to the
    // checked-in one.
    authenticate() {
        if (this.state !== 'pending') return;
        this.state = 'authenticated';
        this.admission.pending -= 1;
        this.admission.authenticated += 1;
    }

    release() {
        if (this.state === 'released') return;
        if (this.state === 'pending') this.admission.pending -= 1;
        else this.admission.authenticated -= 1;
        this.state = 'released';
        const open = (this.admission.open.get(this.key) ?? 1) - 1;
        if (open > 0) this.admission.open.set(this.key, open);
        else this.admission.open.delete(this.key);
    }
}

export class Admission {
    constructor({ config, clock, log }) {
        const { limits } = config;
        this.limits = limits;
        this.trusted = config.trustedProxies;
        this.clock = clock;
        this.log = log;
        this.rate = new RateLimiter({ limit: limits.connectionsPerAddress, windowMs: 60_000, clock });
        this.newIds = new DailyCap({ limit: limits.newIdsPerAddressPerDay });
        this.open = new Map(); // address key -> open sockets
        this.pending = 0;
        this.authenticated = 0;
        this.lastProxyWarning = -Infinity;
    }

    refuse(status, text, scope) {
        this.log('rate_limited', { scope });
        return { ok: false, status, text };
    }

    // A header from a peer that is not a configured proxy is ignored. Logged at most once a minute: after the
    // ingress moves to another address every client shares the ingress's key, which the admin must notice.
    noteIgnoredHeader() {
        const now = this.clock.now();
        if (now - this.lastProxyWarning < PROXY_WARNING_INTERVAL_MS) return;
        this.lastProxyWarning = now;
        this.log('proxy_untrusted', { reason: 'x-real-ip from a peer outside FRIENDS_TRUSTED_PROXY' });
    }

    admit(req, socket) {
        const { key, wideKey, netKey, forwardedIgnored } = clientKey(req, socket, this.trusted);
        if (forwardedIgnored) this.noteIgnoredHeader();
        if (!this.rate.allow(key)) return this.refuse(429, 'Too Many Requests', 'connections');
        if ((this.open.get(key) ?? 0) >= this.limits.connectionsPerAddressOpen) {
            return this.refuse(429, 'Too Many Requests', 'address');
        }
        if (this.pending >= this.limits.maxUnauthenticated) {
            return this.refuse(503, 'Service Unavailable', 'unauthenticated');
        }
        if (this.authenticated >= this.limits.maxConnections) {
            return this.refuse(503, 'Service Unavailable', 'capacity');
        }
        this.open.set(key, (this.open.get(key) ?? 0) + 1);
        this.pending += 1;
        const ticket = new Ticket(this, { key, wideKey, netKey });
        socket.once('close', () => ticket.release());
        return { ok: true, ticket };
    }

    // Once a minute: forget connection-rate entries not seen for 10 minutes, and yesterday's new-ID counts.
    sweep(day) {
        this.rate.sweep();
        this.newIds.roll(day);
    }
}
