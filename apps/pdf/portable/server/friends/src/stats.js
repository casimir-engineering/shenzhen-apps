// The admin statistics (brief § Admin statistics), computed from the database and the live connection maps. Both
// the dashboard page and /stats.json render this one object, so the numbers on the page are the numbers tests
// check.

import { addDays, dayString, hourLabel, minuteOf } from './clock.js';
import { metaGet } from './db.js';
import { devicesPerPerson } from './device-records.js';
import { idTableState } from './id-sync.js';
import { THREE_WORD_THRESHOLD, TWO_WORD_SPACE } from './protocol.js';
import { publishedDates } from './records.js';
import { summarizeRelay } from './relay-summary.js';

// A replica that has not reported for three minutes is shown as not reporting, and its last count no longer
// adds to "online now".
const REPORT_FRESH_MS = 3 * 60_000;

function count(db, sql, ...args) {
    return db.prepare(sql).get(...args).n;
}

function onlineHosts(host, now) {
    const rows = [];
    const versions = new Map(host.liveListVersions());
    for (const entry of host.list.hosts) {
        if (entry.id === host.config.hostId) {
            rows.push({ id: entry.id, connections: host.liveCount(), status: 'this_host' });
            continue;
        }
        const report = host.replicaReports.get(entry.id);
        const fresh = report && now - report.at < REPORT_FRESH_MS;
        rows.push({ id: entry.id, connections: fresh ? report.connections : null,
            status: fresh ? 'reporting' : 'not_reporting' });
        if (fresh) {
            for (const [version, n] of report.listVersions) versions.set(version, (versions.get(version) ?? 0) + n);
        }
    }
    if (!host.list.hosts.some((entry) => entry.id === host.config.hostId)) {
        rows.unshift({ id: host.config.hostId, connections: host.liveCount(), status: 'this_host' });
    }
    const total = rows.reduce((sum, row) => sum + (row.connections ?? 0), 0);
    return { total, rows, versions };
}

// Peak online per hour over the last 24 hours, from the per-minute samples summed across hosts. The last bucket is
// the current hour so far.
function last24Hours(db, now, timeZone) {
    const nowMinute = minuteOf(now);
    const currentHourStart = nowMinute - (nowMinute % 60);
    const firstHourStart = currentHourStart - 23 * 60;
    const totals = db.prepare(`SELECT minute, SUM(connections) AS total FROM connection_samples
        WHERE minute >= ? GROUP BY minute`).all(firstHourStart);
    const buckets = Array.from({ length: 24 }, (_, i) => ({
        start: (firstHourStart + i * 60) * 60_000,
        label: hourLabel((firstHourStart + i * 60) * 60_000, timeZone),
        value: 0,
    }));
    for (const row of totals) {
        const index = Math.floor((row.minute - firstHourStart) / 60);
        if (index >= 0 && index < 24) buckets[index].value = Math.max(buckets[index].value, row.total);
    }
    return buckets.map(({ label, value }) => ({ label, value }));
}

function listAdoption(host, versions, d30) {
    const { db } = host;
    const actives = count(db, 'SELECT COUNT(*) AS n FROM identities WHERE last_day >= ?', d30);
    const published = publishedDates(db);
    const byVersion = new Map();
    for (const row of db.prepare(`SELECT list_version AS version, COUNT(*) AS n FROM identities
        WHERE last_day >= ? GROUP BY list_version`).all(d30)) {
        byVersion.set(row.version ?? 0, row.n);
    }
    for (const version of versions.keys()) if (!byVersion.has(version)) byVersion.set(version, 0);
    if (!byVersion.has(host.list.version)) byVersion.set(host.list.version, 0);
    const onlineTotal = [...versions.values()].reduce((a, b) => a + b, 0);
    const rows = [...byVersion.entries()].sort((a, b) => b[0] - a[0]).map(([version, users]) => ({
        version,
        latest: version === host.list.version,
        published: published.get(version) ?? null,
        users,
        share: actives > 0 ? users / actives : 0,
        online: versions.get(version) ?? 0,
        onlineShare: onlineTotal > 0 ? (versions.get(version) ?? 0) / onlineTotal : 0,
    }));
    return { latest: host.list.version, actives, onlineTotal, rows };
}

// Release versions are YY.M.DD-BUILD, so text order puts 26.9 after 26.10; compare the numbers instead.
export function compareVersions(a, b) {
    const left = String(a).split(/\D+/).filter(Boolean).map(Number);
    const right = String(b).split(/\D+/).filter(Boolean).map(Number);
    for (let i = 0; i < Math.max(left.length, right.length); i++) {
        const diff = (left[i] ?? -1) - (right[i] ?? -1);
        if (diff !== 0) return diff;
    }
    return 0;
}

// Most users first; among equals, the newest version first.
function appVersions(db, d30, actives) {
    return db.prepare(`SELECT app_version AS version, COUNT(*) AS n FROM identities WHERE last_day >= ?
        GROUP BY app_version`).all(d30).map((row) => ({
        version: row.version ?? 'unknown',
        users: row.n,
        share: actives > 0 ? row.n / actives : 0,
    })).sort((a, b) => b.users - a.users || compareVersions(b.version, a.version));
}

