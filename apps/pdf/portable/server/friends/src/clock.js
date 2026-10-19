// Calendar helpers. Statistics count by day in one configured time zone (Hong Kong by default, where the admin
// reads the dashboard), and every host must use the same zone so a replica's queued check-ins land on the same
// day the main host would have counted. Days are 'YYYY-MM-DD' strings so they sort and compare as text.

const formatters = new Map();

function formatter(timeZone) {
    let format = formatters.get(timeZone);
    if (!format) {
        format = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
            hour: '2-digit', hourCycle: 'h23' });
        formatters.set(timeZone, format);
    }
    return format;
}

function parts(ms, timeZone) {
    const out = {};
    for (const part of formatter(timeZone).formatToParts(new Date(ms))) out[part.type] = part.value;
    return out;
}

// Throws for an unknown zone, so a typo in FRIENDS_STATS_TZ fails at start rather than counting in UTC quietly.
export function checkTimeZone(timeZone) {
    formatter(timeZone).format(new Date(0));
}

export function dayString(ms, timeZone) {
    const p = parts(ms, timeZone);
    return `${p.year}-${p.month}-${p.day}`;
}

export function hourLabel(ms, timeZone) {
    return `${parts(ms, timeZone).hour}:00`;
}

const DAY = /^\d{4}-\d{2}-\d{2}$/;
export function validDay(value) {
    return typeof value === 'string' && DAY.test(value) && !Number.isNaN(Date.parse(`${value}T00:00:00Z`));
}

// Calendar arithmetic on the date itself (UTC midnight has no daylight-saving gaps).
export function addDays(day, count) {
    const date = new Date(`${day}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + count);
    return date.toISOString().slice(0, 10);
}

// Twelve calendar months back; 29 February maps to 1 March of the earlier year, which only moves the retention
// edge by a day.
export function addMonths(day, count) {
    const date = new Date(`${day}T00:00:00Z`);
    date.setUTCMonth(date.getUTCMonth() + count);
    return date.toISOString().slice(0, 10);
}

export function minuteOf(ms) {
    return Math.floor(ms / 60_000);
}

export const systemClock = Object.freeze({ now: () => Date.now() });
