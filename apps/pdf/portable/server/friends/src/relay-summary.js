// The dashboard's relay section (brief § Admin statistics, Relay), from relay_daily: this host's live counters for
// today, the other hosts' rows as their minute reports left them. Both the page and /stats.json render this object.

import { addDays } from './clock.js';
import { cleanRelayDay, emptyRelayDay, relayDays } from './online-store.js';

const CAP_BPS = 5_000_000;
// A replica's row counts as live for "relayed now" while its reports are this fresh (as for connections).
const REPORT_FRESH_MS = 3 * 60_000;

function share(part, whole) {
    return whole > 0 ? part / whole : 0;
}

function add(total, row) {
    for (const [key, value] of Object.entries(row)) total[key] = (total[key] ?? 0) + value;
    return total;
}

function state(config) {
    if (!config.online.enabled) return 'off';
    return config.online.relay ? 'on' : 'no_relay';
}

export function summarizeRelay(host, today) {
    const { db, config, online } = host;
    const from = addDays(today, -29);
    const byDay = new Map();
    for (const row of relayDays(db, from)) {
        const counters = cleanRelayDay(row);
        if (!counters) continue;
        if (!byDay.has(row.day)) byDay.set(row.day, new Map());
        byDay.get(row.day).set(row.host_id, counters);
    }
    // This host's own counters for today are in memory; the stored row may be up to a minute behind.
    if (online) {
        const { day, counters } = online.stats.snapshot();
        if (!byDay.has(day)) byDay.set(day, new Map());
        byDay.get(day).set(config.hostId, counters);
    }
    const todayRows = byDay.get(today) ?? new Map();
    const total = [...todayRows.values()].reduce(add, emptyRelayDay());
    const now = host.clock.now();
    let nowSessions = online ? online.stats.allocations.size : 0;
    for (const [id, row] of todayRows) {
        const fresh = (host.replicaReports.get(id)?.at ?? -Infinity) > now - REPORT_FRESH_MS;
        if (id !== config.hostId && fresh) nowSessions += row.now_sessions;
    }
    const friendsAnswered = total.answered_helper + total.answered_id;
    const bytes = total.bytes_up + total.bytes_down;
    return {
        state: state(config),
        receiving: online ? online.relay.receiving : null,
        capBps: CAP_BPS,
        now: { sessions: nowSessions },
        today: {
            sessions: total.sessions,
            bytesUp: total.bytes_up,
            bytesDown: total.bytes_down,
            bytes,
            averageBps: total.session_seconds > 0 ? (bytes * 8) / total.session_seconds : 0,
            peakBps: Math.max(0, ...[...todayRows.values()].map((row) => row.peak_bps)),
            cappedSessions: total.capped_sessions,
            cappedMinutes: total.capped_minutes,
            credentials: total.credentials,
            opens: { friends: total.opens_helper + total.opens_id, links: total.opens_link },
            answered: { friends: friendsAnswered, links: total.answered_link },
            relayed: { friends: total.relayed_helper + total.relayed_id, links: total.relayed_link,
                other: total.relayed_other },
            share: { friends: share(total.relayed_helper + total.relayed_id, friendsAnswered),
                links: share(total.relayed_link, total.answered_link) },
        },
        hosts: [...todayRows].sort((a, b) => (a[0] < b[0] ? -1 : 1)).map(([id, row]) => ({ id,
            sessions: row.sessions, bytes: row.bytes_up + row.bytes_down, peakBps: row.peak_bps })),
        days: [...byDay].sort((a, b) => (a[0] < b[0] ? 1 : -1)).map(([day, rows]) => {
            const sum = [...rows.values()].reduce(add, emptyRelayDay());
            return { day, sessions: sum.sessions, bytes: sum.bytes_up + sum.bytes_down,
                peakBps: Math.max(0, ...[...rows.values()].map((row) => row.peak_bps)),
                cappedSessions: sum.capped_sessions };
        }),
        memory: online ? online.counts : null,
    };
}
