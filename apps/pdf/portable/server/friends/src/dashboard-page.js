// The dashboard page, styled after the Friends host admin mockup: tiles for users, the last 24 hours online, host
// list adoption, Friends IDs, the relay (dashboard-relay.js), app versions and the hosts in the current list. The
// reader is the admin, who knows the service; text says what each number counts, not how it is computed.

import {
    CHART_CSS, barRows, clockTime, esc, lineChart, number, percent, shortDate, stackedBar, thresholdMeter,
} from './dashboard-charts.js';
import { renderPeople } from './dashboard-people.js';
import { renderRelay } from './dashboard-relay.js';

const PAGE_CSS = `
:root{--page:#f4f4f2;--card:#fff;--border:#e6e5e1;--text:#0b0b0b;--secondary:#52514e;--muted:#6b6a66;
--grid:#ebeae6;--series:#2a78d6;--wash:rgba(42,120,214,.10);--ord-1:#1c5cab;--ord-2:#3987e5;--ord-3:#86b6ef;
--good:#0b8a0b;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--page:#141413;--card:#1a1a19;--border:#2e2e2c;--text:#fff;
--secondary:#c3c2b7;--muted:#a3a29a;--grid:#2a2a28;--series:#3987e5;--wash:rgba(57,135,229,.12);--ord-1:#86b6ef;
--ord-2:#3987e5;--ord-3:#184f95;--good:#0ca30c}}
body{margin:0;background:var(--page);color:var(--text);
font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;
-webkit-font-smoothing:antialiased}
main{max-width:1240px;margin:0 auto;padding:32px 24px 48px;box-sizing:border-box;display:flex;
flex-direction:column;gap:20px}
header{display:flex;flex-wrap:wrap;align-items:flex-end;gap:12px 20px}
h1{margin:0;font-size:26px;font-weight:700}
h2{margin:0;font-size:15px;font-weight:600}
.sub{font-size:13px;color:var(--secondary)}
.updated{margin-left:auto;font-size:12px;color:var(--secondary)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:18px;display:flex;
flex-direction:column;gap:14px;min-width:0}
.tile{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:16px;display:flex;
flex-direction:column;gap:6px}
.inner{border:1px solid var(--border);border-radius:8px;padding:12px;display:flex;flex-direction:column;gap:4px}
.label{font-size:13px;color:var(--secondary)}
.inner .label{font-size:12px}
.big{font-size:52px;font-weight:600;line-height:1}
.value{font-size:28px;font-weight:600;line-height:1.1}
.inner .value{font-size:24px}
.note{font-size:12px;color:var(--muted)}
.row{display:flex;flex-wrap:wrap;gap:20px}
.row>.card{flex:1 1 400px}
.grid2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
.headline{display:flex;align-items:baseline;gap:10px}
.headline .value{font-size:34px}
.title-line{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px 16px}
.notice{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:12px 16px;font-size:13px}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--grid);font-size:13px}
th{color:var(--secondary);font-weight:600;font-size:12px}
td.num{font-variant-numeric:tabular-nums}
td strong{white-space:nowrap}
.scroll{overflow-x:auto}
details{font-size:12px;color:var(--secondary)}
details .scroll{max-height:180px;overflow:auto;margin-top:8px}
summary{cursor:pointer}
.ok{color:var(--good)}
${CHART_CSS}`;

function tile(label, value, note, big = false) {
    return `<div class="tile"><span class="label">${esc(label)}</span>`
        + `<span class="${big ? 'big' : 'value'}">${esc(value)}</span><span class="note">${esc(note)}</span></div>`;
}

function inner(label, value, note) {
    return `<div class="inner"><span class="label">${esc(label)}</span><span class="value">${esc(value)}</span>`
        + `<span class="note">${esc(note)}</span></div>`;
}

function users(s) {
    return `<section class="tiles" aria-label="Users">
${tile('Online now', number(s.online.now), 'Open connections, all hosts', true)}
${tile('Unique users today', number(s.uniques.today), 'Distinct identities that checked in')}
${tile('Last 7 days', number(s.uniques.last7Days), 'Unique users')}
${tile('Last 30 days', number(s.uniques.last30Days), 'Unique users')}
${tile('All time', number(s.uniques.allTime), 'Friends is on by default, so this approximates installs')}
${tile('New identities today', number(s.newIdentities.today), `First check-in ever. `
        + `${number(s.newIdentities.last7Days)} in 7 days, ${number(s.newIdentities.last30Days)} in 30`)}
</section>`;
}

