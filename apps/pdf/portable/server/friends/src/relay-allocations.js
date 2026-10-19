// How much of the relay one person, one network and everyone together hold at once (HOST-PROTOCOL-ONLINE.md § Relay
// credentials; ADR 0010). The hourly credential budgets bound how often relay time is asked for, not how much is held:
// with relayed sessions lasting up to FRIENDS_TURN_MAX_SESSION_S, a handful of identities could otherwise fill every
// relay port. So the host counts, per share, the credentials it issued that are still unused and unexpired, and the
// allocations coturn reports alive for them (relay-events.js), and refuses another credential when a share is full.
// A credential counts in several shares at once: its helper identity or guest address, its network (IPv4 /24 or
// IPv6 /56: identities cost nothing to make, networks do), the host's whole relay, and for a pair of friends drawing
// on the reserve, that pair (online.js decides which shares apply).
//
// A credential counts once until coturn reports an allocation for it, then once per live allocation (coturn allows
// two per credential, user-quota). What is held is known only from coturn's statistics, in memory: after a restart of
// this service, allocations made before it count once their next refresh is reported, and until then only new
// credentials do.

import { MAX_ALLOCATE_LIFETIME_S } from './coturn-config.js';

const MAX_TRACKED = 100_000;
const ALLOCATION = /^\d{1,20}$/;
const RELAY = 'relay'; // the share every credential counts in

export class RelayAllocationCap {
    constructor({ clock, allocationLifetimeS = MAX_ALLOCATE_LIFETIME_S, maxTracked = MAX_TRACKED }) {
        this.clock = clock;
        this.maxTracked = maxTracked;
        // coturn's silence about an allocation for longer than it lives unrefreshed, and a minute, means it ended.
        this.forgetAfterMs = (allocationLifetimeS + 60) * 1000;
        this.credentials = new Map(); // attempt label -> { owners, expiresMs, allocations: Set of allocation ids }
        this.allocations = new Map(); // coturn allocation id -> { attempt, seenMs }
        this.byOwner = new Map(); // owner -> Set of attempt labels
    }

    // What `owner` (a share, such as "identity:<hex>", "guest:<address key>" or "net:<address key>") holds now.
    held(owner) {
        const now = this.clock.now();
        let count = 0;
        for (const attempt of this.byOwner.get(owner) ?? []) {
            const credential = this.credentials.get(attempt);
            const live = credential.allocations.size;
            count += live > 0 ? live : credential.expiresMs > now ? 1 : 0;
        }
        return count;
    }

    allows(owner, cap) {
        return this.held(owner) < cap;
    }

    // The shares a new credential would count in, or null when one is full. `own` and `net` are [share, cap];
    // `pair` is [share, cap] for a pair of friends who answered each other lately, or null. Of the `capacity` the
    // host's relay has, `reserve` is kept for such pairs, each holding at most its cap of it, so strangers filling
    // the relay cannot keep friends off it.
    admit({ own, net, pair, capacity, reserve }) {
        if (!this.canTrack() || !this.allows(...own) || !this.allows(...net)) return null;
        const total = this.held(RELAY);
        const shares = [own[0], net[0], RELAY];
        if (total < capacity - reserve) return shares;
        if (total >= capacity || !pair || !this.allows(...pair)) return null;
        return [...shares, pair[0]];
    }

    // Whether another credential can be remembered. One that could not would hold nothing, so it is never issued.
    canTrack() {
        if (this.credentials.size >= this.maxTracked) this.prune();
        return this.credentials.size < this.maxTracked;
    }

    // `owners`: every share the credential counts in.
    issued({ attempt, owners, expiresS }) {
        if (!this.canTrack()) return false;
        this.credentials.set(attempt, { owners, expiresMs: expiresS * 1000, allocations: new Set() });
        for (const owner of owners) {
            if (!this.byOwner.has(owner)) this.byOwner.set(owner, new Set());
            this.byOwner.get(owner).add(attempt);
        }
        return true;
    }

    // From coturn, for allocations under this host's TURN REST usernames ("<expiry>:<attempt>").
    onStatus({ username, allocation, status }) {
        if (!ALLOCATION.test(String(allocation))) return;
        if (status === 'deleted') {
            this.forget(allocation);
            return;
        }
        const attempt = String(username).split(':')[1];
        const credential = this.credentials.get(attempt);
        if (!credential) return;
        const known = this.allocations.get(allocation);
        if (known && known.attempt !== attempt) this.forget(allocation);
        credential.allocations.add(allocation);
        this.allocations.set(allocation, { attempt, seenMs: this.clock.now() });
    }

    forget(allocation) {
        const known = this.allocations.get(allocation);
        if (!known) return;
        this.allocations.delete(allocation);
        this.credentials.get(known.attempt)?.allocations.delete(allocation);
    }

    // Once a second, from the online service's sweep: drops allocations coturn has gone quiet about, and expired
    // credentials with nothing left alive.
    prune() {
        const now = this.clock.now();
        for (const [allocation, known] of this.allocations) {
            if (now - known.seenMs > this.forgetAfterMs) this.forget(allocation);
        }
        for (const [attempt, credential] of this.credentials) {
            if (credential.expiresMs > now || credential.allocations.size > 0) continue;
            this.credentials.delete(attempt);
            for (const owner of credential.owners) {
                const owned = this.byOwner.get(owner);
                owned?.delete(attempt);
                if (owned?.size === 0) this.byOwner.delete(owner);
            }
        }
    }
}
