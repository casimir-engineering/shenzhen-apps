// Client addresses, reduced to the key every per-address limit counts by (ADR 0005 § Privacy, HOST-PROTOCOL.md
// § Errors, close codes and limits).
//
// One person controls a whole IPv6 /64 (a home router hands out the prefix and the host picks any address in it),
// so IPv6 is limited per /64 and IPv4 per address; an IPv4-mapped IPv6 address is the IPv4 address it carries.
// The key is a keyed hash of that prefix with a secret drawn when the process starts, so even the limiter's memory
// holds no address, and a key means nothing after a restart. Online Friends' limits on browsers opening download
// links, and on opens toward one person, count IPv6 by /56 instead (the wide key): a home or a small server is often
// given a /56 or a /48, so counting by /64 would let one of them act as 256 or more clients. How much of the relay
// one network holds counts IPv4 by /24 as well (the net key), since a server or a small network commonly has a
// handful of addresses in one /24, and helper identities cost nothing to make.
//
// Behind the ingress every TCP peer is the proxy, which passes the client's address in X-Real-IP. The header is
// believed only when the peer itself is a configured proxy address, so another container on the shared network
// cannot pick its own key by sending the header.

import crypto from 'node:crypto';
import net from 'node:net';

const PROCESS_KEY = crypto.randomBytes(32);
const MAPPED_V4 = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i;

function stripZone(address) {
    const zone = address.indexOf('%');
    return zone >= 0 ? address.slice(0, zone) : address;
}

// '::ffff:203.0.113.9' is the IPv4 client a dual-stack socket reports; everything else passes through.
export function unmapIPv4(address) {
    const mapped = MAPPED_V4.exec(address);
    return mapped && net.isIPv4(mapped[1]) ? mapped[1] : address;
}

// The eight 16-bit groups of a valid IPv6 address, expanding '::' and a trailing dotted IPv4 part.
export function ipv6Groups(address) {
    if (!net.isIPv6(address)) return null;
    let text = address.toLowerCase();
    const lastColon = text.lastIndexOf(':');
    const last = text.slice(lastColon + 1);
    if (last.includes('.')) {
        const [a, b, c, d] = last.split('.').map(Number);
        text = `${text.slice(0, lastColon + 1)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
    }
    const halves = text.split('::');
    const left = halves[0] ? halves[0].split(':') : [];
    const right = halves.length > 1 && halves[1] ? halves[1].split(':') : [];
    const fill = halves.length > 1 ? 8 - left.length - right.length : 0;
    const groups = [...left, ...Array(Math.max(fill, 0)).fill('0'), ...right];
    return groups.length === 8 ? groups.map((group) => Number.parseInt(group, 16)) : null;
}

// The prefix a limit counts by, as text: '4:a.b.c.d' or '6:' and the first four groups ('6/56:' and the first 56
// bits with `wide`; with `net` as well, and '4/24:a.b.c' for IPv4). Null for anything that is not an IP address.
export function addressPrefix(address, { wide = false, net: byNet = false } = {}) {
    if (typeof address !== 'string' || address.length === 0) return null;
    const plain = unmapIPv4(stripZone(address.trim()));
    const v4 = (text) => (byNet ? `4/24:${text.split('.').slice(0, 3).join('.')}` : `4:${text}`);
    if (net.isIPv4(plain)) return v4(plain);
    const groups = ipv6Groups(plain);
    if (!groups) return null;
    if (groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff) {
        return v4(`${groups[6] >> 8}.${groups[6] & 0xff}.${groups[7] >> 8}.${groups[7] & 0xff}`);
    }
    const slash56 = [...groups.slice(0, 3), groups[3] & 0xff00];
    if (wide || byNet) return `6/56:${slash56.map((g) => g.toString(16)).join(':')}`;
    return `6:${groups.slice(0, 4).map((g) => g.toString(16)).join(':')}`;
}

// The limiter key for a prefix: 16 bytes of HMAC, base64url. Not reversible without the process's secret.
export function prefixKey(prefix) {
    return crypto.createHmac('sha256', PROCESS_KEY).update(prefix).digest().subarray(0, 16).toString('base64url');
}

// Comma-separated addresses or CIDR blocks, as a BlockList, or null when there are none. Throws `message` on
// anything else.
export function parseAddressList(value, message) {
    const list = new net.BlockList();
    const entries = String(value ?? '').split(',').map((s) => s.trim()).filter(Boolean);
    for (const entry of entries) {
        const [address, bits, extra] = entry.split('/');
        const plain = unmapIPv4(address);
        const family = net.isIPv4(plain) ? 'ipv4' : (net.isIPv6(plain) ? 'ipv6' : null);
        const max = family === 'ipv4' ? 32 : 128;
        const prefix = bits === undefined ? max : Number(bits);
        if (!family || extra !== undefined || !Number.isInteger(prefix) || prefix < 0 || prefix > max
            || (bits !== undefined && !/^\d{1,3}$/.test(bits))) {
            throw new Error(message);
        }
        if (prefix === max) list.addAddress(plain, family);
        else list.addSubnet(plain, prefix, family);
    }
    return entries.length > 0 ? list : null;
}

// FRIENDS_TRUSTED_PROXY: comma-separated addresses or CIDR blocks. Throws with the variable's name on anything else.
export function parseTrustedProxies(value) {
    return parseAddressList(value, 'FRIENDS_TRUSTED_PROXY must list addresses or CIDR blocks, such as 172.18.0.5 or '
        + '172.18.0.0/16');
}

// Whether `peer` (a socket's remote address) is in `list`.
export function addressIn(list, peer) {
    if (!list || typeof peer !== 'string') return false;
    const plain = unmapIPv4(stripZone(peer));
    const family = net.isIPv4(plain) ? 'ipv4' : (net.isIPv6(plain) ? 'ipv6' : null);
    return family !== null && list.check(plain, family);
}

// The key for one upgrade request: the forwarded address when the TCP peer is a trusted proxy and the header holds
// an address, otherwise the peer itself. `forwardedIgnored` reports a header that was present but not believed,
// which the host logs once in a while so a moved ingress is noticed.
export function clientKey(req, socket, trusted) {
    const peer = socket.remoteAddress ?? '';
    const header = req.headers['x-real-ip'];
    const forwarded = typeof header === 'string' && header.length > 0 ? header : null;
    const believe = forwarded !== null && addressIn(trusted, peer);
    const address = believe && addressPrefix(forwarded) !== null ? forwarded : peer;
    const prefix = addressPrefix(address) ?? 'unknown';
    const wide = addressPrefix(address, { wide: true }) ?? 'unknown';
    const netPrefix = addressPrefix(address, { net: true }) ?? 'unknown';
    return { key: prefixKey(prefix), wideKey: prefixKey(wide), netKey: prefixKey(netPrefix),
        forwardedIgnored: forwarded !== null && !believe };
}
