// How many opens reach one device, and from whom (HOST-PROTOCOL-ONLINE.md § Limits). Opens over these budgets are
// dropped without telling the caller, like any open nobody answers; the budgets make sure no one caller, and no one
// network, can use up a device's opens and so cut it off from the people it talks to.
//
// - On the caller's host, before delivery: per (target, caller identity) and per (target, caller address prefix,
//   an IPv4 address or an IPv6 /56). A browser opening a download link has no identity and counts by address only.
// - On the target's host, at delivery: a general budget per target, and a reserve per target that only callers it
//   answered in the last 7 days may use. The caller's host says whether the caller is one of those (`known`).
//
// Who answered whom is kept only as keyed hashes of the pair, in memory, for 7 days, and goes with the process.

import crypto from 'node:crypto';

import { ONLINE_LIMITS } from './online-protocol.js';
import { CostBudget } from './ratelimit.js';

const MINUTE = 60_000;
const PROCESS_KEY = crypto.randomBytes(32);

function pairKey(target, caller) {
    return crypto.createHmac('sha256', PROCESS_KEY).update(`${target}\n${caller}`).digest().subarray(0, 16)
        .toString('base64url');
}

export class IncomingGate {
    constructor({ clock, maxKnown = 50_000 }) {
        const L = ONLINE_LIMITS;
        const budget = (limit) => new CostBudget({ limit, windowMs: MINUTE, clock });
        this.clock = clock;
        this.pairs = budget(L.incomingPerCallerPerMinute);
        this.prefixes = budget(L.incomingPerPrefixPerMinute);
        this.general = budget(L.incomingPerMinute);
        this.reserve = budget(L.incomingReservedPerMinute);
        this.known = new Map(); // pair key -> when it is forgotten (ms); oldest first
        this.maxKnown = maxKnown;
    }

    // On the caller's host. `target` is the device's identity hash, `caller` the caller's (null for a browser),
    // `prefix` the caller's address key.
    admitCaller({ target, caller, prefix }) {
        if (caller && !this.pairs.take(pairKey(target, `id:${caller}`))) return false;
        return this.prefixes.take(pairKey(target, `prefix:${prefix}`));
    }

    isKnown(target, caller) {
        if (!caller) return false;
        const until = this.known.get(pairKey(target, caller));
        return until !== undefined && until > this.clock.now();
    }

    // On the target's host.
    admitTarget(target, known) {
        if (known && this.reserve.take(target)) return true;
        return this.general.take(target);
    }

    // `target` answered an open from `caller`: for 7 days, opens from `caller` may use `target`'s reserve.
    answered(target, caller) {
        if (!caller) return;
        const key = pairKey(target, caller);
        this.known.delete(key);
        if (this.known.size >= this.maxKnown) this.sweep();
        if (this.known.size >= this.maxKnown) this.known.delete(this.known.keys().next().value);
        this.known.set(key, this.clock.now() + ONLINE_LIMITS.answeredMemoryMs);
    }

    sweep() {
        const now = this.clock.now();
        for (const [key, until] of this.known) {
            if (until > now) break;
            this.known.delete(key);
        }
    }
}
