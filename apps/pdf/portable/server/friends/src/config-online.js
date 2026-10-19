// Online Friends settings (README.md § Configuration; deploy/DEPLOY.md, "Online Friends"). Both switches default to
// off, so a host deployed before the relay exists keeps serving check-in, IDs and Nearby exactly as before:
//
// - FRIENDS_M2=on: protocol 2 messages (rendezvous, connection setup, download links) and the STUN port;
// - FRIENDS_RELAY=on (needs FRIENDS_M2=on): relay credentials, coturn's generated configuration and its statistics.
//
// Anything malformed stops the service at start with the variable's name, as for every other setting.

import net from 'node:net';
import path from 'node:path';

import { parseAddressList } from './address.js';
import { publicAddress, validDeniedRange } from './coturn-config.js';

const URI = /^(stun|turn):[A-Za-z0-9.:[\]-]{1,300}(\?transport=(udp|tcp))?$/;
const IP = /^[0-9a-fA-F:.]{2,45}$/;
const BASE64URL_SECRET = /^[A-Za-z0-9_-]{24,}$/;

function onOff(env, name) {
    const raw = env[name];
    if (raw === undefined || raw === '' || raw === 'off') return false;
    if (raw === 'on') return true;
    throw new Error(`${name} must be on or off`);
}

function port(env, name, fallback) {
    const raw = env[name];
    if (raw === undefined || raw === '') return fallback;
    const value = Number(raw);
    if (!Number.isInteger(value) || value < 0 || value > 65535) throw new Error(`${name} must be a port number`);
    return value;
}

function list(env, name) {
    return (env[name] ?? '').split(',').map((s) => s.trim()).filter(Boolean);
}

function required(env, name, test, what) {
    const value = env[name];
    if (!value || !test(value)) throw new Error(`${name} must be ${what} when FRIENDS_RELAY is on`);
    return value;
}

function seconds(env, name, fallback, max) {
    const raw = env[name];
    if (raw === undefined || raw === '') return fallback;
    const value = Number(raw);
    if (!Number.isInteger(value) || value < 0 || value > max) {
        throw new Error(`${name} must be a number of seconds from 0 to ${max}`);
    }
    return value;
}

function stunPorts(env) {
    const raw = env.FRIENDS_STUN_PORTS;
    const ports = raw === undefined || raw === '' ? ['3479'] : list(env, 'FRIENDS_STUN_PORTS');
    return ports.map((value) => {
        const n = Number(value);
        if (!Number.isInteger(n) || n < 0 || n > 65535) {
            throw new Error('FRIENDS_STUN_PORTS must list UDP port numbers, such as 3479');
        }
        return n;
    });
}

function stunListen(env) {
    const addresses = list(env, 'FRIENDS_STUN_LISTEN');
    if (!addresses.every((ip) => net.isIP(ip))) throw new Error('FRIENDS_STUN_LISTEN must list IP addresses');
    return addresses.length > 0 ? addresses : ['0.0.0.0'];
}

