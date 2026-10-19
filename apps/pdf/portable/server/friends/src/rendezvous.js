// Rendezvous records (HOST-PROTOCOL-ONLINE.md § Rendezvous records): one expiring record per device key, published
// over that device's own checked-in connection, signed by its key, naming the host it is connected to and holding a
// sealed blob of its standing connection candidates that only its friends can open. A person's devices all publish
// under the person's one rendezvous key (ADR 0010 § Several devices), the one their root key gives: a device that
// checked in for a person with its device chain (devices.js) publishes under its person's key, signed by its own.
// Records live in memory only, on every host in the list, so any host can route to any helper and
// answer lookups itself.
//
// Lookups must not tell anyone who is online. Every key gets exactly 512 bytes, and what a key gets is fixed for a
// whole period of host time (60 s, aligned to Unix time) and changes at the period's boundary, whether or not anyone
// is behind it: the blob of the newest record published under that key in the previous period and still live when
// this one began, or else filler that depends only on the key and the period. Publishing, leaving and expiring take
// effect on lookups at the next boundary, never in the middle of a period. Routing (sig_open) uses live records at
// once; it tells the caller nothing.

import { decodeBase64url, encodeBase64url, identityHash, verifyEd25519 } from './keys.js';
import { ONLINE_LIMITS, recordSignedBytes, rendezvousFiller, rendezvousKey } from './online-protocol.js';
import { validHostId } from './protocol.js';

function parseRecord(fields) {
    const sealed = decodeBase64url(fields.sealed, ONLINE_LIMITS.sealedRecordBytes);
    const sig = decodeBase64url(fields.sig, 64);
    if (!sealed || !sig || !Number.isSafeInteger(fields.seq) || fields.seq < 0
        || !Number.isSafeInteger(fields.expires) || fields.expires < 0) return null;
    return { sealed, sig, seq: fields.seq, expires: fields.expires };
}

export class RecordStore {
    constructor({ hostId, identitySecret, clock }) {
        this.hostId = hostId;
        this.identitySecret = identitySecret;
        this.clock = clock;
        this.byKey = new Map(); // rdv key (hex) -> Map of device key (hex) -> live record
        this.byIdentity = new Map(); // person (root key's identity hash, hex) -> rdv key (hex)
        this.bySession = new Map(); // checked-in connection on this host -> the record it published
        this.accepted = 0; // orders records by when they were accepted here
        this.shown = { period: this.period(), blobs: new Map() }; // what lookups answer this period, by rdv key
    }

    nowS() {
        return Math.floor(this.clock.now() / 1000);
    }

    period() {
        return Math.floor(this.nowS() / ONLINE_LIMITS.rdvPeriodS);
    }

    // At a period boundary, what lookups show for the new period: per rdv key, the newest record published during the
    // period that just ended and live at this one's start. Nothing that happens during a period changes it.
    roll() {
        const period = this.period();
        if (this.shown.period === period) return;
        const startS = period * ONLINE_LIMITS.rdvPeriodS;
        const blobs = new Map();
        for (const [key, devices] of this.byKey) {
            let newest = null;
            for (const record of devices.values()) {
                if (record.period !== period - 1 || record.expires <= startS) continue;
                if (!newest || record.acceptedAt > newest.acceptedAt) newest = record;
            }
            if (newest) blobs.set(key, newest.sealed);
        }
        this.shown = { period, blobs };
    }

    // What every host checks, wherever the record came from: the signature by the device key over this record's
    // host id, a sealed blob of the fixed size, an expiry in the next 15 minutes, a newer sequence number and a
    // newly sealed blob (one sealed the same as the one it replaces would stand out against the filler, which
    // changes every period).
    // `rootKey` is the person the device checked in for (the device's own key before protocol 3).
    verify({ identityKey, rootKey = identityKey, hostId, fields }) {
        const parsed = parseRecord(fields);
        if (!parsed) return { ok: false, error: 'malformed' };
        const now = this.nowS();
        if (parsed.expires <= now || parsed.expires > now + ONLINE_LIMITS.recordMaxTtlS) {
            return { ok: false, error: 'expiry' };
        }
        const rdvKey = rendezvousKey(rootKey);
        const signed = recordSignedBytes({ hostId, rdvKey, seq: parsed.seq, expires: parsed.expires,
            sealed: parsed.sealed });
        if (!verifyEd25519(identityKey, signed, parsed.sig)) return { ok: false, error: 'signature' };
        const existing = this.device(rdvKey.toString('hex'), identityKey.toString('hex'));
        if (existing && (existing.seq >= parsed.seq || existing.sealed.equals(parsed.sealed))) {
            return { ok: false, error: 'stale' };
        }
        return { ok: true, record: { ...parsed, rdvKey, identityKey, rootKey, hostId,
            identityHash: identityHash(this.identitySecret, identityKey).toString('hex'),
            personHash: identityHash(this.identitySecret, rootKey).toString('hex') } };
    }

    device(rdvKeyHex, deviceHex) {
        return this.byKey.get(rdvKeyHex)?.get(deviceHex) ?? null;
    }

