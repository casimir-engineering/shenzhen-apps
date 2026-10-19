// The services online Friends runs beside the WebSocket endpoint (ADR 0010): the STUN responder (FRIENDS_STUN_PORTS,
// 3479/UDP by default, whenever FRIENDS_M2 is on) and, with FRIENDS_RELAY on, coturn's configuration, written at every
// start from this host's own settings, the sink that receives coturn's per-allocation statistics, and the session
// limit that ends relayed sessions past FRIENDS_TURN_MAX_SESSION_S (relay-limit.js).

import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';

import { parseAddressList } from './address.js';
import { coturnConfig } from './coturn-config.js';
import { ONLINE_LIMITS } from './online-protocol.js';
import { RelayEventSink, defaultGateway } from './relay-events.js';
import { RelaySessionLimit, cancelSessions, coturnCliPassword } from './relay-limit.js';
import { StunResponder } from './stun.js';

// coturn's configuration for these settings. The file holds the TURN secret and the statistics password, so it is
// written mode 0600 and never logged. `cliIp` is where coturn's CLI listens, once `gateway` has been resolved; with
// no session limit there is no CLI at all.
export function relayConfigText(turn, { cliIp = turn.cliIp } = {}) {
    return coturnConfig({
        realm: turn.realm,
        secret: turn.secret,
        listeningIps: turn.listeningIps,
        externalIps: turn.externalIps,
        minPort: turn.minPort,
        maxPort: turn.maxPort,
        statsdb: { ip: turn.eventsIp, port: turn.eventsPort, password: turn.eventsPassword },
        prometheus: turn.prometheus ? { address: turn.prometheus, port: 9641 } : null,
        extraDenied: turn.deniedPeers ?? [],
        otherRelays: turn.otherRelays ?? [],
        cli: turn.maxSessionS > 0 ? { ip: cliIp, port: turn.cliPort, password: coturnCliPassword(turn.secret) } : null,
    });
}

// The address coturn's CLI listens on (FRIENDS_TURN_CLI_IP): `gateway` is read from the container's routing table,
// as for the statistics port, because the server's loopback is out of a container's reach.
export function cliAddress(spec, readRoutes = () => fs.readFileSync('/proc/net/route', 'utf8')) {
    if (spec !== 'gateway') return spec;
    let gateway = null;
    try {
        gateway = defaultGateway(readRoutes());
    } catch {
        gateway = null;
    }
    if (!gateway) throw new Error('FRIENDS_TURN_CLI_IP=gateway, but this system has no default gateway');
    return gateway;
}

// The addresses the statistics sink accepts connections from (FRIENDS_TURN_EVENTS_FROM): null for loopback only.
// `gateway` is read from the container's routing table when the service starts, and stops it if there is none.
export function eventSources(spec, readRoutes = () => fs.readFileSync('/proc/net/route', 'utf8')) {
    if (!spec) return null;
    if (spec !== 'gateway') return parseAddressList(spec, 'FRIENDS_TURN_EVENTS_FROM must list addresses');
    let gateway = null;
    try {
        gateway = defaultGateway(readRoutes());
    } catch {
        gateway = null;
    }
    if (!gateway) throw new Error('FRIENDS_TURN_EVENTS_FROM=gateway, but this system has no default gateway');
    return parseAddressList(gateway, 'FRIENDS_TURN_EVENTS_FROM must list addresses');
}

export function writeRelayConfig(turn, options = {}) {
    fs.mkdirSync(path.dirname(turn.confFile), { recursive: true, mode: 0o700 });
    const temporary = `${turn.confFile}.new`;
    fs.writeFileSync(temporary, relayConfigText(turn, options), { mode: 0o600 });
    fs.chmodSync(temporary, 0o600);
    fs.renameSync(temporary, turn.confFile);
}

export class RelayServices {
    constructor(online) {
        this.online = online;
        this.stun = null;
        this.sink = null;
        this.limit = null;
        this.stunPorts = [];
    }

    get settings() {
        return this.online.settings;
    }

    async start() {
        const { host } = this.online;
        const { stunPorts, stunListen, relay, turn } = this.settings;
        if (stunPorts.length > 0) {
            this.stun = new StunResponder({ clock: host.clock });
            const bindings = stunListen.flatMap((address) => stunPorts.map((port) => ({ address, port,
                type: net.isIPv6(address) ? 'udp6' : 'udp4' })));
            this.stunPorts = await this.stun.start(bindings);
            host.log('stun', { state: 'listening', count: this.stunPorts.length });
        }
        if (!relay) return;
        const cliIp = turn.maxSessionS > 0 ? cliAddress(turn.cliIp) : null;
        writeRelayConfig(turn, { cliIp });
        if (cliIp) {
            const password = coturnCliPassword(turn.secret);
            this.limit = new RelaySessionLimit({ clock: host.clock, maxSessionS: turn.maxSessionS,
                credentialTtlS: ONLINE_LIMITS.relayCredentialTtlS, log: host.log,
                cancel: (ids) => cancelSessions({ host: cliIp, port: turn.cliPort, password, ids }) });
        }
        this.sink = new RelayEventSink({ password: turn.eventsPassword, stats: this.online.stats,
            host: turn.eventsListen, port: turn.eventsPort, allowFrom: eventSources(turn.eventsFrom),
            onEvent: (event) => {
                if (event.type !== 'status') return;
                this.limit?.onStatus(event);
                this.online.relayHeld.onStatus(event);
            } });
        this.eventsPort = await this.sink.start();
        host.log('relay', { state: 'configured', port: this.eventsPort });
    }

    async stop() {
        await this.stun?.stop();
        this.stun = null;
        await this.sink?.stop();
        this.sink = null;
    }

    // Once a second, from the online service's sweep: ends relayed sessions past their bound.
    sweep() {
        return this.limit?.sweep();
    }

    // For the dashboard: whether coturn is connected to the statistics port now.
    get receiving() {
        return this.sink ? this.sink.receiving : null;
    }
}
