// The dashboard's relay section. The reader is the admin, who runs this host and knows what the relay is for; the
// text says what each number counts and, when something is off, what to do about it.

import { esc, number, percent } from './dashboard-charts.js';

export function bytesText(bytes) {
    const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
    let value = bytes;
    let unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
        value /= 1000;
        unit += 1;
    }
    if (unit === 0) return `${number(value)} bytes`;
    return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

export function rateText(bitsPerSecond) {
    if (bitsPerSecond < 1_000_000) return `${number(Math.round(bitsPerSecond / 1000))} kbit/s`;
    return `${(bitsPerSecond / 1_000_000).toFixed(1)} Mbit/s`;
}

function inner(label, value, note) {
    return `<div class="inner"><span class="label">${esc(label)}</span><span class="value">${esc(value)}</span>`
        + `<span class="note">${esc(note)}</span></div>`;
}

function heading() {
    return `<div class="title-line"><h2>Relay</h2><span class="note">Used only after nearby routes and every direct
method fail · 5 Mbit/s per session</span></div>`;
}

function receivingLine(r) {
    if (r.receiving) return '<span class="sub ok">coturn is sending its statistics to this host.</span>';
    return `<div class="notice">coturn is not sending its statistics to this host, so the numbers below miss what it
relays. Check that the relay container is running and that FRIENDS_TURN_EVENTS_PASSWORD and the statistics port
match (DEPLOY.md, "Online Friends").</div>`;
}

function days(r) {
    if (r.days.length === 0) return '<span class="sub">Nothing has been relayed in the last 30 days.</span>';
    const rows = r.days.map((d) => `<tr><td>${esc(d.day)}</td><td class="num">${number(d.sessions)}</td>
<td class="num">${esc(bytesText(d.bytes))}</td><td class="num">${esc(rateText(d.peakBps))}</td>
<td class="num">${number(d.cappedSessions)}</td></tr>`).join('');
    return `<details><summary>Last 30 days</summary><div class="scroll"><table><thead><tr><th scope="col">Day</th>
<th scope="col">Sessions</th><th scope="col">Data</th><th scope="col">Peak rate</th>
<th scope="col">Held at 5 Mbit/s</th></tr></thead><tbody>${rows}</tbody></table></div></details>`;
}

export function renderRelay(s) {
    const r = s.relay;
    if (!r || r.state === 'off') {
        return `<section class="card" aria-label="Relay">${heading()}
<span class="sub">Online Friends is off on this host (FRIENDS_M2), so apps connect through Nearby only and nothing is
relayed.</span></section>`;
    }
    const t = r.today;
    const status = r.state === 'no_relay'
        ? `<div class="notice">Online Friends is on but the relay is off (FRIENDS_RELAY). Friends who cannot connect
directly stay unreachable until it is on.</div>` : receivingLine(r);
    return `<section class="card" aria-label="Relay">${heading()}
${status}
<div class="grid2">
${inner('Relayed now', number(r.now.sessions), 'Sessions, all relay hosts')}
${inner('Sessions today', number(t.sessions), `${bytesText(t.bytes)} relayed`)}
${inner('Peak rate today', rateText(t.peakBps), `Average per session ${rateText(t.averageBps)}`)}
${inner('Held at 5 Mbit/s', number(t.cappedSessions), `${number(t.cappedMinutes)} minutes at the cap today`)}
${inner('Friend connections that needed it', percent(t.share.friends),
        `${number(t.relayed.friends)} of ${number(t.answered.friends)} connections between friends today`)}
${inner('Download links that needed it', percent(t.share.links),
        `${number(t.relayed.links)} of ${number(t.answered.links)} download-link connections today`)}
</div>
${days(r)}
${r.state === 'on' ? `<span class="note">To check the relay from your Mac, POST /relay-test on this dashboard for a
5-minute credential and use it with any TURN client (DEPLOY.md, "Online Friends").</span>` : ''}
</section>`;
}