    // Keeps `record` as its device's record under its rdv key, replacing only that device's. `session` is the
    // checked-in connection it came over on this host, or null for a record another host passed on.
    store(record, session = null) {
        this.roll();
        const key = record.rdvKey.toString('hex');
        let devices = this.byKey.get(key);
        if (!devices) {
            devices = new Map();
            this.byKey.set(key, devices);
        }
        this.accepted += 1;
        const kept = { ...record, session, acceptedAt: this.accepted, period: this.period() };
        devices.set(record.identityKey.toString('hex'), kept);
        this.byIdentity.set(record.personHash, key);
        if (session) this.bySession.set(session, kept);
    }

    // A record from a helper on this host; `session` is its checked-in connection, and the record is withdrawn when
    // that connection closes.
    publishLocal(session, fields) {
        const result = this.verify({ identityKey: session.identityKey, rootKey: session.rootKey ?? session.identityKey,
            hostId: this.hostId, fields });
        if (result.ok) this.store(result.record, session);
        return result;
    }

    // A record another host passed on over its authenticated link. It must name the host it was published on: a
    // host cannot place a record for one of its helpers on another host, and the signature covers the host id. The
    // person (`root_key`, absent before protocol 3) is the origin's word: it checked the device's chain at check-in.
    acceptRemote(origin, fields) {
        const identityKey = decodeBase64url(fields.identity_key, 32);
        const rootKey = fields.root_key === undefined ? identityKey : decodeBase64url(fields.root_key, 32);
        if (!identityKey || !rootKey || !validHostId(fields.host_id) || fields.host_id !== origin
            || origin === this.hostId) {
            return false;
        }
        const result = this.verify({ identityKey, rootKey, hostId: origin, fields });
        if (result.ok) this.store(result.record);
        return result.ok;
    }

    // What a host passes on: the device key travels between hosts so each can verify the signature itself.
    static wire(record) {
        const person = record.rootKey.equals(record.identityKey) ? {} : { root_key: encodeBase64url(record.rootKey) };
        return { identity_key: encodeBase64url(record.identityKey), ...person, host_id: record.hostId, seq: record.seq,
            expires: record.expires, sealed: encodeBase64url(record.sealed), sig: encodeBase64url(record.sig) };
    }

    static withdrawal(record) {
        return { rdv_key: record.rdvKey.toString('hex'), device_key: record.identityKey.toString('hex'),
            seq: record.seq };
    }

    // Removes a device's record if it is still the one with this sequence number, so a late withdrawal from one host
    // never removes a newer record the helper published through another.
    withdraw(rdvKeyHex, deviceHex, seq) {
        const record = typeof rdvKeyHex === 'string' && typeof deviceHex === 'string'
            ? this.device(rdvKeyHex, deviceHex) : null;
        if (!record || record.seq !== seq) return null;
        this.remove(record);
        return record;
    }

    remove(record) {
        this.roll();
        const key = record.rdvKey.toString('hex');
        const devices = this.byKey.get(key);
        if (!devices || devices.get(record.identityKey.toString('hex')) !== record) return;
        devices.delete(record.identityKey.toString('hex'));
        if (record.session && this.bySession.get(record.session) === record) this.bySession.delete(record.session);
        if (devices.size === 0) this.byKey.delete(key);
        if (devices.size === 0 && this.byIdentity.get(record.personHash) === key) {
            this.byIdentity.delete(record.personHash);
        }
    }

    // The record `session` published here, withdrawn because its connection closed.
    sessionClosed(session) {
        const record = this.bySession.get(session);
        if (!record) return null;
        this.bySession.delete(session);
        if (this.device(record.rdvKey.toString('hex'), record.identityKey.toString('hex')) !== record) return null;
        this.remove(record);
        return record;
    }

    all() {
        return [...this.byKey.values()].flatMap((devices) => [...devices.values()]);
    }

    // Every record published on a host for which `gone(hostId)` is true, dropped at once when the link that
    // brought them goes down.
    dropHosts(gone) {
        for (const record of this.all()) if (gone(record.hostId)) this.remove(record);
    }

    live(record) {
        return Boolean(record) && record.expires > this.nowS();
    }

    // Every key costs the same work and gets the same number of bytes back, fixed for the whole period.
    lookup(keys) {
        this.roll();
        const { period, blobs } = this.shown;
        return keys.map((key) => {
            const filler = rendezvousFiller(this.identitySecret, key, period);
            return encodeBase64url(blobs.get(key.toString('hex')) ?? filler);
        });
    }

    // Where the devices behind an rdv key are now: every live record under it.
    routesByKey(rdvKey) {
        const devices = this.byKey.get(rdvKey.toString('hex'));
        return devices ? [...devices.values()].filter((record) => this.live(record)) : [];
    }

    // Every device of the person whose root key has this identity hash: the holder of a Friends ID.
    routesByIdentity(identityHashHex) {
        const key = this.byIdentity.get(identityHashHex);
        return key ? this.routesByKey(Buffer.from(key, 'hex')) : [];
    }

    // Expired records go; the caller withdraws this host's own from the other hosts.
    sweep() {
        this.roll();
        const now = this.nowS();
        const gone = this.all().filter((record) => record.expires <= now);
        for (const record of gone) this.remove(record);
        return gone;
    }

    // Live records, except those published on `exceptHost`: what a host sends over a link that has just come up.
    liveRecords(exceptHost = null) {
        return this.all().filter((record) => this.live(record) && record.hostId !== exceptHost);
    }

    get size() {
        let n = 0;
        for (const devices of this.byKey.values()) n += devices.size;
        return n;
    }
}