function turnSettings(env, dataDir) {
    const secret = required(env, 'FRIENDS_TURN_SECRET', (v) => v.length >= 32 && !/\s/.test(v),
        'at least 32 characters without spaces');
    const realm = required(env, 'FRIENDS_TURN_REALM', (v) => /^[a-z0-9.-]{1,253}$/.test(v), 'a host name');
    const listeningIps = list(env, 'FRIENDS_TURN_LISTEN_IPS');
    if (listeningIps.length === 0 || !listeningIps.every((ip) => IP.test(ip))) {
        throw new Error('FRIENDS_TURN_LISTEN_IPS must list the relay\'s public addresses when FRIENDS_RELAY is on');
    }
    const ports = /^(\d{4,5})-(\d{4,5})$/.exec(env.FRIENDS_TURN_PORTS || '49160-49415');
    if (!ports) throw new Error('FRIENDS_TURN_PORTS must be a range such as 49160-49415');
    const eventsPassword = required(env, 'FRIENDS_TURN_EVENTS_PASSWORD', (v) => BASE64URL_SECRET.test(v),
        'at least 24 base64url characters');
    const deniedPeers = list(env, 'FRIENDS_TURN_DENIED_PEERS');
    if (!deniedPeers.every(validDeniedRange)) {
        throw new Error('FRIENDS_TURN_DENIED_PEERS must list addresses or ranges such as 2001:db8::-2001:db8::ffff, '
            + 'never a range from ::');
    }
    const otherRelays = list(env, 'FRIENDS_TURN_OTHER_RELAYS');
    if (!otherRelays.every(publicAddress)) {
        throw new Error('FRIENDS_TURN_OTHER_RELAYS must list the other relay hosts\' public addresses, '
            + 'one address each');
    }
    const cliIp = (env.FRIENDS_TURN_CLI_IP ?? '').trim() || '127.0.0.1';
    if (cliIp !== 'gateway' && !net.isIP(cliIp)) throw new Error('FRIENDS_TURN_CLI_IP must be gateway or an address');
    const eventsFrom = (env.FRIENDS_TURN_EVENTS_FROM ?? '').trim();
    if (eventsFrom !== 'gateway') {
        parseAddressList(eventsFrom, 'FRIENDS_TURN_EVENTS_FROM must be gateway, or list addresses or CIDR blocks');
    }
    return {
        secret,
        realm,
        listeningIps,
        externalIps: list(env, 'FRIENDS_TURN_EXTERNAL_IPS'),
        minPort: Number(ports[1]),
        maxPort: Number(ports[2]),
        // More addresses the relay must not reach (every address but the relays' own is refused anyway).
        deniedPeers,
        // The other relay hosts' public addresses: a relayed connection between apps on two relay hosts goes from
        // one relay to the other, so each must accept the other as a peer.
        otherRelays,
        // A relayed session ends this long after its credential was issued (0: never), through coturn's CLI, which
        // listens on cliIp (`gateway`: the container's default gateway, an address of the server) and cliPort.
        maxSessionS: seconds(env, 'FRIENDS_TURN_MAX_SESSION_S', 3600, 86_400),
        cliIp,
        cliPort: port(env, 'FRIENDS_TURN_CLI_PORT', 5766),
        // Where coturn's statistics arrive: this service listens on eventsListen; coturn, on the server's network,
        // reaches it at eventsIp (the port published on the server's loopback).
        eventsPassword,
        eventsListen: env.FRIENDS_TURN_EVENTS_LISTEN || '127.0.0.1',
        eventsIp: env.FRIENDS_TURN_EVENTS_IP || '127.0.0.1',
        eventsPort: port(env, 'FRIENDS_TURN_EVENTS_PORT', 6390),
        // Who may connect to it: loopback when empty; `gateway` is the container's default gateway, which Docker's
        // published port connects from; otherwise addresses or CIDR blocks.
        eventsFrom,
        prometheus: env.FRIENDS_TURN_PROMETHEUS || null,
        confFile: path.resolve(env.FRIENDS_TURN_CONF || path.join(dataDir, 'relay', 'turnserver.conf')),
    };
}

export function onlineConfig(env, dataDir) {
    const enabled = onOff(env, 'FRIENDS_M2');
    const relay = onOff(env, 'FRIENDS_RELAY');
    if (relay && !enabled) throw new Error('FRIENDS_RELAY=on needs FRIENDS_M2=on');
    const guestIceServers = list(env, 'FRIENDS_TURN_URIS');
    if (!guestIceServers.every((uri) => uri.length <= 512 && URI.test(uri))) {
        throw new Error('FRIENDS_TURN_URIS must list stun: or turn: URIs, such as turn:example.org:3478?transport=udp');
    }
    return {
        enabled,
        relay,
        stunPorts: enabled ? stunPorts(env) : [],
        stunListen: stunListen(env),
        // Browsers opening a download link have no signed host list, so they are told where TURN is.
        guestIceServers,
        turn: relay ? turnSettings(env, dataDir) : null,
    };
}
