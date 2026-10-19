// The coturn configuration the Friends host generates for its relay (ADR 0010; deploy/DEPLOY.md, "Online Friends").
// One function, so the deployed file and the tests come from the same settings, and every value the brief fixes is
// checked here rather than trusted to a hand-edited file:
//
// - 5 Mbit/s per relayed session, each direction: max-bps=625000 (coturn counts bytes per second, per direction);
// - no server-wide cap: neither bps-capacity nor total-quota is ever written;
// - credentials only from the host (use-auth-secret, the TURN REST API scheme), at most 2 allocations per attempt;
// - nothing in any log: coturn writes client addresses into its lines, so it writes none;
// - the relay reaches only relays. Every Friends relay path is relay to relay (an app on a relay connection sends
//   and accepts relay candidates only), so peers are allowed only on the relay's own addresses and those of the
//   other relay hosts the admin lists (FRIENDS_TURN_OTHER_RELAYS); every other IPv4 and IPv6 address is denied.
//   Without that, each credential would be a 5 Mbit/s UDP proxy to anywhere, from the server's address. The
//   private, loopback, link-local and shared ranges stay denied as well, should the deny-all ever be removed;
// - an allocation lives at most max-allocate-lifetime (600 s) past its last refresh. coturn checks the credential's
//   expiry only when an allocation starts, so the host itself ends sessions that outlive their bound, through
//   coturn's CLI (relay-limit.js); the CLI listens only where the host reaches it and takes a password derived from
//   the TURN secret.

import net from 'node:net';

import { ipv6Groups } from './address.js';

const DEFAULT_DENIED = [
    '0.0.0.0-0.255.255.255', '10.0.0.0-10.255.255.255', '100.64.0.0-100.127.255.255', '127.0.0.0-127.255.255.255',
    '169.254.0.0-169.254.255.255', '172.16.0.0-172.31.255.255', '192.0.0.0-192.0.0.255', '192.0.2.0-192.0.2.255',
    '192.88.99.0-192.88.99.255', '192.168.0.0-192.168.255.255', '198.18.0.0-198.19.255.255',
    '198.51.100.0-198.51.100.255', '203.0.113.0-203.0.113.255', '224.0.0.0-255.255.255.255',
    // Never a range that starts at "::": coturn treats an all-zero lower bound as no bound at all and orders IPv4
    // before IPv6, so "::-::ffff" denies every IPv4 peer (measured, README.md). coturn itself reduces IPv4-mapped,
    // IPv4-compatible, 6to4 and NAT64 encodings to IPv4 before checking IPv4 ranges.
    '::1', '64:ff9b::-64:ff9b::ffff:ffff', '64:ff9b:1::-64:ff9b:1:ffff:ffff:ffff:ffff:ffff',
    '100::-100::ffff:ffff:ffff:ffff', '2001::-2001:0:ffff:ffff:ffff:ffff:ffff:ffff',
    '2001:db8::-2001:db8:ffff:ffff:ffff:ffff:ffff:ffff',
    'fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', 'fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
    'ff00::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
];

// Every address of each family, for the deny-all; the IPv6 range starts at ::1, never at "::" (below). "::" itself
// is never a peer: coturn refuses the unspecified address on its own.
const DENY_ALL = ['0.0.0.0-255.255.255.255', '::1-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'];

const IP = /^[0-9a-fA-F:.]{2,45}$/;

// How long an allocation, and each refresh, may hold at most (max-allocate-lifetime).
export const MAX_ALLOCATE_LIFETIME_S = 600;

const DEFAULT_DENIED_LIST = new net.BlockList();
for (const range of DEFAULT_DENIED) {
    const [low, high = low] = range.split('-');
    const type = net.isIP(low) === 4 ? 'ipv4' : 'ipv6';
    if (low === high) DEFAULT_DENIED_LIST.addAddress(low, type);
    else DEFAULT_DENIED_LIST.addRange(low, high, type);
}

