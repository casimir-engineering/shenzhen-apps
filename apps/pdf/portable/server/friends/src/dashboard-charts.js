// Formatting and inline SVG for the dashboard. Server-rendered with no scripts (the page's CSP allows none), so
// hover values come from SVG <title> elements, which browsers show as native tooltips, and every chart has a table
// beside it for exact numbers.

export function esc(value) {
    return String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;',
        "'": '&#39;' })[c]);
}

export function number(value) {
    return value === null || value === undefined ? '—' : Number(value).toLocaleString('en-US');
}

// Small shares keep two decimals (occupancy of the ID space is tiny for a long time); others are whole percents.
export function percent(share) {
    if (!Number.isFinite(share) || share <= 0) return '0%';
    if (share < 0.01) return `${(share * 100).toFixed(2)}%`;
    return `${Math.round(share * 100)}%`;
}

export function shortDate(ms, timeZone) {
    if (!ms) return '—';
    return new Intl.DateTimeFormat('en-GB', { timeZone, day: 'numeric', month: 'short' }).format(new Date(ms));
}

export function clockTime(ms, timeZone) {
    return new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
        .format(new Date(ms));
}

// The smallest 1, 2, 2.5 or 5 times a power of ten that is at least `value`, so axis labels stay round.
function niceStep(value) {
    if (value <= 1) return 1;
    const power = 10 ** Math.floor(Math.log10(value));
    for (const factor of [1, 2, 2.5, 5, 10]) {
        if (factor * power >= value) return factor * power;
    }
    return 10 * power;
}

const W = 1000;
const H = 240;

// Online users per hour: a line with a soft area under it, three gridlines, labelled axes and the current value.
export function lineChart(points, { label }) {
    const max = Math.max(0, ...points.map((p) => p.value));
    const step = Math.max(1, niceStep(Math.ceil(max / 3)));
    const top = step * 3;
    const n = points.length;
    const x = (i) => (n > 1 ? (i / (n - 1)) * W : W / 2);
    const y = (v) => H - (v / top) * H;
    const coords = points.map((p, i) => `${x(i).toFixed(1)},${y(p.value).toFixed(1)}`);
    const area = `M0,${H} L${coords.join(' L')} L${W},${H} Z`;
    const last = points[n - 1]?.value ?? 0;
    const peak = Math.max(0, ...points.map((p) => p.value));
    const ticks = [3, 2, 1, 0].map((k) => ({ value: k * step, top: `${(100 - (k / 3) * 100).toFixed(2)}%` }));
    const columns = points.map((p, i) => {
        const left = n > 1 ? Math.max(0, x(i) - W / (2 * (n - 1))) : 0;
        const width = n > 1 ? W / (n - 1) : W;
        return `<rect x="${left.toFixed(1)}" y="0" width="${width.toFixed(1)}" height="${H}" fill="transparent">`
            + `<title>${esc(number(p.value))} online at ${esc(p.label)}</title></rect>`;
    }).join('');
    const xLabels = [0, 6, 12, 18, n - 1].filter((i) => i >= 0 && i < n).map((i) => {
        const pos = n > 1 ? (i / (n - 1)) * 100 : 50;
        const centered = `left:${pos.toFixed(1)}%;transform:translateX(-50%)`;
        const align = i === 0 ? 'left:0' : i === n - 1 ? 'right:0' : centered;
        return `<span style="position:absolute;${align}">${esc(points[i].label)}</span>`;
    }).join('');
    const yLabels = ticks.map((t) => `<span style="top:calc(${t.top} - 7px)">${number(t.value)}</span>`).join('');
    const gridLines = [0, 1, 2].map((k) => (k * H) / 3)
        .map((gy) => `<line x1="0" y1="${gy}" x2="${W}" y2="${gy}" class="grid"/>`).join('');
    // The last point is the current hour so far, which can differ from "online now" a minute ago; say which.
    const summary = `${esc(label)}, peaking at ${peak}, ${last} so far this hour`;
    const lastTop = ((y(last) / H) * 100).toFixed(2);
    return `<div class="chart">
  <div class="y-axis" aria-hidden="true">${yLabels}</div>
  <div class="plot">
    <div class="plot-area">
      <svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="${summary}">
        ${gridLines}
        <line x1="0" y1="${H}" x2="${W}" y2="${H}" class="baseline"/>
        <path d="${area}" class="area"/>
        <polyline points="${coords.join(' ')}" class="line"/>
        ${columns}
      </svg>
      <span class="now-dot" aria-hidden="true" style="top:${lastTop}%"></span>
      <span class="now-label" style="top:calc(${lastTop}% - 26px)">${number(last)} this hour</span>
    </div>
    <div class="x-axis" aria-hidden="true">${xLabels}</div>
  </div>
</div>`;
}

