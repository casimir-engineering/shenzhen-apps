// In-memory counters for the host's limits. ADR 0005 § Privacy: what they count by is an address key (address.js:
// a keyed hash of the client's IPv4 address or IPv6 /64), never an address, and nothing here reaches the database
// or a log.

// Fixed-window counters per key, forgotten 10 minutes after a key was last seen. `maxKeys` bounds the map: a flood
// from more distinct prefixes than that is refused rather than allowed to grow memory without limit.
export class RateLimiter {
    constructor({ limit, windowMs, forgetMs = 10 * 60_000, maxKeys = 100_000, clock }) {
        this.limit = limit;
        this.windowMs = windowMs;
        this.forgetMs = forgetMs;
        this.maxKeys = maxKeys;
        this.clock = clock;
        this.entries = new Map();
    }

    // True when `key` may act now; counts the attempt either way so a flood stays refused.
    allow(key) {
        const now = this.clock.now();
        let entry = this.entries.get(key);
        if (!entry && this.entries.size >= this.maxKeys) {
            this.sweep();
            if (this.entries.size >= this.maxKeys) return false;
        }
        if (!entry || now - entry.windowStart >= this.windowMs) {
            entry = { windowStart: now, count: 0, lastSeen: now };
            this.entries.set(key, entry);
        }
        entry.count += 1;
        entry.lastSeen = now;
        return entry.count <= this.limit;
    }

    sweep() {
        const now = this.clock.now();
        for (const [key, entry] of this.entries) {
            if (now - entry.lastSeen >= this.forgetMs) this.entries.delete(key);
        }
    }

    get size() {
        return this.entries.size;
    }
}

// Per-connection message budget: a sliding count over the last window, small enough to keep in each session.
export class MessageBudget {
    constructor({ limit, windowMs, clock }) {
        this.limit = limit;
        this.windowMs = windowMs;
        this.clock = clock;
        this.stamps = [];
    }

    allow() {
        const now = this.clock.now();
        while (this.stamps.length > 0 && now - this.stamps[0] >= this.windowMs) this.stamps.shift();
        if (this.stamps.length >= this.limit) return false;
        this.stamps.push(now);
        return true;
    }
}

// At most `limit` uses per key per statistics day, all forgotten when the day changes. A slot is taken before the
// work it pays for and refunded when the work turns out not to need it, so two concurrent requests from one key
// can never both slip under the limit. A full map refuses: new keys wait for tomorrow rather than grow memory.
export class DailyCap {
    constructor({ limit, maxKeys = 100_000 }) {
        this.limit = limit;
        this.maxKeys = maxKeys;
        this.day = null;
        this.counts = new Map();
    }

    roll(day) {
        if (this.day === day) return;
        this.day = day;
        this.counts.clear();
    }

    take(key, day) {
        this.roll(day);
        const used = this.counts.get(key) ?? 0;
        if (used >= this.limit || (used === 0 && this.counts.size >= this.maxKeys)) return false;
        this.counts.set(key, used + 1);
        return true;
    }

    used(key, day) {
        return this.day === day ? this.counts.get(key) ?? 0 : 0;
    }

    refund(key, day) {
        if (this.day !== day) return;
        const used = this.counts.get(key) ?? 0;
        if (used <= 1) this.counts.delete(key);
        else this.counts.set(key, used - 1);
    }
}

// Fixed-window budgets where a use may cost more than one (a lookup of 20 keys costs 20), keyed by identity hash,
// link or address key. An exhausted window refuses without counting, so a client that waits gets its whole budget
// back. Online Friends (online.js) keeps one per kind of request.
export class CostBudget {
    constructor({ limit, windowMs, clock, maxKeys = 100_000 }) {
        this.limit = limit;
        this.windowMs = windowMs;
        this.clock = clock;
        this.maxKeys = maxKeys;
        this.entries = new Map();
    }

    take(key, cost = 1) {
        const now = this.clock.now();
        let entry = this.entries.get(key);
        if (!entry || now - entry.start >= this.windowMs) {
            if (!entry && this.entries.size >= this.maxKeys) {
                this.sweep();
                if (this.entries.size >= this.maxKeys) return false;
            }
            entry = { start: now, used: 0 };
            this.entries.set(key, entry);
        }
        if (entry.used + cost > this.limit) return false;
        entry.used += cost;
        return true;
    }

    sweep() {
        const now = this.clock.now();
        for (const [key, entry] of this.entries) if (now - entry.start >= this.windowMs) this.entries.delete(key);
    }
}
