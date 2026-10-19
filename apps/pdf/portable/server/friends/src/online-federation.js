// Online Friends between hosts (HOST-PROTOCOL-ONLINE.md § Between hosts): records, link bindings and connection setup
// travel inside the authenticated host-link envelope. Links run between each replica and the main host only, so the
// main host passes on what one replica sends for another. Every message names the host it comes from (`origin`) and,
// unless it is for every host, the one it is for (`dest`); the main host refuses an `origin` other than the replica
// at the far end of the link it arrived on, so no replica can speak for another.
//
// When a link comes up each side sends what it knows: a replica its own records and links, the main host those of
// every other host. When it goes down the other side drops, at once, everything that came over it.

import { validHostId } from './protocol.js';
import { RecordStore } from './rendezvous.js';

export class Federation {
    constructor(online) {
        this.online = online;
    }

    get host() {
        return this.online.host;
    }

    get self() {
        return this.online.hostId;
    }

    // Whether a message for `hostId` can leave now: over its own link on the main host, through the main host on a
    // replica.
    reaches(hostId) {
        if (hostId === this.self) return true;
        if (this.host.isMain) return this.host.hostLinks.has(hostId);
        return this.host.replicaLink?.state === 'up';
    }

    sendAs(origin, hostId, type, body) {
        const fields = { ...body, origin, dest: hostId };
        if (this.host.isMain) this.host.hostLinks.get(hostId)?.send(type, fields);
        else if (this.host.replicaLink?.state === 'up') this.host.replicaLink.send(type, fields);
    }

    send(hostId, type, body) {
        this.sendAs(this.self, hostId, type, body);
    }

    // To every other host. A replica sends to the main host, which passes it on.
    broadcast(type, body, { origin = this.self, except = null } = {}) {
        const fields = { ...body, origin };
        if (this.host.isMain) {
            for (const [id, link] of this.host.hostLinks) if (id !== except) link.send(type, fields);
        } else if (this.host.replicaLink?.state === 'up') {
            this.host.replicaLink.send(type, fields);
        }
    }

    broadcastRecord(record) {
        this.broadcast('rdv_record', RecordStore.wire(record));
    }

    broadcastWithdraw(record) {
        this.broadcast('rdv_withdraw', RecordStore.withdrawal(record));
    }

    // A message from the host at the far end of a link (`linkHost`), already authenticated by the link.
    fromLink(linkHost, msg) {
        const { type, v: _version, origin, dest, ...body } = msg;
        if (!validHostId(origin) || origin === this.self || (dest !== undefined && !validHostId(dest))) return;
        if (this.host.isMain) {
            if (origin !== linkHost) {
                this.host.log('forward_refused', { host: linkHost, scope: 'online' });
                return;
            }
            if (dest !== undefined && dest !== this.self) {
                this.sendAs(origin, dest, type, body);
                return;
            }
            if (dest === undefined) this.broadcast(type, body, { origin, except: linkHost });
        } else if (dest !== undefined && dest !== this.self) {
            return;
        }
        this.handle(origin, type, body);
    }

    handle(origin, type, body) {
        const { records, links, signal } = this.online;
        switch (type) {
        case 'rdv_record':
            records.acceptRemote(origin, body);
            break;
        case 'rdv_withdraw': {
            const record = records.device(body.rdv_key, body.device_key);
            if (record?.hostId === origin) records.withdraw(body.rdv_key, body.device_key, body.seq);
            break;
        }
        case 'link_bind':
            links.remoteBind(origin, body);
            break;
        case 'link_unbind':
            links.remoteUnbind(origin, body);
            break;
        case 'link_tomb':
            links.remoteTomb(origin, body);
            break;
        case 'sig_route':
            signal.fromHost(origin, body);
            break;
        case 'host_gone':
            // Only the main host knows when a replica's link went down.
            if (!this.host.isMain && validHostId(body.host) && body.host !== this.self) {
                this.dropHosts((id) => id === body.host);
            }
            break;
        default:
            break;
        }
    }

    // The link to `hostId` is up and authenticated (the main host's welcome was sent, or received).
    linkUp(hostId) {
        const { records, links } = this.online;
        const mine = this.host.isMain ? (id) => id !== hostId : (id) => id === this.self;
        for (const record of records.liveRecords()) {
            if (mine(record.hostId)) this.sendAs(record.hostId, hostId, 'rdv_record', RecordStore.wire(record));
        }
        for (const link of links.servedLinks(null)) {
            if (mine(link.host_id)) this.sendAs(link.host_id, hostId, 'link_bind', link);
        }
    }

    // The link to `hostId` went down. On the main host that is one replica, whose loss the other replicas hear
    // about; on a replica it is the main host, through which every other host was reached.
    linkDown(hostId) {
        if (this.host.isMain) {
            this.dropHosts((id) => id === hostId);
            this.broadcast('host_gone', { host: hostId }, { except: hostId });
        } else {
            this.dropHosts((id) => id !== this.self);
        }
    }

    dropHosts(gone) {
        const { records, links, signal } = this.online;
        records.dropHosts(gone);
        links.hostsGone(gone);
        signal.hostsGone(gone);
    }
}
