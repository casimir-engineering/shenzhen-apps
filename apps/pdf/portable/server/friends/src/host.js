// The Friends host service: the WebSocket endpoint helpers check in to, the current signed host list, the role
// it implies (the lowest-priority rendezvous host in the list is the main host and only ID allocator; every other
// host is a replica that forwards to it), live connection counts, statistics timers and the admin dashboard.

import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';

import { WebSocketServer } from 'ws';

import { Admission } from './admission.js';
import { expireRevocations, recordDevice } from './device-records.js';
import { admitDevice } from './devices.js';
import { ClientSession } from './client-session.js';
import { addDays, dayString, minuteOf, systemClock } from './clock.js';
import { startDashboard } from './dashboard.js';
import { openDatabase, settingGet, settingSet } from './db.js';
import { HostLink, verifyHostHello } from './host-links.js';
import { hostEntry, mainHost, verifyEnvelope } from './hostlist.js';
import { canAllocate, settleIdTable } from './id-sync.js';
import { identitySecretCheck, randomId, rawPublicKey } from './keys.js';
import { linkPages } from './link-pages.js';
import { createLogger, errorCode } from './log.js';
import { OnlineService } from './online.js';
import {
    CLOSE, LINK_QUERY, MAX_CHECKIN_BYTES, MAX_LINK_MESSAGE_BYTES, WS_PATH, message,
} from './protocol.js';
import { DailyCap } from './ratelimit.js';
import {
    applyRetention, discardPastDays, latestHostList, recordCheckin, recordSample, releaseId, reserveId, rollupDay,
    storeHostList,
} from './records.js';
import { ReplicaLink } from './replica-link.js';

const HOUR_MS = 3_600_000;
const UNAVAILABLE = Object.freeze({ reservation: 'unavailable', friendsId: null, granted: false });

