// Relay statistics for the admin dashboard (brief § Admin statistics, Relay): relayed sessions now; sessions and
// bytes per day; average and peak rate; sessions held at the cap; the share of answered connections that needed the
// relay. Two sources, joined by the relay attempt id the host puts in every TURN username:
//
// - this host's own signalling: opens, answers and relay credentials, per kind (helper to helper, Add by ID, link);
// - coturn's per-allocation events (relay-events.js): allocation start and end, and byte counts it reports every
//   4,096 packets and at the end of each allocation.
//
// Nothing here holds an address, an identity or a link: attempts are random ids, allocations coturn's counters.
// Today's counters live in memory and are written to relay_daily (one row per host per statistics day) once a
// minute, at every day change and when the host stops; a restart carries on from the stored row.

import { dayString } from './clock.js';
import { emptyRelayDay, loadRelayDay, saveRelayDay } from './online-store.js';

// A minute at or above this share of max-bps, in either direction, counts as held at the cap: coturn reports bytes
// in batches of 4,096 packets (about 2.5 MB at full rate), so a capped minute can read a few percent low.
const CAP_SHARE = 0.9;
const ATTEMPT_TTL_MS = 2 * 3_600_000;
const MAX_TRACKED = 100_000;
const KINDS = new Set(['helper', 'id', 'link']);

export class RelayStats {
    constructor({ clock, timeZone, db = null, hostId, maxBps = 625_000 }) {
        this.clock = clock;
        this.timeZone = timeZone;
        this.db = db;
        this.hostId = hostId;
        this.maxBps = maxBps;
        this.today = null;
        this.counters = emptyRelayDay();
        this.attempts = new Map(); // attempt id -> { kind, sid, at }
        this.sidsRelayed = new Set(); // sids already counted as relayed
        this.allocations = new Map(); // coturn allocation id -> live session
    }

    // Today's counters; at a day change the finished day is written and a new one starts.
    day() {
        const key = dayString(this.clock.now(), this.timeZone);
        if (this.today !== key) {
            if (this.today !== null) this.flush();
            this.today = key;
            this.counters = (this.db ? loadRelayDay(this.db, { day: key, hostId: this.hostId }) : null)
                ?? emptyRelayDay();
        }
        return this.counters;
    }

    load() {
        this.day();
    }

    flush() {
        if (!this.db || this.today === null) return;
        this.counters.now_sessions = this.allocations.size;
        saveRelayDay(this.db, { day: this.today, hostId: this.hostId, counters: this.counters });
    }

    noteOpen(kind) {
        if (KINDS.has(kind)) this.day()[`opens_${kind}`] += 1;
    }

    // Counted once per sid, on the host where the sid was opened, when a target first speaks.
    noteAnswered(kind) {
        if (KINDS.has(kind)) this.day()[`answered_${kind}`] += 1;
    }

    // `kind` is 'test' for the dashboard's test credential, which counts as a session but not as a connection.
    noteCredential({ attempt, kind, sid }) {
        this.day().credentials += 1;
        if (this.attempts.size >= MAX_TRACKED) this.attempts.clear();
        this.attempts.set(attempt, { kind, sid, at: this.clock.now() });
    }

    // From coturn: an allocation started, refreshed or ended. The username is "<expiry>:<attempt id>".
    onStatus({ username, allocation, status }) {
        const attemptId = String(username).split(':').slice(1).join(':');
        if (status === 'new') {
            const attempt = this.attempts.get(attemptId);
            const counters = this.day();
            counters.sessions += 1;
            // A connection relayed through both ends' allocations is still one relayed connection.
            const key = attempt ? attempt.sid : `allocation:${allocation}`;
            if (!this.sidsRelayed.has(key)) {
                if (this.sidsRelayed.size >= MAX_TRACKED) this.sidsRelayed.clear();
                this.sidsRelayed.add(key);
                counters[KINDS.has(attempt?.kind) ? `relayed_${attempt.kind}` : 'relayed_other'] += 1;
            }
            if (this.allocations.size < MAX_TRACKED) {
                this.allocations.set(allocation, { minuteUp: 0, minuteDown: 0, capped: false });
            }
        } else if (status === 'deleted') {
            this.allocations.delete(allocation);
        }
    }

    // `rcvb` is what the client sent to the relay (up), `sentb` what the relay sent to the client (down); coturn
    // reports both as deltas since its previous report. Peer-side counters mirror them and are not added again.
    onTraffic({ allocation, kind, rcvb, sentb }) {
        if (kind !== 'traffic') return;
        const counters = this.day();
        counters.bytes_up += rcvb;
        counters.bytes_down += sentb;
        const session = this.allocations.get(allocation);
        if (!session) return;
        session.minuteUp += rcvb;
        session.minuteDown += sentb;
    }

    // Once a minute: session time, the aggregate peak, minutes and sessions at the cap, then today's row.
    // `windowS` lets a test measure windows of another length.
    tick({ windowS = 60 } = {}) {
        const counters = this.day();
        let total = 0;
        for (const session of this.allocations.values()) {
            total += session.minuteUp + session.minuteDown;
            counters.session_seconds += windowS;
            if (Math.max(session.minuteUp, session.minuteDown) / windowS >= CAP_SHARE * this.maxBps) {
                counters.capped_minutes += 1;
                if (!session.capped) {
                    session.capped = true;
                    counters.capped_sessions += 1;
                }
            }
            session.minuteUp = 0;
            session.minuteDown = 0;
        }
        counters.peak_bps = Math.max(counters.peak_bps, Math.round((total * 8) / windowS));
        const now = this.clock.now();
        for (const [id, attempt] of this.attempts) if (now - attempt.at > ATTEMPT_TTL_MS) this.attempts.delete(id);
        this.flush();
    }

    // What a replica sends the main host with its minute report.
    snapshot() {
        const counters = this.day();
        return { day: this.today, counters: { ...counters, now_sessions: this.allocations.size } };
    }
}