// Whether `ip` is a public address: in none of the ranges every relay denies. An admin's list of other relays may
// name only such addresses, or allowing them would reopen what the deny ranges close.
export function publicAddress(ip) {
    const family = net.isIP(ip);
    if (!family || ['0.0.0.0', '::'].includes(ip)) return false;
    return !DEFAULT_DENIED_LIST.check(ip, family === 4 ? 'ipv4' : 'ipv6');
}

// One denied-peer-ip value: an address, or a range of two addresses of one family in order. Never a range from
// "::" (an all-zero lower bound means no bound to coturn), nor "::" itself.
export function validDeniedRange(range) {
    if (typeof range !== 'string') return false;
    const ends = range.split('-');
    if (ends.length > 2 || !ends.every((ip) => net.isIP(ip))) return false;
    const family = net.isIP(ends[0]);
    if (ends.some((ip) => net.isIP(ip) !== family)) return false;
    if (family === 6 && ipv6Groups(ends[0]).every((g) => g === 0)) return false;
    if (ends.length === 1) return true;
    const value = (ip) => (family === 4 ? ip.split('.').map(Number) : ipv6Groups(ip));
    const [low, high] = ends.map(value);
    const order = low.findIndex((part, i) => part !== high[i]);
    return order < 0 || low[order] < high[order];
}

function check(condition, message) {
    if (!condition) throw new Error(`coturn config: ${message}`);
}