// One horizontal bar split by share, first segment darkest; tiny segments still get a sliver so they are seen.
export function stackedBar(segments, { label }) {
    const visible = segments.filter((s) => s.share > 0);
    if (visible.length === 0) return '';
    const parts = visible.map((s, i) => `<span class="seg ord-${Math.min(i + 1, 3)}" `
        + `style="flex:${Math.max(s.share, 0.005)}"></span>`).join('');
    return `<div class="stacked" role="img" aria-label="${esc(label)}">${parts}</div>`;
}

export function barRows(rows) {
    return rows.map((row) => `<div class="bar-row">
  <span class="bar-name">${esc(row.name)}</span>
  <span class="bar-track"><span class="bar" style="width:${Math.max(0.5, row.share * 100).toFixed(1)}%"></span>`
        + `<span class="bar-value">${esc(row.value)}</span></span>
</div>`).join('');
}

// Occupancy of the two-word space against the three-word line. The meter's full width is the threshold, so
// "how close are we" reads at a glance long before the share of the whole space is visible.
export function thresholdMeter(used, threshold) {
    const share = threshold > 0 ? Math.min(1, used / threshold) : 0;
    return `<div class="meter" role="img" aria-label="${esc(percent(share))} of the way to three-word IDs">`
        + `<span style="width:${Math.max(0.3, share * 100).toFixed(2)}%"></span></div>`;
}

export const CHART_CSS = `
.chart{display:flex;gap:8px}
.y-axis{width:36px;height:220px;position:relative;font-size:11px;color:var(--muted);font-variant-numeric:tabular-nums}
.y-axis span{position:absolute;right:0}
.plot{flex:1;min-width:0;display:flex;flex-direction:column;gap:6px}
.plot-area{height:220px;position:relative}
.plot-area svg{position:absolute;inset:0;width:100%;height:220px;overflow:visible}
.grid{stroke:var(--grid);stroke-width:1;vector-effect:non-scaling-stroke}
.baseline{stroke:var(--muted);stroke-width:1;vector-effect:non-scaling-stroke}
.area{fill:var(--wash);stroke:none}
.line{fill:none;stroke:var(--series);stroke-width:2;stroke-linejoin:round;stroke-linecap:round;
vector-effect:non-scaling-stroke}
.now-dot{position:absolute;left:100%;width:10px;height:10px;border-radius:50%;background:var(--series);
box-shadow:0 0 0 2px var(--card);transform:translate(-50%,-50%)}
.now-label{position:absolute;right:8px;font-size:12px;font-weight:600}
.x-axis{position:relative;height:16px;font-size:11px;color:var(--muted)}
.stacked{display:flex;gap:2px;height:20px}
.stacked .seg:first-child{border-radius:4px 0 0 4px}.stacked .seg:last-child{border-radius:0 4px 4px 0}
.stacked .seg:only-child{border-radius:4px}
.ord-1{background:var(--ord-1)}.ord-2{background:var(--ord-2)}.ord-3{background:var(--ord-3)}
.swatch{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:8px;vertical-align:-1px}
.bar-row{display:grid;grid-template-columns:140px minmax(0,1fr);align-items:center;gap:10px}
.bar-name{font-size:13px;color:var(--secondary);font-variant-numeric:tabular-nums;overflow:hidden;
text-overflow:ellipsis}
.bar-track{display:flex;align-items:center;gap:8px}
.bar{height:20px;background:var(--series);border-radius:0 4px 4px 0}
.bar-value{font-size:12px;font-variant-numeric:tabular-nums}
.meter{height:8px;border-radius:4px;background:var(--grid);overflow:hidden}
.meter span{display:block;height:100%;background:var(--series)}
`;