function ids(db, today) {
    const day = db.prepare('SELECT reservations, collisions, renames, releases FROM daily_stats WHERE day = ?')
        .get(today) ?? { reservations: 0, collisions: 0, renames: 0, releases: 0 };
    const reserved = count(db, 'SELECT COUNT(*) AS n FROM identities WHERE friends_id IS NOT NULL');
    const twoWord = count(db, `SELECT COUNT(*) AS n FROM identities
        WHERE friends_id IS NOT NULL AND friends_id NOT LIKE '%-%-%'`);
    const totals = db.prepare(`SELECT COALESCE(SUM(collisions), 0) AS c, COALESCE(SUM(renames), 0) AS r
        FROM daily_stats`).get();
    return {
        reserved,
        reservationsToday: day.reservations,
        collisionsToday: day.collisions,
        renamesToday: day.renames,
        releasesToday: day.releases,
        collisionsTotal: totals.c,
        renamesTotal: totals.r,
        twoWord,
        twoWordShare: twoWord / TWO_WORD_SPACE,
        threshold: THREE_WORD_THRESHOLD,
        thresholdShare: THREE_WORD_THRESHOLD / TWO_WORD_SPACE,
    };
}

// Identities seen for the first time, which a flood of throwaway keys inflates and returning users do not; shown
// beside unique users so the two can be told apart.
function newIdentities(db, today, d7, d30) {
    const sum = (from) => count(db, 'SELECT COALESCE(SUM(new_identities), 0) AS n FROM daily_stats WHERE day >= ?',
        from);
    return { today: sum(today), last7Days: sum(d7), last30Days: sum(d30) };
}

// People and their devices (protocol 3): a person is a root key, each computer a device. Today's counts come from
// today's salted sets; past days from the daily rows the rollup wrote. Joins are devices seen for the first time
// under a person whose first device they are not; revocations are those first seen in a person's chain.
function people(db, today, d30) {
    const days = [];
    for (let i = 13; i >= 0; i--) {
        const day = addDays(today, -i);
        const row = db.prepare('SELECT uniques, device_uniques, joins, revocations FROM daily_stats WHERE day = ?')
            .get(day) ?? { uniques: 0, device_uniques: 0, joins: 0, revocations: 0 };
        const live = day === today;
        days.push({ day,
            people: live ? count(db, 'SELECT COUNT(*) AS n FROM daily_seen WHERE day = ?', day) : row.uniques,
            devices: live ? count(db, 'SELECT COUNT(*) AS n FROM daily_seen_devices WHERE day = ?', day)
                : row.device_uniques,
            joins: row.joins, revocations: row.revocations });
    }
    const todayRow = days[days.length - 1];
    return { peopleToday: todayRow.people, devicesToday: todayRow.devices, joinsToday: todayRow.joins,
        revocationsToday: todayRow.revocations, perPerson: devicesPerPerson(db, d30), days };
}

export function summarize(host) {
    const { db, config } = host;
    const now = host.clock.now();
    const today = dayString(now, config.statsTimeZone);
    const d7 = addDays(today, -6);
    const d30 = addDays(today, -29);
    const online = onlineHosts(host, now);
    const lists = listAdoption(host, online.versions, d30);
    return {
        generatedAt: new Date(now).toISOString(),
        timeZone: config.statsTimeZone,
        today,
        host: { id: config.hostId, role: host.isMain ? 'main' : 'replica', idTable: idTableState(db),
            region: host.list.hosts.find((entry) => entry.id === config.hostId)?.region ?? null },
        online: { now: online.total, hosts: online.rows, last24Hours: last24Hours(db, now, config.statsTimeZone) },
        // Today's set is the only per-day set kept (db.js); over 7 and 30 days an identity was active when its
        // latest check-in falls in the window.
        uniques: {
            today: count(db, 'SELECT COUNT(*) AS n FROM daily_seen WHERE day = ?', today),
            last7Days: count(db, 'SELECT COUNT(*) AS n FROM identities WHERE last_day >= ?', d7),
            last30Days: count(db, 'SELECT COUNT(*) AS n FROM identities WHERE last_day >= ?', d30),
            allTime: metaGet(db, 'identities_ever'),
        },
        newIdentities: newIdentities(db, today, d7, d30),
        people: people(db, today, d30),
        lists,
        ids: ids(db, today),
        appVersions: appVersions(db, d30, lists.actives),
        hosts: host.list.hosts.map((entry) => {
            const live = online.rows.find((row) => row.id === entry.id);
            return { id: entry.id, role: entry.role, region: entry.region, priority: entry.priority,
                main: entry.rendezvous && entry === host.list.hosts.find((h) => h.rendezvous),
                connections: live?.connections ?? null, status: live?.status ?? 'not_reporting' };
        }),
        // Replicas that used up today's new Friends IDs (host-links.js): a busy replica or a compromised one.
        replicaNewIds: host.isMain ? { limit: config.limits.newIdsPerReplicaPerDay, atLimit: host.replicasAtLimit() }
            : null,
        // Online Friends and the relay (relay-summary.js): switched off, or what the relay carried.
        relay: summarizeRelay(host, today),
    };
}