export function coturnConfig({
    realm, secret, listeningIps, relayIps = listeningIps, externalIps = [], listeningPort = 3478,
    altListeningPort = 0, minPort, maxPort, maxBps = 625_000, userQuota = 2, staleNonceS = 600,
    maxAllocateLifetimeS = MAX_ALLOCATE_LIFETIME_S, prometheus = null, statsdb = null, tls = null, extraDenied = [],
    otherRelays = [], cli = null, test = null,
}) {
    check(typeof realm === 'string' && /^[a-z0-9.-]{1,253}$/.test(realm), 'realm must be a host name');
    check(typeof secret === 'string' && secret.length >= 32 && !/\s/.test(secret),
        'the shared secret must be at least 32 characters without spaces');
    check(Array.isArray(listeningIps) && listeningIps.length > 0 && listeningIps.every((ip) => IP.test(ip))
        && !listeningIps.some((ip) => ['0.0.0.0', '::'].includes(ip)),
        'name the listening addresses explicitly; coturn would otherwise listen on every interface');
    check(relayIps.every((ip) => IP.test(ip)), 'relay addresses must be IP addresses');
    check(externalIps.every((mapping) => mapping.split('/').length <= 2
        && mapping.split('/').every((ip) => IP.test(ip))), 'external addresses are <public> or <public>/<private>');
    check(Number.isInteger(minPort) && Number.isInteger(maxPort) && minPort >= 1024 && maxPort <= 65535
        && maxPort - minPort >= 15 && maxPort - minPort <= 4095, 'the relay port range must be 16 to 4,096 ports');
    check(maxBps === 625_000 || test?.allowOtherBps, 'max-bps is 625000 (5 Mbit/s per session, brief § Online)');
    check(Number.isInteger(userQuota) && userQuota >= 1 && userQuota <= 4, 'user-quota is 1 to 4');
    check(Number.isInteger(maxAllocateLifetimeS) && maxAllocateLifetimeS >= 60 && maxAllocateLifetimeS <= 3600,
        'max-allocate-lifetime is 60 to 3600 seconds');
    check(Number.isInteger(staleNonceS) && staleNonceS >= 1 && staleNonceS <= 3600, 'stale-nonce is 1 to 3600 seconds');
    check(otherRelays.every(publicAddress), 'other relays are public addresses, one per entry');
    check(cli === null || (net.isIP(cli.ip) && Number.isInteger(cli.port) && cli.port > 0 && cli.port <= 65535
        && /^[A-Za-z0-9_-]{32,}$/.test(cli.password ?? '')), 'the CLI needs an address, a port and a long password');
    // The addresses peers see for this relay: its relay addresses and their public mappings.
    const allowed = [...new Set([...relayIps, ...externalIps.map((mapping) => mapping.split('/')[0]),
        ...otherRelays])];
    check(allowed.every((ip) => net.isIP(ip) && !['0.0.0.0', '::'].includes(ip)),
        'allowed peers are single addresses');
    const lines = [
        '# Generated by the Friends host (src/coturn-config.js) at every start. Do not edit by hand.',
        `realm=${realm}`,
        `listening-port=${listeningPort}`,
        ...(altListeningPort ? [`alt-listening-port=${altListeningPort}`] : []),
        ...listeningIps.map((ip) => `listening-ip=${ip}`),
        ...relayIps.map((ip) => `relay-ip=${ip}`),
        ...externalIps.map((mapping) => `external-ip=${mapping}`),
        `min-port=${minPort}`,
        `max-port=${maxPort}`,
        'fingerprint',
        'use-auth-secret',
        `static-auth-secret=${secret}`,
        `max-bps=${maxBps}`,
        `user-quota=${userQuota}`,
        `stale-nonce=${staleNonceS}`,
        `max-allocate-lifetime=${maxAllocateLifetimeS}`,
        'no-tcp-relay',
        'no-multicast-peers',
        ...(cli ? ['cli', `cli-ip=${cli.ip}`, `cli-port=${cli.port}`, `cli-password=${cli.password}`] : ['no-cli']),
        'no-software-attribute',
        'no-rfc5780',
        // No log at all: coturn names client addresses in its lines (ADR 0005 § Privacy).
        'no-stdout-log',
        'log-file=/dev/null',
        'simple-log',
        ...(tls ? [`cert=${tls.cert}`, `pkey=${tls.key}`, `tls-listening-port=${tls.port ?? 5349}`, 'no-tlsv1',
            'no-tlsv1_1', 'no-dtls'] : ['no-tls', 'no-dtls']),
        ...(prometheus ? ['prometheus', `prometheus-address=${prometheus.address}`,
            `prometheus-port=${prometheus.port ?? 9641}`] : []),
        ...(statsdb ? [`redis-statsdb="ip=${statsdb.ip} port=${statsdb.port} password=${statsdb.password} dbname=0 `
            + 'connect_timeout=5"'] : []),
        // coturn refuses allow-loopback-peers without a CLI password, even with the CLI off.
        ...(test?.allowLoopbackPeers ? ['allow-loopback-peers', ...(cli ? [] : ['cli-password=unused-test-only'])]
            : []),
        ...(test?.pidfile ? [`pidfile=${test.pidfile}`] : ['pidfile=/var/tmp/turnserver.pid']),
        // An allowed address is allowed whatever denies it (coturn's rule), so these are the only peers.
        ...allowed.map((ip) => `allowed-peer-ip=${ip}`),
        // Tests on loopback keep 127.0.0.0/8 out of the default ranges, so that any loopback address but the relay's
        // own stands in for a public address that only the deny-all refuses.
        ...[...DENY_ALL, ...DEFAULT_DENIED.filter((range) => !(test?.allowLoopbackPeers && range.startsWith('127.'))),
            ...extraDenied].map((range) => `denied-peer-ip=${range}`),
    ];
    if (statsdb) check(/^[A-Za-z0-9_-]{24,}$/.test(statsdb.password), 'the statistics password is base64url');
    for (const line of lines) check(!/^(bps-capacity|total-quota)=/.test(line), 'no server-wide cap');
    for (const line of lines) {
        if (line.startsWith('denied-peer-ip=')) {
            check(validDeniedRange(line.slice('denied-peer-ip='.length)),
                `no range from ::, and ranges in order: ${line}`);
        }
    }
    return `${lines.join('\n')}\n`;
}