// Whether this host's copy of the Friends ID table lets it hand out IDs (id-sync.js), in the admin's terms.
function idTableNotice(s, mainId) {
    const state = s.host.idTable;
    if (s.host.role === 'main') {
        return state === 'authoritative' ? '' : `<div class="notice">This is the main host, but it never finished
copying the Friends ID table from the previous main host, so it is not handing out new IDs. DEPLOY.md, "Replacing
the main host", says what to do.</div>`;
    }
    return state === 'unsynced'
        ? `<div class="notice">This replica has not finished copying the Friends ID table from ${esc(mainId)}. Do not
make it the main host until it has: it would not hand out new IDs.</div>`
        : `<div class="notice">This replica holds a complete copy of the Friends ID table from ${esc(mainId)}, so it
can take over as the main host.</div>`;
}

// A replica that reached its daily limit of new Friends IDs: either many new people use it, or it is minting
// identities for itself. The admin decides which; the page says what is happening and what each answer means.
function replicaLimitNotice(s) {
    const atLimit = s.replicaNewIds?.atLimit ?? [];
    if (atLimit.length === 0) return '';
    const one = atLimit.length === 1;
    const names = atLimit.map((r) => esc(r.id)).join(', ');
    return `<div class="notice"><strong>${names} reached today's limit of ${number(s.replicaNewIds.limit)} new Friends
IDs.</strong> Apps that connect through ${one ? 'it' : 'them'} without a reserved ID keep theirs unreserved until the
day ends (${esc(s.timeZone)} time); Nearby keeps working for them. If that many new people really use ${one
    ? 'this replica' : 'these replicas'}, raise FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY in this host's .env and run
docker compose up -d. If not, ${one ? 'the replica' : 'they'} may be compromised: publish a list without
${one ? 'it' : 'them'} (DEPLOY.md, "Replicas that reach their limit").</div>`;
}

function online(s) {
    const rows = s.online.last24Hours.map((p) => `<tr><td>${esc(p.label)}</td>`
        + `<td class="num">${number(p.value)}</td></tr>`);
    return `<section class="card" aria-label="Online users, last 24 hours">
<div class="title-line"><h2>Online users, last 24 hours</h2>
<span class="note">Peak per hour, ${esc(s.timeZone)} time</span></div>
${lineChart(s.online.last24Hours, { label: 'Online users per hour' })}
<details><summary>Show as table</summary><div class="scroll"><table>
<thead><tr><th scope="col">Hour</th><th scope="col">Online</th></tr></thead><tbody>${rows.join('')}</tbody>
</table></div></details>
</section>`;
}

function adoption(s) {
    const { lists } = s;
    const latest = lists.rows.find((row) => row.latest);
    const headline = lists.actives > 0
        ? `<div class="headline"><span class="value">${percent(latest?.share ?? 0)}</span>`
            + `<span class="sub">have list v${lists.latest}, the latest</span></div>`
        : '<span class="sub">Nobody has checked in during the last 30 days yet.</span>';
    const top = lists.rows.slice(0, 2);
    const rest = lists.rows.slice(2);
    const segments = [...top.map((row) => ({ share: row.share })),
        { share: rest.reduce((sum, row) => sum + row.share, 0) }];
    const body = lists.rows.map((row, i) => `<tr>
<td><span class="swatch ord-${Math.min(i + 1, 3)}" aria-hidden="true"></span>v${row.version}${
    row.latest ? ' (latest)' : ''}</td>
<td>${esc(shortDate(row.published, s.timeZone))}</td><td class="num">${number(row.users)}</td>
<td class="num">${percent(row.share)}</td><td class="num">${number(row.online)}</td></tr>`).join('');
    return `<section class="card" aria-label="Host list adoption">
<div><h2>Host list adoption</h2><span class="note">Which signed host list each user had at their latest check-in, among
the ${number(lists.actives)} users active in the last 30 days</span></div>
${headline}
${stackedBar(segments, { label: lists.rows.map((row) => `List v${row.version} ${percent(row.share)}`).join(', ') })}
<div class="scroll"><table><thead><tr><th scope="col">List</th><th scope="col">Published</th>
<th scope="col">Users, 30 days</th><th scope="col">Share</th><th scope="col">Online now</th></tr></thead>
<tbody>${body}</tbody></table></div>
<span class="note">Lists are signed on your Mac with the signing tool and published to the main host
(DEPLOY.md). Connected users switch within seconds; everyone else at their next launch.</span>
</section>`;
}

