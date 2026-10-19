// The dashboard's people and devices section (protocol 3). The reader is the admin: a person may use Friends on
// several computers, so people and devices are counted apart, with the joins and revocations of each day.

import { esc, number, shortDate } from './dashboard-charts.js';

function inner(label, value, note) {
    return `<div class="inner"><span class="label">${esc(label)}</span><span class="value">${esc(value)}</span>`
        + `<span class="note">${esc(note)}</span></div>`;
}

export function renderPeople(s) {
    const p = s.people;
    const per = p.perPerson;
    const average = per.people > 0 ? per.average.toFixed(2) : '0';
    const rows = [...p.days].reverse().map((d) => `<tr><td>${esc(shortDate(Date.parse(`${d.day}T12:00:00Z`),
        s.timeZone))}</td><td class="num">${number(d.people)}</td><td class="num">${number(d.devices)}</td>`
        + `<td class="num">${number(d.joins)}</td><td class="num">${number(d.revocations)}</td></tr>`).join('');
    return `<section class="card" aria-label="People and devices">
<div class="title-line"><h2>People and devices</h2><span class="note">One person can use Friends on several
computers</span></div>
<div class="grid2">
${inner('People today', number(p.peopleToday), `On ${number(p.devicesToday)} devices`)}
${inner('Devices per person', average, `Over ${number(per.people)} people seen in 30 days: ${number(per.one)} with
one, ${number(per.two)} with two, ${number(per.three)} with three, ${number(per.fourOrMore)} with four or more`)}
${inner('Devices joined today', number(p.joinsToday), 'Computers added to an existing profile')}
${inner('Devices revoked today', number(p.revocationsToday), 'Computers removed from a profile')}
</div>
<details><summary>Last 14 days</summary><div class="scroll"><table>
<thead><tr><th scope="col">Day</th><th scope="col">People</th><th scope="col">Devices</th>
<th scope="col">Joined</th><th scope="col">Revoked</th></tr></thead><tbody>${rows}</tbody></table></div></details>
</section>`;
}
