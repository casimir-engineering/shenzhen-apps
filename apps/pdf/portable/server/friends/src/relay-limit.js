// How long a relayed session may last (HOST-PROTOCOL-ONLINE.md § Relay credentials; ADR 0010). coturn checks a TURN
// REST credential's expiry only when an allocation starts and then keeps its key for the session, so an allocation
// refreshed every few minutes would live for ever, and a few people could hold every relay port. The host hears of
// each allocation from coturn's statistics (relay-events.js) and ends it through coturn's CLI once
// FRIENDS_TURN_MAX_SESSION_S have passed since its credential was issued. The username carries the credential's
// expiry, so the bound holds across a restart of this service; an app whose relayed connection ends this way asks
// for a new credential, as after any dropped connection.
//
// The CLI controls all of coturn (it can stop it), so it listens only where this service reaches it and takes a
// password derived from the TURN secret, which coturn's configuration already holds.

import crypto from 'node:crypto';
import net from 'node:net';

import { MAX_ALLOCATE_LIFETIME_S } from './coturn-config.js';

const RETRY_MS = 30_000;
const MAX_TRACKED = 100_000;
const ALLOCATION = /^\d{1,20}$/;
const PROMPT = '> ';

export function coturnCliPassword(secret) {
    return crypto.createHmac('sha256', String(secret)).update('SZFriends coturn cli v1').digest('base64url');
}

// Ends allocations past their bound. `cancel(ids)` resolves true when coturn took the request.
export class RelaySessionLimit {
    constructor({ clock, maxSessionS, credentialTtlS, cancel, allocationLifetimeS = MAX_ALLOCATE_LIFETIME_S,
        log = () => {} }) {
        this.clock = clock;
        this.maxSessionMs = maxSessionS * 1000;
        // An allocation past its bound that coturn has said nothing about for longer than an allocation lives
        // unrefreshed, and a minute, is forgotten: coturn restarted, or ended it without a word. Were it still alive,
        // its next refresh would bring it back, already due. Without this, such ids would be asked about for ever.
        this.forgetAfterMs = (allocationLifetimeS + 60) * 1000;
        this.credentialTtlS = credentialTtlS;
        this.cancel = cancel;
        this.log = log;
        this.live = new Map(); // coturn allocation id -> { deadlineMs, askedAt, seenMs: coturn's last word on it }
        this.busy = false;
        this.counts = { ended: 0, failed: 0 };
    }

    // From coturn: an allocation started, was refreshed or ended. A refresh counts as a start for one this service
    // never heard begin (it restarted meanwhile); the deadline comes from the username either way.
    onStatus({ username, allocation, status }) {
        if (!ALLOCATION.test(String(allocation))) return;
        if (status === 'deleted') {
            this.live.delete(allocation);
            return;
        }
        const known = this.live.get(allocation);
        if (known) {
            known.seenMs = this.clock.now();
            return;
        }
        if (this.live.size >= MAX_TRACKED) return;
        this.live.set(allocation, { deadlineMs: this.deadline(username), askedAt: null, seenMs: this.clock.now() });
    }

    // The credential's issue time plus the bound. A username without a readable expiry, or one issued for longer
    // than this host's credentials, counts from now: the bound is never later than now plus the bound.
    deadline(username) {
        const now = this.clock.now();
        const expires = Number(String(username).split(':')[0]);
        const issued = Number.isSafeInteger(expires) && expires > 0 ? (expires - this.credentialTtlS) * 1000 : now;
        return Math.min(issued, now) + this.maxSessionMs;
    }

    // Once a second: asks coturn to end every allocation past its bound, and again every 30 s until it has ended.
    async sweep() {
        if (this.busy || this.live.size === 0) return;
        const now = this.clock.now();
        const due = [];
        for (const [id, allocation] of this.live) {
            if (allocation.deadlineMs > now) continue;
            if (now - Math.max(allocation.deadlineMs, allocation.seenMs) > this.forgetAfterMs) {
                this.live.delete(id);
                continue;
            }
            if (allocation.askedAt !== null && now - allocation.askedAt < RETRY_MS) continue;
            allocation.askedAt = now;
            due.push(id);
        }
        if (due.length === 0) return;
        this.busy = true;
        try {
            const ok = await this.cancel(due).catch(() => false);
            this.counts[ok ? 'ended' : 'failed'] += due.length;
            this.log('relay', { state: ok ? 'sessions_ended' : 'end_failed', count: due.length });
        } finally {
            this.busy = false;
        }
    }
}

// Asks coturn's CLI to end these allocations: the password, then `cs <id>` for each, one line at a time (coturn
// reads each arrival as one command), then `quit`. Resolves true once coturn has answered every line.
export function cancelSessions({ host, port, password, ids, timeoutMs = 5000 }) {
    const lines = [password, ...ids.filter((id) => ALLOCATION.test(String(id))).map((id) => `cs ${id}`), 'quit'];
    return new Promise((resolve) => {
        const socket = net.connect({ host, port });
        let text = '';
        let sent = 0;
        const finish = (ok) => {
            clearTimeout(timer);
            socket.destroy();
            resolve(ok);
        };
        const timer = setTimeout(() => finish(false), timeoutMs);
        timer.unref?.();
        // coturn resets the connection as it closes it after `quit`, so an error then is the end, not a failure.
        socket.on('error', () => finish(sent === lines.length));
        socket.on('close', () => finish(sent === lines.length));
        socket.on('data', (chunk) => {
            text = (text + chunk.toString('latin1')).slice(-4096);
            if (sent === 1 && text.includes('Enter password:')) {
                finish(false); // the password was refused
                return;
            }
            // The first line answers the password prompt; each later one waits for the prompt after the previous.
            const ready = sent === 0 ? text.includes('Enter password:') : text.endsWith(PROMPT);
            if (!ready || sent >= lines.length) return;
            text = '';
            socket.write(`${lines[sent]}\r\n`);
            sent += 1;
        });
    });
}