function friendsIds(s) {
    const { ids } = s;
    return `<section class="card" aria-label="Friends IDs">
<h2>Friends IDs</h2>
<div class="grid2">
${inner('Reserved', number(ids.reserved), 'One per identity')}
${inner('Collisions today', number(ids.collisionsToday), `${number(ids.collisionsTotal)} in all`)}
${inner('Renamed today', number(ids.renamesToday),
        `${number(ids.renamesTotal)} in all; each person is told in Friends`)}
${inner('Two-word space used', percent(ids.twoWordShare), 'Of 4,194,304 two-word IDs')}
</div>
${thresholdMeter(ids.twoWord, ids.threshold)}
<span class="note">${number(ids.twoWord)} of ${number(ids.threshold)} two-word IDs before the three-word line
(1/32 of the space). When the bar fills, publish a list with new_id_words 3.</span>
</section>`;
}

function versions(s) {
    const top = s.appVersions.slice(0, 5);
    const rest = s.appVersions.slice(5);
    const rows = top.map((v) => ({ name: v.version, share: v.share, value: percent(v.share) }));
    if (rest.length > 0) {
        const share = rest.reduce((sum, v) => sum + v.share, 0);
        rows.push({ name: 'Older', share, value: percent(share) });
    }
    return `<section class="card" aria-label="App versions">
<div><h2>App versions</h2><span class="note">Share of users active in the last 30 days</span></div>
${rows.length > 0 ? `<div style="display:flex;flex-direction:column;gap:10px">${barRows(rows)}</div>`
        : '<span class="sub">No check-ins in the last 30 days yet.</span>'}
</section>`;
}

const ROLE_NAMES = { rendezvous: 'rendezvous', relay: 'relay', both: 'rendezvous and relay' };
const STATUS_NAMES = { this_host: 'This host', reporting: 'Reporting', not_reporting: 'Not reporting' };

function hosts(s) {
    const main = s.hosts.find((h) => h.main);
    const rows = s.hosts.map((h) => `<tr><td><strong>${esc(h.id)}</strong></td>
<td>${h.main ? 'Main' : 'Replica'} · ${esc(ROLE_NAMES[h.role] ?? h.role)}</td><td>${esc(h.region)}</td>
<td class="num">${number(h.connections)}</td>
<td class="${h.status === 'not_reporting' ? '' : 'ok'}">${esc(STATUS_NAMES[h.status] ?? h.status)}</td></tr>`).join('');
    return `<section class="card" aria-label="Hosts">
<h2>Hosts in list v${s.lists.latest}</h2>
<div class="scroll"><table><thead><tr><th scope="col">Host</th><th scope="col">Role</th><th scope="col">Region</th>
<th scope="col">Connected</th><th scope="col">Status</th></tr></thead><tbody>${rows}</tbody></table></div>
<span class="note">Replicas forward reservations and statistics here. Only ${esc(main?.id ?? 'the main host')}
hands out Friends IDs.</span>
</section>`;
}

export function renderDashboard(s) {
    const generated = Date.parse(s.generatedAt);
    const replica = s.host.role === 'replica';
    const mainId = s.hosts.find((h) => h.main)?.id ?? 'the main host';
    const sections = replica
        ? [`<div class="notice">This is a replica. Statistics are counted on ${esc(mainId)}; open its dashboard for
users, adoption and IDs. This page shows only what this host sees.</div>`, idTableNotice(s, mainId), online(s),
        hosts(s)]
        : [idTableNotice(s, mainId), replicaLimitNotice(s), users(s), renderPeople(s), online(s),
            `<div class="row">${adoption(s)}${friendsIds(s)}</div>`,
            renderRelay(s), `<div class="row">${versions(s)}${hosts(s)}</div>`];
    return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>Friends host</title><style>${PAGE_CSS}</style></head>
<body><main>
<header><div style="display:flex;flex-direction:column;gap:4px"><h1>Friends host</h1>
<span class="sub">Admin · ${esc(s.host.id)}${s.host.region ? ` · ${esc(s.host.region)}` : ''}</span></div>
<span class="updated">Updated ${esc(clockTime(generated, s.timeZone))} · refreshes every minute</span></header>
${sections.join('\n')}
</main></body></html>
`;
}