function refuseUpgrade(socket, status, text) {
    socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

export class FriendsHost {
    constructor(config, { clock = systemClock, log = createLogger() } = {}) {
        this.config = config;
        this.clock = clock;
        this.log = log;
        this.sessions = new Set();
        this.live = new Map(); // identity hash (hex) -> checked-in session; one live connection per identity
        this.hostLinks = new Map(); // replica id -> HostLink (main host only)
        this.replicaReports = new Map(); // replica id -> latest minute report (main host only)
        // New IDs granted through each replica today (main host only; host-links.js), and the day each replica
        // last reached its limit, so the admin is told once per day in the log and on the dashboard.
        this.replicaNewIds = new DailyCap({ limit: config.limits.newIdsPerReplicaPerDay, maxKeys: 64 });
        this.replicaLimitReached = new Map();
        this.replicaLink = null;
        this.online = null; // online Friends (online.js), with FRIENDS_M2=on
        this.isMain = false;
        this.list = null;
        this.envelope = null;
        this.timers = [];
    }

    logError(where, error, conn) {
        this.log('error', { scope: where, code: errorCode(error), conn });
    }

    today() {
        return dayString(this.clock.now(), this.config.statsTimeZone);
    }

    async start() {
        try {
            return await this.startServices();
        } catch (error) {
            // A half-started host must not keep a port, a socket or the database open behind a failed start.
            await this.stop().catch(() => {});
            throw error;
        }
    }

    async startServices() {
        fs.mkdirSync(this.config.dataDir, { recursive: true, mode: 0o700 });
        this.db = openDatabase(path.join(this.config.dataDir, 'friends.sqlite'));
        this.checkIdentitySecret();
        this.loadInitialList();
        this.admission = new Admission({ config: this.config, clock: this.clock, log: this.log });
        // Helpers send small messages but for a check-in with its chain; host links carry summary batches and forwarded
        // check-ins. Each has its own limit (protocol.js); client-session.js holds the rest of a helper's to 8 KiB.
        this.wss = new WebSocketServer({ noServer: true, maxPayload: MAX_CHECKIN_BYTES, perMessageDeflate: false });
        this.linkWss = new WebSocketServer({ noServer: true, maxPayload: MAX_LINK_MESSAGE_BYTES,
            perMessageDeflate: false });
        // The friend and download link pages (link-pages.js), read once here.
        this.pages = linkPages(this.config);
        this.server = http.createServer((req, res) => this.httpRequest(req, res));
        // A socket that never finishes its HTTP request costs the same as an idle WebSocket; the ingress sends the
        // whole request at once, so a short limit only cuts off stragglers.
        this.server.headersTimeout = this.config.limits.checkinTimeoutMs;
        this.server.requestTimeout = this.config.limits.checkinTimeoutMs;
        this.server.on('upgrade', (req, socket, head) => this.upgrade(req, socket, head));
        this.server.on('clientError', (error, socket) => socket.destroy());
        await new Promise((resolve, reject) => {
            this.server.once('error', reject);
            this.server.listen(this.config.listenPort, this.config.listenHost, resolve);
        });
        this.port = this.server.address().port;
        if (this.config.online.enabled) {
            this.online = new OnlineService(this);
            await this.online.start();
        }
        this.dashboard = await startDashboard(this);
        this.timers.push(setInterval(() => this.ping(), this.config.limits.pingIntervalMs));
        this.timers.push(setInterval(() => this.guard('tick', () => this.tick()), 60_000));
        this.timers.push(setInterval(() => this.guard('maintenance', () => this.maintenance()), HOUR_MS));
        this.guard('maintenance', () => this.maintenance());
        this.log('listening', { port: this.port, role: this.isMain ? 'main' : 'replica', version: this.list.version });
        return { port: this.port };
    }

    guard(scope, body) {
        try {
            body();
        } catch (error) {
            this.logError(scope, error);
        }
    }

    async stop() {
        for (const timer of this.timers) clearInterval(timer);
        this.timers = [];
        this.replicaLink?.stop();
        for (const session of this.sessions) session.close(CLOSE.goingAway, 'shutting down');
        await this.online?.stop();
        await this.dashboard?.close();
        this.dashboard = null;
        for (const wss of [this.wss, this.linkWss]) {
            if (!wss) continue;
            await new Promise((resolve) => {
                wss.close(() => resolve());
                for (const ws of wss.clients) ws.terminate();
            });
        }
        if (this.server?.listening) await new Promise((resolve) => this.server.close(() => resolve()));
        try {
            this.db?.close();
        } catch {
            // already closed
        }
        this.db = null;
    }

    // The database's newest list, or the configured file when that is newer (a fresh deployment, or an image
    // carrying a newer bootstrap). Without any verified list the host cannot know its role, so it refuses to start.
    loadInitialList() {
        const stored = latestHostList(this.db);
        let best = stored ? verifyEnvelope(stored.envelope, this.config.pinnedKeys) : null;
        if (best && !best.ok) best = null;
        if (this.config.hostListFile) {
            const fromFile = verifyEnvelope(fs.readFileSync(this.config.hostListFile, 'utf8'), this.config.pinnedKeys);
            if (!fromFile.ok) throw new Error(`FRIENDS_HOST_LIST_FILE does not verify: ${fromFile.error}`);
            if (!best || fromFile.list.version > best.list.version) {
                storeHostList(this.db, { version: fromFile.list.version, envelope: fromFile.envelope,
                    publishedAt: this.clock.now() });
                best = fromFile;
            }
        }
        if (!best) throw new Error('no verified host list: set FRIENDS_HOST_LIST_FILE to a signed list');
        if (!this.hostKeyMatches(best.list)) {
            throw new Error('FRIENDS_HOST_KEY_FILE is not the key the signed host list gives this host');
        }
        this.applyList(best);
    }

    // The database remembers a check value of the identity secret it was written with. Another secret would give
    // every identity a new name, orphaning every reserved ID, so it is refused rather than silently started.
    checkIdentitySecret() {
        const check = identitySecretCheck(this.config.identitySecret).toString('base64url');
        const stored = settingGet(this.db, 'identity_secret_check');
        if (stored === null) settingSet(this.db, 'identity_secret_check', check);
        else if (stored !== check) {
            throw new Error('FRIENDS_IDENTITY_SECRET is not the secret this database was written with');
        }
    }

    // Helpers check every reservation answer against the public key the list gives this host, so a host whose key
    // differs would reserve nothing for anyone.
    hostKeyMatches(list) {
        const entry = hostEntry(list, this.config.hostId);
        return !entry || entry.publicKey.equals(rawPublicKey(this.config.hostKey));
    }

    applyList(verified) {
        const previousMain = this.list ? mainHost(this.list)?.id : null;
        this.list = verified.list;
        this.envelope = verified.envelope;
        this.payload = verified.payloadBytes;
        const main = mainHost(this.list);
        this.isMain = main?.id === this.config.hostId;
        if (!this.hostKeyMatches(this.list)) this.log('host_key', { state: 'mismatch' });
        const idTable = settleIdTable(this.db, { isMain: this.isMain, allowUnsynced: this.config.allowUnsyncedMain });
        if (this.isMain && idTable !== 'authoritative') this.log('id_table', { state: idTable, role: 'main' });
        if (this.isMain) {
            this.replicaLink?.stop();
            this.replicaLink = null;
            for (const link of this.hostLinks.values()) {
                if (!hostEntry(this.list, link.replicaId)) link.session.close(CLOSE.policy, 'not in list');
            }
        } else if (!this.replicaLink) {
            this.replicaLink = new ReplicaLink(this);
            if (this.db) this.replicaLink.start();
        } else if (previousMain !== main?.id) {
            this.replicaLink.restart();
        }
    }

    // A list from the admin (dashboard), the main host (on a replica) or the configured file. The signature decides,
    // not the source; only a higher version replaces the current one.
    offerList(input, { source }) {
        const text = typeof input === 'string' ? input : JSON.stringify(input);
        const verified = verifyEnvelope(text, this.config.pinnedKeys);
        if (!verified.ok) return { ok: false, error: verified.error };
        if (verified.list.version <= this.list.version) {
            const same = verified.list.version === this.list.version && verified.payloadBytes.equals(this.payload);
            return { ok: false, error: same ? 'this version is already current' : 'not newer than the current list' };
        }
        storeHostList(this.db, { version: verified.list.version, envelope: verified.envelope,
            publishedAt: this.clock.now() });
        this.applyList(verified);
        this.pushList();
        this.log('list_published', { version: verified.list.version, scope: source });
        return { ok: true, version: verified.list.version };
    }

    currentListFor(heldVersion) {
        return this.list.version > heldVersion ? JSON.parse(this.envelope) : null;
    }

    // Every open connection hears about a new list within seconds (brief § Signed host list); replicas verify it
    // and push to their own connections in turn.
    pushList() {
        const text = message('host_list', { host_list: JSON.parse(this.envelope) });
        for (const session of this.sessions) {
            if (session.state === 'checked_in' && session.listVersion < this.list.version) {
                session.ws.send(text);
            }
        }
        for (const link of this.hostLinks.values()) link.send('host_list', { host_list: JSON.parse(this.envelope) });
    }

    httpRequest(req, res) {
        // Docker's health check; the ingress proxies only /v1, so this is not reachable from outside.
        if (req.method === 'GET' && req.url === '/healthz') {
            res.writeHead(200, { 'Content-Type': 'text/plain' }).end('ok\n');
            return;
        }
        if (this.pages.handle(req, res)) return;
        res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found\n');
    }

    upgrade(req, socket, head) {
        let url;
        try {
            url = new URL(req.url, 'http://host');
        } catch {
            url = null;
        }
        if (url?.pathname !== WS_PATH) return refuseUpgrade(socket, 404, 'Not Found');
        // A browser opening a download link (online-links.js); there are none while online Friends is off.
        if (url.searchParams.get('guest') === '1') {
            return this.online ? this.online.links.upgradeGuest(req, socket, head)
                : refuseUpgrade(socket, 404, 'Not Found');
        }
        // The address becomes a keyed hash here (address.js) and is not kept.
        const admitted = this.admission.admit(req, socket);
        if (!admitted.ok) return refuseUpgrade(socket, admitted.status, admitted.text);
        const linkOnly = url.searchParams.get(LINK_QUERY) === '1';
        const wss = linkOnly ? this.linkWss : this.wss;
        return wss.handleUpgrade(req, socket, head, (ws) => this.accept(ws, admitted.ticket, linkOnly));
    }

    accept(ws, ticket, linkOnly, { guest = false } = {}) {
        const session = new ClientSession(this, ws, randomId(), { ticket, linkOnly, guest });
        this.sessions.add(session);
        ws.isAlive = true;
        ws.on('pong', () => {
            ws.isAlive = true;
        });
        session.start();
    }

    // Dead peers (a Mac that slept, a dropped mobile link) stop answering pings; terminating them keeps "online
    // now" honest and frees their slot.
    ping() {
        for (const session of this.sessions) {
            const { ws } = session;
            if (ws.isAlive === false) {
                ws.terminate();
                continue;
            }
            ws.isAlive = false;
            try {
                ws.ping();
            } catch {
                ws.terminate();
            }
        }
    }

    sessionClosed(session) {
        this.sessions.delete(session);
        this.online?.sessionClosed(session);
        if (session.identityHash) {
            const key = session.identityHash.toString('hex');
            if (this.live.get(key) === session) this.live.delete(key);
        }
    }

    registerLive(session) {
        const key = session.identityHash.toString('hex');
        const previous = this.live.get(key);
        this.live.set(key, session);
        if (previous && previous !== session) previous.close(CLOSE.replaced, 'replaced');
    }

    liveCount() {
        return this.live.size;
    }

    liveListVersions() {
        const counts = new Map();
        for (const { listVersion } of this.live.values()) counts.set(listVersion, (counts.get(listVersion) ?? 0) + 1);
        return counts;
    }

    acceptHostLink(session, msg) {
        const hello = verifyHostHello(this, session.challenge, msg);
        if (!hello) {
            this.log('host_link', { conn: session.connId, state: 'refused' });
            return null;
        }
        const { replicaId } = hello;
        this.hostLinks.get(replicaId)?.session.close(CLOSE.replaced, 'replaced');
        const link = new HostLink(this, session, hello);
        this.hostLinks.set(replicaId, link);
        link.welcome();
        this.online?.federation.linkUp(replicaId);
        this.log('host_link', { conn: session.connId, state: 'up', host: replicaId });
        return link;
    }

    hostLinkClosed(link) {
        if (this.hostLinks.get(link.replicaId) !== link) return;
        this.hostLinks.delete(link.replicaId);
        this.online?.federation.linkDown(link.replicaId);
    }

    noteReplicaLimit(replicaId, day) {
        if (this.replicaLimitReached.get(replicaId) === day) return;
        this.replicaLimitReached.set(replicaId, day);
        this.log('replica_limit', { host: replicaId, state: 'reached', count: this.replicaNewIds.limit });
    }

    // Replicas that have used up today's new IDs, for the dashboard.
    replicasAtLimit() {
        const day = this.today();
        return [...this.replicaLimitReached].filter(([, reached]) => reached === day).map(([id]) => ({ id,
            granted: this.replicaNewIds.used(id, day) }));
    }

    // A helper's reservation on this host: allocated here on the main host, forwarded on a replica.
    async reserve(request) {
        if (this.isMain) return this.allocate(request);
        if (!this.replicaLink) return UNAVAILABLE;
        return this.replicaLink.reserve(request);
    }

    // The only allocator (main host). A helper on this host spends its address's daily new-ID budget here; a
    // forwarded request arrives with the replica's decision in `allowNew`. A main host whose ID table never
    // finished copying answers "unavailable" rather than hand out IDs that may already be someone's.
    allocate({ identityHash, friendsId, afterCollision, addressKey = null, allowNew = true }) {
        if (!canAllocate(this.db)) return UNAVAILABLE;
        const day = this.today();
        const counted = allowNew && addressKey !== null;
        const permitted = allowNew && (!counted || this.admission.newIds.take(addressKey, day));
        const result = reserveId(this.db, { identityHash, friendsId, afterCollision, day, allowNew: permitted });
        if (counted && permitted && !result.granted) this.admission.newIds.refund(addressKey, day);
        if (result.granted) this.publishIdChange(result.change);
        return result;
    }

    async release({ identityHash, proof }) {
        if (this.isMain) return this.releaseHere(identityHash);
        return this.replicaLink ? this.replicaLink.release({ proof }) : false;
    }

    releaseHere(identityHash) {
        const { released, hadId } = releaseId(this.db, { identityHash, day: this.today() });
        if (hadId) this.publishIdChange({ identityHash, unset: true });
        return released;
    }

    // Every replica keeps a copy of the ID table (id-sync.js).
    publishIdChange(change) {
        for (const link of this.hostLinks.values()) link.sender.push(change);
    }

    // Which person a device checking in here speaks for (devices.js). The revocations its chain brings are kept on
    // every host; the main host also counts them. A device revoked just now is disconnected if it is here.
    admitDevice({ deviceKey, rootKey = null, chain = null }) {
        const result = admitDevice({ db: this.db, secret: this.config.identitySecret, deviceKey, rootKey, chain,
            day: this.today(), count: this.isMain });
        if (result.ok) this.disconnectRevoked(result.personHash, result.revoked);
        return result;
    }

    disconnectRevoked(personHash, deviceHashes) {
        for (const deviceHash of deviceHashes) {
            const session = this.live.get(Buffer.from(deviceHash).toString('hex'));
            if (session?.personHash?.equals(personHash)) {
                session.fail('device_revoked', 'This device was removed from its profile.', CLOSE.revoked);
            }
        }
    }

    recordCheckin({ identityHash, deviceHash = identityHash, appVersion, listVersion, protocol }) {
        const summary = { identityHash, deviceHash, day: this.today(), appVersion, listVersion, protocol };
        if (this.isMain) this.countCheckin(summary);
        else this.replicaLink?.enqueueSummary(summary);
    }

    // A check-in seen here or forwarded by a replica. Replicas' copies follow an ID holder's check-in days, which
    // retention on a promoted replica needs.
    countCheckin(summary) {
        const today = this.today();
        const change = recordCheckin(this.db, { ...summary, today });
        const { identityHash, deviceHash = identityHash, day } = summary;
        recordDevice(this.db, { identityHash, deviceHash, day, today });
        if (change.friendsId && change.advanced) this.publishIdChange(change);
    }

    // Once a minute: this host's connection count, the current day's derived statistics, and forgetting addresses
    // the rate limiter has not seen for 10 minutes.
    tick() {
        // Relay counters first, so a replica's report carries this minute's.
        this.online?.tick();
        const now = this.clock.now();
        const day = this.today();
        const sample = { minute: minuteOf(now), day, connections: this.liveCount() };
        if (this.isMain) {
            recordSample(this.db, { ...sample, hostId: this.config.hostId });
            discardPastDays(this.db, day);
            rollupDay(this.db, day, { isToday: true });
        } else {
            this.replicaLink?.report({ ...sample, listVersions: this.liveListVersions() });
        }
        this.admission.sweep(day);
        this.replicaNewIds.roll(day);
    }

    maintenance() {
        const today = this.today();
        expireRevocations(this.db, today);
        if (!this.isMain) return;
        discardPastDays(this.db, today);
        rollupDay(this.db, addDays(today, -1), { isToday: false });
        rollupDay(this.db, today, { isToday: true });
        const removed = applyRetention(this.db, { today, nowMinute: minuteOf(this.clock.now()) });
        for (const identityHash of removed.released) this.publishIdChange({ identityHash, unset: true });
        if (removed.identities > 0 || removed.probationEnded > 0) {
            this.log('retention', { removed: removed.identities, count: removed.probationEnded });
        }
    }
}
