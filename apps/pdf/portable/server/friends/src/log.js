// One JSON line per event on stdout, read with `docker compose logs friends`.
//
// ADR 0005 § Privacy: no IP address, identity key or Friends ID ever reaches a log. Call sites pass only an event
// name, a random per-connection id and counts or codes; this module drops any field it does not know, so a
// careless `log('x', { address })` cannot leak one. Error messages from node:net name the remote address, so
// errors are reduced to their code.

const ALLOWED_FIELDS = new Set([
    'conn', 'port', 'socket', 'code', 'reason', 'result', 'version', 'state', 'role', 'host', 'count', 'scope',
    'protocol', 'queued', 'removed', 'seconds',
]);

function clean(fields) {
    const out = {};
    for (const [key, value] of Object.entries(fields)) {
        if (!ALLOWED_FIELDS.has(key)) continue;
        if (typeof value === 'number' || typeof value === 'boolean') out[key] = value;
        else if (typeof value === 'string') out[key] = value.slice(0, 80);
    }
    return out;
}

export function errorCode(error) {
    if (!error) return 'unknown';
    if (typeof error.code === 'string' && /^[A-Z0-9_]{2,40}$/.test(error.code)) return error.code;
    return error.name === 'Error' ? 'error' : String(error.name ?? 'error').slice(0, 40);
}

export function createLogger(sink = (line) => process.stdout.write(`${line}\n`), clock = { now: () => Date.now() }) {
    const log = (event, fields = {}) => {
        sink(JSON.stringify({ time: new Date(clock.now()).toISOString(), event, ...clean(fields) }));
    };
    return log;
}

export const silentLogger = () => {};
