// Signalling sessions (HOST-PROTOCOL-ONLINE.md § Connection setup): a sid joins the caller's end to the target's.
// Each end is a connection on this host, the host link toward another host, or nobody. Until a target speaks, an open
// may wait at several ends at once (one person's devices, each with its own record under the person's rendezvous
// key): the first to speak becomes the sid's far end and the others are let go. The host forwards opaque payloads and
// never says whether the far end exists: an open is answered at once, a missing or silent target looks exactly like
// one that chose not to answer, and a close or a disconnect reaches the other end only from an end that has already
// spoken (opening counts).

export const LOCAL = 'local';
export const REMOTE = 'remote';

// `identityHash` (hex) names the device behind a target's end, or the caller; null for a browser.
export function localEnd(session) {
    return { type: LOCAL, session, identityHash: session.identityHash?.toString('hex') ?? null, spoke: false, sent: 0,
        credentials: 0 };
}

export function remoteEnd(hostId, identityHash = null) {
    return { type: REMOTE, hostId, identityHash, spoke: false, sent: 0, credentials: 0 };
}

export function sameEnd(x, y) {
    if (!x || !y || x.type !== y.type) return false;
    return x.type === LOCAL ? x.session === y.session : x.hostId === y.hostId;
}

// What the indexes file an end under: its connection, or the host its link leads to.
function endKey(end) {
    return end.type === LOCAL ? end.session : `host:${end.hostId}`;
}

function endsOf(entry) {
    return [entry.a, entry.b, ...entry.waiting].filter(Boolean);
}

export class SidTable {
    constructor({ clock, lifetimeMs, waitMs }) {
        this.clock = clock;
        this.lifetimeMs = lifetimeMs;
        this.waitMs = waitMs;
        this.entries = new Map();
        this.byEnd = new Map(); // connection or "host:<id>" -> Set of entries it takes part in
        this.opened = new Map(); // connection -> how many sids it opened and still holds
    }

    index(entry, end) {
        const key = endKey(end);
        let set = this.byEnd.get(key);
        if (!set) {
            set = new Set();
            this.byEnd.set(key, set);
        }
        set.add(entry);
    }

    // `end` left `entry`; it stays filed there only if another end of the entry has the same connection or host.
    unindex(entry, end) {
        const key = endKey(end);
        if (endsOf(entry).some((other) => endKey(other) === key)) return;
        const set = this.byEnd.get(key);
        set?.delete(entry);
        if (set?.size === 0) this.byEnd.delete(key);
    }

    // `a` is the caller's end. The target's end `b` stays null until one of `waiting` (the ends an open was
    // delivered to) speaks. A link whose sender is offline waits up to `waitMs` before the ordinary lifetime starts.
    create({ sid, a, via, linkId = null, linkHash = null, held = false, originHere = true }) {
        const now = this.clock.now();
        const entry = { sid, a, b: null, waiting: [], via, linkId, linkHash, held, originHere, payload: null,
            caller: null, expiresAt: now + (held ? this.waitMs : this.lifetimeMs) };
        a.spoke = true;
        this.entries.set(sid, entry);
        this.index(entry, a);
        if (a.type === LOCAL) this.opened.set(a.session, (this.opened.get(a.session) ?? 0) + 1);
        return entry;
    }

    get(sid) {
        return typeof sid === 'string' ? this.entries.get(sid) ?? null : null;
    }

    // Where `end` sits in `entry` ('a', 'b' or 'waiting', with the end itself), or null.
    place(entry, end) {
        if (sameEnd(entry.a, end)) return { side: 'a', end: entry.a };
        if (sameEnd(entry.b, end)) return { side: 'b', end: entry.b };
        const waiting = entry.waiting.find((w) => sameEnd(w, end));
        return waiting ? { side: 'waiting', end: waiting } : null;
    }

    // The open was delivered to `end`; the sid's lifetime starts now if it was held for an offline sender.
    deliver(entry, end) {
        if (!entry.waiting.some((w) => sameEnd(w, end))) {
            entry.waiting.push(end);
            this.index(entry, end);
        }
        if (entry.held) {
            entry.held = false;
            entry.expiresAt = this.clock.now() + this.lifetimeMs;
        }
    }

    // `end`, a waiting end, spoke first: it becomes the far end. Returns the ends that were let go.
    choose(entry, end) {
        const others = entry.waiting.filter((w) => w !== end);
        entry.b = end;
        entry.waiting = [];
        for (const other of others) this.unindex(entry, other);
        return others;
    }

    // A waiting end left without speaking: it becomes nobody.
    forget(entry, end) {
        const before = entry.waiting.length;
        entry.waiting = entry.waiting.filter((w) => w !== end);
        if (entry.waiting.length !== before) this.unindex(entry, end);
    }

    delete(sid) {
        const entry = this.entries.get(sid);
        if (!entry) return;
        this.entries.delete(sid);
        for (const end of endsOf(entry)) {
            const set = this.byEnd.get(endKey(end));
            set?.delete(entry);
            if (set?.size === 0) this.byEnd.delete(endKey(end));
        }
        if (entry.a.type === LOCAL) {
            const n = (this.opened.get(entry.a.session) ?? 1) - 1;
            if (n > 0) this.opened.set(entry.a.session, n);
            else this.opened.delete(entry.a.session);
        }
    }

    // Every sid `end` takes part in, with its place.
    involving(end) {
        const out = [];
        for (const entry of this.byEnd.get(endKey(end)) ?? []) {
            const place = this.place(entry, end);
            if (place) out.push({ entry, ...place });
        }
        return out;
    }

    // Every sid with an end on a host for which `gone(hostId)` is true.
    withRemoteEnds(gone) {
        const out = new Set();
        for (const [key, set] of this.byEnd) {
            if (typeof key === 'string' && gone(key.slice('host:'.length))) for (const entry of set) out.add(entry);
        }
        return [...out];
    }

    // Sids a connection opened and still holds open.
    openedBy(session) {
        return this.opened.get(session) ?? 0;
    }

    expired() {
        const now = this.clock.now();
        return [...this.entries.values()].filter((entry) => entry.expiresAt <= now);
    }

    get size() {
        return this.entries.size;
    }
}
